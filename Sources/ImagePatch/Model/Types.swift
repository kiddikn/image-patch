import AppKit
import CoreGraphics

struct RGBA: Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .red
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    func withAlpha(_ v: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: v) }

    /// 文字色として乗せたときに読みやすい背景色（明るい色なら黒、暗い色なら白）
    var readableBackdrop: RGBA {
        let luma = 0.299 * r + 0.587 * g + 0.114 * b
        return luma > 0.6 ? RGBA(r: 0.1, g: 0.1, b: 0.1, a: 0.85) : RGBA(r: 1, g: 1, b: 1, a: 0.9)
    }

    static let red = RGBA(r: 0.93, g: 0.16, b: 0.16)
    static let orange = RGBA(r: 1.0, g: 0.55, b: 0.0)
    static let yellow = RGBA(r: 1.0, g: 0.82, b: 0.1)
    static let green = RGBA(r: 0.15, g: 0.72, b: 0.35)
    static let blue = RGBA(r: 0.1, g: 0.47, b: 0.95)
    static let purple = RGBA(r: 0.6, g: 0.25, b: 0.85)
    static let black = RGBA(r: 0.08, g: 0.08, b: 0.09)
    static let white = RGBA(r: 1, g: 1, b: 1)

    static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}

enum Tool: String, CaseIterable, Identifiable {
    case select
    case arrow
    case line
    case rect
    case ellipse
    case text
    case mosaic
    case badge
    case crop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: return "選択"
        case .arrow: return "矢印"
        case .line: return "直線"
        case .rect: return "四角"
        case .ellipse: return "丸"
        case .text: return "テキスト"
        case .mosaic: return "モザイク"
        case .badge: return "番号"
        case .crop: return "トリミング"
        }
    }

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .mosaic: return "square.grid.3x3.fill"
        case .badge: return "1.circle.fill"
        case .crop: return "crop"
        }
    }

    /// 修飾キーなしのショートカット
    var key: String {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rect: return "r"
        case .ellipse: return "e"
        case .text: return "t"
        case .mosaic: return "m"
        case .badge: return "b"
        case .crop: return "c"
        }
    }
}

struct ElementStyle: Equatable {
    var color: RGBA = .red
    var lineWidth: CGFloat = 5
    var fontSize: CGFloat = 26
    var filled: Bool = false
    var mosaicBlock: CGFloat = 14
    var cornerRadius: CGFloat = 0
}

enum ElementKind: Equatable {
    case image(UUID)
    case arrow
    case line
    case rect
    case ellipse
    case mosaic
    case text(String)
    case badge(Int)
    /// 範囲を背景色（透過設定なら透明）で塗りつぶして消す
    case erase
}

struct Element: Identifiable, Equatable {
    var id = UUID()
    var kind: ElementKind
    var p0: CGPoint
    var p1: CGPoint
    var style: ElementStyle

    var frame: CGRect {
        CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
               width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
    }

    mutating func setFrame(_ r: CGRect) {
        p0 = CGPoint(x: r.minX, y: r.minY)
        p1 = CGPoint(x: r.maxX, y: r.maxY)
    }

    mutating func translate(by d: CGVector) {
        p0.x += d.dx; p0.y += d.dy
        p1.x += d.dx; p1.y += d.dy
    }

    var isLinear: Bool {
        switch kind {
        case .arrow, .line: return true
        default: return false
        }
    }

    var imageID: UUID? {
        if case let .image(id) = kind { return id }
        return nil
    }

    var isImage: Bool { imageID != nil }

    var text: String? {
        if case let .text(s) = kind { return s }
        return nil
    }

    /// 実際に描かれる範囲。線幅・矢印の頭・文字背景のプレートは frame の外へはみ出す
    var paintedFrame: CGRect {
        switch kind {
        case .image, .mosaic, .badge, .erase:
            return frame
        case .rect, .ellipse, .line:
            return frame.insetBy(dx: -style.lineWidth / 2, dy: -style.lineWidth / 2)
        case .arrow:
            let half = max(style.lineWidth * 1.4, 1.5) * 2.23
            return frame.insetBy(dx: -half, dy: -half)
        case .text:
            return style.filled ? frame.insetBy(dx: -TextMetrics.padding, dy: -TextMetrics.padding) : frame
        }
    }

    var badgeNumber: Int? {
        if case let .badge(n) = kind { return n }
        return nil
    }

    var displayName: String {
        switch kind {
        case .image: return "画像"
        case .arrow: return "矢印"
        case .line: return "直線"
        case .rect: return "四角"
        case .ellipse: return "丸"
        case .mosaic: return "モザイク"
        case .text: return "テキスト"
        case .badge: return "番号"
        case .erase: return "消去"
        }
    }
}

struct CGVector {
    var dx: CGFloat
    var dy: CGFloat
}

enum TextMetrics {
    static func attributed(_ string: String, style: ElementStyle) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineBreakMode = .byClipping
        return NSAttributedString(string: string, attributes: [
            .font: font(size: style.fontSize),
            .foregroundColor: style.color.ns,
            .paragraphStyle: para,
        ])
    }

    static func font(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    static func size(_ string: String, style: ElementStyle) -> CGSize {
        let text = string.isEmpty ? " " : string
        let rect = attributed(text, style: style).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(rect.width) + 2, height: ceil(rect.height))
    }

    static var padding: CGFloat { 6 }
}
