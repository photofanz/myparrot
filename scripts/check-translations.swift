#!/usr/bin/env swift
// Build-time guard for BUG-08: every 繁中 key passed to L("…") / Lf("…", …) must have an entry
// in Localizer.table, otherwise non-繁中 users see the untranslated 繁中 string.
// Scans Sources/MyParrot for L(...) literal keys and diffs against the table.
// Dynamic calls like L(stateLabel) can't be checked statically and are skipped.
// Exit 1 (and list the gaps) if any literal key is missing a translation.
import Foundation

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/MyParrot"
let fm = FileManager.default

func hasHan(_ s: String) -> Bool {
    s.unicodeScalars.contains {
        (0x4E00...0x9FFF).contains($0.value) || (0x3000...0x303F).contains($0.value)
    }
}

// All string literals that are arguments to an L( … ) call, honoring quote state
// and paren depth (keys themselves contain ASCII parens, so we can't naively
// balance on every '(' / ')').
func usedKeys(in src: String) -> Set<String> {
    var keys = Set<String>()
    let c = Array(src)
    var i = 0
    while i < c.count {
        // `L(` 與 `Lf(`(帶 %@ 參數的版本;#2438 M6 補:之前只認 `L(`,`Lf("…")` 的 key 缺翻譯不會被抓到——
        // 正控:把 Lf 用的「每 %@ 分鐘更新一次」從翻譯表拿掉,舊版仍回綠)。
        let open = (c[i] == "L" && i + 1 < c.count && c[i+1] == "(") ? 2
            : (c[i] == "L" && i + 2 < c.count && c[i+1] == "f" && c[i+2] == "(") ? 3 : 0
        if open > 0 {
            let prev: Character = i > 0 ? c[i-1] : " "
            if prev.isLetter || prev.isNumber || prev == "_" || prev == "." { i += 1; continue }
            var j = i + open, depth = 1, inStr = false, esc = false, cur = ""
            while j < c.count, depth > 0 {
                let ch = c[j]
                if inStr {
                    if esc { cur.append(ch); esc = false }
                    else if ch == "\\" { cur.append(ch); esc = true }
                    else if ch == "\"" { if hasHan(cur) { keys.insert(cur) }; inStr = false }
                    else { cur.append(ch) }
                } else if ch == "\"" { inStr = true; cur = "" }
                else if ch == "(" { depth += 1 }
                else if ch == ")" { depth -= 1 }
                j += 1
            }
            i = j; continue
        }
        i += 1
    }
    return keys
}

// Dict keys in Localizer.table: lines shaped like  "KEY": [   (first quoted string
// followed by a colon).
// #2438(2026-10-19):回有序清單(含重複)——字典字面值重複鍵在 Swift 是**執行期 trap**(整個 app 一啟動就崩),
// build 只給 warning 很容易漏看,所以這裡當閘;`tableKeys` 仍回 Set 給既有比對用。
func tableKeyList(in src: String) -> [String] {
    var keys: [String] = []
    for raw in src.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = Array(raw.drop(while: { $0 == " " }))
        guard line.first == "\"" else { continue }
        var k = "", idx = 1, esc = false, closed = false
        while idx < line.count {
            let ch = line[idx]
            if esc { k.append(ch); esc = false }
            else if ch == "\\" { esc = true }
            else if ch == "\"" { closed = true; idx += 1; break }
            else { k.append(ch) }
            idx += 1
        }
        guard closed else { continue }
        let rest = String(line[idx...]).drop(while: { $0 == " " })
        if rest.first == ":" { keys.append(k) }
    }
    return keys
}
func tableKeys(in src: String) -> Set<String> { Set(tableKeyList(in: src)) }

func swiftFiles(_ dir: String) -> [String] {
    guard let en = fm.enumerator(atPath: dir) else { return [] }
    return en.compactMap { ($0 as? String).map { "\(dir)/\($0)" } }.filter { $0.hasSuffix(".swift") }
}

var used = Set<String>()
for f in swiftFiles(root) {
    if let s = try? String(contentsOfFile: f, encoding: .utf8) { used.formUnion(usedKeys(in: s)) }
}
let locPath = "\(root)/Localization.swift"
let table = (try? String(contentsOfFile: locPath, encoding: .utf8)).map(tableKeys) ?? []


// ── BUG-28(#1680):Core 裡的動態 key ──────────────────────────────────────────
// 警示橫幅的模板與設定頁的 Core 標籤是 `L(w.template)` 這種動態呼叫,上面那支
// 只認 `L("字面")` 的掃描器看不到。約定改成:Core 檔用 `l10n-keys:begin/end`
// 圈起「會被 L() 查表的繁中字面值」,這裡一併收進來要求有翻譯。
// 🔴 標記不見 / 區段空的一律 exit 1——否則刪掉標記就會變成「沒東西要查」的假綠燈。
let markedCoreFiles = [
    "Sources/MyParrotCore/RecordingWarning.swift",
    "Sources/MyParrotCore/TranscriptionLanguage.swift",
    "Sources/MyParrotCore/Transcription/TranscriptionProvider.swift",
    "Sources/MyParrotCore/Transcription/WhisperModelStore.swift",
    "Sources/MyParrotCore/Correction/CorrectionProvider.swift",
    "Sources/MyParrotCore/Models/ModelBackendRegistry.swift",   // #2438 M6:後端顯示名(設定頁「模型」區段 L(b.label))
]

