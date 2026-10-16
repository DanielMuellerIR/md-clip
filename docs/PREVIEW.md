# Native Vorschau

Die App-Aktion `--preview` setzt Version 1.10.0 voraus. Ein normaler App-Start
konvertiert weiterhin sofort. Ältere Launcher ignorieren Aktionsargumente;
den nativen Aufruf daher erst mit einer aktualisierten App verwenden.

```bash
open -n -a "md-clip" --args --preview
md-clip --stdin --from html --replace --preview-window < beispiel.html
```

Die CLI-Option `--preview` bleibt die bisherige Terminal-Abfrage.
`--preview-window` benötigt macOS, `--replace` und den kompilierten Vorschau-Helfer.
Sie ist mit Terminal-Vorschau, `--undo` und Doctor nicht kombinierbar. Unter Linux
wird sie vor Clipboard-Zugriff abgelehnt. Die CLI-Installation baut den Helfer;
die App bringt ihn mit.

## Bedienung und Schutz

- Das Fenster zeigt schreibgeschütztes, auswählbares Markdown. Lange Zeilen
  werden zur Anzeige umgebrochen; der Inhalt wird dadurch nicht verändert.
- Quelle, Zielformat, bekannte Vereinfachungen mit Anzahl und Quellenrückfälle
  bleiben sichtbar, auch bei `--quiet`. Längere Hinweise sind scrollbar.
- Übernehmen verwendet das einmal eingelesene und konvertierte Ergebnis. Es
  wird weder erneut gelesen noch beim Bestätigen erneut konvertiert.
- Abbrechen, Escape, Command-Q oder Schließen liefern Exit 4 ohne Ersetzung.
  Return bzw. Command-Return übernimmt eine gültige Vorbereitung.
- „Letzte Ersetzung zurücknehmen“ bzw. Command-Z storniert zuerst die eigene
  Vorbereitung und nimmt dann die vorige erfolgreiche Ersetzung zurück.
  Es führt keine neue Konvertierung aus.
- Statusprüfungen deaktivieren nicht mehr verfügbare Aktionen. Beim eigentlichen
  Schreiben prüft der Undo-Helfer die Generation und Frist erneut. Ein neuer
  Kopiervorgang verhindert damit auch zwischen zwei UI-Statusabfragen das Ersetzen.
- Kopieren aus der Vorschau ist eine normale neue Clipboard-Änderung und kann
  deshalb die Vorbereitung ebenfalls ungültig machen.

Eine Vorbereitung und eine erfolgreiche Undo-Sicherung gelten jeweils zehn
Minuten. Eine neue Ersetzung beginnt ihre eigene Rücknahmefrist. Die vorherige
Sicherung wird durch bloßes Vorbereiten/Abbrechen nicht verbraucht. Eine bereits
ältere laufende Helferversion ohne Statusprotokoll wird vor `prepare` erkannt;
vorhandenes Undo zuerst verwenden oder ablaufen lassen und anschließend erneut
starten. Die normale CLI-Konvertierung und CLI-Undo bleiben verfügbar.

Die Vorschau benötigt UTF-8 und akzeptiert höchstens 64 MiB. Nicht darstellbarer
binärer Klartext und leere Ergebnisse werden vor dem Schreiben abgelehnt.
Klartext ohne native Vorschau behält seinen bisherigen Vertrag. Bekannte
Strict-Ablehnungen erfolgen schon vor dem Öffnen; Strict ist keine allgemeine
Verlustfreiheitsgarantie. Reale exotische Word-Bild-/Tabellenoriginale sind nicht
vollständig durch den synthetischen Testkorpus abgedeckt.

## Interner Lebenszyklus

Die CLI hält Inhalt und Hinweise in privaten temporären Dateien. Inhalt wird
nicht über argv oder Statusausgaben transportiert. Das Fenster ist nicht editierbar;
das bereits vorbereitete Ergebnis bleibt bis zum Schreiben maßgeblich.

Der Undo-Helfer bietet intern `status [TOKEN]` mit JSON-Version 1:

```json
{"version":1,"undo_available":false,"pending_valid":true}
```

Die Abfrage liest nur Metadaten, verbraucht keine Sicherung und legt bei fehlendem
Dienst weder einen Dienstordner noch einen Daemon an. Sie verlängert keine Frist.
Fehler oder unbekannte Versionen erlauben keine Übernahme.

Das Fenster fragt asynchron und ohne überlappende Abfragen nach. Eine einzelne
Abfrage ist begrenzt; die UI bleibt abbrechbar. Die CLI verfolgt ihren GUI-Prozess.
INT/TERM schließen ihn und stornieren den Token. Bei unerwartetem Elternende
storniert der Vorschau-Helfer seine eigene Vorbereitung und beendet sich ebenfalls.
Die vollständige Undo-Sicherung bleibt ausschließlich im RAM. Eingelesene Quellen,
Konvertierungsergebnis und Hinweise liegen während des CLI-Laufs in privaten
temporären Dateien und werden beim normalen Abschluss/Abbruch entfernt.

## Prüfgrenzen

Die automatischen nativen Ansichten laufen ohne Fokusübernahme. Sie prüfen
Controls, Command-Tastaturaktionen, Größen, Hell/Dunkel, unveränderte Textbytes,
wirklich sichtbares Scrollende sowie Status- und Prozesswechsel. Zusätzlich
laufen CLI, Fenster und Undo-Dienst gemeinsam gegen ein privates Pasteboard:
Übernehmen, Abbrechen, Undo, neues Kopieren und Signale sowie UTF-8-, Größen-
und Ressourcenfehler werden mit vollständigen Formatbytes geprüft. Die dafür
verwendete Fenstersteuerung existiert ausschließlich in TEST-Builds.
Diese Hintergrundprüfungen ersetzen
keine Abnahme der vollständigen notarisiert installierten App einschließlich
Vordergrund-Fokus, Return/Escape und Systemdialogen. Diese Abnahme gehört zum
Installations-/Release-Meilenstein.
