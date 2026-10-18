# Changelog

## 1.10.18 — 2026-10-18

- Wörtliche Backslashes bleiben auch vor weiteren Satzzeichen und am Ende
  von Link-/Bildzielen und Titeln erhalten. Klammern und Anführungszeichen
  beenden die Markdown-Verknüpfung dabei nicht vorzeitig.
- Link- und Bildadressen mit ungleichen Klammern bleiben vollständig erhalten,
  statt am ersten schließenden Zeichen abgeschnitten zu werden.
- Getippte Pipe-Zeilen und Tabellentrennlinien bleiben gewöhnlicher Text,
  auch in Listen und Zitaten. Die Nachbearbeitung erzeugt daraus weder
  eine Tabelle noch einen pandoc-Zeilenblock.
- HTML-Textbereiche erkennen auch schließende Tags mit überzähligen Attributen
  oder einem Slash. Nachfolgende vorformatierte Blöcke werden wieder als Code
  erhalten, statt versehentlich zum geschützten Textbereich zu gehören.
- HTML-Angebote mit NUL-Abschluss erzeugen auch bei automatischer Quellenwahl
  unter Linux keine Bash-Warnung mehr. Die Word-Erkennung verändert weiterhin
  keine Quellbytes und wählt RTF wie bisher bevorzugt.
- Konvertierungsleitfaden und Distributionsdokumentation berücksichtigen die
  zusätzlichen Praxisproben sowie den aktuellen manuellen Release-Weg.

## 1.10.17 — 2026-10-18

- Abschließende NUL-Zeichen in HTML-Kopierangeboten gelangen nicht mehr ins
  Markdown. NUL im HTML-Inhalt und ausdrücklich gewählter Klartext bleiben
  unverändert.
- Leere Absätze in verschachtelten Zitaten werden ohne Perl-Warnungen
  bereinigt; nachfolgender Text und Code behalten ihren Inhalt.

## 1.10.16 — 2026-10-18

- Codeblöcke direkt hinter einem Listenmarker behalten Backslashes und
  Leerzeilen. Die Nachbearbeitung erkennt dort sowohl Codezäune als auch
  eingerückten Code, einschließlich verschachtelter Listen und Zitate.
- README, CLI-Hilfe und Konvertierungsleitfaden unterscheiden Quellenwahl,
  Verluste beim Kopieren/Lesen und bekannte Vereinfachungen. Kleine ausführbare
  Beispiele erklären Code, Links, Bildreferenzen, Tabellen und Strict.

## 1.10.15 — 2026-10-17

- Wörtliches `\#` bleibt mit älteren GFM-/CommonMark-Writern vollständig
  erhalten. Die Raute verschwindet auch in Listen, Tabellen und Bildtexten
  nicht mehr; Inline-Code und Codeblöcke bleiben unverändert.
- Backslashes vor Rauten bleiben in Link-/Bildzielen und Titeln nach dem
  Markdown-Roundtrip erhalten, auch wenn mehrere Backslashes aufeinanderfolgen.

## 1.10.14 — 2026-10-16

- Das gebündelte pandoc und ältere unterstützte Versionen erhalten sprachlose
  Codeblöcke auch innerhalb von Listen. Explizite Codezäune verhindern, dass
  daraus normaler Listentext wird. Das Ziel `markdown` verwendet Tilde-Zäune,
  die auch der ältere Reader unmittelbar hinter einem Listenmarker erkennt.

## 1.10.13 — 2026-10-16

- Getippte Attributsyntax wie `{#beispiel}` bleibt in HTML-Überschriften auch
  beim Ziel `markdown` sichtbarer Text. Echte Überschriftsattribute und Code
  bleiben erhalten. Auch ältere GFM-/CommonMark-Writer verlieren die Klammer
  hinter einem getippten Backslash nicht mehr.

## 1.10.12 — 2026-10-16

- Hilfe- und Fehlerdialoge zeigen Umlaute und andere Unicode-Zeichen korrekt.
  Dynamische Texte werden als Argumente unverändert an AppleScript übergeben.

## 1.10.11 — 2026-10-16

- Tab und Shift-Tab erreichen Hinweise, Markdown und alle verfügbaren
  Vorschauaktionen in einer festen Reihenfolge. Deaktivierte Aktionen werden
  übersprungen, statt den Fokus auf dem Standardbutton festzuhalten.

## 1.10.10 — 2026-10-16

- Return übernimmt die native Vorschau auch bei Fokus im Markdown oder in den
  Konvertierungshinweisen. Nicht mehr verfügbare Übernahmen bleiben gesperrt;
  Auswahl, Kopieren und andere Tastenkürzel behalten ihr Verhalten.

## 1.10.9 — 2026-10-16

- Das gebündelte pandoc erhält Code in Zitaten, auch innerhalb nummerierter
  Listen. Sprachlose Codezäune umgehen dessen Writer-Fehler,
  ohne Text, Backslashes oder Sprachangaben zu verändern. macOS 14 bleibt unterstützt.
- Die macOS-CI bindet auch die CLI ausdrücklich an den Konverter ihrer Matrix,
  damit Writer und Roundtrip-Reader dieselbe pandoc-Version verwenden.

