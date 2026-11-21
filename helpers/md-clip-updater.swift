import AppKit
import Foundation
import Sparkle

// Der Standard-User-Driver ruft sein Delegate auf dem Hauptthread auf.
// Sein Objective-C-Protokoll trägt keine entsprechende Swift-Annotation.
@MainActor
final class UpdaterCoordinator: NSObject, SPUUpdaterDelegate,
    @preconcurrency SPUStandardUserDriverDelegate
{
    /// Wahr, sobald Sparkle einen Update-Dialog anzeigt. Solange der Nutzer
    /// dort noch entscheidet, darf der Prozess sich nicht beenden.
    private var updateDialogVisible = false
    private var dialogDeadline: Task<Void, Never>?
    private let maximumDialogLifetime: TimeInterval = 30 * 60

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        updateDialogVisible = true
        dialogDeadline?.cancel()
        dialogDeadline = Task {
            do { try await Task.sleep(for: .seconds(maximumDialogLifetime)) } catch { return }
            NSApp.terminate(nil)
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Der Nutzer hat den Update-Dialog abgeschlossen (installieren,
        // überspringen, später erinnern). Bei einer Installation übernimmt
        // ab hier Sparkles Autoupdate-Programm; dieser Prozess kann weg.
        dialogDeadline?.cancel()
        dialogDeadline = nil
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    // Der Launcher konvertiert beim App-Start sofort das Clipboard.
    // Die neue Version soll erst beim nächsten beauftragten Start laufen.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        false
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
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mode: UpdaterMode
    private let coordinator = UpdaterCoordinator()
    private var updaterController: SPUStandardUpdaterController?

    init(mode: UpdaterMode) {
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

@main
@MainActor
enum UpdaterMain {
    static func main() {
        let mode = UpdaterMode.parse(arguments: CommandLine.arguments)
        if mode == .background {
            let key = "MDClipUpdaterLastBackgroundCheck"
            let checkInterval: TimeInterval = 24 * 60 * 60
            let defaults = UserDefaults.standard
            // Der Betrag berücksichtigt zurückgestellte Systemuhren.
            if let lastCheck = defaults.object(forKey: key) as? Date,
                abs(Date().timeIntervalSince(lastCheck)) < checkInterval
            {
                return
            }
            // Auch ein Abruffehler soll weitere Versuche am selben Tag drosseln.
            defaults.set(Date(), forKey: key)
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate(mode: mode)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
