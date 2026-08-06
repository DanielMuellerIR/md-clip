// md-clip-hud — Erfolgsmeldung als kurzes Einblend-Fenster (HUD).
//
// Warum kein Notification Center? Zwei am 2026-08-06 belegte Gründe:
//
//   1. macOS ordnet osascript-Meldungen („display notification") dem
//      Skripteditor zu, nicht md-clip; solche Banner werden auf neueren
//      Versionen teils still unterdrückt.
//   2. Der moderne Weg (UserNotifications) verlangt eine Erlaubnis, deren
//      Dialog macOS 26 nur zeigt, wenn die anfragende App mit gültiger
//      Signatur an einem ordentlichen Ort liegt UND der Start als
//      nutzerinitiiert gilt. Kommt die Anfrage je aus einem
//      Automationskontext (Hotkey über Kurzbefehle, Skript, CLI — die
//      Hauptnutzungswege von md-clip), wird die Bundle-ID still und
//      dauerhaft auf „verweigert" gesetzt, ohne dass der Nutzer je
//      gefragt wurde — und ohne Reset-Befehl.
//
// Ein eigenes Fenster der App braucht dagegen keinerlei Erlaubnis. Das HUD
// erscheint kurz mittig im unteren Bildschirmbereich (wie das
// Lautstärke-Overlay), stiehlt keinen Fokus, nimmt keine Mausklicks an und
// beendet sich nach dem Ausblenden selbst.
//
// Aufruf: md-clip-hud <Meldungstext>

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2, !arguments[1].isEmpty else {
    FileHandle.standardError.write(Data("Aufruf: md-clip-hud <Meldungstext>\n".utf8))
    exit(64)
}
let message = arguments[1]

/// Baut das Panel, blendet es ein, wartet, blendet aus und beendet den
/// Prozess. Alles läuft auf dem Hauptthread der App-Laufzeit.
final class HUDDelegate: NSObject, NSApplicationDelegate {
    private let text: String
    private var panel: NSPanel?

    init(text: String) {
        self.text = text
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .nonactivatingPanel: Das Fenster erscheint, ohne der aktiven App
        // den Fokus wegzunehmen — der Nutzer will direkt danach einfügen.
        let hud = NSPanel(
            contentRect: .zero,
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

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()

        // .hudWindow: halbtransparentes Systemmaterial, folgt automatisch
        // dem Hell-/Dunkelmodus.
        let horizontalPadding: CGFloat = 20
        let verticalPadding: CGFloat = 12
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        let width = label.frame.width + horizontalPadding * 2
        let height = label.frame.height + verticalPadding * 2
        background.frame = NSRect(x: 0, y: 0, width: width, height: height)
        label.frame.origin = NSPoint(
            x: horizontalPadding,
            y: (height - label.frame.height) / 2
        )
        background.addSubview(label)

        hud.setContentSize(background.frame.size)
        hud.contentView = background

        // Mittig, im unteren Achtel des sichtbaren Bereichs — dort, wo auch
        // die System-Overlays erscheinen und kein Fensterinhalt verdeckt wird.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            hud.setFrameOrigin(NSPoint(
                x: visible.midX - width / 2,
                y: visible.minY + visible.height * 0.12
            ))
        }

        hud.alphaValue = 0
        // orderFrontRegardless, weil die App nie „aktiv" wird (.accessory,
        // nonactivating) — ein normales orderFront käme sonst nie nach vorn.
        hud.orderFrontRegardless()
        panel = hud

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            hud.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.4
                hud.animator().alphaValue = 0
            }, completionHandler: {
                NSApp.terminate(nil)
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
