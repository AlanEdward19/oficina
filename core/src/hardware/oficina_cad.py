"""Ajudante da Oficina para modelos em build123d.

Em mecanica/modelo.py (a Oficina roda o script na pasta do projeto):

    from build123d import *
    from oficina_cad import exportar

    armacao = Box(140, 6, 40)
    bateria = Pos(-60, 0, -10) * Box(30, 5, 20)
    exportar({
        "Armação": (armacao, "PETG"),
        "LiPo 300 mAh": (bateria, None),   # peça comprada: a massa vem da especificação
    })

Gera, em mecanica/: um STL por peça, montagem.step, montagem.stl e
relatorio.json com volume, massa (pelo material), centro, caixa e as
interferências entre peças.
"""

import json
import os
import sys
import unicodedata

DENSIDADE = {  # g/cm³
    "PLA": 1.24,
    "PETG": 1.27,
    "ABS": 1.04,
    "ASA": 1.07,
    "PA12": 1.01,
    "NYLON": 1.14,
    "TPU": 1.21,
    "RESINA": 1.15,
    "ALUMINIO": 2.70,
    "ACO": 7.85,
    "ACRILICO": 1.18,
}


def _arquivo(nome):
    ascii_ = unicodedata.normalize("NFKD", nome).encode("ascii", "ignore").decode()
    seguro = "".join(c if c.isalnum() or c in "-_" else "_" for c in ascii_).strip("_") or "peca"
    return seguro.lower() + ".stl"


def exportar(pecas, pasta="mecanica"):
    from build123d import CenterOf, Compound, export_step, export_stl

    os.makedirs(pasta, exist_ok=True)
    itens = []
    for nome, valor in pecas.items():
        parte, material = valor if isinstance(valor, tuple) else (valor, None)
        itens.append((nome, parte, (material or "").upper() or None))

    relatorio = {"pecas": [], "interferencias": [], "ok": True}
    for nome, parte, material in itens:
        arquivo = _arquivo(nome)
        export_stl(parte, os.path.join(pasta, arquivo))
        volume = float(parte.volume)
        caixa = parte.bounding_box()
        centro = parte.center(CenterOf.MASS) if volume > 0 else caixa.center()
        densidade = DENSIDADE.get(material) if material else None
        relatorio["pecas"].append({
            "nome": nome,
            "arquivo": arquivo,
            "material": material,
            "volume_mm3": round(volume, 2),
            "massa_g": round(volume / 1000.0 * densidade, 2) if densidade else None,
            "centro_mm": [round(centro.X, 2), round(centro.Y, 2), round(centro.Z, 2)],
            "caixa_mm": [
                [round(caixa.min.X, 2), round(caixa.min.Y, 2), round(caixa.min.Z, 2)],
                [round(caixa.max.X, 2), round(caixa.max.Y, 2), round(caixa.max.Z, 2)],
            ],
        })

    # Interferência: primeiro pelas caixas (barato), depois pela interseção real.
    for i in range(len(itens)):
        for j in range(i + 1, len(itens)):
            a, b = relatorio["pecas"][i]["caixa_mm"], relatorio["pecas"][j]["caixa_mm"]
            if any(a[1][k] <= b[0][k] or b[1][k] <= a[0][k] for k in range(3)):
                continue
            try:
                comum = float((itens[i][1] & itens[j][1]).volume)
            except Exception:
                comum = 0.0
            if comum > 0.01:
                relatorio["interferencias"].append([itens[i][0], itens[j][0], round(comum, 2)])
    relatorio["ok"] = not relatorio["interferencias"]

    montagem = Compound(children=[p for _, p, _ in itens])
    export_step(montagem, os.path.join(pasta, "montagem.step"))
    export_stl(montagem, os.path.join(pasta, "montagem.stl"))
    with open(os.path.join(pasta, "relatorio.json"), "w", encoding="utf-8") as f:
        json.dump(relatorio, f, ensure_ascii=False, indent=2)

    for p in relatorio["pecas"]:
        massa = f"{p['massa_g']} g" if p["massa_g"] is not None else "massa da especificação"
        print(f"{p['nome']}: {p['volume_mm3']} mm³, {massa}")
    for a, b, v in relatorio["interferencias"]:
        print(f"INTERFERÊNCIA: {a} × {b} ({v} mm³)", file=sys.stderr)
    return relatorio
