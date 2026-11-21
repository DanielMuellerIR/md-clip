import AppKit

// Ein nicht aktivierendes Panel funktioniert auch beim Aufruf per Hotkey, für
// den macOS keine Berechtigung für Mitteilungen anfragt.
let arguments = CommandLine.arguments
guard arguments.count == 2, !arguments[1].isEmpty else {
    FileHandle.standardError.write(Data("Aufruf: md-clip-hud <Meldungstext>\n".utf8))
    exit(64)
}
let message = arguments[1]

@MainActor
final class HUDDelegate: NSObject, NSApplicationDelegate {
    private let text: String

    init(text: String) {
        self.text = text
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            NSApp.terminate(nil)
            return
        }
        let visible = screen.visibleFrame
        let horizontalPadding: CGFloat = 20
        let verticalPadding: CGFloat = 12
        let screenMargin: CGFloat = 16
        let maximumWidth = min(560, max(1, visible.width - 2 * (screenMargin + horizontalPadding)))
        let maximumHeight = max(1, visible.height - 2 * (screenMargin + verticalPadding))

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping

        let labelSize = label.cell?.cellSize ?? label.fittingSize
        let labelWidth = max(1, min(maximumWidth, labelSize.width))
        let labelBounds = NSRect(x: 0, y: 0, width: labelWidth, height: maximumHeight)
        let labelHeight = min(
            maximumHeight, label.cell?.cellSize(forBounds: labelBounds).height ?? labelSize.height)
        label.frame = NSRect(
            x: horizontalPadding, y: verticalPadding, width: labelWidth, height: labelHeight)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        let width = labelWidth + horizontalPadding * 2
        let height = labelHeight + verticalPadding * 2
        background.frame = NSRect(x: 0, y: 0, width: width, height: height)
        background.addSubview(label)

        let frame = NSRect(
            x: visible.midX - width / 2,
            y: min(visible.minY + visible.height * 0.12, visible.maxY - height - screenMargin),
            width: width,
            height: height)
        let hud = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hud.level = .floating
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.ignoresMouseEvents = true
        hud.hidesOnDeactivate = false
        hud.collectionBehavior = [.canJoinAllSpaces, .transient]

        hud.contentView = background

        hud.alphaValue = 0
        // orderFrontRegardless, weil die App nie „aktiv" wird (.accessory,
        // nonactivating) — ein normales orderFront käme sonst nie nach vorn.
        hud.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            hud.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.4
                    hud.animator().alphaValue = 0
                },
                completionHandler: {
                    Task { @MainActor in NSApp.terminate(nil) }
                })
        }
    }
}

let application = NSApplication.shared
// .accessory: kein Dock-Symbol, kein Menübalken — nur das kurze Overlay.
application.setActivationPolicy(.accessory)
let hudDelegate = HUDDelegate(text: message)
application.delegate = hudDelegate
application.run()
