// 生成应用图标 1024x1024 PNG（macOS squircle 风格）
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let s = CGFloat(size)

// 背景：squircle + 深红渐变
let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
let squircle = CGPath(roundedRect: bgRect.insetBy(dx: 22, dy: 22), cornerWidth: 230, cornerHeight: 230, transform: nil)
ctx.addPath(squircle)
ctx.clip()

let colors = [CGColor(red: 0.53, green: 0.09, blue: 0.10, alpha: 1),
              CGColor(red: 0.84, green: 0.28, blue: 0.17, alpha: 1)] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

// 隧道图案：三层同心圆弧 + 中心圆点（白色）
let cx = s / 2, cy = s / 2
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
for (r, w) in [(330.0, 34.0), (240.0, 40.0)] {
    ctx.setLineWidth(CGFloat(w))
    ctx.strokeEllipse(in: CGRect(x: cx - CGFloat(r), y: cy - CGFloat(r),
                                 width: CGFloat(r) * 2, height: CGFloat(r) * 2))
}
// 外圈弧线（开口隧道）
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
ctx.setLineWidth(52)
ctx.setLineCap(.round)
let r0: CGFloat = 150
for a in [CGFloat(35), 145, 215, 325].map({ $0 * .pi / 180 }) {
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r0,
               startAngle: a, endAngle: a + .pi / 5, clockwise: false)
    ctx.strokePath()
}
// 中心圆点
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fillEllipse(in: CGRect(x: cx - 62, y: cy - 62, width: 124, height: 124))

let img = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "icon_1024.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("saved: \(out.path)")
