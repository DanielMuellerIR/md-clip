# Changelog

## 1.2.2 — unveröffentlicht

Alle zehn Befunde des Code-Reviews vom 2026-08-06, jeder vor dem Fix am echten
Code nachvollzogen. Die beiden Doku-Befunde stehen im letzten Punkt zusammen.

- Inline-Code, der auf einen Backslash endet, bleibt unverändert. Der
  schließende Backtick galt bisher als maskiert, der Code-Span blieb offen und
  sein Inhalt wurde wie Fließtext aufgeräumt: Aus `` `\#foo\` `` wurde
  `` `#foo\` ``, der Code hatte also einen anderen Inhalt als vorher.
- Römisch nummerierte Listen (`--to markdown`, `<ol type="i">`) behalten ihre
  Struktur. Der mehrstellige Marker `iv.` wurde nicht als Listenmarker erkannt,
  dadurch fiel der Schutz-Backslash vor der Raute weg und aus dem Listentext
  wurde eine Überschrift erster Ebene.
- Nach einem Update startet die App sich nicht mehr selbst neu. Sparkles
  Standard-Neustart löste eine Konvertierung aus und ersetzte damit ungefragt
  den Clipboard-Inhalt — auch dann, wenn während Dialog oder Download etwas
  anderes kopiert worden war.
- `wrappers/verify-bundle.sh` prüft im Modus `--signed` erst alle Signaturen
  und startet danach das Skript im Bundle. Bisher lief die Versionsabfrage
  zuerst; ein manipuliertes fremdes Bundle konnte damit Code ausführen, bevor
  überhaupt feststand, ob es vertrauenswürdig ist.
- Der Appcast-Workflow gibt den privaten Signierschlüssel nur noch dem Schritt,
  der signiert, statt allen Schritten des Jobs. Dasselbe Schlüsselpaar signiert
  die Updates von drei Apps.
- Der Appcast-Workflow veröffentlicht nur noch das aktuelle stabile Release:
  Prereleases, Entwürfe und ältere, von Hand gewählte Tags werden abgelehnt.
  Vorher hätte ein Prerelease stabilen Clients angeboten werden können, und ein
  manueller Lauf für ein altes Tag hätte das aktuelle Update aus dem Feed
  genommen.
- Der Appcast-Workflow checkt den Stand des Releases aus statt des Branches,
  aus dem er gestartet wurde, und prüft vor dem Veröffentlichen, dass Tag,
  DMG-Dateiname und Produktversion dieselbe Version meinen.
- Der SVG-Test prüft jetzt positiv, dass ein Bild mit `data:image/svg+xml` im
  Ziellink steht — mit Gegenprobe. Vorher genügte ihm jede Ausgabe außer einer
  bestimmten; eine leere Ausgabe wäre als Erfolg durchgegangen.
- Dokumentation: `--notify` beschreibt das Einblend-Fenster der App und die
  Mitteilungszentrale der Quellinstallation getrennt; AGENTS und der
  Build-Kommentar nennen den HUD-Helfer als zweite Cocoa-Laufzeit im Bundle.

## 1.2.1

Veröffentlicht am 2026-08-06. Erstes Update, das eine installierte App
(1.2.0) nachweislich selbst über Sparkle bezogen und eingespielt hat.

- Die Erfolgsmeldung erscheint als kurzes Einblend-Fenster der App selbst
  („Markdown ist im Clipboard", unten mittig, blendet nach zwei Sekunden
  wieder aus), statt als Mitteilung des Notification Centers. Bisher lief die
  Meldung per AppleScript unter der Identität „Skripteditor" und kam auf
  neueren macOS-Versionen nie sichtbar an. Das Notification Center scheidet
  grundsätzlich aus: macOS erfragt die nötige Erlaubnis nur nach einem
  nutzerinitiierten Start, und eine Anfrage aus einem Automationskontext —
  md-clips Normalfall (Dock-Klick-Kette, Hotkey, Skripte) — sperrt die App
  dauerhaft und ohne Nachfrage. Das Einblend-Fenster braucht keine Erlaubnis,
  stiehlt keinen Fokus und funktioniert in jedem Aufrufweg. Der
  AppleScript-Weg bleibt nur als Fallback der git-Installation ohne
  App-Bundle.

## 1.2.0

Veröffentlicht am 2026-08-06. Der Tag `v1.1.1` und der Stand danach hätten
sonst dieselbe Versionsnummer und denselben DMG-Dateinamen getragen, obwohl der
Inhalt ein anderer ist. Mit dem eingebauten Updater ist aus dem Fix-Stand
(zwischenzeitlich als 1.1.2 geführt) eine Funktions-Version geworden.

