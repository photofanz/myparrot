// 藍牙 HFP 保持探針(#2529 方案 2 前置 PoC;Eric 2026-10-23 08:52「A2 先做探針 poc 驗證,我們再決定」)。
// 問題:AVAudioEngine 對藍牙麥裝 tap 時讀到 A2DP 當下的 48 kHz,HFP 接上後硬體變 24 kHz,引擎報 formats don't match 自停;
//       我們重建時 HFP 已掉回 A2DP 又讀到 48 kHz ⇒ 每 3～4 秒無限重建(10/22 22:45 真機 log)。
// 假設(本探針要驗的):一條裸的 HAL 輸入 IOProc 跑著就能讓 HFP 維持;在它保持下啟動引擎會讀到 HFP 格式、不再觸發
//       AVAudioEngineConfigurationChange;引擎停掉後只要 IOProc 還跑,HFP 不掉。
// 編譯:DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O scripts/dev/bt-hfp-probe.swift -o /tmp/bt-hfp-probe
// 執行(Terminal;AirPods 已連上;MyParrot 沒在錄音、麥克風沒選 AirPods):/tmp/bt-hfp-probe
//   --list            只列裝置、不開任何 IO(不需要麥克風權限)
//   --device <片段>   指定目標裝置(名稱包含該片段);預設=第一顆有輸入的藍牙裝置
//   --no-control      跳過內建麥對照組
//   --seconds N       引擎觀察秒數(預設 10)
// 只讀不寫:IOProc 與 tap 只計數與量電平(RMS/峰值/非零比例),不留任何音訊;輸出是 stdout 與 /tmp/bt-hfp-probe-<時間>.log 副本,
//           以及播放用的 3 秒 440 Hz 音檔 /tmp/bt-hfp-probe-tone.caf。
// v3(2026-10-23 10:3x,Eric C2):第二輪(剛連上、48000 起始)保持器與引擎都沒觸發 HFP,但不知道收到的 48 kHz 是不是真聲音;
//   v3 量電平、加「邊播聲音邊收」情境(P 引擎單跑＋播放、PH 保持器＋引擎＋播放),有觸發過 HFP 就再跑一輪殘留狀態的 H 看分步耗時。
//   --skip-play 跳過播放情境。
// v4(2026-10-23 11:2x,Eric 回饋「中間有來不及說話」):預設流程改成三段都「建好引擎 → 等你按 Enter → 才開始收」:
//   S 內建麥說話對照(6 秒) → H 保持器＋引擎說話(10 秒) → PH 保持器＋引擎＋第 3 秒播 3 秒聲音(10 秒)。--full 跑 v3 的完整流程。
import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

// MARK: - 輸出
let t0 = Date()
let stamp: String = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: t0) }()
let logPath = "/tmp/bt-hfp-probe-\(stamp).log"
FileManager.default.createFile(atPath: logPath, contents: nil)
let logHandle = FileHandle(forWritingAtPath: logPath)
func log(_ s: String) {
    let line = String(format: "[%6.2fs] ", Date().timeIntervalSince(t0)) + s
    print(line); fflush(stdout)
    if let d = (line + "\n").data(using: .utf8) { logHandle?.write(d) }
}
func ms(_ since: Date) -> Double { Date().timeIntervalSince(since) * 1000 }

// MARK: - HAL helpers
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
func streams(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioStreamID] {
    var a = addr(kAudioDevicePropertyStreams, scope); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}
func streamFormat(_ s: AudioStreamID, physical: Bool) -> AudioStreamBasicDescription? {
    var a = addr(physical ? kAudioStreamPropertyPhysicalFormat : kAudioStreamPropertyVirtualFormat)
    var asbd = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    return AudioObjectGetPropertyData(s, &a, 0, nil, &size, &asbd) == noErr ? asbd : nil
}
func fourcc(_ v: UInt32) -> String {
    let b = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
    return String(bytes: b, encoding: .macOSRoman) ?? "????"
}
func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioObjectID { readU32(AudioObjectID(kAudioObjectSystemObject), sel) ?? 0 }
func name(_ id: AudioObjectID) -> String { readString(id, kAudioObjectPropertyName) ?? "?" }
func transport(_ id: AudioObjectID) -> UInt32 { readU32(id, kAudioDevicePropertyTransportType) ?? 0 }
func isBluetooth(_ id: AudioObjectID) -> Bool { let t = transport(id); return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE }
func isBuiltIn(_ id: AudioObjectID) -> Bool { transport(id) == kAudioDeviceTransportTypeBuiltIn }

