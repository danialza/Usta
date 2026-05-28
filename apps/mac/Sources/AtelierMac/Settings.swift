import Foundation
import SwiftUI

/// User-tweakable settings persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    @Published var socketPath: String { didSet { save(Self.socketKey, socketPath) } }
    @Published var anthropicKey: String { didSet { save(Self.anthKey, anthropicKey) } }
    @Published var geminiKey: String { didSet { save(Self.gemKey, geminiKey) } }
    @Published var ollamaHost: String { didSet { save(Self.ollamaKey, ollamaHost) } }
    @Published var autoSpawnDaemon: Bool { didSet { UserDefaults.standard.set(autoSpawnDaemon, forKey: Self.autoSpawnKey) } }

    private static let socketKey = "atelier.socketPath"
    private static let anthKey = "atelier.anthropicKey"
    private static let gemKey = "atelier.geminiKey"
    private static let ollamaKey = "atelier.ollamaHost"
    private static let autoSpawnKey = "atelier.autoSpawnDaemon"

    private func save(_ k: String, _ v: String) { UserDefaults.standard.set(v, forKey: k) }

    init() {
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        self.socketPath = d.string(forKey: Self.socketKey) ?? Self.defaultSocketPath()
        self.anthropicKey = d.string(forKey: Self.anthKey) ?? (env["ANTHROPIC_API_KEY"] ?? "")
        self.geminiKey = d.string(forKey: Self.gemKey) ?? (env["GEMINI_API_KEY"] ?? "")
        self.ollamaHost = d.string(forKey: Self.ollamaKey) ?? (env["OLLAMA_HOST"] ?? "http://127.0.0.1:11434")
        self.autoSpawnDaemon = d.object(forKey: Self.autoSpawnKey) as? Bool ?? true
    }

    static func defaultSocketPath() -> String {
        if let s = ProcessInfo.processInfo.environment["ATELIER_SOCKET"], !s.isEmpty { return s }
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        return (tmp as NSString).appendingPathComponent("atelier.sock")
    }
}

/// Talks to a local Ollama daemon over HTTP for model management.
@MainActor
final class OllamaManager: ObservableObject {
    @Published var installed: [String] = []
    @Published var status: String = ""
    @Published var pulling: Bool = false

    func host(_ base: String) -> URL? { URL(string: base) }

    func refresh(base: String) async {
        guard let url = URL(string: "\(base)/api/tags") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = (obj?["models"] as? [[String: Any]]) ?? []
            installed = models.compactMap { $0["name"] as? String }.sorted()
            status = installed.isEmpty ? "no models installed" : ""
        } catch {
            installed = []
            status = "ollama not reachable at \(base)"
        }
    }

    func pull(base: String, model: String) async {
        guard !model.isEmpty, let url = URL(string: "\(base)/api/pull") else { return }
        pulling = true; status = "pulling \(model)…"
        defer { pulling = false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": model, "stream": true])
        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: req)
            for try await line in bytes.lines {
                if let d = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    if let s = obj["status"] as? String { status = s }
                    if let err = obj["error"] as? String { status = "error: \(err)"; return }
                }
            }
            status = "pulled \(model) ✓"
            await refresh(base: base)
        } catch {
            status = "pull failed: \(error.localizedDescription)"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var client: AtelierClientModel
    @StateObject private var ollama = OllamaManager()
    @State private var status: String? = nil
    @State private var pullModel: String = "qwen2.5-coder:7b"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.title2.bold())

                daemonBox
                anthropicBox
                geminiBox
                ollamaBox

                if let s = status {
                    Text(s).font(.caption).foregroundStyle(.green)
                }
            }
            .padding(24)
        }
        .frame(width: 560, height: 640)
        .background(AtelierTheme.bg)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task { await ollama.refresh(base: settings.ollamaHost) }
    }

    private var daemonBox: some View {
        GroupBox("Daemon") {
            VStack(alignment: .leading, spacing: 8) {
                labeledField("Socket", "/tmp/atelier.sock", $settings.socketPath)
                Toggle("Auto-start daemon on launch", isOn: $settings.autoSpawnDaemon)
                HStack(spacing: 8) {
                    Button("Restart daemon") {
                        DaemonSpawner.stopByProbe(socket: settings.socketPath)
                        _ = DaemonSpawner.spawn(
                            socket: settings.socketPath,
                            anthropicKey: settings.anthropicKey,
                            geminiKey: settings.geminiKey,
                            ollamaHost: settings.ollamaHost
                        )
                        status = "restarted — give it ~1s, then Reconnect"
                    }
                    Button("Reconnect") {
                        Task {
                            await client.connect()
                            status = client.connected ? "connected (v\(client.daemonVersion ?? "?"))" : (client.lastError ?? "failed")
                        }
                    }
                }
                Text("Keys are passed to the daemon when you start it from here. After changing a key, Restart daemon.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var anthropicBox: some View {
        GroupBox("Anthropic") {
            VStack(alignment: .leading, spacing: 6) {
                Text("ANTHROPIC_API_KEY").font(.caption).foregroundStyle(.secondary)
                SecureField("sk-ant-…", text: $settings.anthropicKey).textFieldStyle(.roundedBorder)
                Text("console.anthropic.com → API keys").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    private var geminiBox: some View {
        GroupBox("Google Gemini (free tier)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("GEMINI_API_KEY").font(.caption).foregroundStyle(.secondary)
                SecureField("AIza…", text: $settings.geminiKey).textFieldStyle(.roundedBorder)
                Text("aistudio.google.com → Get API key (free)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    private var ollamaBox: some View {
        GroupBox("Ollama (local, free)") {
            VStack(alignment: .leading, spacing: 8) {
                labeledField("Host", "http://127.0.0.1:11434", $settings.ollamaHost)
                HStack {
                    Button("Refresh") { Task { await ollama.refresh(base: settings.ollamaHost) } }
                    Spacer()
                    if !ollama.status.isEmpty {
                        Text(ollama.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if !ollama.installed.isEmpty {
                    Text("Installed").font(.caption).foregroundStyle(.secondary)
                    ForEach(ollama.installed, id: \.self) { m in
                        HStack { Image(systemName: "cube.box").foregroundStyle(.tint); Text(m).font(.caption) }
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    TextField("qwen2.5-coder:7b", text: $pullModel).textFieldStyle(.roundedBorder)
                    Button {
                        Task { await ollama.pull(base: settings.ollamaHost, model: pullModel) }
                    } label: {
                        if ollama.pulling { ProgressView().scaleEffect(0.6) } else { Text("Pull") }
                    }
                    .disabled(ollama.pulling)
                }
                Text("Coder models with tool-calling: qwen2.5-coder:7b, llama3.1:8b")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    private func labeledField(_ label: String, _ placeholder: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading).font(.caption)
            TextField(placeholder, text: binding).textFieldStyle(.roundedBorder)
        }
    }
}
