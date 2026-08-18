import AppKit
import SwiftUI

/// ツール切り替えボタン。`.plain` は描画された部分しか当たらないので、
/// 枠いっぱいを `contentShape` でクリック範囲にする
private struct ToolButton: View {
    let tool: Tool
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tool.systemImage)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                Text(tool.label)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(width: 56, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(stroke, lineWidth: isSelected ? 1.5 : 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help("\(tool.label)（\(tool.key.uppercased())）")
    }

    private var fill: Color {
        if isSelected { return Color.accentColor.opacity(hovering ? 1 : 0.9) }
        return hovering ? Color.primary.opacity(0.12) : .clear
    }

    private var stroke: Color {
        if isSelected { return Color.accentColor }
        return hovering ? Color.primary.opacity(0.25) : .clear
    }
}

/// 色ボタン。丸は小さいままでも、当たり判定は正方形いっぱいに取る
private struct ColorSwatch: View {
    let color: RGBA
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color.ns))
                .frame(width: isSelected || hovering ? 21 : 18, height: isSelected || hovering ? 21 : 18)
                .overlay(
                    Circle().stroke(isSelected ? Color.accentColor : Color.gray.opacity(hovering ? 0.9 : 0.5),
                                    lineWidth: isSelected ? 2.5 : 1)
                )
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

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
        .frame(minWidth: 1080, minHeight: 640)
    }

    // MARK: - ツール

    private var toolRow: some View {
        HStack(spacing: 6) {
            ForEach(Tool.allCases) { tool in
                ToolButton(tool: tool, isSelected: doc.tool == tool) {
                    doc.tool = tool
                    doc.touch()
                }
            }

            Divider().frame(height: 30)

            HStack(spacing: 2) {
                ForEach(Array(RGBA.palette.enumerated()), id: \.offset) { _, color in
                    ColorSwatch(color: color, isSelected: doc.style.color == color) {
                        doc.applyStyle { $0.color = color }
                    }
                }
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