- Die App aktualisiert sich selbst über Sparkle 2.9.4 (wie Poor Man's Text):
  stille Suche nach einer Konvertierung, höchstens einmal täglich; sichtbare
  Suche per `md-clip --check-updates`. Installiert wird ausschließlich nach
  Bestätigung im Dialog, Feed und Archiv sind Ed25519-signiert, Hardware- und
  Systemprofildaten werden nicht übertragen. Details:
  `docs/SPARKLE-RELEASE.md`. Ältere Installationen müssen diese Version
  einmalig von Hand per DMG installieren; erst danach greifen Updates aus der
  App heraus.
- Drei App-Einstiegspunkte klar getrennt: `build.sh` baut, `install-app.sh`
  installiert nach `/Applications`, `release.sh` packt das DMG. Die App wird
  jetzt selbst notarisiert, nicht nur das Image.
- Der Name des notarytool-Schlüsselbund-Profils steht nicht mehr im Repo; er
  kommt aus `NOTARY_PROFILE` oder aus der Konfiguration des Clones.
- Zeilenumbrüche im Absatz erscheinen als zwei Leerzeichen statt als
  sichtbarem Backslash; Code-Blöcke bleiben dabei unangetastet.
- Überzählige Escapes vor Pipe und Raute werden zurückgenommen, in
  Tabellenzeilen aber bewusst nicht.
- Inline-Code bleibt beim Aufräumen unangetastet: `` `\#` `` heißt dort
  Backslash-Raute und wird nicht zu `` `#` ``.
- Eine Raute direkt hinter einem Listenmarker bleibt escaped, sonst würde aus
  `- # Text` eine Überschrift im Listenpunkt. Das gilt auch für verschachtelte
  Listen (`- - # tief`) sowie für alphabetische und Definitionslisten des Ziels
  `markdown` — dort wurde aus dem Text sonst eine Überschrift.
- Links ohne sichtbaren Text — etwa reine Icon-Links — bekommen ihre URL als
  Linktext, statt als unsichtbares `[](…)` zu verschwinden. Links um ein Bild
  oder ein eingebettetes SVG bleiben unverändert; ein SVG-Icon im Link verliert
  seine Grafik also nicht mehr.
- `--replace` legt kein überzähliges Schluss-Newline mehr ins Clipboard —
  entfernt wird genau eines, nämlich Pandocs Dateiende. Endet der kopierte Text
  auf einen leeren Absatz, bleibt der erhalten. Durchgereichter Plain-Text ist
  weiterhin bytegenau.
- Ein wörtlicher Backtick im Fließtext gilt nicht mehr als Anfang von
  Inline-Code: `` vor ` # mitte ` nach `` behält keinen sichtbaren Backslash
  vor der Raute zurück.
- Ein abgebrochener Release-Lauf lässt sein schreibbares Zwischen-Image nicht
  mehr im Build-Verzeichnis liegen.
- Die vier Sicherheitsfälle des privilegierten Installationsschritts laufen
  jetzt auch unter Linux und damit in der CI, nicht nur auf macOS.
- Der Erststart-Dialog der App ersetzt beim Einrichten des
  Kommandozeilen-Befehls keine fremde Datei mehr, die zwischen Nachfrage und
  Passworteingabe entsteht.
- Release- und Installationslauf räumen ihre temporären Dateien auch bei
  Abbruch und Fehlern auf; das Release prüft das fertige Image mit der
  Gatekeeper-Policy fürs Öffnen.

## 1.1.1 — 2026-07-22

- macOS 11/12: Symlink-Auflösung ohne das erst ab macOS 13 verfügbare `realpath`.
- Classroom-Anhänge werden gezielt gruppiert, ohne bestehende geordnete Listen
  in ungeordnete Listen umzuschreiben.
- Leere HTML-Links werden vor pandoc ergänzt; URLs mit Klammern, Escapes und
  Link-Titeln bleiben intakt.
- Plain-Text bleibt einschließlich aller abschließenden Newlines bytegenau.
- Produkt und Fixtures verwenden dieselbe Pipeline aus `lib/pipeline.sh`;
  Clipboard-Helper entstehen in einem privaten Testlayout statt im Checkout.
- Linux und Installer prüfen den tatsächlichen pandoc-RTF-Reader (mindestens
  pandoc 2.14.2); unsichere Installationsziele werden nicht überschrieben.
- Bundle-Downloads und pandoc-COPYRIGHT sind per SHA-256 gepinnt und atomar
  gecacht; das Release-Skript löst nur sein eigenes DMG-Device.
- Launcher-Pfade werden nicht mehr in AppleScript-/Shell-Quelltext interpoliert.
- Der überholte ausführbare Spike wurde als historischer Text archiviert.