// MARK: - 狀態快照(目標裝置輸入格式 + 預設輸出裝置取樣率)
struct Snap: Equatable {
    var inRate: Int; var inCh: Int; var inPhysRate: Int; var nominal: Int; var outName: String; var outRate: Int
    var text: String { "in \(inRate) Hz/\(inCh) ch (phys \(inPhysRate)) nominal \(nominal) | default-out 「\(outName)」 \(outRate) Hz" }
}
func snap(_ dev: AudioObjectID) -> Snap {
    let s = streams(dev, kAudioDevicePropertyScopeInput).first
    let v = s.flatMap { streamFormat($0, physical: false) }
    let p = s.flatMap { streamFormat($0, physical: true) }
    let out = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    return Snap(inRate: Int(v?.mSampleRate ?? 0), inCh: Int(v?.mChannelsPerFrame ?? 0), inPhysRate: Int(p?.mSampleRate ?? 0),
                nominal: Int(readF64(dev, kAudioDevicePropertyNominalSampleRate) ?? 0),
                outName: name(out), outRate: Int(readF64(out, kAudioDevicePropertyNominalSampleRate) ?? 0))
}
/// 每 0.2 秒取一次快照,變化才印;`until` 給了就在條件成立時提早結束(回傳成立時間)。
@discardableResult
func observe(_ dev: AudioObjectID, seconds: Double, label: String, until: ((Snap) -> Bool)? = nil, onTick: ((Double) -> Void)? = nil) -> (last: Snap, changes: Int, hitAt: Double?) {
    let start = Date(); var last = snap(dev); var changes = 0; var hitAt: Double? = nil
    log("\(label):\(last.text)")
    if let until, until(last) { return (last, 0, 0) }
    while Date().timeIntervalSince(start) < seconds {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        onTick?(Date().timeIntervalSince(start))
        let s = snap(dev)
        if s != last { changes += 1; last = s; log("  變化 → \(s.text)") }
        if let until, until(s) { hitAt = Date().timeIntervalSince(start); break }
    }
    return (last, changes, hitAt)
}


// MARK: - 電平計(只算數字,不存樣本)
final class LevelMeter {
    private let lock = NSLock(); private let start = Date()
    private var sumSq = 0.0, frames = 0, nonzero = 0, buffers = 0, loud = 0; private var peak: Float = 0
    private var perSecond: [Int: Float] = [:]
    func add(_ p: UnsafePointer<Float>, _ n: Int) {
        guard n > 0 else { return }
        var ss = 0.0; var pk: Float = 0; var nz = 0
        for i in 0..<n { let v = p[i]; ss += Double(v * v); let a = abs(v); if a > pk { pk = a }; if v != 0 { nz += 1 } }
        let rms = Float((ss / Double(n)).squareRoot()); let sec = Int(Date().timeIntervalSince(start))
        lock.lock(); sumSq += ss; frames += n; nonzero += nz; buffers += 1; if pk > peak { peak = pk }
        if rms > 0.00316 { loud += 1 }   // > -50 dBFS
        perSecond[sec] = max(perSecond[sec] ?? 0, rms); lock.unlock()
    }
    func add(_ abl: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        for b in list { guard let d = b.mData else { continue }; add(d.assumingMemoryBound(to: Float.self), Int(b.mDataByteSize) / 4) }
    }
    func add(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        for c in 0..<Int(buf.format.channelCount) { add(ch[c], Int(buf.frameLength)) }
    }
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        guard frames > 0 else { return "沒有樣本" }
        let rmsDb = 10 * log10(max(sumSq / Double(frames), 1e-12)); let peakDb = 20 * log10(max(Double(peak), 1e-6))
        let tl = perSecond.keys.sorted().map { k -> String in let v = perSecond[k]!; return v > 0 ? String(format: "%.0f", 20 * log10(Double(v))) : "-inf" }.joined(separator: " ")
        return String(format: "buffers %d、樣本 %d、非零 %.1f%%、整體 RMS %.1f dBFS、峰值 %.1f dBFS、>-50 dBFS 的 buffer %.0f%%;每秒最大 RMS(dBFS):%@",
                      buffers, frames, Double(nonzero) / Double(frames) * 100, rmsDb, peakDb, Double(loud) / Double(buffers) * 100, tl)
    }
    var loudRatio: Double { lock.lock(); defer { lock.unlock() }; return buffers > 0 ? Double(loud) / Double(buffers) : 0 }
}

