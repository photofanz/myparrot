import SwiftUI
import MyParrotCore

/// #2438 NOTE-06：Markdown 預覽（`MarkdownBlocks.parse` 切區塊，行內交給 Foundation 的 `AttributedString(markdown:)`）。
/// 勾選框可點（回呼行號，由呼叫端寫回文字）；時間戳列可點（回呼秒數）。會議記錄面板也用它唯讀顯示。
struct MarkdownPreview: View {
    let text: String
    var onToggleCheckbox: ((Int) -> Void)? = nil
    var onTimestamp: ((TimeInterval) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .heading(let level, let t):
            inline(t)
                .font(level == 1 ? .system(size: 18, weight: .bold)
                      : level == 2 ? .system(size: 15, weight: .semibold) : .system(size: 13, weight: .semibold))
                .padding(.top, level == 1 ? 4 : 2)
        case .paragraph(let t):
            inline(t).font(MPFont.body)
        case .list(_, let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in listRow(item) }
            }
        case .quote(let t):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(MP.coral.opacity(0.6)).frame(width: 3)
                inline(t).font(MPFont.body).foregroundStyle(.secondary)
            }
        case .code(_, let lines):
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        case .table(let header, let rows):
            tableView(header, rows)
        case .hr:
            Divider()
        case .timestamp(let h, let m, let s, let rest):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button { onTimestamp?(TimeInterval(h * 3600 + m * 60 + s)) } label: {
                    Label(String(format: "%d:%02d:%02d", h, m, s), systemImage: "flag.fill")
                        .font(MPFont.caption.weight(.semibold)).foregroundStyle(MP.coral)
                }
                .buttonStyle(.plain)
                .help("⚑")
                inline(rest).font(MPFont.body)
            }
        }
    }

    private func listRow(_ item: MarkdownBlocks.ListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let checked = item.checked {
                Button { onToggleCheckbox?(item.line) } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? MP.blue : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(checked ? "☑" : "☐")
            } else if item.ordered {
                Text("\(item.number ?? 1).").font(MPFont.body).foregroundStyle(.secondary)
            } else {
                Text("•").font(MPFont.body).foregroundStyle(.secondary)
            }
            inline(item.text)
                .font(MPFont.body)
                .strikethrough(item.checked == true, color: .secondary)
                .foregroundStyle(item.checked == true ? Color.secondary : Color.primary)
        }
        .padding(.leading, CGFloat(item.indent) * 14)
    }

    private func tableView(_ header: [String], _ rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, h in inline(h).font(MPFont.body.weight(.semibold)) }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in inline(cell).font(MPFont.body) }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    /// 行內 Markdown（粗斜體、刪除線、程式碼、連結）；解析失敗照原文。
    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }
}
