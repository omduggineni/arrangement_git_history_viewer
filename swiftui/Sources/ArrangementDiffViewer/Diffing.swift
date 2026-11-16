import Foundation

/// Notation diffs. Swift handles blob extraction, the MuseScore conversion and
/// the cache; the comparison itself (musicdiff on music21, rendered with
/// verovio) is a Python-only stack, so it runs in `sidecar/diff_sidecar.py`.
enum Diffing {
    /// musicdiff's DetailLevel.AllObjects
    static let detailAllObjects = 65535

    private struct ManifestItem: Decodable {
        var label: String
        var start: Int
        var end: Int
        var has1: Bool
        var has2: Bool
    }

    static func loadCached(_ dir: String) throws -> DiffResult {
        let costText = try String(contentsOfFile: joinPath(dir, "cost.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cost = Int(costText) else { throw ProcError(message: "Corrupt cached diff (cost.txt).") }
        let text = try String(contentsOfFile: joinPath(dir, "text.txt"), encoding: .utf8)
        var excerpts: [Excerpt] = []
        if let m = FileManager.default.contents(atPath: joinPath(dir, "excerpts.json")) {
            let items = try JSONDecoder().decode([ManifestItem].self, from: m)
            let exDir = joinPath(dir, "excerpts")
            for (i, it) in items.enumerated() {
                excerpts.append(Excerpt(label: it.label, start: it.start, end: it.end,
                                        svg1: it.has1 ? joinPath(exDir, "\(i)_a.svg") : nil,
                                        svg2: it.has2 ? joinPath(exDir, "\(i)_b.svg") : nil))
            }
        }
        return DiffResult(cost: cost, text: text, excerpts: excerpts, error: nil)
    }

    private static var sidecarScript: String { joinPath(AppPaths.projectRoot, "sidecar", "diff_sidecar.py") }

    /// The frozen sidecar shipped inside the app bundle, if any.
    static func bundledSidecar() -> String? {
        let p = joinPath(AppPaths.projectRoot, "sidecar-bin", "diff_sidecar", "diff_sidecar")
        return Settings.isExecutable(p) ? p : nil
    }

    /// (program, leading args): the bundled sidecar unless the user chose their
    /// own Python on the Settings page; otherwise a Python running the script.
    private static func sidecarCommand() throws -> (String, [String]) {
        if Settings.savedPath(Settings.python) == nil, let b = bundledSidecar() { return (b, []) }
        guard let python = Settings.pathFor(Settings.python) else {
            throw ProcError(message: "Could not find a Python with musicdiff installed. Set its location on the Settings page (the gear icon in the toolbar).")
        }
        return (python, [sidecarScript])
    }

    private static func runSidecar(_ mx1: String, _ mx2: String, _ name1: String, _ name2: String, _ dir: String, progress: @escaping (Double, String) -> Void) throws {
        let (python, lead) = try sidecarCommand()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = lead + [mx1, mx2, name1, name2, dir, String(detailAllObjects)]
        var env = Settings.childEnv(python)
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw ProcError(message: "Couldn't run Python at \(python): \(error.localizedDescription)") }

        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }

        var failure: String?
        var done = false
        var buffer = Data()
        func handle(_ line: Data) {
            guard let v = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if let f = v["progress"] as? Double {
                progress(f, v["message"] as? String ?? "")
            } else if let e = v["error"] as? String {
                failure = e
            } else if v["done"] != nil {
                done = true
            }
        }
        let reader = out.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                handle(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        if !buffer.isEmpty { handle(buffer) }
        p.waitUntilExit()
        errDone.wait()
        if let f = failure { throw ProcError(message: f) }
        if p.terminationStatus != 0 || !done {
            let tail = String(decoding: errData, as: UTF8.self).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("[Error]") }.suffix(5).joined(separator: "\n")
            throw ProcError(message: "The diff engine failed (exit \(p.terminationStatus)).\n\(tail)")
        }
    }

    /// Never fails: any conversion/parse/render failure comes back in `error`.
    static func diffVersions(repo: String, cacheRoot: String, ref1: String, path1: String, ref2: String, path2: String,
                             progress: @escaping (Double, String) -> Void) -> DiffResult {
        do {
            progress(0.0, "Converting first version")
            let (sha1, mx1) = try Cache.ensureMusicXML(repo, cacheRoot, ref1, path1)
            progress(0.2, "Converting second version")
            let (sha2, mx2) = try Cache.ensureMusicXML(repo, cacheRoot, ref2, path2)
            let dir = Cache.diffDir(cacheRoot, sha1, sha2, detailAllObjects)
            if Cache.diffIsCached(dir) { return try loadCached(dir) }
            try runSidecar(mx1, mx2, path1, path2, dir, progress: progress)
            return try loadCached(dir)
        } catch {
            return DiffResult(error: "\(error)")
        }
    }
}
