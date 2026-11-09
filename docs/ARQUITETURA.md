# Arquitetura

## Decisões

| Decisão | Motivo |
|---|---|
| Nativo, sem Docker | No Mac, container roda numa VM Linux: não desenha na tela, não controla o macOS e custa RAM fixa. |
| Core em Rust | Fica sempre ligado. Sem GC, 1,4 MB de RAM parado e o mesmo código pode ir para dispositivos. |
| UI em Swift | Overlay, notch, dock e wallpaper exigem AppKit, Core Animation e Metal. |
| Core separado da UI por HTTP/SSE | É o desacoplamento que o Docker daria. Echo, painel e celular serão só mais clientes. |
| `claude` CLI como motor | Usa o login da assinatura. O core remove `ANTHROPIC_*` do ambiente para nunca cobrar por API. |
| Código escrito do zero | PrimoDock e PrimoEngine são fechados e o Pestinha é GPL-3. Usamos ideias, não código, arte ou nomes. |

## Medições (M1 Pro, 16 GB)

Memória em *physical footprint*, a métrica do Monitor de Atividade, com pet e notch ligados.

| | Disco | Memória | CPU parado |
|---|---|---|---|
| `oficinad` | 1,2 MB | 16 MB depois de ler o uso (1,4 MB antes) | 0% |
| `Oficina.app` (pet, notch e Dock) | 600 KB + core | 27 MB | 0,1% |
| Vorssaint, para comparar | | 143 MB | não medido |

A comparação ainda não é entre iguais: o Vorssaint faz muito mais coisas. O custo real aparece com o
`claude` rodando, só enquanto há tarefa.

## Contrato do core

Autenticação por `Authorization: Bearer <token>`, exceto `health`. Escuta só em `127.0.0.1` por padrão.

| Rota | Função |
|---|---|
| `GET /v1/health` | Nome e versão |
| `GET /v1/machines` | Máquinas e quem está online (consulta sob demanda) |
| `POST /v1/messages` | `{text, target?: auto\|chat\|cloud\|machine, machine?}` |
| `GET /v1/tasks`, `GET /v1/tasks/{id}` | Estado |
| `POST /v1/tasks/{id}/approve`, `/cancel` | Aprovar ou cancelar |
| `GET /v1/usage`, `POST /v1/usage/refresh` | Limites e tokens; responde na hora e atualiza em segundo plano |
| `GET /v1/events` | SSE com `{kind: task\|delta\|usage\|resync}` |

## Uso do Claude

- **Limites oficiais:** vêm do comando local `/usage` do CLI, que não chama o modelo. O core nunca lê o Keychain.
  Atualiza a cada 10 minutos, ou até a cada 2 minutos enquanto o notch é aberto.
- **Tokens, modelos e sessões ativas:** vêm dos logs em `~/.claude/projects`, lidos de forma incremental.
  Só números ficam em memória, nunca o texto das conversas. Contam entrada, saída e criação de cache;
  leitura de cache não entra. Cobrem o Claude Code neste Mac, enquanto os limites incluem também o claude.ai.

## Limites conhecidos

- **Nuvem:** o `--cloud` exige terminal, então o core o executa num pseudo-terminal (`script`) e guarda o link.
  É frágil a mudanças no CLI. Não há API de status: "concluída" quer dizer sessão aberta, e o acompanhamento é
  em claude.ai/code. A pasta de trabalho precisa ter sido confirmada uma vez no Claude CLI.
- **Conta:** a documentação da Anthropic não permite *oferecer* login claude.ai em produtos de terceiros.
  Para uso próprio, o CLI é o caminho previsto. Se um dia a Oficina for distribuída, cada pessoa
  precisa usar a própria chave de API.
- **Agentes na máquina:** rodam com `acceptEdits` e a lista `allowed_tools` do `config.json`, sem shell
  livre. Ampliar essa lista é uma decisão consciente.
- **Pastas protegidas do macOS:** se um agente tocar em Desktop, Documentos ou Downloads, o processo fica
  parado até a permissão ser respondida (a tarefa pode ser cancelada). O espaço de trabalho padrão fica fora
  delas. Com assinatura ad-hoc, cada novo build pode pedir a permissão de novo; assinar com um
  certificado de desenvolvedor resolve.
- **Máquinas remotas:** precisam de rede entre si (Tailscale é o plano) e `listen` fora do localhost.

## Caminho

1. **Fundação** (feito): core, roteamento, pet, chat, aprovação.
2. **Desktop:** Dock por ambientes (feita, convive com a Dock do macOS), início automático.
3. **Substituir o Vorssaint** (notch e uso do Claude já feitos), por ordem de uso: música e agenda no notch, área de transferência,
   alternador de janelas, layout de janelas, mixer de áudio, captura de tela, limpeza.
4. **Pet com vida:** emoções e aprendizado no core, inspirados nas ideias do Pestinha.
5. **Dispositivos:** rede via Tailscale, celular, painel touchscreen, Alexa.
6. **Oficina de hardware:** ideia → pesquisa → protótipo → modelo 3D, com agentes especializados.
