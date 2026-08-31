import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 8 else {
    fatalError("Usage: pack-icon.swift <output.icns> <16.png> <32.png> <64.png> <128.png> <256.png> <512.png> <1024.png>")
}

let output = URL(fileURLWithPath: String(arguments[arguments.startIndex]))
let inputPaths = arguments.dropFirst()
let chunkTypes = ["icp4", "icp5", "icp6", "ic07", "ic08", "ic09", "ic10"]

func bigEndianData(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
}

var chunks = Data()
for (type, inputPath) in zip(chunkTypes, inputPaths) {
    let image = try Data(contentsOf: URL(fileURLWithPath: String(inputPath)))
    chunks.append(type.data(using: .ascii)!)
    chunks.append(bigEndianData(UInt32(image.count + 8)))
    chunks.append(image)
}

var icon = Data("icns".utf8)
icon.append(bigEndianData(UInt32(chunks.count + 8)))
icon.append(chunks)
try icon.write(to: output, options: .atomic)
