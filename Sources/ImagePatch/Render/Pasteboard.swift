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
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        if let tiff = rep.representation(using: .tiff, properties: [:]) {
            pb.setData(tiff, forType: .tiff)
        }
        return true
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
