import AppKit
import CoreGraphics

/// キャンバスの内容を CGImage に描く。画面表示と書き出しで同じコードを使う。
enum Renderer {
    static func makeImage(doc: Doc, scale: CGFloat, includeDraft: Bool = true) -> CGImage? {
        var list = doc.elements
        if includeDraft, let d = doc.draft { list.append(d) }
        return makeImage(doc: doc,
                         elements: list,
                         region: CGRect(origin: .zero, size: doc.canvasSize),
                         scale: scale,
                         background: doc.transparentBackground ? nil : doc.background)
    }

    /// 渡した要素だけを region の範囲で描く。background に nil を渡すと背景は透過
    static func makeImage(doc: Doc, elements: [Element], region: CGRect, scale: CGFloat, background: RGBA?) -> CGImage? {
        guard region.width > 0, region.height > 0 else { return nil }
        let w = max(1, Int((region.width * scale).rounded()))
        let h = max(1, Int((region.height * scale).rounded()))
        guard w < 20000, h < 20000 else { return nil }

        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        // キャンバス座標（左上原点・y 下向き）に合わせ、region の左上を原点に持ってくる
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -region.minX, y: -region.minY)

        if let background {
            ctx.setFillColor(background.cg)
            ctx.fill(region)
        }

        for el in elements {
            draw(el, in: ctx, doc: doc, scale: scale, origin: region.origin)
        }

