import AppKit
import CoreText
import SwiftUI

/// A small native renderer for the SVG subset Verovio emits: glyphs referenced through
/// `<use>` into `<defs>`, paths / polygons / polylines / rects / ellipses, and text
/// (tspans). AppKit's own SVG support doesn't resolve those references, and a web view
/// per excerpt is heavy, so the file is parsed once into a flat display list that a
/// SwiftUI Canvas replays as vectors at any size -- no rasterizing, no web content.
final class ScoreSVG: @unchecked Sendable {
    struct Shape {
        var path: CGPath
        var transform: CGAffineTransform
        var fill: CGColor?
        var stroke: CGColor?
        var strokeWidth: CGFloat
        var cap: CGLineCap
        var join: CGLineJoin
    }
    struct Run {
        var text: String
        var x: CGFloat, y: CGFloat
        var transform: CGAffineTransform
        var font: CTFont
        var color: CGColor
    }
    enum Op { case shape(Shape), run(Run) }

    fileprivate(set) var viewBox = CGSize(width: 840, height: 600)
    fileprivate(set) var ops: [Op] = []

    var aspect: CGFloat { viewBox.width / max(viewBox.height, 1) }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: ScoreSVG] = [:]

    static func load(_ path: String) -> ScoreSVG? {
        cacheLock.lock()
        if let c = cache[path] { cacheLock.unlock(); return c }
        cacheLock.unlock()
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let p = SVGParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.shouldResolveExternalEntities = false
        guard xml.parse() else { return nil }
        let s = p.score
        cacheLock.lock(); cache[path] = s; cacheLock.unlock()
        return s
    }

    func draw(in cg: CGContext, width: CGFloat) {
        let k = width / max(viewBox.width, 1)
        cg.saveGState()
        cg.scaleBy(x: k, y: k)
        for op in ops {
            switch op {
            case .shape(let s):
                cg.saveGState()
                cg.concatenate(s.transform)
                if let f = s.fill {
                    cg.addPath(s.path)
                    cg.setFillColor(f)
                    cg.fillPath()
                }
                if let c = s.stroke, s.strokeWidth > 0 {
                    cg.addPath(s.path)
                    cg.setStrokeColor(c)
                    cg.setLineWidth(s.strokeWidth)
                    cg.setLineCap(s.cap)
                    cg.setLineJoin(s.join)
                    cg.strokePath()
                }
                cg.restoreGState()
            case .run(let r):
                let str = NSAttributedString(string: r.text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): r.font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): r.color,
                ])
                let line = CTLineCreateWithAttributedString(str)
                cg.saveGState()
                cg.concatenate(r.transform)
                cg.translateBy(x: r.x, y: r.y)
                cg.scaleBy(x: 1, y: -1)   // the canvas is y-down, CoreText glyphs are y-up
                cg.textPosition = .zero
                CTLineDraw(line, cg)
                cg.restoreGState()
            }
        }
        cg.restoreGState()
    }
}

