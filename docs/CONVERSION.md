# Was bei der Konvertierung erhalten bleibt

`md-clip` verarbeitet das angebotene HTML, RTF oder Klartext. Die sichtbare
Ausgangsansicht allein sagt nicht, welche Informationen das kopierende Programm
in diesen Formaten ablegt. `--strict` prüft bekannte Vereinfachungen und
Quellenrückfälle; es garantiert keine verlustfreie Kopie der Ausgangsansicht.

## Quelle gezielt wählen

| Eingabe | Verhalten von `auto` |
|---|---|
| Clipboard | HTML → RTF → Klartext; bei erkanntem Microsoft-Word-HTML RTF → HTML → Klartext |
| Datei | Format aus `.html`, `.htm`, `.rtf`, `.txt` oder `.md`; kein Wechsel auf eine andere Datei |
| stdin | `auto` ist nicht zulässig; `--from html\|rtf\|plain` oder `--plain` angeben |

Clipboard-Auto verwendet den ersten erfolgreichen Versuch. Ein nicht verfügbares,
leeres oder abgelehntes Angebot wird übersprungen. Auto vergleicht weder die
Inhalte der Angebote noch deren Ähnlichkeit mit der Ausgangsansicht.
Ein vorhandenes HTML-Angebot kann beispielsweise Codeblöcke enthalten, während
das gleichzeitig angebotene RTF dieselben Zeilen nur als normalen Text beschreibt.

`--from html` und `--from rtf` wählen genau dieses Format. Scheitert es, wird
keine andere Quelle versucht. `--from` wählt keinen bestimmten Programm-Reader:
RTF wird auf macOS über `textutil` zu HTML, auf Linux über pandoc zu HTML gelesen.
`--from plain` und `--plain` reichen Klartext bytegenau durch.

```bash
md-clip --verbose                  # gewählte Clipboard-Quelle auf stderr
md-clip --from html                # nur das HTML-Angebot, Ausgabe auf stdout
md-clip --input kopie.rtf --from rtf
```

Ohne `--replace` schreiben diese Aufrufe nicht ins Clipboard. Datei/stdin ohne
`--replace` benötigen auch beim Lesen keine Clipboard-Werkzeuge.

## Wo Unterschiede entstehen

| Stufe | Beispiel und Bedeutung |
|---|---|
| Kopierendes Programm | RTF enthält keinen Linktitel oder kein eingebettetes Bild mehr. md-clip kann fehlende Daten nicht ergänzen. |
| Reader | `textutil` beziehungsweise pandoc liest RTF und liefert HTML; Code-Semantik, Listenstart oder Bilddaten können dabei fehlen. HTML-Reader können fehlerhafte Tabellen reparieren. |
| md-clip-Pipeline | Bekannte Tabellenvereinfachungen und `--images alt\|omit` werden mit Grund und Anzahl gemeldet und von Strict abgelehnt. Quellenreparaturen etwa für Classroom-Anhänge sind davon getrennt. |
| Markdown-Ausgabe | Codezäune, Escapes und Tabellenform können je nach Ziel und pandoc-Version anders aussehen. Entscheidend ist der dargestellte Inhalt, nicht eine identische Markdown-Schreibweise. |

Ein fehlender Hinweis bedeutet nur, dass keine der erfassten Vereinfachungen
gemeldet wurde. md-clip vergleicht das Ergebnis nicht automatisch mit dem
ursprünglichen Dokument. Auch ein erfolgreicher Wechsel HTML → RTF kann daher
andere Details liefern. `--verbose` hilft bei der Zuordnung, ersetzt diesen
Inhaltsvergleich aber nicht.

## HTML, RTF und Klartext im Vergleich

| Inhalt | Geprüfter HTML-Weg | Grenze bei RTF/Klartext |
|---|---|---|
| Absätze und Listen | Absatzgruppen, verschachtelte Listen und ein nummerierter Start ab 3 sind in neutralen Kopierproben erhalten. | Bereits die angebotene RTF-Quelle oder der Reader kann Absatzgruppen verbinden oder den Listenstart verlieren. Klartext enthält keine verlässlich rekonstruierbare Listenstruktur. |
| Sprachloser Code | `<pre><code>` sowie vollständige reine Text-`pre`-Blöcke erhalten Codeinhalt, Einrückung und Backslashes, auch in Listen. | RTF-Einrückung allein ist kein Codebeleg. md-clip rät weder Codeblöcke noch eine Programmiersprache. |
| Links | Ziel und vorhandener Titel bleiben aus dem gelesenen HTML erhalten. | Ein beim Kopieren fehlender RTF-Linktitel kann nicht rekonstruiert werden. |
| Bilder | Referenzen, data-URLs und Inline-SVG werden mit `--images keep` erhalten. | Ein vor dem Writer fehlendes RTF-Bild bleibt fehlend. `keep` extrahiert keine Word-Bilder und kopiert keine externen Bilddateien. |
| Tabellen | Einfache Tabellen bleiben Tabellen; komplexe Tabellen benötigen den ausdrücklich gewählten Textmodus. | Der Standard kann RTF-Layouttabellen in Absätze umwandeln. Der Textmodus erhält nur die vom Reader gelieferte Matrix. |

