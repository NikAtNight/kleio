// Resize the Kleio master icon to an exact pixel size, preserving transparency.
// Usage: swift generate-icon.swift <source.png> <output.png> <size>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 4,
      let size = Int(CommandLine.arguments[3]), (1...1024).contains(size) else {
    fputs("Usage: swift generate-icon.swift <source.png> <output.png> <size: 1...1024>\n", stderr)
    exit(1)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == image.height,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("Could not load a square source image or create the icon canvas.\n", stderr)
    exit(1)
}

context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
guard let resized = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL,
                                                       UTType.png.identifier as CFString, 1, nil) else {
    fputs("Could not create the output PNG.\n", stderr)
    exit(1)
}
CGImageDestinationAddImage(destination, resized, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("Could not write the output PNG.\n", stderr)
    exit(1)
}
