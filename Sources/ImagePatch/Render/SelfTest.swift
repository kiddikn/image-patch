import AppKit
import CoreGraphics

/// 全ツールを 1 枚に描いて PNG に落とす。レンダラの回帰確認用。
enum SelfTest {
    static func run(writingTo path: String) {
        let doc = Doc.shared
        doc.addImages([sampleImage(width: 640, height: 400, hue: 0.58),
                       sampleImage(width: 420, height: 400, hue: 0.10)])
        doc.arrangeImages(.row)

        let box = doc.contentBounds
        var style = ElementStyle()
        style.lineWidth = 6
        style.fontSize = 30
        style.mosaicBlock = 16

        var arrow = Element(kind: .arrow, p0: CGPoint(x: box.minX + 60, y: box.minY + 60),
                            p1: CGPoint(x: box.minX + 300, y: box.minY + 220), style: style)
        arrow.style.color = .red

        var rect = Element(kind: .rect, p0: .zero, p1: .zero, style: style)
        rect.style.color = .blue
        rect.style.cornerRadius = 12
        rect.setFrame(CGRect(x: box.minX + 320, y: box.minY + 60, width: 240, height: 120))

        var ellipse = Element(kind: .ellipse, p0: .zero, p1: .zero, style: style)
        ellipse.style.color = .green
        ellipse.style.filled = true
        ellipse.setFrame(CGRect(x: box.minX + 60, y: box.minY + 260, width: 200, height: 110))

        var line = Element(kind: .line, p0: CGPoint(x: box.minX + 320, y: box.minY + 320),
                           p1: CGPoint(x: box.minX + 580, y: box.minY + 250), style: style)
        line.style.color = .purple

        var mosaic = Element(kind: .mosaic, p0: .zero, p1: .zero, style: style)
        mosaic.setFrame(CGRect(x: box.minX + 700, y: box.minY + 80, width: 300, height: 160))

        var text = Element(kind: .text("ここに注釈テキスト"), p0: .zero, p1: .zero, style: style)
        text.style.color = .black
        text.style.filled = true
        text.setFrame(CGRect(origin: CGPoint(x: box.minX + 700, y: box.minY + 280),
                             size: TextMetrics.size("ここに注釈テキスト", style: text.style)))

        var badge = Element(kind: .badge(1), p0: .zero, p1: .zero, style: style)
        badge.style.color = .orange
        badge.setFrame(CGRect(x: box.minX + 620, y: box.minY + 60, width: 54, height: 54))

        for el in [arrow, rect, ellipse, line, mosaic, text, badge] {
            doc.add(el, select: false)
        }
        doc.fitCanvasToContent()

        guard let data = Clip.pngData(doc: doc) else {
            FileHandle.standardError.write(Data("selftest: render failed\n".utf8))
            exit(1)
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("selftest: wrote \(path) (\(Int(doc.canvasSize.width))x\(Int(doc.canvasSize.height)), \(doc.elements.count) elements)")

        // 選択コピー（⌘C / ⌘X）の切り出しも確認する
        writeSelection(doc: doc, ids: [arrow.id, text.id], base: path, suffix: "-selection")
        writeSelection(doc: doc, ids: [mosaic.id], base: path, suffix: "-selection-mosaic")

        // 範囲消し（トリミングツール ＋ ⌘X）の確認
        doc.selection = []
        let band = CGRect(x: doc.canvasSize.width * 0.12, y: doc.canvasSize.height * 0.5,
                          width: doc.canvasSize.width * 0.76, height: 90)
        doc.erase(band)
        if let data = Clip.pngData(doc: doc) {
            let out = output(base: path, suffix: "-erase")
            try? data.write(to: URL(fileURLWithPath: out))
            print("selftest: wrote \(out) (\(Int(band.width))x\(Int(band.height)) を消去)")
        }

        // 背景透過のときは本当に穴が開く
        doc.transparentBackground = true
        if let data = Clip.pngData(doc: doc) {
            let out = output(base: path, suffix: "-erase-transparent")
            try? data.write(to: URL(fileURLWithPath: out))
            print("selftest: wrote \(out) (背景透過)")
        }
    }

    private static func output(base: String, suffix: String) -> String {
        let url = URL(fileURLWithPath: base)
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        return url.deletingPathExtension().path + suffix + "." + ext
    }

    private static func writeSelection(doc: Doc, ids: Set<UUID>, base: String, suffix: String) {
        doc.selection = ids
        guard let data = Clip.selectionPNGData(doc: doc) else {
            FileHandle.standardError.write(Data("selftest: selection render failed\n".utf8))
            exit(1)
        }
        let out = output(base: base, suffix: suffix)
        try? data.write(to: URL(fileURLWithPath: out))
        let box = doc.selectionPaintedBounds.integral
        print("selftest: wrote \(out) (\(Int(box.width))x\(Int(box.height)), \(ids.count) selected)")
    }

    /// モザイクの効きが分かるよう細かい模様を入れたダミー画像
    private static func sampleImage(width: Int, height: Int, hue: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.18, brightness: 0.97, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for row in 0..<(height / 20) {
            for col in 0..<(width / 20) {
                if (row + col) % 2 == 0 { continue }
                ctx.setFillColor(NSColor(hue: hue, saturation: 0.45,
                                         brightness: 0.55 + CGFloat((row * col) % 5) * 0.08, alpha: 1).cgColor)
                ctx.fill(CGRect(x: col * 20 + 3, y: row * 20 + 3, width: 14, height: 14))
            }
        }
        return ctx.makeImage()!
    }
}
