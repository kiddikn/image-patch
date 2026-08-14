// アプリアイコン（1024px PNG）を生成する単体スクリプト
// 使い方: swift Tools/makeicon.swift out.png
import AppKit
import CoreGraphics
import Foundation

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = 1024

guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}

let S = CGFloat(size)
// macOS 標準の余白
let inset = S * 0.09
let body = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius = body.width * 0.235

// 背景（濃紺→青のグラデーション）
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
let colors = [CGColor(srgbRed: 0.16, green: 0.22, blue: 0.42, alpha: 1),
              CGColor(srgbRed: 0.10, green: 0.42, blue: 0.78, alpha: 1)] as CFArray
if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1]) {
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])
}
ctx.restoreGState()

// 白いキャンバス（2枚重ね = 複数画像を並べられることの表現）
func canvasSheet(_ rect: CGRect, alpha: CGFloat) {
    let r = rect.width * 0.06
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
    ctx.fillPath()
    ctx.restoreGState()
}

let sheetW = body.width * 0.60
let sheetH = body.height * 0.46
canvasSheet(CGRect(x: body.minX + body.width * 0.14, y: body.minY + body.height * 0.42,
                   width: sheetW, height: sheetH), alpha: 0.55)
let main = CGRect(x: body.minX + body.width * 0.24, y: body.minY + body.height * 0.26,
                  width: sheetW, height: sheetH)
canvasSheet(main, alpha: 1.0)

// モザイクブロック
let blocks = 4
let cell = main.width * 0.085
let mx = main.minX + main.width * 0.10
let my = main.minY + main.height * 0.16
for row in 0..<3 {
    for col in 0..<blocks {
        let shade = 0.55 + Double((row * blocks + col) % 5) * 0.07
        ctx.setFillColor(CGColor(srgbRed: shade * 0.6, green: shade * 0.68, blue: shade * 0.85, alpha: 1))
        ctx.fill(CGRect(x: mx + CGFloat(col) * cell, y: my + CGFloat(row) * cell,
                        width: cell * 0.92, height: cell * 0.92))
    }
}

// 赤い矢印
let red = CGColor(srgbRed: 0.93, green: 0.16, blue: 0.16, alpha: 1)
let a = CGPoint(x: main.minX + main.width * 0.18, y: main.minY + main.height * 0.86)
let b = CGPoint(x: main.maxX - main.width * 0.16, y: main.minY + main.height * 0.42)
let len = hypot(b.x - a.x, b.y - a.y)
let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
let headLen = len * 0.34
let halfW = headLen * 0.42
let base = CGPoint(x: b.x - ux * headLen, y: b.y - uy * headLen)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.006), blur: S * 0.02,
              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
ctx.setStrokeColor(red)
ctx.setFillColor(red)
ctx.setLineWidth(S * 0.038)
ctx.setLineCap(.round)
ctx.move(to: a)
ctx.addLine(to: CGPoint(x: b.x - ux * headLen * 0.85, y: b.y - uy * headLen * 0.85))
ctx.strokePath()
ctx.move(to: b)
ctx.addLine(to: CGPoint(x: base.x - uy * halfW, y: base.y + ux * halfW))
ctx.addLine(to: CGPoint(x: base.x + uy * halfW, y: base.y - ux * halfW))
ctx.closePath()
ctx.fillPath()
ctx.restoreGState()

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
