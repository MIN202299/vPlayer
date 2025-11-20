import SwiftUI
import AppKit

/// Ensures the app shows its Dock icon and uses the bundled asset.
private func configureApplicationAppearance() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let bundle = Bundle.module
    if
        let iconURL = bundle.url(forResource: "AppIcon", withExtension: "icns") ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
        let icon = NSImage(contentsOf: iconURL)
    {
        application.applicationIconImage = icon
    }
}

@main
struct SimpleVideoPlayerApp: App {
    init() {
        configureApplicationAppearance()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(VisualEffectBlur(material: .sidebar, blendingMode: .behindWindow))
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { } // Customize menu if needed
        }
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