// MARK: - 播放:3 秒 440 Hz 正弦波,走預設輸出(AirPods),用 afplay 另開行程
func makeTone() -> URL? {
    let url = URL(fileURLWithPath: "/tmp/bt-hfp-probe-tone.caf")
    guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else { return nil }
    let n = AVAudioFrameCount(48000 * 3)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n), let p = buf.floatChannelData?[0] else { return nil }
    buf.frameLength = n
    for i in 0..<Int(n) { p[i] = 0.25 * sinf(2 * .pi * 440 * Float(i) / 48000) }
    do { let f = try AVAudioFile(forWriting: url, settings: fmt.settings); try f.write(from: buf) } catch { log("音檔產生失敗:\(error)"); return nil }
    return url
}
@discardableResult
func playTone(_ url: URL) -> Process? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); p.arguments = [url.path]
    do { try p.run(); return p } catch { log("afplay 失敗:\(error)"); return nil }
}

// MARK: - 保持器:裸的 HAL 輸入 IOProc,只計數與量電平
final class Holder {
    let dev: AudioObjectID; private var proc: AudioDeviceIOProcID?
    private let lock = NSLock(); private var _count = 0
    let meter = LevelMeter(); private let isFloat: Bool
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    init(_ d: AudioObjectID) {
        dev = d
        let f = streams(d, kAudioDevicePropertyScopeInput).first.flatMap { streamFormat($0, physical: false) }
        isFloat = f.map { ($0.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && $0.mBitsPerChannel == 32 } ?? false
    }
    func start() -> (status: OSStatus, blockMs: Double) {
        let q = DispatchQueue(label: "bt-hfp-probe.holder")
        var st = AudioDeviceCreateIOProcIDWithBlock(&proc, dev, q) { [self] _, inData, _, _, _ in
            self.lock.lock(); self._count += 1; self.lock.unlock()
            if self.isFloat { self.meter.add(inData) }
        }
        guard st == noErr, let proc else { return (st, 0) }
        let t = Date(); st = AudioDeviceStart(dev, proc); return (st, ms(t))
    }
    func stop() { if let proc { AudioDeviceStop(dev, proc); AudioDeviceDestroyIOProcID(dev, proc) }; proc = nil }
}

// MARK: - 引擎探針:照 MicCapture.buildAndStart 的順序(釘裝置 → 讀格式 → tap(format: nil) → start)
final class EngineProbe {
    let engine = AVAudioEngine(); private let lock = NSLock(); private var _buffers = 0; private var _firstRate: Double = 0
    let meter = LevelMeter()
    private(set) var configChanges = 0; private var observer: NSObjectProtocol?; private var tapInstalled = false
    var buffers: Int { lock.lock(); defer { lock.unlock() }; return _buffers }
    var firstBufferRate: Double { lock.lock(); defer { lock.unlock() }; return _firstRate }
    /// v2(2026-10-23 10:1x):分步計時。v1 真機發現保持器穩定到「引擎讀到格式」之間有 6.2 秒空檔而 engine.start 只 1 ms,
    /// 卡的是 AUHAL 實例化／釘裝置／prepare 之一,這裡逐步量出來。
    private var steps: [String] = []; private var t = Date()
    private func mark(_ n: String) { steps.append("\(n) \(Int(ms(t))) ms"); t = Date() }
    /// v4:建引擎(inputNode／釘裝置／讀格式／tap／prepare)與 start 分開,中間可以等人按 Enter。
    func build(dev: AudioObjectID) -> (format: String, error: String?) {
        t = Date(); steps = []
        let input = engine.inputNode; mark("inputNode")
        if let au = input.audioUnit {
            var d = dev
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        mark("setDevice")
        let f = input.outputFormat(forBus: 0); mark("outputFormat")
        let desc = "\(Int(f.sampleRate)) Hz/\(f.channelCount) ch"
        guard f.sampleRate > 0, f.channelCount > 0 else {
            log("  步驟耗時:" + steps.joined(separator: "、"))
            return (desc, "inputNode 格式 0 ch/0 Hz,跳過 installTap(會 NSException)")
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.configChanges += 1
            log("  ⚡ AVAudioEngineConfigurationChange 第 \(self.configChanges) 次(engine.isRunning=\(self.engine.isRunning),inputNode 現在 \(Int(self.engine.inputNode.outputFormat(forBus: 0).sampleRate)) Hz)")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
            guard let self else { return }
            self.lock.lock(); self._buffers += 1; if self._firstRate == 0 { self._firstRate = buf.format.sampleRate }; self.lock.unlock()
            self.meter.add(buf)
        }
        tapInstalled = true; mark("installTap")
        engine.prepare(); mark("prepare")
        log("  建引擎步驟耗時:" + steps.joined(separator: "、"))
        return (desc, nil)
    }
    func run() -> (startMs: Double, error: String?) {
        let ts = Date()
        do { try engine.start() } catch { return (ms(ts), "engine.start 失敗:\(error)") }
        return (ms(ts), nil)
    }
    func start(dev: AudioObjectID) -> (format: String, startMs: Double, error: String?) {
        let b = build(dev: dev)
        if let e = b.error { return (b.format, 0, e) }
        let r = run(); return (b.format, r.startMs, r.error)
    }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
    }
}

// MARK: - 情境
struct Outcome {
    var label = ""; var bt = false; var withHolder = false
    var baseline: Snap? = nil
    var holderStatus: OSStatus = 0; var holderBlockMs = 0.0; var hfpAt: Double? = nil; var holderSnap: Snap? = nil; var holderCallbacks = 0
    var engineFormat = ""; var engineStartMs = 0.0; var engineError: String? = nil
    var buffers = 0; var firstBufferRate = 0.0; var configChanges = 0; var formatChangesDuringEngine = 0
    var heldAfterEngineStop: Bool? = nil; var callbacksWhileHeld = 0
    var returnedAt: Double? = nil; var returned = false
    var holderLevel = ""; var engineLevel = ""; var engineLoud = 0.0; var played = false; var playAtSec: Double? = nil
}
var cleanups: [() -> Void] = []
func runScenario(dev: AudioObjectID, label: String, withHolder: Bool, engineSeconds: Double, speak: Bool = false, playAt: Double? = nil, waitEnter: Bool = false) -> Outcome {
    var o = Outcome(); o.label = label; o.bt = isBluetooth(dev); o.withHolder = withHolder; o.playAtSec = playAt
    log("━━ \(label) ━━")
    if speak && !waitEnter { log("👉 請從現在開始對著耳機持續說話(數數就好),看到「可以停了」再停。") }
    let base = observe(dev, seconds: 1.0, label: "基線 1 秒").last
    o.baseline = base
    var holder: Holder? = nil
    if withHolder {
        let h = Holder(dev); holder = h; cleanups.append { h.stop() }
        let r = h.start(); o.holderStatus = r.status; o.holderBlockMs = r.blockMs
        log("保持器 AudioDeviceStart status=\(r.status) 阻塞 \(Int(r.blockMs)) ms")
        if r.status == noErr {
            let w = observe(dev, seconds: o.bt ? 6.0 : 2.0, label: "等 HFP(格式變化)最多 \(o.bt ? 6 : 2) 秒") { $0.inRate != base.inRate || $0.inCh != base.inCh || $0.outRate != base.outRate }
            o.hfpAt = w.hitAt; o.holderSnap = w.last
            if o.hfpAt != nil { RunLoop.main.run(until: Date().addingTimeInterval(1.0)); o.holderSnap = snap(dev); log("  穩定 1 秒後:\(o.holderSnap!.text)") }
            o.holderCallbacks = h.count; o.holderLevel = h.meter.summary
            log("  保持器回呼 \(o.holderCallbacks) 次;HFP 接上耗時 \(o.hfpAt.map { String(format: "%.1f s", $0) } ?? "未變化")")
            log("  保持器電平:\(o.holderLevel)")
        }
    }
    let tEngine = Date(); let e = EngineProbe(); cleanups.append { e.stop() }; log("AVAudioEngine() 建立 \(Int(ms(tEngine))) ms")
    let b = e.build(dev: dev)
    var r: (format: String, startMs: Double, error: String?) = (b.format, 0, b.error)
    if b.error == nil {
        if waitEnter {
            log("👉 引擎建好了。準備好要說話就按 Enter;按下後立刻開始收 \(Int(engineSeconds)) 秒,請一路出聲數數到「可以停了」。")
            _ = readLine()
            log("👉 開始!請持續說話。")
        }
        let st = e.run(); r = (b.format, st.startMs, st.error)
    }
    o.engineFormat = r.format; o.engineStartMs = r.startMs; o.engineError = r.error
    log("引擎 inputNode 讀到 \(r.format);engine.start 阻塞 \(Int(r.startMs)) ms\(r.error.map { ";錯誤:\($0)" } ?? "")")
    if r.error == nil {
        var played = false
        let w = observe(dev, seconds: engineSeconds, label: "引擎跑 \(Int(engineSeconds)) 秒", onTick: { elapsed in
            if let playAt, !played, elapsed >= playAt, let tone = toneURL { played = true; log("  ▶︎ 透過預設輸出播 3 秒 440 Hz(afplay)"); playTone(tone) }
        })
        o.formatChangesDuringEngine = w.changes; o.played = played
    }
    o.buffers = e.buffers; o.firstBufferRate = e.firstBufferRate; o.configChanges = e.configChanges
    o.engineLevel = e.meter.summary; o.engineLoud = e.meter.loudRatio
    log("  tap buffers \(o.buffers)(首 buffer \(Int(o.firstBufferRate)) Hz);configurationChange \(o.configChanges) 次;格式變化 \(o.formatChangesDuringEngine) 次")
    log("  引擎 tap 電平:\(o.engineLevel)")
    if speak { log("👉 可以停了。") }
    e.stop(); log("引擎已停")
    if let h = holder, o.holderStatus == noErr {
        let before = h.count
        let w = observe(dev, seconds: 4.0, label: "引擎停、保持器續跑 4 秒")
        o.callbacksWhileHeld = h.count - before
        if let hs = o.holderSnap { o.heldAfterEngineStop = (w.last.inRate == hs.inRate && w.last.inCh == hs.inCh) }
        log("  保持器這 4 秒回呼 +\(o.callbacksWhileHeld);格式仍是接上時的格式:\(o.heldAfterEngineStop.map { $0 ? "是" : "否" } ?? "n/a")")
        h.stop(); log("保持器已停")
    }
    let back = observe(dev, seconds: 8.0, label: "等回基線最多 8 秒") { $0.inRate == base.inRate && $0.inCh == base.inCh && $0.outRate == base.outRate }
    o.returnedAt = back.hitAt; o.returned = back.hitAt != nil
    log("  回基線:\(o.returnedAt.map { String(format: "%.1f s", $0) } ?? "8 秒內沒回")")
    return o
}

// MARK: - main
var args = Array(CommandLine.arguments.dropFirst())
var listOnly = false, noControl = false, skipPlay = false, full = false, seconds = 10.0, wanted: String? = nil
var toneURL: URL? = nil
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--list": listOnly = true
    case "--no-control": noControl = true
    case "--skip-play": skipPlay = true
    case "--full": full = true
    case "--seconds": seconds = Double(args.removeFirst()) ?? 10
    case "--device": wanted = args.removeFirst()
    default: log("未知參數 \(a)"); exit(2)
    }
}
let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigSrc.setEventHandler { log("SIGINT,清理後離開"); cleanups.forEach { $0() }; exit(130) }
sigSrc.resume()

