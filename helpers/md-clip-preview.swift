import AppKit
import Darwin
import Foundation

struct UndoStatus: Decodable {
    let version: Int
    let undo_available: Bool
    let pending_valid: Bool
}
enum PreviewAction: Int32 {
    case accept = 0
    case cancel = 4
    case undo = 5
}
enum PreviewError: Error { case invalidInput, invalidStatus }

@MainActor
final class StatusClient {
    private let helper: String
    private let token: String
    private var active: Task<UndoStatus, Error>?

    init(helper: String, token: String) {
        self.helper = helper
        self.token = token
    }

    func cancel() async {
        guard let active else { return }
        active.cancel()
        _ = await active.result
    }

    func abandonPreparation() async {
        await Task.detached(priority: .utility) { [helper, token] in
            let process = Self.process(helper: helper, arguments: ["cancel", token])
            process.standardOutput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            defer { Self.stop(process) }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                usleep(10_000)
            }
        }.value
    }

    func read(_ completion: @escaping @MainActor (Result<UndoStatus, Error>) -> Void) {
        guard active == nil else { return }
        let task = Task.detached(priority: .utility) { [helper, token] in
            try Self.readStatus(helper: helper, token: token)
        }
        active = task
        Task {
            let result = await task.result
            active = nil
            if !task.isCancelled { completion(result) }
        }
    }

    nonisolated private static func process(helper: String, arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    nonisolated private static func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    nonisolated private static func readStatus(helper: String, token: String) throws -> UndoStatus {
        try Task.checkCancellation()
        let maximumBytes = 4096
        let process = process(helper: helper, arguments: ["status", token])
        let output = Pipe()
        process.standardOutput = output
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw PreviewError.invalidStatus }
        try process.run()
        defer { stop(process) }

        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: maximumBytes + 1)
        var endOfOutput = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if !endOfOutput {
                let count = Darwin.read(fd, &buffer, buffer.count)
                switch count {
                case 0:
                    endOfOutput = true
                case 1...:
                    guard count <= maximumBytes - bytes.count else { throw PreviewError.invalidStatus }
                    bytes.append(contentsOf: buffer.prefix(count))
                default:
                    guard errno == EAGAIN || errno == EINTR else { throw PreviewError.invalidStatus }
                }
            }
            if endOfOutput && !process.isRunning {
                guard process.terminationStatus == 0 else { throw PreviewError.invalidStatus }
                let status = try JSONDecoder().decode(UndoStatus.self, from: bytes)
                guard status.version == 1 else { throw PreviewError.invalidStatus }
                return status
            }
            usleep(10_000)
        }
        throw PreviewError.invalidStatus
    }
}

@MainActor
struct PreviewConfiguration {
    var background = false
    var configureWindow: ((NSWindow) -> Void)?
    var copySelection: ((NSTextView) -> Void)?
    var observe: ((PreviewController) -> Void)?
}

private final class PreviewBackground: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

final class PreviewTextView: NSTextView {
    var copySelection: ((NSTextView) -> Void)?
    var confirm: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Schreibgeschützte Textansichten verbrauchen Return sonst vor dem Standardbutton.
        if event.keyCode == 36 || event.keyCode == 76,
            event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
        {
            confirm?()
            return
        }
        super.keyDown(with: event)
    }

    override func copy(_ sender: Any?) {
        if let copySelection {
            copySelection(self)
        } else {
            super.copy(sender)
        }
    }
}

