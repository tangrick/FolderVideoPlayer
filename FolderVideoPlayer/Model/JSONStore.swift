import Foundation

/// Reading and writing the app's little JSON files.
///
/// A file hand-edited into the wrong shape must not take the app down, so a
/// failed decode is a fallback rather than an error, and a write goes via a
/// scratch file carrying the pid — two copies of the app running at once
/// would otherwise race for one ".tmp" and whichever lost would blow up
/// renaming a file the other had already moved.
enum JSONStore {
    static func load<T: Decodable>(_ path: String, fallback: T) -> T {
        guard let data = FileManager.default.contents(atPath: path) else { return fallback }
        return (try? JSONDecoder().decode(T.self, from: data)) ?? fallback
    }

    @discardableResult
    static func save<T: Encodable>(_ path: String, _ value: T) -> Bool {
        write(path, value) == nil
    }

    @discardableResult
    /// The compact form, for the big machine files — the fingerprint index
    /// and the durations — where pretty printing and sorted keys meant a
    /// visibly larger file and a visibly slower write, on every flush, for
    /// formatting nobody reads.
    static func saveCompact<T: Encodable>(_ path: String, _ value: T) -> Bool {
        write(path, value, pretty: false) == nil
    }

    /// Write it, or say why not.
    ///
    /// The move into place is a plain POSIX rename, which is atomic and is
    /// what `player.py` used. `FileManager.replaceItemAt` was here first and
    /// is the wrong tool over SMB: it preserves metadata and stages a backup
    /// item, and a share that will not do those refuses the whole write — the
    /// symptom being tags that would not publish while everything else worked.
    static func write<T: Encodable>(_ path: String, _ value: T, pretty: Bool = true) -> String? {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir,
                                                    withIntermediateDirectories: true)
        } catch {
            return reason(error)
        }
        // The scratch name carries the pid and a fresh id. The pid alone was
        // not enough: two writes at once *inside* one process shared the name,
        // so one wrote the file while the other renamed it away — which is
        // what "Resource busy" on the share turned out to be.
        let scratch = "\(path).\(ProcessInfo.processInfo.processIdentifier)"
            + ".\(UUID().uuidString.prefix(8)).tmp"
        let data: Data
        do {
            let encoder = JSONEncoder()
            if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
            data = try encoder.encode(value)
            try data.write(to: URL(fileURLWithPath: scratch))
        } catch {
            try? FileManager.default.removeItem(atPath: scratch)
            return reason(error)
        }
        if rename(scratch, path) == 0 { return nil }
        let renameError = String(cString: strerror(errno))
        // SMB can hold a file open for a moment after something has finished
        // with it, and answers a rename over it with EBUSY. Worth a second
        // ask before giving up.
        for pause in [50_000, 200_000, 500_000] as [UInt32] {
            usleep(pause)
            if rename(scratch, path) == 0 { return nil }
        }
        // Some servers will not rename over a file that is already there at
        // all, so the older copy is taken away first. Not atomic, which is why
        // it is the fallback and not the way it is done.
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
            if rename(scratch, path) == 0 { return nil }
        }
        // Last resort: write over the file where it lies.
        //
        // A rename needs the server to replace a directory entry, and an SMB
        // server will refuse that while another client has the file open —
        // which for a tag file is ordinary, since the Apple TV reads these.
        // Writing into the existing file asks for less and usually goes
        // through. Not atomic, so it is the last thing tried and not the
        // first: a crash mid-write would leave a half-written file.
        if let handle = FileHandle(forWritingAtPath: path) {
            do {
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: data)
                try handle.close()
                try? FileManager.default.removeItem(atPath: scratch)
                return nil
            } catch {
                try? handle.close()
            }
        }
        try? FileManager.default.removeItem(atPath: scratch)
        // EBUSY on a share almost always means somebody else has it open.
        return renameError == "Resource busy"
            ? "Resource busy — another device has the file open"
            : renameError
    }

    private static func reason(_ error: Error) -> String {
        let ns = error as NSError
        return ns.localizedFailureReason ?? ns.localizedDescription
    }
}