/// The score drawn as vectors; sharp at any size and backing scale.
struct SVGScoreView: View {
    var path: String
    @State private var score: ScoreSVG?
    var body: some View {
        Group {
            if let score {
                Canvas { ctx, size in
                    ctx.withCGContext { cg in score.draw(in: cg, width: size.width) }
                }
                .aspectRatio(score.aspect, contentMode: .fit)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .task(id: path) {
            let p = path
            score = await Task.detached(priority: .userInitiated) { ScoreSVG.load(p) }.value
        }
    }
}

// MARK: - parsing

private struct Style {
    var transform = CGAffineTransform.identity
    var color = CGColor(gray: 0, alpha: 1)
    var fill: CGColor? = CGColor(gray: 0, alpha: 1)
    var strokeWidth: CGFloat = 0
    var cap = CGLineCap.butt
    var join = CGLineJoin.miter
    var fontSize: CGFloat = 0
    var leipzig = false
    var fillOpacity: CGFloat = 1
    var italic = false
    var bold = false
    var anchor = 0   // 0 start, 1 middle, 2 end
    var visibleFill: CGColor? { fillOpacity <= 0 ? nil : fill?.copy(alpha: fillOpacity) }
}

private final class SVGParser: NSObject, XMLParserDelegate {
    let score = ScoreSVG()
    private var styles: [Style] = [Style()]
    private var style: Style { styles[styles.count - 1] }
    private var hidden = 0
    private var hiddenAt: [Bool] = []
    private var skipText = 0            // inside <title>/<desc>/<style>
    private var inDefs = false
    private var defId: String?
    private var defOps: [ScoreSVG.Shape] = []
    private var defs: [String: [ScoreSVG.Shape]] = [:]
    private var sawViewBox = false

    // text layout
    private struct PendingRun { var text: String; var style: Style }
    private struct Line { var x: CGFloat; var y: CGFloat; var runs: [PendingRun] = [] }
    private var inText = false
    private var lines: [Line] = []
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        flushText()
        var s = style
        apply(a, to: &s)
        styles.append(s)
        let hide = a["visibility"] == "hidden"
        hiddenAt.append(hide)
        if hide { hidden += 1 }

        switch name {
        case "svg":
            if !sawViewBox, let vb = a["viewBox"] {
                let n = numbers(vb)
                if n.count == 4 { score.viewBox = CGSize(width: n[2], height: n[3]); sawViewBox = true }
            }
        case "title", "desc", "style": skipText += 1
        case "defs": inDefs = true
        case "g":
            if inDefs, let id = a["id"] { defId = id; defOps = [] }
        case "path":
            if let d = a["d"] { emit(parsePath(d)) }
        case "polygon", "polyline":
            let n = numbers(a["points"] ?? "")
            guard n.count >= 4 else { break }
            let p = CGMutablePath()
            p.move(to: CGPoint(x: n[0], y: n[1]))
            var i = 2
            while i + 1 < n.count { p.addLine(to: CGPoint(x: n[i], y: n[i + 1])); i += 2 }
            if name == "polygon" { p.closeSubpath() }
            emit(p)
        case "rect":
            emit(CGPath(rect: CGRect(x: num(a["x"]), y: num(a["y"]), width: num(a["width"]), height: num(a["height"])), transform: nil))
        case "ellipse":
            let rx = num(a["rx"]), ry = num(a["ry"])
            emit(CGPath(ellipseIn: CGRect(x: num(a["cx"]) - rx, y: num(a["cy"]) - ry, width: rx * 2, height: ry * 2), transform: nil))
        case "use":
            guard hidden == 0, let ref = a["xlink:href"] ?? a["href"],
                  let shapes = defs[String(ref.drop(while: { $0 == "#" }))] else { break }
            // `style.transform` already includes the use's own transform attribute
            let t = CGAffineTransform(translationX: num(a["x"]), y: num(a["y"])).concatenating(style.transform)
            for var sh in shapes {
                sh.transform = sh.transform.concatenating(t)
                sh.fill = style.visibleFill
                sh.stroke = style.strokeWidth > 0 ? style.color : nil
                sh.strokeWidth = style.strokeWidth
                score.ops.append(.shape(sh))
            }
        case "text":
            inText = true
            lines = [Line(x: num(a["x"]), y: num(a["y"]))]
        case "tspan":
            if inText, a["x"] != nil || a["y"] != nil {
                let prev = lines.last
                lines.append(Line(x: a["x"].map { num($0) } ?? prev?.x ?? 0, y: a["y"].map { num($0) } ?? prev?.y ?? 0))
            } else if inText, let dy = a["dy"], var l = lines.popLast() {
                l.y += num(dy); lines.append(l)
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        flushText()
        styles.removeLast()
        if hiddenAt.removeLast() { hidden -= 1 }
        switch name {
        case "title", "desc", "style": skipText -= 1
        case "defs": inDefs = false
        case "g":
            if inDefs, let id = defId { defs[id] = defOps; defId = nil }
        case "text": finishText()
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText && skipText == 0 { buffer += string }
    }

    // MARK: elements

    private func apply(_ a: [String: String], to s: inout Style) {
        if let t = a["transform"] { s.transform = parseTransform(t).concatenating(s.transform) }
        if let c = a["color"], let col = color(c, current: s.color) { s.color = col }
        if let f = a["fill"] { s.fill = f == "none" ? nil : color(f, current: s.color) }
        if let o = a["fill-opacity"] { s.fillOpacity = num(o) }
        if let w = a["stroke-width"] { s.strokeWidth = num(w) }
        if let c = a["stroke-linecap"] { s.cap = c == "square" ? .square : c == "round" ? .round : .butt }
        if let j = a["stroke-linejoin"] { s.join = j == "round" ? .round : j == "bevel" ? .bevel : .miter }
        if let f = a["font-size"] { s.fontSize = num(f) }
        if let f = a["font-family"] { s.leipzig = f.contains("Leipzig") }
        if a["font-style"] == "italic" { s.italic = true }
        if a["font-weight"] == "bold" { s.bold = true } else if a["font-weight"] == "normal" { s.bold = false }
        if let t = a["text-anchor"] { s.anchor = t == "middle" ? 1 : t == "end" ? 2 : 0 }
        // Verovio's embedded CSS styles these by class
        if let cls = a["class"]?.split(separator: " ") {
            if cls.contains(where: { ["ending", "fing", "reh", "tempo"].contains($0) }) { s.bold = true }
            if cls.contains(where: { ["dir", "dynam", "mNum"].contains($0) }) { s.italic = true }
            if cls.contains("label") { s.bold = false }
        }
    }

    private func emit(_ path: CGPath) {
        guard hidden == 0 else { return }
        let s = style
        let sh = ScoreSVG.Shape(path: path, transform: s.transform,
                                fill: inDefs ? nil : s.visibleFill,
                                stroke: s.strokeWidth > 0 ? s.color : nil,
                                strokeWidth: s.strokeWidth, cap: s.cap, join: s.join)
        if inDefs { defOps.append(sh) } else { score.ops.append(.shape(sh)) }
    }

    // MARK: text

    private func flushText() {
        guard inText, skipText == 0, !buffer.isEmpty else { buffer = ""; return }
        defer { buffer = "" }
        if buffer.contains("\n"), buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        guard !lines.isEmpty else { return }
        lines[lines.count - 1].runs.append(PendingRun(text: buffer, style: style))
    }

    private func font(for s: Style) -> CTFont {
        if s.leipzig, let l = Leipzig.font(size: max(s.fontSize, 1)) { return l }
        var f = CTFontCreateWithName("Times New Roman" as CFString, max(s.fontSize, 1), nil)
        var traits: CTFontSymbolicTraits = []
        if s.italic { traits.insert(.italicTrait) }
        if s.bold { traits.insert(.boldTrait) }
        if !traits.isEmpty, let v = CTFontCreateCopyWithSymbolicTraits(f, 0, nil, traits, traits) { f = v }
        return f
    }

    private func finishText() {
        defer { inText = false; lines = [] }
        guard hidden == 0 else { return }
        for line in lines where !line.runs.isEmpty {
            let fonts = line.runs.map { font(for: $0.style) }
            let widths = zip(line.runs, fonts).map { run, f -> CGFloat in
                let str = NSAttributedString(string: run.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f])
                return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(str), nil, nil, nil))
            }
            let total = widths.reduce(0, +)
            var x = line.x
            switch line.runs[0].style.anchor { case 1: x -= total / 2; case 2: x -= total; default: break }
            for (i, run) in line.runs.enumerated() {
                score.ops.append(.run(.init(text: run.text, x: x, y: line.y, transform: run.style.transform,
                                            font: fonts[i], color: run.style.fill ?? run.style.color)))
                x += widths[i]
            }
        }
    }

    // MARK: value parsing

    private func num(_ s: String?) -> CGFloat {
        guard let s else { return 0 }
        return Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "px", with: "")).map { CGFloat($0) } ?? 0
    }

    private func color(_ s: String, current: CGColor) -> CGColor? {
        switch s {
        case "currentColor": return current
        case "none": return nil
        case "black": return CGColor(gray: 0, alpha: 1)
        case "white": return CGColor(gray: 1, alpha: 1)
        case "red": return CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        case "dodgerblue": return CGColor(red: 0.12, green: 0.56, blue: 1, alpha: 1)
        case "limegreen": return CGColor(red: 0.2, green: 0.8, blue: 0.2, alpha: 1)
        default:
            guard s.hasPrefix("#") else { return nil }
            var h = String(s.dropFirst())
            if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
            return CGColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
    }

    /// Every number in `s`, however the separators fall ("1,2 3-4 .5.5" -> 1 2 3 -4 .5 .5).
    private func numbers(_ s: String) -> [CGFloat] {
        var out: [CGFloat] = []
        var tok = ""
        var seenDot = false
        func flush() { if let v = Double(tok) { out.append(CGFloat(v)) }; tok = ""; seenDot = false }
        for ch in s {
            if ch.isASCII, ch.isNumber { tok.append(ch) }
            else if ch == "." { if seenDot { flush() }; seenDot = true; tok.append(ch) }
            else if ch == "-" || ch == "+" { if !tok.isEmpty, tok.last != "e" { flush() }; tok.append(ch) }
            else if ch == "e" || ch == "E" { tok.append("e") }
            else { flush() }
        }
        flush()
        return out
    }

    private func parseTransform(_ s: String) -> CGAffineTransform {
        var t = CGAffineTransform.identity
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            let n = numbers(String(rest[rest.index(after: open)..<close]))
            var m = CGAffineTransform.identity
            switch name {
            case "translate": m = CGAffineTransform(translationX: n.first ?? 0, y: n.count > 1 ? n[1] : 0)
            case "scale": m = CGAffineTransform(scaleX: n.first ?? 1, y: n.count > 1 ? n[1] : (n.first ?? 1))
            case "rotate": m = CGAffineTransform(rotationAngle: (n.first ?? 0) * .pi / 180)
            case "matrix" where n.count == 6: m = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
            default: break
            }
            // later transforms in the list apply first to the geometry
            t = m.concatenating(t)
            rest = rest[rest.index(after: close)...]
        }
        return t
    }

    private func parsePath(_ d: String) -> CGPath {
        let p = CGMutablePath()
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint?
        var lastQ: CGPoint?
        func isCmd(_ c: Character) -> Bool { c.isLetter && c != "e" && c != "E" }
        var i = d.startIndex
        while i < d.endIndex {
            let ch = d[i]
            guard isCmd(ch) else { i = d.index(after: i); continue }
            var j = d.index(after: i)
            while j < d.endIndex, !isCmd(d[j]) { j = d.index(after: j) }
            let a = numbers(String(d[d.index(after: i)..<j]))
            let rel = ch.isLowercase
            var k = 0
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            switch ch.uppercased() {
            case "M":
                var first = true
                while k + 1 < a.count {
                    let q = pt(a[k], a[k + 1]); k += 2
                    if first { p.move(to: q); start = q; first = false } else { p.addLine(to: q) }
                    cur = q
                }
                lastCtrl = nil; lastQ = nil
            case "L":
                while k + 1 < a.count { cur = pt(a[k], a[k + 1]); k += 2; p.addLine(to: cur) }
                lastCtrl = nil; lastQ = nil
            case "H":
                while k < a.count { cur = CGPoint(x: rel ? cur.x + a[k] : a[k], y: cur.y); k += 1; p.addLine(to: cur) }
                lastCtrl = nil; lastQ = nil
            case "V":
                while k < a.count { cur = CGPoint(x: cur.x, y: rel ? cur.y + a[k] : a[k]); k += 1; p.addLine(to: cur) }
                lastCtrl = nil; lastQ = nil
            case "C":
                while k + 5 < a.count {
                    let c1 = pt(a[k], a[k + 1]), c2 = pt(a[k + 2], a[k + 3]), e = pt(a[k + 4], a[k + 5]); k += 6
                    p.addCurve(to: e, control1: c1, control2: c2); lastCtrl = c2; cur = e
                }
                lastQ = nil
            case "S":
                while k + 3 < a.count {
                    let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                    let c2 = pt(a[k], a[k + 1]), e = pt(a[k + 2], a[k + 3]); k += 4
                    p.addCurve(to: e, control1: c1, control2: c2); lastCtrl = c2; cur = e
                }
                lastQ = nil
            case "Q":
                while k + 3 < a.count {
                    let c = pt(a[k], a[k + 1]), e = pt(a[k + 2], a[k + 3]); k += 4
                    p.addQuadCurve(to: e, control: c); lastQ = c; cur = e
                }
                lastCtrl = nil
            case "T":
                while k + 1 < a.count {
                    let c = lastQ.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                    let e = pt(a[k], a[k + 1]); k += 2
                    p.addQuadCurve(to: e, control: c); lastQ = c; cur = e
                }
                lastCtrl = nil
            case "Z":
                p.closeSubpath(); cur = start; lastCtrl = nil; lastQ = nil
            default: break   // arcs aren't emitted by Verovio
            }
            i = j
        }
        return p
    }
}
