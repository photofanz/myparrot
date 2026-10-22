import Foundation

/// 一次編輯的結果。**偏移一律是 UTF-16 單位**(＝`NSString`／`NSTextView` 的 `NSRange`),
/// 整組 `MarkdownEditing`／`MarkdownHighlight` 都用同一口徑;App 層直接拿 `NSRange(selection)` 套。
public struct MarkdownEdit: Equatable, Sendable {
    public var text: String
    public var selection: Range<Int>
    public init(text: String, selection: Range<Int>) {
        self.text = text
        self.selection = selection
    }
}

/// 筆記編輯行為的純函式(#2438 NOTE-03／NOTE-04)。輸入 `(text, selection)`,回新的 `(text, selection)`;
/// 回 `nil` 的函式＝「不攔截,照一般打字處理」。選取超出範圍時先夾回 `0...length`。
public enum MarkdownEditing {

    // MARK: - 工具列:行內包覆

    /// 有選取＝包住選取(選取改成包住後的內文);沒選取＝插一對語法、游標放中間。
    /// 再套一次＝解除:選取本身已被包住、或選取兩側緊鄰同一組符號 ⇒ 拿掉。
    /// `*`/`_` 單字元以「兩側連續星號數為奇數」判定斜體開著(`**x**` 上按斜體 ⇒ `***x***`,不會誤拆粗體)。
    public static func wrap(_ text: String, selection: Range<Int>, with marker: String) -> MarkdownEdit {
        let ns = text as NSString
        let sel = clamp(selection, ns.length)
        let mk = marker as NSString
        let k = mk.length
        guard k > 0 else { return MarkdownEdit(text: text, selection: sel) }
        let first = mk.character(at: 0)
        let uniform = (0..<k).allSatisfy { mk.character(at: $0) == first }
        func isOn(_ before: Int, _ after: Int) -> Bool {
            let r = min(before, after)
            if k == 1 && (first == 0x2A || first == 0x5F) { return r % 2 == 1 }   // * 或 _
            return r >= k
        }
        // ① 選取本身已被包住
        if sel.count >= 2 * k {
            let lead: Int, trail: Int
            if uniform {
                lead = runForward(ns, from: sel.lowerBound, upTo: sel.upperBound, char: first)
                trail = runBackward(ns, from: sel.upperBound - 1, downTo: sel.lowerBound, char: first)
            } else {
                let s = ns.substring(with: NSRange(sel))
                lead = s.hasPrefix(marker) ? k : 0
                trail = s.hasSuffix(marker) ? k : 0
            }
            if lead < sel.count && isOn(lead, trail) {
                let m = NSMutableString(string: ns)
                m.deleteCharacters(in: NSRange(location: sel.upperBound - k, length: k))
                m.deleteCharacters(in: NSRange(location: sel.lowerBound, length: k))
                return MarkdownEdit(text: m as String, selection: sel.lowerBound..<(sel.upperBound - 2 * k))
            }
        }
        // ② 選取／游標兩側緊鄰符號
        let before: Int, after: Int
        if uniform {
            before = sel.lowerBound > 0 ? runBackward(ns, from: sel.lowerBound - 1, downTo: 0, char: first) : 0
            after = runForward(ns, from: sel.upperBound, upTo: ns.length, char: first)
        } else {
            before = sel.lowerBound >= k && ns.substring(with: NSRange(location: sel.lowerBound - k, length: k)) == marker ? k : 0
            after = sel.upperBound + k <= ns.length && ns.substring(with: NSRange(location: sel.upperBound, length: k)) == marker ? k : 0
        }
        if isOn(before, after) {
            let m = NSMutableString(string: ns)
            m.deleteCharacters(in: NSRange(location: sel.upperBound, length: k))
            m.deleteCharacters(in: NSRange(location: sel.lowerBound - k, length: k))
            return MarkdownEdit(text: m as String, selection: (sel.lowerBound - k)..<(sel.upperBound - k))
        }
        // ③ 包住/插一對
        let m = NSMutableString(string: ns)
        m.insert(marker, at: sel.upperBound)
        m.insert(marker, at: sel.lowerBound)
        return MarkdownEdit(text: m as String, selection: (sel.lowerBound + k)..<(sel.upperBound + k))
    }

