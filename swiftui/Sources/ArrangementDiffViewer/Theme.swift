import AppKit
import SwiftUI

/// One consistent dark palette (loosely modeled on GitHub Desktop's dark
/// theme) used everywhere, including the main content area. Score pages are
/// rendered on deliberate white "paper" cards against this dark surface.
extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: opacity)
    }
}

enum Theme {
    static let surface = Color(hex: 0x24272e)
    static let chrome = Color(hex: 0x1c1f24)
    static let border = Color(hex: 0x383b42)
    static let primary = Color(hex: 0xe6edf3)
    static let secondary = Color(hex: 0x8b949e)
    static let muted = Color(hex: 0x6e7681)
    static let accent = Color(hex: 0x58a6ff)
    static let green = Color(hex: 0x3fb950)
    static let yellow = Color(hex: 0xd29922)
    static let red = Color(hex: 0xf85149)
    static let purple = Color(hex: 0xa371f7)
    static let selectedRow = Color(hex: 0x58a6ff, opacity: 0.16)
    static let hover = Color(hex: 0xe6edf3, opacity: 0.07)

    static let headerHeight: CGFloat = 56
}

/// Font sizes follow style.css (.small / .caption-s / .xsmall / .title-*), scaled to macOS points.
enum TextSize {
    static let base: CGFloat = 13
    static let xsmall: CGFloat = 11
    static let badge: CGFloat = 10
    static let titleMid: CGFloat = 17
    static let titleBig: CGFloat = 26
}

extension View {
    func tstyle(_ size: CGFloat = TextSize.base, _ color: Color = Theme.primary, bold: Bool = false, mono: Bool = false) -> some View {
        self.font(.system(size: size, weight: bold ? .semibold : .regular, design: mono ? .monospaced : .default))
            .foregroundStyle(color)
    }

    func borderEdge(_ edge: Edge.Set, _ color: Color = Theme.border) -> some View {
        overlay(alignment: edge == .top ? .top : edge == .bottom ? .bottom : edge == .leading ? .leading : .trailing) {
            if edge == .top || edge == .bottom {
                Rectangle().fill(color).frame(height: 1)
            } else {
                Rectangle().fill(color).frame(width: 1)
            }
        }
    }

    func boxBorder(radius: CGFloat = 6) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.border, lineWidth: 1))
    }

    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.background(hovering ? Theme.hover : Color.clear).onHover { hovering = $0 }
    }
}

struct Badge: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.system(size: TextSize.badge, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1))
    }
}

extension FileStatus {
    var badgeText: String { self == .new ? "+" : self == .modified ? "M" : "−" }
    var color: Color { self == .new ? Theme.green : self == .modified ? Theme.yellow : Theme.red }
    var tip: String { self == .new ? "New file" : self == .modified ? "Modified" : "Deleted" }
}

/// An image loaded off the main thread (PNG pages); SVG excerpts are drawn as vectors.
struct FileImage: View {
    var path: String
    @State private var image: NSImage?
    var body: some View {
        if path.hasSuffix(".svg") {
            SVGScoreView(path: path)
        } else {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).antialiased(true).aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
                }
            }
            .task(id: path) { image = await Task.detached { NSImage(contentsOfFile: path) }.value }
        }
    }
}

/// A score excerpt sits on a deliberate white 'paper' card against the dark UI
/// -- normal for sheet music -- or, if this version doesn't have this excerpt,
/// a dashed placeholder of the same shape.
struct ScoreCard: View {
    var path: String?
    var body: some View {
        if let path {
            FileImage(path: path)
                .padding(12)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .boxBorder()
        } else {
            Text("Not present at this version.").tstyle(TextSize.base, Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 80)
                .padding(24)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }
}

/// Native-looking dark text field: plain field (no AppKit bezel) inside a rounded surface box
/// with an accent border while focused.
struct DarkFieldStyle: ViewModifier {
    @FocusState private var focused: Bool
    var mono = false
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: TextSize.base, design: mono ? .monospaced : .default))
            .foregroundStyle(Theme.primary)
            .focused($focused)
            .focusEffectDisabled()
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Theme.accent : Theme.border, lineWidth: focused ? 1.5 : 1))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
    }
}

extension View {
    func darkField(mono: Bool = false) -> some View { modifier(DarkFieldStyle(mono: mono)) }
}

/// Bordered dark button matching the field style; `.prominent` is the accent-filled primary action.
struct DarkButtonStyle: ButtonStyle {
    var prominent = false
    var height: CGFloat = 28
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let lit = enabled && hovering
        return configuration.label
            .font(.system(size: TextSize.base))
            .foregroundStyle(prominent ? Color.white : Theme.primary)
            .padding(.horizontal, 10)
            .frame(minHeight: height)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(prominent ? Theme.accent.opacity(configuration.isPressed ? 0.7 : (lit ? 1.0 : 0.9)) : (configuration.isPressed ? Theme.hover : Theme.surface)))
            .overlay(RoundedRectangle(cornerRadius: 6).fill(!prominent && lit && !configuration.isPressed ? Theme.hover : Color.clear))
            .onHover { hovering = $0 }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: prominent ? 0 : 1))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Borderless icon button: a subtle highlight behind the icon while hovered.
struct IconButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering || configuration.isPressed ? Theme.hover : Color.clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Plain button whose whole label gets the hover highlight (toolbar actions, tabs, list rows).
struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed ? Theme.hover : Color.clear)
            .onHover { hovering = $0 }
    }
}
