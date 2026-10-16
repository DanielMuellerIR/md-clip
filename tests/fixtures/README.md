# Kleiner Quellenkorpus

Die Beispiele enthalten neutrale Texte und öffentliche Linkziele. Sie bilden
wichtige Quellenstrukturen ab, ohne eine vollständige Sammlung realer Dokumente
oder bestimmter Programmversionen zu behaupten. Die ursprüngliche Erfassungs-
umgebung ist nicht für jede Datei belegt.

| Beispiel | Abgedeckter Fall | Herkunftsgrenze |
|---|---|---|
| safari-article.html | Artikel mit Überschrift, Link, Liste, Zitat und Unicode | Neutrales HTML ohne browserspezifische Metadaten; kein Beleg einer bestimmten Safari-Version |
| word-rtf.rtf | RTF mit Fett/Kursiv, Liste, Umlauten und Absatzumbrüchen | Enthält Cocoa-RTF-Metadaten; keine belegte originale Word-Datei |
| claude-desktop-codeblock.html | Code mit data-line-Divs, Subgrid und Span-Auszeichnung | Kleines Beispiel der Quellenstruktur; keine behauptete vollständige Originalaufnahme |
| google-classroom-links.html | Attachment-Container, Titelklassen, Thumbnail und authuser-Links | Quellenstruktur mit anonymisierten langen Kennungen; öffentliche Technik-Linkziele bleiben erhalten |

Die bestehenden `*.expected.md` sind gemeinsame Erwartungen für macOS und Linux.
Sie werden nicht automatisch neu geschrieben. Insbesondere sind die zwei
Leerzeichen vor Hard-Breaks ein Prüfgegenstand.

`test-html-normalization.py` variiert Quotes, Attributreihenfolge und -schreibweise,
mehrzeilige Attribute, Kommentare sowie Code und prüft den geparsten Roundtrip.
Die Bild- und Tabellenmodusprüfungen ergänzen synthetische Grenzfälle mit eigenen
Inhaltsinvarianten. Reale komplexe Word-Bild-/Tabellenoriginale fehlen weiterhin;
dies ist eine Abnahmelücke, kein durch synthetische Tests ersetzter Originalbeleg.
