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

Memória em *physical footprint* (a métrica do Monitor de Atividade), com pet, notch e Dock ligados e o uso
do Claude já lido.

| | Disco | Memória | CPU parado |
|---|---|---|---|
| `oficinad` | 1,3 MB | 6,8 MB | 0,02% |
| `Oficina.app` | 1,3 MB + core | 22 MB (58 MB com chat, Fábrica e Personalizar abertos) | 0,13% (0,7% com as três abertas) |
| Vorssaint, para comparar | | 143 MB | não medido |

O que segura esses números:

- O core fala com outras máquinas por um cliente HTTP mínimo próprio (`peer.rs`), sem `reqwest`.
- O uso guarda só totais por hora e modelo, não uma entrada por resposta.
- Os logs de uso são lidos em pedaços fixos; linhas acima de 1 MB (imagens, resultados longos) são
  descartadas sem ir para a memória, e o alocador devolve o que sobra.
- A mente pensa a cada 1 s acordada e a cada 3 s dormindo ou com você longe.
- Ícones da Dock são guardados como bitmaps do tamanho exibido; a tela da conversa só existe enquanto é usada.
- Faísca e Dock animam por Core Animation; a janela da Dock nunca se move.

## Escolha de modelo

Agentes com modelo **Automático** (o padrão) rodam no modelo mais barato que dá conta, em `core/src/router.rs`:

1. **Estimativa, sem tokens.** Regras (palavras-chave, tamanho, código) somadas a um modelo linear de 256 pesos
   por degrau. Dá Haiku, Sonnet ou Opus; Fable só quando alguém escolhe.
2. **Resultado manda.** Em missão, `falhou` ou `sem-evidencia` refaz a etapa um degrau acima, e a missão não volta
   ao degrau que falhou. `bloqueado` e erros do processo não sobem: modelo maior não resolve falta de acesso ou limite.
3. **Aprendizado.** Cada resultado ajusta só o degrau usado. "Não funcionou" na conversa conta como falha e sobe.
4. **Verificar nunca fica abaixo de Sonnet:** uma aprovação errada não teria quem a detectasse depois.
5. **Economia testada.** A cada 8 etapas só de leitura, uma tenta um degrau abaixo; é o único jeito de descobrir
   que um modelo menor bastava.

O cérebro em Automático vai no máximo até Sonnet, porque só conversa e delega. Agentes na nuvem usam o modelo
padrão da nuvem, que o `--cloud` não deixa escolher.

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
| `GET/POST /v1/conversations`, `GET/DELETE /v1/conversations/{id}`, `POST …/rename` | Conversas e histórico |
| `GET/POST /v1/settings`, `GET /v1/factory` | Ajustes da assistente; agentes e equipes |
| `POST /v1/agents`, `DELETE /v1/agents/{id}`, `POST …/missions`, `POST …/team` | Agentes e missões |
| `POST /v1/teams`, `DELETE /v1/teams/{id}` | Equipes |
| `GET /v1/meetings`, `POST /v1/meetings`, `GET/DELETE /v1/meetings/{id}` | Reuniões transcritas |
| `POST /v1/meetings/{id}/segments`, `…/end`, `…/summarize` | Falas, fim e resumo (o resumo gasta tokens) |
| `POST /v1/mind/initiatives/{id}/never` | "Nunca neste app" na pergunta da chamada |
| `GET/POST /v1/hardware`, `GET/DELETE /v1/hardware/{id}` | Projetos da Oficina de hardware |
| `GET /v1/hardware/{id}/diagram`, `POST /v1/hardware/{id}/run/{sim\|build\|erc\|firmware}`, `POST /v1/hardware/setup` | Simular, modelar e checar sem tokens; instalar o CAD |
| `GET /v1/presence`, `POST /v1/presence/move`, `POST /v1/presence/call` | Onde ela está, levar, chamar (`force`) |
| `POST /v1/bodies/auto`, `POST /v1/bodies/network`, `POST/DELETE /v1/bodies/{id}` | Aceite automático, porta, renomear e esquecer dispositivos |
| `GET/POST /v1/voice/{id}`, `POST /v1/voice/{id}/text` | O Mac sintetiza e transcreve para os dispositivos |
| `GET /v1/events` | SSE com `{kind: task\|delta\|usage\|resync}` |

