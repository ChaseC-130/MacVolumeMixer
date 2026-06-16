import SwiftUI
import AppKit

@main
struct VolumeMixerApp: App {
    // The delegate owns the MixerManager so taps live for the whole app
    // lifetime, independent of whether the menu popover is open.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MixerView(manager: appDelegate.manager)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = MixerManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Safe place to touch NSApp (unlike App.init, where it is nil). Belt and
        // suspenders alongside LSUIElement: keep us a menu-bar-only agent.
        NSApp.setActivationPolicy(.accessory)
        manager.start()
    }
}
