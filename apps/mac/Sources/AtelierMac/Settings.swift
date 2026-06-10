import Foundation
import SwiftUI

/// User-tweakable settings persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    @Published var socketPath: String { didSet { save(Self.socketKey, socketPath) } }
    // API keys live in the Keychain, NOT UserDefaults. The published value is
    // an in-memory mirror; didSet writes through to the Keychain.
    @Published var anthropicKey: String {
        didSet {
            let t = anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if t != anthropicKey { anthropicKey = t; return } // re-trigger w/ trimmed
            Keychain.set(anthropicKey, account: Self.anthKey)
        }
    }
    @Published var geminiKey: String {
        didSet {
            let t = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if t != geminiKey { geminiKey = t; return }
            Keychain.set(geminiKey, account: Self.gemKey)
        }
    }
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
        // Keys: prefer Keychain, then migrate any legacy plaintext UserDefaults
        // value into the Keychain and scrub it from defaults.
        let kcA = Keychain.get(account: Self.anthKey)
        let kcG = Keychain.get(account: Self.gemKey)
        let legacyA = d.string(forKey: Self.anthKey)
        let legacyG = d.string(forKey: Self.gemKey)
        let rawA = kcA ?? legacyA ?? (env["ANTHROPIC_API_KEY"] ?? "")
        let rawG = kcG ?? legacyG ?? (env["GEMINI_API_KEY"] ?? "")
        self.anthropicKey = rawA.trimmingCharacters(in: .whitespacesAndNewlines)
        self.geminiKey    = rawG.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ollamaHost = d.string(forKey: Self.ollamaKey) ?? (env["OLLAMA_HOST"] ?? "http://127.0.0.1:11434")
        self.autoSpawnDaemon = d.object(forKey: Self.autoSpawnKey) as? Bool ?? true
        // One-time migration: if a legacy plaintext key existed, persist it to
        // the Keychain and remove the cleartext copy.
        if kcA == nil, let l = legacyA, !l.isEmpty {
            Keychain.set(l.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.anthKey)
            d.removeObject(forKey: Self.anthKey)
        }
        if kcG == nil, let l = legacyG, !l.isEmpty {
            Keychain.set(l.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.gemKey)
            d.removeObject(forKey: Self.gemKey)
        }
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
    @Published var reachable: Bool = false
    /// 0…1 download progress for active layer (-1 if indeterminate)
    @Published var progress: Double = -1
    @Published var progressLabel: String = ""

    func host(_ base: String) -> URL? { URL(string: base) }

    func refresh(base: String) async {
        guard let url = URL(string: "\(base)/api/tags") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = (obj?["models"] as? [[String: Any]]) ?? []
            installed = models.compactMap { $0["name"] as? String }.sorted()
            reachable = true
            status = installed.isEmpty ? "ollama running — no models pulled yet" : ""
        } catch {
            installed = []
            reachable = false
            status = "ollama not reachable at \(base) — install: brew install ollama && brew services start ollama"
        }
    }

    func pull(base: String, model: String) async {
        guard !model.isEmpty, let url = URL(string: "\(base)/api/pull") else { return }
        pulling = true; status = "starting pull \(model)…"; progress = -1; progressLabel = ""
        defer { pulling = false; progress = -1; progressLabel = "" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": model, "stream": true])
        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: req)
            for try await line in bytes.lines {
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { continue }
                if let err = obj["error"] as? String { status = "error: \(err)"; return }
                let s = (obj["status"] as? String) ?? ""
                // Layer download: status often "pulling <digest>" with total+completed.
                if let total = obj["total"] as? Int64, total > 0 {
                    let done = (obj["completed"] as? Int64) ?? 0
                    let pct = Double(done) / Double(total)
                    progress = pct
                    let mbDone = Double(done) / 1_048_576
                    let mbTot  = Double(total) / 1_048_576
                    let layer = s.hasPrefix("pulling ") ? String(s.dropFirst(8).prefix(12)) : s
                    progressLabel = String(format: "%@ — %.0f/%.0f MB (%.0f%%)",
                                           layer, mbDone, mbTot, pct * 100)
                    status = "downloading \(model)"
                } else if !s.isEmpty {
                    // verifying / writing manifest / success
                    progress = -1
                    progressLabel = s
                    status = s
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
    @EnvironmentObject var client: UstaClientModel
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
        .background(UstaTheme.bg)
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
                        status = "killing old daemon…"
                        let sock = settings.socketPath
                        let aKey = settings.anthropicKey
                        let gKey = settings.geminiKey
                        let oHost = settings.ollamaHost
                        Task {
                            await Task.detached(priority: .userInitiated) {
                                DaemonSpawner.stopByProbe(socket: sock)
                                _ = DaemonSpawner.spawn(
                                    socket: sock,
                                    anthropicKey: aKey,
                                    geminiKey: gKey,
                                    ollamaHost: oHost
                                )
                            }.value
                            // give daemon ~800ms to bind
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            await client.connect()
                            status = client.connected
                                ? "restarted + connected (v\(client.daemonVersion ?? "?"))"
                                : (client.lastError ?? "restart failed")
                        }
                    }
                    Button("Reconnect") {
                        Task {
                            await client.connect()
                            status = client.connected ? "connected (v\(client.daemonVersion ?? "?"))" : (client.lastError ?? "failed")
                        }
                    }
                    Button("Show Log") {
                        NSWorkspace.shared.activateFileViewerSelecting([DaemonSpawner.logFileURL()])
                    }
                    .help("Reveal atelierd.log in Finder")
                    Button("Tail Log") {
                        let url = DaemonSpawner.logFileURL()
                        let task = Process()
                        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        task.arguments = ["-a", "Console", url.path]
                        try? task.run()
                    }
                    .help("Open atelierd.log in Console.app")
                }
                Text("Daemon log: ~/Library/Logs/Usta/atelierd.log · Auto-rotates at 4 MB")
                    .font(.caption2).foregroundStyle(.secondary)
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
                    TextField("qwen2.5-coder:1.5b", text: $pullModel).textFieldStyle(.roundedBorder)
                    Button {
                        Task { await ollama.pull(base: settings.ollamaHost, model: pullModel) }
                    } label: {
                        if ollama.pulling { ProgressView().scaleEffect(0.6) } else { Text("Pull") }
                    }
                    .disabled(ollama.pulling || !ollama.reachable)
                }
                if ollama.pulling {
                    VStack(alignment: .leading, spacing: 4) {
                        if ollama.progress >= 0 {
                            ProgressView(value: ollama.progress)
                                .progressViewStyle(.linear)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        Text(ollama.progressLabel.isEmpty ? "preparing…" : ollama.progressLabel)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text("Quick test:").font(.caption2).foregroundStyle(.secondary)
                    Button("qwen2.5-coder:1.5b") { pullModel = "qwen2.5-coder:1.5b" }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.tint)
                    Text("·").font(.caption2).foregroundStyle(.tertiary)
                    Button("llama3.2:3b") { pullModel = "llama3.2:3b" }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.tint)
                }
                if !ollama.reachable {
                    Text("⚠︎ Ollama not running. Install: `brew install ollama` then `brew services start ollama` (or open Ollama.app).")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Fast/tiny: qwen2.5-coder:1.5b (~1GB) — has tool-calling. Bigger: 7b, llama3.1:8b. Ollama is local & free, runs separately from Usta.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
