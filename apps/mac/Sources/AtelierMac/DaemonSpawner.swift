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

    /// Spawn the daemon detached. Returns the launched URL on success.
    @discardableResult
    static func spawn(socket: String, anthropicKey: String? = nil) -> URL? {
        // Refuse stomping a live daemon.
        if isSocketAlive(socket) { return nil }
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
