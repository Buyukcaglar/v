import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var viewer: ViewerWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // AppKit asks for an untitled document only when the app is launched or reopened (from the
    // Dock or Launchpad) without files to open: ask for some.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        openDocument(nil)
        return true
    }

    private func open(_ urls: [URL]) {
        let viewer = self.viewer ?? ViewerWindowController(opening: urls)
        if self.viewer == nil {
            viewer.onClose = { [weak self] in self?.viewer = nil }
            self.viewer = viewer
        }
        NSApp.activate(ignoringOtherApps: true)
        viewer.show(urls: urls)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageLoader.decodableTypes + [.folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose photos or a folder to view"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            open(panel.urls)
        } else if viewer == nil {
            NSApp.terminate(nil)
        }
    }

    @objc func makeDefaultViewer(_ sender: Any?) {
        let failures = DefaultViewer.makeDefault()
        let alert = NSAlert()
        if failures.isEmpty {
            alert.messageText = "V is now your default image viewer."
        } else {
            alert.messageText = "Some image types couldn’t be assigned."
            alert.informativeText = failures.prefix(8).joined(separator: "\n")
        }
        alert.runModal()
    }
}

enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        let appName = "V"

        main.addItem(submenu("", [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Make Default Image Viewer", #selector(AppDelegate.makeDefaultViewer(_:))),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            item("Open…", #selector(AppDelegate.openDocument(_:)), "o"),
            item("Close", #selector(ViewerWindowController.closeViewer(_:)), "w"),
            .separator(),
            item("Show in Finder", #selector(ViewerWindowController.revealInFinder(_:)), "r", [.command, .shift]),
            item("Move to Trash", #selector(ViewerWindowController.moveToTrash(_:)), "\u{8}"),
        ]))
        main.addItem(submenu("Edit", [
            item("Copy", #selector(ViewerWindowController.copy(_:)), "c"),
        ]))
        main.addItem(submenu("View", [
            item("Zoom In", #selector(ViewerWindowController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(ViewerWindowController.zoomOut(_:)), "-"),
            item("Actual Size", #selector(ViewerWindowController.actualSize(_:)), "0"),
            item("Zoom to Fit", #selector(ViewerWindowController.zoomToFit(_:)), "9"),
            .separator(),
            item("Start Slideshow", #selector(ViewerWindowController.toggleSlideshow(_:)), "f", [.command, .shift]),
        ]))
        main.addItem(submenu("Image", [
            item("Rotate Left", #selector(ViewerWindowController.rotateLeft(_:)), "l"),
            item("Rotate Right", #selector(ViewerWindowController.rotateRight(_:)), "r"),
        ]))
        main.addItem(submenu("Go", [
            item("Next Photo", #selector(ViewerWindowController.nextImage(_:)), "]"),
            item("Previous Photo", #selector(ViewerWindowController.previousImage(_:)), "["),
            item("First Photo", #selector(ViewerWindowController.firstImage(_:)), "[", [.command, .shift]),
            item("Last Photo", #selector(ViewerWindowController.lastImage(_:)), "]", [.command, .shift]),
        ]))
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        return item
    }
}

enum DefaultViewer {
    static var imageTypes: [UTType] { ImageLoader.decodableTypes }

    /// Makes this app the default for every image type in one step. Asking Launch Services
    /// type by type (LSSetDefaultRoleHandlerForContentType) makes current macOS show a
    /// confirmation dialog for each of the ~60 types, so write the handler table directly
    /// and restart lsd, which caches it, so the change applies at once.
    /// Returns a description of anything that went wrong.
    @discardableResult
    static func makeDefault() -> [String] {
        let bundleID = Bundle.main.bundleIdentifier!.lowercased()
        let domain = "com.apple.LaunchServices/com.apple.launchservices.secure" as CFString
        let key = "LSHandlers" as CFString
        let types = Set(imageTypes.map(\.identifier))

        var handlers = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [[String: Any]] ?? []
        handlers.removeAll { types.contains($0["LSHandlerContentType"] as? String ?? "") }
        for type in types.sorted() {
            handlers.append([
                "LSHandlerContentType": type,
                "LSHandlerRoleAll": bundleID,
                "LSHandlerRoleViewer": bundleID,
                "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-", "LSHandlerRoleViewer": "-"],
            ])
        }
        CFPreferencesSetValue(key, handlers as CFArray, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return ["Couldn’t save the Launch Services preferences."]
        }
        // lsd relaunches on demand and rereads the table.
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        restart.arguments = ["lsd"]
        try? restart.run()
        restart.waitUntilExit()
        return []
    }
}
