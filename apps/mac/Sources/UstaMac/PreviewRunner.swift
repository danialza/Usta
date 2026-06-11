import Foundation
import AppKit

/// Detects project type in a workspace and spawns the right "run" command,
/// then opens a browser tab if it's a web app. Best-effort — falls back to
/// opening the folder in Finder when nothing obvious is detected.
enum PreviewRunner {
    enum Kind {
        case viteOrNext(port: Int)       // package.json with vite/next/react
        case nodeScript(file: String)    // package.json scripts.start
        case staticSite(file: String)    // index.html, no build tool
        case rustCargo                   // Cargo.toml
        case pythonApp(file: String)     // main.py / app.py
        case dockerCompose               // docker-compose.yml
        case unknown
    }

    /// Inspect `root` and pick the best command to run the project.
    static func detect(at root: String) -> Kind {
        let fm = FileManager.default
        let pkg = root + "/package.json"
        if fm.fileExists(atPath: pkg),
           let data = try? Data(contentsOf: URL(fileURLWithPath: pkg)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let deps = (obj["dependencies"] as? [String: Any]) ?? [:]
            let devDeps = (obj["devDependencies"] as? [String: Any]) ?? [:]
            let all = deps.merging(devDeps) { a, _ in a }
            if all["vite"] != nil { return .viteOrNext(port: 5173) }
            if all["next"] != nil { return .viteOrNext(port: 3000) }
            if let scripts = obj["scripts"] as? [String: String], scripts["dev"] != nil {
                return .viteOrNext(port: 5173)
            }
            if let scripts = obj["scripts"] as? [String: String], scripts["start"] != nil {
                return .nodeScript(file: "npm start")
            }
        }
        if fm.fileExists(atPath: root + "/Cargo.toml") { return .rustCargo }
        if fm.fileExists(atPath: root + "/docker-compose.yml") ||
           fm.fileExists(atPath: root + "/docker-compose.yaml") {
            return .dockerCompose
        }
        for py in ["main.py", "app.py", "server.py"] {
            if fm.fileExists(atPath: root + "/" + py) { return .pythonApp(file: py) }
        }
        if fm.fileExists(atPath: root + "/index.html") {
            return .staticSite(file: "index.html")
        }
        return .unknown
    }

    /// Human-readable summary of what Run would do for this workspace.
    static func describe(at root: String) -> String {
        switch detect(at: root) {
        case .viteOrNext(let p): return "npm run dev → http://localhost:\(p)"
        case .nodeScript:        return "npm start"
        case .staticSite:        return "python3 http.server 8000 → http://localhost:8000"
        case .rustCargo:         return "cargo run"
        case .pythonApp(let f):  return "python3 \(f)"
        case .dockerCompose:     return "docker compose up"
        case .unknown:           return "no runnable target — opens Finder"
        }
    }

    /// Spawn the run command in a detached shell + open browser after a short
    /// delay if it's a web project. Returns immediately.
    static func run(at root: String) {
        let kind = detect(at: root)
        switch kind {
        case .viteOrNext(let port):
            spawnShell(cwd: root, cmd: "npm install --silent 2>/dev/null; npm run dev")
            openAfter(seconds: 4, url: "http://localhost:\(port)")
        case .nodeScript:
            spawnShell(cwd: root, cmd: "npm install --silent 2>/dev/null; npm start")
            openAfter(seconds: 4, url: "http://localhost:3000")
        case .staticSite:
            spawnShell(cwd: root, cmd: "python3 -m http.server 8000")
            openAfter(seconds: 1, url: "http://localhost:8000")
        case .rustCargo:
            spawnShell(cwd: root, cmd: "cargo run --release")
        case .pythonApp(let f):
            spawnShell(cwd: root, cmd: "python3 \(f)")
        case .dockerCompose:
            spawnShell(cwd: root, cmd: "docker compose up")
            openAfter(seconds: 6, url: "http://localhost:8080")
        case .unknown:
            NSWorkspace.shared.open(URL(fileURLWithPath: root))
        }
    }

    private static func spawnShell(cwd: String, cmd: String) {
        // Launch in Terminal.app so the user can see output + Ctrl-C to stop.
        let escaped = cwd.replacingOccurrences(of: "\"", with: "\\\"")
        let cmdEsc = cmd.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "cd \\"\(escaped)\\" && \(cmdEsc)"
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    private static func openAfter(seconds: Double, url: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
    }
}
