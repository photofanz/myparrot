import Foundation

/// 筆記預覽的**區塊**切分(#2438 NOTE-06)。行內(粗斜體、刪除線、程式碼、連結)交給 App 層的
/// `AttributedString(markdown:)`,Core 只切區塊。方言＝CommonMark＋GFM 子集:
/// ATX／setext 標題、段落、巢狀清單(縮排 2 格一層、tab 算 4 格)、勾選框、引用、圍欄程式碼、表格、分隔線,
/// 以及 MyParrot 自己的時間戳列(行首 `⚑ hh:mm:ss`)。
///
/// 刻意不做(寫明以免誤會成漏做):縮排 4 格的程式碼區塊(當段落)、引用與清單的「懶惰續行」
/// (沒有 `>`/縮排的下一行就結束該區塊)、HTML 區塊、連結參照定義。
public enum MarkdownBlocks {

    public struct ListItem: Equatable, Sendable {
        /// 巢狀層級:前導空白 ÷ 2(tab 算 4 格),0＝最外層。
        public var indent: Int
        /// nil＝不是勾選框;true＝`[x]`/`[X]`。
        public var checked: Bool?
        /// 項目文字(勾選框與標記已去掉;縮排續行以 `\n` 接上)。
        public var text: String
        public var ordered: Bool
        /// 編號清單的號碼;項目清單為 nil。
        public var number: Int?
        /// 原文行號(0 起算):預覽點勾選框 ⇒ `MarkdownEditing.toggleCheckbox(atLine:)` 寫回。
        public var line: Int

