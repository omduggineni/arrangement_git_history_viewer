import SwiftUI

struct WelcomeView: View {
    private var app: AppModel { .shared }
    @State private var recents = Recent.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Arrangement Diff Viewer").tstyle(TextSize.titleBig, bold: true)
                        Text("Track versions of your MuseScore arrangements with git, and see exactly what changed in the notation.")
                            .tstyle(TextSize.base, Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button { app.navigate(.settings) } label: { Image(systemName: "gearshape").frame(width: 28, height: 28) }
                        .buttonStyle(IconButtonStyle()).foregroundStyle(Theme.secondary).help("Settings")
                }

                let missing = Settings.tools.filter { !Settings.isExecutable(Settings.pathFor($0) ?? "") }.map(\.name)
                if !missing.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.yellow)
                        Text("\(missing.joined(separator: " and ")) couldn't be found. Set \(missing.count > 1 ? "their locations" : "its location") in Settings.")
                            .tstyle().fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.yellow, lineWidth: 1))
                    .contentShape(Rectangle())
                    .onTapGesture { app.navigate(.settings) }
                }

                HStack(spacing: 12) {
                    card("folder", "Open a folder", "An existing repository, or a folder of scores") { await app.openRepository() }
                    card("folder.badge.plus", "Create new", "Start a new, empty repository") { await app.createRepository() }
                    card("arrow.down.to.line", "Clone", "Copy a repository from GitHub etc.") { await app.cloneRepository() }
                }

                if !recents.isEmpty {
                    Text("RECENT").tstyle(TextSize.xsmall, Theme.muted)
                    VStack(spacing: 0) {
                        ForEach(recents, id: \.self) { path in
                            HStack(spacing: 12) {
                                Image(systemName: "folder").foregroundStyle(Theme.secondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(baseName(path)).tstyle()
                                    Text(path).tstyle(TextSize.xsmall, Theme.muted).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Button {
                                    Recent.remove(path)
                                    recents = Recent.load()
                                } label: { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 24) }
                                    .buttonStyle(IconButtonStyle()).foregroundStyle(Theme.secondary).help("Remove from list")
                            }
                            .padding(.vertical, 8).padding(.leading, 16).padding(.trailing, 8)
                            .contentShape(Rectangle())
                            .hoverHighlight()
                            .onTapGesture { app.switchToRepo(path) }
                        }
                    }
                    .boxBorder()
                }
            }
            .frame(width: 640)
            .padding(.top, 64).padding(.bottom, 64)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
    }

    private func card(_ icon: String, _ title: String, _ subtitle: String, _ f: @escaping () async -> Void) -> some View {
        Button { Task { await f() } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Theme.accent).frame(height: 20)
                Text(title).tstyle(bold: true)
                Text(subtitle).tstyle(TextSize.base, Theme.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(Theme.chrome)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .boxBorder()
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}
