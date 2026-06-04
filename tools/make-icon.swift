import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else { fputs("usage: make-icon <src.png> <dst.png>\n", stderr); exit(1) }
let srcPath = args[1], dstPath = args[2]

guard let img = NSImage(contentsOfFile: srcPath),
      let tiff = img.tiffRepresentation,
      let src = NSBitmapImageRep(data: tiff) else {
    fputs("error: cannot load \(srcPath)\n", stderr); exit(1)
}
let w = src.pixelsWide, h = src.pixelsHigh

// --- Find the content bounding box (drop the near-white surround) ---
func isContent(_ x: Int, _ y: Int) -> Bool {
    guard let c = src.colorAt(x: x, y: y) else { return false }
    let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
    return !(r > 0.96 && g > 0.96 && b > 0.96)
}
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w where isContent(x, y) {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    }
}
guard maxX > minX, maxY > minY else { fputs("error: no content found\n", stderr); exit(1) }
// Tiny inset to drop anti-aliased edge pixels.
let inset = 2
minX += inset; minY += inset; maxX -= inset; maxY -= inset
let cropW = maxX - minX, cropH = maxY - minY
// NSImage from-rect uses bottom-left origin.
let fromRect = NSRect(x: minX, y: h - maxY, width: cropW, height: cropH)

// --- Compose the masked, padded icon ---
let size = 1024
let pad: CGFloat = 100
let artRect = NSRect(x: pad, y: pad, width: CGFloat(size) - 2*pad, height: CGFloat(size) - 2*pad)
let radius = artRect.width * 0.2237            // Big Sur-ish corner radius
let overscan: CGFloat = 0.04                    // hide the source's own rounded corners
let dxy = artRect.width * overscan / 2
let drawRect = artRect.insetBy(dx: -dxy, dy: -dxy)

guard let out = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSGraphicsContext.current?.imageInterpolation = .high
NSBezierPath(roundedRect: artRect, xRadius: radius, yRadius: radius).addClip()
img.draw(in: drawRect, from: fromRect, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let png = out.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: dstPath))
print("wrote \(dstPath) (cropped \(cropW)x\(cropH) from \(w)x\(h))")
