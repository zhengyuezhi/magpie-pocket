import SwiftUI

@main
struct MagpiePocketApp: App {
    @StateObject private var settings = AppSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .preferredColorScheme(.light)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        NotificationCenter.default.post(name: .magpieDidEnterBackground, object: nil)
                    }
                }
        }
    }
}

extension Notification.Name {
    static let magpieDidEnterBackground = Notification.Name("magpieDidEnterBackground")
}