## 1.10.8 — 2026-10-16

- Weitere INT/TERM während der laufenden Bereinigung ändern den ersten Exit-Status
  nicht mehr. Eigene Kindprozesse, einmalige Stornierung und private Temp-Dateien
  werden weiterhin vollständig aufgeräumt.

## 1.10.7 — 2026-10-16

- Die macOS-CI baut zusätzlich ein unsigniertes Bundle und prüft Konvertierungen
  aus dessen eingebetteter CLI. Quellen-/Archivbindung, fremdes Arbeitsverzeichnis,
  Leerzeichenpfade und Rohbytes ergänzen die bisherigen Quellprüfungen.

- Scheitert die Übertragung einer erfolgreichen Undo-Vorbereitung an den Client,
  gibt der Dienst deren Token wieder frei. Eine neue Konvertierung kann sofort
  beginnen; die vorherige Undo-Sicherung bleibt erhalten.
- Nicht empfangbare Fehler-/Status-Antworten verwerfen keine andere Vorbereitung.
  Bereits geschriebene Ersetzungen und deren Undo bleiben auch bei fehlgeschlagener
  Antwort erhalten. Native macOS-/X11-/Wayland-Gegenproben sichern diese Grenzen.

## 1.10.6 — 2026-10-16

- Scheinbare Tags in `textarea` und `title` lösen keine Tabellenfehler aus.
  Quellenreparaturen erhalten diese Textbereiche einschließlich unvollständiger
  Bereiche; tatsächliche Zellen außerhalb werden weiterhin geprüft.
- Numerische HTML-Zeichenreferenzen in `rowspan`/`colspan` dürfen wie beim Reader
  ohne Semikolon enden. Ungültige und doppelte Spannweiten bleiben abgelehnt;
  Strict verweigert weiterhin eine notwendige Tabellen-Textdarstellung.

## 1.10.5 — 2026-10-16

- INT/TERM nur an die CLI beendet auch eine offene stdin-/Dateikopie oder eine
  blockierte stdout-Kopie. Eigene Kopierprozesse werden beendet und vorbereitete
  Undo-Sicherungen storniert; vorheriges Undo bleibt erhalten.
- Rohbytes und Terminaleingaben bleiben unverändert. Bereits ausgegebene
  Teilbytes müssen Aufrufer bei Exit 130/143 verwerfen.

## 1.10.4 — 2026-10-16

- RTF-Quellen benötigen vor dem Reader einen grundlegenden RTF-1-Kopf. Falsch
  als RTF angebotener Klartext zählt dadurch auch unter Linux nicht mehr als
  erfolgreicher Rich-Text-Versuch. Auto/Strict und explizite Eingaben nennen den
  Ablehnungsgrund; vorhandenes Clipboard und Undo bleiben geschützt.
- Die Kopfprüfung verändert keine Eingabebytes und akzeptiert BOM/Whitespace-
  Präfixe. Die weitere Syntaxprüfung bleibt Aufgabe des jeweiligen Readers.

## 1.10.3 — 2026-10-16

- Reine vorformatierte HTML-Texte ohne `code`-Kind bleiben als Codeblock erhalten,
  auch mit Syntax-Spans und `br`-Umbrüchen. Zeilen, Einrückungen und Backslashes
  gehen dadurch nicht in normalen Markdown-Absätzen verloren.
- Bestehende Code-Kinder/Sprachangaben sowie Blöcke mit Links, Bildern oder anderem
  Rich-Inhalt bleiben von dieser Reparatur ausgenommen.

## 1.10.2 — 2026-10-16

- Eingebettete SVGs behalten Styles, Datenattribute und foreignObject-Inhalte.
  HTML-Quellenreparaturen und Tabellenprüfungen behandeln ihre inneren Elemente
  nicht mehr als Dokumentinhalt; `--images keep` erhält die vollständigen Bilddaten.
- Native Integrationstests verbinden CLI, Vorschau und Undo-Dienst auf einem
  privaten Pasteboard. Übernahme, Abbruch/Undo, neues Kopieren, Signale und
  abgelehnte Eingaben werden gemeinsam geprüft. Die Teststeuerung ist im
  normalen Build ausgeschlossen.

## 1.10.1 — 2026-10-16

- X11 liest bereits in Xlib gepufferte Formatantworten vor dem Warten auf die
  Socket-Verbindung. Dadurch wird eine vollständige Sicherung nicht durch ein
  fälschliches Zeitlimit verworfen. Die bestehenden Lese-/Gesamtfristen bleiben
  erhalten; ein nativer Regressionstest prüft den vollständigen Formatinhalt.
- Die Classroom-Bereinigung erkennt Vorschaubilder am tatsächlichen Host und
  Pfad. Ähnliche URL-Teilstrings entfernen keine normalen Bilder mehr; deren
  Bildpolitik und Strict-Prüfung bleiben wirksam. Die Linkbereinigung entfernt
  wiederholte `authuser`-Query-Parameter vollständig und erhält Fragmentkennungen.

## 1.10.0 — 2026-10-16

- Native macOS-Vorschau über App-Aktion `--preview` oder CLI
  `--preview-window --replace`: Markdown, Quelle/Ziel und Vereinfachungen prüfen,
  übernehmen, abbrechen oder eine vorherige Ersetzung zurücknehmen.
