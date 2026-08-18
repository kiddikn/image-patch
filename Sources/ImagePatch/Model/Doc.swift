import AppKit
import Combine
import CoreGraphics

enum ArrangeMode {
    case row
    case column
    case grid
}

final class Doc: ObservableObject {
    static let shared = Doc()

    @Published var elements: [Element] = []
    @Published var draft: Element?
    @Published var selection: Set<UUID> = []
    @Published var canvasSize = CGSize(width: 1100, height: 720)
    @Published var tool: Tool = .select
    @Published var style = ElementStyle()
    @Published var background: RGBA = .white
    @Published var transparentBackground = false
    @Published var exportScale: CGFloat = 1
    @Published var status = "⌘V でスクリーンショットを貼り付け"

    /// 画像実体。element からは UUID で参照する（undo で作り直さないため別管理）
    private(set) var images: [UUID: CGImage] = [:]

    /// 再描画キャッシュの無効化に使う
    @Published private(set) var revision = 0

    let margin: CGFloat = 28
    let gap: CGFloat = 20

    private struct Snapshot {
        var elements: [Element]
        var canvasSize: CGSize
        var selection: Set<UUID>
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private let undoLimit = 60

    // MARK: - 変更通知

    func touch() {
        revision += 1
    }

    private var snapshot: Snapshot {
        Snapshot(elements: elements, canvasSize: canvasSize, selection: selection)
    }

    private func restore(_ s: Snapshot) {
        elements = s.elements
        canvasSize = s.canvasSize
        selection = s.selection
        touch()
    }

    /// 変更前に呼ぶ。以降の変更がひとまとめで undo される
    func checkpoint() {
        undoStack.append(snapshot)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(s)
        status = "元に戻しました"
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(s)
        status = "やり直しました"
    }

    // MARK: - 要素操作

    func element(_ id: UUID) -> Element? {
        elements.first { $0.id == id }
    }

    func index(of id: UUID) -> Int? {
        elements.firstIndex { $0.id == id }
    }

    func update(_ id: UUID, _ body: (inout Element) -> Void) {
        guard let i = index(of: id) else { return }
        body(&elements[i])
        touch()
    }

    var selectedElements: [Element] {
        elements.filter { selection.contains($0.id) }
    }

    /// 画像は常に注釈より下（背面）に積む
    private var firstAnnotationIndex: Int {
        elements.firstIndex { !$0.isImage } ?? elements.count
    }

    func add(_ element: Element, select: Bool = true) {
        checkpoint()
        if element.isImage {
            elements.insert(element, at: firstAnnotationIndex)
        } else {
            elements.append(element)
        }
        if select { selection = [element.id] }
        touch()
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        checkpoint()
        elements.removeAll { selection.contains($0.id) }
        selection = []
        status = "削除しました"
        touch()
    }

    func duplicateSelection() {
        guard !selection.isEmpty else { return }
        checkpoint()
        var newIDs: Set<UUID> = []
        for el in selectedElements {
            var copy = el
            copy.id = UUID()
            copy.translate(by: CGVector(dx: 24, dy: 24))
            if case .badge = copy.kind { copy.kind = .badge(nextBadgeNumber) }
            elements.append(copy)
            newIDs.insert(copy.id)
        }
        selection = newIDs
        touch()
    }

    func selectAll() {
        selection = Set(elements.map(\.id))
        touch()
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard !selection.isEmpty else { return }
        for id in selection {
            update(id) { $0.translate(by: CGVector(dx: dx, dy: dy)) }
        }
        expandCanvasForTexts(selection)
    }

    func bringForward() {
        guard let id = selection.first, let i = index(of: id), i < elements.count - 1 else { return }
        checkpoint()
        elements.swapAt(i, i + 1)
        touch()
    }

    func sendBackward() {
        guard let id = selection.first, let i = index(of: id), i > 0 else { return }
        checkpoint()
        elements.swapAt(i, i - 1)
        touch()
    }

    /// 既定スタイルを変える。選択中の要素があればそれにも反映する
    func applyStyle(_ body: (inout ElementStyle) -> Void) {
        body(&style)
        for id in selection {
            update(id) { el in
                body(&el.style)
                if case let .text(s) = el.kind {
                    el.setFrame(CGRect(origin: el.frame.origin, size: TextMetrics.size(s, style: el.style)))
                }
                if case .badge = el.kind {
                    let side = max(36, el.style.fontSize * 1.7)
                    let f = el.frame
                    el.setFrame(CGRect(x: f.midX - side / 2, y: f.midY - side / 2, width: side, height: side))
                }
            }
        }
        touch()
    }

