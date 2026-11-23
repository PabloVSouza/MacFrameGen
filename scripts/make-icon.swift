// Draws the app icon (1024×1024 PNG) and builds Assets/AppIcon.icns with iconutil.
// Usage: swift scripts/make-icon.swift   (run from the repository root)
import AppKit
import CoreGraphics
import Foundation

let size: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.displayP3)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

// macOS icon body: 824 pt square on the 1024 canvas, continuous-corner rounded rect.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow + background gradient (deep navy → indigo).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x0B1020)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x262A6B), rgb(0x0B1020)], [0, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Soft glow behind the middle (generated) frame.
ctx.drawRadialGradient(gradient([rgb(0x7C3AED, 0.55), rgb(0x7C3AED, 0)], [0, 1]),
                       startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 520), endRadius: 380, options: [])

// Three video frames, back to front: real (left), generated (middle), real (right).
let frameW: CGFloat = 330, frameH: CGFloat = 250
let centers: [CGPoint] = [CGPoint(x: 330, y: 560), CGPoint(x: 512, y: 512), CGPoint(x: 694, y: 464)]
let accent = gradient([rgb(0x22D3EE), rgb(0xA78BFA)], [0, 1])
for i in [0, 2, 1] {  // the generated frame last, on top
    let c = centers[i]
    let r = CGRect(x: c.x - frameW / 2, y: c.y - frameH / 2, width: frameW, height: frameH)
    let p = CGPath(roundedRect: r, cornerWidth: 44, cornerHeight: 44, transform: nil)
    let generated = i == 1
    // Frame fill.
    ctx.saveGState(); ctx.addPath(p); ctx.clip()
    ctx.drawLinearGradient(gradient(generated ? [rgb(0x22D3EE, 0.20), rgb(0xA78BFA, 0.28)]
                                              : [rgb(0x1E2A5A, 0.96), rgb(0x141A3C, 0.96)], [0, 1]),
                           start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
    ctx.restoreGState()
    // Frame outline: gradient stroke (bright on the generated frame).
    ctx.saveGState()
    ctx.addPath(p); ctx.setLineWidth(generated ? 16 : 12); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.setAlpha(generated ? 1 : 0.75)
    ctx.drawLinearGradient(accent, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
    ctx.restoreGState()
    // The moving ball inside each frame: left, centre (interpolated, glowing), right.
    let ball = CGPoint(x: r.minX + frameW * [0.3, 0.5, 0.7][i], y: r.midY)
    if generated {
        ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.9), rgb(0x22D3EE, 0.0)], [0, 1]),
                               startCenter: ball, startRadius: 0, endCenter: ball, endRadius: 95, options: [])
    }
    ctx.setFillColor(generated ? rgb(0xFFFFFF) : rgb(0x9AA6D8, 0.9))
    ctx.fillEllipse(in: CGRect(x: ball.x - 34, y: ball.y - 34, width: 68, height: 68))
}
// Motion streak through the three ball positions.
ctx.saveGState()
ctx.setLineCap(.round); ctx.setLineWidth(10); ctx.setStrokeColor(rgb(0x22D3EE, 0.55))
ctx.setLineDash(phase: 0, lengths: [2, 26])
ctx.move(to: CGPoint(x: centers[0].x - frameW / 2 + frameW * 0.3 + 50, y: centers[0].y))
ctx.addLine(to: CGPoint(x: centers[2].x - frameW / 2 + frameW * 0.7 - 50, y: centers[2].y))
ctx.strokePath()
ctx.restoreGState()
ctx.restoreGState()

// Write master PNG, then the iconset and .icns.
let image = ctx.makeImage()!
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let master = assets.appendingPathComponent("AppIcon-1024.png")
func writePNG(_ img: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}
writePNG(image, master)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        c.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
        writePNG(c.makeImage()!, iconset.appendingPathComponent("icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Assets/AppIcon-1024.png and Assets/AppIcon.icns" : "iconutil failed")