- Vorschau und Schreiben verwenden dasselbe Ergebnis und dieselbe vorbereitete
  Clipboard-Generation. Statuswechsel deaktivieren ungültige Aktionen; Signale
  und unerwartetes Elternende schließen das Fenster und stornieren die Vorbereitung.
- Interne Statusabfragen verbrauchen kein Undo und starten keinen Dienst.
  Ältere laufende Dienste werden vor einer neuen Vorschauvorbereitung erkannt,
  damit vorhandene Sicherungen erhalten bleiben. Doctor nennt Vorschaufähigkeit.
- Vorschau-Helfer vollständig in CLI-Installation, Bundle-Prüfung und Signaturfolge
  integriert; native Hintergrund- und IPC-Prüfungen ergänzen die CI.

## 1.9.0 — 2026-10-16

- Die macOS-App bietet `--undo` als eigene Aktion für einen zweiten Hotkey.
  Sie nimmt die letzte Ersetzung zurück und zeigt verständliche Fehlerzustände,
  ohne Konvertierung, CLI-Setup oder Update-Suche auszulösen.
- `--help` erklärt die App-Aktionen. Unbekannte oder kombinierte Aktionen werden
  vor Clipboard-Zugriff abgelehnt; der normale Dock-Klick konvertiert weiterhin.

## 1.8.1 — 2026-10-16

- CI prüft das exakt gebündelte pandoc zusätzlich zum aktuellen System-pandoc;
  Build und Tests teilen Version und Archivprüfsumme. Alle Varianten-, Bild-,
  Tabellen- und Diagnoseverträge laufen in beiden macOS-Konfigurationen.
- CLI-Testattrappen verwenden ausdrücklich den Interpreter des Testprozesses.
  Quellenbeispiele sind dokumentiert und Classroom-Kennungen anonymisiert.
  README beschreibt Wayland-CI, CommonMark-Tabellen und sichere Testaufrufe korrekt.

## 1.8.0 — 2026-10-16

- Doctor ergänzt feste Diagnosekennungen, Ursachen und nächste Schritte für
  fehlende Werkzeuge/Bibliotheken, nicht erreichbare Sitzungen, fehlendes
  Wayland-Data-Control und defekte Helfer.
- JSON nennt Konvertierungsfähigkeiten, Clipboard-Werkzeuge und den getrennten
  Sitzungsstatus. Nicht geprüfte Lesefähigkeiten erscheinen als null.
  Sitzungsprüfungen lesen keine Clipboard-Inhalte und starten keinen Undo-Dienst.

## 1.7.0 — 2026-10-16

- `--tables text` stellt komplexe Tabellen als beschrifteten Text dar: geparste
  Zeilen/Spalten, Spannweiten, Fortsetzungen, leere Zellen und Verschachtelung
  bleiben nachvollziehbar. Zellinhalt mit Listen, Links und Code bleibt erhalten.
- Der Standard lehnt komplexe Tabellen weiterhin ab. Textdarstellungen werden
  gezählt und mit `--strict` verweigert; uneindeutige Zuordnungen werden vor der
  Ausgabe abgelehnt. RTF-Layouttabellen bleiben im Textmodus zunächst strukturiert.

## 1.6.0 — 2026-10-16

- `--images keep|alt|omit` erhält Bildreferenzen, reduziert Bilder auf ihren
  Alternativtext oder entfernt sie. Der Standard bleibt `keep`; SVG/data-URLs
  werden berücksichtigt, ohne Bilder herunterzuladen oder zu extrahieren.
- Bildvereinfachungen werden gezählt und mit `--strict` vor der Ausgabe
  abgelehnt. Ein leeres Ergebnis ersetzt das Clipboard nicht. Bildlinks behalten
  Ziel und Titel; Code und durchgereichter Klartext bleiben unverändert.

## 1.5.0 — 2026-10-16

- `--strict` lehnt erkannte Tabellenvereinfachungen und den Auto-Rückfall von
  Rich Text auf Klartext vor Ausgabe oder Clipboard-Ersetzung ab. Ein erfolgreicher
  Wechsel zwischen HTML und RTF sowie ursprünglicher/gewählter Klartext bleiben
  zulässig. Vorbereitete Undo-Sicherungen werden bei Abbruch storniert.
- Statusmeldungen nennen Anzahlen vereinfachter Tabellenzellen und RTF-
  Layouttabellen sowie Gründe übersprungener Quellen und den verwendeten Rückfall.
- Ein interner Bericht mit festen Kennungen trennt die Ergebnisbewertung von
  Nutzdaten und Diagnose. Ungültige Berichte werden vor der Ausgabe abgelehnt.

## 1.4.7 — 2026-10-16

- HTML-Attribute mit Anführungszeichen, Zeilenumbrüchen oder `>` verändern den
  Text nicht mehr. Claude-Codezeilen und Classroom-Anhänge werden auch bei
  einfachen Anführungszeichen und großgeschriebenen Attributnamen erkannt.
- Span-/Div-Container und leere Links werden auf geparsten pandoc-Knoten
  normalisiert. Linkziele, Titel, signifikante Leerzeichen und Code bleiben
  erhalten; Kommentare und JavaScript-/CSS-Rohtext bleiben unangetastet.