    /// 程式碼鈕:選取跨多行 ⇒ 圍欄(```` ``` ```` 上下各一行;已被圍欄包住 ⇒ 拿掉);否則同 `wrap(with: "`")`。
    public static func toggleCode(_ text: String, selection: Range<Int>) -> MarkdownEdit {
        let ns = text as NSString
        let sel = clamp(selection, ns.length)
        let ls = lines(ns)
        let idx = touched(ls, sel)
        guard idx.count > 1 else { return wrap(text, selection: sel, with: "`") }
        let firstL = ls[idx.lowerBound], lastL = ls[idx.upperBound]
        // 已被圍欄包住:上一行與下一行都是 ``` ⇒ 拿掉兩行
        if idx.lowerBound > 0, idx.upperBound + 1 < ls.count,
           isFence(content(ns, ls[idx.lowerBound - 1])), isFence(content(ns, ls[idx.upperBound + 1])) {
            let above = ls[idx.lowerBound - 1], below = ls[idx.upperBound + 1]
            let m = NSMutableString(string: ns)
            m.deleteCharacters(in: NSRange(location: lastL.contentEnd, length: below.contentEnd - lastL.contentEnd))
            m.deleteCharacters(in: NSRange(location: above.start, length: firstL.start - above.start))
            let shift = firstL.start - above.start
            return MarkdownEdit(text: m as String,
                                selection: (firstL.start - shift)..<(lastL.contentEnd - shift))
        }
        let m = NSMutableString(string: ns)
        m.insert("\n```", at: lastL.contentEnd)
        m.insert("```\n", at: firstL.start)
        return MarkdownEdit(text: m as String, selection: (firstL.start + 4)..<(lastL.contentEnd + 4))
    }

    // MARK: - 工具列:行首前綴

    /// 對選取碰到的每一行加前綴;**全部行都已有同一種前綴 ⇒ 移除**(再按一次＝解除)。
    /// 支援 `# `／`## `／`### `(H1～H6)、`- `、`1. `(逐行遞增 1. 2. 3.)、`- [ ] `、`> `;其他字串照字面加/移。
    /// 清單類(標題/項目/編號/勾選框)互相取代(對 `- a` 按編號 ⇒ `1. a`);引用 `> ` 疊在最前面、不取代清單。
    /// 多行選取時空白行略過;游標在空白行上按 ⇒ 照加(工具列插語法)。
    public static func prefixLines(_ text: String, selection: Range<Int>, with prefix: String) -> MarkdownEdit {
        let ns = text as NSString
        let sel = clamp(selection, ns.length)
        let ls = lines(ns)
        let idx = touched(ls, sel)
        let kind = PrefixKind(prefix)
        let multi = idx.count > 1
        let targets = idx.filter { !multi || !isBlank(content(ns, ls[$0])) }
        guard !targets.isEmpty else { return MarkdownEdit(text: text, selection: sel) }
        let parsed = targets.map { LinePrefix(content(ns, ls[$0])) }
        let allHave = parsed.allSatisfy { kind.matches($0) }
        var edits: [LineEdit] = []
        var number = 1
        for (line, p) in zip(targets, parsed) {
            edits.append(allHave ? kind.removal(p, line: line) : kind.addition(p, line: line, number: number))
            number += 1
        }
        return apply(ns, ls, edits, selection: sel)
    }

