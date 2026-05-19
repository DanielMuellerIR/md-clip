# Icon-Assets

Diese Dateien gehören zum md-clip-App-Icon. Nicht-Entwickler interessiert
hier nichts — wer md-clip einfach benutzt, braucht nur die fertige
md-clip.app aus dem GitHub-Release.

## Inhalt

| Datei | Zweck |
|---|---|
| `generate-icon-v2.py` | Python-Skript, das das Master-PNG aus den Design-Parametern (Farben, Schriftart, Clipboard-Geometrie) rendert. |
| `md-clip-icon-master.png` | 1024×1024 Master-Quelle, von `generate-icon-v2.py` erzeugt. |
| `build-icns.sh` | Bash-Skript: nimmt das Master-PNG, generiert die zehn macOS-Standard-Größen via `sips` und packt sie in eine `.icns`-Datei via `iconutil`. |
| `md-clip.icns` | Fertiges Icon, wird vom App-Bundle-Build mitgenommen. |

## Komplette Neugenerierung

```bash
python3 assets/generate-icon-v2.py   # erzeugt md-clip-icon-master.png
bash assets/build-icns.sh            # erzeugt md-clip.icns
bash wrappers/build-app-bundled.sh   # baut das App-Bundle mit dem neuen Icon
```

## Design-Idee

Himmelblauer 3D-Verlauf mit Highlight oben links, weißes Clipboard mit
Aufhänger und kleinem Loch, "MD" in Avenir Next Heavy zentriert mit
großzügigem Abstand zu den Konturen.
