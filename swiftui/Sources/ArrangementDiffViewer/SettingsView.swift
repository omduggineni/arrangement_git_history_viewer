import SwiftUI

struct SettingsView: View {
    private var app: AppModel { .shared }
    @State private var fields: [String: String] = Dictionary(uniqueKeysWithValues: Settings.tools.map { ($0.key, Settings.resolve($0).path ?? "") })
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 8) {
                    Button { app.navigate(.repo) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                        .buttonStyle(IconButtonStyle()).foregroundStyle(Theme.secondary).help("Back")
                    Text("Settings").tstyle(TextSize.titleBig, bold: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("EXTERNAL PROGRAMS").tstyle(TextSize.xsmall, Theme.muted)
                    Text("MuseScore, Git and Python are found automatically. Change one only to use a different copy, or if it wasn't found.")
                        .tstyle(TextSize.base, Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Settings.tools, id: \.key) { tool in
                    ToolCard(tool: tool, text: Binding(get: { fields[tool.key] ?? "" }, set: { fields[tool.key] = $0 }))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("APP DATA").tstyle(TextSize.xsmall, Theme.muted)
                    Text("Settings and the recent-repositories list live in the data folder; converted scores and computed diffs are cached in the cache folder.")
                        .tstyle(TextSize.base, Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Open data folder") { app.openFolder(AppPaths.dataDir) }.buttonStyle(DarkButtonStyle())
                    Button("Open cache folder") { app.openFolder(AppPaths.cacheBase) }.buttonStyle(DarkButtonStyle())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("ABOUT").tstyle(TextSize.xsmall, Theme.muted)
                    Text("This app is built on open source software. See what it uses and under which licenses.")
                        .tstyle(TextSize.base, Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Open source licenses") {
                        Task { let _: Bool? = await app.present { done in AnyView(LicensesSheet { done(true) }) } }
                    }.buttonStyle(DarkButtonStyle())
                }
                HStack(spacing: 8) {
                    Spacer()
                    if saved {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark").foregroundStyle(Theme.green)
                            Text("Settings saved").tstyle(TextSize.base, Theme.secondary)
                        }
                        .padding(.trailing, 8)
                    }
                    Button("Cancel") { app.navigate(.repo) }.buttonStyle(DarkButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("Save", action: save).buttonStyle(DarkButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 720)
            .padding(.top, 36).padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
        .onChange(of: fields) { saved = false }
    }

    private func save() {
        for tool in Settings.tools {
            do { try Settings.savePath(tool, fields[tool.key] ?? "") } catch {
                app.showError("Couldn't save settings", "\(error)")
                return
            }
        }
        for tool in Settings.tools { fields[tool.key] = Settings.pathFor(tool) ?? "" } // also refreshes each source label
        Task { saved = true } // after the refresh above, so its onChange doesn't clear it
    }
}

/// One external program's row: a path field (prefilled with whatever is in
/// effect now), where that path came from, and a way to test it.
struct ToolCard: View {
    var tool: Tool
    @Binding var text: String
    @State private var testMessage: String?
    @State private var testOK = false
    @State private var testing = false

    private var normalized: String { Settings.normalize(text, tool: tool) }
    private var def: (path: String?, source: String) { Settings.defaultPath(tool) }
    private var isDefault: Bool { normalized == def.path || (def.path == nil && normalized.isEmpty) }

    private var source: (String, Color) {
        if isDefault { return (def.source, def.path != nil ? Theme.secondary : Theme.red) }
        return normalized.isEmpty ? ("not set", Theme.red) : ("custom", Theme.yellow)
    }

    private var status: (ok: Bool, message: String) {
        if normalized.isEmpty { return (false, "\(tool.name) is needed for this app to work fully.") }
        if Settings.isExecutable(normalized) { return (true, "Found. Click Test to check that it runs.") }
        return (false, "There's no program at this path.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(tool.name).tstyle(bold: true)
                Badge(text: source.0, color: source.1)
                Spacer()
                if def.path != nil && !isDefault {
                    Button("Use default") { text = def.path ?? "" }.buttonStyle(DarkButtonStyle())
                }
            }
            Text(tool.description).tstyle(TextSize.base, Theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField("Not found -- choose where \(tool.name) is installed", text: $text)
                    .padding(.leading, 36)
                    .darkField(mono: true).frame(height: 28)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 0) {
                        Button {
                            let existing = parentPath(text)
                            if let p = AppModel.shared.pickFile("Choose the \(tool.name) program", start: existing) {
                                text = Settings.normalize(p, tool: tool)
                            }
                        } label: { Image(systemName: "folder").foregroundStyle(Theme.secondary).frame(width: 36, height: 28).contentShape(Rectangle()) }
                            .buttonStyle(IconButtonStyle()).help("Browse…")
                            Rectangle().fill(Theme.border).frame(width: 1)
                        }
                    }
                Button { runTest() } label: { Text("Test").frame(width: 34) }.buttonStyle(DarkButtonStyle()).disabled(!status.ok || testing)
            }
            HStack(spacing: 8) {
                let shown = testMessage.map { (testOK, $0) } ?? status
                Image(systemName: shown.0 ? "checkmark" : "exclamationmark.circle").foregroundStyle(shown.0 ? Theme.green : Theme.red)
                Text(shown.1).tstyle(TextSize.base, shown.0 ? Theme.secondary : Theme.red).lineLimit(2)
                Spacer()
            }
        }
        .padding(12)
        .background(Theme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .boxBorder()
        .onChange(of: text) { testMessage = nil }
    }

    private func runTest() {
        let path = normalized
        testing = true
        testOK = true
        testMessage = "Running…"
        Task {
            let t = tool
            let res = await blocking { Settings.version(t, path: path) }
            testing = false
            switch res {
            case .success(let v): testOK = true; testMessage = "Works: \(v)"
            case .failure(let e): testOK = false; testMessage = "Didn't run: \(e)"
            }
        }
    }
}