- HTML-Varianten werden nach dem Markdown-Roundtrip auf Text, Code, Linkziele,
  Linktitel und Listenstruktur geprüft. Der neue Quellenhelfer gehört zu allen
  Bundle- und isolierten Testlayouts.

## 1.4.6 — 2026-10-13

- Die Listenmarker-Prüfung berücksichtigt auch die ältere, unmaskierte
  Ausgabe des gebündelten pandoc. Die Konvertierung bleibt unverändert.
- 1.4.5 wurde nur als Quellstand getaggt; das geprüfte DMG erscheint als 1.4.6.

## 1.4.5 — 2026-10-13

- Code in Zitaten innerhalb nummerierter Listen behält Backslashes und
  Zeilenfortsetzungen auch bei mehrstelligen Listenmarkern.
- Tabellen- und Listenmarkertests prüfen die Struktur unabhängig von optionalen
  Absatzwrappern und der Maskierung verschiedener pandoc-Versionen.
- Ein wirkungsloser X11-Ereignispuffer entfällt; die Property-Abfrage bleibt
  für den INCR-Empfang maßgeblich.

## 1.4.4 — 2026-10-01

- Undo lässt alle geschriebenen Formatbytes vor dem Ende des Schreibprozesses
  von einem zweiten Prozess bestätigen. Das verhindert den gelegentlichen Verlust von Formaten
  nach einem auf macOS 14 bereits als erfolgreich gemeldeten Schreiben.
- Native Clipboard-Tests warten auf die tatsächlich begonnene Materialisierung
  vor einem simulierten Eigentümerwechsel.

## 1.4.3 — 2026-10-01

- Codeblöcke nach einer Liste und einem eigenständigen Zitat behalten ihren
  vollständigen Inhalt, einschließlich Backslashes und Zeilenfortsetzungen.
- Die CI prüft Undo auf privatem macOS-Pasteboard sowie isoliert unter X11
  und Wayland; Inhaltsregressionen laufen auf beiden Plattformen.

## 1.4.2 — 2026-10-01

- Das macOS-App-Icon ist verpflichtend. Fehlende, leere oder unlesbare
  Icon-Dateien brechen den Build vor Downloads und dem Entfernen eines
  vorhandenen Bundles ab. Die Bundle-Prüfung verlangt dasselbe Icon.

## 1.4.0 — 2026-09-30

- `--replace` sichert vor der Konvertierung alle lesbaren Clipboard-Formate
  und Items. `--undo` stellt die letzte erfolgreiche Ersetzung einmalig
  innerhalb von zehn Minuten wieder her. Eine neue Kopie verwirft die
  Sicherung auch bei identischem Inhalt; die Sicherung bleibt ausschließlich
  im Speicher. Fehlende Formate, Dateiversprechen und erkannte Änderungen
  führen vor dem Ersetzen zum Abbruch.
- Native Helfer verwenden NSPasteboard auf macOS, XFixes auf X11 und
  Data-Control auf unterstützten Wayland-Sitzungen. Der Doctor zeigt die
  Undo-Verfügbarkeit; eine Linux-Installation benötigt keinen laufenden Desktop.
- Zitatlisten beeinflussen nachfolgende eingerückte Codeblöcke nicht mehr.
  Claude-Codeblöcke und Classroom-Anhangstitel werden auch bei anderer
  Reihenfolge ihrer HTML-Attribute erkannt.

## 1.3.1 — 2026-09-08

- Formatierte unsichtbare Zeichen gelten vor der Markdown-Ausgabe als leer.
  Auto verwendet dann die nächste Quelle; explizites `--from html` bricht
  bei solchem Inhalt vor dem Ersetzen des Clipboards ab. Bilder, Trennlinien und sichtbarer Code bleiben erhalten.
- Schreibfehler auf stdout liefern wie dokumentiert Exit 3.
- Zwei unbenutzte Wrapper der früheren Quellenwahl entfernt.

## 1.3.0 — 2026-09-05

- Verschachtelte Tabellen und verbundene Zellen werden vor der Ausgabe anhand
  von pandocs Dokumentstruktur abgelehnt. Auto versucht danach die übrigen
  Quellen; explizites `--from` lässt das Clipboard unverändert. Wörtliches
  `[TABLE]` bleibt normaler Text.
- GFM-/CommonMark-Zellen behalten Text aus Absätzen, Listen, Zitaten und Code
  mit Leerzeichen zwischen Blöcken. Die Statusmeldung nennt die Vereinfachung.
- Auto versucht HTML → RTF → Klartext; bei Word RTF → HTML → Klartext. Status
  und HUD unterscheiden Konvertierung, Klartextübernahme und Vereinfachung.
- `--stdin` und `--input DATEI` funktionieren ohne Desktop. Klartext benötigt
  kein pandoc und bleibt bytegenau. Dependencies werden je Weg geprüft.
- `--doctor [--json]` zeigt Werkzeuge und geprüfte Fähigkeiten ohne Inhalte.
  `--preview --replace` zeigt das Ergebnis und verlangt `ja` am Terminal.
