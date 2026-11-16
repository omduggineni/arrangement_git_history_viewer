import Foundation

/// `.mscz` is MuseScore's own proprietary file format (a zipped,
/// version-specific XML schema), so converting it to MusicXML / images has to
/// shell out to the MuseScore CLI. Every other local step runs in-process.
enum Convert {
    /// MuseScore's CLI behaves like a single-instance GUI app under the hood and is
    /// unreliable when invoked concurrently, so conversions are serialized.
    static let mscoreLock = NSLock()

    static func mscorePath() throws -> String {
        guard let p = Settings.pathFor(Settings.mscore) else {
            throw ProcError(message: "Could not find the MuseScore command-line program (mscore). Set its location on the Settings page (the gear icon in the toolbar).")
        }
        return p
    }

    // mscore's stderr on a crash is dominated by macOS crash-reporter noise; the
    // actual reason, if any, is usually the last non-blank line before that.
    static func lastMeaningfulLine(_ stderr: String) -> String {
        for line in stderr.components(separatedBy: "\n").reversed() {
            let l = line.trimmingCharacters(in: .whitespaces)
            if !l.isEmpty && !l.contains("mach_o_image_annotations_reader") { return l }
        }
        return String(stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))
    }

    static func outputExists(_ out: String) -> Bool {
        if fileExists(out) { return true }
        // Page-per-file formats (png) get a "-<page>" suffix before the extension.
        let ns = out as NSString
        let stem = (ns.lastPathComponent as NSString).deletingPathExtension
        return fileExists(joinPath(ns.deletingLastPathComponent, "\(stem)-1.\(ns.pathExtension)"))
    }

    /// Some MuseScore builds abort (SIGABRT, exit 134) in their crash-reporter teardown
    /// after the conversion has already finished and written its output. A MusicXML file
    /// that ends properly is complete, so it is accepted despite the abnormal exit;
    /// other formats (page PNGs) can't be verified and still need a clean exit.
    static func abortedAfterWriting(_ out: String) -> Bool {
        guard out.hasSuffix(".musicxml"), let h = FileHandle(forReadingAtPath: out) else { return false }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 512 ? size - 512 : 0)
        let tail = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        return tail.contains("</score-partwise>")
    }

    /// Convert via the MuseScore CLI; the output format follows the output file's
    /// extension (.musicxml, .pdf, .png ...).
    ///
    /// MuseScore's CLI is a full GUI app under the hood, and its startup races with
    /// its own crash-reporter/single-instance machinery when another MuseScore
    /// process is already running -- an intermittent SIGABRT that a retry clears.
    @discardableResult
    static func msczConvert(_ mscz: String, _ out: String, timeout: TimeInterval = 180, retries: Int = 4) throws -> String {
        try? FileManager.default.createDirectory(atPath: parentPath(out), withIntermediateDirectories: true)
        let exe = try mscorePath()
        var last: ProcError?
        for attempt in 0...retries {
            var result: ProcResult?
            try? FileManager.default.removeItem(atPath: out) // anything found afterwards is from this run
            mscoreLock.lock()
            do {
                result = try runProcess(exe, ["-o", out, mscz], env: Settings.childEnv(exe), timeout: timeout)
            } catch {
                mscoreLock.unlock()
                throw ProcError(message: "Couldn't run MuseScore at \(exe): \(error)\nCheck its location on the Settings page (the gear icon in the toolbar).")
            }
            mscoreLock.unlock()
            if let r = result {
                if outputExists(out) && (r.status == 0 || abortedAfterWriting(out)) { return out }
                let code = r.status.map(String.init) ?? "timeout/signal"
                last = ProcError(message: "mscore failed to convert \(baseName(mscz)) (exit \(code)): \(lastMeaningfulLine(r.stderr))\nThis can happen when MuseScore is already open elsewhere; closing it may help.")
            }
            if attempt < retries { Thread.sleep(forTimeInterval: 0.5 * Double(attempt + 1)) }
        }
        throw last ?? ProcError(message: "MuseScore conversion failed.")
    }
}
