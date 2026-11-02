import AppKit

// `--make-default` registers the app as the handler for every image type and exits.
if CommandLine.arguments.contains("--make-default") {
    let failures = DefaultViewer.makeDefault()
    if failures.isEmpty {
        print("Set as default viewer for \(DefaultViewer.imageTypes.count) image types.")
    }
    failures.forEach { print("  failed: \($0)") }
    exit(failures.isEmpty ? 0 : 1)
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
