// md-clip-updater — Sparkle-Anbindung der md-clip.app.
//
// Die App selbst ist nur ein Shell-Launcher ohne Cocoa-Laufzeit. Sparkle
// braucht aber einen laufenden Prozess mit Runloop, der Feed-Abruf, Dialoge,
// Download, Signaturprüfung und den Austausch der App abwickelt. Genau das
// übernimmt dieses kleine Programm. Es liegt im Bundle unter Contents/MacOS/
// neben dem Launcher — dadurch ist Bundle.main die md-clip.app selbst, und
// Sparkle liest Feed-URL und Ed25519-Schlüssel aus deren Info.plist.
//
// Zwei Betriebsarten:
//   --background   Stille Suche nach dem eigentlichen md-clip-Lauf, vom
//                  Launcher gestartet — höchstens einmal je 24 Stunden.
//                  Ohne Fund (oder ohne Netz) beendet sich der Prozess
//                  wortlos; nur wenn es ein Update gibt, zeigt Sparkle
//                  seinen Dialog.
//   --interactive  Sichtbare Suche, zeigt auch „Sie sind aktuell" an.
//                  Wird von `md-clip --check-updates` aufgerufen.
//
// Installiert wird ausschließlich nach Zustimmung im Sparkle-Dialog
// (SUAllowsAutomaticUpdates ist in der Info.plist abgeschaltet). Nach dem
// Einspielen startet Sparkle die Host-App normalerweise neu — hier bewusst
// nicht, siehe updaterShouldRelaunchApplication(_:) unten.

import AppKit
import Sparkle

enum Mode {
    case background
    case interactive
}

func fail(usage message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fail(usage: "Aufruf: md-clip-updater --background | --interactive")
}
let mode: Mode
switch arguments[1] {
case "--background":
    mode = .background
case "--interactive":
    mode = .interactive
default:
    fail(usage: "Unbekannte Option: \(arguments[1])\nAufruf: md-clip-updater --background | --interactive")
}

// Drossel für den Hintergrundmodus: Der Launcher startet diesen Prozess bei
// jedem Doppelklick auf die App. Damit daraus nicht bei jeder Konvertierung
// ein Feed-Abruf wird, merken wir uns den letzten Hintergrund-Check selbst —
// in der Defaults-Domain der App (Bundle.main ist die md-clip.app). Der
// Betrag fängt zurückgestellte Uhren ab: Läge der gespeicherte Zeitpunkt in
// der Zukunft, wäre das Intervall sonst dauerhaft „noch nicht um".
let lastBackgroundCheckKey = "MDClipUpdaterLastBackgroundCheck"
let backgroundCheckInterval: TimeInterval = 24 * 60 * 60
if mode == .background {
    let defaults = UserDefaults.standard
    if let lastCheck = defaults.object(forKey: lastBackgroundCheckKey) as? Date,
        abs(Date().timeIntervalSince(lastCheck)) < backgroundCheckInterval {
        exit(0)
    }
    // Zeitstempel VOR dem Check schreiben: Auch ein fehlgeschlagener Abruf
    // (kein Netz, Feed noch nicht veröffentlicht) zählt als Versuch. Sonst
    // würde jeder App-Start ohne Netz erneut ins Leere greifen.
    defaults.set(Date(), forKey: lastBackgroundCheckKey)
}

/// Verdrahtet Sparkle mit dem Lebenszyklus dieses Einweg-Prozesses: Sparkle
/// meldet über die Delegate-Methoden, wann nichts mehr zu tun ist — dann
/// beendet sich der Prozess, statt unsichtbar weiterzulaufen.
final class UpdaterCoordinator: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Wahr, sobald Sparkle einen Update-Dialog anzeigt. Solange der Nutzer
    /// dort noch entscheidet, darf der Prozess sich nicht beenden.
    private var updateDialogVisible = false

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        updateDialogVisible = true
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Der Nutzer hat den Update-Dialog abgeschlossen (installieren,
        // überspringen, später erinnern). Bei einer Installation übernimmt
        // ab hier Sparkles Autoupdate-Programm; dieser Prozess kann weg.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// Kein Neustart der App nach dem Einspielen. md-clip.app ist eine
    /// Einweg-App: Jeder Start führt sofort `md-clip --replace --notify` aus
    /// (siehe wrappers/launcher.sh) und ersetzt damit den Clipboard-Inhalt.
    /// Sparkles Standard-Neustart würde also eine Konvertierung auslösen, die
    /// niemand beauftragt hat — und die kann echten Inhalt überschreiben, wenn
    /// der Nutzer während Dialog oder Download etwas anderes kopiert hat
    /// (Review-Fund 2026-08-06). Die neue Fassung startet beim nächsten
    /// Dock-Klick oder Hotkey ganz normal.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        return false
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        // Zyklus vorbei, ohne dass ein Dialog offen ist: Hintergrundlauf ohne
        // Fund oder ohne Netz — oder die sichtbare „Sie sind aktuell"-Meldung
        // wurde bestätigt (deren Bestätigung schließt den Zyklus erst ab).
        if !updateDialogVisible {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Startet den Updater erst, wenn die App-Laufzeit steht: Sparkle zeigt
/// Fenster an und braucht dafür eine fertig initialisierte NSApplication.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mode: Mode
    private let coordinator = UpdaterCoordinator()
    private var updaterController: SPUStandardUpdaterController?

    init(mode: Mode) {
        self.mode = mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // startingUpdater: false — der Start passiert gleich explizit. So
        // gibt es genau einen klar sichtbaren Ablauf statt eines implizit
        // mitlaufenden Zeitplans.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: coordinator,
            userDriverDelegate: coordinator
        )
        updaterController = controller
        controller.startUpdater()
        switch mode {
        case .background:
            controller.updater.checkForUpdatesInBackground()
        case .interactive:
            controller.updater.checkForUpdates()
        }
    }
}

let application = NSApplication.shared
// .accessory: kein Dock-Symbol, kein Menübalken — passend zur LSUIElement-App.
// Sparkles Standard-Oberfläche holt ihre Dialoge selbst in den Vordergrund.
application.setActivationPolicy(.accessory)
let appDelegate = AppDelegate(mode: mode)
application.delegate = appDelegate
application.run()
