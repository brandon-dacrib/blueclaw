import SwiftUI

struct MarkdownTextView: View {
    let content: String
    let isUser: Bool

    private var blocks: [Block] {
        Self.parseBlocks(from: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(makeAttributedString(from: text))
                        .font(.body)
                        .foregroundStyle(isUser ? .white : AppColors.textPrimary)
                        .textSelection(.enabled)
                case .code(let language, let code):
                    codeBlock(language: language, code: code)
                }
            }
        }
    }

    // MARK: - Block parsing

    private enum Block {
        case text(String)
        case code(language: String?, code: String)
    }

    private static func parseBlocks(from content: String) -> [Block] {
        var blocks: [Block] = []
        var remaining = content[content.startIndex...]

        while !remaining.isEmpty {
            // Look for code fence ```
            if let fenceStart = remaining.range(of: "```") {
                // Text before the fence
                let textBefore = String(remaining[remaining.startIndex..<fenceStart.lowerBound])
                if !textBefore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.text(textBefore))
                }

                // Get language hint (rest of line after ```)
                let afterFence = remaining[fenceStart.upperBound...]
                let languageLine: String
                if let newline = afterFence.firstIndex(of: "\n") {
                    languageLine = String(afterFence[afterFence.startIndex..<newline]).trimmingCharacters(in: .whitespaces)
                    remaining = afterFence[afterFence.index(after: newline)...]
                } else {
                    languageLine = ""
                    remaining = afterFence
                }

                let language = languageLine.isEmpty ? nil : languageLine

                // Find closing fence
                if let closeFence = remaining.range(of: "```") {
                    let code = String(remaining[remaining.startIndex..<closeFence.lowerBound])
                    blocks.append(.code(language: language, code: code.hasSuffix("\n") ? String(code.dropLast()) : code))
                    let afterClose = remaining[closeFence.upperBound...]
                    // Skip newline after closing fence
                    if afterClose.first == "\n" {
                        remaining = afterClose[afterClose.index(after: afterClose.startIndex)...]
                    } else {
                        remaining = afterClose
                    }
                } else {
                    // No closing fence, treat rest as code
                    blocks.append(.code(language: language, code: String(remaining)))
                    remaining = remaining[remaining.endIndex...]
                }
            } else {
                // No more fences, rest is text
                let text = String(remaining)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.text(text))
                }
                break
            }
        }

        if blocks.isEmpty {
            blocks.append(.text(content))
        }

        return blocks
    }

    // MARK: - Attributed string for inline markdown

    private func makeAttributedString(from text: String) -> AttributedString {
        // Use SwiftUI's built-in Markdown support via AttributedString(markdown:)
        do {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
            let attributed = try AttributedString(markdown: text, options: options)
            return attributed
        } catch {
            return AttributedString(text)
        }
    }

    // MARK: - Code block view

    private func codeBlock(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                HStack {
                    Text(language)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(AppColors.textMuted)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                            Text("Copy")
                                .font(.caption2)
                        }
                        .foregroundStyle(AppColors.textMuted)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AppColors.codeBubble.opacity(0.5))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(AppColors.textPrimary)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(AppColors.codeBubble)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppColors.surfaceBorder, lineWidth: 1)
        )
    }
}