- Markdown-Aufräumregeln liegen in `lib/tidy-markdown.pl`; die gemeinsame
  Pipeline bleibt Einstieg. Bundle-Bau und Tests führen die Ressourcen mit.
- Wrapper-Tests sind nach Verantwortung aufgeteilt; Tabellen-Roundtrips,
  CLI-Attrappen für drei Backends, macOS-CI und ein isolierter Wayland-Test
  ergänzen die bestehende Abdeckung.
- Vollständiges Undo bleibt offen; `docs/CLIPBOARD-UNDO.md` beschreibt die
  Format-/Eigentümergrenzen und den Folgeplan.

## 1.2.9 — 2026-09-03

Fünf Fixes aus dem Code-Review vom 2026-09-03. Die ersten vier trafen den
Standardweg und liefen dabei ohne Fehlermeldung durch.

- **Eine Tabelle mit Zeilenumbruch in einer Zelle ging komplett verloren.**
  Eine Pipe-Tabelle hat pro Zelle genau eine Zeile. Enthielt eine Zelle einen
  `<br>`, zwei Absätze oder eine Liste, konnte pandoc sie dort nicht
  unterbringen und schrieb statt der ganzen Tabelle den Text `[TABLE]` — mit
  `--replace` stand danach genau dieses Wort im Clipboard. `<td>eins<br>zwei
  </td>` reichte dafür schon, und das ist in Word-Tabellen und auf Webseiten
  Alltag. `inline_table_cells` macht jetzt aus jeder Blockgrenze innerhalb einer
  Zelle ein Leerzeichen: Der Text bleibt vollständig erhalten, nur die Struktur
  *innerhalb* der Zelle geht verloren. Beim Ziel `markdown` bleibt alles wie es
  war — dort trägt die Gittertabelle Absätze und Umbrüche.
- **Beim Ziel `commonmark` verschwand jede Tabelle.** Strenges CommonMark kennt
  keine Tabellensyntax; ohne die Erweiterung `pipe_tables` schrieb pandoc auch
  für die einfachste Tabelle nur `[TABLE]`. Die Erweiterung ist jetzt an.
- **Beim Ziel `markdown` rutschte Text in die Nachbarzelle.** pandoc schrieb
  dort „simple"- und „multiline"-Tabellen, deren Zeilen mit dem Zellinhalt
  beginnen. `tidy_markdown` erkennt eine Tabellenzeile am führenden `|`, hielt
  diese Zeilen also für Fließtext und nahm den Backslash vor einem `|` weg. Weil
  die Spalten dort an festen Zeichenpositionen stehen, wurde die Zeile ein
  Zeichen kürzer und die Folgespalte rutschte hinein: Aus den Zellen `x|y` und
  `ok` wurde `x|y o` und `k` (im AST belegt). `run_pandoc` schaltet diese beiden
  Tabellenformen jetzt ab; die Gittertabelle bleibt für Zellen mit Absätzen, und
  ihre Inhaltszeilen beginnen ebenfalls mit `|`.
- **Auf einem schlanken Linux scheiterte jede Konvertierung.** Debian und Ubuntu
  liefern als Pflichtpaket nur `perl-base`; das Modul `Encode` steckt erst im
  vollen `perl`-Paket. `command -v perl` bestand deshalb, und danach brach jeder
  Lauf mit „Can't locate Encode.pm in @INC" ab. Statt `Encode::decode` steht
  dort jetzt das im Perl-Kern eingebaute `utf8::decode`, das dieselbe Auskunft
  über ungültiges UTF-8 gibt. Aus demselben Grund ermittelt
  `wrappers/verified-cache.sh` die Prüfsumme jetzt über `sha256_of`: `shasum`
  gibt es auf macOS, auf einem schlanken Linux dagegen nur mit dem vollen
  `perl`-Paket.
- **Strg-C beendet die CLI wieder sofort.** `bin/md-clip` räumte bei INT und
  TERM zwar seine Ausgabedatei weg, lief danach aber weiter — mit einer gerade
  gelöschten Datei. Jetzt endet es mit 130 beziehungsweise 143, wie es die
  übrigen Skripte des Projekts schon taten.

Aus der CodeQA-Kampagne desselben Tages, alle neun Bereiche und beide
Querschnitts-Funde:

- **Ein beschädigtes App-Bundle meldet sich jetzt.** Fehlte der eingebettete
  Befehl, schrieb der Launcher nur „No such file or directory" nach stderr —
  md-clip.app hat kein Fenster, das sah niemand. Der Dock-Klick wirkte, als
  täte die App nichts. Jetzt erscheint ein Dialog, und die App endet mit 2.
- **`install.sh` setzt den Symlink ohne `ln -sf`.** Zwischen der Prüfung des
  Ziels und dem Verlinken konnte dort etwas Fremdes entstehen; bei
  `/usr/local/bin` läuft der Befehl mit sudo und hätte es als root ersetzt.
  Jetzt wird nur der eigene oder tote Symlink entfernt und danach ohne `-f`
  verlinkt — wie im privilegierten Schritt des Launchers schon länger.
