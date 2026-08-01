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
    @Published var openaiKey: String {
        didSet {
            let t = openaiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if t != openaiKey { openaiKey = t; return }
            Keychain.set(openaiKey, account: Self.oaiKey)
        }
    }
    @Published var ollamaHost: String { didSet { save(Self.ollamaKey, ollamaHost) } }
    @Published var autoSpawnDaemon: Bool { didSet { UserDefaults.standard.set(autoSpawnDaemon, forKey: Self.autoSpawnKey) } }

    private static let socketKey = "usta.socketPath"
    private static let anthKey = "usta.anthropicKey"
    private static let gemKey = "usta.geminiKey"
    private static let oaiKey = "usta.openaiKey"
    private static let ollamaKey = "usta.ollamaHost"
    private static let autoSpawnKey = "usta.autoSpawnDaemon"

    private func save(_ k: String, _ v: String) { UserDefaults.standard.set(v, forKey: k) }

    /// Fingerprint of everything that, when changed, needs a daemon restart.
    var snapshotKey: String {
        [anthropicKey, geminiKey, openaiKey, ollamaHost, socketPath].joined(separator: "|")
    }

    init() {
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        self.socketPath = d.string(forKey: Self.socketKey) ?? Self.defaultSocketPath()
        self.ollamaHost = d.string(forKey: Self.ollamaKey) ?? (env["OLLAMA_HOST"] ?? "http://127.0.0.1:11434")
        self.autoSpawnDaemon = d.object(forKey: Self.autoSpawnKey) as? Bool ?? true
        // Keychain reads are deliberately NOT done here. On an ad-hoc-signed
        // build every rebuild changes the code signature, so the first read
        // pops an authorization dialog — and doing that from init() blocks
        // scene instantiation, leaving the app running with no window until
        // someone finds the hidden prompt. Seed from the environment now and
        // load the stored keys off the main thread in `loadKeys()`.
        self.anthropicKey = (env["ANTHROPIC_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.geminiKey    = (env["GEMINI_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.openaiKey    = (env["OPENAI_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True once the Keychain values have been merged in. The daemon spawn
    /// waits on this so it doesn't start with empty keys.
    @Published private(set) var keysLoaded = false

    /// Pull the stored API keys off the main thread. Safe to call more than
    /// once; only the first call does work.
    func loadKeys() async {
        if keysLoaded { return }
        let anth = Self.anthKey, gem = Self.gemKey, oai = Self.oaiKey
        let (kcA, kcG, kcO) = await Task.detached(priority: .userInitiated) {
            (Keychain.get(account: anth), Keychain.get(account: gem), Keychain.get(account: oai))
        }.value

        let d = UserDefaults.standard
        // One-time migration of the pre-Keychain plaintext values.
        let legacyA = d.string(forKey: Self.anthKey)
        let legacyG = d.string(forKey: Self.gemKey)
        let rawA = kcA ?? legacyA
        let rawG = kcG ?? legacyG

        // Only overwrite when the Keychain actually had something — otherwise
        // an env-provided key would be wiped.
        if let v = rawA?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { anthropicKey = v }
        if let v = rawG?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { geminiKey = v }
        if let v = kcO?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { openaiKey = v }

        if kcA == nil, let l = legacyA, !l.isEmpty {
            Keychain.set(l.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.anthKey)
            d.removeObject(forKey: Self.anthKey)
        }
        if kcG == nil, let l = legacyG, !l.isEmpty {
            Keychain.set(l.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.gemKey)
            d.removeObject(forKey: Self.gemKey)
        }
        keysLoaded = true
    }

    static func defaultSocketPath() -> String {
        if let s = ProcessInfo.processInfo.environment["USTA_SOCKET"], !s.isEmpty { return s }
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        return (tmp as NSString).appendingPathComponent("usta.sock")
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

    // Snapshot keys/host at sheet open so we can detect changes on Done
    @State private var openSnapshot: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.title2.bold())

                daemonBox
                anthropicBox
                openaiBox
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
                Button("Done") {
                    let current = settings.snapshotKey
                    let changed = current != openSnapshot
                    dismiss()
                    if changed {
                        let sock = settings.socketPath
                        let aKey = settings.anthropicKey
                        let gKey = settings.geminiKey
                        let oaKey = settings.openaiKey
                        let oHost = settings.ollamaHost
                        Task {
                            await Task.detached(priority: .userInitiated) {
                                DaemonSpawner.stopByProbe(socket: sock)
                                _ = DaemonSpawner.spawn(
                                    socket: sock,
                                    anthropicKey: aKey,
                                    geminiKey: gKey,
                                    openaiKey: oaKey,
                                    ollamaHost: oHost
                                )
                            }.value
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            await client.connect()
                        }
                    }
                }
            }
        }
        .task {
            openSnapshot = settings.snapshotKey
            await ollama.refresh(base: settings.ollamaHost)
        }
    }

    private var daemonBox: some View {
        GroupBox("Daemon") {
            VStack(alignment: .leading, spacing: 8) {
                labeledField("Socket", "/tmp/usta.sock", $settings.socketPath)
                Toggle("Auto-start daemon on launch", isOn: $settings.autoSpawnDaemon)
                HStack(spacing: 8) {
                    Button("Restart daemon") {
                        status = "killing old daemon…"
                        let sock = settings.socketPath
                        let aKey = settings.anthropicKey
                        let gKey = settings.geminiKey
                        let oaKey = settings.openaiKey
                        let oHost = settings.ollamaHost
                        Task {
                            await Task.detached(priority: .userInitiated) {
                                DaemonSpawner.stopByProbe(socket: sock)
                                _ = DaemonSpawner.spawn(
                                    socket: sock,
                                    anthropicKey: aKey,
                                    geminiKey: gKey,
                                    openaiKey: oaKey,
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
                    .help("Reveal ustad.log in Finder")
                    Button("Tail Log") {
                        let url = DaemonSpawner.logFileURL()
                        let task = Process()
                        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        task.arguments = ["-a", "Console", url.path]
                        try? task.run()
                    }
                    .help("Open ustad.log in Console.app")
                }
                Text("Daemon log: ~/Library/Logs/Usta/ustad.log · Auto-rotates at 4 MB")
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

    private var openaiBox: some View {
        GroupBox("OpenAI") {
            VStack(alignment: .leading, spacing: 6) {
                Text("OPENAI_API_KEY").font(.caption).foregroundStyle(.secondary)
                SecureField("sk-…", text: $settings.openaiKey).textFieldStyle(.roundedBorder)
                Text("platform.openai.com → API keys").font(.caption2).foregroundStyle(.tertiary)
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