    /// 切換第 `line` 行(0 起算)的勾選框:`[ ]`⇄`[x]`(`[X]` 也算勾);是清單項但沒勾選框 ⇒ 補 `[ ] `;
    /// 一般文字 ⇒ 變成 `- [ ] `。行號超出 ⇒ 原樣。預覽點勾選框與 ⌘⏎ 共用。
    public static func toggleCheckbox(_ text: String, atLine line: Int, selection: Range<Int> = 0..<0) -> MarkdownEdit {
        let ns = text as NSString
        let sel = clamp(selection, ns.length)
        let ls = lines(ns)
        guard line >= 0, line < ls.count else { return MarkdownEdit(text: text, selection: sel) }
        let p = LinePrefix(content(ns, ls[line]))
        let quoteIndent = p.quoteLen + p.indentLen
        switch p.marker {
        case .checkbox(let checked)?:
            // 勾選字元位在 marker 內 "[" 之後;長度不變,選取不動。
            let c = content(ns, ls[line]) as NSString
            let bracket = c.range(of: "[", options: [], range: NSRange(location: quoteIndent, length: p.rawMarkerLen)).location
            let m = NSMutableString(string: ns)
            m.replaceCharacters(in: NSRange(location: ls[line].start + bracket + 1, length: 1), with: checked ? " " : "x")
            return MarkdownEdit(text: m as String, selection: sel)
        case .bullet?, .ordered?:
            // 在 marker(含空白)後面插 "[ ] "
            let edit = LineEdit(line: line, oldPrefix: quoteIndent + p.rawMarkerLen,
                                newPrefix: p.quoteIndentString + p.markerString + "[ ] ")
            return apply(ns, ls, [edit], selection: sel)
        default:
            let edit = LineEdit(line: line, oldPrefix: quoteIndent, newPrefix: p.quoteIndentString + "- [ ] ")
            return apply(ns, ls, [edit], selection: sel)
        }
    }

    /// ⌘⏎:切換游標所在行的勾選。
    public static func toggleCheckbox(_ text: String, selection: Range<Int>) -> MarkdownEdit {
        let ns = text as NSString
        let sel = clamp(selection, ns.length)
        return toggleCheckbox(text, atLine: lineIndex(lines(ns), sel.lowerBound), selection: sel)
    }

    // MARK: - 編輯行為

    /// Enter:游標所在行是清單項(`- `/`* `/`+ `/`1. `/`1) `/勾選框)⇒ 換行並接續同一種前綴
    /// (編號遞增、勾選框一律接未勾)。空項(前綴後只有空白)再 Enter ⇒ 刪掉前綴、不換行(結束清單)。
    /// 不是清單、有選取、或游標在前綴裡 ⇒ `nil`(照一般 Enter)。
    public static func enterContinuesList(_ text: String, selection: Range<Int>) -> MarkdownEdit? {
        let ns = text as NSString
        let sel = clamp(selection, ns.length)
        guard sel.isEmpty else { return nil }
        let ls = lines(ns)
        let li = lineIndex(ls, sel.lowerBound)
        let line = ls[li]
        let c = content(ns, line)
        let p = LinePrefix(c)
        let preLen = p.quoteLen + p.indentLen + p.rawMarkerLen
        let next: String
        switch p.marker {
        case .bullet?:
            next = p.markerString
        case .ordered(let n)?:
            let delim = p.markerString.contains(")") ? ")" : "."
            next = "\(n + 1)\(delim) "
        case .checkbox?:
            let bulletPart = p.markerString.prefix { $0 != "[" }
            if let n = Int(bulletPart.trimmingCharacters(in: CharacterSet(charactersIn: " .)"))) {
                let delim = bulletPart.contains(")") ? ")" : "."
                next = "\(n + 1)\(delim) [ ] "
            } else {
                next = bulletPart + "[ ] "
            }
        default:
            return nil
        }
        let col = sel.lowerBound - line.start
        guard col >= preLen else { return nil }
        let rest = (c as NSString).substring(from: preLen)
        if isBlank(rest) {
            // 空項 ⇒ 結束清單:整個前綴(含縮排與引用)刪掉。
            let m = NSMutableString(string: ns)
            m.deleteCharacters(in: NSRange(location: line.start, length: line.length))
            return MarkdownEdit(text: m as String, selection: line.start..<line.start)
        }
        let insert = "\n" + p.quoteIndentString + next
        let m = NSMutableString(string: ns)
        m.insert(insert, at: sel.lowerBound)
        let caret = sel.lowerBound + (insert as NSString).length
        return MarkdownEdit(text: m as String, selection: caret..<caret)
    }