    var nextBadgeNumber: Int {
        let used = elements.compactMap(\.badgeNumber)
        return (used.max() ?? 0) + 1
    }

    // MARK: - 当たり判定

    func hitTest(_ p: CGPoint) -> Element? {
        for el in elements.reversed() {
            if hits(el, p) { return el }
        }
        return nil
    }

    private func hits(_ el: Element, _ p: CGPoint) -> Bool {
        if el.isLinear {
            let tol = max(8, el.style.lineWidth * 1.5)
            return distance(from: p, toSegment: el.p0, el.p1) <= tol
        }
        return el.frame.insetBy(dx: -2, dy: -2).contains(p)
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 < 0.0001 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - 画像

    func image(for id: UUID) -> CGImage? { images[id] }

    func naturalSize(of el: Element) -> CGSize? {
        guard let id = el.imageID, let img = images[id] else { return nil }
        return CGSize(width: img.width, height: img.height)
    }

    /// 画像を追加する。`at` を渡すとその位置、省略時は既存コンテンツの右隣に置く
    func addImages(_ cgImages: [CGImage], at dropPoint: CGPoint? = nil) {
        guard !cgImages.isEmpty else { return }
        checkpoint()
        var newIDs: Set<UUID> = []
        var next = dropPoint
        for img in cgImages {
            let key = UUID()
            images[key] = img
            let box = contentBounds
            let origin: CGPoint
            if let p = next {
                origin = p
                next = CGPoint(x: p.x + CGFloat(img.width) + gap, y: p.y)
            } else if box.isEmpty {
                origin = CGPoint(x: margin, y: margin)
            } else {
                origin = CGPoint(x: box.maxX + gap, y: box.minY)
            }
            var el = Element(kind: .image(key), p0: origin, p1: origin, style: style)
            el.setFrame(CGRect(origin: origin, size: CGSize(width: img.width, height: img.height)))
            elements.insert(el, at: firstAnnotationIndex)
            newIDs.insert(el.id)
            adaptStyleScale(to: CGFloat(img.width))
        }
        selection = newIDs
        fitCanvasToContent()
        status = cgImages.count == 1 ? "画像を追加しました" : "画像を \(cgImages.count) 枚追加しました"
        touch()
    }

    /// 大きいスクリーンショットで線や文字が細くなりすぎないよう既定サイズを合わせる
    private var styleAdapted = false
    private func adaptStyleScale(to width: CGFloat) {
        guard !styleAdapted else { return }
        styleAdapted = true
        let k = max(1, min(3, (width / 900).rounded(.toNearestOrEven)))
        style.lineWidth = (5 * k).rounded()
        style.fontSize = (26 * k).rounded()
        style.mosaicBlock = (14 * k).rounded()
    }

    // MARK: - キャンバス

    var contentBounds: CGRect {
        var box = CGRect.null
        for el in elements {
            box = box.union(el.frame)
        }
        return box.isNull ? .zero : box
    }

    func fitCanvasToContent() {
        let box = contentBounds
        guard !box.isEmpty else { return }
        let d = CGVector(dx: margin - box.minX, dy: margin - box.minY)
        for i in elements.indices { elements[i].translate(by: d) }
        canvasSize = CGSize(width: (box.width + margin * 2).rounded(.up),
                            height: (box.height + margin * 2).rounded(.up))
        touch()
    }

    /// はみ出した rect が収まるまでキャンバスを広げる。
    /// 左・上へのはみ出しは全要素をずらして吸収する。広げたら true
    @discardableResult
    func expandCanvas(toInclude rect: CGRect) -> Bool {
        guard !rect.isNull, rect.width.isFinite, rect.height.isFinite else { return false }
        let dx = rect.minX < 0 ? (margin - rect.minX).rounded(.up) : 0
        let dy = rect.minY < 0 ? (margin - rect.minY).rounded(.up) : 0
        var w = canvasSize.width + dx
        var h = canvasSize.height + dy
        if rect.maxX + dx > w { w = rect.maxX + dx + margin }
        if rect.maxY + dy > h { h = rect.maxY + dy + margin }
        let size = CGSize(width: w.rounded(.up), height: h.rounded(.up))
        guard dx > 0 || dy > 0 || size != canvasSize else { return false }
        if dx > 0 || dy > 0 {
            let d = CGVector(dx: dx, dy: dy)
            for i in elements.indices { elements[i].translate(by: d) }
            draft?.translate(by: d)
        }
        canvasSize = size
        touch()
        return true
    }

    /// 枠外に置かれたテキストが収まるようにキャンバスを広げる
    @discardableResult
    func expandCanvasForTexts(_ ids: Set<UUID>) -> Bool {
        var box = CGRect.null
        for el in elements where ids.contains(el.id) && el.text != nil {
            // 「文字背景」のプレートは frame より少し外まで描かれる
            box = box.union(el.style.filled ? el.frame.insetBy(dx: -TextMetrics.padding, dy: -TextMetrics.padding) : el.frame)
        }
        guard !box.isNull else { return false }
        return expandCanvas(toInclude: box)
    }

    func fitCanvasToContentWithCheckpoint() {
        checkpoint()
        fitCanvasToContent()
        status = "余白を整えました"
    }

    func crop(to rect: CGRect) {
        let r = rect.intersection(CGRect(origin: .zero, size: canvasSize)).integral
        guard r.width > 8, r.height > 8 else { return }
        checkpoint()
        let d = CGVector(dx: -r.minX, dy: -r.minY)
        for i in elements.indices { elements[i].translate(by: d) }
        canvasSize = r.size
        status = "トリミングしました（\(Int(r.width))×\(Int(r.height))）"
        touch()
    }

    func resizeCanvas(to size: CGSize) {
        checkpoint()
        canvasSize = CGSize(width: max(32, size.width.rounded()), height: max(32, size.height.rounded()))
        touch()
    }

    /// 画像の表示サイズを変える（左上を固定）。注釈は追従しない
    func scaleImage(_ id: UUID, toWidth width: CGFloat) {
        guard let el = element(id), let natural = naturalSize(of: el), natural.width > 0 else { return }
        checkpoint()
        let ratio = natural.height / natural.width
        let f = el.frame
        update(id) { $0.setFrame(CGRect(x: f.minX, y: f.minY, width: width, height: (width * ratio).rounded())) }
        status = "画像を \(Int(width)) px 幅にしました"
    }

    func clearAll() {
        checkpoint()
        elements = []
        selection = []
        draft = nil
        canvasSize = CGSize(width: 1100, height: 720)
        styleAdapted = false
        status = "キャンバスを空にしました"
        touch()
    }

    // MARK: - 並べ替え（複数画像レイアウト）

    func arrangeImages(_ mode: ArrangeMode) {
        let imageIndices = elements.indices.filter { elements[$0].isImage }
        guard imageIndices.count > 1 else { return }
        checkpoint()

        let frames = imageIndices.map { elements[$0].frame }
        let columns: Int
        switch mode {
        case .row: columns = imageIndices.count
        case .column: columns = 1
        case .grid: columns = max(1, Int(ceil(Double(imageIndices.count).squareRoot())))
        }

        var rowHeights: [CGFloat] = []
        var colWidths = [CGFloat](repeating: 0, count: columns)
        for (n, f) in frames.enumerated() {
            let col = n % columns
            let row = n / columns
            colWidths[col] = max(colWidths[col], f.width)
            if rowHeights.count <= row { rowHeights.append(0) }
            rowHeights[row] = max(rowHeights[row], f.height)
        }

        var movedAnnotations: Set<UUID> = []
        for (n, idx) in imageIndices.enumerated() {
            let col = n % columns
            let row = n / columns
            let x = margin + colWidths.prefix(col).reduce(0) { $0 + $1 + gap }
            let y = margin + rowHeights.prefix(row).reduce(0) { $0 + $1 + gap }
            let old = elements[idx].frame
            let d = CGVector(dx: x - old.minX, dy: y - old.minY)
            elements[idx].translate(by: d)
            // 画像の上に載っている注釈も一緒に動かす
            for i in elements.indices where !elements[i].isImage && !movedAnnotations.contains(elements[i].id) {
                let c = CGPoint(x: elements[i].frame.midX, y: elements[i].frame.midY)
                if old.contains(c) {
                    elements[i].translate(by: d)
                    movedAnnotations.insert(elements[i].id)
                }
            }
        }

        fitCanvasToContent()
        status = "画像を並べ直しました"
        touch()
    }
}
