import Foundation

/// Locates the `atelierd` binary and (optionally) launches it.
///
/// Search order:
///   1. ATELIERD_BIN env var
///   2. ~/.local/bin/atelierd
///   3. Sibling of the running app bundle's executable
///   4. <repo>/target/debug/atelierd  (dev mode — climbs up from CWD/exe)
enum DaemonSpawner {
    static func locateBinary() -> URL? {
        let fm = FileManager.default

        if let p = ProcessInfo.processInfo.environment["ATELIERD_BIN"], !p.isEmpty {
            let u = URL(fileURLWithPath: p)
            if fm.isExecutableFile(atPath: u.path) { return u }
        }

        let home = fm.homeDirectoryForCurrentUser
        let userLocal = home.appendingPathComponent(".local/bin/atelierd")
        if fm.isExecutableFile(atPath: userLocal.path) { return userLocal }

        let exe = Bundle.main.executableURL?.deletingLastPathComponent()
        if let exe {
            let sibling = exe.appendingPathComponent("atelierd")
            if fm.isExecutableFile(atPath: sibling.path) { return sibling }
        }

        // Dev fallback: walk up from current_exe looking for target/debug/atelierd
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("target/debug/atelierd")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        // Also try CWD-based lookup.
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let cwdCandidate = cwd.appendingPathComponent("target/debug/atelierd")
        if fm.isExecutableFile(atPath: cwdCandidate.path) { return cwdCandidate }

        return nil
    }

    /// Spawn the daemon detached. Returns the launched URL on success.
    @discardableResult
    static func spawn(socket: String, anthropicKey: String? = nil) -> URL? {
        guard let bin = locateBinary() else { return nil }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["--socket", socket]

        var env = ProcessInfo.processInfo.environment
        if let key = anthropicKey, !key.isEmpty {
            env["ANTHROPIC_API_KEY"] = key
        }
        proc.environment = env

        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
            return bin
        } catch {
            return nil
        }
    }
}
