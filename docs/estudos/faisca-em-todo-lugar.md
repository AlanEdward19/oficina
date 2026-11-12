# Estudo: a Faísca em todo lugar (2027)

Status: proposta. Nada aqui está implementado.

"Agentic OS" aqui não quer dizer trocar o macOS. Quer dizer que a Faísca é **independente do sistema**: o mesmo
core roda no Mac, no Windows, no Linux, num servidor ou num contêiner na nuvem, **percebe onde está ligada** e
ajusta o que pode fazer e como fala com você. A referência mais próxima é o [Orca](https://orca.dev/docs/ways-to-run)
(Stably AI): um runtime que roda no desktop, numa máquina por SSH, num servidor ou numa VM na nuvem, com interface
no desktop e no celular, e um CLI (`orca`) que os próprios agentes usam para falar com o runtime em execução.

## 0. Saber onde está ligada (P0)

A cada início, e quando algo muda, o core monta um **retrato do lugar** e o guarda como manifesto de
capacidades. É o que o cérebro e as missões consultam antes de prometer qualquer coisa.

| Pergunta | Como descobrir | Muda o quê |
|---|---|---|
| Qual sistema e qual máquina? | `cfg!(target_os)`, nome do host, arquitetura, Apple Silicon ou não | Quais sentidos e telas existem |
| Tem tela e alguém na frente? | Sessão gráfica (WindowServer, `DISPLAY`/`WAYLAND_DISPLAY`, sessão interativa do Windows) e tempo sem mexer | Com tela: pet e balões. Sem tela: só CLI, notificação ou celular |
| Estou num contêiner, numa VM ou na nuvem? | `/.dockerenv`, `/proc/1/cgroup`, variáveis de sessão remota, metadados da nuvem | Na nuvem: sem microfone nem pet; vira trabalhador das missões |
| Entrei por SSH? | `SSH_CONNECTION`, `SSH_TTY` | A interface fica na sua máquina; aqui só roda trabalho |
| Estou dentro de um editor ou de outro agente? | `TERM_PROGRAM`, `VSCODE_*`, `CURSOR_*`, variáveis do JetBrains, `CLAUDECODE`, `AI_AGENT` e afins (a ideia do `@vercel/detect-agent`), tmux, terminal do Orca | Dentro de outro agente, ela vira ferramenta (MCP/CLI), não pet |
| Quais agentes estão instalados? | Procurar no `PATH`: `claude`, `codex`, `gemini`, `qwen`, `cursor-agent`, `aider`, `goose`, `orca`… | A Fábrica oferece cada um como motor de agente, não só o Claude |
| Quais sentidos existem? | Microfone, câmera, bateria, notch, agenda, acessibilidade, permissões já dadas | O manifesto diz o que ela pode perceber aqui |
| Quem mais está ligado? | Máquinas conhecidas (já existe `GET /v1/machines`) e Tailscale | Onde mandar uma missão; onde você está agora |

O manifesto vira `GET /v1/here` e entra no resumo do cérebro ("Estou num servidor Linux sem tela; o Mac do
usuário está online"). As regras continuam: só nomes e contagens, nunca conteúdo de tela.

## 1. Um runtime, vários clientes, um CLI de volta (P0)

O desenho do Orca casa com o que a Oficina já tem (core separado da UI por HTTP/SSE):

- **Runtime**: o `oficinad`, igual em todo lugar.
- **Clientes**: o app do Mac (Swift), uma casca leve para Windows e Linux (Tauri), uma TUI para terminal e SSH, o
  celular e uma página web local. Cada um mostra o que o lugar permite.
- **CLI `faisca`** para quem está *dentro* da máquina, inclusive agentes:
  `faisca diga "…"`, `faisca pergunte "posso apagar?"` (vira aprovação no seu celular ou no Mac),
  `faisca missao "…"`, `faisca lembre "…"`, `faisca contexto --json`. Ele acha o runtime pela porta local ou pelo
  socket e herda o projeto pela pasta atual, como o `orca --worktree active`.
- **Pareamento**: um runtime numa máquina remota pareia com o seu Mac (código curto ou QR), e você vê e aprova tudo
  de um lugar só.

## 2. Uma Faísca, várias máquinas (P1)

- **Identidade única**: a mesma personalidade, roupinhas e memória em todas as máquinas; o estado pessoal fica numa
  máquina "casa" (o Mac) e as outras pedem o que precisam.
- **Ela vai aonde você está**: a máquina com você na frente mostra o pet; as outras ficam quietas e trabalhando.
- **Missões migram**: começa no Mac, continua num servidor com GPU ou na nuvem, e o resultado volta.

## Onde o mercado está (fim de 2026)

- **Windows** virou "agentic OS" oficialmente: *agent workspace* (cada agente roda numa conta própria do Windows,
  isolada e auditada), um registro de agentes no aparelho baseado em MCP ("agent connectors" para arquivos e
  ajustes) e agentes na barra de tarefas mostrando progresso, pela API `Windows.UI.Shell.Tasks`. Empresas podem
  desligar tudo por Intune. Parte disso ainda é preview.
- **macOS 26**: o modelo do Apple Intelligence está aberto aos apps pelo framework Foundation Models (no aparelho,
  com chamada de ferramentas); App Intents expõe as funções dos apps para Siri, Spotlight e Atalhos. Os betas do
  26.1 mostravam código de MCP dentro de App Intents, mas não achei confirmação oficial de que saiu.
- **Linux** não tem uma camada oficial; o espaço é de projetos abertos (OpenHuman, goose, Accomplish, Bytebot e
  outros), quase todos com MCP, modelo local opcional e memória em arquivos.
- **Protocolos**: MCP é o padrão de agente → ferramenta; A2A (v1.0, Linux Foundation, mais de 150 organizações) é
  agente → agente. Os dois estão na Linux Foundation e se complementam.
- **Segurança**: o consenso é que prompt injection não está resolvido. A defesa é limitar o estrago: isolamento,
  rede com lista de permissões, credenciais curtas e fora do contexto do modelo, e não confiar só em pop-ups de
  permissão. O risco máximo é a "tríade letal": dados privados + conteúdo não confiável + saída para fora.

## O que a Oficina já tem a seu favor

- Core em Rust separado da UI por HTTP/SSE: já é o "kernel" portável. Compila no Linux hoje (o CI de Linux é só
  ligar), e o Windows pede pouco além de trocar sinais Unix e o pseudo-terminal.
- Roteamento de modelo por custo, missões com etapas e veredito com evidência, aprovação antes de agir,
  ferramentas restritas por agente (`oficinad hw` é o modelo disso), contexto de trabalho sem ler a tela.

Além dos blocos 0 a 2 acima, o resto cabe em sete blocos.

## As features

Prioridade: **P0** = sem isso não é agentic OS; **P1** = diferencial forte; **P2** = depois.

### 1. Kernel de agentes portável

| Feature | Prioridade | Ideia |
|---|---|---|
| **Core nos três sistemas** | P0 | CI do core em Linux e Windows; trocar `signal`, `script` e caminhos por camadas de plataforma. |
| **Casca por sistema** | P0 | A UI é só cliente do core. Recomendo **Tauri** (Rust + webview do sistema, pequeno) para Windows e Linux, mantendo o app Swift no Mac, que já usa notch, Dock e Core Animation. |
| **Agendador de agentes** | P0 | Fila com prioridade, limite de agentes simultâneos por CPU/bateria, pausa quando você está em chamada ou no foco. O semáforo de hoje vira um agendador. |
| **Gatilhos** | P0 | "Quando chegar e-mail de X", "toda segunda 9h", "quando o CI falhar", "quando eu entrar no projeto Y". Eventos do sistema e de conectores viram missões. |
| **Orçamento de tokens** | P1 | Teto por dia, por agente e por missão, com o roteador escolhendo o modelo para caber. Painel de quanto cada agente custou. |
| **Modelos locais** | P1 | Ollama/llama.cpp, MLX no Mac, Foundation Models no macOS 26, Windows ML. O roteador ganha um degrau "local" antes do Haiku para classificar, resumir e rotear sem custo nem rede. |

### 2. Ferramentas e conexões

| Feature | Prioridade | Ideia |
|---|---|---|
| **Cliente e servidor MCP** | P0 | A Faísca usa servidores MCP (GitHub, Google, Linear…) e **é** um servidor MCP: outros agentes (Claude Code, Copilot, o do Windows) pedem a ela contexto, memória, a fila de missões ou a Oficina de hardware. |
| **Registro de conectores no sistema** | P1 | No Windows, registrar a Faísca no registro de agentes (ODR); no Mac, expor App Intents ("Faísca, comece uma missão"); no Linux, um serviço D-Bus. |
| **A2A** | P2 | Conversar com agentes de outras máquinas e de empresas por A2A em vez do protocolo próprio entre máquinas que existe hoje. |
| **Uso do computador, com escopo** | P1 | Controle de UI pela acessibilidade (AX no Mac, UI Automation no Windows, AT-SPI no Linux), **só** num espaço isolado (próximo bloco) e só em apps que você liberou. É o que mais contraria a regra de não ler a tela, então nasce desligado. |
| **Navegador próprio do agente** | P1 | Um perfil de navegador separado, sem as suas sessões, para pesquisar e preencher coisas. Playwright/CDP. |

### 3. Segurança como sistema operacional

| Feature | Prioridade | Ideia |
|---|---|---|
| **Espaço isolado por agente** | P0 | Mac: usuário próprio ou `sandbox-exec`/App Sandbox; Windows: o *agent workspace*; Linux: namespaces/bubblewrap ou contêiner. O agente vê só a pasta do projeto. |
| **Rede com lista de permissões** | P0 | Proxy local no core: cada agente só fala com os domínios da missão. Corta a perna "saída para fora" da tríade letal. |
| **Cofre de credenciais** | P0 | Chaves no Keychain / Credential Manager / Secret Service, injetadas pelo proxy na requisição; o modelo nunca vê o segredo. |
| **Rótulo de dado não confiável** | P1 | Texto de web, e-mail e issues entra marcado; uma missão que leu conteúdo externo não pode, na mesma etapa, enviar nada para fora sem aprovação. |
| **Diário de auditoria** | P0 | Cada ação de agente registrada (o quê, onde, com qual permissão), separada do que você fez, com "desfazer" quando der (lixeira e snapshot do git em vez de apagar). |
| **Modo empresa** | P2 | Políticas por arquivo de configuração (quais conectores, quais modelos, teto de gasto), para times. |

### 4. Memória e contexto

| Feature | Prioridade | Ideia |
|---|---|---|
| **Memória por projeto** | P0 | O que ficou do estudo de contexto: fatos, decisões e convenções presos a cada projeto, em Markdown legível e editável. |
| **Busca local** | P1 | Índice local (SQLite FTS + embeddings de modelo local) de reuniões, missões, notas e arquivos que você liberar. "O que decidimos sobre a bateria do óculos?" responde sem gastar tokens de leitura. |
| **Linha do tempo** | P1 | O diário vira uma linha do tempo pesquisável: projetos, reuniões, missões, PRs. Só metadados, nunca captura de tela (o oposto do Recall). |
| **Esquecer com escopo** | P0 | Apagar por projeto, por período ou por fonte, e não só "esquecer tudo". |

### 5. Presença e interface

| Feature | Prioridade | Ideia |
|---|---|---|
| **Atalho e paleta universal** | P0 | ⌃⌥Espaço já existe no Mac; nos três sistemas, uma paleta que aceita texto, arquivo arrastado ou a seleção atual (só quando você chama). |
| **Voz de verdade** | P1 | Palavra de ativação local ("Faísca"), ditado no aparelho (o mesmo pipeline das reuniões) e voz de resposta. Sem enviar áudio para fora. |
| **Progresso no sistema** | P1 | Missões aparecendo na barra de tarefas do Windows, no notch/barra do Mac e no indicador do GNOME/KDE, com aprovar e cancelar dali. |
| **Faísca nos três desktops** | P1 | O pet como janela transparente no Windows e no Linux (Wayland complica janelas sempre-no-topo; X11 e KDE resolvem). |
| **Celular como controle** | P2 | Aprovar etapas, ver o pet e falar com ela do celular, pelo core via Tailscale (já está no Caminho). |

### 6. Rotinas prontas (o que a pessoa sente no dia a dia)

| Feature | Prioridade | Ideia |
|---|---|---|
| **Caixa de entrada triada** | P1 | Resumo da manhã de e-mail, chat e issues, com rascunhos de resposta para aprovar. |
| **Reunião de ponta a ponta** | P1 | Antes: pauta a partir da agenda e do projeto. Durante: anotações (já feito). Depois: tarefas viram missões ou issues. |
| **Guardião do projeto** | P0 | CI vermelho, PR parado, dependência com falha de segurança, disco cheio: ela percebe e propõe a missão. Começou com o CI. |
| **Limpeza e manutenção** | P1 | A limpeza de disco que existe no Mac, mais atualizações e backups, nos três sistemas. |
| **Oficina de hardware** | P1 | Já existe; nos três sistemas porque o core é Rust e o CAD é Python. |

### 7. Ecossistema

| Feature | Prioridade | Ideia |
|---|---|---|
| **Skills e agentes compartilháveis** | P1 | Um agente (papel, ferramentas, gatilhos) vira um arquivo que dá para exportar, revisar e importar. |
| **Loja curada** | P2 | Agentes, roupinhas, widgets e skills da comunidade, com permissões declaradas e revisadas antes de instalar. |

## Por onde começar (proposta de ordem)

1. **Core em Linux e Windows no CI**, camada de plataforma no Rust e o **retrato do lugar** (`GET /v1/here`).
   Barato, e destrava todo o resto.
2. **CLI `faisca`** e uma TUI, para ela já ser útil num servidor ou por SSH.
3. **Segurança base**: espaço isolado por agente, proxy com lista de permissões, cofre de credenciais e diário
   de auditoria. Precisa vir antes de dar mais poder aos agentes.
4. **MCP nos dois sentidos** e **gatilhos**. É o que transforma a Faísca de chat em sistema.
5. **Memória por projeto + busca local + modelo local** no roteador.
6. **Casca Tauri** para Windows e Linux, com o pet, a paleta e o painel de missões.
7. Rotinas (caixa de entrada, reunião de ponta a ponta, guardião), voz e celular.

## Riscos e decisões que são suas

- **Uso do computador** contraria a regra atual de não ler a tela. Proposta: só num espaço isolado, só nos apps
  liberados, desligado por padrão, e com a regra reescrita no CONTRIBUTING.md.
- **Uma UI por sistema ou uma só?** Manter Swift no Mac e Tauri no resto custa duas telas, mas preserva o que o
  Mac tem de melhor. Tauri em tudo simplifica, mas perde notch, Dock e Core Animation.
- **Conta e distribuição**: hoje o motor é o `claude` CLI com a assinatura. Distribuir para outras pessoas exige
  cada uma usar a própria chave de API (já anotado em ARQUITETURA.md).
- **Recursos do Windows em preview** (agent workspace, registro de agentes) podem mudar até 2027; vale uma camada
  própria por baixo e usar os do sistema quando houver.

## Fontes

- Windows: [Ignite 2025 — Windows at the frontier of work](https://blogs.windows.com/windowsexperience/2025/11/18/ignite-2025-windows-at-the-frontier-of-work/), [Petri: agent workspaces](https://petri.com/windows-11-agentic-computing-workspaces/), [Pureinfotech: agentes na barra de tarefas](https://pureinfotech.com/windows-11-ai-agent-support-taskbar-search/), [VentureBeat](https://venturebeat.com/ai/microsoft-remakes-windows-for-an-era-of-autonomous-ai-agents), [Windows Latest: riscos](https://windowslatest.com/2025/11/30/microsoft-says-ai-agents-are-risky-but-its-moving-ahead-with-the-plan-on-windows-11)
- Apple: [What's new in macOS 26](https://developer.apple.com/macos/whats-new), [9to5Mac: MCP no 26.1 beta](https://9to5mac.com/2025/09/22/macos-tahoe-26-1-beta-1-mcp-integration/), [Apple Newsroom: ferramentas para desenvolvedores](https://www.apple.com/sa/newsroom/2025/06/apple-supercharges-its-tools-and-technologies-for-developers/)
- Orca: [formas de rodar](https://orca.dev/docs/ways-to-run), [CLI](https://orca.dev/docs/cli/reference), [agentes suportados](https://orca.dev/docs/agents/supported), [celular](https://orca.dev/docs/mobile); [detect-agent (Vercel)](https://classic.yarnpkg.com/en/package/@vercel/detect-agent)
- Projetos abertos: [OpenHuman](https://pasqualepillitteri.it/en/news/2704/openhuman-open-source-ai-agent-local-memory), [Bytebot](https://github.com/bytebot-ai/bytebot), [Kuse Cowork](https://themenonlab.blog/blog/kuse-cowork-open-source-desktop-ai-agent-rust-tauri), [Agentes de uso do computador em 2026](https://fazm.ai/blog/best-open-source-computer-use-agents-2026-local-desktop-control)
- Protocolos: [Linux Foundation: A2A com 150+ organizações](https://linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year), [MCP vs A2A](https://pickaxe.co/post/mcp-vs-a2a-protocol)
- Segurança: [Design patterns contra prompt injection (arXiv)](https://arxiv.org/pdf/2506.08837), [Frontier Model Forum: práticas de segurança para agentes](https://www.frontiermodelforum.org/uploads/2026/06/FMF-Issue-Brief-on-Emerging-Security-Practices-for-AI-Agents.pdf), [Docker: como proteger agentes](https://www.docker.com/blog/how-to-secure-ai-agents/), [SC World: tríade letal](https://www.scworld.com/native/operating-inside-the-lethal-trifecta-blast-radius-reduction-in-ai-agent-deployments)
