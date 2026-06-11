import Foundation

/// Locates the `ustad` binary and (optionally) launches it.
///
/// Search order:
///   1. ATELIERD_BIN env var
///   2. ~/.local/bin/ustad
///   3. Sibling of the running app bundle's executable
///   4. <repo>/target/debug/ustad  (dev mode — climbs up from CWD/exe)
enum DaemonSpawner {
    static func locateBinary() -> URL? {
        let fm = FileManager.default

        if let p = ProcessInfo.processInfo.environment["ATELIERD_BIN"], !p.isEmpty {
            let u = URL(fileURLWithPath: p)
            if fm.isExecutableFile(atPath: u.path) { return u }
        }

        let home = fm.homeDirectoryForCurrentUser
        let userLocal = home.appendingPathComponent(".local/bin/ustad")
        if fm.isExecutableFile(atPath: userLocal.path) { return userLocal }

        let exe = Bundle.main.executableURL?.deletingLastPathComponent()
        if let exe {
            let sibling = exe.appendingPathComponent("ustad")
            if fm.isExecutableFile(atPath: sibling.path) { return sibling }
        }

        // Dev fallback: walk up from current_exe looking for target/debug/ustad
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("target/debug/ustad")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        // Also try CWD-based lookup.
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let cwdCandidate = cwd.appendingPathComponent("target/debug/ustad")
        if fm.isExecutableFile(atPath: cwdCandidate.path) { return cwdCandidate }

        return nil
    }

    /// True if something is accepting on the given UDS path.
    static func isSocketAlive(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            for (i, b) in bytes.enumerated() {
                ptr[i] = b
            }
            ptr[bytes.count] = 0
        }
        let size = MemoryLayout<sockaddr_un>.size
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(size))
            }
        }
        return result == 0
    }

    /// Path of the rolling daemon log file. Created on first spawn.
    static func logFileURL() -> URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Usta", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("ustad.log")
    }

    /// Rotate log to `.1` if larger than 4 MB so the live file stays grep-able.
    static func rotateIfBig(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > 4 * 1024 * 1024 else { return }
        let rotated = url.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }

    /// Best-effort: kill any ustad process bound to `socket`, then remove
    /// the socket file so a fresh spawn can bind. We pkill by full arg match
    /// so we don't touch unrelated daemons.
    static func stopByProbe(socket: String) {
        // pkill -f "ustad --socket <path>" — matches the daemon launched
        // by either this app or a previous run.
        let task = Process()
        task.launchPath = "/usr/bin/pkill"
        task.arguments = ["-f", "ustad --socket \(socket)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        // give it ~250ms to release the socket
        Thread.sleep(forTimeInterval: 0.25)
        if FileManager.default.fileExists(atPath: socket) {
            try? FileManager.default.removeItem(atPath: socket)
        }
    }

    /// Spawn the daemon detached. Returns the launched URL on success.
    @discardableResult
    static func spawn(
        socket: String,
        anthropicKey: String? = nil,
        geminiKey: String? = nil,
        ollamaHost: String? = nil
    ) -> URL? {
        // Refuse stomping a live daemon.
        if isSocketAlive(socket) { return nil }
        guard let bin = locateBinary() else { return nil }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["--socket", socket]

        var env = ProcessInfo.processInfo.environment
        if let key = anthropicKey, !key.isEmpty { env["ANTHROPIC_API_KEY"] = key }
        if let key = geminiKey, !key.isEmpty { env["GEMINI_API_KEY"] = key }
        if let h = ollamaHost, !h.isEmpty { env["OLLAMA_HOST"] = h }
        // Bump daemon log level so the file is useful for debugging.
        if env["RUST_LOG"] == nil {
            env["RUST_LOG"] = "info,usta_daemon=debug"
        }
        proc.environment = env

        proc.standardInput = FileHandle.nullDevice
        // Send daemon stdout/stderr to a rolling log file so the user can
        // tail it for debugging. Old log moved to .1 each spawn.
        let logURL = Self.logFileURL()
        Self.rotateIfBig(logURL)
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            proc.standardOutput = h
            proc.standardError = h
        } else if FileManager.default.createFile(atPath: logURL.path, contents: nil),
                  let h = try? FileHandle(forWritingTo: logURL) {
            proc.standardOutput = h
            proc.standardError = h
        } else {
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
        }

        do {
            try proc.run()
            return bin
        } catch {
            return nil
        }
    }
}
