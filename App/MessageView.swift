import SwiftUI
import UIKit
import MagpieCore

struct MessageView: View {
    let message: ChatMessage
    let onRetry: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isUser: Bool { message.role == .user }
    private var isRetryable: Bool {
        message.role == .assistant && (message.status == .failed || message.status == .stopped)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 8 : 26) }
            VStack(alignment: .leading, spacing: 10) {
                header
                if message.text.isEmpty && message.status == .streaming {
                    Text("正在思考…")
                        .foregroundStyle(.secondary)
                        .italic()
                        .accessibilityLabel("正在生成回复")
                } else if !message.text.isEmpty {
                    RichMessageText(text: message.text)
                }
                if isRetryable, let onRetry {
                    Button(action: onRetry) {
                        Label("重试此回复", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .accessibilityHint("会替换这条未完成的回复，不会重复发送你的消息")
                }
            }
            .padding(dynamicTypeSize.isAccessibilitySize ? 11 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isUser ? Color(red: 0.95, green: 0.91, blue: 0.85) : Color.white.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if !message.text.isEmpty {
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("复制整条消息")
                    .padding(4)
                }
            }
            if !isUser { Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 8 : 26) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isUser ? "你的消息" : "Magpie 回复")
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text(isUser ? "你" : "MAGPIE")
                .font(.caption2.weight(.bold))
                .tracking(1.3)
            if let route = message.routedModel, !route.isEmpty {
                Text(route)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 4)
            if message.status == .streaming {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("生成中")
            } else if message.status == .stopped {
                Label("已停止", systemImage: "stop.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if message.status == .failed {
                Label("未完成", systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.trailing, message.text.isEmpty ? 0 : 30)
    }
}

private struct RichMessageText: View {
    let text: String

    var body: some View {
        Group {
            if text.contains("```") {
                MarkdownBlocks(text: text)
            } else {
                Text(markdown(text))
                    .textSelection(.enabled)
            }
        }
        .font(.body)
        .lineSpacing(4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func markdown(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value)) ?? AttributedString(value)
    }
}

private struct MarkdownBlocks: View {
    let text: String

    private var blocks: [Block] {
        var result: [Block] = []
        var code = false
        var language: String?
        var buffer: [String] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(Block(code: code, language: language, value: buffer.joined(separator: "\n")))
            buffer.removeAll()
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                if code {
                    language = nil
                } else {
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                }
                code.toggle()
            } else {
                buffer.append(line)
            }
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.code {
                    CodeBlock(block: block)
                } else if !block.value.isEmpty {
                    Text((try? AttributedString(markdown: block.value)) ?? AttributedString(block.value))
                        .textSelection(.enabled)
                }
            }
        }
    }

    fileprivate struct Block {
        let code: Bool
        let language: String?
        let value: String
    }
}

private struct CodeBlock: View {
    let block: MarkdownBlocks.Block

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(block.language?.uppercased() ?? "代码")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = block.value
                } label: {
                    Label("复制代码", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)

            ScrollView(.horizontal) {
                Text(block.value)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
            }
        }
        .background(Color(red: 0.15, green: 0.16, blue: 0.17).opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
