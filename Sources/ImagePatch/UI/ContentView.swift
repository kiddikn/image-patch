import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var doc: Doc

    var body: some View {
        VStack(spacing: 0) {
            toolRow
            Divider()
            styleRow
            Divider()
            CanvasRepresentable(doc: doc)
                .frame(minWidth: 560, minHeight: 360)
            Divider()
            statusRow
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    // MARK: - ツール

    private var toolRow: some View {
        HStack(spacing: 6) {
            ForEach(Tool.allCases) { tool in
                Button {
                    doc.tool = tool
                    doc.touch()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 14))
                        Text(tool.label)
                            .font(.system(size: 9))
                    }
                    .frame(width: 52, height: 34)
                }
                .buttonStyle(.plain)
                .background(doc.tool == tool ? Color.accentColor.opacity(0.22) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(doc.tool == tool ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .help("\(tool.label)（\(tool.key.uppercased())）")
            }

            Divider().frame(height: 30)

            ForEach(Array(RGBA.palette.enumerated()), id: \.offset) { _, color in
                Button {
                    doc.applyStyle { $0.color = color }
                } label: {
                    Circle()
                        .fill(Color(nsColor: color.ns))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().stroke(doc.style.color == color ? Color.accentColor : Color.gray.opacity(0.5),
                                            lineWidth: doc.style.color == color ? 2.5 : 0.5)
                        )
                }
                .buttonStyle(.plain)
            }

            ColorPicker("", selection: Binding(
                get: { Color(nsColor: doc.style.color.ns) },
                set: { newColor in doc.applyStyle { $0.color = RGBA(NSColor(newColor)) } }
            ))
            .labelsHidden()
            .frame(width: 36)

            Spacer()

            Button { Clip.copyToPasteboard(doc: doc); doc.status = "キャンバス全体をコピーしました" } label: {
                Label("コピー", systemImage: "doc.on.doc")
            }
            Button { Clip.save(doc: doc) } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - スタイル

    private var styleRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            styleControls
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .frame(height: 40)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var styleControls: some View {
        HStack(spacing: 14) {
            slider("線の太さ", value: Binding(
                get: { doc.style.lineWidth },
                set: { v in doc.applyStyle { $0.lineWidth = v.rounded() } }
            ), range: 1...40, width: 110, text: "\(Int(doc.style.lineWidth))")

            slider("文字", value: Binding(
                get: { doc.style.fontSize },
                set: { v in doc.applyStyle { $0.fontSize = v.rounded() } }
            ), range: 10...160, width: 110, text: "\(Int(doc.style.fontSize))")

            slider("モザイク", value: Binding(
                get: { doc.style.mosaicBlock },
                set: { v in doc.applyStyle { $0.mosaicBlock = v.rounded() } }
            ), range: 4...80, width: 100, text: "\(Int(doc.style.mosaicBlock))")

            slider("角丸", value: Binding(
                get: { doc.style.cornerRadius },
                set: { v in doc.applyStyle { $0.cornerRadius = v.rounded() } }
            ), range: 0...60, width: 80, text: "\(Int(doc.style.cornerRadius))")

            Toggle("塗り／文字背景", isOn: Binding(
                get: { doc.style.filled },
                set: { v in doc.applyStyle { $0.filled = v } }
            ))
            .toggleStyle(.checkbox)

            Divider().frame(height: 22)

            if let image = selectedImage, let natural = doc.naturalSize(of: image) {
                Text("画像幅")
                    .font(.caption)
                Text("\(Int(image.frame.width)) px")
                    .font(.caption.monospacedDigit())
                Button("等倍") { doc.scaleImage(image.id, toWidth: natural.width) }
                Button("50%") { doc.scaleImage(image.id, toWidth: (natural.width / 2).rounded()) }
                Divider().frame(height: 22)
            }

            Menu("並べる") {
                Button("横並び") { doc.arrangeImages(.row) }
                Button("縦並び") { doc.arrangeImages(.column) }
                Button("グリッド") { doc.arrangeImages(.grid) }
                Divider()
                Button("余白を整える") { doc.fitCanvasToContentWithCheckpoint() }
            }
            .frame(width: 90)

            Picker("背景", selection: Binding(
                get: { doc.transparentBackground ? 2 : (doc.background == RGBA.white ? 0 : 1) },
                set: { v in
                    switch v {
                    case 0: doc.transparentBackground = false; doc.background = .white
                    case 1: doc.transparentBackground = false; doc.background = RGBA(r: 0.93, g: 0.94, b: 0.96)
                    default: doc.transparentBackground = true
                    }
                    doc.touch()
                }
            )) {
                Text("白").tag(0)
                Text("灰").tag(1)
                Text("透明").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)

            Picker("倍率", selection: Binding(
                get: { doc.exportScale },
                set: { doc.exportScale = $0 }
            )) {
                Text("1x").tag(CGFloat(1))
                Text("2x").tag(CGFloat(2))
            }
            .pickerStyle(.segmented)
            .frame(width: 80)
            .help("コピー・保存するときの倍率")
        }
    }

    private var selectedImage: Element? {
        doc.selectedElements.first { $0.isImage }
    }

    private func slider(_ label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>,
                        width: CGFloat, text: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption)
            Slider(value: value, in: range).frame(width: width)
            Text(text).font(.caption.monospacedDigit()).frame(width: 24, alignment: .trailing)
        }
    }

    // MARK: - ステータス

    private var statusRow: some View {
        HStack(spacing: 12) {
            Text(doc.status)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Text("\(Int(doc.canvasSize.width))×\(Int(doc.canvasSize.height))")
                .font(.caption.monospacedDigit())
            Text("要素 \(doc.elements.count)")
                .font(.caption.monospacedDigit())
            Button("全体表示") { CanvasBridge.shared.view?.fitToWindow() }
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