/// 一行裡所有的字串字面值(照引號狀態與跳脫處理)。
func literals(in line: String) -> [String] {
    var out: [String] = [], cur = ""
    var inStr = false, esc = false
    for ch in line {
        if inStr {
            if esc { cur.append(ch); esc = false }
            else if ch == "\\" { cur.append(ch); esc = true }
            else if ch == "\"" { out.append(cur); inStr = false }
            else { cur.append(ch) }
        } else if ch == "\"" { inStr = true; cur = "" }
    }
    return out
}

/// 標記區段內的繁中字面值;回傳 (key 集合, 區段數)。
func markedKeys(in src: String) -> (keys: Set<String>, regions: Int) {
    var keys = Set<String>(), regions = 0, inside = false
    for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.contains("l10n-keys:begin") { inside = true; regions += 1; continue }
        if line.contains("l10n-keys:end") { inside = false; continue }
        if inside { for l in literals(in: String(line)) where hasHan(l) { keys.insert(l) } }
    }
    return (keys, regions)
}

// root 形如 "Sources/MyParrot" → 推回 repo 根目錄,讓 Core 路徑相對正確。
let repoRoot = root.hasSuffix("Sources/MyParrot")
    ? String(root.dropLast("Sources/MyParrot".count)) : "./"
var markedProblems: [String] = []
for rel in markedCoreFiles {
    let path = repoRoot + rel
    guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
        markedProblems.append("讀不到 \(rel)(路徑變了?標記檔清單要同步更新)"); continue
    }
    let (keys, regions) = markedKeys(in: src)
    if regions == 0 { markedProblems.append("\(rel) 找不到 l10n-keys 標記區段") }
    else if keys.isEmpty { markedProblems.append("\(rel) 的標記區段裡沒有繁中字串") }
    used.formUnion(keys)
}

// 含 %@ 的 key:每個語言的譯文佔位符數量必須一致,否則畫面會漏字或多出 "%@"。
func placeholderProblems(in src: String) -> [String] {
    var problems: [String] = []
    var currentKey: String?
    var keyCount = 0
    var inTable = false          // 只掃翻譯表本體,別掃到註解或其他程式碼
    for raw in src.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        let trimmed = line.drop(while: { $0 == " " })
        if line.contains("private static let table") { inTable = true; continue }
        guard inTable else { continue }
        if trimmed == "]" { inTable = false; currentKey = nil; continue }
        let lits = literals(in: line)
        if trimmed.hasPrefix("//") { continue }
        defer { if trimmed.hasSuffix("],") { currentKey = nil } }   // 一筆結束
        // key 行:第一個字面值後面接冒號
        if trimmed.first == "\"", let first = lits.first,
           let afterKey = line.range(of: "\"\(first)\"").map({ line[$0.upperBound...] }),
           afterKey.drop(while: { $0 == " " }).first == ":" {
            currentKey = first
            keyCount = first.components(separatedBy: "%@").count - 1
            for v in lits.dropFirst() where v.components(separatedBy: "%@").count - 1 != keyCount {
                problems.append("\(first.prefix(14))… 的譯文佔位符數不符")
            }
            continue
        }
        if let key = currentKey, keyCount >= 0 {
            for v in lits where v.components(separatedBy: "%@").count - 1 != keyCount {
                problems.append("\(key.prefix(14))… 的譯文佔位符數不符(\(v.prefix(10))…)")
            }
        }
    }
    return problems
}
let phProblems = (try? String(contentsOfFile: locPath, encoding: .utf8)).map(placeholderProblems) ?? []
let tableList = (try? String(contentsOfFile: locPath, encoding: .utf8)).map(tableKeyList) ?? []
let duplicateKeys = Dictionary(tableList.map { ($0, 1) }, uniquingKeysWith: +).filter { $0.value > 1 }.keys.sorted()

let missing = used.subtracting(table).sorted()
print("🌐 翻譯表完整性檢查")
print("   L() 使用的字面 key:\(used.count) · 翻譯表 key:\(table.count)")
if missing.isEmpty && markedProblems.isEmpty && phProblems.isEmpty && duplicateKeys.isEmpty {
    print("✅ 所有 key 都有翻譯(英/日/韓/簡中),無重複 key,Core 標記區段與 %@ 佔位符數量一致")
    exit(0)
}
if !missing.isEmpty {
    print("❌ 以下 key 缺翻譯(非繁中語系會顯示原繁中字串):")
    for k in missing { print("   · \(k)") }
}
if !markedProblems.isEmpty {
    print("❌ Core 的 l10n-keys 標記有問題(動態 key 會變成沒人檢查):")
    for m in markedProblems { print("   · \(m)") }
}
if !phProblems.isEmpty {
    print("❌ 譯文的 %@ 佔位符數量與繁中 key 不一致(畫面會漏字或出現 %@):")
    for m in Set(phProblems).sorted() { print("   · \(m)") }
}
if !duplicateKeys.isEmpty {
    print("❌ 翻譯表有重複的 key(Swift 字典字面值重複鍵 ⇒ app 一啟動就 trap;刪到只剩一筆):")
    for k in duplicateKeys { print("   · \(k)") }
}
exit(1)
