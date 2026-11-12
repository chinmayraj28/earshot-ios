// Draws Earshot's 1024×1024 app icon with Core Graphics.
// Usage: swift Tools/make_icon.swift <output.png>
//
// Design: a warm ember point of sound on deep ink, with three rings that fade
// out a short way from the centre — the "earshot" motif used throughout the app.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
// No alpha channel: App Store icons must be opaque.
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not create bitmap context")
}

let s = CGFloat(size)
let center = CGPoint(x: s / 2, y: s / 2)

// Background: deep ink with a faint warm glow behind the centre.
ctx.setFillColor(rgb(0x121010))
ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
let glow = CGGradient(colorsSpace: space, colors: [rgb(0x3A2018), rgb(0x1E1513), rgb(0x121010)] as CFArray,
                      locations: [0, 0.45, 1])!
ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: s * 0.62,
                       options: [.drawsAfterEndLocation])

// Rings: thinner and fainter as they travel outward.
let rings: [(radius: CGFloat, width: CGFloat, alpha: CGFloat)] = [
    (178, 26, 0.90),
    (282, 20, 0.48),
    (386, 15, 0.20),
]
for ring in rings {
    ctx.setStrokeColor(rgb(0xF0673A, ring.alpha))
    ctx.setLineWidth(ring.width)
    ctx.strokeEllipse(in: CGRect(x: center.x - ring.radius, y: center.y - ring.radius,
                                 width: ring.radius * 2, height: ring.radius * 2))
}

// The point of sound: a lit ember dot.
let dotRadius: CGFloat = 84
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
ctx.clip()
let ember = CGGradient(colorsSpace: space, colors: [rgb(0xFF8A5C), rgb(0xF0673A), rgb(0xE05A2E)] as CFArray,
                       locations: [0, 0.6, 1])!
let highlight = CGPoint(x: center.x - dotRadius * 0.2, y: center.y + dotRadius * 0.2)
ctx.drawRadialGradient(ember, startCenter: highlight, startRadius: 0, endCenter: center, endRadius: dotRadius * 1.15,
                       options: [.drawsAfterEndLocation])
ctx.restoreGState()

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not create image")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(output)") }
print("Wrote \(output)")
