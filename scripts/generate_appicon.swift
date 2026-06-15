#!/usr/bin/env swift
//
// generate_appicon.swift — renders the PieSwitcher radial-pie logo mark into a
// full macOS AppIcon.appiconset. The mark mirrors the logo used on the landing
// page (site/index.html) and About window: a purple line-art ring with a
// highlighted top wedge and two divider legs, on a light squircle tile.
//
// Usage:  swift scripts/generate_appicon.swift <output-appiconset-dir>
//
// No external tooling required (no SVG rasterizer) — pure CoreGraphics/AppKit.

import AppKit
import CoreGraphics

// MARK: - Palette
let purple = NSColor(srgbRed: 123/255, green: 92/255, blue: 255/255, alpha: 1)   // #7b5cff
let tileTop = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)                    // #ffffff
let tileBottom = NSColor(srgbRed: 238/255, green: 240/255, blue: 245/255, alpha: 1) // #eef0f5

// Point on a circle (radius r, angle measured clockwise from straight up) in the
// glyph's 24x24 coordinate space (y grows downward, like SVG / screen).
func glyphPoint(_ r: CGFloat, _ degFromTop: CGFloat) -> CGPoint {
    let a = degFromTop * .pi / 180
    return CGPoint(x: 12 + r * sin(a), y: 12 - r * cos(a))
}

func renderIcon(pixels S: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Flip to a top-left origin, y-down space so all coordinates read like SVG/screen.
    ctx.translateBy(x: 0, y: CGFloat(S))
    ctx.scaleBy(x: 1, y: -1)

    let f = CGFloat(S)
    // macOS app-icon grid proportions (1024 canvas → 824 tile, 185 corner, 100 margin).
    let margin = f * 100.0 / 1024.0
    let side = f - 2 * margin
    let corner = side * 185.0 / 824.0
    let tile = CGRect(x: margin, y: margin, width: side, height: side)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Soft ambient shadow under the tile (skip on tiny sizes where it just muddies).
    if S >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: f * 0.026, color: NSColor(white: 0.08, alpha: 0.20).cgColor)
        ctx.addPath(tilePath)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Light vertical gradient fill, clipped to the squircle.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs,
                          colors: [tileTop.cgColor, tileBottom.cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: tile.midX, y: tile.minY),
                           end: CGPoint(x: tile.midX, y: tile.maxY), options: [])
    ctx.restoreGState()

    // Hairline rim so the tile reads on white backgrounds.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(NSColor(white: 0, alpha: 0.06).cgColor)
    ctx.setLineWidth(max(0.5, f * 0.0016))
    ctx.strokePath()

    // ---- Glyph (24x24 space mapped into a centered sub-rect of the tile) ----
    let G = side * 0.64
    let gx = tile.midX - G / 2
    let gy = tile.midY - G / 2
    let gs = G / 24.0
    func P(_ sx: CGFloat, _ sy: CGFloat) -> CGPoint { CGPoint(x: gx + sx * gs, y: gy + sy * gs) }
    func C(_ r: CGFloat, _ deg: CGFloat) -> CGPoint { let p = glyphPoint(r, deg); return P(p.x, p.y) }
    let sw = 1.5 * gs

    ctx.setStrokeColor(purple.cgColor)
    ctx.setFillColor(purple.cgColor)
    ctx.setLineWidth(sw)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Outer ring (center 12,12 r 9.2) and inner ring (r 3.3).
    func ringRect(_ r: CGFloat) -> CGRect {
        CGRect(x: gx + (12 - r) * gs, y: gy + (12 - r) * gs, width: 2 * r * gs, height: 2 * r * gs)
    }
    ctx.strokeEllipse(in: ringRect(9.2))
    ctx.strokeEllipse(in: ringRect(3.3))

    // Filled top wedge: outer arc -40°..+40° (through top), inner arc back, closed.
    let wedge = CGMutablePath()
    let steps = max(24, S / 16)
    wedge.move(to: C(9.2, -40))
    for i in 0...steps { wedge.addLine(to: C(9.2, -40 + 80 * CGFloat(i) / CGFloat(steps))) }
    for i in 0...steps { wedge.addLine(to: C(3.3, 40 - 80 * CGFloat(i) / CGFloat(steps))) }
    wedge.closeSubpath()
    ctx.addPath(wedge)
    ctx.fillPath()

    // Two divider legs from the inner ring out toward the bottom.
    ctx.move(to: P(14.12, 14.53)); ctx.addLine(to: P(17.91, 19.05)); ctx.strokePath()
    ctx.move(to: P(9.88, 14.53));  ctx.addLine(to: P(6.09, 19.05));  ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Failed to encode \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: path))
}

// MARK: - Drive

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// (filename, pixel size)
let targets: [(String, Int)] = [
    ("icon_16x16.png", 16),       ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),       ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),    ("icon_512x512@2x.png", 1024),
]

for (name, size) in targets {
    let img = renderIcon(pixels: size)
    writePNG(img, to: "\(outDir)/\(name)")
    print("✓ \(name) (\(size)px)")
}
print("Done → \(outDir)")
