# Oficina

Sistema agêntico pessoal que vive no Mac. A assistente é a **Faísca**: um pet na tela, com conversa
por ⌃⌥Espaço, que usa a sua conta do Claude (login, não chave de API).

## Como funciona

```text
Oficina.app (Swift)  ──HTTP/SSE──►  oficinad (Rust)  ──►  claude CLI (seu login)
pet, chat, menu                     fila, roteamento       ├─ conversa rápida
                                    máquinas, estado       ├─ agente na nuvem (--cloud)
futuro: Echo, painel, celular ──►  (mesma API)             └─ agente numa máquina online
```

- Cada mensagem passa pelo cérebro (modelo rápido, sem ferramentas). Ele responde ou delega.
- `/nuvem …`, `/pc …` e `/chat …`, ou o seletor do chat, escolhem o destino direto.
- Quando o cérebro decide usar o seu computador, a Faísca mostra a instrução e **pede aprovação**.
- A máquina é escolhida entre as online: esta primeiro, depois as de `machines` no `config.json`.

Detalhes e decisões em [docs/ARQUITETURA.md](docs/ARQUITETURA.md).

## Primeiro uso

O CLI precisa do seu login (o do app desktop do Claude é separado):

```bash
claude auth login
```

```bash
bash scripts/build.sh
```

```bash
open build/Oficina.app
```

Clique na Faísca para conversar. Para sair, botão direito nela e **Sair da Oficina**.

A Dock da Oficina fica na base da tela, com ambientes (Trabalho, Pessoal…). ⌃⌥1 a ⌃⌥9 trocam de ambiente
e escondem os apps que são só do anterior. Clique direito num ícone fixa, remove ou move o app; clique
direito nos ambientes cria, renomeia ou apaga. Os ambientes ficam em `dock.json`.

## Contribuir

Pedidos de funcionalidades, widgets, roupinhas e casinhas viram issues no GitHub; issues com a etiqueta
`agente` são implementadas por um agente do Claude. Veja o [CONTRIBUTING.md](CONTRIBUTING.md).

## Desenvolvimento

```bash
cd core && cargo test
```

```bash
cd core && cargo build --release && bash tests/e2e.sh
```

O `e2e.sh` sobe dois daemons reais e usa um `claude` falso, sem consumir a assinatura.

Dados, configuração e token ficam em `~/Library/Application Support/Oficina`.