- **Die Produktversion wird überall gleich gelesen.** `bin/md-clip` trägt sie;
  gelesen wurde sie an sechs Stellen mit drei Schreibweisen, und die im
  Appcast-Workflow kam ohne `head` aus. Jetzt liest `md_clip_version` überall
  dasselbe. Dabei fielen zwei fehlende Absicherungen auf: Der Release-Lauf
  hätte bei unlesbarer Zeile ein `md-clip-.dmg` veröffentlicht, und die
  Bundle-Prüfung meldete einen Versionsvergleich gegen einen leeren Wert statt
  zu sagen, was fehlt.
- **Innen aufgeräumt, Verhalten unverändert:** Das gemeinsame Ende beider
  Konvertierungswege steht einmal in `html_to_markdown`, der Plain-Text-
  Rückfall einmal in `use_plain_text` statt fünfmal, die verifizierten
  Downloads des Bundle-Baus in `fetch_verified`, und die Developer-ID-Vorgabe
  nur noch in `wrappers/notarization.sh`. Der Aufräum-Trap des Bundle-Baus
  steht jetzt vor dem ersten `mktemp`.
- **Ein fehlgeschlagener Test sagt endlich, was er wollte.** Knapp sechzig
  stumme Vertragsprüfungen beendeten den Lauf wortlos; jetzt nennt ein
  ERR-Trap Datei, Zeile und Wortlaut. Der Linux-CI-Job hat eine Zeitgrenze von
  15 Minuten, und `md-clip-hud` hat als letzter Bundle-Helfer einen
  Argumentvertragstest bekommen.

Tests: `tests/run-tests.sh` 43/43 grün (vier neue Prüfungen: Tabellenzellen in
allen drei Zieldialekten, dazu ein Lauf mit absichtlich kaputtem `Encode.pm`),
`tests/test-wrapper-safety.sh` 34, `tests/test-install-safety.sh` 13,
`tests/test-plain-newlines.sh` 15 und `tests/test-dependencies.sh` 4 Prüfungen
grün. Ubuntu 24.04 im minimalen Container (pandoc 3.1.3, nur `perl-base`):
40/40 ohne Display, 43/43 unter Xvfb, alle vier Einzelskripte grün.
`./build.sh` VERIFY OK und BUILD OK.

Nach dem Tag kamen zwei Korrekturen an CI und Tests dazu, ohne Wirkung auf das
ausgelieferte Programm: Der Appcast-Workflow sourcte eine Datei aus der fest
gepinnten Tooling-Revision, die es dort noch nicht gibt, und der neue
HUD-Vertragstest kompilierte AppKit-Code auf dem Linux-Runner. Beides ist
behoben und im `swift:6.0`-Container unter genau der CI-Bedingung nachgeprüft.

## 1.2.8 — 2026-08-28

Fixes aus dem Code-Review vom 2026-08-28:

- **Ein beschädigter HTML-Flavor mit BOM gilt nicht mehr als lesbarer
  Rich Text.** Eine Byte-Order-Mark sagt verbindlich, in welcher Kodierung
  die Daten vorliegen. Scheiterte diese Dekodierung, lief
  `helpers/clipboard-html.swift` bis zum Latin-1-Rückfall durch — und
  ISO-8859-1 kennt jeden Bytewert, lieferte also Zeichensalat mit Exit 0.
  md-clip hielt das für brauchbaren Rich Text, erreichte den vorhandenen
  Plain-Text-Fallback nicht und ersetzte mit `--replace` das Clipboard
  durch den Zeichensalat. Jetzt bricht der Helfer bei einer BOM ab, die
  nicht zum Inhalt passt.
- **Unsichtbare Steuer- und Formatzeichen zählen wieder als leer.**
  `require_nonempty_markdown` kannte nur eine handgepflegte Liste
  (U+200B–U+200D, U+2060, U+FEFF). Ein Rich-Text-Flavor, der nur aus
  `&lrm;`/`&rlm;` (U+200E/U+200F), den unsichtbaren Operatoren
  U+2061–U+2064, einem weichen Trennstrich oder einem Variation Selector
  bestand, galt als sichtbarer Inhalt und unterdrückte den vorhandenen
  Plain-Text-Fallback. Maßgeblich ist jetzt die Unicode-Eigenschaft
  `Default_Ignorable_Code_Point`.
- **Der Layout-Umbruch am Ende eines mehrzeiligen Listenpunktes fällt weg.**
  Ob ein Hard-Break vor dem nächsten Listenpunkt entfernt wird, hing daran,
  ob die Zeile davor selbst mit einem Listenmarker beginnt. Fortsetzungs-
  zeilen eines offenen Punktes tun das nicht — im Ziel `markdown` blieb dort
  sichtbarer Leerraum stehen, der beim erneuten Rendern als zusätzliches
  `<br />` direkt vor `</li>` auftauchte. Jetzt entscheidet die Zugehörigkeit
  zum offenen Listencontainer.
- **Die Diagnose-Anleitung in `docs/ENCODING.md` läuft wieder durch.** Sie
  baute die beiden Test-Helfer in ein Temp-Verzeichnis, rief sie aber ohne
  Pfad auf — in einer normalen Shell antwortete beides mit
  `command not found`. Jetzt stehen die vollen Pfade da, samt Aufräumschritt.