## Conversas

- Cada conversa é uma sessão do Claude Code (o cérebro roda com `--resume` da sessão da conversa), então dá
  para continuar no Claude Code: o chat copia o comando. Cada conversa tem sua própria fila no core.
- O histórico completo fica na Oficina: as mensagens recentes em `state.json`; as que saem da memória vão
  para `conversas/<id>.jsonl`, com cartões e links. Apagar uma conversa não apaga a sessão no Claude Code.

## Projetos, ajustes e fábrica

- **Projetos:** vêm do `cwd` e do branch nos logs do Claude Code. Worktrees e subpastas contam para a raiz.
  Vão para o resumo do cérebro e servem de pasta de trabalho dos agentes.
- **Ajustes** (`fabrica.json`): nome, personalidade, modelo e esforço do cérebro, cores, olhos, antena, tamanho.
- **Agentes:** nome, papel, modelo, esforço, lugar (Mac ou nuvem) e projeto. Cada um é uma conversa e mantém
  a própria sessão do Claude. No chat, o cérebro delega com `@@delegar agente:` e propõe novos com
  `@@delegar criar-agente:`, que pede aprovação.
- **Equipes:** um canal em que `@Nome` chama um agente. Respostas que mencionam colegas são repassadas, até
  6 repasses por mensagem.
- **Missões:** Investigar → Propor → Executar → Verificar. As etapas de leitura rodam em `dontAsk` com
  ferramentas de leitura; Executar espera aprovação; cada etapa termina com veredito e evidência, e um
  "concluído" sem evidência para a missão. A ideia dos playbooks vem do Waymark público.

## Uso do Claude

- **Limites oficiais:** vêm do comando local `/usage` do CLI, que não chama o modelo. O core nunca lê o Keychain.
  Atualiza a cada 10 minutos, ou até a cada 2 minutos enquanto o notch é aberto.
- **Tokens, modelos e sessões ativas:** vêm dos logs em `~/.claude/projects`, lidos de forma incremental.
  Só números ficam em memória, nunca o texto das conversas. Contam entrada, saída e criação de cache;
  leitura de cache não entra. Cobrem o Claude Code neste Mac, enquanto os limites incluem também o claude.ai.

## Mente da Faísca

Roda no core, num ciclo de 500 ms (0,03% de CPU), e fica em `mind.json`.

- **Sentidos:** app em foco (só o nome), tempo sem mexer no Mac, tarefas, gestos no pet, troca de ambiente,
  chamadas (qual app usa o microfone). Nunca títulos de janela nem conteúdo de tela.
- **Contexto de trabalho** (`mind/context.rs`): a cada 2 minutos o core pega o projeto mais recente do Claude Code,
  lê o git dele (branch, quantos arquivos sem commit, assuntos dos últimos commits, linguagens pelos nomes dos
  arquivos) e, fora de `main`, o PR do branch com o `gh`, no máximo a cada 10 minutos. Por regras, sem tokens,
  deduz a atividade (programando, revisando, reunião, lendo, pausa). Vai para o resumo do cérebro e para o
  diário do dia (tempo por projeto e em reunião, só números).
- **Rede:** 12 canais → 49 interneurônios de disparo (integra e dispara, com vazamento) → 7 impulsos
  (alegria, curiosidade, tédio, cansaço, carência, foco, iniciativa). Os pesos iniciais seguem afinidades
  desenhadas à mão; os pesos interneurônio → impulso aprendem por recompensa (carinho, iniciativas aceitas
  ou recusadas, tarefas que deram certo), com traços de elegibilidade.
