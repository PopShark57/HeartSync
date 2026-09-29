import SwiftUI
import UIKit

@main
struct HeartSyncApp: App {
    /// Owns the root model, so launch-time setup can run before any scene exists.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.model)
                .tint(HeartSyncTheme.accent)
                // Already started at launch; kept so a retry path and previews still start.
                .task { await appDelegate.model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:     Task { await appDelegate.model.refresh() }
            case .background: Task { await appDelegate.model.enterBackground() }
            default:          break
            }
        }
    }
}

/// The launch hook the transports need (improvement 53).
///
/// When iOS relaunches HeartSync in the background, to hand back a restored Bluetooth link
/// or to deliver new Health samples, no view's `.task` is guaranteed to run. Apple's
/// restoration and background-delivery contracts both ask for the central manager and the
/// observer queries to be set up during launch, so that happens here, and loading the
/// history starts here too.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Scene-based apps receive nil launch options even for a Bluetooth restoration, so
        // the central is created unconditionally, with its restoration identifier.
        model.launch()
        Task { await model.start() }
        return true
    }
}
