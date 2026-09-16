import SwiftUI

@main
struct DragonKControlApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DragonK Control", id: "main") {
            MainView(model: model)
        }
            .defaultSize(width: 1160, height: 900)

        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            MenuBarLoadIcon(value: model.loadPercentage)
        }
        .menuBarExtraStyle(.window)
    }
}
