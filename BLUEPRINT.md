# md-clip · Blueprint v1.0

**Stand:** 2026-05-18 · **Status:** Spike abgeschlossen, validiert, bereit für Phase-1-Implementierung.

---

## So benutzt du dieses Dokument

Dieses Dokument ist eine **vollständige Übergabe**. Es enthält Kontext, validierte Spike-Erkenntnisse, fertigen Code aus dem Spike und einen klaren Implementierungsauftrag. Ziel: eine neue Claude-Code-Session kann mit diesem Blueprint als einzigem Input ein funktionierendes Tool bauen, ohne die Vorerkenntnisse erneut sammeln zu müssen.

**Workflow:**

1. Neues Projekt-Verzeichnis anlegen, z.B. `~/Code/md-clip/`.
2. Dieses Dokument als `BLUEPRINT.md` ins Projekt legen.
3. Neue Claude-Code-Session in diesem Verzeichnis starten.
4. Als ersten Prompt: *"Lies BLUEPRINT.md und implementiere Phase 1 wie beschrieben."*

---

## Zweck

`md-clip` ist ein macOS-CLI-Tool, das den Inhalt des Clipboards in Markdown konvertiert. Default: Ausgabe auf stdout. Mit `--replace`: das Clipboard wird durch das Markdown-Ergebnis ersetzt. Wrapper für Dock-Icon (Automator-App) und globalen Hotkey (macOS-Shortcuts-App) sind Teil des Lieferumfangs.

**Use-Case:** Formatierten Text aus Webbrowsern, Claude Desktop, Word, Notion etc. mit einem Klick / Tastendruck in sauberes Markdown verwandeln, um ihn dann irgendwo einfügen zu können, wo Markdown erwartet wird.

---

## Nicht-verhandelbare Eigenschaften

- **Bash-Skript als Kern.** Glue-Logik um bestehende CLIs (`pbpaste`, `pbcopy`, `pandoc`, `textutil`, plus ein kleiner Swift-Helper).
- **Erst Konvertieren, dann ersetzen.** `--replace` ist Opt-in, nicht Default. Niemals destruktiv ohne Flag.
- **Verlustarm.** Inline-Whitespace, Code-Block-Struktur und Listen müssen erhalten bleiben.
- **macOS-only in v1.0.** Linux/Windows später, wenn überhaupt.
- **Keine Telemetrie, keine Cloud.**

---

## Spike-Ergebnisse (validiert, nicht neu herleiten)

### Was funktioniert

- **HTML aus Clipboard via Swift-Helper:** NSPasteboard liefert direkt den `public.html`-Flavor. Helper: ~15 Zeilen Swift, einmal kompilieren, danach Plain-Binary.
- **HTML → Markdown via pandoc:** Mit `-f html -t gfm-raw_html --wrap=none` und vorgeschaltetem Preprocessor liefert pandoc brauchbares Markdown auch aus modernem Tailwind-Inline-Style-HTML (Claude Desktop, Notion, Webbrowser).
- **RTF → Markdown via textutil + pandoc:** `textutil -convert html -format rtf` wandelt RTF zuerst in HTML, dann pandoc weiter. Funktioniert für Office, Pages, TextEdit.

### Was nicht funktioniert (Fallen, die wir umgangen haben)

1. **Pandoc kann RTF nicht als Input lesen.** RTF ist nur ein *Writer* in pandoc, kein Reader. `pandoc -f rtf` wirft `Unknown reader: rtf`. Deshalb der Umweg über `textutil`.
2. **`pbpaste` kann kein HTML.** Die `-Prefer`-Flag akzeptiert nur `ascii | rtf | ps`, kein HTML. Für HTML-Zugriff aus Bash braucht es entweder den hässlichen `osascript -e 'the clipboard as «class HTML»'`-Hex-Weg oder einen kleinen Swift-Helper. Der Helper ist sauberer und schneller.
3. **Moderne Electron-Apps liefern oft nur HTML, kein RTF.** Beispielmessung mit Claude Desktop: HTML 107 KB, RTF 0 Bytes. HTML muss daher *primärer* Pfad sein, nicht Fallback.
4. **Claude Desktop kodiert Code-Blöcke als CSS-Grid mit Subgrid.** Jede Zeile ist ein `<div data-line="N">` ohne `<br>` oder `\n` im DOM. Ohne Preprocessor produziert pandoc einen einzelnen langen String statt Mehrzeiler. Preprocessor unwrappt die Divs und fügt echte Newlines ein.
5. **Claude Desktop nutzt `<span> </span>` mit einem Leerzeichen für signifikanten Whitespace** zwischen Inline-Elementen. Ein zu aggressiver Span-Cleaner (`<span>...</span>` ersatzlos entfernen) zerstört das. Der Cleaner muss den Inhalt erhalten — auch wenn der Inhalt nur ein Leerzeichen ist.
6. **`<div>` innerhalb von `<code>` ist HTML-illegal**, kommt aber bei Claude Desktop vor. Pandoc fällt in dem Fall auf Indent-Style-Code zurück statt fenced.

