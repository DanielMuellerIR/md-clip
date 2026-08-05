# Sparkle-Updates veröffentlichen

md-clip bindet Sparkle 2.9.4 exakt gepinnt als fertig gebautes Framework ein
(kein SwiftPM — die App ist ein Shell-Launcher, siehe unten). Die App prüft
den Feed unter `https://danielmuellerir.github.io/md-clip/appcast.xml`, lädt
das DMG aus dem zugehörigen GitHub-Release und installiert ausschließlich nach
Zustimmung. Anonyme Hardware- und Systemprofildaten sind abgeschaltet.

Die erste Version mit eingebautem Updater ist der einmalige Einstieg: Ältere
Installationen enthalten keinen Updater und müssen einmal von Hand per DMG
aktualisiert werden; erst danach funktionieren Updates aus der App heraus.

Zwei unabhängige Prüfungen bleiben Pflicht:

- Developer-ID-Signatur und Apple-Notarisierung für App und DMG.
- Sparkle-Ed25519-Signatur für Update-Archiv und Feed.

Der private Sparkle-Schlüssel gehört weder in Git noch in Logs oder Argumente.
Nur sein öffentlicher Gegenpart steht als `SUPublicEDKey` in der Info.plist
(erzeugt in `wrappers/build-app-bundled.sh`). md-clip benutzt bewusst dasselbe
Schlüsselpaar wie Poor Man's Text und Fastra; es liegt im lokalen
Schlüsselbund unter dem Dienst `https://sparkle-project.org`. Eine Rotation
beträfe damit alle drei Apps.

## Warum ein eigener Updater-Helfer

Anders als Poor Man's Text ist md-clip.app keine Swift-App, sondern ein
Shell-Launcher: Beim Doppelklick konvertiert er das Clipboard und beendet
sich. Sparkle braucht aber einen laufenden Cocoa-Prozess mit Runloop für
Feed-Abruf, Dialoge, Download und App-Austausch. Diese Rolle übernimmt der
kompilierte Helfer `Contents/MacOS/md-clip-updater`
(Quelle: `helpers/md-clip-updater.swift`):

- Der Launcher startet ihn nach jeder Konvertierung entkoppelt mit
  `--background`. Der Helfer drosselt sich selbst auf höchstens einen
  Feed-Abruf je 24 Stunden und beendet sich ohne Fund wortlos; nur wenn es
  ein Update gibt, erscheint Sparkles Dialog.
- `md-clip --check-updates` startet ihn sichtbar (`--interactive`), inklusive
  „Sie sind aktuell“-Meldung. Das ist das Gegenstück zum Menüpunkt
  „Check for Updates…“ in Poor Man's Text — die md-clip.app hat kein Menü.
- Nach „Install and Relaunch“ startet macOS die App neu; der Launcher führt
  dann wie bei jedem Start eine Konvertierung aus. Das Clipboard enthält zu
  dem Zeitpunkt bereits Markdown, der Lauf ist also praktisch folgenlos.

## Was im Projekt dazugehört

- `wrappers/build-app-bundled.sh` pinnt Sparkle exakt (Version + SHA-256,
  gegenverifiziert am Homebrew-Cask), lädt die offizielle Binär-Distribution,
  prüft die Signatur der Sparkle-Entwickler auf dem entpackten Framework,
  kompiliert den Updater-Helfer dagegen, kopiert das Framework ohne
  XPC-Dienste (die App ist nicht sandboxed) nach `Contents/Frameworks` und
  legt Sparkles Lizenz unter `Contents/Resources/Licenses/Sparkle-LICENSE.txt`
  ab. Die Update-Schlüssel stehen im Info.plist-Heredoc derselben Datei.
- `wrappers/sign-bundle.sh` signiert von innen nach außen: Werkzeuge in
  `Resources/bin`, Updater-Helfer, Sparkles `Autoupdate`, `Updater.app`,
  Framework, zuletzt die App. Installation (`install-app.sh`) und Release
  (`wrappers/sign-and-release.sh`) benutzen dieselbe Datei.
- `wrappers/verify-bundle.sh` prüft das Produkt: Framework ohne XPC-Dienste,
  rpath und Sparkle-Verlinkung des Helfers, HTTPS-Feed samt öffentlichem
  Schlüssel, Versionsgleichheit — und mit `--signed` alle Signaturen.
- `helpers/md-clip-updater.swift` hält den einen Updater-Prozess; die
  Delegate-Methoden beenden ihn, sobald nichts mehr zu tun ist.
- `.github/workflows/publish-appcast.yml` erzeugt nach jedem Release den
  signierten Feed und veröffentlicht ihn über GitHub Pages.

## Einmalige GitHub-Einrichtung

1. In den Repository-Einstellungen unter **Pages** als Quelle
   **GitHub Actions** wählen. Das Environment `github-pages` muss neben dem
   Branch `main` auch Tags vom Typ `v*` zulassen, weil der automatische Lauf
   auf dem veröffentlichten Release-Tag startet.
2. Den privaten Schlüssel als Actions-Secret `SPARKLE_PRIVATE_KEY`
   hinterlegen. Sparkles `generate_keys -x` exportiert ihn vorübergehend in
   eine lokale Datei; `gh secret set SPARKLE_PRIVATE_KEY < datei` liest sie
   über stdin. Die Datei danach sicher entfernen. Den Schlüssel nie auf
   stdout ausgeben.
3. Der Schlüssel ist derselbe wie bei Poor Man's Text und Fastra und dort
   bereits verschlüsselt gesichert. Geht er verloren, ist eine kontrollierte
   Rotation über Developer-ID-signierte DMGs nötig — für alle drei Apps
   gemeinsam.

## Ablauf pro Release

1. Version in `bin/md-clip` (`VERSION=`), README und Changelog pflegen. Die
   Bundle-Version leitet der Build daraus ab; sie muss monoton steigen, denn
   Sparkle vergleicht Versionen über `CFBundleVersion`.
2. Release bauen: `./release.sh`. Das signiert (inkl. Sparkle), verifiziert,
   notarisiert App und DMG und stapelt die Tickets.
3. Tag und GitHub-Release mit genau einem DMG anlegen. Die Release Notes sind
   der Text, den Sparkle später im Update-Dialog anzeigt; erst danach
   veröffentlichen.
4. `.github/workflows/publish-appcast.yml` erzeugt mit Sparkles
   `generate_appcast` den signierten Feed und veröffentlicht ihn über GitHub
   Pages.
5. Workflow und Feed prüfen. Eine ältere, bereits Sparkle-fähige und
   notarisiert installierte Version muss das Release finden, installieren und
   neu starten.

Der Workflow kann für ein bestehendes Tag manuell gestartet werden. Er
erwartet genau ein `*.dmg`; der Feed enthält nur das aktuelle Vollupdate und
keine Deltas.