- **`docs/DISTRIBUTION.md` nennt keine eingefrorene Versionsnummer mehr.**
  Sie stand noch auf v1.2.6 und empfahl `v1.2.6-rc1` als nächsten Test-Tag,
  während das Produkt längst 1.2.7 meldete. Status und Beispiel leiten die
  Nummer jetzt aus `bin/md-clip --version` beziehungsweise
  `git describe` ab.

Tests: `tests/run-tests.sh` 39/39 grün (drei neue Regressionstests: kaputte
BOM mit Plain-Text-Fallback, unsichtbare Zeichen, mehrzeiliger Listenpunkt in
allen drei Zieldialekten) plus die vier `tests/test-*.sh` grün.

## 1.2.7 — 2026-08-21

Fixes aus dem Code-Review vom 2026-08-21:

- **`--sandbox` wird jetzt vorab geprüft.** Die Option steckt in jedem
  HTML→Markdown-Aufruf, gibt es aber erst ab pandoc 2.15. Auf der bisher
  dokumentierten Mindestversion 2.14.2 bestand die Dependency-Prüfung und
  erst die eigentliche Konvertierung brach mit „Unknown option --sandbox"
  und Exit 3 ab. `pandoc_supports_sandbox()` prüft die Option jetzt real,
  Produkt und Installer lehnen ein zu altes pandoc mit klarer Meldung ab,
  und die dokumentierte Mindestversion ist überall 2.15.
- **Ein Hard-Break vor `1.`, `1)` oder `-` überlebt im Ziel `markdown`.**
  Diese Marker unterbrechen in GFM und CommonMark einen laufenden Absatz, in
  pandoc-Markdown nicht. Der Umbruch fiel bisher in allen Zielen weg und
  degradierte dort deshalb zum SoftBreak. Jetzt entscheidet der Zieldialekt,
  und zusätzlich zählt, ob die Zeile davor selbst zur Liste gehört: Nur dann
  ist der Umbruch pandocs Layout am Ende eines Listenpunktes.
- **Nur unsichtbarer Inhalt gilt wieder als leer.** `require_nonempty_markdown`
  las UTF-8 als rohe Bytes; die zwei Bytes des geschützten Leerzeichens
  U+00A0 galten dabei als sichtbarer Inhalt. Ein Rich-Text-Flavor mit einem
  einzelnen `&nbsp;` unterdrückte damit den vorhandenen Plain-Text-Fallback
  und ersetzte mit `--replace` das Clipboard durch Unsichtbares. Die Prüfung
  dekodiert jetzt als UTF-8 und wertet Unicode-Whitespace sowie die
  breitenlosen Zeichen (U+200B–U+200D, U+2060, U+FEFF) als leer.
- **`decodeHTML` in `helpers/clipboard-html.swift` ist nicht mehr optional.**
  ISO-8859-1 bildet jeden Bytewert ab, der Latin-1-Rückfall konnte also nie
  `nil` liefern — der Exit-2-Zweig „nicht dekodierbar" war unerreichbar und
  täuschte eine Prüfung vor.
- **Die dokumentierten Handbefehle bauen die Test-Helfer in ein
  Temp-Verzeichnis**, nicht mehr nach `tests/`. Sonst hinterließe der
  dokumentierte Diagnoseweg zwei ungetrackte Binaries im Arbeitsbaum,
  entgegen der Zusage im README.

Tests: 34 Fixture-/Roundtrip-Tests plus die vier `tests/test-*.sh` grün. Die
pandoc-Attrappe lehnt jetzt unbekannte Optionen ab und liegt auch neben
`md-clip` — das Produkt stellt sein eigenes Verzeichnis vorn in den PATH,
eine nur im fake-bin gepflegte Attrappe wurde nie befragt.

## 1.2.6 — 2026-08-20

- Die HTML-Vorverarbeitung entfernt `style`- und `data-*`-Attribute nur noch
  aus Tags. Gleichlautender Text in Prosa und Code bleibt erhalten; pandocs
  Sandbox verhindert außerdem Netzwerkzugriffe durch eingebettete Ressourcen.
- Leere oder nicht direkt als UTF-8 lesbare Rich-Text-Flavors umgehen den
  Plain-Text-Fallback nicht mehr. Die macOS-Helfer dekodieren auch UTF-16 mit
  BOM, und `--replace` lehnt ein leeres Konvertat unmittelbar vor dem Schreiben
  ins Clipboard ab.
- Echte Datentabellen, formatierte Listen und harte Zeilenumbrüche vor
  Jahreszahlen bleiben im RTF- und HTML-Pfad erhalten. Google-Classroom-Links
  behalten Fragmente und weitere Query-Parameter.
- Alphabetische, römische und Definitionslisten sowie verschachtelte Zitate
  werden im jeweiligen Markdown-Dialekt konsistent erkannt. Beide
  Konvertierungswege verwenden dafür dieselbe pandoc-Konfiguration.
- Der Linux-Installer verlangt nur noch das Clipboard-Werkzeug der aktiven
  X11- oder Wayland-Sitzung. Bytegenaue Clipboard-Tests decken UTF-8 und den
  UTF-16-HTML-Flavor von Firefox ab.
