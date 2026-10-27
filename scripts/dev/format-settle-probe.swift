// 輸入格式跟上探針(AUD-41／BUG-37／#2548 前置;2026-10-23 21:4x)。
// 問題:內建麥錄音中 AirPods 戴回 ⇒ 系統預設輸入換成 AirPods(HFP)⇒ 釘在內建麥的 AVAudioEngine 自停、自癒重建時
//       `inputNode` 重新實例化 AUHAL 先綁**系統預設輸入**(AirPods),我們再釘回內建,但緊接著 `outputFormat(forBus:0)`
//       讀到的仍是 24000/1 ⇒ tap 以 24000 裝上 ⇒ `engine.start` -10868 ⇒ AUD-37 1 s 重試才成功,你軌空檔 8.5 s(真機 R3 16:41)。
// 要量的(決定修法 A 還是 B):
//   A. 釘裝置之後,AU 的客端格式(`inputNode.outputFormat`)要多久才跟上目標裝置的 nominal rate?會不會自己跟上?
//      同時看 `inputNode.inputFormat`(硬體側)與 AUHAL `kAudioUnitProperty_StreamFormat`(output／input scope bus 1)三者誰先變。
//   B. 不等,直接用目標裝置的格式 `installTap(format: 顯式)` 再 start,成不成?(AUD-37 ② 當初為避開「與硬體不符」斷言才改 nil;
//      若這一步斷言,探針會在最後一段崩掉——崩掉本身就是答案,前面的 log 已落檔。)
// 編譯:DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O scripts/dev/format-settle-probe.swift -o /tmp/format-settle-probe
// 執行(Terminal;**AirPods 已連上且系統預設輸入＝AirPods**;MyParrot 沒在錄音):/tmp/format-settle-probe
//   --list            只列裝置、不開任何 IO(不需要麥克風權限)
//   --device <片段>   要釘的目標裝置(名稱包含該片段);預設=內建麥(transport bltn 且有輸入)
//   --seconds N       釘裝置後輪詢格式的秒數(預設 3)
//   --skip-explicit   跳過最後的顯式格式試裝(B)
// 對照組(沒有 AirPods 時也能跑):預設輸入＝內建 ⇒ 三個格式一開始就等於 nominal,formatWait 應為 0。
// 只讀不寫:tap 只計數,不留任何音訊;輸出是 stdout 與 /tmp/format-settle-probe-<時間>.log 副本。
import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

// MARK: - 輸出
let t0 = Date()
let stamp: String = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: t0) }()
let logPath = "/tmp/format-settle-probe-\(stamp).log"
FileManager.default.createFile(atPath: logPath, contents: nil)
let logHandle = FileHandle(forWritingAtPath: logPath)
func log(_ s: String) {
    let line = String(format: "[%6.2fs] ", Date().timeIntervalSince(t0)) + s
    print(line); fflush(stdout)
    if let d = (line + "\n").data(using: .utf8) { logHandle?.write(d) }
}
func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

// MARK: - HAL helpers(照 bt-hfp-probe)
func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func readU32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var a = addr(sel, scope); var v: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
}
func readF64(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Double? {
    var a = addr(sel); var v: Float64 = 0; var size = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
}
func readString(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel); var value: Unmanaged<CFString>? = nil; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    guard st == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
}
func allDevices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}
func inputChannels(_ id: AudioObjectID) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8); defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    let list = raw.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
}
func fourcc(_ v: UInt32) -> String {
    let b = [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    return String(bytes: b, encoding: .macOSRoman) ?? "????"
}
func name(_ id: AudioObjectID) -> String { readString(id, kAudioObjectPropertyName) ?? "?" }
func nominal(_ id: AudioObjectID) -> Double { readF64(id, kAudioDevicePropertyNominalSampleRate) ?? 0 }
func defaultInput() -> AudioObjectID { readU32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) ?? 0 }
func describe(_ id: AudioObjectID) -> String {
    "\(name(id)) id=\(id) transport=\(fourcc(readU32(id, kAudioDevicePropertyTransportType) ?? 0)) in=\(inputChannels(id))ch nominal=\(Int(nominal(id)))"
}

// MARK: - AUHAL 格式三視角
func auFormat(_ au: AudioUnit, scope: AudioUnitScope) -> String {
    var asbd = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let st = AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, scope, 1, &asbd, &size)
    return st == noErr ? "\(Int(asbd.mSampleRate))/\(asbd.mChannelsPerFrame)" : "err\(st)"
}
func auDevice(_ au: AudioUnit) -> AudioDeviceID {
    var dev: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    return AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, &size) == noErr ? dev : 0
}
func fmt(_ f: AVAudioFormat) -> String { "\(Int(f.sampleRate))/\(f.channelCount)" }
struct Snap: Equatable { var out: String; var inp: String; var auOut: String; var auIn: String }
func snap(_ input: AVAudioInputNode) -> Snap {
    let au = input.audioUnit
    return Snap(out: fmt(input.outputFormat(forBus: 0)), inp: fmt(input.inputFormat(forBus: 0)),
                auOut: au.map { auFormat($0, scope: kAudioUnitScope_Output) } ?? "nil",
                auIn: au.map { auFormat($0, scope: kAudioUnitScope_Input) } ?? "nil")
}
func show(_ s: Snap) -> String { "outputFormat=\(s.out) inputFormat=\(s.inp) AU.out=\(s.auOut) AU.in=\(s.auIn)" }

