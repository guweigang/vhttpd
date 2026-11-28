// Export Desktop assets from the approved artwork, preserving alpha and aspect
// ratio. Run: swift desktop/prepare_icon.swift desktop
import AppKit
import ImageIO

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift prepare_icon.swift DESKTOP_DIRECTORY\n", stderr)
    exit(2)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let artwork = root.deletingLastPathComponent().appendingPathComponent("assets/1128")
let output = root.appendingPathComponent("assets")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func trimmed(_ name: String) -> CGImage {
    let url = artwork.appendingPathComponent(name)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Cannot read artwork: \(url.path)")
    }
    let width = image.width, height = image.height
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    var left = width, top = height, right = -1, bottom = -1
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            // Near-invisible matte residue (up to 3% alpha) otherwise makes
            // the bounds cover the original canvas. Clear it before trimming.
            if pixels[offset + 3] <= 8 {
                for channel in 0..<4 { pixels[offset + channel] = 0 }
                continue
            }
            left = min(left, x); top = min(top, y)
            right = max(right, x); bottom = max(bottom, y)
        }
    }
    precondition(right >= left && bottom >= top, "Artwork is fully transparent: \(name)")
    let bounds = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    print("\(name): \(width)×\(height) → subject \(Int(bounds.width))×\(Int(bounds.height))")
    // Normalize premultiplied sRGB so invisible background RGB cannot leak
    // into the edges when a platform rescales the image.
    return context.makeImage()!.cropping(to: bounds)!
}

let appIcon = trimmed("vhttpd_app_icon.png")
let mark = trimmed("vhttpd_icon.png")
let logo = trimmed("vhttpd_logo_dark.png")
let lightLogo = trimmed("vhttpd_logo_light.png")

func render(_ image: CGImage, size: Int, margin: Double) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.interpolationQuality = .high
    let inset = max(1, (Double(size) * margin).rounded())
    let available = Double(size) - inset * 2
    let scale = available / Double(max(image.width, image.height))
    let width = Double(image.width) * scale, height = Double(image.height) * scale
    context.draw(image, in: CGRect(x: (Double(size) - width) / 2,
        y: (Double(size) - height) / 2, width: width, height: height))
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

// The artwork already has a dark rounded tile. Add only a small transparent
// margin, with no additional tile or border around it.
func renderApp(_ size: Int) -> Data { render(appIcon, size: size, margin: 0.05) }
try renderApp(1024).write(to: output.appendingPathComponent("vhttpd-icon.png"))
try render(mark, size: 512, margin: 0.02).write(to: output.appendingPathComponent("vhttpd-mark.png"))

// Preserve the wide wordmark without a square canvas.
let logoBitmap = NSBitmapImageRep(cgImage: logo)
try logoBitmap.representation(using: .png, properties: [:])!
    .write(to: output.appendingPathComponent("vhttpd-logo.png"))

let lightLogoBitmap = NSBitmapImageRep(cgImage: lightLogo)
try lightLogoBitmap.representation(using: .png, properties: [:])!
    .write(to: output.appendingPathComponent("vhttpd-logo-light.png"))

func bigEndian(_ value: Int) -> Data {
    Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
          UInt8((value >> 8) & 255), UInt8(value & 255)])
}
var chunks = Data()
for (type, size) in [("icp4",16), ("icp5",32), ("icp6",64), ("ic07",128),
    ("ic08",256), ("ic09",512), ("ic10",1024), ("ic11",32),
    ("ic12",64), ("ic13",256), ("ic14",512)] {
    let png = renderApp(size)
    chunks += Data(type.utf8) + bigEndian(png.count + 8) + png
}
try (Data("icns".utf8) + bigEndian(chunks.count + 8) + chunks)
    .write(to: output.appendingPathComponent("vhttpd-macos.icns"))

// ICO embeds the same artwork at native Windows icon sizes.
func word(_ value: Int) -> Data { Data([UInt8(value & 255), UInt8((value >> 8) & 255)]) }
func dword(_ value: Int) -> Data { word(value & 65535) + word(value >> 16) }
let sizes = [16, 32, 48, 64, 128, 256]
func writeICO(_ images: [Data], name: String) throws {
var directory = word(0) + word(1) + word(sizes.count)
var offset = 6 + sizes.count * 16
for (size, image) in zip(sizes, images) {
    directory += Data([UInt8(size & 255), UInt8(size & 255), 0, 0])
    directory += word(1) + word(32) + dword(image.count) + dword(offset)
    offset += image.count
}
for image in images { directory += image }
try directory.write(to: output.appendingPathComponent(name))
}
try writeICO(sizes.map(renderApp), name: "vhttpd-windows.ico")
try writeICO(sizes.map { render(mark, size: $0, margin: 0.02) }, name: "vhttpd-tray.ico")
