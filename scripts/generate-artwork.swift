#!/usr/bin/env swift
// Generates Zuno's original development artwork procedurally (no third-party images):
// 16 painterly seed event covers, 3 onboarding images, the app icon and the launch
// wordmark. Deterministic: the same seed always produces the same pixels.
//
// Usage: swift scripts/generate-artwork.swift   (from the repository root, macOS)

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Deterministic randomness

struct RNG {
    var state: UInt64
    init(_ seed: String) { state = seed.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 } }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(next() % 1_000_000) / 1_000_000 }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
}

// MARK: - Color helpers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip so y grows downward like a canvas.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    return ctx
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint, locations: [CGFloat]? = nil) {
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Linear gradient confined to a band (no bleed outside it).
func band(_ ctx: CGContext, _ colors: [CGColor], y0: CGFloat, y1: CGFloat, width: CGFloat) {
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: y0, width: width, height: y1 - y0))
    linear(ctx, colors, from: CGPoint(x: 0, y: y0), to: CGPoint(x: 0, y: y1))
    ctx.restoreGState()
}

func glow(_ ctx: CGContext, at p: CGPoint, radius: CGFloat, color: UInt32, alpha: CGFloat = 0.9) {
    let gradient = CGGradient(colorsSpace: space, colors: [rgb(color, alpha), rgb(color, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

/// A rolling ridge line (sum of sines) filled down to the bottom.
func ridge(_ ctx: CGContext, w: CGFloat, h: CGFloat, baseY: CGFloat, amplitude: CGFloat, color: CGColor, rng: inout RNG, roughness: Int = 4) {
    let path = CGMutablePath()
    var phases: [(CGFloat, CGFloat, CGFloat)] = []
    for i in 0..<roughness { phases.append((rng.range(0, 6.28), CGFloat(i + 1) * rng.range(0.8, 1.6), amplitude / CGFloat(i + 1))) }
    path.move(to: CGPoint(x: 0, y: h))
    var x: CGFloat = 0
    while x <= w {
        var y = baseY
        for (phase, frequency, amp) in phases { y -= sin(x / w * .pi * frequency + phase) * amp }
        path.addLine(to: CGPoint(x: x, y: y))
        x += 6
    }
    path.addLine(to: CGPoint(x: w, y: h))
    path.closeSubpath()
    fill(ctx, path, color)
}

func ellipse(_ ctx: CGContext, _ rect: CGRect, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: rect)
}

func rect(_ ctx: CGContext, _ r: CGRect, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fill(r)
}

func palm(_ ctx: CGContext, base: CGPoint, height: CGFloat, lean: CGFloat, color: CGColor, rng: inout RNG, palmyra: Bool = false) {
    let top = CGPoint(x: base.x + lean, y: base.y - height)
    let trunk = CGMutablePath()
    trunk.move(to: CGPoint(x: base.x - height * 0.018, y: base.y))
    trunk.addQuadCurve(to: CGPoint(x: top.x - height * 0.01, y: top.y), control: CGPoint(x: base.x + lean * 0.2, y: base.y - height * 0.5))
    trunk.addLine(to: CGPoint(x: top.x + height * 0.01, y: top.y))
    trunk.addQuadCurve(to: CGPoint(x: base.x + height * 0.018, y: base.y), control: CGPoint(x: base.x + lean * 0.2 + height * 0.02, y: base.y - height * 0.5))
    trunk.closeSubpath()
    fill(ctx, trunk, color)
    let fronds = palmyra ? 22 : 9
    for i in 0..<fronds {
        let angle = palmyra ? CGFloat(i) / CGFloat(fronds) * .pi * 2 : rng.range(-.pi * 0.95, -0.05) + (i % 2 == 0 ? 0 : .pi * 0.0)
        let length = height * (palmyra ? rng.range(0.16, 0.22) : rng.range(0.28, 0.42))
        let end = CGPoint(x: top.x + cos(angle) * length, y: top.y + sin(angle) * length * (palmyra ? 1 : 0.6) + (palmyra ? 0 : length * 0.35))
        let frond = CGMutablePath()
        frond.move(to: top)
        let control = CGPoint(x: (top.x + end.x) / 2, y: min(top.y, end.y) - length * (palmyra ? 0.05 : 0.25))
        frond.addQuadCurve(to: end, control: control)
        ctx.addPath(frond)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(height * (palmyra ? 0.012 : 0.02))
        ctx.setLineCap(.round)
        ctx.strokePath()
    }
}

func stars(_ ctx: CGContext, w: CGFloat, h: CGFloat, count: Int, rng: inout RNG) {
    for _ in 0..<count {
        let p = CGPoint(x: rng.range(0, w), y: rng.range(0, h))
        let r = rng.range(0.6, 2.2)
        ellipse(ctx, CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2), rgb(0xFFF4DA, rng.range(0.3, 0.9)))
    }
}

// MARK: - Painterly finishing

/// Re-paints the image with thousands of short strokes sampled from itself, adds canvas
/// grain, a warm varnish and a vignette — an oil-on-canvas feel.
func paintify(_ image: CGImage, rng: inout RNG, strokes: Int, strokeScale: CGFloat = 1) -> CGImage {
    let w = image.width, h = image.height
    let ctx = makeContext(w, h)
    ctx.saveGState()
    ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: 0, y: -CGFloat(h))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.restoreGState()

    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return image }
    let bytesPerRow = image.bytesPerRow, bpp = image.bitsPerPixel / 8
    func sample(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
        let cx = min(max(x, 0), w - 1), cy = min(max(y, 0), h - 1)
        let i = cy * bytesPerRow + cx * bpp
        return (CGFloat(bytes[i]) / 255, CGFloat(bytes[i + 1]) / 255, CGFloat(bytes[i + 2]) / 255)
    }
    ctx.setLineCap(.round)
    for _ in 0..<strokes {
        let x = Int(rng.range(0, CGFloat(w))), y = Int(rng.range(0, CGFloat(h)))
        let (r, g, b) = sample(x, y)
        let jitter = rng.range(-0.05, 0.05)
        let length = rng.range(6, 22) * strokeScale
        let angle = rng.range(-0.6, 0.6) + (rng.unit() < 0.3 ? .pi / 2 : 0)
        ctx.setStrokeColor(CGColor(red: min(max(r + jitter, 0), 1), green: min(max(g + jitter, 0), 1),
                                   blue: min(max(b + jitter * 0.8, 0), 1), alpha: rng.range(0.35, 0.75)))
        ctx.setLineWidth(rng.range(2.5, 7) * strokeScale)
        ctx.move(to: CGPoint(x: CGFloat(x) - cos(angle) * length / 2, y: CGFloat(y) - sin(angle) * length / 2))
        ctx.addLine(to: CGPoint(x: CGFloat(x) + cos(angle) * length / 2, y: CGFloat(y) + sin(angle) * length / 2))
        ctx.strokePath()
    }
    // Canvas grain.
    for _ in 0..<(w * h / 60) {
        let p = CGPoint(x: rng.range(0, CGFloat(w)), y: rng.range(0, CGFloat(h)))
        rect(ctx, CGRect(x: p.x, y: p.y, width: 1.4, height: 1.4), rng.unit() < 0.5 ? rgb(0xFFFFFF, 0.05) : rgb(0x000000, 0.07))
    }
    // Warm varnish.
    ctx.setBlendMode(.multiply)
    rect(ctx, CGRect(x: 0, y: 0, width: w, height: h), rgb(0xF2DFB8, 0.22))
    ctx.setBlendMode(.normal)
    // Vignette.
    let center = CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
    let gradient = CGGradient(colorsSpace: space, colors: [rgb(0x000000, 0), rgb(0x0B0A06, 0.55)] as CFArray, locations: [0.55, 1])!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                           endRadius: hypot(CGFloat(w), CGFloat(h)) * 0.62, options: [.drawsAfterEndLocation])
    return ctx.makeImage()!
}

