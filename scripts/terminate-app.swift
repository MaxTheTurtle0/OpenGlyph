import AppKit

let bundleIdentifier = "app.openglyph.mac"
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
for application in applications where !application.isTerminated {
    if !application.terminate() {
        fputs("OpenGlyph declined to quit. Quit it from its menu before installing.\n", stderr)
        exit(1)
    }
}
let deadline = Date().addingTimeInterval(10)
while applications.contains(where: { !$0.isTerminated }), Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
if applications.contains(where: { !$0.isTerminated }) {
    fputs("OpenGlyph is still running. Quit it from its menu before installing.\n", stderr)
    exit(1)
}
