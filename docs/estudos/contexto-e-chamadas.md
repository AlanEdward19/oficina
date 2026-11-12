# Estudo: Faísca atenta ao trabalho e às chamadas

Status: primeira versão implementada. Ficaram para depois: agenda (EventKit), memória por projeto e o `SpeechAnalyzer` do macOS 26 (hoje a transcrição usa o `SFSpeechRecognizer` no Mac). O que foi feito está em [ARQUITETURA.md](../ARQUITETURA.md#chamadas-e-reuniões).

## O ponto de partida

Hoje a mente da Faísca (`core/src/mind/`) sabe:

- o **nome** do app em foco e os apps abertos (`main.swift` → `MindEvent`);
- o tempo sem mexer no Mac;
- os **projetos** do Claude Code (`cwd` e branch nos logs, `engine.rs` → `set_projects`);
- palavras recorrentes nos pedidos e fatos ditos com "lembre que…".

A regra do projeto é clara: **nada de conteúdo de tela nem títulos de janela**. A proposta abaixo fica
dentro dessa regra em quase tudo. O único sentido novo, o áudio da reunião, só liga com um "sim" a cada
chamada.

## Parte 1: entender o que está sendo trabalhado

### A ideia: um "contexto atual" calculado sem tokens

Um módulo novo no core, `core/src/mind/context.rs`, monta a cada minuto um retrato pequeno:

```json
{
  "projeto": "oficina",
  "branch": "feat/dock-musica",
  "linguagens": ["Swift", "Rust"],
  "atividade": "programando",      // programando | revisando | reunião | lendo | pausa
  "desde": 1731420000,
  "sinais": ["Xcode em foco", "sessão do Claude Code ativa", "3 arquivos alterados"],
  "pendencias": ["CI vermelho no PR #42"]
}
```

São só regras e contagens, como o resto da mente. O retrato vai para o resumo do cérebro (`summary()`), então
quando você abre o chat ela já sabe em que você está, sem você explicar.

### Sinais, do mais barato ao mais invasivo

| Nível | Sinal | Como | Permissão | Dentro da regra atual? |
|---|---|---|---|---|
| 0 | App em foco, apps abertos | já existe | nenhuma | sim |
| 0 | Projeto e branch do Claude Code | já existe | nenhuma | sim |
| 1 | **Projeto ativo agora** | última atividade por projeto nos logs que o core já lê (só o horário) | nenhuma | sim |
| 1 | **Estado do git** dos projetos conhecidos | `git status --porcelain` (contagem), `git log -5 --format=%s`, nomes dos arquivos mexidos na última hora | nenhuma | sim (arquivos do próprio projeto, não da tela) |
| 1 | **Linguagem** do projeto | extensões dos arquivos alterados | nenhuma | sim |
| 1 | **GitHub** | `gh pr list --author @me`, checks do PR do branch atual, revisões pedidas | `gh` já usado para issues | sim |
| 1 | **Agenda** | EventKit: há evento agora? começa em 10 min? | Calendário (pede uma vez) | sim |
| 2 | Pasta do editor | arquivos de "abertos recentemente" do VS Code/Cursor/Xcode | nenhuma | zona cinza: não é tela, mas é do editor |
| 3 | Arquivo da janela em foco | Acessibilidade (`AXDocument`) | Acessibilidade | **não**: é informação de janela |
| ✗ | OCR ou captura de tela | — | Gravação de tela | **não, e não recomendo** |

Recomendação: fazer os níveis 0 e 1, que já dão quase tudo. Nível 2 como opção "Modo atento" desligada por
padrão. Nível 3 só se a regra for mudada de propósito no CONTRIBUTING.md. OCR fica de fora.

### Como a "atividade" é deduzida

Regras simples, sem modelo:

- app de trabalho em foco (`is_work`) + projeto ativo há menos de 5 min → **programando**;
- navegador em foco + PR com revisão pedida → **revisando**;
- microfone em uso por app de chamada → **reunião** (Parte 2);
- ocioso > 2 min → **pausa**.

Blocos contínuos viram um **diário do dia** (só números e nomes de projeto): "Hoje: 3h10 no oficina, 40 min em
reunião, 1 PR aberto". Fica em `mind.json` e o "Esquecer tudo" apaga.

### O que ela faz com isso (iniciativas novas em `best`)

| Situação | Iniciativa | Gasta tokens? |
|---|---|---|
| CI vermelho no PR do branch atual | "O CI do PR #42 falhou. Quer que um agente investigue?" | só se aceitar |
| Revisão pedida a você há mais de 1 dia | "A Ana pediu sua revisão ontem." | não |
| Muitas horas no mesmo branch sem commit | "Faz 2h sem commit no feat/dock. Quer salvar um ponto?" | não |
| Reunião em 10 min (agenda) | "Reunião às 15h. Te aviso quando começar?" | não |
| Fim do dia | diário do dia em um balão | não |

Os bandits que já existem aprendem quais você aceita. Durante **reunião** e **foco**, nenhuma iniciativa
aparece, exceto a pergunta da transcrição.

### Memória por projeto

Fatos com "lembre que…" ditos enquanto um projeto está ativo ficam presos a ele (`Fact { projeto: Some(..) }`).
O resumo do cérebro leva só os fatos do projeto atual e os gerais, o que mantém o prompt curto.

## Parte 2: perceber chamadas e oferecer a transcrição

### Detectar sem olhar a tela

O sinal certo é o **microfone**, não a janela:

1. **Microfone em uso no Mac**: `kAudioDevicePropertyDeviceIsRunningSomewhere` no dispositivo de entrada
   padrão, com listener do Core Audio. Custo zero parado. Diz *que* o microfone está em uso.
2. **Quem está usando**: no macOS 14+, `kAudioHardwarePropertyProcessObjectList` lista os processos de áudio; para
   cada um, `kAudioProcessPropertyIsRunningInput` e `kAudioProcessPropertyPID` → bundle do app. Há relatos de que
   o listener desse sinal falha no macOS 15, então a leitura é feita quando o sinal 1 muda, não por listener.
3. **Lista de apps de chamada**: Discord (`com.hnc.Discord`), Zoom (`us.zoom.xos`), Teams (`com.microsoft.teams2`),
   WhatsApp (`net.whatsapp.WhatsApp`), FaceTime (`com.apple.FaceTime`), Slack (`com.tinyspeck.slackmacgap`).
   Navegador usando o microfone (Google Meet) vira "parece uma chamada no Chrome".
4. **Agenda** (se permitida) aumenta a confiança e dá o nome da reunião.

Para evitar alarme falso: microfone aberto pelo app de chamada por mais de 10 s, ignorando ditado, Siri,
Gravador e a própria Oficina. O fim é o microfone liberado por mais de 20 s.

O app manda ao core `{kind: "call_start", bundle, name}` e `{kind: "call_end"}` pelo mesmo canal dos
`MindEvent`. Na rede da mente vale como foco forte (mais um canal de entrada ou o canal `TRABALHANDO` em
intensidade alta).

### A pergunta

Balão na Faísca, uma vez por chamada:

> Entrou numa chamada no Zoom. Quer que eu ouça e anote?
> **Ouvir** · Agora não · Nunca no Discord

- "Nunca neste app" fica salvo (Discord costuma ser jogo, não reunião).
- Sem resposta em 60 s, conta como "agora não".
- Enquanto ouve, ela coloca **fones** (peça nova em `PROPS`) e o notch mostra um ponto vermelho. Clique na
  Faísca → "Parar de ouvir". Indicador visível o tempo todo.

### Capturar o áudio

| Opção | Permissão | Prós | Contras |
|---|---|---|---|
| **Process tap do Core Audio** (`AudioHardwareCreateProcessTap`, macOS 14.2+) só do app da chamada + microfone | "Gravação de áudio do sistema" (`NSAudioCaptureUsageDescription`) | pega só a chamada; separa "você" (microfone) de "outros" (tap) | API nova, pouco documentada |
| ScreenCaptureKit com áudio | Gravação de tela | API madura | pede permissão de **tela**, o que contraria a regra e assusta |
| Dispositivo virtual (BlackHole) | instalar driver | funciona em qualquer macOS | dependência e configuração manual |

Recomendação: **process tap + microfone**, cada um num fluxo. Isso já resolve a etiqueta de quem fala em dois
grupos ("Você" e "Outros") sem modelo de diarização.

### Transcrever no Mac, sem tokens

- **macOS 26**: `SpeechAnalyzer` + `SpeechTranscriber`, no aparelho e sem rede. Testes publicados mostram que é
  mais rápido que o Whisper com precisão parecida. Conferir `pt-BR` em `supportedLocales` antes de prometer.
- **macOS 14 e 15**: `SFSpeechRecognizer` com `requiresOnDeviceRecognition = true` (ou `DictationTranscriber`).
  Pior, mas sem dependências.
- whisper.cpp fica como plano C; seria a primeira dependência pesada do app.

O áudio não é guardado. Só o texto, com horário, vai para o core.

### Depois da chamada

- Core guarda em `reunioes/<id>.md` (título da agenda, app, duração, transcrição).
- A Faísca pergunta: "Quer um resumo com decisões e tarefas?" Isso **gasta tokens**, então é pergunta.
- O resumo sai pelo cérebro (Sonnet no Automático) com três blocos: decisões, tarefas com dono, dúvidas.
- Tarefas podem virar, com aprovação, missão de agente ou issue (o fluxo de `@@delegar` já existe).

### Cuidados

- **Consentimento**: pela LGPD, o ideal é avisar os outros participantes. Junto com "Ouvir", a Faísca copia
  uma frase pronta ("Estou usando transcrição automática local nesta chamada") para colar no chat da reunião.
- Transcrições entram no "Esquecer tudo" e têm botão de apagar individual.
- Nada sai do Mac sem pedido: transcrever é local; só o resumo usa o Claude.

## Onde mexer

| Peça | Arquivo |
|---|---|
| Detector de microfone e processo | `app/Sources/Oficina/Call.swift` (novo) |
| Captura e transcrição | `app/Sources/Oficina/Listen.swift` (novo) |
| Fones da Faísca | `core/src/mind/outfit.rs` (`PROPS`) e `Pet.swift` (`wear`) |
| Contexto atual e diário | `core/src/mind/context.rs` (novo), `mod.rs` (`summary`, `best`) |
| Git e GitHub dos projetos | `core/src/engine.rs` junto de `set_projects` |
| Reuniões | `core/src/meeting.rs` (novo); rotas `GET/POST /v1/meetings`, `POST /v1/meetings/{id}/summarize` |
| Textos | `L10n.swift` |

## Fases

1. **Contexto nível 1** (sem permissões): projeto ativo, git, linguagem, diário. Testes com repositórios
   sintéticos num `HOME` temporário. ~3 dias.
2. **Detectar chamada + perguntar**: `Call.swift`, eventos na mente, silenciar iniciativas, fones. ~2 dias.
3. **Transcrição local**: process tap + microfone + Speech, salvar no core. ~4 dias, a parte mais arriscada.
4. **Resumo e tarefas**: rota de resumo, cartões no chat, missão/issue com aprovação. ~2 dias.
5. **GitHub e agenda** nas iniciativas. ~2 dias.

## Riscos

- O process tap tem relatos de buffers zerados em algumas versões; testar no macOS do Mac real antes da fase 4.
- Ler o PID de quem usa o microfone só existe a partir do macOS 14; antes disso, só "microfone em uso".
- `pt-BR` no `SpeechTranscriber` precisa ser confirmado.
- Medir a CPU durante a transcrição; a meta é ficar abaixo de 10% num M1.

## Fontes

- [kAudioProcessPropertyIsRunningInput](https://developer.apple.com/documentation/coreaudio/kaudioprocesspropertyisrunninginput) e [AudioHardwareProcess](https://developer.apple.com/documentation/coreaudio/audiohardwareprocess)
- [Detectar microfone em uso (fórum da Apple)](https://developer.apple.com/forums/thread/741026), [listener falhando no macOS 15](https://developer.apple.com/forums/thread/748257)
- [Process tap com buffers zerados (fórum da Apple)](https://developer.apple.com/forums/thread/825780)
- [SpeechAnalyzer, WWDC25](https://nonstrict.eu/wwdcindex/wwdc2025/277/), [comparação com Whisper (MacRumors)](https://macrumors.com/2025/06/18/apple-transcription-api-faster-than-whisper)
