# Grenze und Folgeplan für einmaliges Undo

Stand: 2026-09-05. Noch nicht implementiert.

`pbcopy`, `xclip` und `wl-copy` ersetzen die Auswahl durch ein Textangebot.
Ein vorheriges `pbpaste` oder `wl-paste` sichert nur eine Darstellung. Damit
lassen sich RTF, HTML, Bilder, Dateiverweise, mehrere Pasteboard-Items und
anwendungseigene Formate nicht vollständig wiederherstellen.

Auf macOS könnte ein nativer Helfer alle NSPasteboard-Items samt Typen und
Daten lesen. Er müsste vor dem Ersetzen prüfen, ob wirklich jedes Format
materialisiert werden konnte, und bei verzögert bereitgestellten oder nicht
lesbaren Formaten abbrechen. changeCount müsste beim Sichern sowie unmittelbar
vor dem Schreiben übereinstimmen. Undo dürfte nur bei unverändertem, nach dem
Schreiben festgehaltenem changeCount angeboten werden. Ein neuer Kopiervorgang,
auch mit gleichen Bytes, muss Undo ungültig machen. NSPasteboard bietet für
Prüfen-und-Schreiben keine atomare Vergleichsoperation; diese Restlücke braucht
eine ausdrückliche Produktentscheidung und belastbare Parallelitätstests.

Unter X11 und Wayland besitzt ein Prozess das Datenangebot und liefert Bytes
auf Anfrage. Ein Folgeschritt benötigt einen dauerhaft laufenden Eigentümer,
der alle angebotenen Typen sichert und erneut anbietet. CLI-Werkzeuge für einen
einzelnen Typ reichen dafür nicht. Sitzungswechsel, Eigentümerwechsel während
der Sicherung, große/verzögerte Daten und das Beenden des Helfers müssen zum
sicheren Abbruch führen. Eine vollständige plattformübergreifende Zusicherung
ist mit der aktuellen Architektur nicht belegt.

Umsetzbare nächste Schritte:

1. macOS-Prototyp mit eigenem privaten Pasteboard: mehrere Items, HTML/RTF/Text,
   Bild- und benutzerdefinierte Daten; fehlendes Format verhindert Ersetzen.
2. Eigentümerwechsel und identische neue Kopien gezielt simulieren. Die atomare
   Restlücke bewerten, bevor eine Nutzerfunktion freigegeben wird.
3. Linux-Prototyp je Backend mit isoliertem Xvfb/sway: alle angebotenen MIME-
   Typen sichern und als dauerhaftes Angebot wiederherstellen; verzögerte
   Antwort und Prozessende testen.
4. Erst bei belegtem Vertrag Speichergrenzen, private Ablage, Ablaufzeit und
   einmaliges Löschen des Undo-Datensatzes festlegen und eine CLI ergänzen.