// MARK: - Scenes

typealias Scene = (CGContext, CGFloat, CGFloat, inout RNG) -> Void

let scenes: [String: Scene] = [
    "climate-ai-hackathon": { ctx, w, h, rng in
        linear(ctx, [rgb(0x2E3B3A), rgb(0x6F7F72), rgb(0xC9A764)], from: .zero, to: CGPoint(x: 0, y: h * 0.62), locations: [0, 0.6, 1])
        for i in 0..<9 { // heavy clouds
            let c = CGPoint(x: rng.range(0, w), y: rng.range(h * 0.05, h * 0.3))
            glow(ctx, at: c, radius: rng.range(w * 0.12, w * 0.25), color: i % 2 == 0 ? 0x1F2A2B : 0x3E4C49, alpha: 0.85)
        }
        ctx.setStrokeColor(rgb(0xC8D3CC, 0.18)); ctx.setLineWidth(1.5)
        for _ in 0..<220 { let x = rng.range(0, w), y = rng.range(0, h * 0.5); ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x - 18, y: y + 60)); ctx.strokePath() }
        let greens: [UInt32] = [0x5B7A4A, 0x4C6B3C, 0x3D5A31, 0x2F4A27, 0x24391F, 0x1B2C17]
        for (i, color) in greens.enumerated() {
            ridge(ctx, w: w, h: h, baseY: h * (0.45 + CGFloat(i) * 0.09), amplitude: h * 0.05, color: rgb(color), rng: &rng)
            ctx.setStrokeColor(rgb(0xB9C98A, 0.25)); ctx.setLineWidth(2)
            for _ in 0..<5 { let y = h * (0.5 + CGFloat(i) * 0.09) + rng.range(-10, 10); ctx.move(to: CGPoint(x: 0, y: y)); ctx.addCurve(to: CGPoint(x: w, y: y + rng.range(-30, 30)), control1: CGPoint(x: w * 0.3, y: y - 25), control2: CGPoint(x: w * 0.7, y: y + 25)); ctx.strokePath() }
        }
        glow(ctx, at: CGPoint(x: w * 0.78, y: h * 0.46), radius: w * 0.18, color: 0xEDA71A, alpha: 0.35)
    },
    "swiftui-workshop": { ctx, w, h, rng in
        linear(ctx, [rgb(0x2A1E16), rgb(0x3B2A1E)], from: .zero, to: CGPoint(x: w, y: h))
        let window = CGRect(x: w * 0.52, y: h * 0.08, width: w * 0.38, height: h * 0.5)
        ctx.saveGState(); ctx.clip(to: window)
        linear(ctx, [rgb(0x3E3A6B), rgb(0xC7735A), rgb(0xF0B36A)], from: CGPoint(x: 0, y: window.minY), to: CGPoint(x: 0, y: window.maxY))
        ridge(ctx, w: w, h: h, baseY: window.maxY - 30, amplitude: 20, color: rgb(0x2B2338), rng: &rng)
        ctx.restoreGState()
        rect(ctx, CGRect(x: window.midX - 4, y: window.minY, width: 8, height: window.height), rgb(0x24180F))
        rect(ctx, CGRect(x: window.minX, y: window.midY - 4, width: window.width, height: 8), rgb(0x24180F))
        band(ctx, [rgb(0x7A4E2C), rgb(0x4A2E19)], y0: h * 0.66, y1: h, width: w)
        rect(ctx, CGRect(x: 0, y: h * 0.64, width: w, height: h * 0.03), rgb(0x8C5B33))
        // laptop
        let base = CGRect(x: w * 0.2, y: h * 0.62, width: w * 0.36, height: h * 0.035)
        let screen = CGMutablePath(); screen.move(to: CGPoint(x: base.minX + 20, y: base.minY)); screen.addLine(to: CGPoint(x: base.minX + 45, y: h * 0.3)); screen.addLine(to: CGPoint(x: base.maxX - 45, y: h * 0.3)); screen.addLine(to: CGPoint(x: base.maxX - 20, y: base.minY)); screen.closeSubpath()
        fill(ctx, screen, rgb(0x1B1B22))
        glow(ctx, at: CGPoint(x: base.midX, y: h * 0.46), radius: w * 0.28, color: 0x9FC6E8, alpha: 0.5)
        rect(ctx, base, rgb(0xB8B4AE))
        glow(ctx, at: CGPoint(x: w * 0.12, y: h * 0.4), radius: w * 0.16, color: 0xEDA71A, alpha: 0.35)
    },
    "kandyan-drumming": { ctx, w, h, rng in
        linear(ctx, [rgb(0x0E1012), rgb(0x1E1A14)], from: .zero, to: CGPoint(x: 0, y: h))
        ridge(ctx, w: w, h: h, baseY: h * 0.42, amplitude: h * 0.06, color: rgb(0x151A14), rng: &rng)
        band(ctx, [rgb(0x0F1416, 0), rgb(0x0F1416)], y0: h * 0.5, y1: h, width: w)
        for i in 0..<5 { // lake reflections of lamps
            let x = w * (0.15 + CGFloat(i) * 0.18)
            glow(ctx, at: CGPoint(x: x, y: h * 0.47), radius: 26, color: 0xF2B44A, alpha: 0.9)
            ctx.setStrokeColor(rgb(0xF2B44A, 0.35)); ctx.setLineWidth(3)
            for j in 0..<8 { let y = h * 0.55 + CGFloat(j) * 14; ctx.move(to: CGPoint(x: x - rng.range(8, 30), y: y)); ctx.addLine(to: CGPoint(x: x + rng.range(8, 30), y: y)); ctx.strokePath() }
        }
        for (i, scale) in [0.9, 1.1, 1.0].enumerated() { // drums
            let cx = w * (0.3 + CGFloat(i) * 0.2), cy = h * 0.72, dw = w * 0.13 * scale, dh = h * 0.22 * scale
            glow(ctx, at: CGPoint(x: cx, y: cy - dh * 0.3), radius: dw * 1.6, color: 0xE39A3B, alpha: 0.45)
            rect(ctx, CGRect(x: cx - dw / 2, y: cy - dh / 2, width: dw, height: dh), rgb(0x6B3418))
            ctx.setStrokeColor(rgb(0xD9A15A, 0.8)); ctx.setLineWidth(2.5)
            for k in 0..<6 { let x = cx - dw / 2 + CGFloat(k) * dw / 5; ctx.move(to: CGPoint(x: x, y: cy - dh / 2)); ctx.addLine(to: CGPoint(x: cx - dw / 2 + CGFloat(5 - k) * dw / 5, y: cy + dh / 2)); ctx.strokePath() }
            ellipse(ctx, CGRect(x: cx - dw / 2, y: cy - dh / 2 - dh * 0.09, width: dw, height: dh * 0.18), rgb(0xE9D3A6))
            ellipse(ctx, CGRect(x: cx - dw / 2, y: cy + dh / 2 - dh * 0.09, width: dw, height: dh * 0.18), rgb(0x4A2412))
        }
    },
    "galle-photo-walk": { ctx, w, h, rng in
        linear(ctx, [rgb(0x47375A), rgb(0xD1694A), rgb(0xF3B562)], from: .zero, to: CGPoint(x: 0, y: h * 0.55), locations: [0, 0.55, 1])
        glow(ctx, at: CGPoint(x: w * 0.68, y: h * 0.48), radius: w * 0.3, color: 0xFFD27A, alpha: 0.85)
        ellipse(ctx, CGRect(x: w * 0.64, y: h * 0.44, width: w * 0.08, height: w * 0.08), rgb(0xFFE6A8))
        band(ctx, [rgb(0xC8774F), rgb(0x2F3448)], y0: h * 0.55, y1: h, width: w)
        rect(ctx, CGRect(x: 0, y: h * 0.55, width: w, height: h * 0.45), rgb(0x2F3448, 0.35))
        ctx.setStrokeColor(rgb(0xFFD27A, 0.35)); ctx.setLineWidth(2)
        for _ in 0..<50 { let y = rng.range(h * 0.56, h * 0.75); let x = w * 0.68 + rng.range(-120, 120); ctx.move(to: CGPoint(x: x - 25, y: y)); ctx.addLine(to: CGPoint(x: x + 25, y: y)); ctx.strokePath() }
        let wall = CGMutablePath(); wall.move(to: CGPoint(x: 0, y: h * 0.7)); wall.addLine(to: CGPoint(x: w * 0.55, y: h * 0.64)); wall.addLine(to: CGPoint(x: w * 0.6, y: h)); wall.addLine(to: CGPoint(x: 0, y: h)); wall.closeSubpath()
        fill(ctx, wall, rgb(0x5A3B2A))
        let tower = CGMutablePath(); tower.move(to: CGPoint(x: w * 0.2, y: h * 0.66)); tower.addLine(to: CGPoint(x: w * 0.225, y: h * 0.2)); tower.addLine(to: CGPoint(x: w * 0.275, y: h * 0.2)); tower.addLine(to: CGPoint(x: w * 0.3, y: h * 0.66)); tower.closeSubpath()
        fill(ctx, tower, rgb(0xEFE3D0))
        rect(ctx, CGRect(x: w * 0.215, y: h * 0.16, width: w * 0.07, height: h * 0.045), rgb(0x2D2A2A))
        glow(ctx, at: CGPoint(x: w * 0.25, y: h * 0.18), radius: 46, color: 0xFFF1B0, alpha: 0.9)
        palm(ctx, base: CGPoint(x: w * 0.9, y: h * 0.72), height: h * 0.55, lean: -w * 0.06, color: rgb(0x2A1E1C), rng: &rng)
    },
    "jaffna-tech-meetup": { ctx, w, h, rng in
        linear(ctx, [rgb(0x2D2350), rgb(0x7A4A7E), rgb(0xE59A6E)], from: .zero, to: CGPoint(x: 0, y: h * 0.8), locations: [0, 0.6, 1])
        glow(ctx, at: CGPoint(x: w * 0.3, y: h * 0.7), radius: w * 0.35, color: 0xF6B37A, alpha: 0.5)
        ridge(ctx, w: w, h: h, baseY: h * 0.82, amplitude: h * 0.015, color: rgb(0x231A2A), rng: &rng, roughness: 2)
        for i in 0..<7 {
            palm(ctx, base: CGPoint(x: w * (0.08 + CGFloat(i) * 0.14) + rng.range(-20, 20), y: h * 0.86), height: h * rng.range(0.45, 0.75),
                 lean: rng.range(-20, 20), color: rgb(0x1A1220), rng: &rng, palmyra: true)
        }
    },
    "jazz-under-the-stars": { ctx, w, h, rng in
        linear(ctx, [rgb(0x0B1230), rgb(0x1E2A55), rgb(0x3A2E45)], from: .zero, to: CGPoint(x: 0, y: h))
        stars(ctx, w: w, h: h * 0.6, count: 260, rng: &rng)
        for arc in 0..<3 { // string lights
            let y0 = h * (0.18 + CGFloat(arc) * 0.1)
            for k in 0...24 {
                let t = CGFloat(k) / 24, x = t * w, y = y0 + sin(t * .pi) * h * 0.12
                glow(ctx, at: CGPoint(x: x, y: y), radius: 22, color: 0xFFC46B, alpha: 0.85)
                ellipse(ctx, CGRect(x: x - 3, y: y - 3, width: 6, height: 6), rgb(0xFFF0C4))
            }
        }
        // saxophone silhouette: neck, body, U-bend and flared bell
        glow(ctx, at: CGPoint(x: w * 0.52, y: h * 0.62), radius: w * 0.26, color: 0xEDA71A, alpha: 0.42)
        ctx.setStrokeColor(rgb(0x120D08)); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let body = CGMutablePath()
        body.move(to: CGPoint(x: w * 0.47, y: h * 0.22))
        body.addQuadCurve(to: CGPoint(x: w * 0.55, y: h * 0.3), control: CGPoint(x: w * 0.53, y: h * 0.2))
        body.addLine(to: CGPoint(x: w * 0.555, y: h * 0.74))
        body.addQuadCurve(to: CGPoint(x: w * 0.47, y: h * 0.76), control: CGPoint(x: w * 0.53, y: h * 0.88))
        body.addLine(to: CGPoint(x: w * 0.455, y: h * 0.62))
        ctx.addPath(body); ctx.setLineWidth(w * 0.032); ctx.strokePath()
        let bell = CGMutablePath()
        bell.move(to: CGPoint(x: w * 0.44, y: h * 0.66)); bell.addLine(to: CGPoint(x: w * 0.405, y: h * 0.53))
        bell.addQuadCurve(to: CGPoint(x: w * 0.505, y: h * 0.53), control: CGPoint(x: w * 0.455, y: h * 0.5))
        bell.addLine(to: CGPoint(x: w * 0.47, y: h * 0.66)); bell.closeSubpath()
        fill(ctx, bell, rgb(0x120D08))
        for k in 0..<6 { ellipse(ctx, CGRect(x: w * 0.565, y: h * (0.36 + CGFloat(k) * 0.06), width: 16, height: 16), rgb(0xC98B3A, 0.9)) }
        ridge(ctx, w: w, h: h, baseY: h * 0.9, amplitude: h * 0.02, color: rgb(0x0E0C10), rng: &rng)
    },
    "tech-careers-fair": { ctx, w, h, rng in
        linear(ctx, [rgb(0xE7D6B8), rgb(0xB89B74)], from: .zero, to: CGPoint(x: 0, y: h))
        for i in 0..<4 {
            let x = w * (0.08 + CGFloat(i) * 0.24), aw = w * 0.16
            let arch = CGMutablePath(); arch.addRect(CGRect(x: x, y: h * 0.25, width: aw, height: h * 0.5))
            arch.addEllipse(in: CGRect(x: x, y: h * 0.25 - aw / 2, width: aw, height: aw))
            fill(ctx, arch, rgb(0xFFF6E3))
            glow(ctx, at: CGPoint(x: x + aw / 2, y: h * 0.4), radius: aw, color: 0xFFFFFF, alpha: 0.6)
            ctx.setFillColor(rgb(0xFFF1D2, 0.25))
            let beam = CGMutablePath(); beam.move(to: CGPoint(x: x, y: h * 0.75)); beam.addLine(to: CGPoint(x: x + aw, y: h * 0.75)); beam.addLine(to: CGPoint(x: x + aw * 2.1, y: h)); beam.addLine(to: CGPoint(x: x + aw * 0.6, y: h)); beam.closeSubpath()
            ctx.addPath(beam); ctx.fillPath()
        }
        rect(ctx, CGRect(x: 0, y: h * 0.75, width: w, height: h * 0.25), rgb(0x8C6A45, 0.6))
        for _ in 0..<26 { // figures
            let x = rng.range(0, w), y = rng.range(h * 0.78, h * 0.9), s = rng.range(0.6, 1.1)
            ellipse(ctx, CGRect(x: x, y: y - 40 * s, width: 16 * s, height: 16 * s), rgb(0x3D2C1E, 0.85))
            rect(ctx, CGRect(x: x - 2 * s, y: y - 24 * s, width: 20 * s, height: 46 * s), rgb([0x2F3F55, 0x6B3E2E, 0x3D2C1E, 0x4F5B3A][Int(rng.next() % 4)], 0.85))
        }
    },
    "kolam-lamp-workshop": { ctx, w, h, rng in
        linear(ctx, [rgb(0x6E3B22), rgb(0x9C5631)], from: .zero, to: CGPoint(x: w, y: h))
        let center = CGPoint(x: w * 0.5, y: h * 0.52)
        let palette: [UInt32] = [0xF4E6C8, 0xE84F5E, 0xEDA71A, 0x3FA28C, 0x6C5BD6]
        for ring in 0..<7 {
            let radius = CGFloat(ring + 1) * h * 0.06
            ctx.setStrokeColor(rgb(palette[ring % palette.count], 0.9)); ctx.setLineWidth(5)
            let petals = 8 + ring * 4
            let path = CGMutablePath()
            for k in 0...petals * 8 {
                let t = CGFloat(k) / CGFloat(petals * 8) * .pi * 2
                let r = radius + sin(t * CGFloat(petals)) * h * 0.018
                let p = CGPoint(x: center.x + cos(t) * r * 1.4, y: center.y + sin(t) * r)
                k == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            ctx.addPath(path); ctx.strokePath()
            for k in 0..<petals { let t = CGFloat(k) / CGFloat(petals) * .pi * 2; ellipse(ctx, CGRect(x: center.x + cos(t) * radius * 1.4 - 3, y: center.y + sin(t) * radius - 3, width: 6, height: 6), rgb(0xFFF6E0)) }
        }
        for i in 0..<6 { // clay lamps
            let t = CGFloat(i) / 6 * .pi * 2 + 0.3
            let p = CGPoint(x: center.x + cos(t) * w * 0.4, y: center.y + sin(t) * h * 0.36)
            glow(ctx, at: CGPoint(x: p.x, y: p.y - 26), radius: 70, color: 0xFFB347, alpha: 0.85)
            ellipse(ctx, CGRect(x: p.x - 34, y: p.y - 12, width: 68, height: 28), rgb(0x8A3F1F))
            let flame = CGMutablePath(); flame.move(to: CGPoint(x: p.x, y: p.y - 48)); flame.addQuadCurve(to: CGPoint(x: p.x, y: p.y - 10), control: CGPoint(x: p.x + 16, y: p.y - 22)); flame.addQuadCurve(to: CGPoint(x: p.x, y: p.y - 48), control: CGPoint(x: p.x - 16, y: p.y - 22))
            fill(ctx, flame, rgb(0xFFE8A0))
        }
    },
    "negombo-sunrise-10k": { ctx, w, h, rng in
        linear(ctx, [rgb(0xB9C6D6), rgb(0xF3D4B6), rgb(0xF7C58F)], from: .zero, to: CGPoint(x: 0, y: h * 0.55), locations: [0, 0.7, 1])
        glow(ctx, at: CGPoint(x: w * 0.4, y: h * 0.52), radius: w * 0.25, color: 0xFFE2A8, alpha: 0.9)
        ellipse(ctx, CGRect(x: w * 0.36, y: h * 0.47, width: w * 0.08, height: w * 0.08), rgb(0xFFF1CF))
        band(ctx, [rgb(0xD7B596), rgb(0x6F8295)], y0: h * 0.55, y1: h, width: w)
        rect(ctx, CGRect(x: 0, y: h * 0.55, width: w, height: h * 0.45), rgb(0x6F8295, 0.3))
        ctx.setStrokeColor(rgb(0xFFF1CF, 0.45)); ctx.setLineWidth(2)
        for _ in 0..<60 { let y = rng.range(h * 0.57, h * 0.85); let x = w * 0.4 + rng.range(-90, 90) * (y / h); ctx.move(to: CGPoint(x: x - 20, y: y)); ctx.addLine(to: CGPoint(x: x + 20, y: y)); ctx.strokePath() }
        for i in 0..<3 { // outrigger boats
            let x = w * (0.62 + CGFloat(i) * 0.11), y = h * (0.66 + CGFloat(i) * 0.04), s = 1 + CGFloat(i) * 0.25
            let hull = CGMutablePath(); hull.move(to: CGPoint(x: x - 60 * s, y: y)); hull.addQuadCurve(to: CGPoint(x: x + 60 * s, y: y), control: CGPoint(x: x, y: y + 18 * s)); hull.closeSubpath()
            fill(ctx, hull, rgb(0x2C2622))
            ctx.setStrokeColor(rgb(0x2C2622)); ctx.setLineWidth(3 * s)
            ctx.move(to: CGPoint(x: x - 30 * s, y: y)); ctx.addLine(to: CGPoint(x: x - 20 * s, y: y + 26 * s)); ctx.addLine(to: CGPoint(x: x + 40 * s, y: y + 26 * s)); ctx.strokePath()
            ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x, y: y - 70 * s)); ctx.strokePath()
            let sail = CGMutablePath(); sail.move(to: CGPoint(x: x, y: y - 68 * s)); sail.addLine(to: CGPoint(x: x + 38 * s, y: y - 10 * s)); sail.addLine(to: CGPoint(x: x, y: y - 8 * s)); sail.closeSubpath()
            fill(ctx, sail, rgb(0xE9D7BC))
        }
    },
    "robotics-build-night": { ctx, w, h, rng in
        linear(ctx, [rgb(0x0B0E12), rgb(0x16120E)], from: .zero, to: CGPoint(x: w, y: h))
        ctx.setLineCap(.round)
        for _ in 0..<70 {
            var p = CGPoint(x: rng.range(0, w), y: rng.range(0, h))
            ctx.setStrokeColor(rgb(0xD08A4A, rng.range(0.4, 0.9))); ctx.setLineWidth(rng.range(2, 5))
            ctx.move(to: p)
            for _ in 0..<4 {
                let horizontal = rng.unit() < 0.5
                let length = rng.range(40, 160)
                let diagonal = rng.unit() < 0.3
                p = CGPoint(x: p.x + (horizontal || diagonal ? length : 0) * (rng.unit() < 0.5 ? -1 : 1), y: p.y + (!horizontal || diagonal ? length : 0) * (rng.unit() < 0.5 ? -1 : 1))
                ctx.addLine(to: p)
            }
            ctx.strokePath()
            glow(ctx, at: p, radius: 26, color: 0xFFB35C, alpha: 0.7)
            ellipse(ctx, CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12), rgb(0xFFE0A8))
        }
        glow(ctx, at: CGPoint(x: w * 0.5, y: h * 0.5), radius: w * 0.2, color: 0xEDA71A, alpha: 0.3)
    },
    "island-light-exhibition": { ctx, w, h, rng in
        linear(ctx, [rgb(0xCFD8D3), rgb(0xE9E1C9)], from: .zero, to: CGPoint(x: 0, y: h * 0.5))
        glow(ctx, at: CGPoint(x: w * 0.7, y: h * 0.22), radius: w * 0.3, color: 0xFFF4D6, alpha: 0.8)
        let layers: [UInt32] = [0xA9B8A4, 0x8EA587, 0x6F8E66, 0x557A4C, 0x3F6338, 0x2E4D2A]
        for (i, color) in layers.enumerated() {
            ridge(ctx, w: w, h: h, baseY: h * (0.32 + CGFloat(i) * 0.11), amplitude: h * 0.08, color: rgb(color), rng: &rng)
            rect(ctx, CGRect(x: 0, y: h * (0.3 + CGFloat(i) * 0.11), width: w, height: h * 0.05), rgb(0xF1F0E6, 0.18)) // mist
            if i >= 3 {
                ctx.setStrokeColor(rgb(0x2B4426, 0.45)); ctx.setLineWidth(3)
                for k in 0..<10 { let y = h * (0.42 + CGFloat(i) * 0.11) + CGFloat(k) * 8; ctx.move(to: CGPoint(x: 0, y: y)); ctx.addCurve(to: CGPoint(x: w, y: y + 20), control1: CGPoint(x: w * 0.3, y: y - 30), control2: CGPoint(x: w * 0.7, y: y + 30)); ctx.strokePath() }
            }
        }
    },
    "open-source-day": { ctx, w, h, rng in
        linear(ctx, [rgb(0x101626), rgb(0x241C2E)], from: .zero, to: CGPoint(x: 0, y: h))
        var points: [CGPoint] = []
        for _ in 0..<18 { points.append(CGPoint(x: rng.range(w * 0.05, w * 0.95), y: rng.range(h * 0.12, h * 0.8))) }
        ctx.setStrokeColor(rgb(0xFFCF85, 0.35)); ctx.setLineWidth(1.6)
        for (i, p) in points.enumerated() { for q in points[(i + 1)...].prefix(3) { ctx.move(to: p); ctx.addQuadCurve(to: q, control: CGPoint(x: (p.x + q.x) / 2, y: max(p.y, q.y) + 30)); ctx.strokePath() } }
        let colors: [UInt32] = [0xEDA71A, 0xE8604C, 0xF4D27A, 0x6FB3A6]
        for (i, p) in points.enumerated() {
            let s = rng.range(0.7, 1.3), c = colors[i % colors.count]
            glow(ctx, at: p, radius: 60 * s, color: c, alpha: 0.75)
            let lantern = CGMutablePath()
            lantern.move(to: CGPoint(x: p.x, y: p.y - 28 * s)); lantern.addLine(to: CGPoint(x: p.x + 20 * s, y: p.y)); lantern.addLine(to: CGPoint(x: p.x, y: p.y + 28 * s)); lantern.addLine(to: CGPoint(x: p.x - 20 * s, y: p.y)); lantern.closeSubpath()
            fill(ctx, lantern, rgb(c, 0.95))
            ctx.setStrokeColor(rgb(0xFFF4D6, 0.6)); ctx.setLineWidth(1)
            for k in 0..<4 { ctx.move(to: CGPoint(x: p.x - 6 + CGFloat(k) * 4, y: p.y + 28 * s)); ctx.addLine(to: CGPoint(x: p.x - 6 + CGFloat(k) * 4, y: p.y + 50 * s)); ctx.strokePath() }
        }
    },
    "design-systems-online": { ctx, w, h, rng in
        linear(ctx, [rgb(0x1E1B19), rgb(0x2F2A24)], from: .zero, to: CGPoint(x: w, y: h))
        let colors: [UInt32] = [0xEDA71A, 0xD9644E, 0x4E7A8C, 0xE8D5B0, 0x7C5C9E, 0x3F8F78]
        for i in 0..<14 {
            let rw = rng.range(w * 0.15, w * 0.4), rh = rng.range(h * 0.15, h * 0.45)
            let r = CGRect(x: rng.range(-rw * 0.2, w - rw * 0.8), y: rng.range(-rh * 0.2, h - rh * 0.8), width: rw, height: rh)
            ctx.saveGState()
            ctx.translateBy(x: r.midX, y: r.midY); ctx.rotate(by: rng.range(-0.25, 0.25)); ctx.translateBy(x: -r.midX, y: -r.midY)
            let path = CGPath(roundedRect: r, cornerWidth: 26, cornerHeight: 26, transform: nil)
            fill(ctx, path, rgb(colors[i % colors.count], rng.range(0.25, 0.55)))
            ctx.restoreGState()
        }
    },
    "junior-cricket-clinic": { ctx, w, h, rng in
        linear(ctx, [rgb(0xBFD3E0), rgb(0xF2E3C2)], from: .zero, to: CGPoint(x: 0, y: h * 0.38))
        for i in 0..<9 { let x = w * CGFloat(i) / 8; glow(ctx, at: CGPoint(x: x, y: h * 0.36), radius: rng.range(60, 120), color: 0x3E5A35, alpha: 0.95) }
        rect(ctx, CGRect(x: 0, y: h * 0.38, width: w, height: h * 0.62), rgb(0x5E8A44))
        ellipse(ctx, CGRect(x: -w * 0.2, y: h * 0.42, width: w * 1.4, height: h * 0.9), rgb(0x6E9B4F))
        for k in 0..<10 { rect(ctx, CGRect(x: 0, y: h * 0.42 + CGFloat(k) * h * 0.06, width: w, height: h * 0.03), rgb(0x86AE62, 0.25)) }
        let pitch = CGMutablePath(); pitch.move(to: CGPoint(x: w * 0.46, y: h * 0.5)); pitch.addLine(to: CGPoint(x: w * 0.54, y: h * 0.5)); pitch.addLine(to: CGPoint(x: w * 0.6, y: h * 0.95)); pitch.addLine(to: CGPoint(x: w * 0.4, y: h * 0.95)); pitch.closeSubpath()
        fill(ctx, pitch, rgb(0xD9C49A))
        for s in 0..<3 { rect(ctx, CGRect(x: w * 0.485 + CGFloat(s) * 10, y: h * 0.47, width: 4, height: h * 0.05), rgb(0xF3EBD9)) }
        ctx.setFillColor(rgb(0x2D3D24, 0.45))
        let shadow = CGMutablePath(); shadow.move(to: CGPoint(x: w * 0.5, y: h * 0.52)); shadow.addLine(to: CGPoint(x: w * 0.95, y: h * 0.6)); shadow.addLine(to: CGPoint(x: w * 0.95, y: h * 0.62)); shadow.addLine(to: CGPoint(x: w * 0.5, y: h * 0.53)); shadow.closeSubpath()
        ctx.addPath(shadow); ctx.fillPath()
        for i in 0..<4 { // small players
            let x = w * (0.2 + CGFloat(i) * 0.2), y = h * (0.62 + CGFloat(i % 2) * 0.1)
            ellipse(ctx, CGRect(x: x, y: y - 34, width: 14, height: 14), rgb(0x4A3426))
            rect(ctx, CGRect(x: x - 1, y: y - 20, width: 16, height: 36), rgb(0xF4EFE4))
            ctx.setFillColor(rgb(0x2D3D24, 0.4)); ctx.fill(CGRect(x: x + 14, y: y + 14, width: 60, height: 5))
        }
    },
    "startup-pitch-night": { ctx, w, h, rng in
        linear(ctx, [rgb(0x0B1424), rgb(0x16233A)], from: .zero, to: CGPoint(x: 0, y: h))
        ctx.setFillColor(rgb(0xBFD7F2, 0.18))
        let cone = CGMutablePath(); cone.move(to: CGPoint(x: w * 0.62, y: 0)); cone.addLine(to: CGPoint(x: w * 0.72, y: 0)); cone.addLine(to: CGPoint(x: w * 0.6, y: h * 0.8)); cone.addLine(to: CGPoint(x: w * 0.3, y: h * 0.8)); cone.closeSubpath()
        ctx.addPath(cone); ctx.fillPath()
        for _ in 0..<30 { glow(ctx, at: CGPoint(x: rng.range(w * 0.3, w * 0.7), y: rng.range(h * 0.1, h * 0.75)), radius: rng.range(40, 120), color: 0x9EC2E6, alpha: 0.08) }
        glow(ctx, at: CGPoint(x: w * 0.45, y: h * 0.8), radius: w * 0.22, color: 0xDDEBFA, alpha: 0.5)
        rect(ctx, CGRect(x: 0, y: h * 0.8, width: w, height: h * 0.2), rgb(0x0A0F18))
        rect(ctx, CGRect(x: w * 0.42, y: h * 0.6, width: w * 0.07, height: h * 0.2), rgb(0x1A1F2A))
        ellipse(ctx, CGRect(x: w * 0.465, y: h * 0.47, width: 34, height: 34), rgb(0x0E1118))
        rect(ctx, CGRect(x: w * 0.458, y: h * 0.51, width: 44, height: h * 0.29), rgb(0x0E1118))
        for k in 0..<22 { let x = CGFloat(k) / 21 * w; ellipse(ctx, CGRect(x: x - 22, y: h * 0.9, width: 44, height: 56), rgb(0x05080E)) }
        glow(ctx, at: CGPoint(x: w * 0.2, y: h * 0.84), radius: 90, color: 0xEDA71A, alpha: 0.25)
    },
    "lagoon-music-night": { ctx, w, h, rng in
        linear(ctx, [rgb(0x2B2A4A), rgb(0x8A5A6A), rgb(0xE59B6A)], from: .zero, to: CGPoint(x: 0, y: h * 0.5), locations: [0, 0.65, 1])
        ridge(ctx, w: w, h: h, baseY: h * 0.5, amplitude: h * 0.02, color: rgb(0x1F1B2A), rng: &rng, roughness: 2)
        band(ctx, [rgb(0xC98A6A), rgb(0x2A2B45)], y0: h * 0.52, y1: h, width: w)
        rect(ctx, CGRect(x: 0, y: h * 0.52, width: w, height: h * 0.48), rgb(0x2A2B45, 0.25))
        for i in 0..<8 {
            let x = w * (0.08 + CGFloat(i) * 0.12), y = h * 0.47
            glow(ctx, at: CGPoint(x: x, y: y), radius: 30, color: 0xFFC56E, alpha: 0.9)
            ctx.setStrokeColor(rgb(0xFFC56E, 0.4)); ctx.setLineWidth(2.5)
            for j in 0..<6 { let yy = h * 0.56 + CGFloat(j) * 16; ctx.move(to: CGPoint(x: x - rng.range(6, 24), y: yy)); ctx.addLine(to: CGPoint(x: x + rng.range(6, 24), y: yy)); ctx.strokePath() }
        }
        for i in 0..<2 {
            let x = w * (0.3 + CGFloat(i) * 0.35), y = h * (0.72 + CGFloat(i) * 0.06)
            let hull = CGMutablePath(); hull.move(to: CGPoint(x: x - 90, y: y)); hull.addQuadCurve(to: CGPoint(x: x + 90, y: y), control: CGPoint(x: x, y: y + 26)); hull.closeSubpath()
            fill(ctx, hull, rgb(0x15131C))
        }
        palm(ctx, base: CGPoint(x: w * 0.06, y: h * 0.56), height: h * 0.5, lean: w * 0.05, color: rgb(0x15131C), rng: &rng)
    },
    "Onboarding1": { ctx, w, h, rng in // a great rock at golden hour above the jungle
        linear(ctx, [rgb(0x5A4A6A), rgb(0xD98A5A), rgb(0xF6C27A)], from: .zero, to: CGPoint(x: 0, y: h * 0.62), locations: [0, 0.6, 1])
        glow(ctx, at: CGPoint(x: w * 0.72, y: h * 0.5), radius: w * 0.5, color: 0xFFD58A, alpha: 0.7)
        let rock = CGMutablePath()
        rock.move(to: CGPoint(x: w * 0.18, y: h * 0.62)); rock.addCurve(to: CGPoint(x: w * 0.32, y: h * 0.3), control1: CGPoint(x: w * 0.2, y: h * 0.45), control2: CGPoint(x: w * 0.24, y: h * 0.32))
        rock.addLine(to: CGPoint(x: w * 0.62, y: h * 0.29)); rock.addCurve(to: CGPoint(x: w * 0.78, y: h * 0.62), control1: CGPoint(x: w * 0.72, y: h * 0.33), control2: CGPoint(x: w * 0.76, y: h * 0.48)); rock.closeSubpath()
        fill(ctx, rock, rgb(0x7A4A34))
        ctx.saveGState(); ctx.addPath(rock); ctx.clip()
        linear(ctx, [rgb(0xC6774A, 0.8), rgb(0x3E2418, 0.2)], from: CGPoint(x: w * 0.8, y: h * 0.3), to: CGPoint(x: w * 0.2, y: h * 0.6))
        ctx.restoreGState()
        let greens: [UInt32] = [0x4E6B3E, 0x3B5531, 0x2B4126, 0x1E301B]
        for (i, c) in greens.enumerated() { ridge(ctx, w: w, h: h, baseY: h * (0.6 + CGFloat(i) * 0.1), amplitude: h * 0.03, color: rgb(c), rng: &rng, roughness: 7) }
        for _ in 0..<5 { palm(ctx, base: CGPoint(x: rng.range(0, w), y: h * rng.range(0.8, 0.95)), height: h * rng.range(0.18, 0.3), lean: rng.range(-30, 30), color: rgb(0x152214), rng: &rng) }
    },
    "Onboarding2": { ctx, w, h, rng in // a stage with warm lights and an audience
        linear(ctx, [rgb(0x140F12), rgb(0x2A1A16)], from: .zero, to: CGPoint(x: 0, y: h))
        for i in 0..<5 {
            let x = w * (0.1 + CGFloat(i) * 0.2)
            ctx.setFillColor(rgb(0xFFC77A, 0.12))
            let beam = CGMutablePath(); beam.move(to: CGPoint(x: x - 10, y: 0)); beam.addLine(to: CGPoint(x: x + 10, y: 0)); beam.addLine(to: CGPoint(x: w * 0.5 + (x - w * 0.5) * 0.3 + 80, y: h * 0.62)); beam.addLine(to: CGPoint(x: w * 0.5 + (x - w * 0.5) * 0.3 - 80, y: h * 0.62)); beam.closeSubpath()
            ctx.addPath(beam); ctx.fillPath()
            glow(ctx, at: CGPoint(x: x, y: h * 0.04), radius: 70, color: 0xFFD08A, alpha: 0.9)
        }
        glow(ctx, at: CGPoint(x: w * 0.5, y: h * 0.62), radius: w * 0.5, color: 0xEDA71A, alpha: 0.45)
        rect(ctx, CGRect(x: 0, y: h * 0.62, width: w, height: h * 0.05), rgb(0x3A2418))
        for row in 0..<4 {
            for k in 0..<14 {
                let x = CGFloat(k) / 13 * w + CGFloat(row % 2) * 30 + rng.range(-8, 8), y = h * (0.72 + CGFloat(row) * 0.08)
                ellipse(ctx, CGRect(x: x - 26, y: y - 30, width: 52, height: 60), rgb(0x0A0708))
                ellipse(ctx, CGRect(x: x - 16, y: y - 58, width: 32, height: 32), rgb(0x0A0708))
            }
        }
    },
    "Onboarding3": { ctx, w, h, rng in // dawn mist over hills with a single lamp
        linear(ctx, [rgb(0x2F3A4A), rgb(0x8A8F8C), rgb(0xE6D2AE)], from: .zero, to: CGPoint(x: 0, y: h * 0.6), locations: [0, 0.6, 1])
        glow(ctx, at: CGPoint(x: w * 0.5, y: h * 0.58), radius: w * 0.5, color: 0xFFE7B8, alpha: 0.6)
        let layers: [UInt32] = [0x7F8A84, 0x63716A, 0x4A5A52, 0x34443C, 0x22302A]
        for (i, c) in layers.enumerated() {
            ridge(ctx, w: w, h: h, baseY: h * (0.5 + CGFloat(i) * 0.1), amplitude: h * 0.05, color: rgb(c), rng: &rng)
            rect(ctx, CGRect(x: 0, y: h * (0.48 + CGFloat(i) * 0.1), width: w, height: h * 0.04), rgb(0xF3EEE2, 0.16))
        }
        let base = CGPoint(x: w * 0.5, y: h * 0.82)
        glow(ctx, at: CGPoint(x: base.x, y: base.y - 40), radius: 160, color: 0xEDA71A, alpha: 0.7)
        rect(ctx, CGRect(x: base.x - 8, y: base.y - 40, width: 16, height: 60), rgb(0x1A1410))
        let flame = CGMutablePath(); flame.move(to: CGPoint(x: base.x, y: base.y - 78)); flame.addQuadCurve(to: CGPoint(x: base.x, y: base.y - 42), control: CGPoint(x: base.x + 14, y: base.y - 56)); flame.addQuadCurve(to: CGPoint(x: base.x, y: base.y - 78), control: CGPoint(x: base.x - 14, y: base.y - 56))
        fill(ctx, flame, rgb(0xFFE9A8))
    },
]

