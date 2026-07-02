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
                    // Auto-restart a STALE daemon: if a daemon from a previous
                    // launch is still holding the socket but its binary has
                    // since been rebuilt, it won't have the latest code. Detect
                    // by comparing the running daemon's start time to the
                    // bundled binary's mtime, and restart if the binary is newer.
                    if settings.autoSpawnDaemon, client.connected, client.daemonStartedMs > 0,
                       let mtime = DaemonSpawner.binaryMtimeMs(),
                       mtime > client.daemonStartedMs + 1000 {
                        let sock = settings.socketPath
                        let aKey = settings.anthropicKey, gKey = settings.geminiKey
                        let oaKey = settings.openaiKey, oHost = settings.ollamaHost
                        await Task.detached(priority: .userInitiated) {
                            DaemonSpawner.stopByProbe(socket: sock)
                            _ = DaemonSpawner.spawn(socket: sock, anthropicKey: aKey,
                                                    geminiKey: gKey, openaiKey: oaKey, ollamaHost: oHost)
                        }.value
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        await client.connect()
                    }
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
