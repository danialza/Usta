import Foundation
import SwiftUI

/// User-tweakable settings persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    @Published var socketPath: String {
        didSet { UserDefaults.standard.set(socketPath, forKey: Self.socketKey) }
    }
    @Published var anthropicKey: String {
        didSet { UserDefaults.standard.set(anthropicKey, forKey: Self.keyKey) }
    }
    @Published var autoSpawnDaemon: Bool {
        didSet { UserDefaults.standard.set(autoSpawnDaemon, forKey: Self.autoSpawnKey) }
    }

    private static let socketKey = "atelier.socketPath"
    private static let keyKey = "atelier.anthropicKey"
    private static let autoSpawnKey = "atelier.autoSpawnDaemon"

    init() {
        let d = UserDefaults.standard
        self.socketPath = d.string(forKey: Self.socketKey) ?? Self.defaultSocketPath()
        self.anthropicKey = d.string(forKey: Self.keyKey) ?? (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")
        self.autoSpawnDaemon = d.object(forKey: Self.autoSpawnKey) as? Bool ?? true
    }

    static func defaultSocketPath() -> String {
        if let s = ProcessInfo.processInfo.environment["ATELIER_SOCKET"], !s.isEmpty { return s }
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        return (tmp as NSString).appendingPathComponent("atelier.sock")
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var client: AtelierClientModel
    @State private var status: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2.bold())

            GroupBox("Daemon") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Socket").frame(width: 80, alignment: .leading)
                        TextField("/tmp/atelier.sock", text: $settings.socketPath)
                            .textFieldStyle(.roundedBorder)
                    }
                    Toggle("Auto-start daemon on launch", isOn: $settings.autoSpawnDaemon)
                    HStack(spacing: 8) {
                        Button("Start daemon now") {
                            _ = DaemonSpawner.spawn(socket: settings.socketPath, anthropicKey: settings.anthropicKey)
                            status = "spawn attempted — give it ~1s, then Reconnect"
                        }
                        Button("Reconnect") {
                            Task {
                                await client.connect()
                                status = client.connected ? "connected (v\(client.daemonVersion ?? "?"))" : (client.lastError ?? "failed")
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Providers") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ANTHROPIC_API_KEY (passed to daemon you spawn from here)")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("sk-ant-…", text: $settings.anthropicKey)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.vertical, 4)
            }

            if let s = status {
                Text(s).font(.caption).foregroundStyle(.green)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
