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
| `table-nested` | Strukturelle Ablehnung einer verschachtelten Tabelle |
| `table-spanned` | Strukturelle Ablehnung verbundener Tabellenzellen |
| `empty-document` | Dokument ohne sichtbaren darstellbaren Inhalt |

Bei einer frühzeitigen Ablehnung beschreiben Anzahlen nur die bis zum Abbruch
erkannten Vorgänge. Sie sind keine vollständige Bestandsaufnahme der Eingabe.
Neue Kennungen brauchen einen ausdrücklichen CLI-Handler und passende Tests.

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
Strict ist keine allgemeine Garantie verlustfreier Markdown-Darstellung.

Abgelehnte Konvertierungen liefern Exit 3, geben keine Nutzdaten aus und schreiben
nicht ins Clipboard. Eine vorbereitete Undo-Sicherung wird storniert; ein früheres
gültiges Undo wird dadurch nicht verbraucht. Details erscheinen vor einer
Terminal-Vorschau. `--quiet` unterdrückt Hinweise, aber keine Fehlermeldungen.
