import SwiftUI

/// One credited component: what it is, its license, and where to find it.
private struct Credit: Identifiable {
    var name: String
    var license: String
    var note: String
    var url: String
    var id: String { name }
}

private let bundledCredits = [
    Credit(name: "musicdiff", license: "MIT", note: "Computes the differences between two scores.", url: "https://github.com/gregchapman-dev/musicdiff"),
    Credit(name: "converter21", license: "MIT", note: "Reads and writes MusicXML and other score formats.", url: "https://github.com/gregchapman-dev/converter21"),
    Credit(name: "music21", license: "BSD-3-Clause", note: "Music notation toolkit that musicdiff builds on.", url: "https://github.com/cuthbertLab/music21"),
    Credit(name: "Verovio", license: "LGPL-3.0", note: "Renders scores to SVG.", url: "https://github.com/rism-digital/verovio"),
    Credit(name: "Leipzig font", license: "SIL Open Font License 1.1", note: "Music-symbol font, distributed with Verovio.", url: "https://github.com/rism-digital/leipzig"),
    Credit(name: "NumPy", license: "BSD-3-Clause", note: "", url: "https://github.com/numpy/numpy"),
    Credit(name: "Matplotlib", license: "Matplotlib License (PSF-based)", note: "", url: "https://github.com/matplotlib/matplotlib"),
    Credit(name: "Pillow", license: "MIT-CMU", note: "", url: "https://github.com/python-pillow/Pillow"),
    Credit(name: "Requests", license: "Apache-2.0", note: "", url: "https://github.com/psf/requests"),
]

private let externalCredits = [
    Credit(name: "Git", license: "GPL-2.0", note: "Run as a separate program; not part of this app.", url: "https://git-scm.com"),
    Credit(name: "MuseScore", license: "GPL-3.0", note: "Run as a separate program. The full app (make app-with-bundled-musescore) ships an unmodified copy; source at the project link.", url: "https://github.com/musescore/MuseScore"),
]

struct LicensesSheet: View {
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open source licenses").tstyle(TextSize.titleMid, bold: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HelpText("This app is built on the open source software below. Smaller supporting Python libraries are also included under their own licenses; see each project for the full license text.")
                    section("INCLUDED IN THE APP", bundledCredits)
                    section("USED AS SEPARATE PROGRAMS", externalCredits)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(height: 380)
            .background(Theme.chrome)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack { Spacer(); Button("Close", action: onClose).keyboardShortcut(.defaultAction).buttonStyle(DarkButtonStyle(prominent: true)) }
        }
        .padding(18)
        .frame(width: 520)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }

    private func section(_ title: String, _ credits: [Credit]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).tstyle(TextSize.xsmall, Theme.muted)
            ForEach(credits) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(c.name).tstyle(TextSize.base, bold: true)
                        Badge(text: c.license, color: Theme.secondary)
                    }
                    if !c.note.isEmpty { Text(c.note).tstyle(TextSize.base, Theme.secondary) }
                    if let url = URL(string: c.url) { Link(c.url, destination: url).font(.system(size: TextSize.base)) }
                }
            }
        }
    }
}
