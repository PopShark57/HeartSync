import SwiftUI

@main
struct HeartSyncApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:     Task { await model.refresh() }
            case .background: Task { await model.enterBackground() }
            default:          break
            }
        }
    }
}
