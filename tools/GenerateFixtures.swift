import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func write(_ image: CGImage, name: String) {
    let url = directory.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    assert(CGImageDestinationFinalize(dest))
}
let image = NSImage(size: NSSize(width: 1100, height: 480))
image.lockFocus()
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1100, height: 480).fill()
let lines = ["OpenGlyph reads this text offline.", "Release checklist", "Ship the release on Friday.", "Freeze the branch Thursday at noon."]
for (index, line) in lines.enumerated() {
    (line as NSString).draw(at: NSPoint(x: 50, y: 370 - index * 85), withAttributes: [.font: NSFont.systemFont(ofSize: 39), .foregroundColor: NSColor.black])
}
image.unlockFocus()
write(image.cgImage(forProposedRect: nil, context: nil, hints: nil)!, name: "text.png")
let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue(Data("https://example.com/openglyph-test".utf8), forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
let context = CIContext()
write(context.createCGImage(qr, from: qr.extent)!, name: "qr.png")
print(directory.path)
