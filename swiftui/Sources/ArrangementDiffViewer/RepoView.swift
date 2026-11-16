import SwiftUI

// --- Header: repository / branch / sync ---------------------------------------

/// A GitHub Desktop-style header button: small caption over a bold value.
struct ToolbarLabel: View {
    var icon: String
    var caption: String
    var value: String
    var width: CGFloat
    var menu = false
    var spinner = false

    var body: some View {
        HStack(spacing: 12) {
            if spinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon).foregroundStyle(Theme.secondary).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(caption).tstyle(TextSize.xsmall, Theme.secondary).lineLimit(1)
                Text(value).tstyle(TextSize.base, Theme.primary, bold: true).lineLimit(1)
            }
            Spacer(minLength: 0)
            if menu { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary) }
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: Theme.headerHeight)
        .contentShape(Rectangle())
        .hoverHighlight()
        .borderEdge(.trailing)
    }
}

struct HeaderBar: View {
    var model: RepoModel
    private var app: AppModel { .shared }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 88) // window traffic lights
            repoMenu
            branchMenu
            syncButton
            Spacer()
            Button { app.navigate(.settings) } label: { Image(systemName: "gearshape").frame(width: 32, height: 32) }
                .buttonStyle(IconButtonStyle()).foregroundStyle(Theme.secondary).help("Settings")
            Button { Task { await model.refreshAll(rerenderSelection: true) } } label: { Image(systemName: "arrow.clockwise").frame(width: 32, height: 32) }
                .buttonStyle(IconButtonStyle()).foregroundStyle(Theme.secondary).help("Refresh")
                .keyboardShortcut("r", modifiers: .command)
            Color.clear.frame(width: 8)
        }
        .frame(height: Theme.headerHeight)
        .background(Theme.chrome)
        .borderEdge(.bottom)
    }

    private var repoMenu: some View {
        Menu {
            let others = Recent.load().filter { $0 != model.repoPath }
            ForEach(Array(others.prefix(8)), id: \.self) { p in
                Button { app.switchToRepo(p) } label: { Label(baseName(p), systemImage: "folder") }
            }
            if !others.isEmpty { Divider() }
            Button("Open folder…") { Task { await app.openRepository() } }
            Button("Create new repository…") { Task { await app.createRepository() } }
            Button("Clone repository…") { Task { await app.cloneRepository() } }
            Divider()
            Button("Remote settings…") { Task { await model.editRemote() } }
            Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.repoPath)) }
            Button("Close repository") { app.closeRepo() }
        } label: {
            ToolbarLabel(icon: "folder", caption: "Current repository", value: model.repoName, width: 260, menu: true)
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
    }

    private var branchMenu: some View {
        Menu {
            ForEach(model.branches, id: \.name) { b in
                Button { Task { await model.switchBranch(b) } } label: {
                    Label(b.name, systemImage: b.isCurrent ? "checkmark" : b.isRemote ? "cloud" : "")
                }
            }
            Divider()
            Button("New branch…") { Task { await model.newBranch() } }
        } label: {
            ToolbarLabel(icon: "arrow.triangle.branch", caption: "Current branch", value: model.sync.branch, width: 240, menu: true)
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
    }

    @ViewBuilder private var syncButton: some View {
        let sync = model.sync
        let remote = model.remote
        if let busy = model.busy {
            ToolbarLabel(icon: "", caption: "\(busy)…", value: "Please wait", width: 240, spinner: true)
        } else if sync.isUnborn {
            ToolbarLabel(icon: "square.and.arrow.up", caption: "Publish repository", value: "Commit something first", width: 240).opacity(0.5)
        } else if !sync.hasRemote {
            action("square.and.arrow.up", "Publish repository", "Not on any server yet") { await model.publishRepository() }
        } else if sync.upstream == nil {
            action("square.and.arrow.up", "Publish branch", "Push to \(remote)") { await model.push(setUpstream: true) }
        } else if sync.ahead > 0 && sync.behind > 0 {
            action("exclamationmark.triangle", "Diverged from \(sync.upstream ?? "")", "↑\(sync.ahead) ↓\(sync.behind)") { model.explainDivergence() }
        } else if sync.behind > 0 {
            action("arrow.down.circle", "Pull \(remote)", "↓ \(sync.behind) new commit\(sync.behind != 1 ? "s" : "")") { await model.pull() }
        } else if sync.ahead > 0 {
            action("arrow.up.circle", "Push \(remote)", "↑ \(sync.ahead) commit\(sync.ahead != 1 ? "s" : "")") { await model.push(setUpstream: false) }
        } else {
            action("arrow.clockwise", "Fetch \(remote)", "Check for new commits") { await model.fetch() }
        }
    }

    private func action(_ icon: String, _ caption: String, _ value: String, _ f: @escaping () async -> Void) -> some View {
        Button { Task { await f() } } label: { ToolbarLabel(icon: icon, caption: caption, value: value, width: 240) }
            .buttonStyle(RowButtonStyle())
    }
}

