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

Zusätzliche private Prüfungen verwenden bereinigte Ableitungen vorhandener
Browser-HTML- und Textverarbeitungs-/RTF-Aufnahmen. Text und Linkziele werden
neutralisiert, persönliche Metadaten und eingebettete RTF-Bilder entfernt;
HTML-/RTF-Strukturen bleiben die Grundlage der Prüfung. Solche Ableitungen
belegen weder eine bestimmte Programmversion noch den ursprünglichen Bildinhalt.
Originaldateien und Betriebsbelege gehören nicht ins öffentliche Repository.

Für jeden tatsächlich geprüften Stand werden Absatzgruppen, Listen außerhalb
von Tabellen, Linkziele, Code und Bildreferenzen sowie Tabellenzellen nach dem
Markdown-Roundtrip verglichen. Dokumentierte Tabellenvereinfachungen werden
separat ausgewiesen und gegen `--strict` geprüft. Ein fehlender historischer
Mitschnitt wird als Lücke festgehalten und nicht synthetisch nachgebildet.

Prüfungen am allgemeinen Clipboard benötigen eine vollständige RAM-Sicherung
aller Items und Formate sowie Generationskontrolle. Unbekannte Bytes sind kein
Beweis einer fremden Kopie: Die Sicherung bleibt bis zur ausdrücklichen Klärung
erhalten, ohne den unbekannten Zustand zu überschreiben. EOF, Abbruch und
Controllerverlust müssen zuvor auf privaten Pasteboards geprüft werden.
Dateiprüfungen ohne `--replace` und Fixtures mit `MD_CLIP_SKIP_CLIPBOARD=1`
benötigen diesen Zugriff nicht.
