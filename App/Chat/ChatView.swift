import SwiftUI

struct ChatPane: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    private let suggestions = ["🐍 做个贪吃蛇", "🧱 做个俄罗斯方块", "🪖 做个坦克大战", "🔢 做个 2048"]

    var body: some View {
        let session = model.currentSession
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(session.entries) { entry in
                            EntryRow(entry: entry).id(entry.id)
                        }
                        if session.isRunning {
                            WorkingIndicator(since: session.turnStartedAt, notice: session.retryNotice).id("working")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: session.revision) {
                    proxy.scrollTo(session.isRunning ? "working" : session.entries.last?.id as AnyHashable?, anchor: .bottom)
                }
            }
            .overlay {
                if session.entries.isEmpty && !session.isRunning { emptyState }
            }

            Divider()
            inputBar(session)
        }
        .background(.background)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("想做个什么？")
                .font(.title3.weight(.semibold))
            ForEach(suggestions, id: \.self) { s in
                Button(s) { submit(String(s.dropFirst(2))) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
    }

    private func inputBar(_ session: ChatSession) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(model.currentAppId == nil ? "描述一个新应用…" : "继续修改这个应用…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .padding(.vertical, 8)
                .onSubmit { submit(draft) }
                .disabled(session.isRunning)
            if session.isRunning {
                Button { model.cancel() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .help("停止")
            } else {
                Button { submit(draft) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.isEmpty ? Color.secondary : Color.accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("发送 (Return)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func submit(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await model.send(text) }
    }
}

private struct EntryRow: View {
    let entry: ChatEntry

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(entry.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .assistant:
            Text(markdown(entry.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            ToolRow(entry: entry)
        case .status:
            Label(entry.text, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

private struct ToolRow: View {
    let entry: ChatEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: ToolPresentation.symbol(for: entry.toolName))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(entry.text)
                    .font(.callout.weight(.medium))
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(entry.state == .failed ? .red : .secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                switch entry.state {
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark").foregroundStyle(.red)
                }
            }
            if entry.state == .running && !entry.codeTail.isEmpty {
                Text(entry.codeTail.split(separator: "\n", omittingEmptySubsequences: false).suffix(12).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct WorkingIndicator: View {
    let since: Date?
    let notice: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("工作中 · \(Int(context.date.timeIntervalSince(since ?? context.date))) 秒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
