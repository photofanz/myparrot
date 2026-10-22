import Foundation

/// 筆記編輯區的語法高亮範圍(#2438 NOTE-05)。App 層對 `NSTextStorage` 依 Kind 套色。
/// 範圍一律 **UTF-16 偏移**(與 `MarkdownEditing` 同口徑),保證不越界、互不重疊、依起點排序。
///
/// 重疊規則(「外層為準」):
/// 1. 區塊級先拿:圍欄程式碼整塊(含上下圍欄行)＝`code`、ATX 標題整行＝`heading`;裡面不再切任何東西。
/// 2. 行首標記只標符號本身:引用 `>`(連同後面一格)＝`quote`、清單 `-`/`*`/`+`/`1.`＝`listMarker`、`[ ]`/`[x]`＝`checkbox`;
///    分隔線 `---` 不算清單標記。標記後面若是 `#` 標題 ⇒ 該段到行尾＝`heading`。
/// 3. 行內(標記之後的文字):`code`(反引號)、`link`(`[字](網址)`、`<http…>`)、`bold`(`**x**`、`__x__`)、
///    `timestamp`(`⚑ hh:mm:ss`,行中也算)。候選依「起點小者先、同起點長者先」逐一收,與已收的重疊就丟——
///    巢狀時外層贏(`**[a](u)**` 整段 bold;`[**a**](u)` 整段 link;`` `**x**` `` 整段 code),交叉時先開始的贏。
public enum MarkdownHighlight {

    public enum Kind: String, Sendable, CaseIterable {
        case heading, listMarker, checkbox, quote, code, bold, timestamp, link
    }

    public struct Span: Equatable, Sendable {
        public var range: Range<Int>
        public var kind: Kind
        public init(_ range: Range<Int>, _ kind: Kind) { self.range = range; self.kind = kind }
    }

    /// 計畫簽章:`[(Range<Int>, Kind)]`。
    public static func ranges(in text: String) -> [(range: Range<Int>, kind: Kind)] {
        spans(in: text).map { ($0.range, $0.kind) }
    }

    /// 同 `ranges`,但回 Equatable 的 `Span`(測試好比對)。
    public static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        let ls = MarkdownEditing.lines(ns)
        var out: [Span] = []
        var i = 0
        while i < ls.count {
            let l = ls[i]
            let c = MarkdownEditing.content(ns, l)
            // ① 圍欄程式碼整塊
            if let open = MarkdownBlocks.match(MarkdownBlocks.fenceRE, c) {
                var j = i + 1
                var end = ls.count - 1
                while j < ls.count {
                    let cj = MarkdownEditing.content(ns, ls[j])
                    if let close = MarkdownBlocks.match(MarkdownBlocks.fenceCloseRE, cj),
                       close[1].first == open[1].first, close[1].count >= open[1].count { end = j; break }
                    j += 1
                }
                if j >= ls.count { end = ls.count - 1 }
                let r = l.start..<ls[end].contentEnd
                if !r.isEmpty { out.append(Span(r, .code)) }
                i = end + 1
                continue
            }
            // ② 標題整行
            if MarkdownBlocks.match(MarkdownBlocks.atxRE, c) != nil {
                if l.length > 0 { out.append(Span(l.start..<l.contentEnd, .heading)) }
                i += 1
                continue
            }
            // ③ 行首標記
            let cn = c as NSString
            var col = 0
            if let q = quotePrefixRE.firstMatch(in: c, range: NSRange(location: 0, length: cn.length)) {
                out.append(Span(l.start..<(l.start + q.range.length), .quote))
                col = q.range.length
            }
            while col < cn.length && (cn.character(at: col) == 0x20 || cn.character(at: col) == 0x09) { col += 1 }
            let rest = cn.substring(from: col)
            if MarkdownBlocks.match(MarkdownBlocks.hrRE, rest) == nil,
               let m = listMarkerRE.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
                let mr = m.range(at: 1)
                out.append(Span((l.start + col + mr.location)..<(l.start + col + mr.upperBound), .listMarker))
                var k = col + m.range.length
                if let cb = checkboxRE.firstMatch(in: c, options: .anchored, range: NSRange(location: k, length: cn.length - k)) {
                    out.append(Span((l.start + cb.range.location)..<(l.start + cb.range.upperBound), .checkbox))
                    k = cb.range.upperBound
                }
                col = k
            }
            let tail = cn.substring(from: col)
            if MarkdownBlocks.match(MarkdownBlocks.atxRE, tail) != nil {
                if col < cn.length { out.append(Span((l.start + col)..<l.contentEnd, .heading)) }
            } else {
                out += inline(tail, offset: l.start + col)
            }
            i += 1
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: - 行內

    private static func inline(_ s: String, offset: Int) -> [Span] {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        var cands: [Span] = []
        for (re, kind) in inlineRules {
            for m in re.matches(in: s, range: full) {
                cands.append(Span((offset + m.range.location)..<(offset + m.range.upperBound), kind))
            }
        }
        cands.sort {
            $0.range.lowerBound != $1.range.lowerBound ? $0.range.lowerBound < $1.range.lowerBound
                                                       : $0.range.count > $1.range.count
        }
        var kept: [Span] = []
        for c in cands where !kept.contains(where: { $0.range.overlaps(c.range) }) { kept.append(c) }
        return kept
    }

    private static let quotePrefixRE = try! NSRegularExpression(pattern: #"^(?: {0,3}> ?)+"#)
    private static let listMarkerRE = try! NSRegularExpression(pattern: #"^([-*+]|\d{1,9}[.)])(?:[ \t]+|$)"#)
    private static let checkboxRE = try! NSRegularExpression(pattern: #"\[[ xX]\](?=[ \t]|$)"#)
    private static let inlineRules: [(NSRegularExpression, Kind)] = [
        (try! NSRegularExpression(pattern: #"(`+)(?!`)(?:.*?[^`])?\1(?!`)"#), .code),
        (try! NSRegularExpression(pattern: #"\[[^\]\n]*\]\([^)\n]*\)"#), .link),
        (try! NSRegularExpression(pattern: #"<https?://[^>\s]+>"#), .link),
        (try! NSRegularExpression(pattern: #"\*\*(?=\S).*?\S\*\*|__(?=\S).*?\S__"#), .bold),
        (try! NSRegularExpression(pattern: #"⚑\x{FE0F}? ?\d{1,3}:[0-5]\d:[0-5]\d"#), .timestamp),
    ]
}