// MARK: - Output

func writeJPEG(_ image: CGImage, to url: URL, quality: CGFloat = 0.84) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    CGImageDestinationFinalize(destination)
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func writeImageSet(_ directory: URL, files: [(name: String, scale: String?)], extraProperties: String = "") {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let images = files.map { file in
        file.scale.map { "    { \"filename\" : \"\(file.name)\", \"idiom\" : \"universal\", \"scale\" : \"\($0)\" }" }
            ?? "    { \"filename\" : \"\(file.name)\", \"idiom\" : \"universal\" }"
    }.joined(separator: ",\n")
    let json = "{\n  \"images\" : [\n\(images)\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\(extraProperties)\n}\n"
    try? json.write(to: directory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Zuno/Resources/Assets.xcassets")
let devAssets = root.appendingPathComponent("Zuno/Resources/DevelopmentAssets.xcassets")
let storageSeed = root.appendingPathComponent("supabase/seed/images")

func render(_ name: String, width: Int, height: Int, strokes: Int) -> CGImage {
    var rng = RNG(name)
    let ctx = makeContext(width, height)
    scenes[name]!(ctx, CGFloat(width), CGFloat(height), &rng)
    return paintify(ctx.makeImage()!, rng: &rng, strokes: strokes, strokeScale: CGFloat(width) / 1400)
}

for name in scenes.keys.sorted() {
    if name.hasPrefix("Onboarding") {
        let image = render(name, width: 1200, height: 1400, strokes: 60_000)
        let set = assets.appendingPathComponent("\(name).imageset")
        writeJPEG(image, to: set.appendingPathComponent("\(name).jpg"))
        writeImageSet(set, files: [("\(name).jpg", nil)])
    } else {
        let image = render(name, width: 1400, height: 900, strokes: 50_000)
        let set = devAssets.appendingPathComponent("seed-\(name).imageset")
        writeJPEG(image, to: set.appendingPathComponent("seed-\(name).jpg"))
        writeImageSet(set, files: [("seed-\(name).jpg", nil)])
        writeJPEG(image, to: storageSeed.appendingPathComponent("\(name).jpg"), quality: 0.82)
    }
    print("rendered \(name)")
}

// MARK: - Brand assets (Sansita One)

let fontURL = root.appendingPathComponent("Zuno/Resources/Fonts/SansitaOne-Regular.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)

func textImage(_ text: String, size: CGFloat, canvas: CGSize, background: CGColor?, dotRatio: CGFloat = 0.16, iconMode: Bool = false) -> CGImage {
    let w = Int(canvas.width), h = Int(canvas.height)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if let background {
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if iconMode {
            let center = CGPoint(x: canvas.width * 0.5, y: canvas.height * 0.62)
            let gradient = CGGradient(colorsSpace: space, colors: [rgb(0xEDA71A, 0.22), rgb(0xEDA71A, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: canvas.width * 0.7, options: [])
        }
    }
    let font = CTFontCreateWithName("SansitaOne-Regular" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let dot = size * dotRatio
    let totalWidth = bounds.width + dot * 1.3
    let x = (canvas.width - totalWidth) / 2 - bounds.minX
    let y = (canvas.height - bounds.height) / 2 - bounds.minY
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
    ctx.setFillColor(rgb(0xEDA71A))
    ctx.fillEllipse(in: CGRect(x: x + bounds.maxX + dot * 0.3, y: y, width: dot, height: dot))
    return ctx.makeImage()!
}

// App icon: single 1024 px universal icon.
let icon = textImage("Z", size: 640, canvas: CGSize(width: 1024, height: 1024), background: rgb(0x111110), dotRatio: 0.15, iconMode: true)
let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
writePNG(icon, to: iconSet.appendingPathComponent("AppIcon-1024.png"))
try? """
{
  "images" : [
    { "filename" : "AppIcon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""".write(to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// Launch wordmark @2x/@3x (transparent, rendered on the LaunchBackground colour).
for scale in [2, 3] {
    let image = textImage("Zuno", size: 52 * CGFloat(scale), canvas: CGSize(width: 200 * scale, height: 90 * scale), background: nil)
    writePNG(image, to: assets.appendingPathComponent("LaunchWordmark.imageset/LaunchWordmark@\(scale)x.png"))
}
writeImageSet(assets.appendingPathComponent("LaunchWordmark.imageset"),
              files: [("LaunchWordmark@2x.png", "2x"), ("LaunchWordmark@3x.png", "3x")])
print("rendered brand assets")