    /// Tab:選取碰到的每一行行首加兩格(多行時空白行略過)。
    public static func indent(_ text: String, selection: Range<Int>) -> MarkdownEdit {
        let ns = text as NSString
        let sel = clamp(selection, ns.length)
        let ls = lines(ns)
        let idx = touched(ls, sel)
        let multi = idx.count > 1
        let edits = idx.filter { !multi || !isBlank(content(ns, ls[$0])) }
            .map { LineEdit(line: $0, oldPrefix: 0, newPrefix: "  ") }
        return apply(ns, ls, edits, selection: sel)
    }

    /// ⇧Tab:每行行首去掉最多兩格空白(或一個 tab)。
    public static func outdent(_ text: String, selection: Range<Int>) -> MarkdownEdit {
        let ns = text as NSString
        let sel = clamp(selection, ns.length)
        let ls = lines(ns)
        var edits: [LineEdit] = []
        for i in touched(ls, sel) {
            let c = content(ns, ls[i]) as NSString
            var n = 0
            if c.length > 0 && c.character(at: 0) == 0x09 {
                n = 1
            } else {
                while n < 2 && n < c.length && c.character(at: n) == 0x20 { n += 1 }
            }
            if n > 0 { edits.append(LineEdit(line: i, oldPrefix: n, newPrefix: "")) }
        }
        return apply(ns, ls, edits, selection: sel)
    }

    /// 連結 ⌘K(GitHub 工具列同款):
    /// - 剪貼簿是網址:有選取 ⇒ `[選取](網址)`、游標在後;沒選取 ⇒ `[](網址)`、游標在方括號內。
    /// - 剪貼簿不是網址:有選取 ⇒ `[選取](url)`、選中字面 `url` 讓人直接打;沒選取 ⇒ `[](url)`、游標在方括號內。
    public static func insertLink(_ text: String, selection: Range<Int>, url: String, clipboardIsURL: Bool) -> MarkdownEdit {
        let ns = text as NSString
        let sel = clamp(selection, ns.length)
        let label = ns.substring(with: NSRange(sel))
        let target = clipboardIsURL ? url.trimmingCharacters(in: .whitespacesAndNewlines) : "url"
        let snippet = "[\(label)](\(target))"
        let m = NSMutableString(string: ns)
        m.replaceCharacters(in: NSRange(sel), with: snippet)
        let start = sel.lowerBound
        let labelLen = (label as NSString).length
        if label.isEmpty {
            return MarkdownEdit(text: m as String, selection: (start + 1)..<(start + 1))
        }
        if clipboardIsURL {
            let end = start + (snippet as NSString).length
            return MarkdownEdit(text: m as String, selection: end..<end)
        }
        let urlStart = start + labelLen + 3   // "[" + label + "]("
        return MarkdownEdit(text: m as String, selection: urlStart..<(urlStart + 3))
    }

    /// 表格鈕:插 2 欄×2 列範本(表頭＋分隔＋兩列空白)。表頭字由 App 層傳(Core 不放 UI 字串)。
    /// 前面不是空行 ⇒ 先空一行(避免被當成段落延續);後面有字 ⇒ 多空一行(GFM 表格遇非空行會吃進去)。
    /// 完成後選中第一個表頭,直接打字取代。
    public static func insertTable2x2(_ text: String, selection: Range<Int>,
                                      headers: (String, String) = ("Column 1", "Column 2")) -> MarkdownEdit {
        let body = "| \(headers.0) | \(headers.1) |\n| --- | --- |\n|  |  |\n|  |  |\n"
        let r = insertBlock(text, selection: selection, block: body)
        let headerStart = r.blockStart + 2
        return MarkdownEdit(text: r.text, selection: headerStart..<(headerStart + (headers.0 as NSString).length))
    }

