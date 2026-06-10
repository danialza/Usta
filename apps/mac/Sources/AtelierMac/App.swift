import SwiftUI

@main
struct AtelierApp: App {
    @StateObject private var client = AtelierClientModel()
    @StateObject private var settings = AppSettings()
    @StateObject private var appearance = AppearanceManager.shared

    var body: some Scene {
        WindowGroup("Atelier") {
            ContentView()
                .environmentObject(client)
                .environmentObject(settings)
                .environmentObject(appearance)
                .preferredColorScheme(appearance.preferred)
                .id(appearance.mode)         // force redraw on toggle
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    client.applySocket(settings.socketPath)
                    if settings.autoSpawnDaemon {
                        _ = DaemonSpawner.spawn(
                            socket: settings.socketPath,
                            anthropicKey: settings.anthropicKey.isEmpty ? nil : settings.anthropicKey,
                            geminiKey: settings.geminiKey.isEmpty ? nil : settings.geminiKey,
                            ollamaHost: settings.ollamaHost.isEmpty ? nil : settings.ollamaHost
                        )
                        try? await Task.sleep(nanoseconds: 600_000_000)
                    }
                    await client.ensureConnected()
                }
        }
        .defaultSize(width: 1200, height: 760)

        Settings {
            SettingsView()
                .environmentObject(client)
                .environmentObject(settings)
        }
    }
}
