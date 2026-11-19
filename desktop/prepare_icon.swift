// Reproducible native icon export. Keep the existing mark unchanged and draw
// the platform tile as a flat #FFFFFF shape, independent of Dock materials.
import AppKit
import ImageIO

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let source = CGImageSourceCreateWithURL(root.appendingPathComponent("assets/vhttpd-mark.png") as CFURL, nil)!
let mark = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let output = root.appendingPathComponent("assets")
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func render(_ size: Int) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
        cornerWidth: 184, cornerHeight: 184, transform: nil))
    context.fillPath()
    context.draw(mark, in: CGRect(x: 132, y: 132, width: 760, height: 760))
    if size == 1024 {
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        let white = (150 * size + 512) * 4
        precondition((0..<4).allSatisfy { pixels[white + $0] == 255 }, "Icon tile must be opaque #FFFFFF")
        precondition(pixels[3] == 0, "Margin outside the tile must stay transparent")
    }
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(1024).write(to: output.appendingPathComponent("vhttpd-icon.png"))
func bigEndian(_ value: Int) -> Data {
    Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
          UInt8((value >> 8) & 255), UInt8(value & 255)])
}
var chunks = Data()
for (type, size) in [("icp4",16), ("icp5",32), ("icp6",64), ("ic07",128),
    ("ic08",256), ("ic09",512), ("ic10",1024), ("ic11",32),
    ("ic12",64), ("ic13",256), ("ic14",512)] {
    let png = render(size)
    chunks += Data(type.utf8) + bigEndian(png.count + 8) + png
}
try (Data("icns".utf8) + bigEndian(chunks.count + 8) + chunks)
    .write(to: output.appendingPathComponent("vhttpd-macos.icns"))

// ICO embeds the same rendered PNGs at each Windows icon size.
func word(_ value: Int) -> Data { Data([UInt8(value & 255), UInt8((value >> 8) & 255)]) }
func dword(_ value: Int) -> Data { word(value & 65535) + word(value >> 16) }
let sizes = [16, 32, 48, 64, 128, 256]
let images = sizes.map(render)
var directory = word(0) + word(1) + word(sizes.count)
var offset = 6 + sizes.count * 16
for (size, image) in zip(sizes, images) {
    directory += Data([UInt8(size & 255), UInt8(size & 255), 0, 0])
    directory += word(1) + word(32) + dword(image.count) + dword(offset)
    offset += image.count
}
for image in images { directory += image }
try directory.write(to: output.appendingPathComponent("vhttpd-windows.ico"))
