# Konvertierungsbericht

Die Pipeline meldet bekannte Vereinfachungen und strukturelle Ablehnungsgründe
getrennt vom erzeugten Markdown. Das CLI verwendet diese Informationen für
Statusmeldungen, Quellenrückfälle und `--strict`. Der Bericht ist eine interne
Schnittstelle, keine weitere Ausgabe auf stdout.

## Internes Format (Version 1)

`MD_CLIP_RESULT_FILE` bezeichnet eine private temporäre Datei des Aufrufers.
Jeder Datensatz hat genau das Format `kennung<TAB>anzahl<LF>`. Die Anzahl ist
eine positive Dezimalzahl mit höchstens neun Stellen. Der Bericht enthält keine
URLs, Dokumenttitel, Textausschnitte oder anderen Nutzinhalt.

Die CLI leert die Datei vor jedem Quellenversuch; Pipeline-Stufen hängen ihre
Datensätze an. Wiederholte Kennungen werden addiert. Fehlende Datensätze bedeuten
keinen gemeldeten Vorgang. Unbekannte Kennungen oder beschädigte Datensätze
verhindern die Übernahme des betreffenden Konvertierungsergebnisses.

| Kennung | Bedeutung der Anzahl |
|---|---|
| `table-cells-flattened` | Zellen, deren Blockstruktur oder Umbrüche zu Inline-Inhalt vereinfacht wurden |
| `layout-tables-flattened` | Entfernte RTF-Layouttabellen, einschließlich verschachtelter Tabellen darin |
| `tables-text` | Als beschrifteten Text dargestellte Tabellen, einschließlich darin verschachtelter Tabellen |
| `table-ambiguous` | Ablehnung nicht eindeutig zuordenbarer Zellpositionen oder Spannweiten |
| `table-nested` | Strukturelle Ablehnung einer verschachtelten Tabelle |
| `table-spanned` | Strukturelle Ablehnung verbundener Tabellenzellen |
| `empty-document` | Dokument ohne sichtbaren darstellbaren Inhalt |
| `rtf-header-invalid` | Als RTF deklarierte Quelle ohne erkannten RTF-1-Kopf; vor dem Reader abgelehnt |
| `images-alt` | Nach Quellenbereinigung auf Alternativtext reduzierte Bildknoten, auch bei leerem Alternativtext |
| `images-omitted` | Nach Quellenbereinigung entfernte Bildknoten |

Bei einer frühzeitigen Ablehnung beschreiben Anzahlen nur die bis zum Abbruch
erkannten Vorgänge. Sie sind keine vollständige Bestandsaufnahme der Eingabe.
Neue Kennungen brauchen einen ausdrücklichen CLI-Handler und passende Tests.

Die RTF-Kopfprüfung liest nur die bereits erfasste Quelldatei und verändert sie
nicht. Sie prüft die grundlegende Sequenz `{\rtf1` mit einer Token-Grenze;
optionale UTF-8-BOM und führender ASCII-Whitespace sind zulässig. Sie ist keine
vollständige RTF-Syntaxprüfung: Der Plattformreader bewertet das weitere Dokument.
Datei/stdin und Clipboard verwenden dieselbe Prüfung. Expliziter Klartext wird
dadurch weder erkannt noch umgedeutet.
Die grundlegende Kopfsequenz ist in Microsofts
[Beschreibung des RTF-Dokumentkopfs](https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-oxrtfex/3cf14977-3883-404a-8ed8-57c99263fb76)
festgehalten.

## Strenger Modus

`--strict` setzt für die Pipeline `MD_CLIP_STRICT=1`; ohne die Option setzt die
CLI ausdrücklich `0`. Interne Umgebungswerte verändern den CLI-Modus nicht.
Direkte Pipeline-Aufrufer können die Variable selbst setzen.

Abgelehnt werden derzeit die Vereinfachung von Tabellenzellen für GFM/CommonMark,
das Auflösen von RTF-Layouttabellen und im Auto-Modus der Rückfall nach einem
gescheiterten nicht leeren Rich-Text-Angebot auf Klartext. Beim Ziel `markdown`
bleiben Zellblöcke als Gittertabelle erhalten und benötigen diese Vereinfachung
nicht. Auch unsichtbarer Inhalt eines vorhandenen Rich-Text-Angebots kann zum
Abbruch führen, wenn anschließend nur Klartext verfügbar wäre.

Ein erfolgreicher Wechsel HTML → RTF oder RTF → HTML bleibt zulässig, sofern
das gewählte Ergebnis keine der erkannten Vereinfachungen benötigt. Die CLI
nennt übersprungene Quellen, den Grund und die anschließend verwendete Quelle.
Sie vergleicht nicht, ob zwei unterschiedliche Angebote denselben Inhalt tragen.

Ursprünglicher Klartext und ausdrücklich gewähltes `--plain`/`--from plain`
bleiben bytegenau zulässig und brauchen weiterhin weder pandoc noch Perl.
`--images alt|omit` meldet Bildvereinfachungen über denselben Bericht. Strict
verweigert diese nur, wenn tatsächlich Bilder verändert würden; Dokumente ohne
Bilder bleiben zulässig. `keep` erhält bestehende Bildreferenzen auch im strengen
Modus. Leere Ergebnisse nach einer Bildvereinfachung werden ebenfalls abgelehnt.
`--tables text` setzt intern `MD_CLIP_TABLES=text`, der Standard ist `reject`.
Die CLI überschreibt geerbte Werte. Die Textdarstellung komplexer Tabellen wird
als `tables-text` gemeldet; Strict verweigert sie unabhängig vom Zielformat.
Die RTF-Layoutreparatur wird im Textmodus übersprungen. Einfache Tabellen bleiben
zulässig, sofern keine andere bekannte Vereinfachung erforderlich ist.
Siehe [TABLES.md](TABLES.md) für den Darstellungsvertrag.
Strict ist keine allgemeine Garantie verlustfreier Markdown-Darstellung.

Abgelehnte Konvertierungen liefern Exit 3, geben keine Nutzdaten aus und schreiben
nicht ins Clipboard. Eine vorbereitete Undo-Sicherung wird storniert; ein früheres
gültiges Undo wird dadurch nicht verbraucht. Details erscheinen vor einer
Terminal-Vorschau. `--quiet` unterdrückt Hinweise, aber keine Fehlermeldungen.
