import AppKit
// Draws the 1024px Inkwell app icon: navy ground, cream page, a coral ink stroke ending in a nib.
let size: CGFloat = 1024
let cg = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
let navy = NSColor(srgbRed: 0x1F/255, green: 0x3A/255, blue: 0x5F/255, alpha: 1)
let deep = NSColor(srgbRed: 0x14/255, green: 0x26/255, blue: 0x40/255, alpha: 1)
let cream = NSColor(srgbRed: 0xF6/255, green: 0xF1/255, blue: 0xE4/255, alpha: 1)
let coral = NSColor(srgbRed: 0xE9/255, green: 0x69/255, blue: 0x4B/255, alpha: 1)
NSGradient(starting: navy, ending: deep)!.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)

// page
let page = NSBezierPath(roundedRect: NSRect(x: 214, y: 170, width: 596, height: 684), xRadius: 56, yRadius: 56)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 40; shadow.shadowOffset = NSSize(width: 0, height: -18); shadow.set()
cream.setFill(); page.fill()
NSGraphicsContext.current?.restoreGraphicsState()

// ruled lines
NSColor(srgbRed: 0x1F/255, green: 0x3A/255, blue: 0x5F/255, alpha: 0.14).setStroke()
for i in 0..<5 {
    let y = 300 + CGFloat(i) * 92
    let l = NSBezierPath(); l.lineWidth = 6
    l.move(to: NSPoint(x: 276, y: y)); l.line(to: NSPoint(x: 748, y: y)); l.stroke()
}

// ink stroke
let stroke = NSBezierPath(); stroke.lineWidth = 46; stroke.lineCapStyle = .round; stroke.lineJoinStyle = .round
stroke.move(to: NSPoint(x: 290, y: 420))
stroke.curve(to: NSPoint(x: 520, y: 560), controlPoint1: NSPoint(x: 360, y: 700), controlPoint2: NSPoint(x: 430, y: 380))
stroke.curve(to: NSPoint(x: 700, y: 640), controlPoint1: NSPoint(x: 600, y: 700), controlPoint2: NSPoint(x: 640, y: 560))
coral.setStroke(); stroke.stroke()

// nib
NSGraphicsContext.current?.saveGraphicsState()
let t = NSAffineTransform(); t.translateX(by: 700, yBy: 640); t.rotate(byDegrees: -38); t.concat()
let nib = NSBezierPath()
nib.move(to: NSPoint(x: 0, y: 0)); nib.line(to: NSPoint(x: 40, y: 110)); nib.line(to: NSPoint(x: 28, y: 230))
nib.line(to: NSPoint(x: -28, y: 230)); nib.line(to: NSPoint(x: -40, y: 110)); nib.close()
NSColor(srgbRed: 0xF2/255, green: 0xB6/255, blue: 0x4A/255, alpha: 1).setFill(); nib.fill()
navy.setStroke(); nib.lineWidth = 6; nib.stroke()
navy.setFill(); NSBezierPath(ovalIn: NSRect(x: -9, y: 120, width: 18, height: 18)).fill()
let slit = NSBezierPath(); slit.lineWidth = 7; slit.move(to: NSPoint(x: 0, y: 129)); slit.line(to: NSPoint(x: 0, y: 14))
navy.setStroke(); slit.stroke()
NSGraphicsContext.current?.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
