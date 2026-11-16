import CryptoKit
import Foundation

/// Converted scores and computed diffs, keyed by git blob sha so they survive
/// branch switches. Layout and keys are identical to the Python and Rust apps.
enum Cache {
    static func cacheRoot(forRepo repo: String) -> String {
        let hash = SHA256.hash(data: Data(canonicalPath(repo).utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        let root = joinPath(AppPaths.cacheBase, String(hex.prefix(16)))
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    /// Stage the file at `ref` as `blobs/<sha><ext>` and return (sha, path).
    private static func stageBlob(_ repo: String, _ cacheRoot: String, _ ref: String, _ path: String) throws -> (String, String) {
        guard let sha = GitOps.blobSha(repo, ref, path) else { throw ProcError(message: "\(path) does not exist at \(ref)") }
        let blobs = joinPath(cacheRoot, "blobs")
        try FileManager.default.createDirectory(atPath: blobs, withIntermediateDirectories: true)
        let ext = (path as NSString).pathExtension
        let mscz = joinPath(blobs, "\(sha).\(ext.isEmpty ? "mscz" : ext)")
        if !fileExists(mscz) {
            let data = try GitOps.blobBytes(repo, ref, path)
            try data.write(to: URL(fileURLWithPath: mscz))
        }
        return (sha, mscz)
    }

    /// (blob_sha, musicxml_path) for the file at `ref`, converting via MuseScore
    /// and caching the result if needed.
    static func ensureMusicXML(_ repo: String, _ cacheRoot: String, _ ref: String, _ path: String) throws -> (String, String) {
        guard let existing = GitOps.blobSha(repo, ref, path) else { throw ProcError(message: "\(path) does not exist at \(ref)") }
        let out = joinPath(cacheRoot, "blobs", "\(existing).musicxml")
        if fileExists(out) { return (existing, out) }
        let (sha, mscz) = try stageBlob(repo, cacheRoot, ref, path)
        try Convert.msczConvert(mscz, out)
        return (sha, out)
    }

    private static func pageNumber(_ name: String) -> Int {
        let stem = (name as NSString).deletingPathExtension
        return Int(stem.components(separatedBy: "-").last ?? "") ?? 0
    }

    private static func existingPages(_ dir: String, _ sha: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasPrefix("\(sha)-") && $0.hasSuffix(".png") }
            .sorted { pageNumber($0) < pageNumber($1) }
            .map { joinPath(dir, $0) }
    }

    /// PNG pages of the score at `ref`, rendered by MuseScore and cached by blob.
    static func ensurePages(_ repo: String, _ cacheRoot: String, _ ref: String, _ path: String) throws -> [String] {
        let (sha, mscz) = try stageBlob(repo, cacheRoot, ref, path)
        let dir = joinPath(cacheRoot, "pages")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let have = existingPages(dir, sha)
        if !have.isEmpty { return have }
        try Convert.msczConvert(mscz, joinPath(dir, "\(sha).png"))
        let got = existingPages(dir, sha)
        if got.isEmpty { throw ProcError(message: "MuseScore produced no pages.") }
        return got
    }

    static func diffDir(_ cacheRoot: String, _ sha1: String, _ sha2: String, _ detail: Int) -> String {
        let d = joinPath(cacheRoot, "diffs", "\(sha1)__\(sha2)__\(detail)")
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    static func diffIsCached(_ dir: String) -> Bool { fileExists(joinPath(dir, "done.marker")) }
}
