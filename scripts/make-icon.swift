import AppKit
// Draws the 1024px Inkwell app icon: flat deep-blue ground, a white "i" stem and one coral drop of ink.
let size: CGFloat = 1024
let cg = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
let blue = NSColor(srgbRed: 0x1B/255, green: 0x36/255, blue: 0x5D/255, alpha: 1)
let paper = NSColor(srgbRed: 0xFA/255, green: 0xF7/255, blue: 0xEF/255, alpha: 1)
let coral = NSColor(srgbRed: 0xF0/255, green: 0x6A/255, blue: 0x4A/255, alpha: 1)
blue.setFill(); NSRect(x: 0, y: 0, width: size, height: size).fill()

// stem
paper.setFill()
NSBezierPath(roundedRect: NSRect(x: 512 - 100, y: 172, width: 200, height: 430), xRadius: 100, yRadius: 100).fill()
// ink drop
coral.setFill()
NSBezierPath(ovalIn: NSRect(x: 512 - 104, y: 652, width: 208, height: 208)).fill()

NSGraphicsContext.restoreGraphicsState()
let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
