import AppKit
import SwiftUI

@main
struct IELTSVocabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 560, idealWidth: 640, maxWidth: .infinity,
                       minHeight: 480, idealHeight: 560, maxHeight: .infinity)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 640, height: 540)

        Settings {
            SettingsView()
        }
    }
}
