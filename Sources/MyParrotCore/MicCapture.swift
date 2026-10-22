import Foundation
import AVFoundation
import AudioToolbox
import os
import MyParrotObjC

/// Captures "you" — the microphone — via AVAudioEngine.
/// Kept separate from the system tap so the Bluetooth headset can stay on A2DP
/// for listening while we record from the built-in / wired mic.
///
/// `@unchecked Sendable`: all control (start/stop/rebuild) is confined to the main
/// thread — the owner (RecordingController, @MainActor) calls start/stop, and the
/// configuration-change observer is delivered on `OperationQueue.main`. The tap block
/// only *reads* `gain`/`onLevel`/`onBuffer`, which are set once before `start()`. So no
/// shared mutable state is concurrently written; the marker just lets the @Sendable
/// notification closure capture `self` (PKG-10).
final class MicCapture: @unchecked Sendable {

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    var gain: Float = 1.0

    private let engine = AVAudioEngine()
    private(set) var isRunning = false
    /// G-1 (跟 BUG-22 同一類縫): tracks whether the tap is actually installed,
    /// independent of `isRunning` — `engine.start()` can throw *after* the tap is
    /// already attached (`buildAndStart()`), leaving `isRunning` false. `stop()`
    /// must still know to remove that leaked tap. Unlike BUG-22's `tapID`/
    /// `aggregateID` (real CoreAudio handles that ARE the resource), this is a
    /// hand-synced bool — any future `installTap`/`removeTap` call site must keep
    /// it in sync too.
    private var tapInstalled = false

    /// The device this engine is pinned to (nil = system default). Remembered so the
    /// configuration-change self-heal can re-pin the same device (AUD-27 / BUG-18).
    private var deviceID: AudioDeviceID?
    private var configObserver: NSObjectProtocol?
    /// De-dupes + defers the config-change rebuild (2026-08-10 CLI 死鎖修復,見
    /// `rebuildAfterConfigurationChange()` 的完整說明)。main-confined,同 class
    /// 其餘引擎控制狀態一樣不需要鎖——`@unchecked Sendable` 的既有理由(class 頂
    /// 端註解)已涵蓋:所有讀寫都在 main thread。
    private var rebuildScheduled = false
    /// AUD-37(#2523):裝置變更後重建失敗的重試次數。AirPods 剛連上那一瞬間 inputNode 回報
    /// 0 聲道,等 1 秒端點就緒再試;超過上限交 AUD-28 看門狗。
    private var rebuildAttempts = 0
    static let maxRebuildAttempts = 3

    /// Optional specific input device; nil = system default input.
    func start(deviceID: AudioDeviceID? = nil) throws {
        guard !isRunning else { return }
        self.deviceID = deviceID
        try buildAndStart()
        isRunning = true
        observeConfigurationChange()
    }

    /// AUD-37(#2523):輸入格式要能裝 tap——取樣率與聲道數都要 >0。10/22 10:31 真機:
    /// AirPods 剛連上那一瞬間 AUHAL 先選到只有輸出的端點,inputNode 回報 0 聲道,
    /// `installTap` 對這種格式用 NSException 斷言(不是 throw),Swift `try?` 接不到 ⇒ abort。
    static func isUsableInputFormat(sampleRate: Double, channels: UInt32) -> Bool {
        sampleRate > 0 && channels > 0
    }

