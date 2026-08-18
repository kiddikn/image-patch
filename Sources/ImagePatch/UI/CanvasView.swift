import AppKit
import SwiftUI

enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case start, end
}

/// メニューやツールバーからキャンバス本体を操作するための橋渡し
final class CanvasBridge {
    static let shared = CanvasBridge()
    weak var view: CanvasNSView?
}

struct CanvasRepresentable: NSViewRepresentable {
    @ObservedObject var doc: Doc

    func makeNSView(context: Context) -> CanvasNSView {
        CanvasNSView(doc: doc)
    }

    func updateNSView(_ view: CanvasNSView, context: Context) {
        view.docDidChange()
    }
}

final class CanvasNSView: NSView, NSTextViewDelegate {
    let doc: Doc

    private var zoom: CGFloat = 1
    private var origin = CGPoint.zero
    private var autoFit = true
    private var lastCanvasSize = CGSize.zero

    private var renderCache: (revision: Int, scale: CGFloat, image: CGImage)?
    private var isInteracting = false

    private var cropRect: CGRect?
    private var editingID: UUID?
    private var textEditor: NSTextView?

    private enum DragState {
        case none
        case create(CGPoint)
        case move(origin: CGPoint, snapshot: [UUID: (CGPoint, CGPoint)])
        case resize(id: UUID, handle: Handle, original: Element)
        case marquee(CGPoint, CGRect, Set<UUID>)
        case crop(CGPoint)
        case pan(CGPoint, CGPoint)
    }

    private var drag = DragState.none
    /// 実際に動かし始めてから undo を積む（クリックだけで空の undo を作らない）
    private var pendingCheckpoint = false

    init(doc: Doc) {
        self.doc = doc
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        CanvasBridge.shared.view = self
    }

    var isEditingText: Bool { editingID != nil }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    // MARK: - 座標変換

