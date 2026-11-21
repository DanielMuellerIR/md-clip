import AppKit
import Foundation
import QuartzCore

@MainActor
private func configure(_ window: NSWindow) {
    if let name = ProcessInfo.processInfo.environment["MD_CLIP_TEST_PREVIEW_APPEARANCE"] {
        window.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
    }
    if ProcessInfo.processInfo.environment["MD_CLIP_TEST_PREVIEW_SMALL"] == "1" {
        window.setContentSize(NSSize(width: 640, height: 520))
    }
}

@MainActor
private func copyToTestPasteboard(_ view: NSTextView) {
    // Echte Copy-Tasten dürfen im Test nur das private Pasteboard ändern.
    guard let name = ProcessInfo.processInfo.environment["MD_CLIP_TEST_PASTEBOARD"],
        name != NSPasteboard.Name.general.rawValue
    else { return }
    let board = NSPasteboard(name: NSPasteboard.Name(name))
    let types = view.writablePasteboardTypes
    board.declareTypes(types, owner: nil)
    _ = view.writeSelection(to: board, types: types)
}

private struct PreviewInput: Decodable {
    let id: Int
    var focus: String?
    var code: UInt16?
    var characters: String?
    var command: Bool?
    var shift: Bool?
}

@MainActor
private func deliverInput(_ input: PreviewInput, to view: PreviewController) {
    let window = view.window
    if let focus = input.focus {
        switch focus {
        case "content": window.makeFirstResponder(view.textView)
        case "notes": window.makeFirstResponder(view.notesView)
        default: break
        }
        return
    }
    guard let code = input.code, let characters = input.characters else { return }
    var modifiers = NSEvent.ModifierFlags()
    if input.command == true { modifiers.insert(.command) }
    if input.shift == true { modifiers.insert(.shift) }
    guard let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code)
    else { return }
    // Anders als globale Tastaturevents bleibt dieser AppKit-Event in der Test-App.
    if !window.performKeyEquivalent(with: event)
        && !(input.command == true && NSApp.mainMenu?.performKeyEquivalent(with: event) == true)
    {
        window.sendEvent(event)
    }
}

@MainActor
private var lastInput = 0

@MainActor
private func observe(_ view: PreviewController, initialFront front: pid_t?) {
    if let path = ProcessInfo.processInfo.environment["MD_CLIP_TEST_PREVIEW_INPUT"],
        let data = FileManager.default.contents(atPath: path)
    {
        try? FileManager.default.removeItem(atPath: path)
        if let input = try? JSONDecoder().decode(PreviewInput.self, from: data) {
            deliverInput(input, to: view)
            lastInput = input.id
        }
    }
    if let path = ProcessInfo.processInfo.environment["MD_CLIP_TEST_PREVIEW_EVIDENCE"] {
        let responder = view.window.firstResponder
        let controls: [(NSResponder, String)] = [
            (view.textView, "content"), (view.notesView, "notes"), (view.acceptButton, "accept"),
            (view.cancelButton, "cancel"), (view.undoButton, "undo"),
        ]
        let focus =
            controls.first { $0.0 === responder }?.1
            ?? responder.map { String(describing: type(of: $0)) } ?? "none"
        let selected = view.textView.selectedRange()
        let selectedNotes = view.notesView.selectedRange()
        let observed: [String: Any] = [
            "accept": view.acceptButton.isEnabled, "undo": view.undoButton.isEnabled,
            "visible": view.window.isVisible, "status": view.statusLabel.stringValue,
            "focus": focus, "key_window": view.window.isKeyWindow,
            "keyboard_access": NSApp.isFullKeyboardAccessEnabled,
            "observed_at": ProcessInfo.processInfo.systemUptime,
            "last_input": lastInput,
            "content": String(view.textView.string.prefix(4096)),
            "content_length": (view.textView.string as NSString).length,
            "selection": [selected.location, selected.length],
            "notes_selection": [selectedNotes.location, selectedNotes.length],
            "scroll_y": view.scrollView.documentVisibleRect.minY,
            "focus_preserved": NSWorkspace.shared.frontmostApplication?.processIdentifier == front,
            "initial_front_pid": front.map { Int($0) } ?? -1,
            "front_pid": NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) } ?? -1,
            "preview_pid": Int(getpid()),
        ]
        try? JSONSerialization.data(withJSONObject: observed).write(
            to: URL(fileURLWithPath: path), options: .atomic)
    }
    if let path = ProcessInfo.processInfo.environment["MD_CLIP_TEST_PREVIEW_ACTION"],
        let action = try? String(contentsOfFile: path, encoding: .utf8)
    {
        try? FileManager.default.removeItem(atPath: path)
        switch action {
        case "accept": view.acceptButton.performClick(nil)
        case "cancel": view.cancelButton.performClick(nil)
        case "undo": view.undoButton.performClick(nil)
        default: break
        }
    }

}

