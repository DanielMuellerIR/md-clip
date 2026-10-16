import AppKit
import Foundation
import QuartzCore
import Darwin

private struct UndoStatus: Decodable {
    let version: Int
    let undo_available: Bool
    let pending_valid: Bool
}
private enum PreviewAction: Int32 { case accept = 0, cancel = 4, undo = 5 }
private enum PreviewError: Error { case invalidInput, invalidStatus }

private func stop(_ process: Process) {
    if process.isRunning { process.terminate() }
    let deadline = ProcessInfo.processInfo.systemUptime + 0.05
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}

private final class StatusClient {
    private let helper: String
    private let token: String
    private let lock = NSLock()
    private var active: Process?
    private var cancelled = false

    init(helper: String, token: String) { self.helper = helper; self.token = token }

    func cancel() {
        lock.lock()
        cancelled = true
        if let process = active { stop(process) }
        lock.unlock()
    }

    func abandonPreparation() {
        cancel()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["cancel", token]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
            stop(process)
        }
    }

    func read(_ completion: @escaping (Result<UndoStatus, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["status", token]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            var result: Result<UndoStatus, Error> = .failure(PreviewError.invalidStatus)
            do {
                lock.lock()
                if cancelled { lock.unlock(); return }
                active = process
                do { try process.run() } catch { active = nil; lock.unlock(); throw error }
                lock.unlock()
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
                if process.isRunning {
                    stop(process)
                }
                process.waitUntilExit()
                let bytes = try output.fileHandleForReading.read(upToCount: 4097) ?? Data()
                guard process.terminationStatus == 0, bytes.count <= 4096 else { throw PreviewError.invalidStatus }
                let status = try JSONDecoder().decode(UndoStatus.self, from: bytes)
                guard status.version == 1 else { throw PreviewError.invalidStatus }
                result = .success(status)
            } catch { result = .failure(error) }
            lock.lock(); active = nil; lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }
    }
}

private final class PreviewBackground: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

private let backgroundPreview: Bool = {
#if TEST
    return ProcessInfo.processInfo.environment["MD_CLIP_TEST_PREVIEW_BACKGROUND"] == "1"
#else
    return false
#endif
}()

#if TEST
private final class PreviewTextView: NSTextView {
    override func copy(_ sender: Any?) {
        // Echte Copy-Tasten dürfen im Test nur das private Pasteboard ändern.
        guard let name = ProcessInfo.processInfo.environment["MD_CLIP_TEST_PASTEBOARD"],
              name != NSPasteboard.Name.general.rawValue else { return }
        let board = NSPasteboard(name: NSPasteboard.Name(name))
        board.clearContents()
        _ = writeSelection(to: board, type: .string)
    }
}
#else
private typealias PreviewTextView = NSTextView
#endif

