// Test fixture preparation. Writes the supplied image to the macOS clipboard.
import AppKit
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = NSImage(contentsOf: url) else { fatalError("Cannot read fixture image") }
NSPasteboard.general.clearContents()
guard NSPasteboard.general.writeObjects([image]) else { fatalError("Cannot write test image to clipboard") }