@MainActor
private final class PreviewSelfTest: NSObject, NSApplicationDelegate {
    let directory: URL
    let front: pid_t?
    init(directory: URL, front: pid_t?) {
        self.directory = directory
        self.front = front
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.run() }
    }
    private func snapshot(_ controller: PreviewController, name: String) {
        controller.window.contentView!.layoutSubtreeIfNeeded()
        controller.window.displayIfNeeded()
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        CATransaction.flush()
        let view = controller.window.contentView!
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(
            to: directory.appendingPathComponent(name + ".png"))
        for button in [controller.acceptButton, controller.cancelButton, controller.undoButton] {
            let rect = button.convert(button.bounds, to: view)
            precondition(
                rect.width >= 60 && rect.height >= 28 && view.bounds.contains(rect),
                "Button außerhalb der Ansicht: \(name), \(rect)")
        }
        precondition(controller.scrollView.frame.height >= 120, "Textbereich zu klein")
        precondition(
            NSWorkspace.shared.frontmostApplication?.processIdentifier == front,
            "Hintergrundtest hat Fokus übernommen")
    }
    private func run() {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text =
            "# Vorschau mit Unicode ☀\n\n- Ein Listenpunkt\n- Noch ein Punkt\n\n```sh\nprintf '%s' \\\n  '\\# unverändert'\n```\n\n[Beispiellink](https://example.invalid/)\n"
        let notes =
            "Quelle: HTML\nZielformat: gfm\n\nmd-clip: Vereinfachung: 2 Tabellenzellen; Blockgrenzen und Umbrüche zusammengeführt.\nmd-clip: Vereinfachung: 1 Bild auf Alternativtext reduziert.\nWeitere Hinweise bleiben vollständig scrollbar."
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var result: PreviewAction?
            let view = PreviewController(text: text, notes: notes, background: true) { result = $0 }
            view.window.appearance = NSAppearance(named: appearance)
            view.window.setContentSize(NSSize(width: 860, height: 660))
            precondition(!view.acceptButton.isEnabled && !view.undoButton.isEnabled)
            view.update(.success(UndoStatus(version: 1, undo_available: true, pending_valid: true)))
            snapshot(view, name: appearance == .aqua ? "ready-light" : "ready-dark")
            precondition(view.acceptButton.isEnabled && view.undoButton.isEnabled)
            precondition(
                Data(view.textView.string.utf8) == Data(text.utf8) && !view.textView.isEditable
                    && view.textView.isSelectable)
            view.update(.success(UndoStatus(version: 1, undo_available: false, pending_valid: false)))
            view.window.setContentSize(NSSize(width: 640, height: 520))
            snapshot(view, name: appearance == .aqua ? "invalid-small-light" : "invalid-small-dark")
            view.acceptButton.performClick(nil)
            precondition(result == nil && !view.acceptButton.isEnabled && !view.undoButton.isEnabled)
            view.update(.failure(PreviewError.invalidStatus))
            precondition(
                !view.acceptButton.isEnabled && view.statusLabel.stringValue.contains("fehlgeschlagen"))
            view.window.performClose(nil)
            precondition(result == .cancel && !view.window.isVisible)
        }
        for action in [PreviewAction.accept, .cancel, .undo] {
            var result: PreviewAction?
            let view = PreviewController(text: text, notes: "Quelle: HTML", background: true) {
                result = $0
            }
            view.update(.success(UndoStatus(version: 1, undo_available: true, pending_valid: true)))
            view.window.contentView!.layoutSubtreeIfNeeded()
            let characters = action == .accept ? "\r" : action == .cancel ? "q" : "z"
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: 0,
                windowNumber: view.window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: action == .accept ? 36 : action == .cancel ? 12 : 6)!
            NSApp.mainMenu!.update()
            _ = NSApp.mainMenu!.performKeyEquivalent(with: event)
            precondition(result == action, "Tastaturaktion fehlt: \(action)")
        }
        let large =
            (0..<18000).map {
                "Zeile \($0): langer Inhalt mit Umlauten und Emoji ☀ — Backslash \\# bleibt erhalten."
            }.joined(separator: "\n") + "\nENDMARKER"
        let view = PreviewController(
            text: large, notes: "Quelle: Klartext\nZielformat: unverändert", background: true
        ) { _ in }
        view.update(.success(UndoStatus(version: 1, undo_available: false, pending_valid: true)))
        view.window.contentView!.layoutSubtreeIfNeeded()
        let before = view.scrollView.documentVisibleRect.minY
        view.textView.scrollRangeToVisible(NSRange(location: (large as NSString).length - 1, length: 1))
        view.window.displayIfNeeded()
        let visible = view.textView.visibleRect.offsetBy(
            dx: -view.textView.textContainerOrigin.x, dy: -view.textView.textContainerOrigin.y)
        let glyphs = view.textView.layoutManager!.glyphRange(
            forBoundingRect: visible, in: view.textView.textContainer!)
        let chars = view.textView.layoutManager!.characterRange(
            forGlyphRange: glyphs, actualGlyphRange: nil)
        let seen = (view.textView.string as NSString).substring(with: chars)
        snapshot(view, name: "large-end")
        precondition(
            view.scrollView.documentVisibleRect.minY > before && seen.contains("ENDMARKER"),
            "Ende nicht tatsächlich sichtbar")
        precondition(Data(view.textView.string.utf8) == Data(large.utf8), "Vorschau hat Inhalt verändert")
        view.window.orderOut(nil)
        let evidence: [String: Any] = [
            "characters": large.unicodeScalars.count, "scrolled": true,
            "end_marker_visible": true, "focus_preserved": true,
            "keyboard_actions": ["command-return", "command-q", "command-z"], "appearance_modes": 2,
        ]
        try! JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(
            to: directory.appendingPathComponent("result.json"))
        print(
            "OK: native Hintergrundansicht, Zustände, Tastatur, Hell/Dunkel, große Texte und tatsächliches Scrollen"
        )
        exit(0)
    }
}

@main
struct PreviewTestMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if arguments.count == 3 && arguments[1] == "--self-test" {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let delegate = PreviewSelfTest(directory: URL(fileURLWithPath: arguments[2]), front: front)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
            exit(0)
        }
        if arguments.count == 4 && ["--test-status", "--test-cancel-status"].contains(arguments[1]) {
            let client = StatusClient(helper: arguments[2], token: arguments[3])
            let cancel = arguments[1] == "--test-cancel-status"
            client.read { result in
                if cancel { return }
                switch result {
                case .success(let status):
                    print(
                        "{\"version\":1,\"undo_available\":\(status.undo_available),\"pending_valid\":\(status.pending_valid)}"
                    )
                    exit(0)
                case .failure:
                    print("status-error")
                    exit(2)
                }
            }
            if cancel {
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    await client.cancel()
                    exit(0)
                }
            }
            dispatchMain()
        }
        PreviewProgram.run(
            configuration: PreviewConfiguration(
                background: ProcessInfo.processInfo.environment["MD_CLIP_TEST_PREVIEW_BACKGROUND"] == "1",
                configureWindow: configure,
                copySelection: copyToTestPasteboard,
                observe: { observe($0, initialFront: front) }
            ))
    }
}
