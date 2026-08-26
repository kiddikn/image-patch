import AppKit
import CoreGraphics
import UniformTypeIdentifiers

enum Clip {
    // MARK: - 取り込み

    /// クリップボードから画像を取り出す（ファイルコピーにも対応）
    static func readImages() -> [CGImage] {
        let pb = NSPasteboard.general
        var result: [CGImage] = []

        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                if let img = image(fromFile: url) { result.append(img) }
            }
        }
        if !result.isEmpty { return result }

        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), let img = image(from: data) {
                return [img]
            }
        }
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            for ns in images {
                if let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    result.append(cg)
                }
            }
        }
        return result
    }

    static func image(fromFile url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return image(from: data)
    }

    static func image(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
    }

    // MARK: - 書き出し

    /// 書き出し用のビットマップ表現。論理サイズはキャンバス寸法にそろえる（2x でも貼り先で等倍に見える）
    private static func makeRep(doc: Doc) -> NSBitmapImageRep? {
        guard let cg = Renderer.makeImage(doc: doc, scale: doc.exportScale, includeDraft: false) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = doc.canvasSize
        return rep
    }

    static func pngData(doc: Doc) -> Data? {
        makeRep(doc: doc)?.representation(using: .png, properties: [:])
    }

    @discardableResult
    static func copyToPasteboard(doc: Doc) -> Bool {
        guard let rep = makeRep(doc: doc),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        write(png: png, tiff: rep.representation(using: .tiff, properties: [:]))
        return true
    }

    /// 選択されている要素だけを画像にしてコピーする（背景は透過）
    @discardableResult
    static func copySelectionToPasteboard(doc: Doc) -> Bool {
        guard let rep = makeSelectionRep(doc: doc),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        write(png: png, tiff: rep.representation(using: .tiff, properties: [:]))
        return true
    }

    static func selectionPNGData(doc: Doc) -> Data? {
        makeSelectionRep(doc: doc)?.representation(using: .png, properties: [:])
    }

    private static func makeSelectionRep(doc: Doc) -> NSBitmapImageRep? {
        let box = doc.selectionPaintedBounds
        guard !box.isNull, box.width >= 1, box.height >= 1 else { return nil }
        let region = box.integral
        let scale = doc.exportScale

        let image: CGImage?
        if doc.selectionHasMosaic {
            // モザイクは下に描かれたものを読んで色を決めるので、全体を描いてから切り抜く
            let clipped = region.intersection(CGRect(origin: .zero, size: doc.canvasSize)).integral
            guard clipped.width >= 1, clipped.height >= 1 else { return nil }
            image = Renderer.makeImage(doc: doc, scale: scale, includeDraft: false)
                .flatMap { $0.cropping(to: pixelRect(clipped, scale: scale, in: $0)) }
        } else {
            image = Renderer.makeImage(doc: doc, elements: doc.selectedElements, region: region,
                                       scale: scale, background: nil)
        }

        guard let cg = image else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        // 論理サイズはキャンバス上の見た目にそろえる（2x でも貼り先で等倍に見える）
        rep.size = CGSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
        return rep
    }

    /// キャンバスの一部分（見た目そのまま）をコピーする
    @discardableResult
    static func copyRegionToPasteboard(doc: Doc, region: CGRect) -> Bool {
        let r = region.intersection(CGRect(origin: .zero, size: doc.canvasSize)).integral
        guard r.width >= 1, r.height >= 1,
              let full = Renderer.makeImage(doc: doc, scale: doc.exportScale, includeDraft: false),
              let cg = full.cropping(to: pixelRect(r, scale: doc.exportScale, in: full)) else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = r.size
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        write(png: png, tiff: rep.representation(using: .tiff, properties: [:]))
        return true
    }

    /// キャンバス座標の矩形を、書き出し画像のピクセル座標（左上原点）に直す
    private static func pixelRect(_ r: CGRect, scale: CGFloat, in image: CGImage) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        return CGRect(x: r.minX * scale, y: r.minY * scale,
                      width: r.width * scale, height: r.height * scale)
            .integral.intersection(full)
    }

    /// このアプリが最後に書き込んだときの changeCount
    private(set) static var lastWrittenChangeCount = -1

    /// クリップボードの中身がこのアプリの直近のコピーのままか（他アプリでコピーされていないか）
    static var ownsPasteboard: Bool { NSPasteboard.general.changeCount == lastWrittenChangeCount }

    private static func write(png: Data, tiff: Data?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        if let tiff { pb.setData(tiff, forType: .tiff) }
        lastWrittenChangeCount = pb.changeCount
    }

    static func save(doc: Doc) {
        guard let png = pngData(doc: doc) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFileName()
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
            doc.status = "保存しました: \(url.lastPathComponent)"
        }
    }

    static func openImages(doc: Doc) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .bmp, .heic, .webP]
        if panel.runModal() == .OK {
            let images = panel.urls.compactMap { image(fromFile: $0) }
            doc.addImages(images)
        }
    }

    private static func defaultFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "image-patch-\(f.string(from: Date())).png"
    }
}