Die Praxisproben mit Version 1.10.15 stammen aus selbst verfassten neutralen
Dokumenten, tatsächlich aus Safari und TextEdit kopiert. Safari-HTML belegte
Code, Listenstart, Linktitel, Bildreferenz und einfache Tabellen. TextEdit-RTF
belegte auch verschachtelte Tabellen. Das sind keine Word-Originale und keine
Zusage für jedes Dokument oder jede Programmversion. Öffentliche kleine
Strukturbeispiele und ihre Herkunftsgrenzen stehen im
[Quellenkorpus](../tests/fixtures/README.md).

## Kleine Beispiele selbst prüfen

Die folgenden Eingaben sind synthetische Beispiele. Sie benötigen weder eine
Quell-App noch Clipboard-Zugriff und prüfen ausschließlich den HTML-Weg.

### Code ohne Sprachangabe in einer Liste

```bash
md-clip --stdin --from html <<'HTML'
<ul><li>Vorbereitung</li><li><pre><code>  printf '%s' \
    '\# Text'</code></pre></li></ul>
HTML
```

Der zweite Listenpunkt enthält einen Codeblock. Die beiden Zeilen behalten zwei
beziehungsweise vier führende Leerzeichen sowie die Backslashes. Eine Sprache
wird nicht hinzugefügt. Je nach Zielformat können Backtick- oder Tilde-Zäune
entstehen; das ändert den Codeinhalt nicht. Reine `pre`-Blöcke dürfen Text, Spans
und `br` enthalten. Links, Bilder, andere Rich-Inhalte sowie unvollständige oder
verschachtelte `pre`-Blöcke sind von dieser Code-Reparatur ausgenommen.

### Link und Bildreferenz

```bash
md-clip --stdin --from html <<'HTML'
<p><a href="https://example.com/handbuch" title="Handbuch">Lesen</a></p>
<p><img src="bild.png" alt="Blaues Quadrat"></p>
HTML
```

Das Ergebnis enthält den Link mit Ziel und Titel sowie die Referenz auf
`bild.png` mit Alternativtext. md-clip liest oder kopiert die Bilddatei dabei
nicht; sie muss im Zielkontext erreichbar sein. `--images alt` lässt stattdessen
„Blaues Quadrat“ stehen, `--images omit` entfernt das Bild. Beide sind gemeldete
Vereinfachungen und würden hier mit `--strict` abgelehnt. Fehlt ein Alternativtext,
kann `alt` das Bild ganz entfallen lassen. Ein Ergebnis ohne sichtbaren Inhalt
wird abgelehnt.

### Verschachtelte Tabelle

```bash
md-clip --stdin --from html --tables text <<'HTML'
<table><tr><td>Außen A</td><td>Außen B
<table><tr><td>Innen A</td><td>Innen B</td></tr></table>
</td></tr></table>
HTML
```

Die Textdarstellung nennt für beide Tabellen Zeile 1 und die Spalten 1/2. Die
innere Tabelle steht im Inhalt von Außenspalte 2; jeder Zelltext erscheint einmal.
Ohne `--tables text` wird diese explizite HTML-Quelle abgelehnt. Mit zusätzlichem
`--strict` wird auch die Textdarstellung abgelehnt: Exit 3 und keine Nutzdaten.
Spannweiten, leere Zellen und Zuordnungsgrenzen erklärt [TABLES.md](TABLES.md).

## Strict richtig einordnen

Strict verweigert bekannte Tabellen-/Bildvereinfachungen und den Rückfall von
einem gescheiterten vorhandenen Rich-Text-Angebot auf Klartext. Ein erfolgreicher
Wechsel zwischen HTML und RTF bleibt möglich. Ursprünglicher oder ausdrücklich
gewählter Klartext bleibt zulässig und bytegenau.

Ein Strict-Erfolg beweist weder gleiche HTML-/RTF-Angebote noch vollständige
Ausgangsdaten. Fehlt Code-Semantik, Listenstart, Linktitel oder Bild bereits in
der gelesenen Quelle, stellt Strict dies nicht wieder her. Kennungen, Anzahlen
und der Schreibschutz bei Ablehnung stehen in
[CONVERSION-REPORT.md](CONVERSION-REPORT.md).
