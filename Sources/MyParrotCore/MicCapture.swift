import Foundation
import AVFoundation
import AudioToolbox
import os
import MyParrotObjC

/// Captures "you" — the microphone — via AVAudioEngine.
/// Kept separate from the system tap so the Bluetooth headset can stay on A2DP
/// for listening while we record from the built-in / wired mic.
///
/// 執行緒模型(AUD-38,#2529;取代 PKG-10 的「全部 main-confined」):
/// - **引擎控制全部在私有序列佇列 `controlQueue`(AUD-39 起所有實例共用一條)**:建 inputNode、釘裝置、讀格式、裝／拆 tap、prepare／start／stop、
///   保持器、重建判定。真機量到藍牙 HFP 下建 inputNode 3.1 秒＋讀輸入格式 3.0 秒(`start` 本身 ≤55 ms),
///   放 main 就是 6 秒轉圈圈;所以整段離開 main,不是只搬 start。main 不碰引擎。
/// - `start(deviceID:isBluetooth:completion:)`／`stop(completion:)` 非阻塞,完成時在 main 回呼。
/// - `onBuffer`／`onLevel`／`gain`／`onLocked` 跟以前一樣:start 前在 main 設好,tap 與 controlQueue 只讀。
/// - `muted` 是唯一跨執行緒寫的旗標(stop() 在呼叫端立刻翻 true,tap 馬上丟 buffer),用 lock 保護。
/// - 標為 `@unchecked Sendable`:上面這些約束由佇列紀律保證,不是編譯器。
final class MicCapture: @unchecked Sendable {

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    var gain: Float = 1.0
    /// 震盪鎖觸發時回 main 通知擁有者(RecordingController 跳橫幅、記 locked)。
    var onLocked: (@Sendable () -> Void)?

    /// AUD-39:**所有實例共用**一條序列佇列——舊引擎拆完才建／啟新的,不再並行拆建(並行時 HAL 互搶,
    /// 真機 R3 新引擎 inputNode 卡 20.5 秒的現場就是舊引擎還在拆)。label 不變。
    private static let controlQueue = DispatchQueue(label: "tw.uncle.MyParrot.mic-control", qos: .userInitiated)
    private let engine = AVAudioEngine()
    /// stop() 一呼叫就翻 true,tap 立刻丟 buffer;其餘清理在佇列上慢慢做。
    private let muted = OSAllocatedUnfairLock(initialState: false)
    /// AUD-39 D(G1):切麥時舊實例還在錄,但它的裝置變更自癒不能再排進共用佇列插隊(會跟新實例的 prepare 搶 HAL)。
    private let selfHealSuspended = OSAllocatedUnfairLock(initialState: false)

    // MARK: 以下全部 controlQueue-confined,main 不讀不寫。

    private var isRunning = false
    /// AUD-39:prepare 完成(tap 已裝、引擎已 prepare)但還沒 run。
    private var isPrepared = false
    /// G-1 (跟 BUG-22 同一類縫): tracks whether the tap is actually installed,
    /// independent of `isRunning` — the engine start can throw *after* the tap is
    /// already attached (`buildAndStart()`), leaving `isRunning` false. `stop()`
    /// must still know to remove that leaked tap. Hand-synced bool — any future
    /// `installTap`/`removeTap` call site must keep it in sync too.
    private var tapInstalled = false
    /// 去重＋延遲裝置變更後的重建(2026-08-10 CLI 死鎖修復,見 `rebuildAfterConfigurationChange()`)。
    private var rebuildScheduled = false
    /// AUD-37(#2523):裝置變更後重建失敗的重試次數。AirPods 剛連上那一瞬間 inputNode 回報
    /// 0 聲道,等 1 秒端點就緒再試;超過上限交 AUD-28 看門狗。
    private var rebuildAttempts = 0
    /// The device this engine is pinned to (nil = system default). Remembered so the
    /// configuration-change self-heal can re-pin the same device (AUD-27 / BUG-18).
    private var deviceID: AudioDeviceID?
    private var isBluetooth = false
    /// AUD-38:藍牙裝置的 HFP 保持器,活到 stop()(或震盪鎖)。
    private var holder: BluetoothInputHolder?
    /// tap 裝上時的輸入格式鍵,例 "24000/1";偽通知判定拿現在的格式跟它比。
    private var tapFormatKey = ""
    /// 震盪鎖用的裝置變更重建紀錄(只留 20 秒內)。
    private var configRebuilds: [MicRebuildPolicy.Rebuild] = []
    /// 震盪鎖住了:不再自動重建,直到換裝置(新的 MicCapture 實例)或重新 start。
    private var locked = false
    private var configObserver: NSObjectProtocol?
    /// 每次 start/stop 遞增;排在佇列上、跨過 start/stop 的舊重建一律作廢。
    private var lifecycle = 0
    static let maxRebuildAttempts = 3

