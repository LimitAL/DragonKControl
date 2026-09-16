import SwiftUI

@main
struct DragonKControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("DragonK Control", id: "main") {
            MainView(model: appDelegate.model)
                .background(AppLifecycleBridge(appDelegate: appDelegate))
        }
            .defaultSize(width: 1160, height: 900)
    }
}
