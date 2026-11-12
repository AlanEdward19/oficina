#!/usr/bin/env python3
"""Caixa de som simulada: faz o papel da caixa da Faísca no terminal.

Serve para testar a presença única sem hardware. Usa só a biblioteca padrão.

    python3 devices/caixa/simulador.py --codigo 123456 --comodo Sala
    python3 devices/caixa/simulador.py            # depois do primeiro pareamento

O que você digita é o que "alguém na sala" disse. `/chamar` aperta o botão da
caixa. Com `--tocar`, as falas com áudio tocam no alto-falante (afplay no Mac,
aplay no Linux). O token fica em ~/.oficina-caixa-simulada.json.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request

ESTADO = os.path.expanduser("~/.oficina-caixa-simulada.json")


def pedir(base, caminho, token=None, dados=None, metodo=None, tempo=30):
    corpo = None if dados is None else json.dumps(dados).encode()
    req = urllib.request.Request(base + caminho, data=corpo, method=metodo or ("POST" if corpo is not None else "GET"))
    if corpo is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=tempo) as r:
        bruto = r.read()
        tipo = r.headers.get("Content-Type", "")
    if "json" in tipo:
        return json.loads(bruto or b"{}")
    return bruto


def tocar(base, token, caminho):
    tocador = shutil.which("afplay") or shutil.which("aplay")
    if not tocador:
        return
    wav = pedir(base, caminho, token)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        f.write(wav)
    subprocess.run([tocador, f.name], check=False)
    os.unlink(f.name)


def escutar(base, token, args, parar):
    while not parar.is_set():
        try:
            r = pedir(base, "/v1/body/next?wait=20", token, tempo=30)
        except urllib.error.HTTPError as e:
            print(f"\n[a Oficina recusou: {e.code}] Pareie de novo com --codigo.")
            parar.set()
            return
        except OSError as e:
            print(f"\n[sem contato com a Oficina: {e}]")
            parar.wait(3)
            continue
        for c in r.get("commands", []):
            tipo = c.get("kind")
            if tipo == "arrive":
                print("\n💡 A Faísca chegou aqui.")
            elif tipo == "leave":
                print("\n⚫ A Faísca foi embora.")
            elif tipo == "say":
                print(f"\n🗣  Faísca: {c.get('text')}")
                if args.tocar and c.get("audio"):
                    tocar(base, token, c["audio"])
            elif tipo == "listen":
                print(f"🎤 (ouvindo por {c.get('secs')} s — digite a resposta)")
        print("> ", end="", flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default="http://127.0.0.1:7879", help="porta dos dispositivos da Oficina")
    p.add_argument("--codigo", help="código de pareamento (Dispositivos… no menu da Faísca)")
    p.add_argument("--comodo", default="Sala")
    p.add_argument("--nome", default="")
    p.add_argument("--tocar", action="store_true", help="tocar os áudios das falas")
    args = p.parse_args()
    base = args.url.rstrip("/")

    estado = {}
    if os.path.exists(ESTADO):
        with open(ESTADO) as f:
            estado = json.load(f)
    if args.codigo:
        try:
            r = pedir(base, "/v1/body/pair", dados={"code": args.codigo, "room": args.comodo, "name": args.nome, "kind": "caixa"})
        except urllib.error.HTTPError as e:
            sys.exit(f"Pareamento recusado: {e.read().decode(errors='replace')}")
        estado = {"url": base, "token": r["token"], "id": r["id"], "room": r["room"]}
        fd = os.open(ESTADO, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(estado, f)
        print(f"Pareada como {r['name']} ({r['room']}).")
    if not estado.get("token"):
        sys.exit("Primeiro pareie: --codigo 123456 (o código aparece em Dispositivos…, no menu da Faísca).")
    token = estado["token"]
    base = estado.get("url", base)

    parar = threading.Event()
    threading.Thread(target=escutar, args=(base, token, args, parar), daemon=True).start()
    print(f"Caixa simulada na {estado.get('room')}. Digite o que alguém disse; /chamar aperta o botão; /sair encerra.")
    try:
        while not parar.is_set():
            linha = input("> ").strip()
            if not linha:
                continue
            if linha == "/sair":
                break
            try:
                if linha == "/chamar":
                    r = pedir(base, "/v1/body/call", token, dados={})
                    print({"aqui": "Ela já está aqui.", "chegando": "Ela está vindo.", "ocupada": "Ela está ocupada; avisei quem está no computador."}.get(r.get("result"), r.get("result")))
                else:
                    pedir(base, "/v1/body/heard", token, dados={"text": linha})
            except urllib.error.HTTPError as e:
                print(f"[{e.code}] {e.read().decode(errors='replace')}")
    except (EOFError, KeyboardInterrupt):
        pass
    parar.set()


if __name__ == "__main__":
    main()