@MainActor
final class PreviewController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    let window: NSWindow
    let textView = PreviewTextView()
    let notesView = PreviewTextView()
    let scrollView = NSScrollView()
    let statusLabel = NSTextField(wrappingLabelWithString: "Verfügbarkeit wird geprüft …")
    let acceptButton = NSButton(title: "Übernehmen", target: nil, action: nil)
    let cancelButton = NSButton(title: "Abbrechen", target: nil, action: nil)
    let undoButton = NSButton(title: "Letzte Ersetzung zurücknehmen", target: nil, action: nil)
    private let acceptMenuItem = NSMenuItem(title: "Übernehmen", action: nil, keyEquivalent: "\r")
    private let undoMenuItem = NSMenuItem(
        title: "Letzte Ersetzung zurücknehmen", action: nil, keyEquivalent: "z")
    private let completion: (PreviewAction) -> Void
    private var status: UndoStatus?
    private var finishing = false

    init(
        text: String, notes: String, background: Bool = false, completion: @escaping (PreviewAction) -> Void
    ) {
        self.completion = completion
        let rect = NSRect(x: 0, y: 0, width: 860, height: 660)
        if background {
            window = NSPanel(
                contentRect: rect, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                backing: .buffered, defer: false)
        } else {
            window = NSWindow(
                contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
        }
        super.init()
        window.title = "Markdown-Vorschau — md-clip"
        window.contentMinSize = NSSize(width: 640, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let stack = makeContentStack()
        addHeader(to: stack, text: text)
        addNotes(to: stack, notes: notes.trimmingCharacters(in: .newlines))
        addMarkdown(to: stack, text: text)
        addStatus(to: stack)
        addActions(to: stack)
        configureKeyboardNavigation()
        installMenu()
        window.center()
        if background { window.orderBack(nil) }
    }

    private func makeContentStack() -> NSStackView {
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
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        return stack
    }

    private func addHeader(to stack: NSStackView, text: String) {
        let title = NSTextField(labelWithString: "Markdown vor dem Ersetzen prüfen")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let explanation = NSTextField(
            wrappingLabelWithString:
                "Das Clipboard wird erst nach Übernehmen ersetzt. Der Text ist schreibgeschützt; lange Zeilen werden nur zur Anzeige umgebrochen."
        )
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        let counts = NSTextField(
            labelWithString:
                "\(text.unicodeScalars.count) Zeichen · \(text.unicodeScalars.reduce(1) { $0 + ($1.value == 10 ? 1 : 0) }) Zeilen"
        )
        counts.font = .systemFont(ofSize: 12)
        counts.textColor = .secondaryLabelColor
        for label in [title, explanation, counts] { stack.addArrangedSubview(label) }
        explanation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addNotes(to stack: NSStackView, notes: String) {
        configureTextView(notesView, text: notes, font: .systemFont(ofSize: 12))
        notesView.setAccessibilityLabel("Quelle und Konvertierungshinweise")
        let notesScroll = NSScrollView()
        notesScroll.borderType = .bezelBorder
        notesScroll.hasVerticalScroller = true
        notesScroll.documentView = notesView
        stack.addArrangedSubview(notesScroll)
        let noteLines = notes.components(separatedBy: "\n").count
        NSLayoutConstraint.activate([
            notesScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notesScroll.heightAnchor.constraint(
                equalToConstant: min(112, max(52, CGFloat(noteLines) * 17 + 16))),
        ])
    }

    private func addMarkdown(to stack: NSStackView, text: String) {
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
    }

    private func addStatus(to stack: NSStackView) {
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("Vorschau-Status")
        stack.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addActions(to stack: NSStackView) {
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
        undoButton.toolTip =
            "Die vorige Ersetzung zurücknehmen: einmalig, zehn Minuten und nur bis zum nächsten Kopieren."
        acceptButton.isEnabled = false
        undoButton.isEnabled = false
        window.defaultButtonCell = acceptButton.cell as? NSButtonCell
    }

    private func configureKeyboardNavigation() {
        for view in [textView, notesView] {
            view.confirm = { [weak self] in self?.accept() }
        }
        // Die feste Schleife bleibt unabhängig vom noch nicht berechneten Auto-Layout.
        window.autorecalculatesKeyViewLoop = false
        notesView.nextKeyView = textView
        textView.nextKeyView = undoButton
        undoButton.nextKeyView = cancelButton
        cancelButton.nextKeyView = acceptButton
        acceptButton.nextKeyView = notesView
        window.initialFirstResponder = acceptButton
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
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        // Große Dokumente nur für die tatsächlich sichtbaren Bereiche setzen.
        view.layoutManager?.allowsNonContiguousLayout = true
        view.string = text
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "Vorschau schließen", action: #selector(cancel), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Bearbeiten")
        undoMenuItem.target = self
        undoMenuItem.action = #selector(undo)
        undoMenuItem.isEnabled = false
        edit.addItem(undoMenuItem)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(
            NSMenuItem(
                title: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        acceptMenuItem.action = #selector(accept)
        acceptMenuItem.keyEquivalentModifierMask = .command
        acceptMenuItem.target = self
        acceptMenuItem.isEnabled = false
        edit.addItem(acceptMenuItem)
        editItem.submenu = edit
        menu.addItem(editItem)
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
            message =
                value.pending_valid
                ? "Bereit zum Übernehmen."
                : "Diese Vorschau ist nicht mehr gültig. Clipboard geändert oder Sicherung nicht mehr verfügbar; bitte neu starten."
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
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.cancel)
        return false
    }
}

@MainActor
private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private let input: PreviewInput
    private let configuration: PreviewConfiguration
    private let client: StatusClient
    private let parent: pid_t
    private var signalSources: [DispatchSourceSignal] = []
    private var controller: PreviewController?
    private var timer: Timer?
    private var polling = false
    private var finishing = false

    init(input: PreviewInput, configuration: PreviewConfiguration, parent: pid_t) {
        self.input = input
        self.configuration = configuration
        self.parent = parent
        client = StatusClient(helper: input.helper, token: input.token)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signalSources = [SIGTERM, SIGINT].map { value in
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { [weak self] in self?.finish(.cancel, abandon: true) }
            source.resume()
            return source
        }
        guard getppid() == parent else {
            finish(.cancel, abandon: true)
            return
        }
        let view = PreviewController(
            text: input.text, notes: input.notes, background: configuration.background
        ) {
            [weak self] action in self?.finish(action)
        }
        view.textView.copySelection = configuration.copySelection
        view.notesView.copySelection = configuration.copySelection
        configuration.configureWindow?(view.window)
        controller = view
        if !configuration.background {
            view.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        poll()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func poll() {
        guard !finishing else { return }
        guard getppid() == parent else {
            finish(.cancel, abandon: true)
            return
        }
        guard !polling else { return }
        polling = true
        client.read { [weak self] result in
            guard let self, !finishing else { return }
            polling = false
            if let controller {
                controller.update(result)
                configuration.observe?(controller)
            }
        }
    }

    private func finish(_ action: PreviewAction, abandon: Bool = false) {
        guard !finishing else { return }
        finishing = true
        controller?.window.orderOut(nil)
        timer?.invalidate()
        Task {
            await client.cancel()
            if abandon { await client.abandonPreparation() }
            exit(action.rawValue)
        }
    }
}

private struct PreviewInput {
    let text: String
    let notes: String
    let helper: String
    let token: String

    init(arguments: [String]) throws {
        guard arguments.count == 5, !arguments[4].isEmpty,
            FileManager.default.isExecutableFile(atPath: arguments[3])
        else { throw PreviewError.invalidInput }
        let bodyURL = URL(fileURLWithPath: arguments[1])
        let notesURL = URL(fileURLWithPath: arguments[2])
        let bodySize = try bodyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let notesSize = try notesURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bodySize > 0, bodySize <= 64 * 1024 * 1024, notesSize <= 16 * 1024,
            let text = String(data: try Data(contentsOf: bodyURL), encoding: .utf8),
            let notes = String(data: try Data(contentsOf: notesURL), encoding: .utf8)
        else { throw PreviewError.invalidInput }
        self.text = text
        self.notes = notes
        self.helper = arguments[3]
        self.token = arguments[4]
    }
}

@MainActor
enum PreviewProgram {
    static func run(configuration: PreviewConfiguration = PreviewConfiguration()) -> Never {
        let parent = getppid()
        let input: PreviewInput
        do {
            input = try PreviewInput(arguments: CommandLine.arguments)
        } catch {
            let message =
                "Vorschau benötigt lesbaren UTF-8-Inhalt bis 64 MiB, Hinweise und einen Undo-Helfer.\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(64)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(configuration.background ? .accessory : .regular)
        let delegate = PreviewDelegate(input: input, configuration: configuration, parent: parent)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
        exit(PreviewAction.cancel.rawValue)
    }
}
