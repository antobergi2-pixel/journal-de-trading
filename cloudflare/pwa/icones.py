"""Génère les icônes de l'application (lancer : python3 icones.py)."""
from PIL import Image, ImageDraw, ImageFont
import os

FOND, ENCRE, ACCENT = (15, 92, 110), (255, 255, 255), (99, 183, 202)
POLICES = ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf"]

def icone(taille, marge_securite=0.0, coins=True):
    img = Image.new("RGBA", (taille, taille), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = int(taille * 0.22) if coins else 0
    d.rounded_rectangle([0, 0, taille - 1, taille - 1], radius=r, fill=FOND)
    zone = taille * (1 - 2 * marge_securite)
    ox = oy = taille * marge_securite
    # barres d'un registre : trois lignes croissantes
    bw, gap = zone * 0.13, zone * 0.07
    base = oy + zone * 0.74
    x0 = ox + zone * 0.15
    for i, h in enumerate([0.22, 0.34, 0.48]):
        x = x0 + i * (bw + gap)
        d.rounded_rectangle([x, base - zone * h, x + bw, base], radius=bw * 0.25, fill=ACCENT if i < 2 else ENCRE)
    police = next((ImageFont.truetype(p, int(zone * 0.26)) for p in POLICES if os.path.exists(p)), ImageFont.load_default())
    d.text((ox + zone * 0.83, oy + zone * 0.25), "$", font=police, fill=ENCRE, anchor="mm")
    d.line([ox + zone * 0.12, base + zone * 0.06, ox + zone * 0.82, base + zone * 0.06], fill=ENCRE, width=max(2, int(zone * 0.025)))
    return img

ici = os.path.dirname(os.path.abspath(__file__))
icone(192).save(os.path.join(ici, "icone-192.png"))
icone(512).save(os.path.join(ici, "icone-512.png"))
icone(512, marge_securite=0.12, coins=False).save(os.path.join(ici, "icone-masquable-512.png"))
icone(180, coins=False).convert("RGB").save(os.path.join(ici, "apple-touch-icon.png"))
print("icônes générées")
