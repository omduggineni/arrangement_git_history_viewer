import SwiftUI

private let musescoreGitignore = """
# MuseScore backups and autosaves
.mscbackup/
*.mscz~
*.mscz,
*.mscx~
.DS_Store

"""

// --- Building blocks -----------------------------------------------------------

/// Title, body, and a Cancel / confirm row. Closing the sheet any other way than
/// confirming yields nil to whoever awaits it.
struct ModalFrame<Content: View>: View {
    var title: String
    var width: CGFloat
    var confirmLabel: String
    var confirmDisabled = false
    var busy = false
    var onConfirm: () -> Void
    var onCancel: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).tstyle(TextSize.titleMid, bold: true)
            content
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(DarkButtonStyle()).keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(DarkButtonStyle(prominent: true))
                    .disabled(confirmDisabled || busy)
            }
            .padding(.top, 6)
        }
        .padding(18)
        .frame(width: width)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }
}

struct HelpText: View {
    var text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).tstyle(TextSize.base, Theme.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct ErrorText: View {
    var text: String
    var body: some View {
        if !text.isEmpty {
            Text(text).tstyle(TextSize.base, Theme.red, mono: true).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct InputField: View {
    var title: String
    @Binding var text: String
    var placeholder = ""
    var onSubmit: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).tstyle(TextSize.base, Theme.secondary)
            TextField(placeholder, text: $text).darkField().onSubmit { onSubmit?() }
        }
    }
}

struct FolderField: View {
    var title: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).tstyle(TextSize.base, Theme.secondary)
            HStack(spacing: 6) {
                TextField("", text: $text).darkField().frame(height: 28)
                Button { if let p = AppModel.shared.pickFolder("Choose a folder", start: text) { text = p } } label: { Image(systemName: "folder").frame(width: 34) }
                    .buttonStyle(DarkButtonStyle()).help("Browse…")
            }
        }
    }
}

// --- Simple dialogs --------------------------------------------------------------

struct ErrorSheet: View {
    var title: String
    var message: String
    var onOK: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).tstyle(TextSize.titleMid, bold: true)
            ScrollView {
                Text(message).tstyle(TextSize.base, mono: true).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(minHeight: 60, maxHeight: 300)
            .background(Theme.chrome)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack { Spacer(); Button("OK", action: onOK).keyboardShortcut(.defaultAction).buttonStyle(DarkButtonStyle(prominent: true)) }
        }
        .padding(18)
        .frame(width: 560)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }
}

// --- Opening, creating, and cloning repositories -------------------------------

extension AppModel {
    func switchToRepo(_ path: String) {
        do { try openRepo(path) } catch {
            showError("Can't open repository", "\(error)")
            return
        }
        reload()
    }

    /// Pick a folder; open it if it's a repo, else offer to make it one.
    func openRepository() async {
        guard let path = pickFolder("Choose a repository folder (or a folder of scores to turn into one)") else { return }
        guard isDirectory(path) else { showError("Folder not found", path); return }
        if await blocking({ GitOps.isGitRepo(path) }) {
            switchToRepo(path)
            return
        }
        let msg = "\(path)\n\nisn't a git repository yet. Create one here? Any scores already in the folder will show up as new changes, ready for a first commit."
        if await confirm("Not a git repository", msg, confirmLabel: "Create repository", danger: false) {
            do { try await blocking { Result { try AppModel.shared.createRepoSync(path, true) } }.get() } catch {
                showError("Couldn't create repository", "\(error)")
                return
            }
            switchToRepo(path)
        }
    }

    func createRepository() async {
        let start = defaultLocation()
        let path: String? = await present { done in AnyView(CreateRepoSheet(start: start, done: done)) }
        if let path { switchToRepo(path) }
    }

    func cloneRepository() async {
        let start = defaultLocation()
        let path: String? = await present { done in AnyView(CloneSheet(start: start, done: done)) }
        if let path { switchToRepo(path) }
    }

    /// Ask for user.name / user.email, which git needs before committing.
    func identityDialog() async -> Bool {
        let repo = current?.repoPath ?? ""
        return await present { done in AnyView(IdentitySheet(repo: repo, done: done)) } ?? false
    }

    /// View/set the URL of the repo's main remote. Returns the remote name once
    /// one is configured, or nil if cancelled.
    func remoteDialog(publishing: Bool) async -> String? {
        let repo = current?.repoPath ?? ""
        let remotes = (try? GitOps.listRemotes(repo)) ?? []
        let name = GitOps.defaultRemote(repo) ?? "origin"
        let url = remotes.first { $0.name == name }?.url ?? ""
        return await present { done in AnyView(RemoteSheet(repo: repo, remoteName: name, initialURL: url, publishing: publishing, done: done)) }
    }

    func newBranchDialog() async -> String? {
        let repo = current?.repoPath ?? ""
        let base = GitOps.currentBranchName(repo)
        return await present { done in AnyView(NewBranchSheet(repo: repo, base: base, done: done)) }
    }
}

struct CreateRepoSheet: View {
    var start: String
    var done: (String?) -> Void
    @State private var name = ""
    @State private var location: String
    @State private var ignore = true
    @State private var error = ""
    @State private var working = false

    init(start: String, done: @escaping (String?) -> Void) {
        self.start = start
        self.done = done
        _location = State(initialValue: start)
    }

