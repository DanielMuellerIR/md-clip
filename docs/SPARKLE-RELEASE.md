# Sparkle-Updates veröffentlichen

md-clip bindet Sparkle als exakt gepinntes Framework ein. Die App prüft
den Feed unter `https://danielmuellerir.github.io/md-clip/appcast.xml`, lädt
das DMG aus dem zugehörigen GitHub-Release und installiert ausschließlich nach
Zustimmung. Anonyme Hardware- und Systemprofildaten sind abgeschaltet.

Die erste Version mit eingebautem Updater ist der einmalige Einstieg: Ältere
Installationen enthalten keinen Updater und müssen einmal von Hand per DMG
aktualisiert werden; erst danach funktionieren Updates aus der App heraus.

Zwei unabhängige Prüfungen bleiben Pflicht:

- Developer-ID-Signatur und Apple-Notarisierung für App und DMG.
- Ed25519-Signatur für das Update-Archiv. Der Feed enthält die Signatur.

Der private Sparkle-Schlüssel gehört weder in Git noch in Logs oder Argumente.
Das Bundle enthält den öffentlichen Prüfschlüssel in `SUPublicEDKey`.
Der private Schlüssel bleibt im Schlüsselbund und im Release-Environment.

## Warum ein eigener Updater-Helfer

Der Shell-Launcher konvertiert das Clipboard und beendet sich. Sparkle braucht
für Feed-Abruf, Dialoge, Download und App-Austausch einen laufenden
Cocoa-Prozess. Diese Rolle übernimmt der
kompilierte Helfer `Contents/MacOS/md-clip-updater`
(Quelle: `helpers/md-clip-updater.swift`):

- Der Launcher startet ihn nach jeder Konvertierung entkoppelt mit
  `--background`. Der Helfer ruft den Feed höchstens einmal je 24 Stunden ab.
  Sparkles Dialog erscheint bei einem verfügbaren Update.
- `md-clip --check-updates` startet ihn sichtbar (`--interactive`), inklusive
  „Sie sind aktuell“-Meldung.
- Nach der Installation startet Sparkle die App bewusst nicht neu. Ein
  automatischer Neustart würde den Launcher und damit ungefragt eine neue
  Clipboard-Konvertierung auslösen. Die neue Fassung läuft erst beim nächsten
  ausdrücklichen Dock-Klick, Hotkey- oder CLI-Aufruf.

## Was im Projekt dazugehört

- `wrappers/build-app-bundled.sh` pinnt Sparkle exakt (Version + SHA-256,
  gegenverifiziert am Homebrew-Cask), lädt die offizielle Binär-Distribution,
  prüft die Signatur der Sparkle-Entwickler auf dem entpackten Framework,
  kompiliert den Updater-Helfer dagegen, kopiert das Framework ohne
  XPC-Dienste (die App ist nicht sandboxed) nach `Contents/Frameworks` und
  legt Sparkles Lizenz unter `Contents/Resources/Licenses/Sparkle-LICENSE.txt`
  ab. Die Update-Schlüssel stehen im Info.plist-Heredoc derselben Datei.
- `wrappers/sign-bundle.sh` signiert von innen nach außen: Werkzeuge in
  `Resources/bin`, HUD-, Vorschau- und Updater-Helfer, Sparkles `Autoupdate`, `Updater.app`,
  Framework, zuletzt die App. Installation (`install-app.sh`) und Release
  (`wrappers/sign-and-release.sh`) benutzen dieselbe Datei.
- `wrappers/verify-bundle.sh` prüft das Produkt: Framework ohne XPC-Dienste,
  rpath und Sparkle-Verlinkung des Helfers, HTTPS-Feed samt öffentlichem
  Schlüssel, Versionsgleichheit — und mit `--signed` alle Signaturen.
- `helpers/md-clip-updater.swift` hält den einen Updater-Prozess; die
  Delegate-Methoden beenden ihn, sobald nichts mehr zu tun ist.
- `.github/workflows/request-appcast.yml` reagiert ohne Secret auf das Release.
  Erst sein Abschluss startet `.github/workflows/publish-appcast.yml` per
  `workflow_run` aus dem vertrauenswürdigen Default-Branch. Dieser zweite
  Workflow erzeugt den Feed mit der Archivsignatur und veröffentlicht ihn
  über GitHub Pages. Downloader, Sparkle-Pins und Generator kommen dabei aus einer
  festgelegten, vertrauenswürdigen Tooling-Revision; der Release-Tag liefert
  nur Version, DMG und Release Notes. Vor der Veröffentlichung muss der Feed
  genau einen Eintrag enthalten, dessen beide Versionsfelder und URL zum Tag
  passen. Der Workflow prüft die Ed25519-Signatur gegen die DMG-Bytes mit
  dem öffentlichen Schlüssel aus der App im DMG.

## Einmalige GitHub-Einrichtung

1. In den Repository-Einstellungen unter **Pages** als Quelle
   **GitHub Actions** wählen. Das Environment `github-pages` darf nur den
   geschützten Default-Branch `main` zulassen. Der unprivilegierte
   Release-Dispatcher läuft aus dem Tag und darf dieses Environment nicht
   betreten.
2. Den privaten Schlüssel als **Environment-Secret** `SPARKLE_PRIVATE_KEY` im
   Environment `github-pages` hinterlegen, nicht als Repository-Secret. Ein
   früher dort hinterlegtes Repository-Secret anschließend entfernen, damit
   kein Workflow aus einem Release-Tag darauf zugreifen kann. Sparkles
   `generate_keys -x` exportiert den Schlüssel vorübergehend in eine lokale
   Datei; beim Einfügen nie auf stdout ausgeben und die Datei danach sicher
   entfernen.
3. Den privaten Schlüssel verschlüsselt sichern. Eine Rotation muss die
   Aktualisierung bereits installierter Apps berücksichtigen. Bei Verlust des
   Schlüssels lässt sich ein neues Developer-ID-signiertes und notarisiertes
   DMG zur manuellen Installation bereitstellen.

## Ablauf pro Release

1. Version in `bin/md-clip` (`VERSION=`) und `CHANGELOG.md` pflegen. Der
   Build übernimmt sie in `CFBundleVersion`. Sparkle erwartet einen
   steigenden Wert.
2. Mit `./release.sh` App und DMG bauen, mit Developer ID signieren und
   notarisieren. [Build und Signaturprüfung](DISTRIBUTION.md)
3. Tag und GitHub-Release mit genau einem DMG anlegen. Die Release Notes sind
   der Text, den Sparkle später im Update-Dialog anzeigt; erst danach
   veröffentlichen.
4. `.github/workflows/request-appcast.yml` stößt ohne Secret den
   vertrauenswürdigen `.github/workflows/publish-appcast.yml` im Default-Branch
   an. Dieser erstellt mit Sparkles `generate_appcast` den Feed samt
   Archivsignatur und veröffentlicht ihn über GitHub Pages.
5. Workflow und Feed prüfen. Eine ältere, bereits Sparkle-fähige und
   notarisiert installierte Version muss das Release finden und installieren,
   ohne md-clip automatisch neu zu starten. Beim nächsten ausdrücklichen Start
   muss die neue Version laufen.

Der manuelle Workflow ist ausschließlich der Wiederholungslauf für das
aktuelle stabile Release, etwa wenn dessen automatischer Appcast-Lauf
fehlgeschlagen ist. Ein älteres Tag, Prerelease oder Entwurf wird abgelehnt.
Das Release muss genau ein `*.dmg` enthalten; der Feed enthält nur das aktuelle
Vollupdate und keine Deltas.
