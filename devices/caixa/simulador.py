#!/usr/bin/env python3
"""Caixa de som simulada: faz o papel da caixa da Faísca no terminal.

Serve para testar a presença única sem hardware. Usa só a biblioteca padrão.

    python3 devices/caixa/simulador.py --comodo Sala

Sem pareamento: ela acha a Oficina na rede (broadcast UDP "oficina?") e se
apresenta com uma identidade própria; a Oficina aceita sozinha.

O que você digita é o que "alguém na sala" disse. `/chamar` aperta o botão da
caixa. Com `--tocar`, as falas com áudio tocam no alto-falante (afplay no Mac,
aplay no Linux). O token fica em ~/.oficina-caixa-simulada.json.
"""

import argparse
import json
import os
import socket
import uuid
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


def descobrir(porta):
    """Grita "oficina?" na rede e devolve a URL de quem responder."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(1.5)
    for destino in ("255.255.255.255", "127.0.0.1"):
        try:
            s.sendto(b"oficina?", (destino, porta))
            resposta, (ip, _) = s.recvfrom(128)
        except OSError:
            continue
        partes = resposta.decode(errors="replace").split(":")
        if partes[0] == "oficina":
            print(f"Achei a Oficina em {partes[2] if len(partes) > 2 else ip} ({ip}).")
            return f"http://{ip}:{partes[1]}"
    return None


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
            print(f"\n[a Oficina recusou: {e.code}] Fui esquecida; rode de novo para me apresentar.")
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


def guardar(estado):
    fd = os.open(ESTADO, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(estado, f)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", help="porta dos dispositivos da Oficina (sem isso, ela procura na rede)")
    p.add_argument("--porta", type=int, default=7879, help="porta usada na descoberta")
    p.add_argument("--codigo", help="código de pareamento, se o aceite automático estiver desligado")
    p.add_argument("--comodo", default="Sala")
    p.add_argument("--nome", default="")
    p.add_argument("--tocar", action="store_true", help="tocar os áudios das falas")
    args = p.parse_args()
    estado = {}
    if os.path.exists(ESTADO):
        with open(ESTADO) as f:
            estado = json.load(f)
    base = (args.url or estado.get("url") or descobrir(args.porta) or "").rstrip("/")
    if not base:
        sys.exit("Não achei a Oficina na rede. Ela está aberta? Ou passe --url http://IP-do-Mac:7879")
    estado.setdefault("device", "sim-" + uuid.uuid4().hex[:12])
    if not args.codigo and (not estado.get("token") or args.url):
        try:
            r = pedir(base, "/v1/body/hello", dados={"device": estado["device"], "room": args.comodo, "name": args.nome, "kind": "caixa"})
        except urllib.error.HTTPError as e:
            sys.exit(f"A Oficina não aceitou: {e.read().decode(errors='replace')}")
        estado.update({"url": base, "token": r["token"], "id": r["id"], "room": r["room"]})
        guardar(estado)
        print(f"Entrei como {r['name']} ({r['room']}).")
    if args.codigo:
        try:
            r = pedir(base, "/v1/body/pair", dados={"code": args.codigo, "room": args.comodo, "name": args.nome, "kind": "caixa"})
        except urllib.error.HTTPError as e:
            sys.exit(f"Pareamento recusado: {e.read().decode(errors='replace')}")
        estado.update({"url": base, "token": r["token"], "id": r["id"], "room": r["room"]})
        guardar(estado)
        print(f"Pareada como {r['name']} ({r['room']}).")
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
