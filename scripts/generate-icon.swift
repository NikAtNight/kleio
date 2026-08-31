// Renders the Scribe app icon: a macOS-style rounded square with an
// indigo→violet gradient and a white waveform-with-quote motif.
// Usage: swift generate-icon.swift <output.png> <size>
import AppKit

let outputPath = CommandLine.arguments[1]
let size = Int(CommandLine.arguments[2])!
let s = CGFloat(size)

let image = NSImage(size: NSSize(width: s, height: s))
image.lockFocus()

// macOS icon grid: content inset ~10%, corner radius ~22.5% of size.
let inset = s * 0.10
let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
let radius = rect.width * 0.225
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// Soft shadow behind the tile.
if let ctx = NSGraphicsContext.current?.cgContext {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.04,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    path.fill()
    ctx.restoreGState()
}

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.31, green: 0.27, blue: 0.90, alpha: 1),
    NSColor(calibratedRed: 0.56, green: 0.27, blue: 0.96, alpha: 1),
    NSColor(calibratedRed: 0.72, green: 0.32, blue: 0.98, alpha: 1),
])!
gradient.draw(in: path, angle: 90)

// Subtle top highlight.
let highlight = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.22),
    NSColor.white.withAlphaComponent(0.0),
])!
highlight.draw(in: path, angle: -90)

// Waveform: symmetric vertical bars, heights shaped like speech.
let barHeights: [CGFloat] = [0.18, 0.34, 0.62, 0.88, 0.55, 0.72, 0.40, 0.25]
let barCount = barHeights.count
let waveWidth = rect.width * 0.62
let barWidth = waveWidth / CGFloat(barCount) * 0.52
let gap = (waveWidth - barWidth * CGFloat(barCount)) / CGFloat(barCount - 1)
let maxBarHeight = rect.height * 0.46
let startX = rect.midX - waveWidth / 2
let midY = rect.midY - rect.height * 0.02

NSColor.white.setFill()
for (i, h) in barHeights.enumerated() {
    let barHeight = maxBarHeight * h
    let x = startX + CGFloat(i) * (barWidth + gap)
    let bar = NSRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
    NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
}

image.unlockFocus()

let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outputPath))