    /// 分隔線鈕:獨立一行 `---`;前一行有字 ⇒ 先空一行(不然 `文字\n---` 會變成 H2)。游標放在分隔線下一行。
    public static func insertHR(_ text: String, selection: Range<Int>) -> MarkdownEdit {
        let r = insertBlock(text, selection: selection, block: "---\n")
        let caret = r.blockStart + 4
        return MarkdownEdit(text: r.text, selection: caret..<caret)
    }

    /// 在游標處插一段字(取代選取),游標放在後面。⚑ 標記、引用到筆記用。
    public static func insert(_ text: String, selection: Range<Int>, snippet: String) -> MarkdownEdit {
        let ns = text as NSString
        let sel = clamp(selection, ns.length)
        let m = NSMutableString(string: ns)
        m.replaceCharacters(in: NSRange(sel), with: snippet)
        let caret = sel.lowerBound + (snippet as NSString).length
        return MarkdownEdit(text: m as String, selection: caret..<caret)
    }

    /// 自動成對(打字時呼叫,`typed` 是剛打的那個字):
    /// - `[`、`` ` ``:沒選取 ⇒ 插一對、游標在中間;有選取 ⇒ 包住選取。
    /// - `]`、`` ` ``:下一個字就是它 ⇒ 跳過(不重複插)。
    /// - `*`:下一個字是 `*` ⇒ 跳過;前一個字是單一 `*`(剛打出 `**`)⇒ 補上收尾 `**`、游標在中間。
    /// 其他 ⇒ `nil`(照一般打字)。
    public static func autoPair(_ text: String, selection: Range<Int>, typed: Character) -> MarkdownEdit? {
        let ns = text as NSString
        let sel = clamp(selection, ns.length)
        let p = sel.lowerBound
        let nextChar: unichar? = sel.isEmpty && p < ns.length ? ns.character(at: p) : nil
        let prevChar: unichar? = p > 0 ? ns.character(at: p - 1) : nil
        switch typed {
        case "[":
            return wrapOrPair(ns, sel, open: "[", close: "]")
        case "`":
            if nextChar == 0x60 { return MarkdownEdit(text: text, selection: (p + 1)..<(p + 1)) }
            return wrapOrPair(ns, sel, open: "`", close: "`")
        case "]":
            if nextChar == 0x5D { return MarkdownEdit(text: text, selection: (p + 1)..<(p + 1)) }
            return nil
        case "*":
            guard sel.isEmpty else { return nil }
            if nextChar == 0x2A { return MarkdownEdit(text: text, selection: (p + 1)..<(p + 1)) }
            let prevPrev: unichar? = p > 1 ? ns.character(at: p - 2) : nil
            if prevChar == 0x2A && prevPrev != 0x2A {
                let m = NSMutableString(string: ns)
                m.insert("***", at: p)
                return MarkdownEdit(text: m as String, selection: (p + 1)..<(p + 1))
            }
            return nil
        default:
            return nil
        }
    }

    /// 貼上的是單一網址 ⇒ 自動成連結:有選取 ⇒ `[選取](網址)`;沒選取 ⇒ `<網址>`(CommonMark 自動連結)。
    /// 不是網址、選取本身就是網址、或游標緊接在 `(`／`<`／`[` 後面(正在手打連結)⇒ `nil`(照一般貼上)。
    public static func linkifyPastedURL(_ text: String, selection: Range<Int>, pasted: String) -> MarkdownEdit? {
        let url = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelyURL(url) else { return nil }
        let ns = text as NSString
        let sel = clamp(selection, ns.length)
        if sel.lowerBound > 0 {
            let prev = ns.character(at: sel.lowerBound - 1)
            if prev == 0x28 || prev == 0x3C || prev == 0x5B { return nil }   // ( < [
        }
        let label = ns.substring(with: NSRange(sel))
        if isLikelyURL(label.trimmingCharacters(in: .whitespacesAndNewlines)) { return nil }
        let snippet = label.isEmpty ? "<\(url)>" : "[\(label)](\(url))"
        return insert(text, selection: sel, snippet: snippet)
    }