// --- Left pane ----------------------------------------------------------------

struct FileContextMenu: ViewModifier {
    var rel: String
    func body(content: Content) -> some View {
        content.contextMenu {
            if rel.hasSuffix(".mscz") { Button("Open in MuseScore") { AppModel.shared.openInMuseScore(rel) } }
            Button("Show in Finder") { AppModel.shared.revealInFinder(rel) }
        }
    }
}

struct Sidebar: View {
    var model: RepoModel

    var body: some View {
        VStack(spacing: 0) {
            tabs
            ScrollView {
                LazyVStack(spacing: 0) {
                    switch model.mode {
                    case .changes: ChangesList(model: model)
                    case .files: FilesTree(model: model)
                    case .history: HistoryList(model: model)
                    }
                }
            }
            if model.mode == .changes { CommitBox(model: model) }
        }
        .frame(width: 300)
        .background(Theme.surface)
        .borderEdge(.trailing)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach([(RepoModel.Mode.changes, "Changes"), (.files, "Files"), (.history, "History")], id: \.1) { m, title in
                let text = m == .changes && !model.changedFiles.isEmpty ? "\(title) (\(model.changedFiles.count))" : title
                let active = model.mode == m
                Button { Task { await model.switchMode(m) } } label: {
                    Text(text).tstyle(TextSize.base, active ? Theme.primary : Theme.secondary, bold: active)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(active ? Theme.accent : .clear).frame(height: 2) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }
            Spacer()
        }
        .borderEdge(.bottom)
    }
}

struct EmptyNote: View {
    var title: String
    var detail: String?
    var body: some View {
        VStack(spacing: 4) {
            Text(title).tstyle(TextSize.base, Theme.secondary)
            if let detail { Text(detail).tstyle(TextSize.base, Theme.muted).multilineTextAlignment(.center) }
        }
        .padding(.vertical, 32).padding(.horizontal, 16).frame(maxWidth: .infinity)
    }
}

struct ChangesList: View {
    var model: RepoModel

    var body: some View {
        if model.changedFiles.isEmpty {
            EmptyNote(title: "No local changes", detail: "Save a score in MuseScore and it will show up here.")
        } else {
            let all = Binding<Bool>(
                get: { model.excluded.isEmpty },
                set: { on in model.excluded = on ? [] : Set(model.changedFiles.map(\.path)) })
            HStack(spacing: 6) {
                Toggle("", isOn: all).toggleStyle(.checkbox).labelsHidden()
                let n = model.changedFiles.count
                Text("\(n) changed file\(n != 1 ? "s" : "")").tstyle(TextSize.base, Theme.secondary)
                Spacer()
            }
            .padding(.leading, 12).padding(.vertical, 6)
            .borderEdge(.bottom)
            ForEach(model.changedFiles, id: \.path) { f in
                let on = Binding<Bool>(
                    get: { !model.excluded.contains(f.path) },
                    set: { if $0 { model.excluded.remove(f.path) } else { model.excluded.insert(f.path) } })
                HStack(spacing: 0) {
                    Toggle("", isOn: on).toggleStyle(.checkbox).labelsHidden().padding(.leading, 12)
                    HStack(spacing: 8) {
                        Text(f.path).tstyle(TextSize.base, f.isScore ? Theme.primary : Theme.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Badge(text: f.status.badgeText, color: f.status.color).help(f.status.tip)
                    }
                    .padding(.vertical, 8).padding(.leading, 8).padding(.trailing, 10)
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await model.selectChangedFile(f.path) } }
                    .modifier(OptionalFileMenu(rel: f.path, enabled: f.status != .deleted))
                }
                .background(model.selectedFile == f.path ? Theme.selectedRow : Color.clear)
            }
        }
    }
}

struct OptionalFileMenu: ViewModifier {
    var rel: String
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.modifier(FileContextMenu(rel: rel)) } else { content }
    }
}

