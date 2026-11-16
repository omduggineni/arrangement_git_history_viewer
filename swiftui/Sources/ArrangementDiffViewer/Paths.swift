import Foundation

/// Path helpers. Paths are plain strings throughout, like the other ports.
func joinPath(_ base: String, _ parts: String...) -> String {
    parts.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
}

func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

func isDirectory(_ path: String) -> Bool {
    var d: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
}

/// Like Rust's `fs::canonicalize` (realpath). Foundation's resolvingSymlinksInPath
/// would turn /private/var into /var, which changes the cache key.
func canonicalPath(_ path: String) -> String {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(path, &buf) != nil else { return path }
    return String(cString: buf)
}

func baseName(_ path: String) -> String { (path as NSString).lastPathComponent }
func parentPath(_ path: String) -> String { (path as NSString).deletingLastPathComponent }

enum AppPaths {
    static var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }

    /// Where settings and the recent-repositories list live. `ADV_CONFIG_DIR`
    /// overrides it (used by the tests; `HOME` itself must stay real because
    /// MuseScore's CLI crashes without its own ~/Library directories).
    static var dataDir: String {
        if let d = ProcessInfo.processInfo.environment["ADV_CONFIG_DIR"], !d.isEmpty { return d }
        return joinPath(home, ".config", "arrangement-diff-viewer")
    }

    /// Shared by every repo (each gets its own hashed subdirectory). `ADV_CACHE_DIR` overrides it.
    static var cacheBase: String {
        if let d = ProcessInfo.processInfo.environment["ADV_CACHE_DIR"], !d.isEmpty { return d }
        return joinPath(home, ".cache", "arrangement-diff-viewer")
    }

    /// The app's own files (sidecar, icons): `Contents/Resources` inside an
    /// app bundle, else `ADV_ROOT`, else the source checkout.
    static var projectRoot: String {
        if Bundle.main.bundlePath.hasSuffix(".app"), let r = Bundle.main.resourcePath { return r }
        if let r = ProcessInfo.processInfo.environment["ADV_ROOT"], !r.isEmpty { return r }
        // .../<project>/Sources/ArrangementDiffViewer/Paths.swift
        return parentPath(parentPath(parentPath(#filePath)))
    }
}