log("bt-hfp-probe 開始;log 副本 \(logPath)")
log("預設輸入 id=\(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)) 「\(name(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)))」;預設輸出 「\(name(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)))」")
let inputs = allDevices().filter { !streams($0, kAudioDevicePropertyScopeInput).isEmpty }
log("有輸入的裝置 \(inputs.count) 顆:")
for d in inputs {
    let s = snap(d)
    log(String(format: "  id=%-4d %@ %@  in %d Hz/%d ch (phys %d) nominal %d", d, fourcc(transport(d)), name(d), s.inRate, s.inCh, s.inPhysRate, s.nominal))
}
if listOnly { exit(0) }

if !skipPlay { toneURL = makeTone(); log("播放音檔:\(toneURL?.path ?? "產生失敗,播放情境會跳過")") }
let control = inputs.first { isBuiltIn($0) }
let target: AudioObjectID? = {
    if let w = wanted { return inputs.first { name($0).localizedCaseInsensitiveContains(w) } }
    return inputs.first { isBluetooth($0) }
}()

var outcomes: [Outcome] = []
if full {
    if !noControl, let c = control {
        outcomes.append(runScenario(dev: c, label: "對照組:內建麥「\(name(c))」保持器＋引擎 3 秒(驗機制,不涉 HFP)", withHolder: true, engineSeconds: 3))
    }
    if let t = target {
        let tn = name(t)
        outcomes.append(runScenario(dev: t, label: "E 目標「\(tn)」引擎單跑 \(Int(seconds)) 秒(重現 BUG-34;量電平看 48 kHz 收到的是不是聲音)", withHolder: false, engineSeconds: seconds, speak: true))
        outcomes.append(runScenario(dev: t, label: "H 目標「\(tn)」保持器先接 HFP、再啟動引擎 \(Int(seconds)) 秒(方案 2 假設;量電平)", withHolder: true, engineSeconds: seconds, speak: true))
        if toneURL != nil {
            outcomes.append(runScenario(dev: t, label: "P 目標「\(tn)」引擎單跑 12 秒、第 3 秒播 3 秒聲音(播放會不會觸發 HFP、引擎會不會自停)", withHolder: false, engineSeconds: 12, speak: true, playAt: 3))
            outcomes.append(runScenario(dev: t, label: "PH 目標「\(tn)」保持器＋引擎 12 秒、第 3 秒播 3 秒聲音(保持器在播放下能不能撐住)", withHolder: true, engineSeconds: 12, speak: true, playAt: 3))
        }
        let hfpSeen = outcomes.contains { $0.bt && ($0.hfpAt != nil || $0.formatChangesDuringEngine > 0 || $0.configChanges > 0) }
        if hfpSeen {
            outcomes.append(runScenario(dev: t, label: "H-res 目標「\(tn)」殘留狀態再跑保持器＋引擎 8 秒(分步耗時對照)", withHolder: true, engineSeconds: 8, speak: true))
        } else {
            log("這一輪沒有任何情境看到 HFP 或格式變化,跳過 H-res。")
        }
    } else {
        log("⚠️ 找不到藍牙輸入裝置(或 --device 片段沒對到);請先連上 AirPods 再跑。只跑了對照組。")
    }
} else {
    // v4 預設:三段都等 Enter 才開始收。
    if !noControl, let c = control {
        outcomes.append(runScenario(dev: c, label: "S 內建麥「\(name(c))」引擎 6 秒(你的聲音透過正常麥克風長什麼樣,當對照電平)", withHolder: false, engineSeconds: 6, speak: true, waitEnter: true))
    }
    if let t = target {
        let tn = name(t)
        outcomes.append(runScenario(dev: t, label: "H 目標「\(tn)」保持器先接 HFP、再啟動引擎 10 秒(HFP 麥克風到底有沒有你的聲音)", withHolder: true, engineSeconds: 10, speak: true, waitEnter: true))
        if toneURL != nil {
            outcomes.append(runScenario(dev: t, label: "PH 目標「\(tn)」保持器＋引擎 10 秒、第 3 秒播 3 秒聲音(播放下你的聲音還在不在)", withHolder: true, engineSeconds: 10, speak: true, playAt: 3, waitEnter: true))
        }
    } else {
        log("⚠️ 找不到藍牙輸入裝置(或 --device 片段沒對到);請先連上 AirPods 再跑。只跑了對照組。")
    }
}

