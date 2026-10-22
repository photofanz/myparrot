import Foundation

/// #2438 Phase 3a(AFM-04/05):Apple Foundation Models 的 4,096 token 上下文預算(TN3193:指令＋輸入＋輸出一起算)。
/// 全部純函式,兩種建置都可測。估法:**CJK 1 字＝1.5 token**(10/20 真跑校準:原本 1 字＝1 低估約四成,
/// 框架實算 6,798 對上估 4,900)、其他每 4 個 UTF-16 單位＝1 token(向上取整)、換行 1。
public enum AFMBudget {
    public static let contextWindow = 4096
    public static let instructionsReserve = 350
    public static let previousMax = 700
    public static let notesMax = 400
    public static let deltaChunkMax = 1400
    public static let outputMax = 800
    public static let correctionBatchMax = 1200
    public static let correctionOutputMax = 600
    public static let summaryMaxChars = 300

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return true
        default: return false
        }
    }

    /// 估 token。
    public static func estimateTokens(_ s: String) -> Int {
        var cjk = 0, newlines = 0, otherUnits = 0
        for u in s.unicodeScalars {
            if u == "\n" { newlines += 1 }
            else if isCJK(u) { cjk += 1 }
            else { otherUnits += u.utf16.count }
        }
        return (cjk * 3 + 1) / 2 + newlines + (otherUnits + 3) / 4
    }

    /// 逐字稿增量切段:按行、不拆行;單行超過上限才按字硬切成多行再放。拼回＝原文(硬切的行除外,順序不變)。
    public static func chunk(lines: [String], max: Int = deltaChunkMax) -> [[String]] {
        var out: [[String]] = []
        var cur: [String] = []
        var curTokens = 0
        func flush() { if !cur.isEmpty { out.append(cur); cur = []; curTokens = 0 } }
        for line in lines {
            let t = estimateTokens(line) + 1
            if t > max {
                flush()
                for piece in hardSplit(line, max: max) { out.append([piece]) }
                continue
            }
            if curTokens + t > max { flush() }
            cur.append(line); curTokens += t
        }
        flush()
        return out
    }

    /// 單行按字切到每片 ≤ max token。
    static func hardSplit(_ line: String, max: Int) -> [String] {
        var pieces: [String] = []
        var piece = ""
        var tokens = 0
        for ch in line {
            let t = estimateTokens(String(ch))
            if tokens + t > max - 1, !piece.isEmpty { pieces.append(piece); piece = ""; tokens = 0 }
            piece.append(ch); tokens += t
        }
        if !piece.isEmpty { pieces.append(piece) }
        return pieces
    }

    /// 上一版記錄壓到預算內:摘要截 300 字;三個清單從最舊(開頭)丟,時間軸最後才丟;每丟一條重估。
    public static func compressPrevious(_ d: MinutesDocument, max: Int = previousMax) -> MinutesDocument {
        var doc = d
        if doc.summary.count > summaryMaxChars { doc.summary = String(doc.summary.prefix(summaryMaxChars)) }
        func size() -> Int { estimateTokens(MinutesPrompt.previousJSON(doc) ?? "") }
        var guardCount = 0
        while size() > max, guardCount < 10_000 {
            guardCount += 1
            let lists: [(Int, WritableKeyPath<MinutesDocument, [String]>)] = [
                (doc.decisions.count, \.decisions), (doc.actions.count, \.actions), (doc.questions.count, \.questions)]
            if let longest = lists.filter({ $0.0 > 0 }).max(by: { $0.0 < $1.0 }) {
                doc[keyPath: longest.1].removeFirst()
            } else if !doc.timeline.isEmpty {
                doc.timeline.removeFirst()
            } else if doc.summary.count > 50 {
                doc.summary = String(doc.summary.prefix(doc.summary.count / 2))
            } else { break }
        }
        return doc
    }

    /// 筆記取尾:第一行(標題)一定保留,其餘從尾端往上塞到預算為止。
    public static func notesTail(_ notes: String, max: Int = notesMax) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if estimateTokens(trimmed) <= max { return trimmed }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let title = lines.first else { return trimmed }
        lines.removeFirst()
        var budget = max - estimateTokens(title) - 1
        var kept: [String] = []
        for line in lines.reversed() {
            let t = estimateTokens(line) + 1
            if t > budget { break }
            kept.insert(line, at: 0); budget -= t
        }
        return ([title] + kept).joined(separator: "\n")
    }

    /// 退讓計畫:第 n 次嘗試把段切成幾份;超過 3 次 ⇒ nil。
    public static func halvePlan(attempt: Int) -> Int? {
        switch attempt {
        case 1: return 1
        case 2: return 2
        case 3: return 4
        default: return nil
        }
    }

    /// 把一段行平均切成 n 份(按行,不拆行;n > 行數時每行一份)。
    public static func split(_ lines: [String], into n: Int) -> [[String]] {
        guard n > 1, lines.count > 1 else { return [lines] }
        let parts = min(n, lines.count)
        let size = Int((Double(lines.count) / Double(parts)).rounded(.up))
        return stride(from: 0, to: lines.count, by: size).map { Array(lines[$0..<min($0 + size, lines.count)]) }
    }

    /// 校正子批:在 `range` 內按段落 token 貪婪切到 ≤ max;單段超過 max 自成一批。
    public static func correctionBatches(segments: [String], range: Range<Int>, max: Int = correctionBatchMax) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = range.lowerBound
        var tokens = 0
        for i in range {
            let t = estimateTokens("\(i): \(segments[i])") + 1
            if i > start, tokens + t > max { out.append(start..<i); start = i; tokens = 0 }
            tokens += t
        }
        if start < range.upperBound { out.append(start..<range.upperBound) }
        return out
    }
}
