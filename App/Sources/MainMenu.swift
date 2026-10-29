import AppKit

/// The menu bar, built in code (no nib to load at launch).
@MainActor
enum MainMenu {
    typealias Doc = DocumentWindowController

    static func build() -> NSMenu {
        let main = NSMenu()

        let app = submenu(in: main, title: "PiDF")
        app.addItem(item("About PiDF", #selector(AppDelegate.showAbout(_:))))
        app.addItem(.separator())
        app.addItem(item("Hide PiDF", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit PiDF", #selector(NSApplication.terminate(_:)), "q"))

        let file = submenu(in: main, title: "File")
        file.addItem(item("Open…", #selector(AppDelegate.showOpenPanel(_:)), "o"))
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(item("Save", #selector(Doc.saveDocument(_:)), "s"))
        file.addItem(.separator())
        file.addItem(item("Show in Finder", #selector(Doc.showInFinder(_:)), "r", [.command, .shift]))
        file.addItem(item("Open in Preview", #selector(Doc.openInPreview(_:)), "p", [.command, .shift]))

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("Highlight", #selector(Doc.toggleHighlight(_:)), "h", .control))
        edit.addItem(item("Add Note…", #selector(Doc.addNote(_:)), "n", .control))
        edit.addItem(item("Delete Page", #selector(Doc.deletePage(_:)), "d", .control))
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(item("Find…", #selector(Doc.showFind(_:)), "f"))
        find.addItem(item("Find Next", #selector(Doc.findNext(_:)), "g"))
        find.addItem(item("Find Previous", #selector(Doc.findPrevious(_:)), "g", [.command, .shift]))
        let findHolder = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findHolder.submenu = find
        edit.addItem(findHolder)

        let view = submenu(in: main, title: "View")
        view.addItem(item("Zoom to Fit", #selector(Doc.zoomToFit(_:)), "9"))
        view.addItem(item("Actual Size", #selector(Doc.actualSize(_:)), "0"))
        view.addItem(item("Zoom In", #selector(Doc.zoomIn(_:)), "+"))
        view.addItem(item("Zoom Out", #selector(Doc.zoomOut(_:)), "-"))
        view.addItem(.separator())
        view.addItem(item("Two Pages", #selector(Doc.toggleTwoPages(_:)), "2", [.command, .option]))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        let go = submenu(in: main, title: "Go")
        go.addItem(item("Previous Page", #selector(Doc.goToPreviousPage(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option]))
        go.addItem(item("Next Page", #selector(Doc.goToNextPage(_:)), arrow(NSRightArrowFunctionKey), [.command, .option]))
        go.addItem(item("First Page", #selector(Doc.goToFirstPage(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]))
        go.addItem(item("Last Page", #selector(Doc.goToLastPage(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]))
        go.addItem(.separator())
        go.addItem(item("Back", #selector(Doc.goBack(_:)), "["))
        go.addItem(item("Forward", #selector(Doc.goForward(_:)), "]"))
        go.addItem(.separator())
        go.addItem(item("Go to Page…", #selector(Doc.showGoToPage(_:)), "g", [.command, .option]))

        // AppKit adds the tab commands (Show Tab Bar, Merge All Windows…) here.
        let window = submenu(in: main, title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt16(key))!))
    }
}