    /// Pin the device, read the *current* hardware format, install the tap and start.
    /// Reused by `start()` and by the configuration-change self-heal — both must read a
    /// FRESH format: after a device/route change `outputFormat(forBus:)` only reflects the
    /// new device once the audio unit has renegotiated its stream description.
    ///
    /// AUD-37:整段包進 ObjC `@try/@catch`(`MPCatchObjCException`)。AVFAudio 的前置條件
    /// 失敗(格式與硬體不符、0 聲道、重複裝 tap)全是 NSException,Swift 的 do/catch 接不到;
    /// 轉成 Swift error 丟回呼叫端,讓 `rebuildAfterConfigurationChange` 重試、看門狗接手,
    /// 而不是整個 app 死掉。
    private func buildAndStart() throws {
        var failure: Error?
        var tapWasInstalled = false
        let exception = MPCatchObjCException {
            do {
                let input = self.engine.inputNode
                if let deviceID = self.deviceID, let au = input.audioUnit {
                    var dev = deviceID
                    AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                         kAudioUnitScope_Global, 0, &dev,
                                         UInt32(MemoryLayout<AudioDeviceID>.size))
                }
                let format = input.outputFormat(forBus: 0)
                guard Self.isUsableInputFormat(sampleRate: format.sampleRate, channels: format.channelCount) else {
                    throw "麥克風不可用(輸入格式 \(Int(format.sampleRate)) Hz／\(format.channelCount) ch)"
                }
                // format: nil = 用節點此刻的輸出格式(避開「傳入格式與硬體不符」那條斷言);
                // 下游 MonoDownconverter 逐 buffer 看格式重採樣,不依賴固定格式。
                input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                    guard let self else { return }
                    if self.gain != 1.0 { buffer.scale(by: self.gain) }
                    self.onLevel?(buffer.rmsLevel)
                    self.onBuffer?(buffer)
                }
                tapWasInstalled = true
                self.engine.prepare()
                try self.engine.start()
            } catch {
                failure = error
            }
        }
        tapInstalled = tapWasInstalled
        if let exception {
            os_log("MyParrot mic: AVAudioEngine 例外 %{public}@: %{public}@",
                   exception.name.rawValue, exception.reason ?? "")
            if tapWasInstalled { removeTapQuietly() }
            throw "麥克風引擎例外:\(exception.name.rawValue) \(exception.reason ?? "")"
        }
        if let failure { throw failure }
    }

    /// `removeTap` 在沒有輸入裝置時同樣可能斷言,一樣包起來。
    private func removeTapQuietly() {
        _ = MPCatchObjCException { self.engine.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
    }

    /// AUD-27 / BUG-18: when the input hardware's channel count or sample rate changes
    /// (a meeting app grabs/switches the default input, Bluetooth flips A2DP↔HFP, a device
    /// is un/replugged), AVAudioEngine **stops and uninitializes itself** and posts this
    /// notification — it does NOT auto-restart. Left unhandled, the engine stays dead and
    /// the tap delivers nothing → 你軌 goes permanently silent until the user manually
    /// switches mics. So we rebuild the tap with the now-current format and restart.
    ///
    /// Apple's docs warn the engine must not be torn down synchronously inside the
    /// notification's internal dispatch queue (it DEADLOCKS). Delivering on
    /// `OperationQueue.main` runs the rebuild on the main thread instead — decoupled from
    /// that internal queue — which both avoids the deadlock and keeps all engine control
    /// main-confined.
    private func observeConfigurationChange() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.rebuildAfterConfigurationChange()
        }
    }

    /// ① 為什麼要跳出 callout + 延遲 + 去重(2026-08-10 CLI 死鎖實測,取代原本
    /// 「同步重建」版本):上面那段註解說「deliver on .main 可避免 Apple 文件警告
    /// 的死鎖」——這在 GUI app 兩個月的正常使用下成立,但在**引擎剛啟動的瞬間**
    /// 破功:CLI 版 `myparrot record` 真 Terminal 100% 重現過,`sample` stack 顯示
    /// main thread 卡在這裡呼叫的 `buildAndStart()`→`AVAudioEngine.start()`→
    /// CoreAudio `HALC_ProxyIOContext::_StartIO`→`HALB_IOThread::_WaitForState`,
    /// 對一個 pthread mutex 永久等待。根因:`AVAudioEngineConfigurationChange`
    /// 有時在 `engine.start()` 都還沒完全回傳、HAL 內部狀態機還在轉換時就送達
    /// (`.main` queue 只保證跳出 Apple 私有 dispatch queue,不保證 HAL 已經穩定),
    /// 通知 callout 內同步呼叫 `engine.stop()`+`engine.start()` 這種「重入 HAL
    /// StartIO」的動作,就撞上這個 mutex。改成 `asyncAfter` 完全跳出這次通知的
    /// callout(不在它的呼叫堆疊上做任何引擎操作),讓 run loop 先回轉一輪。
    ///
    /// ② BUG-18/AUD-27 語意保留:裝置變更後**還是**在 0.3 秒內自動重建、自動
    /// 重新掛回同一顆(`deviceID` 記住的)裝置,使用者感受不到差異——只是把
    /// 「立刻同步重建」改成「跳出通知堆疊,0.3 秒後在乾淨的 main run loop 迭代
    /// 重建」。0.3 秒遠低於 `RecordingController` AUD-28 看門狗對「你軌無訊號」
    /// 的容忍窗(3 秒),不會被看門狗誤判成另一次故障、觸發不必要的二次重試。
    ///
    /// ③ 為什麼是 0.3 秒 + 去重(`rebuildScheduled`):給 HAL 一點時間讓上一輪
    /// 裝置轉換真正完成(而不是在它還沒穩定時就再戳一次 `engine.start()`,重蹈
    /// 同一個死鎖);同時裝置切換常常在極短時間內連續送出好幾個
    /// `AVAudioEngineConfigurationChange`(一次路由變更可能觸發格式變更+裝置
    /// 變更兩則通知),`rebuildScheduled` 確保這些通知合併成同一次重建,不會
    /// 排出好幾個互相打架的 `asyncAfter` 重建。
    ///
    /// ④ AUD-37(#2523,2026-10-22):重建失敗(端點還沒就緒、格式 0 聲道、AVFAudio 斷言被
    /// `buildAndStart` 接成 error)不再 `try?` 吞掉——1 秒後再試,最多 3 次;仍失敗就保持
    /// `isRunning` 讓 AUD-28 看門狗(3 秒無訊號)走 `rebuildCurrentMic()` 換裝置重建。
    private func rebuildAfterConfigurationChange(after delay: TimeInterval = 0.3) {
        guard isRunning, !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            guard self.isRunning else { return }
            self.removeTapQuietly()
            self.engine.stop()
            do {
                try self.buildAndStart()
                self.rebuildAttempts = 0
            } catch {
                self.rebuildAttempts += 1
                os_log("MyParrot mic: 裝置變更後重建失敗(第 %d 次):%{public}@", self.rebuildAttempts, "\(error)")
                if self.rebuildAttempts < Self.maxRebuildAttempts {
                    self.rebuildAfterConfigurationChange(after: 1.0)
                } else {
                    self.rebuildAttempts = 0
                }
            }
        }
    }

    func stop() {
        // G-1 審查發現:guard 曾經只看 `isRunning`,但 `start()` 中途失敗時
        // (tap 已裝在 `buildAndStart()`,`engine.start()` 才拋錯)`isRunning`
        // 還沒被設成 true,導致這裡整段清理被跳過 → tap 永久洩漏——跟 BUG-22
        // 修復前的 `SystemAudioCapture` 一模一樣的縫。改用 `tapInstalled` 是否
        // 真的裝了判斷,不管 `isRunning` 有沒有真的翻過。
        guard isRunning || tapInstalled else { return }
        isRunning = false
        rebuildAttempts = 0
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        removeTapQuietly()
        engine.stop()
    }

    deinit { stop() }
}

extension AVAudioPCMBuffer {
    /// Apply input gain `g`, then a soft-knee limiter so high gain can't push the
    /// signal past ±1 and clip ("破音"). Linear below ±0.9, smoothly compressed above.
    func scale(by g: Float) {
        guard let data = floatChannelData else { return }
        let n = Int(frameLength)
        let knee: Float = 0.9, span: Float = 0.1   // span = 1 - knee
        for c in 0..<Int(format.channelCount) {
            let ch = data[c]
            for i in 0..<n {
                let v = ch[i] * g
                if v > knee { ch[i] = knee + span * tanhf((v - knee) / span) }
                else if v < -knee { ch[i] = -knee - span * tanhf((-v - knee) / span) }
                else { ch[i] = v }
            }
        }
    }
}
