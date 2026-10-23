import Foundation
import CoreAudio
import os

/// AUD-38(#2529)藍牙 HFP 保持器:對藍牙輸入裝置開一條**空回呼**的裸 HAL 輸入 IOProc,活到 `stop()`。
///
/// 探針 `scripts/dev/bt-hfp-probe.swift` 2026-10-23 真機 7/7 成立:這條 IOProc 跑著,HFP 就 0.2 秒接上並維持;
/// AVAudioEngine 在它保持下讀到正確的 HFP 格式(24000)、拿到 buffer、播放中不掉、停引擎不掉;停保持器
/// 2.3～2.5 秒回 A2DP。沒有它時,AUHAL 建立時拿到的格式 ≠ 裝置 HFP 狀態 ⇒ -10868／0 buffer／
/// formats-don't-match 自停迴圈(10/22 22:45 真機 log)。
///
/// 執行緒:只由 `MicCapture` 的 controlQueue 建立、start、stop(非 Sendable,不跨佇列共用)。
/// IOProc 本身跑在自己的 `queue`,回呼不碰任何狀態。
final class BluetoothInputHolder {
    let deviceID: AudioDeviceID
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "tw.uncle.MyParrot.bt-holder")

    init(deviceID: AudioDeviceID) { self.deviceID = deviceID }

    /// 回傳 `AudioDeviceStart` 的 OSStatus(建 IOProc 失敗就回那一步的 status);
    /// 非 0 由呼叫端決定(目前:記 log、照建引擎＝退回沒有保持器的行為)。
    func start() -> OSStatus {
        guard proc == nil else { return noErr }
        var st = AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, queue) { _, _, _, _, _ in }   // 空回呼
        guard st == noErr, let proc else { self.proc = nil; return st }
        st = AudioDeviceStart(deviceID, proc)
        if st != noErr {
            AudioDeviceDestroyIOProcID(deviceID, proc)
            self.proc = nil
        }
        return st
    }

    func stop() {
        if let proc {
            AudioDeviceStop(deviceID, proc)
            AudioDeviceDestroyIOProcID(deviceID, proc)
        }
        proc = nil
    }

    /// 擁有者(MicCapture)負責在 controlQueue 上 stop;這裡只是保險,避免漏掉時 IOProc 永遠撐住 HFP。
    deinit { stop() }

    /// 判斷 HFP 有沒有接上用的格式快照:目標裝置輸入串流的 virtual format(取樣率／聲道數)＋
    /// 預設輸出裝置的 nominal rate(真機:HFP 接上時輸出 48000→24000 或輸入 48000→24000)。
    struct FormatSnapshot: Equatable, Sendable {
        var inRate: Int
        var inCh: Int
        var outRate: Int
    }

    /// 照探針 `snap()`:`kAudioDevicePropertyStreams`(輸入 scope)→ `kAudioStreamPropertyVirtualFormat`,
    /// 不用 deprecated 的 `kAudioDevicePropertyStreamFormat`。讀不到的欄位記 0。
    static func snapshot(_ dev: AudioDeviceID) -> FormatSnapshot {
        let input = try? dev.readInputStreamID().readStreamVirtualFormat()
        let out: AudioDeviceID? = try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice,
                                                                 defaultValue: AudioDeviceID.unknown)
        let outRate = out.flatMap { $0.isValid ? (try? $0.readNominalSampleRate()) : nil } ?? 0
        return FormatSnapshot(inRate: Int(input?.mSampleRate ?? 0),
                              inCh: Int(input?.mChannelsPerFrame ?? 0),
                              outRate: Int(outRate))
    }
}

/// AUD-38(#2529)保持器的**純決策**,給 SelfTest 直接呼叫。
enum BluetoothHoldPolicy {
    /// 只有藍牙裝置才起保持器;非藍牙完全不建。
    static func shouldHold(isBluetooth: Bool) -> Bool { isBluetooth }
    /// 任一欄變了＝HFP 接上。
    static func settled(baseline: BluetoothInputHolder.FormatSnapshot, now: BluetoothInputHolder.FormatSnapshot) -> Bool {
        baseline != now
    }
    /// 等 HFP 接上的上限;沒變也照建引擎(剛連上、沒播過聲音的耳機可能根本不切)。
    /// AUD-39:3→1.5 秒(真機 R2／R3 剛連上狀態 3 秒都沒切,白等)。
    static let settleTimeout: TimeInterval = 1.5
    static let pollInterval: TimeInterval = 0.1

    /// AUD-39:baseline 已是窄頻(輸入與輸出取樣率都 <44100)＝HFP 早已接上,不必等變化。
    static func alreadyHFP(_ s: BluetoothInputHolder.FormatSnapshot) -> Bool {
        s.inRate > 0 && s.inRate < 44_100 && s.outRate > 0 && s.outRate < 44_100
    }
}
