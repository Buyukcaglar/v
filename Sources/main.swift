import AppKit

// `--make-default` registers the app as the handler for every image type and exits.
if CommandLine.arguments.contains("--make-default") {
    let failures = DefaultViewer.makeDefault()
    print("Set as default viewer for \(DefaultViewer.imageTypes.count - failures.count) image types.")
    failures.forEach { print("  failed: \($0)") }
    exit(failures.isEmpty ? 0 : 1)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
