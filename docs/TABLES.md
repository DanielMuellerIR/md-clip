# Komplexe Tabellen

`md-clip --tables text` ist eine ausdrücklich gewählte Vereinfachung für
verbundene Zellen und verschachtelte Tabellen. Der Standard `reject` bleibt
unverändert. Alle drei Ziele (`gfm`, `markdown`, `commonmark`) verwenden dieselbe
Textdarstellung. `--strict` lehnt sie vor der Ausgabe ab.

## Darstellungsvertrag

Eine komplexe Außentabelle wird vollständig in einen Zitatblock umgewandelt.
Ihre Tabellenüberschrift bleibt mit ihrer Auszeichnung erhalten. Die neu
hinzugefügten Beschriftungen sind fett, keine Markdown-Überschriften.

- Nummern zählen die als Text dargestellten Tabellen in ihrer Reihenfolge,
  einschließlich verschachtelter Tabellen. Einfache Tabellen außerhalb davon
  bleiben Tabellen und werden nicht mitgezählt.
- Zeilennummern beginnen je Tabelle bei 1 und laufen über Kopf, Tabellenkörper
  und Fuß weiter. Vorhandene Gruppen und Zwischenköpfe werden benannt; die erste
  Datenzeile wird nicht künstlich zum Tabellenkopf erklärt.
- Spalten werden ab 1 nummeriert. Verbundene Zellen nennen Spaltenbereiche und
  bei mehreren belegten Zeilen auch den Zeilenbereich.
- Der Zellinhalt erscheint genau einmal, an seiner Ursprungsposition. Spätere
  belegte Zeilen enthalten eine ausdrücklich beschriftete Fortsetzung mit der
  Ursprungskoordinate. Eine leere Ursprungszelle erscheint als „(leere Zelle)“.
- Absätze, Listen, Links, Hervorhebungen und Code bleiben Zellblöcke.
  Verschachtelte Tabellen erhalten an dieser Stelle einen eigenen Zitatblock
  und eigene Koordinaten, auch wenn sie selbst nur einfache Zellen enthalten.

Beispiel einer über zwei Zeilen verbundenen Zelle:

```text
Tabelle 1 — Textdarstellung (2 Spalten)
Zeile 1 (Tabellenkörper 1)
Spalte 1; Zeilen 1–2
Gemeinsamer Inhalt
Spalte 2
Erster Wert
Zeile 2 (Tabellenkörper 1)
Spalte 1: Fortsetzung aus Zeile 1, Spalte 1
Spalte 2
Zweiter Wert
```

## Grenzen und Fehler

Die Zuordnung verwendet pandocs geparste Matrix. Der HTML-Reader kann fehlerhaftes
HTML vorher reparieren, fehlende Zellen ergänzen oder Spannweiten begrenzen.
Die Textdarstellung rekonstruiert keine zuvor verworfenen Quellinformationen und
übernimmt keine HTML-Layoutmaße, Farben oder Ausrichtungen. Sie ist keine
allgemeine Garantie verlustfreier Rich-Text-Konvertierung.

Nicht positive, nicht numerische oder mehrfach angegebene `rowspan`-/`colspan`-
Attribute werden im Textmodus schon vor pandoc abgelehnt. Dazu gehört die
HTML-Sonderform `rowspan="0"`; sie wird nicht als Eins geraten. Positive
Dezimalzahlen mit Leerraum und numerischen HTML-Zeichenreferenzen sind zulässig.
Ein geparstes Raster mit Überlappungen, fehlenden Positionen oder Spannweiten
außerhalb seiner Zeilengruppe wird ebenfalls abgelehnt.

Im Textmodus wird die historische RTF-Layouttabellenreparatur übersprungen.
Dadurch bleibt die Matrix bis zur strukturellen Auswertung erhalten. Einfache
RTF-Tabellen erscheinen dann als Tabellen; der Standardmodus behält das bisherige
Layoutverhalten. Klartext wird in beiden Modi unverändert durchgereicht.

Eine tatsächliche Textdarstellung meldet `tables-text` samt Anzahl.
Uneindeutige Zuordnungen melden `table-ambiguous`. Explizit gewählte HTML-/RTF-
Quellen liefern bei Ablehnung Exit 3 ohne Nutzdaten oder Clipboard-Ersetzung;
im Auto-Modus gilt der dokumentierte Quellenrückfall. Eine vorbereitete
Undo-Sicherung wird bei Abbruch storniert.