- Der Release-Lauf veröffentlicht den endgültigen DMG-Dateinamen erst nach
  erfolgreicher Signatur-, Notarisierungs- und Gatekeeper-Prüfung. Gemeinsame
  Notarisierungslogik, vollständige Helfer-Signaturprüfungen und eine feste
  Lebensdauer des Updater-Dialogs härten App und Image zusätzlich ab.
- Der Appcast-Workflow prüft die Ed25519-Signatur kryptografisch gegen den
  öffentlichen Schlüssel aus dem tatsächlichen Release-Bundle. Tooling,
  Release-DMG, Versionsfelder und Download-URL werden dabei fest miteinander
  verknüpft.
- Gemeinsame Test- und Release-Helfer ersetzen doppelte Abläufe. Die erweiterte
  Suite prüft Pipeline, Installer, Wrapper und beide Linux-Clipboard-Wege mit
  denselben Erwartungsdateien.

## 1.2.5 — 2026-08-16

- Die Markdown-Nachbearbeitung unterscheidet Listenmarker jetzt nach dem
  gewählten Zieldialekt. Gewöhnlicher Text wie `a. Text` oder `: Text` nach
  einem harten Zeilenumbruch wird dadurch nicht mehr als Liste oder
  eingerückter Code fehlgedeutet; echte Umbrüche und Code-Inhalt bleiben
  erhalten.
- Alphabetische, römische und Definitionslisten im Ziel `markdown` behalten
  weiterhin ihre Struktur, ohne die engeren Regeln von GFM und CommonMark zu
  verändern.
- Der Linux-Installer prüft für Wayland beide benötigten Programme
  (`wl-paste` und `wl-copy`) und meldet eine unvollständige Installation vor
  jeder Änderung am Installationsziel.
- Der Sparkle-Helfer akzeptiert genau einen dokumentierten Modus und lehnt
  fehlende, doppelte oder widersprüchliche Argumente mit Exit-Code 64 ab.
- Die App weist nun macOS 14 als tatsächliche Mindestversion aus. Der
  Bundle-Prüfer vergleicht diese Angabe mit allen eigenen Helfern, pandoc und
  den ausgelieferten Sparkle-Programmen.
- Der Release-Lauf bewahrt bei einem unklaren DMG-Mountzustand das
  Zwischen-Image, statt möglicherweise die Unterlage eines noch aktiven
  Mounts zu löschen.
- Linux-CI, Build-, Release- und Sicherheitstests prüfen die gehärteten
  Grenzen jetzt direkt; die Icon-Werkzeuge arbeiten in privaten temporären
  Verzeichnissen und lehnen nicht quadratische Vorlagen ab.

## 1.2.4 — 2026-08-11

- Der Release-Dispatcher startet nur noch für stabile Releases; ein
  übersprungener Prerelease-Job kann den privilegierten Folgelauf nicht mehr
  fälschlich freigeben.
- Der Appcast-Lauf wartet auf stdout und stderr des Sparkle-Generators, lehnt
  Schlüsselwarnungen zuverlässig ab und veröffentlicht kein Enclosure ohne
  EdDSA-Signatur.
- Eine ausdrücklich gesetzte Apple-Team-ID wird beim Signieren und bei allen
  nachfolgenden Vertrauensprüfungen identisch verwendet.
- Lokale Builds binden die eingebettete CLI bytegenau an `bin/md-clip`, prüfen
  ihre Syntax und führen `--version` aus, bevor sie Erfolg melden.
- `install.sh` erkennt einen vorhandenen CLI-Verweis in `md-clip.app` als
  gültige App-Installation, erklärt den getrennten Quellcode-Weg und nennt
  direkt `md-clip --check-updates`, statt die App irreführend als fremde
  Installation zu melden.

## 1.2.3 — 2026-08-10

Diese Version schließt die fünf Befunde des Code-Reviews vom 2026-08-09 und
härtet den Weg vom GitHub-Release bis zum signierten Sparkle-Feed.

- Der privilegierte Appcast-Lauf stammt jetzt immer aus dem Default-Branch.
  Ein Release-Tag löst nur noch einen unprivilegierten Dispatcher aus und kann
  weder ausführbaren Workflow-Code noch das Sparkle-Secret liefern.
- Downloader, Sparkle-Pins und Feed-Generator kommen aus einem fest
  eingetragenen, geprüften Tooling-Commit. Tag-Eingaben werden vor jeder
  Weitergabe streng als einzeiliges stabiles `vMAJOR.MINOR.PATCH` geprüft.
- Vor dem Start der mitgelieferten CLI prüft der Bundle-Guard Apples
  Signaturkette, Team-ID und Bundle-ID als gemeinsame Designated Requirement.
  Eine bloß gültige fremde Signatur genügt nicht mehr.
- Der Feed wird nur veröffentlicht, wenn er genau einen Eintrag und ein Archiv
  enthält und beide Versionsfelder sowie die Download-URL zum aktuellen
  stabilen Release passen.
- Die Release-Dokumentation stellt klar, dass ein Update md-clip nicht
  automatisch neu startet und ein manueller Appcast-Lauf ausschließlich das
  aktuelle stabile Release wiederholen darf.

## 1.2.2 — 2026-08-07

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
