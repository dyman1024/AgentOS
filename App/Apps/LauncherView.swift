import SwiftUI

/// Shown in the runtime pane when no app is open: saved apps as a grid.
struct LauncherView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Text("AgentOS")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("在右侧描述你想要的应用，它会直接出现在这里")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 60)

                if !model.registry.apps.isEmpty {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(model.registry.apps) { app in
                            Button { model.open(app.id) } label: { AppIcon(app: app) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("删除", role: .destructive) { model.delete(app.id) }
                                }
                        }
                    }
                    .padding(.horizontal, 40)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 40)
        }
        .background(.background)
    }
}

private struct AppIcon: View {
    let app: AppManifest

    var body: some View {
        VStack(spacing: 10) {
            Text(app.icon)
                .font(.system(size: 44))
                .frame(width: 84, height: 84)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(app.title)
                .font(.callout)
                .lineLimit(1)
            Text(app.updatedAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
