import SwiftUI

@main
struct UstaApp: App {
    @StateObject private var client = UstaClientModel()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup("Usta") {
            ContentView()
                .environmentObject(client)
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    client.applySocket(settings.socketPath)
                    if settings.autoSpawnDaemon {
                        _ = DaemonSpawner.spawn(
                            socket: settings.socketPath,
                            anthropicKey: settings.anthropicKey.isEmpty ? nil : settings.anthropicKey,
                            geminiKey: settings.geminiKey.isEmpty ? nil : settings.geminiKey,
                            openaiKey: settings.openaiKey.isEmpty ? nil : settings.openaiKey,
                            ollamaHost: settings.ollamaHost.isEmpty ? nil : settings.ollamaHost
                        )
                        try? await Task.sleep(nanoseconds: 600_000_000)
                    }
                    await client.ensureConnected()
                }
        }
        .defaultSize(width: 1200, height: 760)
        // Hide the title bar — keep traffic lights, drop the "Usta" text
        // strip. Sidebar header has our brand mark already.
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(client)
                .environmentObject(settings)
        }
    }
}
