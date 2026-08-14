import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// ウィンドウを閉じたら終了する（閉じたあと再表示する手段がないため）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let doc = Doc.shared
        guard !doc.elements.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "編集中の内容があります"
        alert.informativeText = "終了すると失われます。クリップボードにコピーしてから終了できます。"
        alert.addButton(withTitle: "コピーして終了")
        alert.addButton(withTitle: "破棄して終了")
        alert.addButton(withTitle: "キャンセル")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Clip.copyToPasteboard(doc: doc)
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

@main
struct ImagePatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var doc = Doc.shared

    private static var didAutoPaste = false

    init() {
        // 描画の確認用: ImagePatch --selftest out.png
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            let out = args.count > i + 1 ? args[i + 1] : "selftest.png"
            SelfTest.run(writingTo: out)
            exit(0)
        }
        // クリップボード読み取りの確認用: ImagePatch --clipcheck
        if args.contains("--clipcheck") {
            let images = Clip.readImages()
            let sizes = images.map { "\($0.width)x\($0.height)" }.joined(separator: ", ")
            print("clipboard: \(images.count) image(s) \(sizes)")
            exit(images.isEmpty ? 1 : 0)
        }
    }

    var body: some Scene {
        WindowGroup("ImagePatch") {
            ContentView(doc: doc)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    autoPasteOnLaunch()
                }
        }
        .defaultSize(width: 1320, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新しいキャンバス") { doc.clearAll() }
                    .keyboardShortcut("n")
                Button("画像を開く…") { Clip.openImages(doc: doc) }
                    .keyboardShortcut("o")
            }

            CommandGroup(replacing: .saveItem) {
                Button("PNG で保存…") { Clip.save(doc: doc) }
                    .keyboardShortcut("s")
            }

            CommandGroup(replacing: .undoRedo) {
                Button("取り消す") { doc.undo() }
                    .keyboardShortcut("z")
                Button("やり直す") { doc.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .pasteboard) {
                Button("キャンバス全体をコピー") { copyAction() }
                    .keyboardShortcut("c")
                Button("貼り付け") { pasteAction() }
                    .keyboardShortcut("v")
                Button("複製") { doc.duplicateSelection() }
                    .keyboardShortcut("d")
                Button("削除") { doc.deleteSelection() }
                Divider()
                Button("すべて選択") { selectAllAction() }
                    .keyboardShortcut("a")
            }

            CommandMenu("配置") {
                Button("前面へ") { doc.bringForward() }
                    .keyboardShortcut("]")
                Button("背面へ") { doc.sendBackward() }
                    .keyboardShortcut("[")
                Divider()
                Button("画像を横並び") { doc.arrangeImages(.row) }
                Button("画像を縦並び") { doc.arrangeImages(.column) }
                Button("画像をグリッド") { doc.arrangeImages(.grid) }
                Divider()
                Button("余白を整える") { doc.fitCanvasToContentWithCheckpoint() }
                Button("トリミングを確定") { CanvasBridge.shared.view?.confirmCrop() }
            }

            CommandMenu("ツール") {
                ForEach(Tool.allCases) { tool in
                    Button("\(tool.label)  （\(tool.key.uppercased())）") {
                        doc.tool = tool
                        doc.touch()
                    }
                }
            }

            CommandGroup(after: .sidebar) {
                Button("全体表示") { CanvasBridge.shared.view?.fitToWindow() }
                    .keyboardShortcut("0")
                Button("拡大") { CanvasBridge.shared.view?.zoomIn() }
                    .keyboardShortcut("=")
                Button("縮小") { CanvasBridge.shared.view?.zoomOut() }
                    .keyboardShortcut("-")
            }
        }
    }

    /// 起動時にクリップボードに画像があればそのまま読み込む（撮る→開く→もう描ける）
    private func autoPasteOnLaunch() {
        guard !Self.didAutoPaste else { return }
        Self.didAutoPaste = true
        guard doc.elements.isEmpty else { return }
        let images = Clip.readImages()
        guard !images.isEmpty else { return }
        doc.addImages(images)
        doc.status = "クリップボードの画像を読み込みました（不要なら ⌘Z）"
    }

    // テキスト編集中は標準の編集動作に譲る
    private var isEditingText: Bool {
        CanvasBridge.shared.view?.isEditingText ?? false
    }

    private func copyAction() {
        if isEditingText {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            return
        }
        if Clip.copyToPasteboard(doc: doc) {
            doc.status = "キャンバス全体をコピーしました（\(Int(doc.canvasSize.width * doc.exportScale))×\(Int(doc.canvasSize.height * doc.exportScale))）"
        }
    }

    private func pasteAction() {
        if isEditingText {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            return
        }
        let images = Clip.readImages()
        if images.isEmpty {
            doc.status = "クリップボードに画像がありません"
        } else {
            doc.addImages(images)
        }
    }

    private func selectAllAction() {
        if isEditingText {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            return
        }
        doc.selectAll()
    }
}