struct FilesTree: View {
    var model: RepoModel

    var body: some View {
        if model.files.isEmpty {
            Text("No files").tstyle(TextSize.base, Theme.secondary).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(model.treeRows) { row in
            let pad = 8 + CGFloat(row.depth) * 16
            switch row.kind {
            case .dir(let closed):
                HStack(spacing: 4) {
                    Image(systemName: closed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: 12)
                    Image(systemName: "folder").foregroundStyle(Theme.secondary)
                    Text(row.name).tstyle()
                    Spacer()
                }
                .padding(.vertical, 4).padding(.leading, pad).padding(.trailing, 8)
                .contentShape(Rectangle())
                .hoverHighlight()
                .onTapGesture { model.toggleFolder(String(row.id.dropFirst(2))) }
            case .file(let path):
                let isScore = path.hasSuffix(".mscz")
                HStack(spacing: 4) {
                    Color.clear.frame(width: 12)
                    Image(systemName: isScore ? "music.note" : "doc").foregroundStyle(isScore ? Theme.accent : Theme.muted).frame(width: 16)
                    Text(row.name).tstyle(TextSize.base, isScore ? Theme.primary : Theme.secondary).lineLimit(1)
                    Spacer()
                    if let s = model.status(of: path) { Badge(text: s.badgeText, color: s.color).help(s.tip) }
                }
                .padding(.vertical, 4).padding(.leading, pad).padding(.trailing, 8)
                .background(model.selectedTreeFile == path ? Theme.selectedRow : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { Task { await model.selectTreeFile(path) } }
                .modifier(FileContextMenu(rel: path))
            }
        }
    }
}

struct HistoryList: View {
    var model: RepoModel

    var body: some View {
        if model.commits.isEmpty {
            Text("No commits yet").tstyle(TextSize.base, Theme.secondary).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(model.commits, id: \.sha) { c in
            VStack(alignment: .leading, spacing: 0) {
                Text(c.subject).tstyle().lineLimit(1)
                Text("\(c.author) committed on \(c.date)").tstyle(TextSize.xsmall, Theme.muted).lineLimit(1)
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(model.selectedCommit == c.sha ? Theme.selectedRow : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { Task { await model.selectCommit(c.sha) } }
            .borderEdge(.bottom)
        }
    }
}

struct CommitBox: View {
    @Bindable var model: RepoModel

    var body: some View {
        VStack(spacing: 8) {
            TextField("Summary (required)", text: $model.summary)
                .darkField()
                .onSubmit { Task { await model.doCommit() } }
            TextField("Description", text: $model.desc, axis: .vertical)
                .lineLimit(3...3)
                .darkField()
            Button { Task { await model.doCommit() } } label: {
                Text(model.committing ? "Committing…" : model.commitTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(DarkButtonStyle(prominent: true))
            .disabled(!model.commitEnabled)
        }
        .padding(12)
        .background(Theme.chrome)
        .borderEdge(.top)
    }
}

// --- Middle pane (history: files changed in the selected commit) -----------------

struct CommitFilesPane: View {
    var model: RepoModel

    var body: some View {
        if let sha = model.selectedCommit, let c = model.commits.first(where: { $0.sha == sha }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.subject).tstyle(TextSize.base, bold: true).fixedSize(horizontal: false, vertical: true)
                    Text("\(c.author) committed on \(c.date)").tstyle(TextSize.xsmall, Theme.muted).fixedSize(horizontal: false, vertical: true)
                    Text(c.shortSha).tstyle(TextSize.xsmall, Theme.muted, mono: true).padding(.bottom, 8)
                    Text("\(model.commitFiles.count) SCORE FILE(S) CHANGED").tstyle(TextSize.xsmall, Theme.muted).padding(.bottom, 4)
                    if model.commitFiles.isEmpty {
                        Text("No .mscz files changed in this commit.").tstyle(TextSize.base, Theme.muted)
                    }
                    ForEach(model.commitFiles, id: \.self) { path in
                        HStack(spacing: 8) {
                            Text("M").tstyle(TextSize.xsmall, Theme.yellow, bold: true)
                            Text(path).tstyle().lineLimit(2)
                        }
                        .padding(.vertical, 4).padding(.leading, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(model.selectedCommitFile == path ? Theme.selectedRow : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await model.selectCommitFile(path) } }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 220)
            .background(Theme.chrome)
            .borderEdge(.trailing)
        }
    }
}

// --- Right pane: score preview and diffs --------------------------------------------

struct RightPane: View {
    var model: RepoModel

    var body: some View {
        ScrollView {
            if let r = model.right {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(r.heading).tstyle(TextSize.titleMid, bold: true).textSelection(.enabled)
                        Spacer()
                        if let d = r.discardPath {
                            Button { Task { await model.discard(d) } } label: { Label("Discard changes…", systemImage: "arrow.uturn.backward") }
                                .buttonStyle(IconButtonStyle()).foregroundStyle(Theme.red)
                        }
                    }
                    if let s = r.subtitle { Text(s).tstyle(TextSize.base, Theme.secondary) }
                    switch r.body {
                    case .none: EmptyView()
                    case .message(let m): Text(m).tstyle(TextSize.base, Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    case .rendering:
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Rendering with MuseScore…").tstyle(TextSize.base, Theme.secondary) }
                    case .pages(let pages):
                        ForEach(pages, id: \.self) { ScoreCard(path: $0) }
                    case .diff(let d):
                        DiffBody(state: d).padding(.top, 8)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
    }
}

struct DiffBody: View {
    var state: DiffState
    var body: some View {
        switch state {
        case .newlyAdded:
            Text("Newly added — nothing to compare against yet.").tstyle(TextSize.base, Theme.secondary)
        case .running(let f, let m):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: f).progressViewStyle(.linear)
                Text("\(m)…").tstyle(TextSize.base, Theme.secondary)
            }
        case .done(let r):
            DiffResultView(result: r)
        }
    }
}

struct DiffResultView: View {
    var result: DiffResult
    @State private var tab = 0

    var body: some View {
        if let e = result.error {
            Text("Error: \(e)").tstyle(TextSize.base, Theme.red, mono: true).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } else if result.cost == 0 {
            Text("No notation differences detected.").tstyle(TextSize.base, Theme.green, bold: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(result.cost) notation differences (OMR edit distance)").tstyle(TextSize.base, bold: true)
                HStack(spacing: 0) {
                    ForEach([(0, "Visual diff"), (1, "Text diff")], id: \.0) { i, title in
                        Button { tab = i } label: {
                            Text(title).tstyle(TextSize.base, tab == i ? Theme.primary : Theme.secondary, bold: tab == i)
                                .padding(.horizontal, 16).padding(.vertical, 6)
                                .overlay(alignment: .bottom) { Rectangle().fill(tab == i ? Theme.accent : .clear).frame(height: 2) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                    Spacer()
                }
                .borderEdge(.bottom)
                if tab == 0 { visual.padding(.top, 12) } else { DiffTextView(text: result.text).padding(.top, 12) }
            }
        }
    }

    @ViewBuilder private var visual: some View {
        VStack(alignment: .leading, spacing: 0) {
            if result.excerpts.isEmpty {
                Text("No differences render visibly in the score — see the text diff.").tstyle(TextSize.base, Theme.secondary)
            }
            ForEach(Array(result.excerpts.enumerated()), id: \.offset) { _, ex in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ex.label).tstyle(bold: true)
                    HStack(alignment: .top, spacing: 16) {
                        side("BEFORE", ex.svg1)
                        side("AFTER", ex.svg2)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private func side(_ caption: String, _ svg: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).tstyle(TextSize.xsmall, Theme.secondary)
            ScoreCard(path: svg)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct DiffTextView: View {
    var text: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(attributed).font(.system(size: TextSize.base, design: .monospaced)).textSelection(.enabled).padding(.top, 4)
        }
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for line in text.components(separatedBy: "\n") {
            var a = AttributedString(line + "\n")
            let color: Color
            var bold = false
            if line.hasPrefix("+++") || line.hasPrefix("---") { color = Theme.secondary }
            else if line.hasPrefix("+") { color = Theme.green }
            else if line.hasPrefix("-") { color = Theme.red }
            else if line.hasPrefix("@@") { color = Theme.purple; bold = true }
            else { color = Theme.primary }
            a.foregroundColor = color
            if bold { a.font = .system(size: TextSize.base, weight: .bold, design: .monospaced) }
            out += a
        }
        return out
    }
}

// --- The page ---------------------------------------------------------------------

struct RepoView: View {
    var model: RepoModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model)
            HStack(spacing: 0) {
                Sidebar(model: model)
                if model.mode == .history { CommitFilesPane(model: model) }
                RightPane(model: model)
            }
        }
    }
}