log("━━ 總結 ━━")
for o in outcomes {
    log(o.label)
    if o.withHolder { log(String(format: "  保持器:status %d、AudioDeviceStart 阻塞 %.0f ms、HFP 接上 %@、回呼 %d", o.holderStatus, o.holderBlockMs, o.hfpAt.map { String(format: "%.1f s", $0) } ?? "未變化", o.holderCallbacks)) }
    log(String(format: "  引擎:讀到 %@、start 阻塞 %.0f ms、buffers %d(首 buffer %.0f Hz)、configurationChange %d、格式變化 %d%@", o.engineFormat, o.engineStartMs, o.buffers, o.firstBufferRate, o.configChanges, o.formatChangesDuringEngine, o.engineError.map { "、錯誤:\($0)" } ?? ""))
    if let held = o.heldAfterEngineStop { log("  引擎停後保持器 4 秒仍維持格式:\(held ? "是" : "否")(回呼 +\(o.callbacksWhileHeld))") }
    if !o.holderLevel.isEmpty { log("  保持器電平:\(o.holderLevel)") }
    if !o.engineLevel.isEmpty { log("  引擎電平:\(o.engineLevel)") }
    if o.playAtSec != nil { log("  播放:\(o.played ? "有播" : "沒播");播放期間/之後格式變化 \(o.formatChangesDuringEngine) 次、configurationChange \(o.configChanges) 次") }
    log("  回基線:\(o.returnedAt.map { String(format: "%.1f s", $0) } ?? "沒回")")
}
for o in outcomes where o.bt {
    let voice = o.engineLoud >= 0.3 ? "有聲音(>-50 dBFS 的 buffer ≥30%)" : "幾乎無聲(可能是數位零或沒說話)"
    log("聲音判讀 \(o.label.prefix(2)):\(voice);buffers \(o.buffers)")
}
if let h = outcomes.last(where: { $0.bt && $0.withHolder }), let e = outcomes.last(where: { $0.bt && !$0.withHolder }) {
    let hfpRate = h.holderSnap?.inRate ?? 0
    let engineReadHFP = h.hfpAt != nil && h.engineFormat.hasPrefix("\(hfpRate) Hz")
    let h1 = h.hfpAt != nil, h2 = engineReadHFP, h3 = h.configChanges == 0 && h.buffers > 0, h4 = h.heldAfterEngineStop == true
    log("判準:E 重現(configurationChange ≥1)=\(e.configChanges >= 1 ? "是" : "否");H1 保持器接上 HFP=\(h1 ? "過" : "沒過");H2 引擎讀到 HFP 格式=\(h2 ? "過" : "沒過");H3 引擎 10 秒 0 次 configurationChange 且有 buffer=\(h3 ? "過" : "沒過");H4 引擎停後 HFP 仍維持=\(h4 ? "過" : "沒過")")
    log(h1 && h2 && h3 && h4 ? "結論:四項全過,方案 2 的保持器假設成立。" : "結論:有判準沒過,方案 2 假設不成立或需調整(看上面哪一項)。")
}
log("結束;log 副本 \(logPath)")