- **Corpo:** energia que cai acordada e volta dormindo; dorme com cansaço, noite ou ausência longa.
- **Memória:** tempo por app e por hora, palavras recorrentes nos pedidos, fatos ditos com "lembre que…",
  roupinhas. Um resumo vai para o cérebro em cada conversa. "Esquecer tudo" apaga o pessoal.
- **Iniciativas:** quando o impulso de iniciativa sobe e você não está concentrado, escolhe entre roupinha
  (se o assunto é IA), abrir um app do seu horário, pausa depois de 1h30 de trabalho ou pesquisa na nuvem
  sobre um interesse. Um bandit aprende o que você aceita. Tudo que gasta tokens pergunta antes.
- **Roupinhas:** o Claude escolhe peças de um vocabulário fixo e cores; o app só desenha o que é válido.
- **Iniciativas de trabalho:** CI vermelho no PR do branch atual (oferece um agente para investigar), 2h sem commit
  com arquivos alterados e o diário no fim do dia. Durante uma chamada nenhuma iniciativa aparece.

## Chamadas e reuniões

- **Detectar** (`Call.swift`): o Core Audio avisa quando o microfone padrão liga; enquanto ele está ligado, a cada
  3 s o app lê os processos de áudio (`kAudioHardwarePropertyProcessObjectList`) e qual deles captura entrada.
  O bundle do processo é comparado com uma lista de apps de chamada (Zoom, Discord, Teams, WhatsApp, FaceTime,
  Slack, Webex, Skype) e navegadores (Meet). 10 s seguidos começam a chamada; 20 s sem ela, terminam.
- **Perguntar:** o core cria a pergunta "Quer que eu ouça e anote?" com três respostas: Ouvir, Agora não e
  "Nunca no Zoom", que fica guardado. Vale 60 s.
- **Ouvir** (`Listen.swift`): o microfone (AVAudioEngine) vira "Você"; um *process tap* do Core Audio só nos processos
  do app da chamada (macOS 14.2+, permissão "Gravação de áudio do sistema", não de tela) vira "Outros". Cada
  fonte passa pelo `SpeechAnalyzer` + `SpeechTranscriber` no macOS 26 (o modelo de português é baixado uma vez pelo
  sistema) ou, antes dele, pelo `SFSpeechRecognizer` no Mac (`requiresOnDeviceRecognition`); sem reconhecimento
  local, ela não ouve. O código do macOS 26 só entra quando o app é compilado com Xcode 26 (`#if compiler(>=6.2)`). Pedaços de 25 s viram falas no core. O áudio nunca é gravado. Enquanto ouve, a
  Faísca usa fones com um selo REC, e o menu dela ganha "Parar de ouvir a chamada".
- **Agenda** (`Agenda.swift`, desligada até você ligar "Usar a agenda" no menu): o app manda à mente só título,
  início e fim dos eventos das próximas horas. Ela avisa uma vez quando faltam 10 minutos, dá nome à pergunta da
  chamada ("Entrou na reunião Daily no Zoom") e às anotações, e o cérebro sabe o que vem a seguir.
- **Guardar:** `reunioes/<id>.json`, com as falas. No fim da chamada ela oferece o resumo (decisões, tarefas e
  dúvidas), que gasta tokens. "Esquecer tudo" apaga as reuniões.

## Presença única

- **Uma Faísca, um lugar.** A mente fica no core do Mac ("casa"). Dispositivos são corpos (`presence.rs`); só quem tem a
  posse de presença fala e ouve. Ir para outro lugar manda "saiu" ao anterior e "chegou" ao novo.