        public init(indent: Int, checked: Bool?, text: String, ordered: Bool = false, number: Int? = nil, line: Int) {
            self.indent = indent; self.checked = checked; self.text = text
            self.ordered = ordered; self.number = number; self.line = line
        }
    }

    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        /// 連續的段落行,以 `\n` 接。
        case paragraph(String)
        /// `ordered` 依第一項;巢狀子項的種類看各項 `ordered`。
        case list(ordered: Bool, items: [ListItem])
        /// 去掉一層 `> ` 後的內文,以 `\n` 接(巢狀引用保留內層的 `>`)。
        case quote(String)
        case code(lang: String?, lines: [String])
        /// 每列欄數補齊/截斷成表頭欄數(GFM 規則)。
        case table(header: [String], rows: [[String]])
        case hr
        /// 行首 `⚑ hh:mm:ss`;`rest`＝時間後面的字。
        case timestamp(h: Int, m: Int, s: Int, rest: String)
    }

    public static func parse(_ text: String) -> [Block] {
        let ns = text as NSString
        let lines = MarkdownEditing.lines(ns).map { MarkdownEditing.content(ns, $0) }
        var blocks: [Block] = []
        var para: [String] = []
        func flushPara() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // 圍欄程式碼
            if let open = match(fenceRE, line) {
                flushPara()
                let fence = open[1]
                let info = open[2].trimmingCharacters(in: .whitespaces)
                let lang = info.split(separator: " ").first.map(String.init)
                var body: [String] = []
                i += 1
                while i < lines.count {
                    if let close = match(fenceCloseRE, lines[i]), close[1].first == fence.first,
                       close[1].count >= fence.count { i += 1; break }
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.code(lang: lang, lines: body))
                continue
            }
            if MarkdownEditing.isBlank(line) { flushPara(); i += 1; continue }
            if let t = match(timestampRE, line) {
                flushPara()
                blocks.append(.timestamp(h: Int(t[1]) ?? 0, m: Int(t[2]) ?? 0, s: Int(t[3]) ?? 0, rest: t[4]))
                i += 1; continue
            }
            if let h = match(atxRE, line) {
                flushPara()
                blocks.append(.heading(level: h[1].count, text: h[2]))
                i += 1; continue
            }
            if !para.isEmpty, let u = match(setextRE, line) {
                let level = u[1].hasPrefix("=") ? 1 : 2
                blocks.append(.heading(level: level, text: para.joined(separator: "\n")))
                para = []
                i += 1; continue
            }
            if match(hrRE, line) != nil { flushPara(); blocks.append(.hr); i += 1; continue }
            if match(quoteRE, line) != nil {
                flushPara()
                var inner: [String] = []
                while i < lines.count, let q = match(quoteRE, lines[i]) { inner.append(q[1]); i += 1 }
                blocks.append(.quote(inner.joined(separator: "\n")))
                continue
            }
            if listItem(line, lineNo: i) != nil {
                flushPara()
                let (block, next) = parseList(lines, from: i)
                blocks.append(block)
                i = next
                continue
            }
            if i + 1 < lines.count, let header = tableHeader(line, delimiter: lines[i + 1]) {
                flushPara()
                var rows: [[String]] = []
                i += 2
                while i < lines.count, !MarkdownEditing.isBlank(lines[i]), !startsOtherBlock(lines[i]) {
                    var cells = splitCells(lines[i])
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(Array(cells.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            para.append(line.trimmingCharacters(in: .whitespaces))
            i += 1
        }
        flushPara()
        return blocks
    }

    // MARK: - 清單

    private static func parseList(_ lines: [String], from start: Int) -> (Block, Int) {
        var items: [ListItem] = []
        var ordered = false
        var i = start
        while i < lines.count {
            let line = lines[i]
            if match(hrRE, line) != nil { break }
            if let item = listItem(line, lineNo: i) {
                if items.isEmpty { ordered = item.ordered }
                else if item.indent == 0 && item.ordered != ordered { break }   // 最外層換種類 ⇒ 另一個清單
                items.append(item)
                i += 1; continue
            }
            if MarkdownEditing.isBlank(line) {
                var j = i + 1
                while j < lines.count && MarkdownEditing.isBlank(lines[j]) { j += 1 }
                if j < lines.count, let next = listItem(lines[j], lineNo: j),
                   next.indent > 0 || next.ordered == ordered {
                    i = j; continue                                               // 鬆散清單:空行後還是同一個清單
                }
                break
            }
            // 縮排續行(≥2 格、不是別種區塊)⇒ 接到上一項
            if !items.isEmpty, leadingWidth(line) >= 2, !startsOtherBlock(line) {
                items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
                i += 1; continue
            }
            break
        }
        return (.list(ordered: ordered, items: items), i)
    }

    static func listItem(_ line: String, lineNo: Int) -> ListItem? {
        guard match(hrRE, line) == nil, let m = match(listRE, line) else { return nil }
        let indent = width(of: m[1]) / 2
        let isOrdered = !m[3].isEmpty
        let checked: Bool? = m[4].isEmpty ? nil : (m[4] != " ")
        return ListItem(indent: indent, checked: checked, text: m[5], ordered: isOrdered,
                        number: isOrdered ? Int(m[3]) : nil, line: lineNo)
    }

    // MARK: - 表格

    /// `line` 是表頭、`delimiter` 是分隔列且欄數相同 ⇒ 表頭各欄;否則 nil。
    static func tableHeader(_ line: String, delimiter: String) -> [String]? {
        guard line.contains("|"), delimiter.contains("|") || line.hasPrefix("|"),
              match(delimiterRE, delimiter) != nil else { return nil }
        let header = splitCells(line)
        let delims = splitCells(delimiter)
        guard !header.isEmpty, header.count == delims.count else { return nil }
        return header
    }

    /// 切欄:去掉頭尾各一個 `|`、以未跳脫的 `|` 切、每格 trim、`\|` 還原成 `|`。
    static func splitCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = []
        var cur = ""
        var escaped = false
        for ch in s {
            if escaped { cur.append(ch == "|" ? "|" : "\\"); if ch != "|" { cur.append(ch) }; escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { cells.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
        }
        if escaped { cur.append("\\") }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - 共用

    private static func startsOtherBlock(_ line: String) -> Bool {
        match(fenceRE, line) != nil || match(atxRE, line) != nil || match(quoteRE, line) != nil
            || match(hrRE, line) != nil || match(timestampRE, line) != nil
    }

    private static func width(of indent: String) -> Int {
        indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func leadingWidth(_ line: String) -> Int {
        width(of: String(line.prefix { $0 == " " || $0 == "\t" }))
    }

    /// 整行比對;回各組字串(沒參與比對的組＝空字串)。
    static func match(_ re: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { k in
            let r = m.range(at: k)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    static let fenceRE = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})(.*)$"#)
    static let fenceCloseRE = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})[ \t]*$"#)
    static let timestampRE = try! NSRegularExpression(pattern: #"^⚑\x{FE0F}? ?(\d{1,3}):([0-5]\d):([0-5]\d)(?:[ \t]+(.*))?$"#)
    static let atxRE = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$"#)
    static let setextRE = try! NSRegularExpression(pattern: #"^ {0,3}(=+|-+)[ \t]*$"#)
    static let hrRE = try! NSRegularExpression(pattern: #"^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    static let quoteRE = try! NSRegularExpression(pattern: #"^ {0,3}> ?(.*)$"#)
    static let listRE = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-*+]|(\d{1,9})[.)])(?:[ \t]+|$)(?:\[([ xX])\](?:[ \t]+|$))?(.*)$"#)
    static let delimiterRE = try! NSRegularExpression(pattern: #"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)
}
