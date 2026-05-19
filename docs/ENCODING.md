# Encoding-Fallstricke auf macOS

Dieses Dokument hält die Fallen fest, in die wir während der Entwicklung
getappt sind. Jede ist mit einem echten Symptom dokumentiert, das wir
gesehen haben — wer das hier liest, soll dieselben Fehler nicht zweimal
machen müssen.

## TL;DR

- **Setze in jedem Bash-Skript, das mit Clipboard und Pandoc arbeitet,
  global `LC_ALL=en_US.UTF-8`** (oder eine andere `<lang>.UTF-8`). Das
  funktioniert sowohl für `pandoc`/`perl`/`sed` als auch für
  `pbcopy`/`pbpaste`.
- **Verwende KEINEN Inline-Override** wie `LC_ALL=C pbcopy` oder
  `LC_ALL=C pbpaste`. Das *wirkt* in trivialen Roundtrip-Tests korrekt,
  korrumpiert aber das Clipboard für jede andere App.
- **Teste den vollen Clipboard-Roundtrip mit einem ECHTEN App-View** —
  z.B. via `NSPasteboard.string(forType: .string)` in einem Swift-Helper.
  Niemals via `pbpaste`, das den Bug verstecken kann.

## Falle 1: pbcopy/pbpaste haben einen bizarren Locale-Bug

### Symptom

Du kopierst „Hermes Agent ☤" aus dem Browser. `md-clip --replace` läuft.
Du fügst in eine andere App ein und siehst „Hermes Agent ‚ò§". Umlaute
werden zu MacRoman-artigen Krüppel-Folgen wie `M√ºll` für „Müll".

### Ursache

`pbcopy` und `pbpaste` entscheiden anhand der Umgebungsvariable `LC_ALL`,
in welcher Codierung sie ihre Bytes interpretieren bzw. ausgeben:

| `LC_ALL` | pbcopy interpretiert Input als | pbpaste gibt aus als |
|---|---|---|
| `en_US.UTF-8` | UTF-8 ✓ | UTF-8 ✓ |
| `de_DE.UTF-8` | UTF-8 ✓ | UTF-8 ✓ |
| `C` | MacRoman ✗ | MacRoman ✗ |
| `POSIX` | MacRoman ✗ | MacRoman ✗ |
| `UTF-8` (ohne Sprache) | MacRoman ✗ | MacRoman ✗ |
| leer / nicht gesetzt | MacRoman ✗ | MacRoman ✗ |

Apple verlangt eine **vollqualifizierte „benannte" UTF-8-Locale** der
Form `<sprache>.UTF-8`. Eine bloße `UTF-8`-Angabe oder `C` reicht
nicht — sie werden behandelt wie das C-Locale, das auf macOS noch
historisch MacRoman als Fallback hat.

### Konsequenz

Wenn ein Skript ohne Locale gestartet wird (typisch für GUI-Apps wie
Dock-Icons oder Kurzbefehle.app), liest `pbpaste` UTF-8-Bytes vom
Clipboard und gibt sie als MacRoman-misinterpretierte Bytes auf stdout.
Spiegelbildlich nimmt `pbcopy` UTF-8-Bytes von stdin entgegen,
interpretiert sie als MacRoman und legt diese (falschen) Zeichen als
NSString aufs Clipboard.

Andere Apps, die per `NSPasteboard.string(forType: .string)` lesen,
sehen dann die falschen Zeichen direkt — Mojibake.

### Lösung

Ganz oben in `bin/md-clip`:

```bash
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
```

Diese Exporte gelten für das gesamte Skript inkl. aller Subprozesse,
also auch für die internen `pbcopy`- und `pbpaste`-Aufrufe.

### Wichtig: KEIN Inline-Override

Es war verlockend, beim Debuggen `LC_ALL=C pbcopy` und `LC_ALL=C pbpaste`
zu setzen. In einem Roundtrip wie

```bash
printf 'äöü' | LC_ALL=C pbcopy
LC_ALL=C pbpaste
# → äöü ✓
```

scheint das zu funktionieren. **Es ist eine Illusion**: pbcopy
interpretiert die UTF-8-Bytes als MacRoman und legt falsche Zeichen ab,
pbpaste interpretiert das stored NSString als MacRoman zurück und
restauriert die ursprünglichen Bytes. Der Test sieht grün, aber das
Clipboard enthält Müll, den jede andere App falsch dekodiert.

## Falle 2: Roundtrip-Tests können den Bug verstecken

### Symptom

Eigener Test:

```bash
printf '%s' "$input" | pbcopy
result=$(pbpaste)
[ "$result" = "$input" ] && echo OK
```

Test sagt OK. Aber das Clipboard enthält trotzdem Mojibake-Zeichen, die
jede andere App falsch dekodiert.

### Ursache

Wenn `pbcopy` und `pbpaste` mit der gleichen falschen Locale aufgerufen
werden, heben sich die Fehler gegenseitig auf. Das ist eine klassische
Symmetrie-Falle: gleicher Codec auf beiden Seiten = scheinbar korrekter
Roundtrip, obwohl die Daten dazwischen falsch sind.

### Lösung

Den Roundtrip-Test mit einem **dritten, unabhängigen Reader** prüfen.
In unserem Test ist das `tests/clipboard-string.swift`, das via
`NSPasteboard.string(forType: .string)` direkt das gespeicherte
NSString liest — was jede normale macOS-App auch tut.

