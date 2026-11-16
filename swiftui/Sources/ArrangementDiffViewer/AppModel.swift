import AppKit
import SwiftUI

func blocking<T>(_ f: @escaping () -> T) async -> T {
    await Task.detached(priority: .userInitiated, operation: f).value
}

/// Serializes everything that writes to the repo (commit, checkout, push...).
@MainActor final class WriteLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var isLocked: Bool { locked }

    func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }

    func with<T>(_ body: () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await body()
    }
}

struct OpenRepo {
    var repoPath: String
    var cacheRoot: String
}

struct SheetItem: Identifiable {
    let id = UUID()
    let view: AnyView
}

private final class ResumeOnce<T> {
    var cont: CheckedContinuation<T?, Never>?
    func resume(_ v: T?) { cont?.resume(returning: v); cont = nil }
}

/// The window: one page at a time (welcome, settings, repository view), plus
/// the open-repository session, toasts and modal sheets.
@MainActor @Observable final class AppModel {
    static let shared = AppModel()

    enum Page { case welcome, settings, repo }

    var page: Page = .welcome
    var repo: RepoModel?
    var toast: String?
    var sheet: SheetItem?
    /// bumped on every page change, so a replaced page's polling stops
    private(set) var token = 0
    var current: OpenRepo?

    @ObservationIgnored let writeLock = WriteLock()
    @ObservationIgnored private var sheetDismissed: (() -> Void)?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    // --- Navigation ----------------------------------------------------------

    func reload() { navigate(.repo) }

    func navigate(_ to: Page) {
        token += 1
        if to == .settings {
            page = .settings
        } else if let cur = current {
            repo = RepoModel(token: token, open: cur)
            page = .repo
            repo?.start()
        } else {
            repo = nil
            page = .welcome
        }
    }

    func notify(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // --- Session ---------------------------------------------------------------

    func openRepo(_ path: String) throws {
        let top = try GitOps.openRepo(path)
        let repoPath = canonicalPath(top)
        Recent.add(repoPath)
        current = OpenRepo(repoPath: repoPath, cacheRoot: Cache.cacheRoot(forRepo: repoPath))
    }

    func closeRepo() {
        current = nil
        reload()
    }

    /// Reopen the most recent repo (like GitHub Desktop), or fall through to the welcome screen.
    func openInitialRepo(explicit: String?) {
        if let p = explicit {
            do { try openRepo(canonicalPath(p)) } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)) }
            return
        }
        for path in Recent.load() {
            if (try? openRepo(path)) != nil { break }
            Recent.remove(path)
        }
    }

    // --- Modal sheets ----------------------------------------------------------

    /// Show a sheet and await its result. `make` receives the `finish` callback
    /// the sheet calls with its value; dismissing any other way yields nil.
    func present<T>(_ make: @escaping (@escaping (T?) -> Void) -> AnyView) async -> T? {
        while sheet != nil { try? await Task.sleep(nanoseconds: 80_000_000) }
        let once = ResumeOnce<T>()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            once.cont = cont
            sheetDismissed = { once.resume(nil) }
            sheet = SheetItem(view: make { [weak self] value in
                once.resume(value)
                self?.sheet = nil
            })
        }
    }

    func sheetWasDismissed() {
        sheetDismissed?()
        sheetDismissed = nil
    }

    func showError(_ title: String, _ message: String) {
        Task { let _: Bool? = await present { done in AnyView(ErrorSheet(title: title, message: message) { done(true) }) } }
    }

    func confirm(_ title: String, _ message: String, confirmLabel: String, danger: Bool) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = danger ? .warning : .informational
        let ok = alert.addButton(withTitle: confirmLabel)
        if danger { ok.hasDestructiveAction = true }
        alert.addButton(withTitle: "Cancel")
        if let w = NSApp.keyWindow ?? NSApp.windows.first {
            return await alert.beginSheetModal(for: w) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    // --- Pickers and Finder ----------------------------------------------------

    func pickFolder(_ prompt: String, start: String? = nil) -> String? {
        let p = NSOpenPanel()
        p.message = prompt
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        if let s = start, isDirectory(s) { p.directoryURL = URL(fileURLWithPath: s) }
        guard p.runModal() == .OK, let url = p.url else { return nil }
        return canonicalPath(url.path)
    }

    /// Not canonicalized: a symlink like /opt/homebrew/bin/mscore should stay a
    /// symlink, so it keeps working after the thing it points to is upgraded.
    func pickFile(_ prompt: String, start: String? = nil) -> String? {
        let p = NSOpenPanel()
        p.message = prompt
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.treatsFilePackagesAsDirectories = false
        if let s = start, isDirectory(s) { p.directoryURL = URL(fileURLWithPath: s) }
        guard p.runModal() == .OK, let url = p.url else { return nil }
        return url.path
    }

    func openFolder(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openInMuseScore(_ rel: String) {
        guard let exe = Settings.pathFor(Settings.mscore) else { notify("MuseScore not found. Set its path in Settings."); return }
        guard let cur = current else { return }
        let full = joinPath(cur.repoPath, rel)
        guard fileExists(full) else { notify("That file no longer exists."); return }
        let bundle = sequence(first: exe, next: { $0 == "/" || $0.isEmpty ? nil : parentPath($0) }).first { $0.hasSuffix(".app") }
        let p = Process()
        if let bundle {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", bundle, full]
        } else {
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = [full]
        }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { showError("Couldn't open MuseScore", error.localizedDescription) }
    }

    func revealInFinder(_ rel: String) {
        guard let cur = current else { return }
        let full = joinPath(cur.repoPath, rel)
        guard fileExists(full) else { notify("That file no longer exists."); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
    }

    /// Where new/cloned repos go by default: next to the most recently opened
    /// repo, else ~/Documents.
    func defaultLocation() -> String {
        if let first = Recent.load().first { return parentPath(first) }
        let docs = joinPath(AppPaths.home, "Documents")
        return isDirectory(docs) ? docs : AppPaths.home
    }
}
