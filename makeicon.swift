import AppKit
import CoreGraphics
import Foundation

// 生成 1024x1024 应用图标：深色圆角方块 + 声波条 + 循环弧线
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: 0, space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

let s = CGFloat(size)

// 背景圆角矩形（macOS 图标安全区约留 10%）
let inset: CGFloat = s * 0.085
let bgRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
let corner = bgRect.width * 0.225
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: corner, cornerHeight: corner, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let colors = [
    CGColor(red: 0.13, green: 0.16, blue: 0.24, alpha: 1),
    CGColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1)
] as CFArray
if let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: s, y: 0),
        options: []
    )
}
ctx.restoreGState()

// 声波条
let bars: [(CGFloat, CGFloat)] = [(0.245, 0.26), (0.352, 0.42), (0.459, 0.56), (0.566, 0.34)]
let barWidth: CGFloat = s * 0.070
let barColor = CGColor(red: 0.98, green: 0.80, blue: 0.36, alpha: 1)

for (centerX, heightRatio) in bars {
    let h = s * heightRatio
    let x = s * centerX - barWidth / 2
    let y = (s - h) / 2
    let r = barWidth / 2
    let path = CGPath(
        roundedRect: CGRect(x: x, y: y, width: barWidth, height: h),
        cornerWidth: r, cornerHeight: r, transform: nil
    )
    ctx.addPath(path)
    ctx.setFillColor(barColor)
    ctx.fillPath()
}

// 循环弧线（右下角的小环，暗示 loop）
let ringCenter = CGPoint(x: s * 0.745, y: s * 0.285)
let ringRadius = s * 0.108
ctx.setStrokeColor(CGColor(red: 0.42, green: 0.80, blue: 0.72, alpha: 1))
ctx.setLineWidth(s * 0.028)
ctx.setLineCap(.round)
let startAngle = CGFloat.pi * 0.16
let tipAngle = CGFloat.pi * 1.66
ctx.addArc(
    center: ringCenter,
    radius: ringRadius,
    startAngle: startAngle,
    endAngle: tipAngle,
    clockwise: false
)
ctx.strokePath()

// 环末端的箭头（沿切线方向）
let tipX = ringCenter.x + cos(tipAngle) * ringRadius
let tipY = ringCenter.y + sin(tipAngle) * ringRadius
let tangent = CGVector(dx: -sin(tipAngle), dy: cos(tipAngle))
let normal = CGVector(dx: cos(tipAngle), dy: sin(tipAngle))
let a = s * 0.036
let back = CGPoint(x: tipX - tangent.dx * a * 1.5, y: tipY - tangent.dy * a * 1.5)
ctx.setFillColor(CGColor(red: 0.42, green: 0.80, blue: 0.72, alpha: 1))
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: tipX + tangent.dx * a * 0.35, y: tipY + tangent.dy * a * 0.35))
arrow.addLine(to: CGPoint(x: back.x + normal.dx * a, y: back.y + normal.dy * a))
arrow.addLine(to: CGPoint(x: back.x - normal.dx * a, y: back.y - normal.dy * a))
arrow.closeSubpath()
ctx.addPath(arrow)
ctx.fillPath()

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }

let outURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png")
try data.write(to: outURL)
print("wrote \(outURL.path)")
