import AppKit
import SwiftUI

@main
struct OrbitSlimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = DeviceStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
                .environment(store)
        } label: {
            Image(systemName: "circle.hexagongrid.fill")
                .accessibilityLabel("OrbitSlim")
                .task {
                    AppLog.write("menu bar label task")
                    store.startPolling()
                    await store.refresh()
                }
        }
        .menuBarExtraStyle(.window)

        Window("OrbitSlim", id: "manager") {
            ManagerView(store: store)
                .environment(store)
        }
        .defaultSize(width: 780, height: 680)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