Wenn dieser Reader Mojibake sieht, wird wirklich Mojibake auf dem
Clipboard liegen.

## Falle 3: Mehrere pandoc-Versionen koexistieren

### Symptom

`brew install pandoc` installiert pandoc 3.x. `pandoc --version` in der
Shell zeigt 3.x. Aber md-clip produziert Output, der wie pandoc 2.x
aussieht (z.B. 4-Space-Indent-Code statt ` ``` `-Fences).

### Ursache

Auf vielen Macs liegen historisch gewachsen zwei pandoc-Binaries:

- `/usr/local/bin/pandoc` — Reste eines alten `.pkg`-Installers von
  pandoc.org oder altes Intel-Homebrew. Brew kennt das nicht und
  aktualisiert es daher nicht.
- `/opt/homebrew/bin/pandoc` — das aktuelle, von brew verwaltete Binary
  auf Apple-Silicon-Macs.

Im `PATH` der Shell steht meistens `/opt/homebrew/bin` vor
`/usr/local/bin`, also gewinnt das aktuelle. Wenn `bin/md-clip` aber
einen eigenen `PATH` setzt, kann es die Reihenfolge umkehren und
versehentlich das uralte Binary verwenden.

### Lösung

In `bin/md-clip`:

```bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
```

`/opt/homebrew/bin` zuerst. Damit gewinnt auf Apple Silicon das
brew-Binary, und auf Intel-Macs (wo `/opt/homebrew/` nicht existiert)
gewinnt `/usr/local/bin/pandoc`, was dort auch das brew-Binary ist.

### Empfehlung für Nutzer

Wer ein altes `/usr/local/bin/pandoc` aus einem .pkg-Installer
übernommen hat, kann es gefahrlos löschen:

```bash
ls -la /usr/local/bin/pandoc   # Datum vor ca. 2020? = vermutlich alt
sudo rm /usr/local/bin/pandoc
```

Brew wird das `/opt/homebrew/bin/pandoc` weiter pflegen.

## Falle 4: PATH und LC_ALL fehlen in GUI-Launches

### Symptom

`md-clip` aus dem Terminal funktioniert. Wenn dasselbe md-clip aus der
Dock-App oder Kurzbefehle.app gestartet wird, kommt entweder „pandoc not
found" oder Mojibake-Output.

### Ursache

GUI-Apps unter macOS erben **nicht** den `PATH` der Shell. Sie sehen nur
den System-PATH (`/usr/bin:/bin:/usr/sbin:/sbin`). Brew-Binaries sind
nicht drin. Ähnlich fehlt oft `LANG`/`LC_ALL` — die werden nur durch
Shell-Init-Skripte gesetzt, nicht durch launchd.

### Lösung

`bin/md-clip` setzt PATH und LC_ALL **selbst** ganz oben:

```bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
```

Damit funktioniert das Skript unabhängig davon, wie es gestartet wird.

## Falle 5: textutil-RTF-Roundtrip mangelt Umlaute (für Test-Fixtures)

### Symptom

```bash
echo '<p>Einträge</p>' | textutil -convert rtf -format html -stdin -stdout
# → RTF mit \'c3\'a4 für ä
# Diese RTF zurückkonvertiert via textutil:
# → "EintrÃ¤ge"
```

### Ursache

`textutil` schreibt UTF-8-Bytes als RTF-Escape-Sequenzen, deklariert die
RTF aber mit `\ansicpg1252` (Windows-Latin-1). Beim Re-Parsing werden
die einzelnen Bytes als cp1252-Zeichen gelesen. Apple-Bug, dokumentiert
in unzähligen Stack-Overflow-Threads.

### Konsequenz für unsere Test-Fixtures

`tests/fixtures/word-rtf.rtf` wird ausschließlich mit ASCII-Inhalt
gefüttert, um diesen Bug zu umgehen. Echte RTFs aus Word/TextEdit/Pages
sind nicht betroffen, weil die ordentliche `\u<code>?`-Unicode-Notation
verwenden.

Falls wir mal Umlaut-Roundtrip in einer RTF-Fixture brauchen, kommt der
Test-Input aus TextEdit (per Hand), nicht aus `textutil HTML→RTF`.

## Der Test, der die Falle erwischt

Siehe `tests/run-tests.sh` → Block „Encoding-Roundtrip-Test". Kurz:

1. Setze HTML mit Umlaut + Emoji + EM-Dash auf das Clipboard
   (`tests/load-clipboard public.html …`).
2. Lass `md-clip --replace` laufen — die gesamte Pipeline inkl. pbcopy.
3. Lies das Clipboard via `tests/clipboard-string` — ein Swift-Helper,
   der `NSPasteboard.string(forType: .string)` aufruft und das Ergebnis
   als UTF-8 nach stdout schreibt.
4. Vergleiche Byte-für-Byte mit der erwarteten Ausgabe.

Der Test schlägt rot fehl, sobald jemand wieder einen `LC_ALL=C
pbcopy`-Inline-Override einbaut oder die globale LC_ALL-Locale
versehentlich wegnimmt. Er rauscht nicht durch, weil die Lese-Seite
explizit nicht `pbpaste` ist — der Symmetrie-Bias ist gebrochen.
