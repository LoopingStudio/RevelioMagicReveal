import SwiftUI

@main
struct RevelioNoelApp: App {
    @State private var model = AppModel(launch: LaunchOptions())

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
        }
    }
}