### Akzeptierte Limitationen

- **Code-Blöcke kommen als 4-Space-Indent statt ` ``` `-fenced.** Valides Markdown, jeder Renderer interpretiert es korrekt. Versuche, Pandoc zu Fenced zu zwingen, haben im Spike nichts geändert. Kein Blocker. Wenn das später stört: Post-Processor mit awk, der zusammenhängende Indent-Blöcke in Fences umwandelt (Risiko: Listen-Continuation wird zu Code).
- **Sprachannotation für Code-Blöcke geht verloren.** Claude Desktop und viele andere Quellen schicken keinen `class="language-xyz"` mit, daher kann pandoc keine Sprache annotieren. Akzeptiert.
- **Bilder gehen verloren.** RTF-Embeds und HTML-Images werden nicht extrahiert. Phase-5-Thema, nicht v1.0.

---

## Architektur

```
┌─────────────────────────────────────┐
│ Dock-App (Automator)                │
│ Hotkey (macOS-Shortcuts)            │
└──────────────┬──────────────────────┘
               │ ruft auf
               ▼
┌─────────────────────────────────────┐
│ bin/md-clip   (Bash, ~150 Zeilen)   │
│  - Flag-Parsing                     │
│  - Clipboard-Flavor erkennen        │
│  - HTML/RTF/Plain-Pfad wählen       │
│  - Preprocessor + Cleaner anwenden  │
│  - pandoc/textutil aufrufen         │
│  - stdout ODER pbcopy               │
└──────────────┬──────────────────────┘
               │ nutzt
       ┌───────┴────────┬──────────────┐
       ▼                ▼              ▼
  helpers/        pandoc          textutil
  clipboard-      (HTML → MD,     (RTF → HTML)
  html (Swift)    via stdin)
  (HTML aus
   NSPasteboard)
```

**Datenfluss-Prioritäten in der Auto-Detection:**

1. HTML auf Clipboard? → `clipboard-html` → Preprocessor → Cleaner → pandoc html→gfm
2. Sonst RTF? → `pbpaste -Prefer rtf` → `textutil rtf→html` → Cleaner → pandoc html→gfm
3. Sonst Plain Text? → `pbpaste` → durchreichen (keine Konvertierung)
4. Sonst → Exit 1

---

## CLI-Spezifikation

```
md-clip [OPTIONS]