private final class PreviewController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    let window: NSWindow
    let textView = PreviewTextView()
    let notesView = PreviewTextView()
    let scrollView = NSScrollView()
    let statusLabel = NSTextField(wrappingLabelWithString: "Verfügbarkeit wird geprüft …")
    let acceptButton = NSButton(title: "Übernehmen", target: nil, action: nil)
    let cancelButton = NSButton(title: "Abbrechen", target: nil, action: nil)
    let undoButton = NSButton(title: "Letzte Ersetzung zurücknehmen", target: nil, action: nil)
    private let acceptMenuItem = NSMenuItem(title: "Übernehmen", action: nil, keyEquivalent: "\r")
    private let undoMenuItem = NSMenuItem(title: "Letzte Ersetzung zurücknehmen", action: nil, keyEquivalent: "z")
    private let completion: (PreviewAction) -> Void
    private var status: UndoStatus?
    private var finishing = false

    init(text: String, notes: String, background: Bool = false, completion: @escaping (PreviewAction) -> Void) {
        self.completion = completion
        let rect = NSRect(x: 0, y: 0, width: 860, height: 660)
        if background {
            window = NSPanel(contentRect: rect, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        } else {
            window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        }
        super.init()
        window.title = "Markdown-Vorschau — md-clip"
        window.contentMinSize = NSSize(width: 640, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = PreviewBackground()
        window.contentView = content
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        let title = NSTextField(labelWithString: "Markdown vor dem Ersetzen prüfen")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: "Das Clipboard wird erst nach Übernehmen ersetzt. Der Text ist schreibgeschützt; lange Zeilen werden nur zur Anzeige umgebrochen.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        let counts = NSTextField(labelWithString: "\(text.unicodeScalars.count) Zeichen · \(text.unicodeScalars.reduce(1) { $0 + ($1.value == 10 ? 1 : 0) }) Zeilen")
        counts.font = .systemFont(ofSize: 12)
        counts.textColor = .secondaryLabelColor
        for label in [title, explanation, counts] { stack.addArrangedSubview(label) }
        explanation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        configureTextView(notesView, text: notes.trimmingCharacters(in: .newlines), font: .systemFont(ofSize: 12))
        notesView.setAccessibilityLabel("Quelle und Konvertierungshinweise")
        let notesScroll = NSScrollView()
        notesScroll.borderType = .bezelBorder
        notesScroll.hasVerticalScroller = true
        notesScroll.documentView = notesView
        stack.addArrangedSubview(notesScroll)
        let noteLines = notes.trimmingCharacters(in: .newlines).components(separatedBy: "\n").count
        NSLayoutConstraint.activate([
            notesScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notesScroll.heightAnchor.constraint(equalToConstant: min(112, max(52, CGFloat(noteLines) * 17 + 16)))
        ])
        configureTextView(textView, text: text, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        textView.setAccessibilityLabel("Markdown-Ergebnis")
        textView.setAccessibilityIdentifier("md-clip-preview-content")
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        stack.addArrangedSubview(scrollView)
        scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("Vorschau-Status")
        stack.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 12
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for item in [undoButton, spacer, cancelButton, acceptButton] { footer.addArrangedSubview(item) }
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for button in [undoButton, cancelButton, acceptButton] {
            button.bezelStyle = .rounded
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
            button.target = self
            button.setAccessibilityLabel(button.title)
        }
        acceptButton.action = #selector(accept)
        acceptButton.keyEquivalent = "\r"
        acceptButton.keyEquivalentModifierMask = []
        acceptButton.setAccessibilityIdentifier("md-clip-preview-accept")
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        undoButton.action = #selector(undo)
        undoButton.toolTip = "Die vorige Ersetzung zurücknehmen: einmalig, zehn Minuten und nur bis zum nächsten Kopieren."
        acceptButton.isEnabled = false
        undoButton.isEnabled = false
        window.defaultButtonCell = acceptButton.cell as? NSButtonCell
        window.initialFirstResponder = acceptButton
        installMenu()
        window.center()
        if background { window.orderBack(nil) }
    }

    private func configureTextView(_ view: NSTextView, text: String, font: NSFont) {
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = font
        view.textColor = .labelColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 10, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        // Große Dokumente nur für die tatsächlich sichtbaren Bereiche setzen.
        view.layoutManager?.allowsNonContiguousLayout = true
        view.string = text
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(), appMenu = NSMenu()
        let quit = NSMenuItem(title: "Vorschau schließen", action: #selector(cancel), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit); appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(), edit = NSMenu(title: "Bearbeiten")
        undoMenuItem.target = self
        undoMenuItem.action = #selector(undo)
        undoMenuItem.isEnabled = false
        edit.addItem(undoMenuItem)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        acceptMenuItem.action = #selector(accept)
        acceptMenuItem.keyEquivalentModifierMask = .command
        acceptMenuItem.target = self
        acceptMenuItem.isEnabled = false
        edit.addItem(acceptMenuItem)
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    func update(_ result: Result<UndoStatus, Error>) {
        guard !finishing else { return }
        let message: String
        switch result {
        case .success(let value):
            status = value
            acceptButton.isEnabled = value.pending_valid
            acceptMenuItem.isEnabled = value.pending_valid
            undoButton.isEnabled = value.undo_available
            undoMenuItem.isEnabled = value.undo_available
            message = value.pending_valid ? "Bereit zum Übernehmen." : "Diese Vorschau ist nicht mehr gültig. Clipboard geändert oder Sicherung nicht mehr verfügbar; bitte neu starten."
            statusLabel.textColor = value.pending_valid ? .secondaryLabelColor : .systemOrange
        case .failure:
            status = nil
            acceptButton.isEnabled = false
            acceptMenuItem.isEnabled = false
            undoButton.isEnabled = false
            undoMenuItem.isEnabled = false
            message = "Statusprüfung fehlgeschlagen. Bitte Vorschau schließen."
            statusLabel.textColor = .systemRed
        }
        if statusLabel.stringValue != message {
            statusLabel.stringValue = message
            NSAccessibility.post(element: statusLabel, notification: .valueChanged)
        }
#if TEST
        if let path = ProcessInfo.processInfo.environment["MD_CLIP_TEST_PREVIEW_EVIDENCE"] {
            let responder = window.firstResponder
            let focus = responder === textView ? "content" : responder === notesView ? "notes" :
                responder === acceptButton ? "accept" : responder === cancelButton ? "cancel" :
                responder === undoButton ? "undo" : String(describing: type(of: responder))
            let selected = textView.selectedRange(), selectedNotes = notesView.selectedRange()
            let observed: [String: Any] = ["accept": acceptButton.isEnabled, "undo": undoButton.isEnabled,
                "visible": window.isVisible, "status": statusLabel.stringValue,
                "focus": focus, "key_window": window.isKeyWindow,
                "keyboard_access": NSApp.isFullKeyboardAccessEnabled,
                "observed_at": ProcessInfo.processInfo.systemUptime,
                "content": String(textView.string.prefix(4096)), "content_length": (textView.string as NSString).length,
                "selection": [selected.location, selected.length],
                "notes_selection": [selectedNotes.location, selectedNotes.length],
                "scroll_y": scrollView.documentVisibleRect.minY,
                "focus_preserved": NSWorkspace.shared.frontmostApplication?.processIdentifier == initialFrontForTest,
                "initial_front_pid": initialFrontForTest.map { Int($0) } ?? -1,
                "front_pid": NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) } ?? -1,
                "preview_pid": Int(getpid())]
            try? JSONSerialization.data(withJSONObject: observed).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        if let path = ProcessInfo.processInfo.environment["MD_CLIP_TEST_PREVIEW_ACTION"],
           let action = try? String(contentsOfFile: path, encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: path)
            switch action {
            case "accept": acceptButton.performClick(nil)
            case "cancel": cancelButton.performClick(nil)
            case "undo": undoButton.performClick(nil)
            default: break
            }
        }
#endif
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(accept) { return status?.pending_valid == true }
        if item.action == #selector(undo) { return status?.undo_available == true }
        return true
    }

    @objc private func accept() { if status?.pending_valid == true { finish(.accept) } }
    @objc private func undo() { if status?.undo_available == true { finish(.undo) } }
    @objc private func cancel() { finish(.cancel) }
    private func finish(_ action: PreviewAction) {
        guard !finishing else { return }
        finishing = true
        window.orderOut(nil)
        completion(action)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(.cancel); return false }
}

private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private let text: String, notes: String
    private let client: StatusClient
    private let parent: pid_t
    private var signalSources: [DispatchSourceSignal] = []
    private var controller: PreviewController?
    private var timer: Timer?
    private var polling = false

    init(text: String, notes: String, helper: String, token: String, parent: pid_t) {
        self.parent = parent
        self.text = text; self.notes = notes; client = StatusClient(helper: helper, token: token)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        for value in [SIGTERM, SIGINT] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .global(qos: .userInitiated))
            source.setEventHandler { [client] in client.abandonPreparation(); exit(PreviewAction.cancel.rawValue) }
            source.resume(); signalSources.append(source)
        }
        if getppid() != parent { client.abandonPreparation(); exit(PreviewAction.cancel.rawValue) }
        let view = PreviewController(text: text, notes: notes, background: backgroundPreview) { [self] action in
            timer?.invalidate(); client.cancel(); exit(action.rawValue)
        }
#if TEST
        if let name = ProcessInfo.processInfo.environment["MD_CLIP_TEST_PREVIEW_APPEARANCE"] {
            view.window.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        if ProcessInfo.processInfo.environment["MD_CLIP_TEST_PREVIEW_SMALL"] == "1" {
            view.window.setContentSize(NSSize(width: 640, height: 520))
        }
#endif
        controller = view
        if !backgroundPreview {
            view.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        poll()
        timer = Timer(timeInterval: 1, repeats: true) { [self] _ in
            if getppid() != parent { client.abandonPreparation(); exit(PreviewAction.cancel.rawValue) }
            poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    private func poll() {
        guard !polling else { return }
        polling = true
        client.read { [weak self] result in
            guard let self else { return }
            polling = false
            controller?.update(result)
        }
    }
}

private func inputs() throws -> (String, String, String, String) {
    let args = CommandLine.arguments
    guard args.count == 5, !args[4].isEmpty, FileManager.default.isExecutableFile(atPath: args[3]) else { throw PreviewError.invalidInput }
    let bodyURL = URL(fileURLWithPath: args[1]), notesURL = URL(fileURLWithPath: args[2])
    let bodySize = try bodyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    let notesSize = try notesURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard bodySize > 0, bodySize <= 64 * 1024 * 1024, notesSize <= 16 * 1024,
          let text = String(data: try Data(contentsOf: bodyURL), encoding: .utf8),
          let notes = String(data: try Data(contentsOf: notesURL), encoding: .utf8) else { throw PreviewError.invalidInput }
    return (text, notes, args[3], args[4])
}

#if TEST
private final class PreviewSelfTest: NSObject, NSApplicationDelegate {
    let directory: URL
    let front: pid_t?
    init(directory: URL, front: pid_t?) { self.directory = directory; self.front = front }
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
        try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        for button in [controller.acceptButton, controller.cancelButton, controller.undoButton] {
            let rect = button.convert(button.bounds, to: view)
            precondition(rect.width >= 60 && rect.height >= 28 && view.bounds.contains(rect), "Button außerhalb der Ansicht: \(name), \(rect)")
        }
        precondition(controller.scrollView.frame.height >= 120, "Textbereich zu klein")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == front, "Hintergrundtest hat Fokus übernommen")
    }
    private func run() {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = "# Vorschau mit Unicode ☀\n\n- Ein Listenpunkt\n- Noch ein Punkt\n\n```sh\nprintf '%s' \\\n  '\\# unverändert'\n```\n\n[Beispiellink](https://example.invalid/)\n"
        let notes = "Quelle: HTML\nZielformat: gfm\n\nmd-clip: Vereinfachung: 2 Tabellenzellen; Blockgrenzen und Umbrüche zusammengeführt.\nmd-clip: Vereinfachung: 1 Bild auf Alternativtext reduziert.\nWeitere Hinweise bleiben vollständig scrollbar."
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var result: PreviewAction?
            let view = PreviewController(text: text, notes: notes, background: true) { result = $0 }
            view.window.appearance = NSAppearance(named: appearance)
            view.window.setContentSize(NSSize(width: 860, height: 660))
            precondition(!view.acceptButton.isEnabled && !view.undoButton.isEnabled)
            view.update(.success(UndoStatus(version: 1, undo_available: true, pending_valid: true)))
            snapshot(view, name: appearance == .aqua ? "ready-light" : "ready-dark")
            precondition(view.acceptButton.isEnabled && view.undoButton.isEnabled)
            precondition(Data(view.textView.string.utf8) == Data(text.utf8) && !view.textView.isEditable && view.textView.isSelectable)
            view.update(.success(UndoStatus(version: 1, undo_available: false, pending_valid: false)))
            view.window.setContentSize(NSSize(width: 640, height: 520))
            snapshot(view, name: appearance == .aqua ? "invalid-small-light" : "invalid-small-dark")
            view.acceptButton.performClick(nil)
            precondition(result == nil && !view.acceptButton.isEnabled && !view.undoButton.isEnabled)
            view.update(.failure(PreviewError.invalidStatus))
            precondition(!view.acceptButton.isEnabled && view.statusLabel.stringValue.contains("fehlgeschlagen"))
            view.window.performClose(nil)
            precondition(result == .cancel && !view.window.isVisible)
        }
        for action in [PreviewAction.accept, .cancel, .undo] {
            var result: PreviewAction?
            let view = PreviewController(text: text, notes: "Quelle: HTML", background: true) { result = $0 }
            view.update(.success(UndoStatus(version: 1, undo_available: true, pending_valid: true)))
            view.window.contentView!.layoutSubtreeIfNeeded()
            let characters = action == .accept ? "\r" : action == .cancel ? "q" : "z"
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: 0,
                windowNumber: view.window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: action == .accept ? 36 : action == .cancel ? 12 : 6)!
            NSApp.mainMenu!.update()
            _ = NSApp.mainMenu!.performKeyEquivalent(with: event)
            precondition(result == action, "Tastaturaktion fehlt: \(action)")
        }
        let large = (0..<18000).map { "Zeile \($0): langer Inhalt mit Umlauten und Emoji ☀ — Backslash \\# bleibt erhalten." }.joined(separator: "\n") + "\nENDMARKER"
        let view = PreviewController(text: large, notes: "Quelle: Klartext\nZielformat: unverändert", background: true) { _ in }
        view.update(.success(UndoStatus(version: 1, undo_available: false, pending_valid: true)))
        view.window.contentView!.layoutSubtreeIfNeeded()
        let before = view.scrollView.documentVisibleRect.minY
        view.textView.scrollRangeToVisible(NSRange(location: (large as NSString).length - 1, length: 1))
        view.window.displayIfNeeded()
        let visible = view.textView.visibleRect.offsetBy(dx: -view.textView.textContainerOrigin.x, dy: -view.textView.textContainerOrigin.y)
        let glyphs = view.textView.layoutManager!.glyphRange(forBoundingRect: visible, in: view.textView.textContainer!)
        let chars = view.textView.layoutManager!.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let seen = (view.textView.string as NSString).substring(with: chars)
        snapshot(view, name: "large-end")
        precondition(view.scrollView.documentVisibleRect.minY > before && seen.contains("ENDMARKER"), "Ende nicht tatsächlich sichtbar")
        precondition(Data(view.textView.string.utf8) == Data(large.utf8), "Vorschau hat Inhalt verändert")
        view.window.orderOut(nil)
        let evidence: [String: Any] = ["characters": large.unicodeScalars.count, "scrolled": true,
                                      "end_marker_visible": true, "focus_preserved": true,
                                      "keyboard_actions": ["command-return", "command-q", "command-z"], "appearance_modes": 2]
        try! JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"))
        print("OK: native Hintergrundansicht, Zustände, Tastatur, Hell/Dunkel, große Texte und tatsächliches Scrollen")
        exit(0)
    }
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--self-test" {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let testApp = NSApplication.shared
    testApp.setActivationPolicy(.accessory)
    let testDelegate = PreviewSelfTest(directory: URL(fileURLWithPath: CommandLine.arguments[2]), front: front)
    testApp.delegate = testDelegate
    withExtendedLifetime(testDelegate) { testApp.run() }
    exit(0)
}
if CommandLine.arguments.count == 4 && ["--test-status", "--test-cancel-status"].contains(CommandLine.arguments[1]) {
    let client = StatusClient(helper: CommandLine.arguments[2], token: CommandLine.arguments[3])
    client.read { result in
        if CommandLine.arguments[1] == "--test-cancel-status" { return }
        switch result {
        case .success(let status):
            print("{\"version\":1,\"undo_available\":\(status.undo_available),\"pending_valid\":\(status.pending_valid)}")
            exit(0)
        case .failure: print("status-error"); exit(2)
        }
    }
    if CommandLine.arguments[1] == "--test-cancel-status" {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { client.cancel(); exit(0) }
    }
    dispatchMain()
}
#endif

private let originalParent = getppid()
let values: (String, String, String, String)
do { values = try inputs() }
catch {
    FileHandle.standardError.write(Data("Vorschau benötigt lesbaren UTF-8-Inhalt bis 64 MiB, Hinweise und einen Undo-Helfer.\n".utf8))
    exit(64)
}
#if TEST
private let initialFrontForTest = NSWorkspace.shared.frontmostApplication?.processIdentifier
#endif
let application = NSApplication.shared
application.setActivationPolicy(backgroundPreview ? .accessory : .regular)
private let delegate = PreviewDelegate(text: values.0, notes: values.1, helper: values.2, token: values.3, parent: originalParent)
application.delegate = delegate
application.run()
