import SwiftUI

@main
struct HeartSyncMacApp: App {
    @State private var model = AppModel()

    init() {
        let cutoff = Date.now
        Task.detached(priority: .utility) { _ = ExportDirectory.sweep(createdBefore: cutoff) }
    }

    var body: some Scene {
        Window("HeartSync", id: "main") {
            MacRootView()
                .environment(model)
                .tint(HeartSyncTheme.accent)
                .task { await model.start() }
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1_180, height: 780)
        .commands { HeartSyncNavigationCommands() }

        Settings {
            MacSettingsView()
                .environment(model)
        }
    }
}
