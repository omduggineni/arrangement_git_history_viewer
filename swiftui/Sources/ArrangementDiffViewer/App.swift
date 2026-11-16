import AppKit
import SwiftUI

let appVersionHelp = """
Diff viewer for MuseScore files in a git repo.

USAGE: ArrangementDiffViewer [--repo PATH]

Without --repo, the most recently opened repo (or a welcome screen) is shown.
"""

struct RootView: View {
    private var app: AppModel { .shared }

    var body: some View {
        @Bindable var app = app
        ZStack(alignment: .bottom) {
            Group {
                switch app.page {
                case .welcome: WelcomeView().padding(.top, 28)
                case .settings: SettingsView().padding(.top, 28)
                case .repo: if let r = app.repo { RepoView(model: r) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let t = app.toast {
                Text(t).tstyle(TextSize.base, Theme.primary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color(hex: 0x30343c)).clipShape(Capsule())
                    .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                    .shadow(radius: 6)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.toast)
        .background(Theme.surface)
        .background(WindowConfigurator())
        .sheet(item: $app.sheet, onDismiss: { AppModel.shared.sheetWasDismissed() }) { item in item.view }
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 900, minHeight: 560)
    }
}

/// Lets the content run under the title bar (the header bar doubles as the
/// title bar, like the GTK app) and makes the window draggable from it.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(Theme.surface)
            context.coordinator.attach(to: w)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Vertically centres the traffic lights in the header bar and gives them
    /// a little more room from the window edge. AppKit resets their layout on
    /// resize / full screen, so it is re-applied on those events.
    final class Coordinator {
        private var observers: [NSObjectProtocol] = []
        private let leading: CGFloat = 20
        private let spacing: CGFloat = 8

        func attach(to w: NSWindow) {
            layout(w)
            let nc = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self, weak w] _ in
                    guard let w else { return }
                    self?.layout(w)
                })
            }
        }

        private func layout(_ w: NSWindow) {
            guard !w.styleMask.contains(.fullScreen),
                  let close = w.standardWindowButton(.closeButton),
                  let mini = w.standardWindowButton(.miniaturizeButton),
                  let zoom = w.standardWindowButton(.zoomButton),
                  let bar = close.superview else { return }
            let h = Theme.headerHeight
            if let container = bar.superview, container !== w.contentView {
                // `bar` is the title bar view; make it as tall as the header.
                bar.setFrameSize(NSSize(width: bar.frame.width, height: h))
                bar.setFrameOrigin(NSPoint(x: bar.frame.origin.x, y: container.bounds.height - h))
            }
            let y = (h - close.frame.height) / 2
            for (i, b) in [close, mini, zoom].enumerated() {
                b.setFrameOrigin(NSPoint(x: leading + CGFloat(i) * (b.frame.width + spacing), y: y))
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if !Bundle.main.bundlePath.hasSuffix(".app"),
           let icon = NSImage(contentsOfFile: joinPath(AppPaths.projectRoot, "packaging", "icon.icns")) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ArrangementDiffViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let args = CommandLine.arguments
        if args.contains("-h") || args.contains("--help") {
            print(appVersionHelp)
            exit(0)
        }
        var repo: String?
        if let i = args.firstIndex(of: "--repo"), i + 1 < args.count { repo = args[i + 1] }
        try? FileManager.default.createDirectory(atPath: AppPaths.cacheBase, withIntermediateDirectories: true)
        let app = AppModel.shared
        app.openInitialRepo(explicit: repo)
        app.reload()
        DispatchQueue.main.async { E2E.runIfRequested() }
    }

    var body: some Scene {
        Window("Arrangement Diff Viewer", id: "main") {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { Task { await AppModel.shared.openRepository() } }.keyboardShortcut("o")
                Button("Create New Repository…") { Task { await AppModel.shared.createRepository() } }.keyboardShortcut("n")
                Button("Clone Repository…") { Task { await AppModel.shared.cloneRepository() } }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { AppModel.shared.navigate(.settings) }.keyboardShortcut(",")
            }
        }
    }
}