    private func toCanvas(_ p: NSPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) / zoom, y: (p.y - origin.y) / zoom)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + origin.x, y: p.y * zoom + origin.y)
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * zoom + origin.x, y: r.minY * zoom + origin.y,
               width: r.width * zoom, height: r.height * zoom)
    }

    private var canvasViewRect: CGRect {
        viewRect(CGRect(origin: .zero, size: doc.canvasSize))
    }

    // MARK: - ズーム

    func fitToWindow() {
        let inset: CGFloat = 40
        let available = CGSize(width: max(80, bounds.width - inset), height: max(80, bounds.height - inset))
        let z = min(available.width / doc.canvasSize.width, available.height / doc.canvasSize.height)
        zoom = min(1, max(0.05, z))
        centerCanvas()
        autoFit = true
        setNeedsDisplay(bounds)
    }

    /// キャンバスを画面外まで飛ばしてしまわないように寄せる
    private func clampOrigin() {
        let shown = CGSize(width: doc.canvasSize.width * zoom, height: doc.canvasSize.height * zoom)
        let keep: CGFloat = 80
        origin.x = min(max(origin.x, -(shown.width - keep)), bounds.width - keep)
        origin.y = min(max(origin.y, -(shown.height - keep)), bounds.height - keep)
    }

    private func centerCanvas() {
        origin = CGPoint(x: ((bounds.width - doc.canvasSize.width * zoom) / 2).rounded(),
                         y: ((bounds.height - doc.canvasSize.height * zoom) / 2).rounded())
    }

    func setZoom(_ z: CGFloat, anchor: CGPoint? = nil) {
        let a = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let canvasAnchor = toCanvas(a)
        zoom = min(8, max(0.05, z))
        origin = CGPoint(x: a.x - canvasAnchor.x * zoom, y: a.y - canvasAnchor.y * zoom)
        autoFit = false
        setNeedsDisplay(bounds)
    }

    var currentZoom: CGFloat { zoom }

    func zoomIn() { setZoom(zoom * 1.25) }
    func zoomOut() { setZoom(zoom / 1.25) }

    private var lastBoundsSize = CGSize.zero

    override func layout() {
        super.layout()
        // サブビュー追加でも layout は走るので、実際にサイズが変わったときだけ作り直す
        guard bounds.size != lastBoundsSize else { return }
        lastBoundsSize = bounds.size
        endTextEditing()
        if autoFit { fitToWindow() }
    }

    func docDidChange() {
        if doc.canvasSize != lastCanvasSize {
            lastCanvasSize = doc.canvasSize
            if autoFit { fitToWindow() }
        }
        // ツールバーからツールを切り替えたときもトリミング枠を片付ける
        if doc.tool != .crop, cropRect != nil {
            cropRect = nil
        }
        refreshTextEditor()
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
        setNeedsDisplay(bounds)
    }

    override func resetCursorRects() {
        let cursor: NSCursor = doc.tool == .select ? .arrow : .crosshair
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(NSColor(calibratedWhite: 0.16, alpha: 1).cgColor)
        ctx.fill(bounds)

        let canvas = canvasViewRect
        if doc.transparentBackground {
            drawCheckerboard(in: canvas, ctx: ctx)
        }

        let backing = window?.backingScaleFactor ?? 2
        var scale = min(3, max(0.4, zoom * backing))
        if isInteracting { scale = min(scale, max(0.5, zoom)) }

        if let image = cachedImage(scale: scale) {
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.translateBy(x: canvas.minX, y: canvas.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
            ctx.restoreGState()
        }

        ctx.setStrokeColor(NSColor(calibratedWhite: 0.45, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(canvas.insetBy(dx: -0.5, dy: -0.5))

        drawSelection(ctx: ctx)
        drawCropOverlay(ctx: ctx)
        drawMarquee(ctx: ctx)
    }

    private func cachedImage(scale: CGFloat) -> CGImage? {
        if let c = renderCache, c.revision == doc.revision, abs(c.scale - scale) < 0.001 {
            return c.image
        }
        guard let image = Renderer.makeImage(doc: doc, scale: scale) else { return nil }
        renderCache = (doc.revision, scale, image)
        return image
    }

    private func drawCheckerboard(in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setFillColor(NSColor(calibratedWhite: 0.85, alpha: 1).cgColor)
        ctx.fill(rect)
        ctx.setFillColor(NSColor(calibratedWhite: 0.72, alpha: 1).cgColor)
        let size: CGFloat = 10
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : size)
            while x < rect.maxX {
                ctx.fill(CGRect(x: x, y: y, width: size, height: size).intersection(rect))
                x += size * 2
            }
            y += size
            row += 1
        }
        ctx.restoreGState()
    }

    private func drawSelection(ctx: CGContext) {
        guard editingID == nil else { return }
        for el in doc.selectedElements {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            if el.isLinear {
                ctx.saveGState()
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.move(to: toView(el.p0))
                ctx.addLine(to: toView(el.p1))
                ctx.strokePath()
                ctx.restoreGState()
            } else {
                ctx.saveGState()
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.stroke(viewRect(el.frame).insetBy(dx: -1, dy: -1))
                ctx.restoreGState()
            }
            for (_, p) in handlePositions(for: el) {
                let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(r)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.stroke(r)
            }
        }
    }

    private func drawCropOverlay(ctx: CGContext) {
        guard let crop = cropRect else { return }
        let r = viewRect(crop)
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addRect(canvasViewRect)
        ctx.addRect(r)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r)
        ctx.restoreGState()

        let label = NSAttributedString(string: "\(Int(crop.width))×\(Int(crop.height))  Enter で確定 / Esc で取消", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        let box = CGRect(x: r.minX, y: max(2, r.minY - size.height - 6), width: size.width + 12, height: size.height + 6)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.fill(box)
        label.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }

    private func drawMarquee(ctx: CGContext) {
        guard case let .marquee(_, rect, _) = drag else { return }
        let r = viewRect(rect)
        ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor)
        ctx.fill(r)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r)
    }

    // MARK: - ハンドル

    private func handlePositions(for el: Element) -> [(Handle, CGPoint)] {
        if el.isLinear {
            return [(.start, toView(el.p0)), (.end, toView(el.p1))]
        }
        let r = viewRect(el.frame)
        return [
            (.topLeft, CGPoint(x: r.minX, y: r.minY)),
            (.top, CGPoint(x: r.midX, y: r.minY)),
            (.topRight, CGPoint(x: r.maxX, y: r.minY)),
            (.right, CGPoint(x: r.maxX, y: r.midY)),
            (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)),
            (.bottom, CGPoint(x: r.midX, y: r.maxY)),
            (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
            (.left, CGPoint(x: r.minX, y: r.midY)),
        ]
    }

    private func handleHit(at viewPoint: CGPoint) -> (UUID, Handle)? {
        for el in doc.selectedElements {
            for (handle, p) in handlePositions(for: el) {
                if abs(p.x - viewPoint.x) <= 6, abs(p.y - viewPoint.y) <= 6 {
                    return (el.id, handle)
                }
            }
        }
        return nil
    }

    // MARK: - マウス

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let p = toCanvas(viewPoint)
        let shift = event.modifierFlags.contains(.shift)

        if editingID != nil {
            endTextEditing()
            return
        }

        if event.clickCount == 2 {
            if let el = doc.hitTest(p), el.text != nil {
                doc.selection = [el.id]
                beginTextEditing(el.id)
                return
            }
            if let crop = cropRect {
                applyCrop(crop)
                return
            }
        }

        if event.modifierFlags.contains(.command) {
            drag = .pan(viewPoint, origin)
            return
        }

        switch doc.tool {
        case .crop:
            cropRect = nil
            drag = .crop(p)
        case .select:
            if let (id, handle) = handleHit(at: viewPoint), let el = doc.element(id) {
                pendingCheckpoint = true
                drag = .resize(id: id, handle: handle, original: el)
                isInteracting = true
            } else if let el = doc.hitTest(p) {
                if shift {
                    if doc.selection.contains(el.id) {
                        doc.selection.remove(el.id)
                    } else {
                        doc.selection.insert(el.id)
                    }
                } else if !doc.selection.contains(el.id) {
                    doc.selection = [el.id]
                }
                pendingCheckpoint = true
                var snapshot: [UUID: (CGPoint, CGPoint)] = [:]
                for s in doc.selectedElements { snapshot[s.id] = (s.p0, s.p1) }
                drag = .move(origin: p, snapshot: snapshot)
                isInteracting = true
                doc.touch()
            } else {
                let base = shift ? doc.selection : []
                doc.selection = base
                drag = .marquee(p, CGRect(origin: p, size: .zero), base)
                doc.touch()
            }
        case .text:
            createText(at: p)
        case .badge:
            createBadge(at: p)
        default:
            drag = .create(p)
            doc.draft = newElement(kind: draftKind(), from: p, to: p)
            isInteracting = true
        }
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        var p = toCanvas(viewPoint)
        let shift = event.modifierFlags.contains(.shift)

        switch drag {
        case .none:
            return
        case let .pan(start, base):
            origin = CGPoint(x: base.x + (viewPoint.x - start.x), y: base.y + (viewPoint.y - start.y))
            clampOrigin()
            autoFit = false
        case let .create(start):
            if shift { p = constrain(from: start, to: p, square: doc.tool != .arrow && doc.tool != .line) }
            doc.draft = newElement(kind: draftKind(), from: start, to: p)
        case let .move(startPoint, snapshot):
            takeCheckpointIfNeeded()
            var dx = p.x - startPoint.x
            var dy = p.y - startPoint.y
            if shift {
                if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
            }
            for (id, base) in snapshot {
                doc.update(id) {
                    $0.p0 = CGPoint(x: base.0.x + dx, y: base.0.y + dy)
                    $0.p1 = CGPoint(x: base.1.x + dx, y: base.1.y + dy)
                }
            }
        case let .resize(id, handle, original):
            takeCheckpointIfNeeded()
            doc.update(id) { $0 = resized(original, handle: handle, to: p, lockAspect: shift) }
        case let .marquee(start, _, base):
            let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                           width: abs(p.x - start.x), height: abs(p.y - start.y))
            drag = .marquee(start, r, base)
            doc.selection = base.union(doc.elements.filter { $0.frame.intersects(r) }.map(\.id))
        case let .crop(start):
            cropRect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                              width: abs(p.x - start.x), height: abs(p.y - start.y))
                .intersection(CGRect(origin: .zero, size: doc.canvasSize))
        }
        setNeedsDisplay(bounds)
    }

    private func takeCheckpointIfNeeded() {
        guard pendingCheckpoint else { return }
        pendingCheckpoint = false
        doc.checkpoint()
    }

    override func mouseUp(with event: NSEvent) {
        isInteracting = false
        pendingCheckpoint = false
        switch drag {
        case let .create(start):
            if let d = doc.draft {
                let big = max(d.frame.width, d.frame.height)
                let length = hypot(d.p1.x - d.p0.x, d.p1.y - d.p0.y)
                doc.draft = nil
                if (d.isLinear && length >= 8) || (!d.isLinear && big >= 6) {
                    doc.add(d)
                } else if !d.isLinear {
                    // クリックだけなら既定サイズで置く
                    var el = d
                    let side: CGFloat = max(80, doc.style.fontSize * 4)
                    el.setFrame(CGRect(x: start.x, y: start.y, width: side, height: side * 0.6))
                    doc.add(el)
                }
            }
        case .move, .resize:
            if doc.expandCanvasForTexts(doc.selection) {
                doc.status = "文字が入るようにキャンバスを広げました"
            }
        case .marquee:
            break
        default:
            break
        }
        drag = .none
        doc.touch()
        setNeedsDisplay(bounds)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let viewPoint = convert(event.locationInWindow, from: nil)
            setZoom(zoom * (1 + event.scrollingDeltaY * 0.01), anchor: viewPoint)
            return
        }
        origin = CGPoint(x: origin.x + event.scrollingDeltaX, y: origin.y + event.scrollingDeltaY)
        clampOrigin()
        autoFit = false
        setNeedsDisplay(bounds)
    }

    override func magnify(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        setZoom(zoom * (1 + event.magnification), anchor: viewPoint)
    }

    // MARK: - 要素生成

    private func draftKind() -> ElementKind {
        switch doc.tool {
        case .arrow: return .arrow
        case .line: return .line
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .mosaic: return .mosaic
        default: return .rect
        }
    }

    private func newElement(kind: ElementKind, from a: CGPoint, to b: CGPoint) -> Element {
        Element(kind: kind, p0: a, p1: b, style: doc.style)
    }

    private func constrain(from a: CGPoint, to b: CGPoint, square: Bool) -> CGPoint {
        if square {
            let side = max(abs(b.x - a.x), abs(b.y - a.y))
            return CGPoint(x: a.x + (b.x < a.x ? -side : side), y: a.y + (b.y < a.y ? -side : side))
        }
        let dx = b.x - a.x, dy = b.y - a.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let len = hypot(dx, dy)
        return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
    }

    private func createBadge(at p: CGPoint) {
        let side = max(36, doc.style.fontSize * 1.7)
        var el = Element(kind: .badge(doc.nextBadgeNumber), p0: .zero, p1: .zero, style: doc.style)
        el.setFrame(CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side))
        doc.add(el)
        doc.status = "番号 \(el.badgeNumber ?? 1) を置きました"
    }

    private func createText(at p: CGPoint) {
        var el = Element(kind: .text(""), p0: p, p1: p, style: doc.style)
        let size = TextMetrics.size("テキスト", style: doc.style)
        el.setFrame(CGRect(origin: p, size: size))
        doc.add(el)
        doc.expandCanvasForTexts([el.id])
        doc.tool = .select
        beginTextEditing(el.id)
    }

    private func resized(_ el: Element, handle: Handle, to p: CGPoint, lockAspect: Bool) -> Element {
        var out = el
        if el.isLinear {
            if handle == .start { out.p0 = p } else { out.p1 = p }
            return out
        }
        var r = el.frame
        switch handle {
        case .topLeft: r = CGRect(x: p.x, y: p.y, width: r.maxX - p.x, height: r.maxY - p.y)
        case .top: r = CGRect(x: r.minX, y: p.y, width: r.width, height: r.maxY - p.y)
        case .topRight: r = CGRect(x: r.minX, y: p.y, width: p.x - r.minX, height: r.maxY - p.y)
        case .right: r = CGRect(x: r.minX, y: r.minY, width: p.x - r.minX, height: r.height)
        case .bottomRight: r = CGRect(x: r.minX, y: r.minY, width: p.x - r.minX, height: p.y - r.minY)
        case .bottom: r = CGRect(x: r.minX, y: r.minY, width: r.width, height: p.y - r.minY)
        case .bottomLeft: r = CGRect(x: p.x, y: r.minY, width: r.maxX - p.x, height: p.y - r.minY)
        case .left: r = CGRect(x: p.x, y: r.minY, width: r.maxX - p.x, height: r.height)
        case .start, .end: break
        }
        r = CGRect(x: r.minX, y: r.minY, width: max(8, r.width), height: max(8, r.height))

        // 画像は常に縦横比を保つ
        if el.isImage, let natural = doc.naturalSize(of: el), natural.width > 0 {
            let ratio = natural.height / natural.width
            switch handle {
            case .top, .bottom:
                r.size.width = (r.height / ratio).rounded()
            default:
                r.size.height = (r.width * ratio).rounded()
            }
            if handle == .topLeft || handle == .left || handle == .bottomLeft {
                r.origin.x = el.frame.maxX - r.width
            }
            if handle == .topLeft || handle == .top || handle == .topRight {
                r.origin.y = el.frame.maxY - r.height
            }
        }

        if case let .text(s) = el.kind {
            // テキストは枠ではなく文字サイズを変える
            let base = TextMetrics.size(s, style: el.style)
            guard base.height > 0 else { return el }
            let factor = max(0.2, r.height / base.height)
            out.style.fontSize = max(8, (el.style.fontSize * factor).rounded())
            let newSize = TextMetrics.size(s, style: out.style)
            out.setFrame(CGRect(origin: el.frame.origin, size: newSize))
            return out
        }

        out.setFrame(r)
        return out
    }

    // MARK: - テキスト編集

    private func editorFrame(for el: Element) -> NSRect {
        let f = viewRect(el.frame)
        return NSRect(x: f.minX - 5, y: f.minY - 4,
                      width: max(80, f.width + 40), height: max(26, f.height + 10))
    }

    /// キャンバスが広がってズームや位置が変わっても入力欄を追従させる
    private func refreshTextEditor() {
        guard let id = editingID, let editor = textEditor, let el = doc.element(id) else { return }
        let size = max(9, el.style.fontSize * zoom)
        if abs((editor.font?.pointSize ?? 0) - size) > 0.5 {
            editor.font = TextMetrics.font(size: size)
        }
        editor.frame = editorFrame(for: el)
    }

    private func beginTextEditing(_ id: UUID) {
        guard let el = doc.element(id), el.text != nil else { return }
        endTextEditing()
        editingID = id

        let editor = NSTextView(frame: editorFrame(for: el))
        editor.font = TextMetrics.font(size: max(9, el.style.fontSize * zoom))
        editor.textColor = el.style.color.ns
        editor.drawsBackground = true
        editor.backgroundColor = NSColor.white.withAlphaComponent(0.94)
        editor.insertionPointColor = NSColor.black
        editor.isRichText = false
        editor.allowsUndo = true
        editor.textContainerInset = NSSize(width: 3, height: 3)
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: 20000, height: 20000)
        editor.string = el.text ?? ""
        editor.delegate = self
        addSubview(editor)
        textEditor = editor
        window?.makeFirstResponder(editor)
        editor.selectAll(nil)
        doc.status = "入力して Esc または枠外クリックで確定"
    }

    func textDidChange(_ notification: Notification) {
        guard let id = editingID, let editor = textEditor else { return }
        let s = editor.string
        doc.update(id) {
            $0.kind = .text(s)
            let size = TextMetrics.size(s, style: $0.style)
            $0.setFrame(CGRect(origin: $0.frame.origin, size: size))
        }
        doc.expandCanvasForTexts([id])
        refreshTextEditor()
        setNeedsDisplay(bounds)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing()
            return true
        }
        return false
    }

    @discardableResult
    func endTextEditing() -> Bool {
        guard let id = editingID, let editor = textEditor else { return false }
        let s = editor.string
        editingID = nil
        textEditor = nil
        editor.removeFromSuperview()
        window?.makeFirstResponder(self)

        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.elements.removeAll { $0.id == id }
            doc.selection = []
        } else {
            doc.update(id) {
                $0.kind = .text(s)
                $0.setFrame(CGRect(origin: $0.frame.origin, size: TextMetrics.size(s, style: $0.style)))
            }
            if doc.expandCanvasForTexts([id]) {
                doc.status = "文字が入るようにキャンバスを広げました"
            }
        }
        doc.touch()
        setNeedsDisplay(bounds)
        return true
    }

    // MARK: - トリミング

    private func applyCrop(_ rect: CGRect) {
        doc.crop(to: rect)
        cropRect = nil
        doc.tool = .select
        if autoFit { fitToWindow() }
        setNeedsDisplay(bounds)
    }

    func confirmCrop() {
        if let c = cropRect { applyCrop(c) }
    }

    // MARK: - キーボード

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        let key = event.keyCode

        // Delete / Backspace
        if key == 51 || key == 117 {
            doc.deleteSelection()
            setNeedsDisplay(bounds)
            return
        }
        // Escape
        if key == 53 {
            if endTextEditing() { return }
            if cropRect != nil {
                cropRect = nil
                doc.tool = .select
                setNeedsDisplay(bounds)
                return
            }
            doc.selection = []
            doc.touch()
            return
        }
        // Return
        if key == 36 {
            if cropRect != nil { confirmCrop(); return }
            if let id = doc.selection.first, doc.element(id)?.text != nil {
                beginTextEditing(id)
                return
            }
        }
        // 矢印キーで微調整
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch key {
        case 123: doc.nudgeSelection(dx: -step, dy: 0); return
        case 124: doc.nudgeSelection(dx: step, dy: 0); return
        case 125: doc.nudgeSelection(dx: 0, dy: step); return
        case 126: doc.nudgeSelection(dx: 0, dy: -step); return
        default: break
        }

        if !event.modifierFlags.contains(.command),
           let tool = Tool.allCases.first(where: { $0.key == chars.lowercased() }) {
            doc.tool = tool
            if tool != .crop { cropRect = nil }
            docDidChange()
            return
        }

        super.keyDown(with: event)
    }

    // MARK: - ドラッグ＆ドロップ

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var images: [CGImage] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            images = urls.compactMap { Clip.image(fromFile: $0) }
        }
        if images.isEmpty, let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let img = Clip.image(from: data) {
            images = [img]
        }
        guard !images.isEmpty else { return false }
        let dropPoint = toCanvas(convert(sender.draggingLocation, from: nil))
        doc.addImages(images, at: doc.elements.isEmpty ? nil : dropPoint)
        return true
    }
}
