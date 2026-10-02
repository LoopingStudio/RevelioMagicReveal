import SwiftUI

@main
struct RevelioMagicRevealApp: App {
    @State private var model = AppModel(launch: LaunchOptions())

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
        }
    }
}