    /// http(s) 網址、無空白、有 host。App 層判斷「剪貼簿是不是網址」也用這支,口徑一致。
    public static func isLikelyURL(_ s: String) -> Bool {
        guard !s.isEmpty, s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = c.host, !host.isEmpty
        else { return false }
        return true
    }

    // MARK: - 內部:行

    struct Line {
        let start: Int
        let contentEnd: Int
        let end: Int
        var length: Int { contentEnd - start }
    }

    /// 切行(`\n`;`\r\n` 的 `\r` 不算內容)。結尾是換行 ⇒ 最後多一個空行(游標可以停在那)。
    static func lines(_ ns: NSString) -> [Line] {
        var out: [Line] = []
        var start = 0
        let n = ns.length
        var i = 0
        while i < n {
            if ns.character(at: i) == 0x0A {
                var ce = i
                if ce > start && ns.character(at: ce - 1) == 0x0D { ce -= 1 }
                out.append(Line(start: start, contentEnd: ce, end: i + 1))
                start = i + 1
            }
            i += 1
        }
        out.append(Line(start: start, contentEnd: n, end: n))
        return out
    }

    static func content(_ ns: NSString, _ l: Line) -> String {
        ns.substring(with: NSRange(location: l.start, length: l.length))
    }

    static func lineIndex(_ ls: [Line], _ p: Int) -> Int {
        var lo = 0, hi = ls.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if ls[mid].start <= p { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// 選取碰到的行;非空選取的結尾剛好在行首 ⇒ 不算那一行。
    static func touched(_ ls: [Line], _ sel: Range<Int>) -> ClosedRange<Int> {
        let a = lineIndex(ls, sel.lowerBound)
        let b = lineIndex(ls, sel.isEmpty ? sel.lowerBound : sel.upperBound - 1)
        return a...max(a, b)
    }

    static func clamp(_ s: Range<Int>, _ n: Int) -> Range<Int> {
        let lo = min(max(0, s.lowerBound), n)
        let hi = min(max(lo, s.upperBound), n)
        return lo..<hi
    }

    static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    static func isFence(_ s: String) -> Bool {
        let t = s.drop { $0 == " " }
        return t.hasPrefix("```") || t.hasPrefix("~~~")
    }

    static func runForward(_ ns: NSString, from: Int, upTo: Int, char: unichar) -> Int {
        var i = from, n = 0
        while i < upTo && ns.character(at: i) == char { i += 1; n += 1 }
        return n
    }

    static func runBackward(_ ns: NSString, from: Int, downTo: Int, char: unichar) -> Int {
        var i = from, n = 0
        while i >= downTo && i >= 0 && ns.character(at: i) == char { i -= 1; n += 1 }
        return n
    }

    private static func wrapOrPair(_ ns: NSString, _ sel: Range<Int>, open: String, close: String) -> MarkdownEdit {
        let m = NSMutableString(string: ns)
        m.insert(close, at: sel.upperBound)
        m.insert(open, at: sel.lowerBound)
        let o = (open as NSString).length
        return MarkdownEdit(text: m as String, selection: (sel.lowerBound + o)..<(sel.upperBound + o))
    }

    /// 把一段區塊(以 `\n` 結尾)插成獨立段落;回新文字與區塊起點。
    private static func insertBlock(_ text: String, selection: Range<Int>, block: String) -> (text: String, blockStart: Int) {
        let ns = text as NSString
        let sel = clamp(selection, ns.length)
        let ls = lines(ns)
        let li = lineIndex(ls, sel.lowerBound)
        var lead = ""
        if sel.lowerBound > ls[li].start {
            lead = "\n\n"                                    // 游標在行中 ⇒ 換行再空一行
        } else if li > 0 && !isBlank(content(ns, ls[li - 1])) {
            lead = "\n"                                      // 在行首但上一行有字 ⇒ 空一行
        }
        var trail = ""
        let afterLine = ls[lineIndex(ls, sel.upperBound)]
        let restOfLine = ns.substring(with: NSRange(location: sel.upperBound, length: max(0, afterLine.contentEnd - sel.upperBound)))
        // 區塊以 \n 結尾;原行剩下的字若非空白會緊貼在區塊下一行 ⇒ 多空一行。剩下是空的 ⇒ 原本的換行自然成為空行。
        if !isBlank(restOfLine) { trail = "\n" }
        let m = NSMutableString(string: ns)
        m.replaceCharacters(in: NSRange(sel), with: lead + block + trail)
        return (m as String, sel.lowerBound + (lead as NSString).length)
    }

    // MARK: - 內部:行首前綴解析與套用

    enum Marker: Equatable {
        case heading(Int)
        case bullet
        case ordered(Int)
        case checkbox(Bool)
    }

    /// 一行開頭的結構:引用 `> ` 串、縮排、清單類標記(含尾端空白與勾選框)。長度都是 UTF-16。
    struct LinePrefix {
        var quoteString = ""
        var indentString = ""
        var markerString = ""
        var marker: Marker?
        var quoteLen: Int { (quoteString as NSString).length }
        var indentLen: Int { (indentString as NSString).length }
        var markerLen: Int { (markerString as NSString).length }
        var quoteIndentString: String { quoteString + indentString }

        private static let quoteRE = try! NSRegularExpression(pattern: #"^(?: {0,3}> ?)+"#)
        private static let headingRE = try! NSRegularExpression(pattern: #"^(#{1,6})(?: +|$)"#)
        private static let checkboxRE = try! NSRegularExpression(pattern: #"^(?:[-*+]|(\d{1,9})[.)]) +\[([ xX])\](?: +|$)"#)
        private static let bulletRE = try! NSRegularExpression(pattern: #"^[-*+](?: +|$)"#)
        private static let orderedRE = try! NSRegularExpression(pattern: #"^(\d{1,9})[.)](?: +|$)"#)

        init(_ line: String) {
            var ns = line as NSString
            if let m = Self.quoteRE.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                quoteString = ns.substring(with: m.range)
                ns = ns.substring(from: m.range.length) as NSString
            }
            var i = 0
            while i < ns.length && (ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09) { i += 1 }
            indentString = ns.substring(to: i)
            let rest = ns.substring(from: i)
            let full = NSRange(location: 0, length: (rest as NSString).length)
            if let m = Self.headingRE.firstMatch(in: rest, range: full) {
                marker = .heading(m.range(at: 1).length)
                markerString = (rest as NSString).substring(with: m.range)
            } else if let m = Self.checkboxRE.firstMatch(in: rest, range: full) {
                let box = (rest as NSString).substring(with: m.range(at: 2))
                marker = .checkbox(box != " ")
                markerString = (rest as NSString).substring(with: m.range)
            } else if let m = Self.orderedRE.firstMatch(in: rest, range: full) {
                marker = .ordered(Int((rest as NSString).substring(with: m.range(at: 1))) ?? 1)
                markerString = (rest as NSString).substring(with: m.range)
            } else if let m = Self.bulletRE.firstMatch(in: rest, range: full) {
                marker = .bullet
                markerString = (rest as NSString).substring(with: m.range)
            }
            // 標記沒有尾端空白(行尾就是標記)時補一格,接續/替換時才不會黏字。
            if marker != nil, !markerString.hasSuffix(" ") {
                markerString += " "
                markerPadded = true
            }
        }
        /// 行尾就是標記(例:`-`)時 markerString 補了一格空白,但原文沒有;oldPrefix 要扣回來。
        var markerPadded = false
        var rawMarkerLen: Int { markerLen - (markerPadded ? 1 : 0) }
    }

    struct LineEdit {
        var line: Int
        var oldPrefix: Int
        var newPrefix: String
    }

    enum PrefixKind {
        case heading(Int), bullet, ordered, checkbox, quote, literal(String)

        init(_ prefix: String) {
            let t = prefix.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, t.count <= 6, t.allSatisfy({ $0 == "#" }) { self = .heading(t.count); return }
            switch prefix {
            case "- ", "* ", "+ ": self = .bullet
            case "1. ", "1) ": self = .ordered
            case "- [ ] ", "- [x] ": self = .checkbox
            case "> ": self = .quote
            default: self = .literal(prefix)
            }
        }

        func matches(_ p: LinePrefix) -> Bool {
            switch (self, p.marker) {
            case (.heading(let n), .heading(let m)?): return n == m
            case (.bullet, .bullet?): return true
            case (.ordered, .ordered?): return true
            case (.checkbox, .checkbox?): return true
            case (.quote, _): return !p.quoteString.isEmpty
            case (.literal(let s), _): return (p.quoteString + p.indentString + p.markerString).hasPrefix(s)
            default: return false
            }
        }

        func removal(_ p: LinePrefix, line: Int) -> LineEdit {
            switch self {
            case .quote:
                // 拿掉最外層一個 ">" 與它後面的一格空白
                let q = p.quoteString as NSString
                let gt = q.range(of: ">").location
                var n = gt + 1
                if n < q.length && q.character(at: n) == 0x20 { n += 1 }
                return LineEdit(line: line, oldPrefix: n, newPrefix: q.substring(to: gt))
            case .literal(let s):
                return LineEdit(line: line, oldPrefix: (s as NSString).length, newPrefix: "")
            default:
                return LineEdit(line: line, oldPrefix: p.quoteLen + p.indentLen + p.rawMarkerLen,
                                newPrefix: p.quoteIndentString)
            }
        }

        func addition(_ p: LinePrefix, line: Int, number: Int) -> LineEdit {
            let newMarker: String
            switch self {
            case .quote: return LineEdit(line: line, oldPrefix: 0, newPrefix: "> ")
            case .literal(let s): return LineEdit(line: line, oldPrefix: 0, newPrefix: s)
            case .heading(let n): newMarker = String(repeating: "#", count: n) + " "
            case .bullet: newMarker = "- "
            case .ordered: newMarker = "\(number). "
            case .checkbox: newMarker = "- [ ] "
            }
            let old = p.marker == nil ? 0 : p.rawMarkerLen
            return LineEdit(line: line, oldPrefix: p.quoteLen + p.indentLen + old,
                            newPrefix: p.quoteIndentString + newMarker)
        }
    }

    /// 套一組行首替換,並把選取對到新位置:
    /// 在被換掉的前綴之後 ⇒ 跟著位移;落在舊前綴裡 ⇒ 移到新前綴之後;
    /// 非空選取的起點剛好在行首 ⇒ 留在行首(選取涵蓋新前綴)。
    static func apply(_ ns: NSString, _ ls: [Line], _ edits: [LineEdit], selection sel: Range<Int>) -> MarkdownEdit {
        let m = NSMutableString(string: ns)
        for e in edits.sorted(by: { $0.line > $1.line }) {
            m.replaceCharacters(in: NSRange(location: ls[e.line].start, length: e.oldPrefix), with: e.newPrefix)
        }
        func map(_ p: Int, keepLineStart: Bool) -> Int {
            var out = p
            for e in edits {
                let s = ls[e.line].start, o = e.oldPrefix, nl = (e.newPrefix as NSString).length
                if p < s { continue }
                if keepLineStart && p == s { continue }
                if p >= s + o { out += nl - o } else { out += (s + nl) - p }
            }
            return out
        }
        let lo = map(sel.lowerBound, keepLineStart: !sel.isEmpty)
        let hi = sel.isEmpty ? lo : max(lo, map(sel.upperBound, keepLineStart: false))
        return MarkdownEdit(text: m as String, selection: lo..<hi)
    }
}
