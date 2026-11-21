# Zeichenkodierung

## UTF-8 in der Kommandozeile

Die CLI setzt `LC_ALL` und `LANG` unter macOS auf `en_US.UTF-8`, unter Linux
auf `C.UTF-8`. GUI-Starts unter macOS können mit anderer Locale und anderem
Suchpfad als im Terminal erfolgen. Die CLI ergänzt dort den Suchpfad um
`/opt/homebrew/bin` vor `/usr/local/bin`. Im App-Bundle hat der eingebettete
Konverter Vorrang. `md-clip --version` zeigt den tatsächlich gefundenen pandoc.

Der Klartextpfad reicht alle Bytes unverändert durch. Die Mac-CLI verwendet
zum Schreiben den nativen Helfer über `NSPasteboard`. Beim Lesen von Klartext
und in Testwerkzeugen kann `pbpaste` weiterhin beteiligt sein. Die macOS-Tools
`pbcopy` und `pbpaste` brauchen eine benannte Locale wie `en_US.UTF-8`;
mit `LC_ALL=C` können sie MacRoman verwenden. Ein Test mit beiden Werkzeugen
in derselben falschen Locale kann gleiche Bytes zurückliefern, obwohl andere
Apps falsche Zeichen sehen. Deshalb prüft der macOS-Roundtrip den Text mit
einem unabhängigen Leser direkt aus `NSPasteboard`.

## Linux-Clipboard

Linux-Programme können HTML unterschiedlich kodieren. Ein Firefox-Angebot
kann UTF-16 mit Byte Order Mark (BOM) enthalten, ein Chromium-Angebot UTF-8.
Der Plattformadapter liest Clipboard-Angebote in eine Datei. Das erhält
die NUL-Bytes in UTF-16, die eine Bash-Command-Substitution verwerfen würde.

Bei `FF FE` oder `FE FF` wandelt `iconv -f UTF-16 -t UTF-8` den Inhalt um.
Die BOM bestimmt die Byte-Reihenfolge und wird entfernt. Eine UTF-8-BOM
(`EF BB BF`) wird ebenfalls entfernt. Ohne BOM bleiben die Daten unverändert.
Der Linux-Test erzeugt den UTF-16-Fall mit `iconv` und liest die Markdown-Ausgabe
über das Clipboard-Werkzeug der eigenen Testsitzung zurück.

## AppleScript-Pfade

Launcher und Finder-Layout reichen Dateipfade als Argumente an die
AppleScripts weiter. `system attribute` kann UTF-8-Umgebungswerte als
MacRoman lesen. Ein Pfad wie `Müller` kommt dann verfälscht an.
Bei einem nachgelagerten Shell-Aufruf schützt AppleScripts `quoted form of`
den Pfad als einzelnen Wert, auch bei Leerzeichen und Apostrophen.

## RTF-Testdaten

Beim lokalen Generieren von RTF aus HTML kann `textutil` UTF-8-Bytes als
`\\'c3\\'a4` für „ä“ schreiben und gleichzeitig Windows-1252 deklarieren.
Das führt beim Rücklesen zu `Ã¤`. Der gemeinsame RTF-Fixture verwendet ASCII.
Für eine Unicode-Probe eignet sich ein tatsächlicher RTF-Export oder eine
korrekte RTF-Unicode-Sequenz wie `\\u228?`.
[Fixture-Korpus](../tests/fixtures/README.md) · [Testanleitung](../CONTRIBUTING.md#prüfungen)