    var body: some View {
        ModalFrame(title: "Create a new repository", width: 520, confirmLabel: "Create repository", busy: working, onConfirm: create, onCancel: { done(nil) }) {
            InputField(title: "Name", text: $name, placeholder: "my-arrangement", onSubmit: create)
            FolderField(title: "Location", text: $location)
            if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                HelpText("Will be created at \(joinPath(location, name.trimmingCharacters(in: .whitespaces)))")
            }
            Toggle("Ignore MuseScore backup files (adds a .gitignore)", isOn: $ignore).tstyle()
            ErrorText(text: error)
        }
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { error = "Enter a name for the repository."; return }
        let path = joinPath(location, n)
        if fileExists(joinPath(path, ".git")) { error = "\(path) is already a git repository -- use Open instead."; return }
        working = true
        let add = ignore
        Task {
            let res = await blocking { Result { try AppModel.shared.createRepoSync(path, add) } }
            working = false
            switch res {
            case .success: done(canonicalPath(path))
            case .failure(let e): error = "\(e)"
            }
        }
    }
}

extension AppModel {
    nonisolated func createRepoSync(_ path: String, _ add: Bool) throws {
        try GitOps.initRepo(path)
        let gi = joinPath(path, ".gitignore")
        if add && !fileExists(gi) { try musescoreGitignore.write(toFile: gi, atomically: true, encoding: .utf8) }
    }
}

struct CloneSheet: View {
    var done: (String?) -> Void
    @State private var url = ""
    @State private var location: String
    @State private var error = ""
    @State private var working = false

    init(start: String, done: @escaping (String?) -> Void) {
        self.done = done
        _location = State(initialValue: start)
    }

    private var target: String? {
        let u = url.trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? nil : joinPath(location, RemoteOps.repoName(fromURL: u))
    }

    var body: some View {
        ModalFrame(title: "Clone a repository", width: 560, confirmLabel: "Clone", busy: working, onConfirm: clone, onCancel: { done(nil) }) {
            InputField(title: "Repository URL", text: $url, placeholder: "https://github.com/you/scores.git  or  git@github.com:you/scores.git", onSubmit: clone)
            FolderField(title: "Location", text: $location)
            if let t = target { HelpText("Will be cloned into \(t)") }
            ErrorText(text: error)
            if working { HelpText("Cloning… this can take a while for large repositories.") }
        }
    }

    private func clone() {
        guard let dest = target else { error = "Enter the URL of the repository to clone."; return }
        error = ""
        working = true
        let u = url.trimmingCharacters(in: .whitespaces)
        Task {
            let res = await blocking { Result { try RemoteOps.clone(url: u, dest: dest) } }
            working = false
            switch res {
            case .success: done(canonicalPath(dest))
            case .failure(let e): error = "\(e)"
            }
        }
    }
}

struct IdentitySheet: View {
    var repo: String
    var done: (Bool?) -> Void
    @State private var name = ""
    @State private var email = ""
    @State private var everywhere = true
    @State private var error = ""

    var body: some View {
        ModalFrame(title: "Who's committing?", width: 480, confirmLabel: "Save", onConfirm: save, onCancel: { done(nil) }) {
            HelpText("Git records a name and email address with every commit. This is only stored in your git settings.")
            InputField(title: "Name", text: $name)
            InputField(title: "Email", text: $email)
            Toggle("Use for all repositories on this computer", isOn: $everywhere).tstyle()
            ErrorText(text: error)
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces), e = email.trimmingCharacters(in: .whitespaces)
        if n.isEmpty || e.isEmpty { error = "Both a name and an email are required."; return }
        let (r, g) = (repo, everywhere)
        Task {
            let res = await blocking { Result { try GitOps.setIdentity(r, name: n, email: e, global: g) } }
            switch res {
            case .success: done(true)
            case .failure(let err): error = "\(err)"
            }
        }
    }
}

struct RemoteSheet: View {
    var repo: String
    var remoteName: String
    var publishing: Bool
    var done: (String?) -> Void
    @State private var url: String
    @State private var error = ""

    init(repo: String, remoteName: String, initialURL: String, publishing: Bool, done: @escaping (String?) -> Void) {
        self.repo = repo
        self.remoteName = remoteName
        self.publishing = publishing
        self.done = done
        _url = State(initialValue: initialURL)
    }

    var body: some View {
        ModalFrame(title: publishing ? "Publish repository" : "Remote repository", width: 560, confirmLabel: publishing ? "Publish" : "Save", onConfirm: save, onCancel: { done(nil) }) {
            HelpText("To share this repository or back it up online, create an empty repository on GitHub, GitLab, or similar, then paste its URL here.")
            InputField(title: "URL for “\(remoteName)”", text: $url, placeholder: "https://github.com/you/scores.git", onSubmit: save)
            ErrorText(text: error)
        }
    }

    private func save() {
        let u = url.trimmingCharacters(in: .whitespaces)
        if u.isEmpty { error = "Enter the remote repository's URL."; return }
        do {
            try GitOps.setRemote(repo, name: remoteName, url: u)
            done(remoteName)
        } catch { self.error = "\(error)" }
    }
}

struct NewBranchSheet: View {
    var repo: String
    var base: String
    var done: (String?) -> Void
    @State private var name = ""
    @State private var error = ""

    var body: some View {
        ModalFrame(title: "Create a branch", width: 440, confirmLabel: "Create branch", onConfirm: create, onCancel: { done(nil) }) {
            HelpText("Based on “\(base)”. Any uncommitted changes come along to the new branch.")
            InputField(title: "Name", text: $name, placeholder: "e.g. strings-revision", onSubmit: create)
            ErrorText(text: error)
        }
    }

    private func create() {
        let n = name
        Task {
            let app = AppModel.shared
            await app.writeLock.acquire()
            let r = repo
            let res = await blocking { Result { try GitOps.createBranch(r, n) } }
            app.writeLock.release()
            switch res {
            case .success: done(n.trimmingCharacters(in: .whitespaces))
            case .failure(let e): error = "\(e)"
            }
        }
    }
}