        return ctx.makeImage()
    }

    // MARK: - 要素ごとの描画

    private static func draw(_ el: Element, in ctx: CGContext, doc: Doc, scale: CGFloat, origin: CGPoint) {
        switch el.kind {
        case let .image(key):
            guard let img = doc.image(for: key) else { return }
            drawImage(img, in: el.frame, ctx: ctx)
        case .rect:
            drawRect(el, ctx: ctx)
        case .ellipse:
            drawEllipse(el, ctx: ctx)
        case .line:
            drawLine(el, ctx: ctx)
        case .arrow:
            drawArrow(el, ctx: ctx)
        case .mosaic:
            drawMosaic(el, ctx: ctx, scale: scale, origin: origin)
        case let .text(s):
            drawText(s, el: el, ctx: ctx)
        case let .badge(n):
            drawBadge(n, el: el, ctx: ctx)
        case .erase:
            drawErase(el, ctx: ctx, doc: doc)
        }
    }

    /// 範囲を消す。背景透過の設定なら本当に穴を開け、そうでなければ背景色で塗る
    private static func drawErase(_ el: Element, ctx: CGContext, doc: Doc) {
        let r = el.frame
        guard r.width > 0.5, r.height > 0.5 else { return }
        ctx.saveGState()
        if doc.transparentBackground {
            ctx.setBlendMode(.clear)
            ctx.fill(r)
        } else {
            ctx.setFillColor(doc.background.cg)
            ctx.fill(r)
        }
        ctx.restoreGState()
    }

    private static func drawImage(_ img: CGImage, in frame: CGRect, ctx: CGContext) {
        guard frame.width > 0, frame.height > 0 else { return }
        ctx.saveGState()
        ctx.translateBy(x: frame.minX, y: frame.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        ctx.restoreGState()
    }

    private static func drawRect(_ el: Element, ctx: CGContext) {
        let r = el.frame
        guard r.width > 0.5, r.height > 0.5 else { return }
        let path: CGPath
        if el.style.cornerRadius > 0 {
            let radius = min(el.style.cornerRadius, min(r.width, r.height) / 2)
            path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        } else {
            path = CGPath(rect: r, transform: nil)
        }
        ctx.saveGState()
        if el.style.filled {
            ctx.addPath(path)
            ctx.setFillColor(el.style.color.withAlpha(0.28).cg)
            ctx.fillPath()
        }
        ctx.addPath(path)
        ctx.setStrokeColor(el.style.color.cg)
        ctx.setLineWidth(el.style.lineWidth)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawEllipse(_ el: Element, ctx: CGContext) {
        let r = el.frame
        guard r.width > 0.5, r.height > 0.5 else { return }
        ctx.saveGState()
        if el.style.filled {
            ctx.setFillColor(el.style.color.withAlpha(0.28).cg)
            ctx.fillEllipse(in: r)
        }
        ctx.setStrokeColor(el.style.color.cg)
        ctx.setLineWidth(el.style.lineWidth)
        ctx.strokeEllipse(in: r)
        ctx.restoreGState()
    }

    private static func drawLine(_ el: Element, ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(el.style.color.cg)
        ctx.setLineWidth(el.style.lineWidth)
        ctx.setLineCap(.round)
        ctx.move(to: el.p0)
        ctx.addLine(to: el.p1)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Skitch 風の矢印。尾から先端へ向かって太くなる軸と、軸幅の約 2.2 倍の三角形の頭を
    /// 1 本の塗りつぶしパスで描く。比率は Skitch の矢印を実測して合わせている。
    private static func drawArrow(_ el: Element, ctx: CGContext) {
        let a = el.p0, b = el.p1
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 1 else { return }
        let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
        let nx = -uy, ny = ux

        let shaftHalf = max(el.style.lineWidth * 1.4, 1.5)
        let headHalf = min(shaftHalf * 2.23, len * 0.3)
        let headLen = headHalf * 2.0
        let shaftLen = len - headLen
        // 尾は軸幅の約 17% まで細くなる（指数的に絞る）
        let taper: CGFloat = 1.55
        let steps = 10

        // b を原点に、進行方向の逆向き along・法線方向 across で頂点を作る
        func pt(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: b.x - ux * along + nx * across, y: b.y - uy * along + ny * across)
        }
        func shaftPoint(_ i: Int, sign: CGFloat) -> CGPoint {
            let f = CGFloat(i) / CGFloat(steps)
            return pt(headLen + shaftLen * f, sign * shaftHalf * exp(-taper * f))
        }

        ctx.saveGState()
        ctx.setFillColor(el.style.color.cg)
        ctx.beginPath()
        ctx.move(to: b)
        ctx.addLine(to: pt(headLen, headHalf))
        for i in 0...steps { ctx.addLine(to: shaftPoint(i, sign: 1)) }
        for i in stride(from: steps, through: 0, by: -1) { ctx.addLine(to: shaftPoint(i, sign: -1)) }
        ctx.addLine(to: pt(headLen, -headHalf))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawText(_ string: String, el: Element, ctx: CGContext) {
        guard !string.isEmpty else { return }
        let attributed = TextMetrics.attributed(string, style: el.style)
        let size = TextMetrics.size(string, style: el.style)
        let origin = CGPoint(x: el.frame.minX, y: el.frame.minY)

        if el.style.filled {
            let pad = TextMetrics.padding
            let plate = CGRect(x: origin.x - pad, y: origin.y - pad * 0.6,
                              width: size.width + pad * 2, height: size.height + pad * 1.2)
            let radius = min(8, plate.height / 3)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(el.style.color.readableBackdrop.cg)
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        attributed.draw(with: CGRect(origin: origin, size: CGSize(width: size.width + 4, height: size.height + 4)),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    private static func drawBadge(_ number: Int, el: Element, ctx: CGContext) {
        let r = el.frame
        guard r.width > 2, r.height > 2 else { return }
        let side = min(r.width, r.height)
        let circle = CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)

        ctx.saveGState()
        ctx.setFillColor(el.style.color.cg)
        ctx.fillEllipse(in: circle)
        ctx.setStrokeColor(RGBA(r: 1, g: 1, b: 1, a: 0.95).cg)
        ctx.setLineWidth(max(1.5, side * 0.06))
        ctx.strokeEllipse(in: circle.insetBy(dx: side * 0.03, dy: side * 0.03))
        ctx.restoreGState()

        let fontSize = side * 0.58
        let label = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let ls = label.size()
        let origin = CGPoint(x: circle.midX - ls.width / 2, y: circle.midY - ls.height / 2)

        ctx.saveGState()
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        label.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    /// すでに描かれたピクセルを読み戻してブロック平均で塗り直す
    private static func drawMosaic(_ el: Element, ctx: CGContext, scale: CGFloat, origin: CGPoint) {
        let r = el.frame.intersection(CGRect(x: origin.x, y: origin.y,
                                             width: CGFloat(ctx.width) / scale, height: CGFloat(ctx.height) / scale))
        guard r.width > 1, r.height > 1, let base = ctx.data else { return }
        ctx.flush()

        let bytesPerRow = ctx.bytesPerRow
        let maxX = ctx.width, maxY = ctx.height
        let block = max(2, el.style.mosaicBlock)

        var blocks: [(CGRect, RGBA)] = []
        var y = r.minY
        while y < r.maxY {
            let bh = min(block, r.maxY - y)
            var x = r.minX
            while x < r.maxX {
                let bw = min(block, r.maxX - x)
                let x0 = max(0, Int(((x - origin.x) * scale).rounded(.down)))
                let y0 = max(0, Int(((y - origin.y) * scale).rounded(.down)))
                let x1 = min(maxX, max(x0 + 1, Int(((x + bw - origin.x) * scale).rounded(.up))))
                let y1 = min(maxY, max(y0 + 1, Int(((y + bh - origin.y) * scale).rounded(.up))))
                if x0 < x1, y0 < y1 {
                    let strideX = max(1, (x1 - x0) / 8)
                    let strideY = max(1, (y1 - y0) / 8)
                    var sr = 0.0, sg = 0.0, sb = 0.0, sa = 0.0, n = 0.0
                    var py = y0
                    while py < y1 {
                        let row = base.advanced(by: py * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                        var px = x0
                        while px < x1 {
                            let o = px * 4
                            sr += Double(row[o]); sg += Double(row[o + 1]); sb += Double(row[o + 2]); sa += Double(row[o + 3])
                            n += 1
                            px += strideX
                        }
                        py += strideY
                    }
                    if n > 0, sa > 0 {
                        // premultiplied のまま平均し、平均アルファで割り戻す
                        let alpha = min(1, sa / n / 255.0)
                        let clamp = { (v: Double) in min(1, max(0, v / n / 255.0 / alpha)) }
                        let color = RGBA(r: clamp(sr), g: clamp(sg), b: clamp(sb), a: alpha)
                        blocks.append((CGRect(x: x, y: y, width: bw, height: bh), color))
                    }
                }
                x += block
            }
            y += block
        }

        // 読み取りが終わってから塗る（塗った色を隣のブロックが読まないように）
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        for (rect, color) in blocks {
            ctx.setFillColor(color.cg)
            ctx.fill(rect)
        }
        ctx.restoreGState()
    }
}
