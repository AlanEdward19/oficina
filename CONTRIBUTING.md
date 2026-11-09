# Contribuindo com a Oficina

A Oficina é a casa da **Faísca**, uma assistente que vive no Mac. Dá para contribuir com funcionalidades,
widgets da Dock, roupinhas, casinhas e correções. Este guia diz onde mexer em cada caso.

## Como pedir

Abra uma issue escolhendo o modelo (funcionalidade, widget, roupa, casa ou bug). A própria Faísca também
abre issues quando alguém pede uma melhoria pelo chat ou pelo menu **Pedir melhoria…**.

Issues com a etiqueta **`agente`** são implementadas por um agente do Claude, que abre um pull request.
Só quem tem permissão de escrita consegue aplicar a etiqueta, então uma pessoa da equipe decide o que vai
para o agente.

## Mapa do código

| Quero mexer em… | Onde |
|---|---|
| Roupinhas (peças novas) | Vocabulário em `core/src/mind/outfit.rs` (`HEADS`, `FACES`, `NECKS`, `PROPS`) e desenho em `app/Sources/Oficina/Pet.swift` (`wear`) |
| Casinhas (caminhas, mantas, enfeites) | Vocabulário em `core/src/mind/decor.rs` (`BEDS`, `BLANKETS`, `EXTRAS`) e desenho em `Pet.swift` (`setDecor`) |
| Widgets da Dock | `app/Sources/Oficina/Dock.swift`, em `DockView.widgets` |
| Comportamento e humor da Faísca | Rede e mente em `core/src/mind/` (`net.rs`, `mod.rs`); animações em `Pet.swift` (`PetFigure`) |
| Iniciativas (o que ela sugere) | `core/src/mind/mod.rs`, função `best` |
| Conversa, agentes e roteamento | `core/src/engine.rs` e `core/src/route.rs` |
| Notch e uso do Claude | `app/Sources/Oficina/Notch.swift` e `core/src/usage.rs` |
| Chat | `app/Sources/Oficina/Chat.swift` |
| Agentes, equipes, missões e ajustes | `core/src/factory.rs` e `app/Sources/Oficina/Factory.swift` |

Uma peça nova de roupinha ou casinha precisa de duas mudanças: o nome entra no vocabulário do core (assim o
Claude passa a poder escolher a peça) e o desenho entra no `Pet.swift`. Peças fora do vocabulário são
ignoradas, então o app nunca desenha algo que não conhece.

## Regras

- Escreva textos de interface em português do Brasil, curtos e diretos.
- Tudo que gasta tokens do usuário pede permissão antes.
- A Faísca não lê conteúdo de tela nem títulos de janela; só nomes de apps e tempo de uso.
- Animações contínuas vão para o Core Animation (servidor de janelas), nunca para timers por quadro no app.
- Nada de dependências novas sem motivo forte: o core é Rust com poucas crates; o app é Swift sem pacotes.

## Rodando e testando

```bash
cd core && cargo test
```

```bash
cd core && cargo build --release && bash tests/e2e.sh
```

```bash
cd app && swift build -c release
```

```bash
bash scripts/build.sh && open build/Oficina.app
```

O `e2e.sh` usa um `claude` falso e não gasta tokens. O CI roda os três primeiros comandos em todo pull request.

## Pull requests

- Um assunto por PR, com a issue referenciada (`Resolve #123`).
- Testes do core passando; em mudança de comportamento, um teste novo.
- Descreva como verificar a mudança no app.