- **Sem pareamento.** O core abre uma porta só para dispositivos (`body_listen`, `0.0.0.0:7879`) e responde ao
  broadcast UDP `oficina?` com `oficina:<porta>:<nome>`. A caixa se apresenta (`/v1/body/hello`) com o endereço MAC e,
  com "Aceitar dispositivos sozinha" ligado (o padrão), entra na hora e recebe um token só dela; a Faísca avisa. O mesmo
  aparelho, regravado, volta como o mesmo dispositivo com token novo. Lá só existem as rotas `/v1/body/*`; a API
  principal continua só no localhost. O risco: qualquer aparelho da rede pode se apresentar. Por isso as duas chaves
  em Dispositivos, o "Esquecer", e o que gasta ou mexe no Mac continua pedindo aprovação. O código de 6 dígitos
  (`/v1/bodies/pairing`) fica para quem desligar o aceite automático.
- **Voz:** o core pede ao app do Mac a fala sintetizada (`AVSpeechSynthesizer`, WAV 16 kHz) e a transcrição do que a
  caixa gravou (`SFSpeechRecognizer` no Mac). Os áudios ficam só na memória, no máximo 30 ou 24 MB. Sem o app, a caixa
  recebe só o texto.
- **Conversa no cômodo:** cada dispositivo tem sua conversa. O cérebro sabe onde ela está, fala curto quando é por voz e
  pode ir até outro cômodo com `@@delegar presenca: <cômodo>: <fala>`. As respostas são faladas lá, e a caixa ouve a
  réplica.
- **Ocupada:** você chamando (abrir a conversa ou "Chamar de volta"), ela pesa a conversa de lá: com um pedido em
  andamento, fica e te avisa; com conversa viva, avisa e vem em até 20 s; parada, vem. "Vem agora" (`force`) sempre traz,
  com uma despedida no jeito da personalidade. Sozinha, ela volta após 90 s de silêncio ou se o dispositivo sumir.
- **Botão da caixa:** chama a Faísca para lá, a não ser que você esteja falando com ela no Mac; aí ela te avisa.
- Firmware e simulador em `devices/caixa/`.

## Windows e Linux

- O core compila nos três sistemas; o que muda fica em `core/src/platform.rs` (pasta de dados, aleatoriedade, hora local,
  nome da máquina, grupos de processos, programas no PATH com `.exe`/`.cmd`). No Windows os dados ficam em
  `%APPDATA%\Oficina`. Agentes na nuvem (`--cloud`) ainda não funcionam no Windows, porque precisam de terminal Unix.
- `desktop/` é o app para Windows e Linux, em Rust (tao, wry, tray-icon): o pet numa janela transparente sempre no topo,
  a conversa numa janela comum e o ícone na bandeja. As telas são páginas servidas pelo próprio core em `/ui/`
  (`core/ui/`), sem segredo; o app injeta o token.
- **Tudo pelo Wi-Fi.** Ao abrir, o app grita `oficina?` na rede. Se outra Oficina responde (o Mac), este computador vira
  um corpo da mesma Faísca (tipo `pc`), sem pareamento: o pet só aparece quando ela vem para cá, a conversa vai para a
  mente no Mac e as respostas são faladas com a voz do Windows. Se ninguém responde, o app liga o `oficinad` local e a
  Faísca mora ali.
- `scripts/build-windows.sh` gera `build/Oficina-Windows.zip` (no Windows ou por compilação cruzada com mingw-w64); o CI
  tem um job no Windows que roda os testes do core e publica o pacote como artefato.

## Oficina de hardware

- Cada projeto é uma pasta em `hardware/<id>/` com um esqueleto: `requisitos.md`, `pesquisa.md`,
  `eletrica/diagrama.mmd` e `mapa.md`, `especificacao.json`, `mecanica/modelo.py`, `montagem.md`, `firmware/`.
- Criar um projeto cria um agente `HW-<id>` com esse papel e começa a missão de quatro etapas. A etapa Executar
  espera aprovação, como as outras missões.
- O agente não tem shell livre: além das ferramentas da missão, só `oficinad hw sim|build|erc|bom`, que só roda
  dentro de uma pasta de projeto. Nas etapas de leitura ele ganha também WebSearch, WebFetch e `hw sim`.
