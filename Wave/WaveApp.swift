import SwiftUI

@main
struct WaveApp: App {
    let contentView = ContentView()

    var body: some Scene {
        WindowGroup {
            contentView
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    contentView.saveAllTabsSync()
                }
        }
    }
}