// MARK: - 參數
let args = CommandLine.arguments
func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let listOnly = args.contains("--list")
let devicePart = opt("--device")
let pollSeconds = Double(opt("--seconds") ?? "3") ?? 3
let skipExplicit = args.contains("--skip-explicit")

log("format-settle-probe 開始;log 副本 \(logPath)")
let devices = allDevices().filter { inputChannels($0) > 0 }
for d in devices { log("  輸入裝置:\(describe(d))") }
let defIn = defaultInput()
log("系統預設輸入:\(defIn == 0 ? "無" : describe(defIn))")
if listOnly { exit(0) }

guard let target: AudioObjectID = {
    if let part = devicePart { return devices.first { name($0).localizedCaseInsensitiveContains(part) } }
    return devices.first { readU32($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn }
}() else { log("找不到目標裝置"); exit(1) }
let targetRate = nominal(target)
log("目標裝置(要釘的):\(describe(target))")
log(defIn == target ? "⚠️ 預設輸入＝目標裝置,這是對照組(formatWait 應為 0);要重現 BUG-37 請讓系統預設輸入＝AirPods" : "預設輸入≠目標裝置 ⇒ 重現 BUG-37 情境")

// MARK: - A. 釘裝置後格式多久跟上
let engine = AVAudioEngine()
var t = Date()
let input = engine.inputNode
log("engine.inputNode \(ms(t)) ms;AUHAL 綁的裝置 id=\(auDevice(input.audioUnit!))(\(name(auDevice(input.audioUnit!))))")
log("釘裝置前:\(show(snap(input)))")
t = Date()
var dev = target
let setStatus = AudioUnitSetProperty(input.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
log("setDevice status=\(setStatus) \(ms(t)) ms;AUHAL 現在綁 id=\(auDevice(input.audioUnit!))")
let pinnedAt = Date()
var last = snap(input)
log("釘裝置後立刻:\(show(last))  目標 nominal=\(Int(targetRate))")
var matchedAt: Int? = (Double(last.out.split(separator: "/").first ?? "0") == targetRate) ? 0 : nil
while Date().timeIntervalSince(pinnedAt) < pollSeconds {
    Thread.sleep(forTimeInterval: 0.1)
    let s = snap(input)
    if s != last {
        log("  變化 @\(ms(pinnedAt)) ms:\(show(s))")
        last = s
    }
    if matchedAt == nil, Double(s.out.split(separator: "/").first ?? "0") == targetRate {
        matchedAt = ms(pinnedAt)
        log("  ✅ outputFormat 跟上目標 nominal @\(matchedAt!) ms")
    }
}
if let m = matchedAt { log("A 結論:釘裝置後 outputFormat 在 \(m) ms 跟上(\(m == 0 ? "一開始就對" : "輪詢等得到"))") }
else { log("A 結論:等了 \(Int(pollSeconds * 1000)) ms outputFormat 仍是 \(last.out),沒跟上 ⇒ 修法 A(等格式)不成立") }

// MARK: - A2. 用「此刻格式」裝 tap 並 start(＝現行 MicCapture 做法)
var buffers = 0; var firstRate = 0.0
input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, _ in
    buffers += 1; if firstRate == 0 { firstRate = buf.format.sampleRate }
}
engine.prepare()
log("prepare 後:\(show(snap(input)))")
t = Date()
do {
    try engine.start()
    log("engine.start ✅ \(ms(t)) ms")
    Thread.sleep(forTimeInterval: 2)
    log("2 秒收到 buffers=\(buffers) 首 buffer rate=\(Int(firstRate))")
} catch {
    log("engine.start ❌ \(ms(t)) ms:\(error)")
}
input.removeTap(onBus: 0)
engine.stop()

// MARK: - B. 顯式格式裝 tap(可能斷言崩掉;崩掉＝B 不可行,前面 log 已落檔)
if !skipExplicit, let explicit = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1) {
    log("B:新引擎、釘裝置、不等,直接 installTap(format: \(fmt(explicit)))——若下一行之後沒有輸出就是 NSException 崩了")
    let e2 = AVAudioEngine()
    let in2 = e2.inputNode
    var dev2 = target
    _ = AudioUnitSetProperty(in2.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev2, UInt32(MemoryLayout<AudioDeviceID>.size))
    log("B 釘裝置後立刻:\(show(snap(in2)))")
    var b2 = 0
    in2.installTap(onBus: 0, bufferSize: 4096, format: explicit) { _, _ in b2 += 1 }
    log("B installTap 沒斷言 ✅;prepare 後:\(show(snap(in2)))")
    e2.prepare()
    t = Date()
    do {
        try e2.start()
        log("B engine.start ✅ \(ms(t)) ms")
        Thread.sleep(forTimeInterval: 2)
        log("B 2 秒 buffers=\(b2)")
    } catch { log("B engine.start ❌ \(ms(t)) ms:\(error)") }
    in2.removeTap(onBus: 0); e2.stop()
}
log("結束")
