// md-clip-notifier — Erfolgsmeldung unter eigener App-Identität.
//
// Warum nicht einfach osascript mit „display notification"? macOS ordnet
// Skript-Meldungen dem Skripteditor zu, nicht md-clip. Der Nutzer bekommt
// dann keinen „md-clip"-Eintrag in den Mitteilungs-Einstellungen — und auf
// neueren macOS-Versionen werden Skripteditor-Banner still unterdrückt
// (Befund 2026-08-06: Zustellungen landen in der Datenbank der
// Mitteilungszentrale, presented=0, ohne aktiven Fokus).
//
// Dieses Programm ist im Bundle ein EIGENES kleines App-Bundle
// (Contents/Resources/md-clip-notifier.app, Anzeigename „md-clip"), kein
// nacktes Binary: Nur das Haupt-Executable eines Bundles kann Mitteilungen
// unter eigener Identität abliefern. Dasselbe Muster nutzen Sparkles
// Updater.app und terminal-notifier.
//
// Zwei Zustellwege, in dieser Reihenfolge:
//
//   1. UserNotifications (modern). Braucht eine Erlaubnis; der Dialog
//      erscheint aber nur, wenn macOS den Aufruf als nutzerinitiierten
//      App-Start einstuft. Beim Start aus einem Skript heraus lehnt TCC
//      die Anfrage kommentarlos ab („Notifications are not allowed"),
//      OHNE den Nutzer je gefragt zu haben — am 2026-08-06 auf macOS 26
//      in allen Varianten (direkt, LaunchServices, signiert) belegt.
//   2. NSUserNotificationCenter (alt, deprecated seit 10.14, funktioniert
//      auf macOS 26 nachweislich — terminal-notifier arbeitet genau so).
//      Stellt ohne Vorab-Dialog zu und registriert die App dabei selbst
//      in den Mitteilungs-Einstellungen; dort kann der Nutzer sie
//      jederzeit abschalten.
//
// Eine ECHTE Nutzer-Entscheidung wird respektiert: Steht der Status auf
// „verweigert", obwohl der Nutzer je gefragt wurde oder den Eintrag in den
// Einstellungen abgeschaltet hat, greift derselbe Schalter auch für den
// alten Weg — beide laufen unter derselben Bundle-Identität.
//
// Aufruf: md-clip-notifier <Meldungstext>
// Exit: 0 = übergeben (oder Nutzer hat abgelehnt), 64 = falscher Aufruf,
//       69 = kein Zustellweg verfügbar.

import AppKit
import UserNotifications

let arguments = CommandLine.arguments
guard arguments.count == 2, !arguments[1].isEmpty else {
    FileHandle.standardError.write(Data("Aufruf: md-clip-notifier <Meldungstext>\n".utf8))
    exit(64)
}
let message = arguments[1]

// Alt-API-Zustellung (terminal-notifier-Weg). Die Deprecation-Warnung ist
// bekannt und bewusst in Kauf genommen, solange der moderne Weg aus
// Skript-Kontexten heraus keine Erlaubnis bekommen kann.
@available(macOS, deprecated: 11.0)
func deliverViaLegacyCenter() {
    let notification = NSUserNotification()
    notification.title = "md-clip"
    notification.informativeText = message
    NSUserNotificationCenter.default.deliver(notification)
    // Kurze Gnadenfrist: Die Zustellung ist asynchron, ein sofortiger
    // Prozess-Exit würde sie gelegentlich verlieren.
    Thread.sleep(forTimeInterval: 0.5)
}

let finished = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

let center = UNUserNotificationCenter.current()
center.getNotificationSettings { settings in
    switch settings.authorizationStatus {
    case .authorized, .provisional:
        // Modern erlaubt — regulär zustellen.
        let content = UNMutableNotificationContent()
        content.title = "md-clip"
        content.body = message
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { addError in
            if addError != nil {
                deliverViaLegacyCenter()
            }
            finished.signal()
        }
    case .denied:
        // Entscheidung des Nutzers (Einstellungen → Mitteilungen → md-clip).
        // Nicht umgehen — auch nicht über die Alt-API.
        finished.signal()
    default:
        // .notDetermined: einmal regulär anfragen. Erscheint der Dialog und
        // der Nutzer stimmt zu, läuft künftig der moderne Weg. Lehnt TCC
        // dagegen ab, ohne je gefragt zu haben (Skript-Kontext, siehe
        // Kopfkommentar), bleibt die Alt-API der Zustellweg.
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                let content = UNMutableNotificationContent()
                content.title = "md-clip"
                content.body = message
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                center.add(request) { addError in
                    if addError != nil {
                        deliverViaLegacyCenter()
                    }
                    finished.signal()
                }
            } else if error != nil {
                // Abgewiesen ohne Nutzerfrage — terminal-notifier-Weg.
                deliverViaLegacyCenter()
                finished.signal()
            } else {
                // Dialog erschien und der Nutzer hat abgelehnt: respektieren.
                finished.signal()
            }
        }
    }
}

// 180 s: großzügig genug für den einmaligen Erlaubnis-Dialog, endlich genug,
// um keinen unsichtbaren Dauerprozess zu hinterlassen.
if finished.wait(timeout: .now() + 180) == .timedOut {
    exit(69)
}
exit(exitCode)
