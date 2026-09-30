# Einmaliges Undo der vollständigen Clipboard-Ersetzung

`md-clip --replace` sichert vor dem Lesen der Konvertierungsquelle alle
angebotenen Clipboard-Daten. Die Konvertierung, eine optionale Vorschau und das
Schreiben bilden eine Operation. `md-clip --undo` nimmt die letzte erfolgreiche
Ersetzung einmalig zurück; es lässt sich mit `--quiet` und `--notify`, aber
nicht mit Konvertierungsoptionen kombinieren.

Die Sicherung enthält rohe Bytes aller unterstützten angebotenen Formate;
unter macOS zusätzlich alle einzelnen Pasteboard-Items. HTML, RTF, Bilddaten,
Dateiverweise, benutzerdefinierte Formate und leere Formatrepräsentationen werden
nicht auf Klartext reduziert. Aktive Lieferanten können nicht rekonstruiert
werden: macOS-Datei-Versprechen werden deshalb abgelehnt. Ein nicht lesbares
Format, mehr als 128 Formate, mehr als 64 MiB oder ein Eigentümerwechsel während
der Sicherung verhindert die Ersetzung. Die Zeit für Datenlieferungen ist
begrenzt; ein blockierter Lieferant führt zum Abbruch.

## Gültigkeit und Lebensdauer

Die Sicherung liegt ausschließlich im Arbeitsspeicher eines lokalen Helfers,
nicht in einer Clipboard-Historie oder einer Sicherungsdatei. Private lokale
Sockets dienen nur der Kommunikation. Die ohnehin temporären Eingabe- und
Ausgabedateien der Konvertierung sind keine dauerhafte Undo-Ablage.

Undo gilt höchstens zehn Minuten ab erfolgreichem Schreiben und endet schon
vorher bei einem neuen Clipboard-Eigentümer. Eine neue Kopie mit identischen
Bytes zählt ebenfalls als Änderung. Fehlgeschlagene Konvertierungen und
abgelehnte Vorschauen schreiben nicht; ihre vorbereitete Sicherung wird
verworfen. Parallel vorbereitete Ersetzungen werden abgelehnt. Auch eine
Vorbereitung verfällt nach zehn Minuten, falls ihr Aufrufer verschwindet.

Beim Undo werden alle gesicherten Daten wieder angeboten und die Undo-Operation
verbraucht. Eine zweite Ausführung scheitert. Leere Ausgangs-Clipboards können
bei Datei-/stdin-Eingaben wieder leer hergestellt werden. Nach dem Verlust oder
Neustart des Helfers gibt es keine rekonstruierbare Sicherung.

## Plattformen

macOS verwendet einen nativen Swift-Helfer mit `NSPasteboard`. Jede Sicherung
und jedes Schreiben prüft `changeCount`; Nutzdaten werden in kurzlebigen,
zeitlich begrenzten Worker-Prozessen materialisiert. Der Helfer reist im
App-Bundle mit und gehört zu Build-, Signatur- und Kompatibilitätsprüfungen.
Die Quellinstallation baut ihn über `install.sh`.

Linux verwendet Python 3 mit den nativen Clipboard-Protokollen. Unter X11 sind
`libX11` und `libXfixes` erforderlich; die Auswahl und Eigentümerwechsel werden
auf derselben Verbindung beobachtet. Unter Wayland braucht es `ext-data-control`
oder `wlr-data-control`. Nicht unterstützte Compositoren und mehrdeutige
Sitzungen verhindern das Ersetzen, statt eine unvollständige Sicherung zu
versprechen. Ein Linux-Helfer bleibt Eigentümer und liefert seine Daten weiter,
solange kein anderer Prozess die Auswahl übernimmt. Nach Ablauf des Undo hält
er nur noch das aktuelle Angebot, nach Wiederherstellung die zurückgegebenen
Daten; diese sind dann der aktuelle Clipboard-Inhalt. Wird er beendet oder die
Desktop-Verbindung getrennt, kann das Angebot verloren gehen.

## Konkurrenzgrenze

Weder `NSPasteboard` noch die unterstützten Linux-Protokolle bieten hier eine
atomare Operation „nur schreiben, wenn derselbe Eigentümer noch gilt“. Der
Helfer prüft unmittelbar vor dem Schreiben und bindet Undo an seinen eigenen
Schreibvorgang. Eine neue Kopie genau zwischen Prüfung und Schreiben kann
weiterhin überschrieben werden. Dieser verbleibende Wettlauf gehört zum
Produktvertrag; identische Bytes allein sind niemals ein Gültigkeitsnachweis.

## Prüfungen

Die Helfer werden mit unabhängigen nativen Lesern geprüft: vollständiger
Formatvergleich, binäre und leere Daten, einmalige Wiederherstellung, neuer
Eigentümer mit identischen Bytes, nicht lesbare und verzögerte Angebote,
Größen-/Zeitgrenzen, parallele Vorbereitung und private Socket-Ablage.
CLI-Vertragstests prüfen außerdem Abbruch vor dem Schreiben und die
Unverträglichkeit von `--undo` mit Konvertierungsoptionen. Die gemeinsame
Pipeline bleibt unverändert die Quelle der Fixture-Tests. Eine synthetische
Gegenprobe ersetzt keine echte Browser-Klickabnahme auf dem Desktop.
