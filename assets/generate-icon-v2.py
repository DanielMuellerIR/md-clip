#!/usr/bin/env python3
"""
generate-icon-v2.py — Überarbeitete Variante 2 mit:
  - Realistischerer Clipboard-Darstellung (Clip mit Loch, Schreib-Linien)
  - Fetteres dekoratives Font für 'MD' mit Abstand zu den Konturen
  - 3D-Hintergrund: stärkerer Verlauf + Highlight oben links + tiefer Schatten

Erzeugt zwei Vorschläge mit unterschiedlichen Fonts zum Vergleich:
  - preview-icon-2a-georgia.png   (Serif, dekorativ)
  - preview-icon-2b-avenir.png    (Modern bold)
"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
from pathlib import Path

OUT_DIR = Path(__file__).parent
SIZE = 1024
RADIUS = 224

# Farb-Palette — angelehnt an die Beispiel-Vorlage des Nutzers.
TOP_BLUE = (89, 196, 230, 255)        # heller, lichter Blauton oben
BOTTOM_BLUE = (48, 130, 192, 255)     # tieferes Blau unten
SHADOW_BLUE = (32, 95, 145, 255)      # noch dunkler für Tiefen
HIGHLIGHT = (255, 255, 255, 60)       # weiches Licht oben links
WHITE = (255, 255, 255, 255)
WHITE_SOFT = (255, 255, 255, 180)
PAPER_LINE = (255, 255, 255, 90)      # leichte Striche für Papier-Andeutung


def base_canvas_3d():
    """3D-anmutender Hintergrund mit Verlauf, Highlight und gerundeten Ecken."""
    # Schritt 1: vertikaler Verlauf von hell oben zu dunkel unten.
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    for y in range(SIZE):
        t = y / SIZE
        # Quadratische Interpolation — gibt Tiefen-Wirkung, weil die untere
        # Hälfte stärker abgedunkelt wird als ein lineares Mapping.
        t2 = t * t
        r = int(TOP_BLUE[0] * (1 - t) + BOTTOM_BLUE[0] * t * 0.8 + SHADOW_BLUE[0] * t2 * 0.2)
        g = int(TOP_BLUE[1] * (1 - t) + BOTTOM_BLUE[1] * t * 0.8 + SHADOW_BLUE[1] * t2 * 0.2)
        b = int(TOP_BLUE[2] * (1 - t) + BOTTOM_BLUE[2] * t * 0.8 + SHADOW_BLUE[2] * t2 * 0.2)
        draw.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

    # Schritt 2: radiales Highlight oben links — Licht-Reflex auf der
    # „Oberfläche" des Icons. Soft-Glow-Methode: viele konzentrische
    # Ellipsen mit abnehmender Alpha.
    highlight = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    h_draw = ImageDraw.Draw(highlight)
    hx, hy = 380, 280  # Mittelpunkt des Highlights
    max_r = 500
    for r in range(max_r, 0, -8):
        # alpha-Falloff: Quadrat, damit Mitte hell, Ränder weich
        alpha = max(0, int(70 * (1 - (r / max_r) ** 1.5)))
        h_draw.ellipse(
            [hx - r, hy - r, hx + r, hy + r],
            fill=(255, 255, 255, alpha),
        )
    # Highlight weichzeichnen, damit kein hartes Banding entsteht.
    highlight = highlight.filter(ImageFilter.GaussianBlur(radius=40))

    # Schritt 3: alles kombinieren.
    img = Image.alpha_composite(img, highlight)

    # Schritt 4: zu Squircle maskieren.
    mask = Image.new("L", (SIZE, SIZE), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle([(0, 0), (SIZE, SIZE)], radius=RADIUS, fill=255)

    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def get_font_indexed(path, size, index=0):
    """TTC-Font mit spezifischem Index laden."""
    return ImageFont.truetype(path, size, index=index)


def draw_text_centered(draw, text, font, fill, x_center, y_center):
    bbox = draw.textbbox((0, 0), text, font=font)
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    pos = (x_center - width / 2 - bbox[0], y_center - height / 2 - bbox[1])
    draw.text(pos, text, font=font, fill=fill)


def draw_clipboard(img, draw):
    """Realistischeres Clipboard mit Clip-Detail und Papier-Linien.
    Gibt Koordinaten des inneren Bereichs zurück, damit der Aufrufer
    seinen MD-Text innerhalb der freien Fläche platzieren kann.
    """
    # Body-Maße: schmaler in der Breite, damit ein vernünftiger Rand bleibt
    # und das MD-Text nicht zu nah an die Kontur stößt.
    pad_x = 245
    body_top = 270
    body_bottom = 905
    body_radius = 55
    line_w = 30

    # ---- Body ----
    # Sehr leichter Schlagschatten unter dem Clipboard.
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sh_draw = ImageDraw.Draw(shadow)
    sh_draw.rounded_rectangle(
        [pad_x + 10, body_top + 18, SIZE - pad_x + 10, body_bottom + 18],
        radius=body_radius, fill=(0, 0, 0, 80),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=20))
    img.alpha_composite(shadow)

    draw = ImageDraw.Draw(img)  # nach alpha_composite neu holen

    # White outline body
    draw.rounded_rectangle(
        [pad_x, body_top, SIZE - pad_x, body_bottom],
        radius=body_radius, outline=WHITE, width=line_w,
    )

    # ---- Papier-Linien innen (oben und unten, MD-Bereich frei) ----
    inner_left = pad_x + 80
    inner_right = SIZE - pad_x - 80
    paper_line_w = 6
    # Drei dünne Linien oben, simulieren Linierung
    for y in [365, 405, 445]:
        draw.line([(inner_left, y), (inner_right, y)],
                  fill=PAPER_LINE, width=paper_line_w)
    # Drei weitere unten
    for y in [760, 800, 840]:
        draw.line([(inner_left, y), (inner_right, y)],
                  fill=PAPER_LINE, width=paper_line_w)

    # ---- Clip oben ----
    # Untere Klammer (Trägerplatte): breiteres Rechteck, das den Body oben
    # leicht überlappt.
    clip_w = 320
    clip_h = 160
    clip_x = (SIZE - clip_w) // 2
    clip_y = body_top - clip_h // 2 - 10
    clip_radius = 28

    # Trägerplatte gefüllt mit Sky-Blau (überdeckt den Body-Strich oben).
    # Mit Außenkontur für Definition.
    draw.rounded_rectangle(
        [clip_x, clip_y, clip_x + clip_w, clip_y + clip_h],
        radius=clip_radius, outline=WHITE, width=line_w, fill=TOP_BLUE,
    )

    # Bügel oben — kleines Rechteck, das aus der Trägerplatte rausragt
    # und ein Loch hat (typisch echte Clipboard-Klemme).
    arch_w = 140
    arch_h = 60
    arch_x = (SIZE - arch_w) // 2
    arch_y = clip_y - arch_h + 8  # über die Trägerplatte
    draw.rounded_rectangle(
        [arch_x, arch_y, arch_x + arch_w, arch_y + arch_h + 20],
        radius=24, outline=WHITE, width=line_w, fill=TOP_BLUE,
    )

    # Loch in der Mitte des Bügels (gestanztes Loch).
    hole_r = 22
    hole_cx = SIZE // 2
    hole_cy = arch_y + arch_h // 2 + 5
    draw.ellipse(
        [hole_cx - hole_r, hole_cy - hole_r, hole_cx + hole_r, hole_cy + hole_r],
        fill=TOP_BLUE, outline=WHITE, width=12,
    )

    # Innenbereich für MD-Text. Großzügiger Abstand zu den Konturen.
    inner = {
        "left": pad_x + line_w + 60,
        "right": SIZE - pad_x - line_w - 60,
        "top": body_top + line_w + 100,    # unter den oberen Papier-Linien
        "bottom": body_bottom - line_w - 100,  # über den unteren Papier-Linien
    }
    return inner


def render_variant(font_path, font_index, label):
    img = base_canvas_3d()
    draw = ImageDraw.Draw(img)
    inner = draw_clipboard(img, draw)
    draw = ImageDraw.Draw(img)  # nach möglichem alpha_composite neu

    # MD-Text mit dem gewählten Font.
    # Größe so wählen, dass MD den Innenbereich fast vollständig nutzt,
    # aber die Konturen NICHT berührt — Zielbreite knapp unter 100 %.
    target_w = (inner["right"] - inner["left"]) * 0.92
    # Iterativ richtige Pixel-Größe finden — wir nehmen die größte Font-
    # Größe, bei der „MD" in target_w passt.
    font_size = 700
    while font_size > 50:
        f = get_font_indexed(font_path, font_size, font_index)
        bbox = draw.textbbox((0, 0), "MD", font=f)
        w = bbox[2] - bbox[0]
        if w <= target_w:
            break
        font_size -= 20

    font = get_font_indexed(font_path, font_size, font_index)
    cx = (inner["left"] + inner["right"]) / 2
    cy = (inner["top"] + inner["bottom"]) / 2

    # Leichter Schatten unter dem Text für Tiefe.
    shadow_img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sh_draw = ImageDraw.Draw(shadow_img)
    draw_text_centered(sh_draw, "MD", font, (0, 0, 0, 70), cx + 4, cy + 6)
    shadow_img = shadow_img.filter(ImageFilter.GaussianBlur(radius=6))
    img.alpha_composite(shadow_img)
    draw = ImageDraw.Draw(img)

    # Eigentlicher Text in Weiß.
    draw_text_centered(draw, "MD", font, WHITE, cx, cy)

    # Master-Bild (1024×1024); aus dem baut build-icns.sh anschließend
    # das .icns mit allen Größen-Varianten.
    out = OUT_DIR / "md-clip-icon-master.png"
    img.save(out)
    print(f"✓ {out.name} ({label})")


if __name__ == "__main__":
    # Avenir Next Heavy — final gewählte Variante.
    render_variant("/System/Library/Fonts/Avenir Next.ttc", 8, "final")

    print(f"\nIn: {OUT_DIR}")
    print("Master-Icon: preview-icon-2-final.png")