Optionen:
  -r, --replace        Clipboard mit dem Markdown-Output ersetzen
  -p, --plain          Plain-Text-Modus: kein Convert, nur Clipboard-Inhalt
                       als Plain-Text durchreichen (entspricht "Paste as
                       Plain Text"). Mit --replace ersetzt Plain Text das
                       Clipboard, alle Format-Flavors gehen verloren.
  -f, --from FORMAT    Eingabe-Format erzwingen: auto|html|rtf|plain
                       (default: auto)
  -t, --to FORMAT      Pandoc-Ziel-Dialekt: gfm|markdown|commonmark
                       (default: gfm)
  -q, --quiet          Keine Statusausgabe auf stderr
  -n, --notify         macOS-Notification bei Erfolg (für Wrapper-Aufrufe)
  -V, --verbose        Diagnose-Output (welche Flavors, welcher Pfad)
  -v, --version
  -h, --help

Exit-Codes:
  0  Erfolg
  1  Nichts Konvertierbares auf dem Clipboard
  2  Dependency fehlt (pandoc, textutil, Swift-Helper)
  3  Konvertierungsfehler (pandoc o.ä. mit non-zero exit)
```

**Verhalten in Details:**

- Standard-Aufruf `md-clip` ohne Flags: Konvertiert, schreibt Markdown nach stdout.
- `md-clip --replace`: Konvertiert, setzt Markdown ins Clipboard, kein stdout-Output.
- `md-clip --plain`: Holt `pbpaste` (UTF-8 Plain), schreibt nach stdout. Nützlich als Alternative zu `pbpaste`-direkt, wenn man später Whitespace-Normalisierung dazumontiert.
- `md-clip --plain --replace`: Plain-Text-Variante wird zurück ins Clipboard geschrieben. Effekt: alle Rich-Flavors verschwinden, nur noch Plain bleibt. Das ist die *eigentliche* macOS-`Paste-as-Plain-Text`-Funktion als CLI.
- Bei Verbose: Vor jedem Schritt eine Zeile auf stderr (Flavor-Detection, gewählter Pfad, Pandoc-Aufruf).

---

## Implementierung — fertige Bausteine aus dem Spike

### 1. `helpers/clipboard-html.swift`

```swift
// helpers/clipboard-html.swift
// Holt den HTML-Flavor aus dem macOS-Clipboard (public.html UTI) und
// schreibt ihn nach stdout. Exit 1, wenn kein HTML vorhanden ist.
//
// Warum dieser Helper? `pbpaste -Prefer` unterstützt keine HTML-Ausgabe,
// und der `osascript`-Hex-Weg ist hässlich + langsam. NSPasteboard direkt
// abfragen ist die saubere Lösung — kostet uns 15 Zeilen Swift.
//
// Build (einmal beim Setup):
//   swiftc helpers/clipboard-html.swift -o helpers/clipboard-html
//
// Aufruf aus dem Bash-Skript:
//   html=$(helpers/clipboard-html) || handle-error

import AppKit  // Für NSPasteboard. Bringt AppKit als Dependency rein,
                // aber Swift CommandLineTools (kein Xcode) reichen.

// Das System-weite Clipboard, in macOS-API "general pasteboard" genannt.
let pb = NSPasteboard.general

// .html ist die typsichere Konstante für "public.html" UTI.
// Liefert nil, wenn dieser Flavor nicht auf dem Clipboard liegt.
if let html = pb.string(forType: .html) {
    print(html)
    exit(0)
} else {
    // FileHandle.standardError, weil print() nach stdout schreibt.
    // Wir wollen die Fehlermeldung getrennt halten, damit der Aufrufer
    // stdout sauber per `html=$(...)` einsammeln kann.
    FileHandle.standardError.write("Kein HTML auf dem Clipboard.\n".data(using: .utf8)!)
    exit(1)
}
```

### 2. Preprocessor- und Cleaner-Funktionen (Bash, aus dem Spike)

Diese gehören in `bin/md-clip` als Hilfsfunktionen.

```bash
# Schritt 1: Claude-Desktop- und Tailwind-spezifische HTML-Strukturen normalisieren.
# Diese Funktion ist die wichtigste Erkenntnis aus dem Spike — ohne sie kommen
# Code-Blöcke aus Electron-Apps als ein einziger zusammengeklatschter String raus.
preprocess_claude_desktop() {
  # 1a. <div data-line="N">INHALT</div> → INHALT + echtes Newline.
  #     Claude Desktop kodiert Code-Zeilen als CSS-Subgrid-Divs OHNE \n im DOM.
  #     Diese Regel macht aus dem visuellen CSS-Layout echte Plain-Text-Zeilen.
  perl -0pe 's{<div\s+data-line="[^"]*"[^>]*>(.*?)</div>}{$1\n}gs' \
    | \
  # 1b. ALLE übrigen <div>/<\/div> innerhalb <pre>...</pre> entfernen.
  #     Vor allem das umschließende <div data-content>. Damit sieht pandoc
  #     einen sauberen <pre><code>...</code></pre>-Block ohne illegale Verschachtelung.
  #     /s = Dot matcht auch Newlines. /e = Replacement ist Perl-Code, nicht String.
  perl -0pe '
    s{(<pre[^>]*>.*?</pre>)}{
      my $block = $1;
      $block =~ s{</?div[^>]*>}{}g;
      $block;
    }gse' \
    | \
  # 1c. style="..."-Attribute komplett entfernen.
  #     Tailwind packt 1-2 KB Inline-CSS an JEDES Element, alles ohne semantischen Wert.
  perl -0pe 's/\s+style="[^"]*"//g' \
    | \
  # 1d. data-*-Attribute entfernen (data-file, data-line-type, data-tw-*).
  #     Reines Rauschen, niemand nutzt das in der Markdown-Konvertierung.
  perl -0pe 's/\s+data-[a-z-]+="[^"]*"//g'
}

# Schritt 2: <span>-Wrapper um reinen Text auflösen.
# Wichtig: ([^<]*) matcht auch ein einzelnes Leerzeichen.
# Claude Desktop nutzt <span> </span> als Whitespace zwischen Inline-Elementen —
# der Inhalt (incl. Leerzeichen) muss erhalten bleiben.
# Zweimal laufen lassen, weil sed nicht greedy-nicht-überlappend matcht
# und einfache Verschachtelung damit auflöst.
clean_html() {
  sed -E 's/<span[^>]*>([^<]*)<\/span>/\1/g' \
    | sed -E 's/<span[^>]*>([^<]*)<\/span>/\1/g'
}
```

### 3. Pandoc-Aufruf (validierte Optionen)

```bash
# -f html         : HTML als Input.
# -t gfm-raw_html : GitHub-Flavored Markdown als Output, mit deaktivierter
#                   raw_html-Extension. Konsequenz: HTML-Tags, die nicht in
#                   Markdown abbildbar sind, werden VERWORFEN statt durchgereicht.
#                   Killt das Hauptproblem mit Tailwind-Tag-Müll im Output.
# --wrap=none     : Kein automatischer Zeilenumbruch bei ~78 Zeichen.
#                   Pandocs Auto-Wrap stört bei Markdown-zu-Markdown-Roundtrips.
PANDOC_OPTS=(-f html -t gfm-raw_html --wrap=none)

pandoc "${PANDOC_OPTS[@]}"  # liest stdin, schreibt stdout
```

### 4. RTF-Pfad

```bash
# textutil ist macOS-Bordmittel seit 10.4. Kein Brew-Install nötig.
# Wandelt RTF in HTML; danach geht's denselben Weg wie HTML-Direkt.
echo "$rtf_content" \
  | textutil -convert html -format rtf -stdin -stdout \
  | clean_html \
  | pandoc "${PANDOC_OPTS[@]}"
```

### 5. Vollständiges Spike-Skript zur Referenz

Das funktionierende Spike-Skript, auf dem alle obigen Erkenntnisse basieren, sah am Ende so aus (kann als Basis für `bin/md-clip` dienen):

```bash
#!/usr/bin/env bash
set -euo pipefail

HTML_HELPER="$(dirname "$0")/clipboard-html"
PANDOC_OPTS=(-f html -t gfm-raw_html --wrap=none)

preprocess_claude_desktop() {
  perl -0pe 's{<div\s+data-line="[^"]*"[^>]*>(.*?)</div>}{$1\n}gs' \
    | perl -0pe '
        s{(<pre[^>]*>.*?</pre>)}{
          my $block = $1;
          $block =~ s{</?div[^>]*>}{}g;
          $block;
        }gse' \
    | perl -0pe 's/\s+style="[^"]*"//g' \
    | perl -0pe 's/\s+data-[a-z-]+="[^"]*"//g'
}

clean_html() {
  sed -E 's/<span[^>]*>([^<]*)<\/span>/\1/g' \
    | sed -E 's/<span[^>]*>([^<]*)<\/span>/\1/g'
}

# HTML-Pfad zuerst (häufigster Fall).
if html=$("$HTML_HELPER" 2>/dev/null); then
  echo "$html" \
    | preprocess_claude_desktop \
    | clean_html \
    | pandoc "${PANDOC_OPTS[@]}"
  exit 0
fi

# RTF-Fallback.
rtf=$(pbpaste -Prefer rtf)
if [ -n "$rtf" ]; then
  echo "$rtf" \
    | textutil -convert html -format rtf -stdin -stdout \
    | clean_html \
    | pandoc "${PANDOC_OPTS[@]}"
  exit 0
fi

# Plain-Text-Durchreichung.
plain=$(pbpaste)
if [ -n "$plain" ]; then
  echo "$plain"
  exit 0
fi

exit 1
```

Phase 1 erweitert das um Flag-Parsing, `--replace`, sauberes Error-Handling, `--help`, Verbose-Modus, Notification-Hook.

---

## Projekt-Struktur

```
md-clip/
├── BLUEPRINT.md                 # dieses Dokument
├── README.md                    # Nutzer-Doku (kurz, mit Installations-Anleitung)
├── LICENSE                      # MIT
├── Brewfile                     # pandoc als Dependency
├── bin/
│   └── md-clip                  # Hauptskript (Bash), ausführbar
├── helpers/
│   ├── clipboard-html.swift     # Source (committen)
│   └── clipboard-html           # Kompiliertes Binary (nicht committen — .gitignore)
├── wrappers/
│   ├── md-clip.app/             # Automator-Bundle für Dock
│   └── ClipboardToMarkdown.shortcut  # Exportierter macOS-Shortcut für Hotkey
├── tests/
│   ├── fixtures/                # *.html, *.rtf, expected *.md
│   │   ├── claude-desktop-codeblock.html
│   │   ├── claude-desktop-codeblock.expected.md
│   │   ├── safari-article.html
│   │   ├── word-rtf.rtf
│   │   └── plain.txt
│   └── run-tests.sh             # Vergleicht md-clip-Output gegen expected.md
├── install.sh                   # Kompiliert clipboard-html, symlinkt
│                                # bin/md-clip nach /usr/local/bin/md-clip
└── .gitignore                   # helpers/clipboard-html, .DS_Store
```

---

## Wrapper

### Dock-App (Automator)

1. Automator → Neu → Dokument-Typ **"Programm"** (nicht "Workflow").
2. Eine Aktion **"Shell-Skript ausführen"** mit:
   ```bash
   /usr/local/bin/md-clip --replace --notify || \
     osascript -e 'display notification "Clipboard nicht konvertierbar" with title "md-clip"'
   ```
3. Speichern als `md-clip.app` in `wrappers/`.
4. Eigenes Icon zuweisen (rechts-Click → Informationen → Icon einsetzen).
5. App ins Dock ziehen.

### Hotkey (macOS-Shortcuts.app)

1. Shortcuts.app öffnen → Neuer Shortcut → "Clipboard → Markdown".
2. Aktion **"Shell-Skript ausführen"** mit identischem Befehl wie oben.
3. In Shortcut-Settings einen Tastatur-Shortcut vergeben. Vorschlag: `⌃⌥⌘M` (Control-Option-Cmd-M).
4. Aus Shortcuts.app als `.shortcut`-Datei exportieren und nach `wrappers/` legen.

---

## Roadmap

### Phase 0 · Spike — ✅ abgeschlossen
Architektur validiert, Pandoc+Preprocessor liefert brauchbares Markdown auch aus Claude Desktops Subgrid-HTML. Lessons Learned dokumentiert (siehe oben).

### Phase 1 · MVP-CLI — **als Nächstes**
Vollständiges `bin/md-clip`-Skript mit allen Flags aus der CLI-Spec, sauberer Fehlerbehandlung, `--help`-Text. `helpers/clipboard-html.swift` einkompiliert via `install.sh`. Drei Test-Fixtures in `tests/fixtures/` + `run-tests.sh`. README. Aufwand: halber Tag.

### Phase 2 · Wrapper
Automator-App + macOS-Shortcut bauen und in `wrappers/` committen. README ergänzen um Setup-Anleitung. Aufwand: 1–2 Stunden.

### Phase 3 · Quality
- Heuristische Code-Block-Sprach-Erkennung (z.B. an Shebang, Keywords)
- Post-Processor für Indent→Fenced-Konvertierung (optional)
- Bessere Whitespace-Normalisierung im `--plain`-Modus
- Eventuell `htmltomarkdown` (Go) als alternative Engine

### Phase 4 · Distribution
- Homebrew-Tap, optional via GitHub
- Signiertes `.app`-Bundle
- Donationware?

### Phase 5 · Extras (offen)
- Bild-Extraktion (RTF-Embeds, HTML-Images → lokale Datei + `![]()`-Link)
- Linux-Port (xclip statt pbpaste, Swift-Helper durch python-pyobjc-Äquivalent ersetzen — oder direkt Go-Rewrite)

---

## Offene Designfragen für die nächste Session

Vor Phase 1 zu klären (oder vom Implementierer pragmatisch zu entscheiden):

1. **Naming final?** `md-clip` ist okay, aber `clipmd` (kürzer fürs Tippen) oder `pbmd` (analog zu `pbpaste`/`pbcopy`) sind Alternativen. Vorschlag: bei `md-clip` bleiben.
2. **Notification-Default?** Bei Hotkey-Aufruf will man oft *keine* Notification (Workflow-Interrupt). Vorschlag: Notification standardmäßig **aus**, `--notify` als Opt-in für Wrapper.
3. **Plain-Modus mit Whitespace-Reinigung?** NBSP→Space, weiche Bindestriche entfernen, mehrfache Leerzeilen kollabieren? Vorschlag: in Phase 1 *kein* Cleaning, nur durchreichen. Cleaning in Phase 3.
4. **Distribution-Form?** Homebrew-Tap (sauber, mehr Wartung) vs. GitHub-Release mit `install.sh` per curl (einfacher). Phase 1: nur `install.sh` lokal. Brew kommt in Phase 4.

---

## Dependencies-Übersicht

| Komponente | Quelle | Pflicht? | Größe |
|---|---|---|---|
| `pandoc` | Homebrew (`brew install pandoc`) | ja | ~150 MB |
| `textutil` | macOS-Bordmittel (seit 10.4) | ja | 0 (vorhanden) |
| `pbpaste` / `pbcopy` | macOS-Bordmittel | ja | 0 (vorhanden) |
| `osascript` | macOS-Bordmittel | ja | 0 (vorhanden) |
| Swift CommandLineTools | `xcode-select --install` | für Build | ~500 MB einmalig |
| `perl` 5.x | macOS-Bordmittel | ja | 0 (vorhanden) |
| `sed`, `awk`, `bash` | macOS-Bordmittel | ja | 0 (vorhanden) |

**Brewfile:**

```ruby
brew "pandoc"
```

---

## Auftrag für die Implementierungs-Session (One-Shot-Prompt)

> Lies `BLUEPRINT.md` komplett. Implementiere dann **Phase 1** (MVP-CLI) wie dort beschrieben.
>
> Konkret:
> 1. Projekt-Struktur anlegen (`bin/`, `helpers/`, `tests/`, `install.sh`, `README.md`, `.gitignore`, `Brewfile`).
> 2. `helpers/clipboard-html.swift` aus dem Blueprint übernehmen.
> 3. `bin/md-clip` als vollständiges Bash-Skript implementieren mit:
>    - Allen Flags aus der CLI-Spezifikation
>    - Den Preprocessor- und Cleaner-Funktionen aus dem Blueprint
>    - Sauberer Fehlerbehandlung (Exit-Codes 0/1/2/3)
>    - `--help`-Text
>    - Verbose-Modus
> 4. `install.sh` schreiben: kompiliert `clipboard-html`, prüft pandoc-Verfügbarkeit, symlinkt `bin/md-clip` nach `/usr/local/bin/md-clip`.
> 5. Drei Test-Fixtures in `tests/fixtures/` anlegen (Claude-Desktop-Code-Block, einfache HTML-Webseite, Word-RTF) plus erwarteten Output und ein `run-tests.sh`, das die Konvertierung gegen die Fixtures prüft.
> 6. README mit kurzer Setup-Anleitung und Beispielen.
>
> Hinweise:
> - macOS-only ist Vorgabe, Linux/Windows-Kompatibilität nicht beachten.
> - Code in Bash und Swift bitte ausführlich kommentieren, sodass Anfänger ihn nachvollziehen können.
> - Alle Spike-Erkenntnisse stehen im Blueprint — nicht neu validieren.
> - Wenn etwas im Blueprint widersprüchlich oder unklar ist: nachfragen, nicht raten.
