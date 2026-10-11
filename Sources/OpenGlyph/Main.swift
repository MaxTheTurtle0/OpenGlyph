import AppKit
import OpenGlyphCore
import SwiftUI

@main
struct OpenGlyphMain {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--ocr"), !arguments.indices.contains((arguments.firstIndex(of: "--ocr") ?? 0) + 1) {
            FileHandle.standardError.write(Data("OpenGlyph: --ocr requires a file path\n".utf8))
            exit(2)
        }
        if let index = arguments.firstIndex(of: "--ocr"), arguments.indices.contains(index + 1) {
            do {
                let languageIndex = arguments.firstIndex(of: "--language")
                let language = languageIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
                let options = RecognitionOptions(mode: arguments.contains("--fast") ? .fast : .accurate, language: language, keepLineBreaks: !arguments.contains("--no-line-breaks"))
                let result = try OCRService.recognize(fileURL: URL(fileURLWithPath: arguments[index + 1]), options: options)
                if arguments.contains("--json") {
                    let data = try JSONSerialization.data(withJSONObject: ["text": result.text, "kind": result.kind.rawValue], options: [.sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                } else { print(result.text) }
                if arguments.contains("--copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.text, forType: .string)
                }
            } catch {
                FileHandle.standardError.write(Data("OpenGlyph: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        if let index = arguments.firstIndex(of: "--render-previews"), arguments.indices.contains(index + 1) {
            do { try PreviewRenderer.render(to: URL(fileURLWithPath: arguments[index + 1], isDirectory: true), dark: arguments.contains("--dark")) }
            catch { FileHandle.standardError.write(Data("OpenGlyph: \(error.localizedDescription)\n".utf8)); exit(1) }
            return
        }
        if arguments.contains("--diagnostics") {
            let values: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0", "screenCapturePermission": CaptureCoordinator.hasPermission, "languages": OCRService.supportedLanguages(mode: .accurate), "bundlePath": Bundle.main.bundlePath]
            if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
            return
        }
        if arguments.contains("--help") {
            print("OpenGlyph\n  --ocr FILE [--fast] [--language CODE] [--no-line-breaks] [--json] [--copy]\n  --diagnostics\n  Without arguments, opens the menu bar app.")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = AppController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}
