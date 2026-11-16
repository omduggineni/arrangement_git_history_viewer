import Foundation

/// Recently opened repositories, for the welcome screen and repo switcher.
enum Recent {
    static let max = 12
    static var file: String { joinPath(AppPaths.dataDir, "recent_repos.json") }

    static func load() -> [String] {
        guard let data = FileManager.default.contents(atPath: file),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return raw.compactMap { $0 as? String }.filter { isDirectory($0) }
    }

    static func add(_ path: String) {
        var paths = [path] + load().filter { $0 != path }
        paths = Array(paths.prefix(max))
        save(paths)
    }

    static func remove(_ path: String) {
        save(load().filter { $0 != path })
    }

    private static func save(_ paths: [String]) {
        try? FileManager.default.createDirectory(atPath: AppPaths.dataDir, withIntermediateDirectories: true)
        // a missing recents list is not worth failing over
        if let d = try? JSONSerialization.data(withJSONObject: paths, options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: file))
        }
    }
}