    // MARK: - 控制(非阻塞)

    /// AUD-39 D(G1):暫停／恢復裝置變更自癒(引擎照錄,只是不再自己拆建)。切麥決定後對舊實例呼叫;
    /// 切換沒成、舊實例繼續錄時恢復。
    func suspendSelfHeal() { selfHealSuspended.withLock { $0 = true } }
    func resumeSelfHeal() { selfHealSuspended.withLock { $0 = false } }

    /// AUD-39 D(G2):實例是**單次使用**——`stop()` 過(muted)就不能再 prepare／run;作廢的 prepare 在每個等待點提早結束。
    private func throwIfStopped() throws {
        if muted.withLock({ $0 }) { throw "麥克風已停止(這一輪 prepare／run 已作廢)" }
    }

    /// AUD-39「先建後拆」的第一步:保持器 → 等系統預設輸入穩定 → inputNode → 釘裝置 → 格式 → tap → prepare,
    /// **不 start**。`deviceID` nil＝系統預設輸入;`avoidDeviceID`＝剛被移除的裝置(等預設輸入換掉它)。
    /// 完成(成功 nil／失敗 error)在 main 回呼;失敗時已自己清乾淨。
    func prepare(deviceID: AudioDeviceID?, isBluetooth: Bool, avoidDeviceID: AudioDeviceID?,
                 completion: @escaping @Sendable (Error?) -> Void) {
        MicCapture.controlQueue.async { [self] in
            do {
                try prepareOnQueue(deviceID: deviceID, isBluetooth: isBluetooth, avoidDeviceID: avoidDeviceID)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// AUD-39「先建後拆」的第二步:`engine.start`＋掛觀察者。要先 `prepare` 成功;中間被 `stop()` 過就回錯。
    func run(completion: @escaping @Sendable (Error?) -> Void) {
        MicCapture.controlQueue.async { [self] in
            do {
                try runOnQueue()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// 開始收音＝prepare＋run 一次做完(開錄、麥克風測試、fallback 用)。`isBluetooth` 為 true 且有指定裝置時,
    /// 先起 HFP 保持器(最多等 1.5 秒 HFP 接上)再建引擎。完成在 main 回呼。
    func start(deviceID: AudioDeviceID?, isBluetooth: Bool, avoidDeviceID: AudioDeviceID? = nil,
               completion: @escaping @Sendable (Error?) -> Void) {
        MicCapture.controlQueue.async { [self] in
            do {
                try prepareOnQueue(deviceID: deviceID, isBluetooth: isBluetooth, avoidDeviceID: avoidDeviceID)
                try runOnQueue()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    private func prepareOnQueue(deviceID: AudioDeviceID?, isBluetooth: Bool, avoidDeviceID: AudioDeviceID?) throws {
        dispatchPrecondition(condition: .onQueue(MicCapture.controlQueue))
        try throwIfStopped()   // G2:stop 過的實例不再 prepare(也不把 muted 翻回 false)
        guard !isRunning, !isPrepared else { return }
        lifecycle += 1
        self.deviceID = deviceID
        self.isBluetooth = isBluetooth
        locked = false
        configRebuilds = []
        rebuildAttempts = 0
        rebuildScheduled = false
        do {
            if BluetoothHoldPolicy.shouldHold(isBluetooth: isBluetooth), let deviceID {
                try startHolderAndWait(deviceID)
            }
            try throwIfStopped()
            try buildEngine(avoidDeviceID: avoidDeviceID)
            isPrepared = true
        } catch {
            cleanupAfterFailure()
            throw error
        }
    }

    private func runOnQueue() throws {
        dispatchPrecondition(condition: .onQueue(MicCapture.controlQueue))
        guard !isRunning else { return }
        guard isPrepared else { throw "麥克風引擎尚未準備好(prepare 之後被停止或失敗)" }
        do {
            try throwIfStopped()   // G2
            try startEngine()
            isPrepared = false
            isRunning = true
            observeConfigurationChange()          // start 成功後才掛
        } catch {
            cleanupAfterFailure()
            throw error
        }
    }

    /// 擁有者拿到失敗通常直接丟掉這個實例、不會再呼叫 stop(),所以失敗就清乾淨
    /// (G-1:engine start 失敗時 tap 可能已經裝上)。
    private func cleanupAfterFailure() {
        dispatchPrecondition(condition: .onQueue(MicCapture.controlQueue))
        isPrepared = false
        removeTapQuietly()
        engine.stop()
        holder?.stop()
        holder = nil
    }

    /// 停止收音。呼叫當下立刻靜音(tap 丟 buffer,呼叫端不必等);拆 tap、停引擎、停保持器在佇列上做,
    /// 做完(有給 completion 才)在 main 回呼。
    func stop(completion: (@Sendable () -> Void)? = nil) {
        muted.withLock { $0 = true }
        MicCapture.controlQueue.async { [self] in
            lifecycle += 1
            // G-1 審查發現:guard 曾經只看 `isRunning`,但 start 中途失敗時 tap 可能已裝而
            // `isRunning` 還是 false ⇒ tap 永久洩漏(跟 BUG-22 修復前的 `SystemAudioCapture` 一樣的縫)。
            // AUD-38 再加保持器:start 失敗或震盪鎖之外的路徑也可能留著它。
            guard isRunning || isPrepared || tapInstalled || holder != nil else {
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            isRunning = false
            isPrepared = false
            rebuildAttempts = 0
            rebuildScheduled = false
            if let configObserver {
                NotificationCenter.default.removeObserver(configObserver)
                self.configObserver = nil
            }
            removeTapQuietly()
            engine.stop()
            holder?.stop()
            holder = nil
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// 擁有者負責 stop();這裡不做任何引擎操作(可能不在 controlQueue 上)。
    /// 保持器若還在,`BluetoothInputHolder.deinit` 會自己停掉 IOProc。
    deinit {
        #if DEBUG
        if isRunning { os_log("MyParrot mic: MicCapture 釋放時仍在跑(擁有者沒呼叫 stop)") }
        #endif
    }

    /// AUD-37(#2523):輸入格式要能裝 tap——取樣率與聲道數都要 >0。10/22 10:31 真機:
    /// AirPods 剛連上那一瞬間 AUHAL 先選到只有輸出的端點,inputNode 回報 0 聲道,
    /// `installTap` 對這種格式用 NSException 斷言(不是 throw),Swift `try?` 接不到 ⇒ abort。
    static func isUsableInputFormat(sampleRate: Double, channels: UInt32) -> Bool {
        sampleRate > 0 && channels > 0
    }

    // MARK: - 保持器(controlQueue,允許阻塞)

    /// 記 baseline → 起保持器(失敗就記 log、不留保持器,照建引擎＝退回沒有保持器的行為)→
    /// baseline 已 HFP 就不等;否則每 0.1 秒看格式快照,直到任一欄變了(HFP 接上)或 1.5 秒 → 記一行耗時。
    private func startHolderAndWait(_ dev: AudioDeviceID) throws {
        dispatchPrecondition(condition: .onQueue(MicCapture.controlQueue))
        let t0 = DispatchTime.now()
        let baseline = BluetoothInputHolder.snapshot(dev)
        let h = BluetoothInputHolder(deviceID: dev)
        let status = h.start()
        let startMs = Self.ms(since: t0)
        guard status == noErr else {
            os_log("MyParrot mic: holder start 失敗 status=%d(%ldms),照建引擎(無保持器)", status, startMs)
            holder = nil
            return
        }
        holder = h
        let waitStart = DispatchTime.now()
        var latest = baseline
        var settled = false
        // AUD-39:baseline 已是窄頻＝HFP 早就接上(殘留狀態),保持器照起、不等變化。
        if BluetoothHoldPolicy.alreadyHFP(baseline) {
            os_log("MyParrot mic: holder started in %ldms, baseline 已 HFP(in %ld/%ld out %ld),不等",
                   startMs, baseline.inRate, baseline.inCh, baseline.outRate)
            return
        }
        while true {
            try throwIfStopped()   // G2:作廢就不再等(保持器由 cleanupAfterFailure 停掉)
            latest = BluetoothInputHolder.snapshot(dev)
            if BluetoothHoldPolicy.settled(baseline: baseline, now: latest) { settled = true; break }
            if Double(Self.ms(since: waitStart)) >= BluetoothHoldPolicy.settleTimeout * 1000 { break }
            Thread.sleep(forTimeInterval: BluetoothHoldPolicy.pollInterval)
        }
        os_log("MyParrot mic: holder started in %ldms, settled=%ld after %ldms (in %ld/%ld out %ld → in %ld/%ld out %ld)",
               startMs, settled ? 1 : 0, Self.ms(since: waitStart),
               baseline.inRate, baseline.inCh, baseline.outRate, latest.inRate, latest.inCh, latest.outRate)
    }

    // MARK: - 等系統預設輸入穩定(controlQueue,允許阻塞;AUD-39)

    /// 碰 `engine.inputNode` 之前:AUHAL 建立時會先開**系統預設輸入**,預設輸入還指著剛消失的裝置時
    /// 要等 HAL 放棄(真機 R3 20.5 秒)。這裡只讀**系統物件**的兩個屬性(預設輸入 id、裝置 id 清單),
    /// 不讀任何逐顆裝置屬性(那些在藍牙狀態變動時同樣會卡)。0.1 秒一次、上限 2 秒,超時照建。
    private func waitForDefaultInputSettled(avoidDeviceID: AudioDeviceID?) throws {
        dispatchPrecondition(condition: .onQueue(MicCapture.controlQueue))
        let t0 = DispatchTime.now()
        var defaultID: AudioDeviceID = 0
        var settled = false
        while true {
            try throwIfStopped()   // G2
            defaultID = Self.systemDefaultInputID()
            if MicDevicePolicy.defaultInputSettled(defaultID: defaultID, deviceIDs: Self.systemDeviceIDs(),
                                                   removedID: avoidDeviceID) {
                settled = true
                break
            }
            if Double(Self.ms(since: t0)) >= MicDevicePolicy.settleTimeout * 1000 { break }
            Thread.sleep(forTimeInterval: MicDevicePolicy.pollInterval)
        }
        if settled {
            os_log("MyParrot mic: 預設輸入穩定 waited=%ldms default=%u avoid=%u",
                   Self.ms(since: t0), defaultID, avoidDeviceID ?? 0)
        } else {
            os_log("MyParrot mic: 預設輸入 2 s 內未穩定,照建 waited=%ldms default=%u avoid=%u",
                   Self.ms(since: t0), defaultID, avoidDeviceID ?? 0)
        }
    }

    /// 系統物件的 `kAudioHardwarePropertyDefaultInputDevice`(讀不到回 0)。
    private static func systemDefaultInputID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return st == noErr ? id : 0
    }

    /// 系統物件的 `kAudioHardwarePropertyDevices`(只有 id 陣列;讀不到回空)。
    private static func systemDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let st = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }
        return st == noErr ? ids : []
    }

    // MARK: - 建引擎(controlQueue)

    /// 裝置變更自癒用:建＋啟一次做完(引擎原地重建,不走 prepare/run 狀態)。
    private func buildAndStart() throws {
        try buildEngine(avoidDeviceID: nil)
        try startEngine()
    }

    /// Pin the device, read the *current* hardware format, install the tap and prepare (no start).
    /// Reused by `prepare` and by the configuration-change self-heal — both must read a
    /// FRESH format: after a device/route change the input node's format only reflects the
    /// new device once the audio unit has renegotiated its stream description.
    ///
    /// AUD-37:整段包進 ObjC `@try/@catch`(`MPCatchObjCException`)。AVFAudio 的前置條件
    /// 失敗(格式與硬體不符、0 聲道、重複裝 tap)全是 NSException,Swift 的 do/catch 接不到;
    /// 轉成 Swift error 丟回呼叫端,讓 `rebuildAfterConfigurationChange` 重試、看門狗接手,
    /// 而不是整個 app 死掉。
    ///
    /// AUD-38:逐步量 inputNode／setDevice／讀格式／installTap／prepare 的毫秒數,成功或失敗都記一行
    /// (`MyParrot mic: build steps …`,Eric 真機靠它量);沒走到的步驟記 -1。AUD-39:start 那一步改在
    /// `startEngine` 另記一行(`MyParrot mic: engine start …`);碰 inputNode 前先等系統預設輸入穩定。
    private func buildEngine(avoidDeviceID: AudioDeviceID?) throws {
        dispatchPrecondition(condition: .onQueue(MicCapture.controlQueue))
        try waitForDefaultInputSettled(avoidDeviceID: avoidDeviceID)
        try throwIfStopped()   // G2:碰 inputNode 之前最後一次確認沒被作廢
        var failure: Error?
        var tapWasInstalled = false
        var clock = StepClock()
        var steps = [Int](repeating: -1, count: 5)   // inputNode, setDevice, outputFormat, installTap, prepare
        var formatKey = "?"
        let exception = MPCatchObjCException {
            do {
                let input = self.engine.inputNode
                steps[0] = clock.lap()
                if let deviceID = self.deviceID, let au = input.audioUnit {
                    var dev = deviceID
                    AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                         kAudioUnitScope_Global, 0, &dev,
                                         UInt32(MemoryLayout<AudioDeviceID>.size))
                }
                steps[1] = clock.lap()
                let format = input.outputFormat(forBus: 0)
                steps[2] = clock.lap()
                formatKey = Self.formatKey(sampleRate: format.sampleRate, channels: format.channelCount)
                guard Self.isUsableInputFormat(sampleRate: format.sampleRate, channels: format.channelCount) else {
                    throw "麥克風不可用(輸入格式 \(Int(format.sampleRate)) Hz／\(format.channelCount) ch)"
                }
                // format: nil = 用節點此刻的輸出格式(避開「傳入格式與硬體不符」那條斷言);
                // 下游 MonoDownconverter 逐 buffer 看格式重採樣,不依賴固定格式。
                input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                    guard let self else { return }
                    if self.muted.withLock({ $0 }) { return }
                    if self.gain != 1.0 { buffer.scale(by: self.gain) }
                    self.onLevel?(buffer.rmsLevel)
                    self.onBuffer?(buffer)
                }
                tapWasInstalled = true
                steps[3] = clock.lap()
                self.engine.prepare()
                steps[4] = clock.lap()
            } catch {
                failure = error
            }
        }
        tapInstalled = tapWasInstalled
        if tapWasInstalled { tapFormatKey = formatKey }
        let ok = exception == nil && failure == nil
        os_log("MyParrot mic: build steps bt=%ld inputNode=%ldms setDevice=%ldms outputFormat=%ldms installTap=%ldms prepare=%ldms format=%{public}@ ok=%ld",
               isBluetooth ? 1 : 0, steps[0], steps[1], steps[2], steps[3], steps[4], formatKey, ok ? 1 : 0)
        if let exception {
            os_log("MyParrot mic: AVAudioEngine 例外 %{public}@: %{public}@",
                   exception.name.rawValue, exception.reason ?? "")
            if tapWasInstalled { removeTapQuietly() }
            throw "麥克風引擎例外:\(exception.name.rawValue) \(exception.reason ?? "")"
        }
        if let failure { throw failure }
    }

    /// `engine.start`(同樣包 `MPCatchObjCException`),記一行耗時。
    private func startEngine() throws {
        dispatchPrecondition(condition: .onQueue(MicCapture.controlQueue))
        var failure: Error?
        var clock = StepClock()
        let exception = MPCatchObjCException {
            do { try self.engine.start() } catch { failure = error }
        }
        let ms = clock.lap()
        os_log("MyParrot mic: engine start %ldms bt=%ld ok=%ld", ms, isBluetooth ? 1 : 0, (exception == nil && failure == nil) ? 1 : 0)
        if let exception {
            os_log("MyParrot mic: AVAudioEngine 例外 %{public}@: %{public}@",
                   exception.name.rawValue, exception.reason ?? "")
            throw "麥克風引擎例外:\(exception.name.rawValue) \(exception.reason ?? "")"
        }
        if let failure { throw failure }
    }

    /// `removeTap` 在沒有輸入裝置時同樣可能斷言,一樣包起來。沒裝 tap 就不碰 inputNode
    /// (HFP 下第一次碰 inputNode 會建 AUHAL,要 3 秒)。
    private func removeTapQuietly() {
        dispatchPrecondition(condition: .onQueue(MicCapture.controlQueue))
        guard tapInstalled else { return }
        _ = MPCatchObjCException { self.engine.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
    }

    /// 現在 inputNode 的輸出格式鍵(在 controlQueue 上,HFP 下可能要幾秒;讀不到回 "")。
    private func currentFormatKey() -> String {
        dispatchPrecondition(condition: .onQueue(MicCapture.controlQueue))
        var key = ""
        _ = MPCatchObjCException {
            let f = self.engine.inputNode.outputFormat(forBus: 0)
            key = Self.formatKey(sampleRate: f.sampleRate, channels: f.channelCount)
        }
        return key
    }

    static func formatKey(sampleRate: Double, channels: AVAudioChannelCount) -> String {
        "\(Int(sampleRate))/\(channels)"
    }

    // MARK: - 裝置變更自癒(AUD-27／BUG-18,AUD-38 加偽通知判定與震盪鎖)

    /// AUD-27 / BUG-18: when the input hardware's channel count or sample rate changes
    /// (a meeting app grabs/switches the default input, Bluetooth flips A2DP↔HFP, a device
    /// is un/replugged), AVAudioEngine **stops and uninitializes itself** and posts this
    /// notification — it does NOT auto-restart. Left unhandled, the engine stays dead and
    /// the tap delivers nothing → 你軌 goes permanently silent until the user manually
    /// switches mics. So we rebuild the tap with the now-current format and restart.
    ///
    /// callout 內**不碰引擎、也不讓發通知的執行緒等任何佇列**:只把重建丟到 controlQueue。
    /// 為什麼用 `queue: nil`＋自己 async,而不是 `queue:` 指定一個以 controlQueue 為底的 OperationQueue:
    /// #2529 執行時實測(scratchpad nc-probe)`NotificationCenter.post` 會**等**被指定佇列把 block 跑完
    /// (佇列忙 2 秒 ⇒ post 卡 1.9 秒)。controlQueue 常常正在建引擎(HFP 下 6 秒),AVFAudio 的內部佇列若
    /// 在那時發通知就會被我們卡住;若建引擎那一步又在等那條內部佇列 ⇒ 死鎖。`queue: nil` 讓 block 直接在
    /// 發通知的執行緒跑,而它只做一次非阻塞的 async。
    private func observeConfigurationChange() {
        dispatchPrecondition(condition: .onQueue(MicCapture.controlQueue))
        guard configObserver == nil else { return }
        let gen = lifecycle
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            MicCapture.controlQueue.async { [weak self] in
                guard let self, self.lifecycle == gen else { return }
                self.rebuildAfterConfigurationChange()
            }
        }
    }

    /// ① 為什麼要跳出 callout + 延遲 + 去重(2026-08-10 CLI 死鎖實測):CLI 版 `myparrot record`
    /// 真 Terminal 100% 重現過,`sample` stack 顯示當時在通知 callout 內同步呼叫的重建卡在
    /// 引擎 start → CoreAudio `HALC_ProxyIOContext::_StartIO` → `HALB_IOThread::_WaitForState`,
    /// 對一個 pthread mutex 永久等待。根因:`AVAudioEngineConfigurationChange` 有時在引擎 start
    /// 都還沒完全回傳、HAL 內部狀態機還在轉換時就送達,callout 內同步 stop+start 這種「重入 HAL
    /// StartIO」的動作就撞上這個 mutex。所以排 `asyncAfter` 完全跳出這次通知的 callout。
    ///
    /// ② BUG-18/AUD-27 語意保留:裝置變更後**還是**在 0.3 秒內自動重建、自動重新掛回同一顆
    /// (`deviceID` 記住的)裝置。0.3 秒遠低於 `RecordingController` AUD-28 看門狗對「你軌無訊號」
    /// 的容忍窗(3 秒),不會被看門狗誤判成另一次故障。
    ///
    /// ③ 為什麼是 0.3 秒 + 去重(`rebuildScheduled`):給 HAL 一點時間讓上一輪裝置轉換真正完成;
    /// 同時一次路由變更常連續送出好幾個通知,`rebuildScheduled` 讓它們合併成同一次重建。
    ///
    /// ④ AUD-37(#2523):重建失敗(端點還沒就緒、格式 0 聲道、AVFAudio 斷言被 `buildAndStart`
    /// 接成 error)1 秒後再試,最多 3 次;仍失敗就保持 `isRunning` 讓 AUD-28 看門狗接手。
    ///
    /// ⑤ AUD-38(#2529):拆之前先判偽通知(引擎仍在跑、格式鍵沒變 ⇒ 忽略),再看震盪鎖(藍牙、20 秒內
    /// 同一格式鍵第 3 次 ⇒ 停引擎、停保持器、不再自動重建、回 main 通知擁有者)。重建時保持器不動,繼續撐 HFP。
    private func rebuildAfterConfigurationChange(after delay: TimeInterval = 0.3) {
        dispatchPrecondition(condition: .onQueue(MicCapture.controlQueue))
        guard isRunning, !locked, !rebuildScheduled else { return }
        guard !selfHealSuspended.withLock({ $0 }) else { return }   // G1:切麥中的舊實例不自癒
        rebuildScheduled = true
        let gen = lifecycle
        MicCapture.controlQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.lifecycle == gen else { return }
            self.rebuildScheduled = false
            guard !self.muted.withLock({ $0 }) else { return }   // F3:stop() 一呼叫就不再重建
            self.performConfigurationRebuild()
        }
    }

    private func performConfigurationRebuild() {
        dispatchPrecondition(condition: .onQueue(MicCapture.controlQueue))
        guard isRunning, !locked else { return }
        // F3:stop() 已被呼叫(muted 在呼叫端當下就翻)⇒ 不再重建、也不再鎖(否則切麥途中舊實例的鎖會記到新裝置)。
        guard !muted.withLock({ $0 }) else { return }
        guard !selfHealSuspended.withLock({ $0 }) else { return }   // G1
        // 1) 偽通知:引擎沒停、格式沒變 ⇒ 不拆(格式要在拆引擎之前讀)
        let nowKey = currentFormatKey()
        if MicRebuildPolicy.isSpurious(engineRunning: engine.isRunning, currentKey: nowKey, tapKey: tapFormatKey) {
            os_log("MyParrot mic: 忽略 configurationChange(引擎仍在跑、格式 %{public}@ 未變)", nowKey)
            return
        }
        // 2) 震盪鎖。F2:走在 AUD-37 的 1 秒重試路徑上(rebuildAttempts > 0)不判鎖,直接重建。
        let now = Date()
        if rebuildAttempts == 0,
           MicRebuildPolicy.shouldLock(history: configRebuilds, now: now, key: nowKey, isBluetooth: isBluetooth) {
            locked = true
            os_log("MyParrot mic: 震盪鎖啟動(20 秒內第 3 次、格式 %{public}@)", nowKey)
            removeTapQuietly()
            engine.stop()
            holder?.stop()
            holder = nil
            let onLocked = self.onLocked
            DispatchQueue.main.async { onLocked?() }
            return
        }
        // 3) 重建(保持器不動,繼續撐 HFP)
        removeTapQuietly()
        engine.stop()
        do {
            try buildAndStart()
            rebuildAttempts = 0
            // F2:只記「成功完成」的裝置變更重建,且格式鍵要讀得到、取樣率與聲道 >0;失敗的重試不算進震盪鎖。
            configRebuilds = MicRebuildPolicy.prune(configRebuilds, now: now)
            if MicRebuildPolicy.isRecordable(key: nowKey) { configRebuilds.append((at: now, key: nowKey)) }
        } catch {
            rebuildAttempts += 1
            os_log("MyParrot mic: 裝置變更後重建失敗(第 %ld 次):%{public}@", rebuildAttempts, "\(error)")
            if rebuildAttempts < Self.maxRebuildAttempts {
                rebuildAfterConfigurationChange(after: 1.0)
            } else {
                rebuildAttempts = 0
            }
        }
    }

    // MARK: - 計時

    private static func ms(since t: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- t.uptimeNanoseconds) / 1_000_000)
    }

    /// 分步計時:每次 `lap()` 回傳距上一次(或建立時)的毫秒數。
    private struct StepClock {
        private var last = DispatchTime.now()
        mutating func lap() -> Int {
            let now = DispatchTime.now()
            defer { last = now }
            return Int((now.uptimeNanoseconds &- last.uptimeNanoseconds) / 1_000_000)
        }
    }
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
