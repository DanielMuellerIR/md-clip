# Encoding-Fallstricke (macOS und Linux)

Dieses Dokument hält die Fallen fest, in die wir während der Entwicklung
getappt sind. Jede ist mit einem echten Symptom dokumentiert, das wir
gesehen haben — wer das hier liest, soll dieselben Fehler nicht zweimal
machen müssen.

Fallen 1–5 stammen aus der macOS-Entwicklung, Fallen 6–7 kamen mit dem
Linux-Port dazu (2026-07-16).

## TL;DR

- **Setze in jedem Bash-Skript, das mit Clipboard und Pandoc arbeitet,
  global eine UTF-8-Locale.** Auf macOS `LC_ALL=en_US.UTF-8` (oder eine
  andere `<lang>.UTF-8`) — das funktioniert für `pandoc`/`perl`/`sed`
  ebenso wie für `pbcopy`/`pbpaste`. **Auf Linux dagegen `C.UTF-8`**,
  siehe Falle 6.
- **Verwende KEINEN Inline-Override** wie `LC_ALL=C pbcopy` oder
  `LC_ALL=C pbpaste`. Das *wirkt* in trivialen Roundtrip-Tests korrekt,
  korrumpiert aber das Clipboard für jede andere App.
- **Teste den vollen Clipboard-Roundtrip mit einem ECHTEN App-View** —
  z.B. via `NSPasteboard.string(forType: .string)` in einem Swift-Helper.
  Niemals via `pbpaste`, das den Bug verstecken kann.
- **Auf Linux ist das Clipboard nicht automatisch UTF-8:** Firefox legt
  HTML als UTF-16 ab, Chromium als UTF-8. Siehe Falle 7.

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

## Falle 6: `en_US.UTF-8` existiert auf Linux oft gar nicht

### Symptom

`perl: warning: Setting locale failed.` / `Falling back to the standard
locale ("C")` auf stderr — und danach genau der Umlaut-Salat, den die
LC_ALL-Zeile eigentlich verhindern sollte.

### Ursache

Auf macOS ist `en_US.UTF-8` immer vorhanden. Auf Linux sind Locales
**erzeugte Artefakte** (`locale-gen`): Was nicht erzeugt wurde, existiert
nicht. Auf einem deutschen System ist oft nur `de_DE.UTF-8` da, in einem
schlanken Container (`ubuntu:24.04`) sogar **nur `C.UTF-8`** — verifiziert:

```
$ docker run --rm ubuntu:24.04 locale -a
C
C.utf8
POSIX
```

Ein `export LC_ALL=en_US.UTF-8` auf eine nicht existierende Locale ist
kein Fehler, der abbricht — die Programme fallen still auf `C` zurück.
Damit ist die Zeile, die UTF-8 sicherstellen soll, ausgerechnet die
Ursache des Byte-Salats.

### Lösung

`C.UTF-8` auf Linux. Die ist in glibc **fest eingebaut**, braucht kein
`locale-gen` und ist damit überall verfügbar. Der einzige Grund für eine
benannte Sprach-Locale war `pbcopy`/`pbpaste` (Falle 1) — die gibt es auf
Linux ohnehin nicht.

```bash
if [ "$PLATFORM" = "macos" ]; then
  export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
else
  export LC_ALL=C.UTF-8 LANG=C.UTF-8
fi
```

## Falle 7: Firefox legt HTML als UTF-16 aufs Linux-Clipboard

### Symptom

Aus einer Firefox-Kopie kommt Müll, aus derselben Seite in Chromium
sauberes Markdown. Im rohen Clipboard-Inhalt steht zwischen jedem
Buchstaben ein NUL-Byte.

### Ursache

Der `text/html`-Flavor hat auf X11/Wayland **keine vorgeschriebene
Kodierung**. Firefox schreibt UTF-16 (mit BOM, Altlast der
GTK-Clipboard-Anbindung), Chromium UTF-8. Anders als auf macOS, wo
NSPasteboard immer UTF-8 liefert, muss man beides können — und man sieht
dem Clipboard nicht an, welcher Browser geschrieben hat.

### Lösung

BOM lesen und ggf. per iconv wandeln (`to_utf8` in `bin/md-clip`):

- `ff fe` / `fe ff` → `iconv -f UTF-16 -t UTF-8`. Bewusst **ohne**
  `LE`/`BE`-Suffix: In dieser Form wertet iconv die BOM selbst aus und
  entfernt sie; mit `UTF-16LE` bliebe die BOM als unsichtbares Zeichen stehen.
- `ef bb bf` → UTF-8 mit BOM, die drei Bytes abschneiden.
- sonst → schon UTF-8, durchreichen.

### Die Falle in der Falle

Das muss über eine **Temp-Datei** laufen, nicht über eine Variable:
Bash verwirft in `$(...)` NUL-Bytes — also genau die Bytes, die UTF-16
ausmachen. Wer das Clipboard erst in eine Variable liest und dann die
Kodierung prüfen will, hat den Text bereits zerstört, bevor er ihn ansieht.

## Die Tests, die die Fallen erwischen

Siehe `tests/run-tests.sh` → Block „Clipboard-Roundtrip-Tests". Kurz:

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

Auf Linux läuft derselbe Roundtrip über `xclip` bzw. `wl-copy`/`wl-paste`
(auch hier bewusst die plattformeigenen Werkzeuge, nicht md-clips eigene
Funktionen — sonst hübe sich ein Fehler auf beiden Seiten gegenseitig auf).
Dazu kommt `utf16-html-clipboard` für Falle 7: Der Test erzeugt die
UTF-16-Variante mit `iconv` selbst, statt einen echten Firefox zu starten
— es geht um die **Bytes** auf dem Clipboard, und die sind so exakt
reproduzierbar, headless und in CI.

Ohne erreichbares Clipboard (Container, SSH-Sitzung) überspringen sich die
Roundtrip-Tests **sichtbar** statt rot zu werden; mit `xvfb-run
./tests/run-tests.sh` laufen sie auch dort mit.
