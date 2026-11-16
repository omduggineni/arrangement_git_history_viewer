import AppKit

/// Drives the real window for end-to-end checks, like the Rust app's `e2e` bin.
///
///     ADV_E2E_OUT=/tmp/shots ADV_E2E_STEPS="file:song.mscz,tab:history,commit:0,settings" ArrangementDiffViewer --repo R
///
/// Each step runs, then a PNG of the window is written to ADV_E2E_OUT and the
/// app exits after the last one. Steps: tab:changes|files|history, file:<path>
/// (a changed file), treefile:<path>, commit:<index>, commitfile:<path>,
/// settings, back, wait:<seconds>, commitall:<summary>, shot.
@MainActor enum E2E {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["ADV_E2E_OUT"], let steps = env["ADV_E2E_STEPS"] else { return }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let app = AppModel.shared
            var n = 0
            snapshot(out, &n, "start")
            for step in steps.split(separator: ",").map(String.init) {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                let arg = parts.count > 1 ? parts[1] : ""
                let repo = app.repo
                switch parts[0] {
                case "tab": await repo?.switchMode(arg == "files" ? .files : arg == "history" ? .history : .changes)
                case "file": await repo?.selectChangedFile(arg)
                case "treefile": await repo?.selectTreeFile(arg)
                case "commit":
                    if let r = repo, let i = Int(arg), i < r.commits.count { await r.selectCommit(r.commits[i].sha) }
                case "commitfile": await repo?.selectCommitFile(arg)
                case "settings": app.navigate(.settings)
                case "back": app.navigate(.repo)
                case "wait": try? await Task.sleep(nanoseconds: UInt64((Double(arg) ?? 1) * 1_000_000_000))
                case "commitall":
                    repo?.summary = arg
                    await repo?.doCommit()
                default: break
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                snapshot(out, &n, step)
            }
            exit(0)
        }
    }

    private static func snapshot(_ dir: String, _ n: inout Int, _ name: String) {
        n += 1
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "-")
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: joinPath(dir, String(format: "%02d-%@.png", n, safe))))
        }
    }
}
