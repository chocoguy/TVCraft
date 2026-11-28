// TVCraft Installer: builds TVCraft from the player's own Minecraft PE 0.8.1 APK, at a GitHub release
// tag, and installs it on their Apple TVs (never opening it); updates them all when a new release of its
// major version comes out. Distributed signed and notarized (tools/release.sh). It doesn't update
// itself: a new major version is a new installer, which it links to. Derived from Frontline Rewritten's
// installer.

import AppKit
import SwiftUI

@main
struct InstallerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("TVCraft Installer", id: "main") {
            ContentView()
                .environmentObject(model)
                .tint(.brand)
                .task { model.start() }
        }
    }
}

extension Color {
    /// TVCraft's accent (Assets.xcassets/AccentColor: #C6E9AF light, #2D5DA4 dark). Set as the tint too,
    /// because the asset catalog's accent alone gives way to an accent color chosen in System Settings.
    static let brand = Color("AccentColor", bundle: .main)
}