- `hw sim` calcula, sem tokens e sem dependências, autonomia (bateria × margem ÷ corrente média dos modos), peso e
  centro de massa, custo e calor (ΔT = P / (h · A)), e gera `simulacoes/resultado.md`, `resultado.json` e `bom.csv`.
- `hw build` roda `mecanica/modelo.py` (build123d) num ambiente Python só da Oficina (`hardware/.env`,
  instalado pela tela, cerca de 2 GB). O ajudante `oficina_cad.py` exporta um STL por peça, `montagem.step`, massa
  pelo material e as interferências entre peças, que entram nas simulações como "Encaixe".
- `hw erc` compila o esquemático com atopile ou roda o ERC do KiCad, se algum estiver instalado.
- `hw firmware` compila `firmware/platformio.ini` com o PlatformIO do ambiente da Oficina e, se houver
  `firmware/renode.resc`, roda 5 s no Renode sem janela, com `$bin` (o ELF) e `$uart` (o log serial). Cada linha de
  `firmware/esperado.txt` precisa aparecer na serial; o resultado entra nas simulações como "Firmware". O Renode
  emula Cortex-M e RISC-V; o ESP32-S3 (Xtensa) só compila.
- O diagrama de blocos (`eletrica/diagrama.mmd`) é lido pelo core (`hardware/diagram.rs`): blocos, setas e rótulos,
  em camadas pelo maior caminho. O app desenha no Canvas, sem navegador; `GET /v1/hardware/{id}/diagram`.
- A tela mostra o pacote em abas e o modelo 3D em SceneKit (STL via ModelIO), com vista explodida.

## Dock

- Segue Mesa e Dock do macOS: ocultar automaticamente, tamanho, ampliação e posição.
- "Substituir a Dock do macOS" vem ligado. Guarda os valores originais, liga ocultar com atraso de 1000 s na Dock do
  sistema e reinicia a Dock. Ao sair da Oficina, devolve tudo com a sua escolha mais recente. Se a Oficina
  fechar à força com a substituição ligada:
  `defaults delete com.apple.dock autohide-delay && killall Dock`

## Pedidos de melhoria

- No chat ("faz uma roupa de pirata pra você"), o cérebro reconhece o pedido e delega como melhoria, com o
  tipo (funcionalidade, widget, roupa, casa, bug). Como abrir issue é publicar, o chat pede aprovação.
- Pelo menu **Pedir melhoria…** o pedido sai na hora, com a opção de pedir um agente.
- O core abre a issue com o `gh` no repositório de `repo` (config.json). A etiqueta `agente` dispara o
  workflow `.github/workflows/agente.yml`, em que um agente do Claude implementa e abre um PR; o CI compila e
  testa. Qualquer pessoa pode abrir issues pelos modelos; só quem tem escrita aplica `agente`.
- Guia para quem contribui: [CONTRIBUTING.md](../CONTRIBUTING.md).

## Limites conhecidos

- **CPU do app:** parado, cerca de 0,5%. A Faísca vive num palco transparente da tela inteira que ignora o
  mouse; os movimentos são animações do Core Animation, executadas pelo servidor de janelas. Numa visita
  à Dock o app caiu de cerca de 12% para cerca de 3% de CPU (o resto é o ícone balançando, em SwiftUI).
  Uma janela invisível do tamanho dela recebe clique, arraste e carinho e só muda de lugar no fim de
  cada movimento, então durante uma caminhada ela não responde a clique.

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
6. **Oficina de hardware** (primeira versão feita): ideia → pesquisa → protótipo → modelo 3D, com agentes especializados.

Estudos: [Faísca atenta ao trabalho e às chamadas](estudos/contexto-e-chamadas.md),
[Oficina de hardware](estudos/oficina-de-hardware.md) e [Faísca em todo lugar](estudos/faisca-em-todo-lugar.md).
