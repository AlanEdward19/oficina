#!/bin/bash
# Fluxo completo com dois daemons reais e um `claude` falso.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../target/release/oficinad"
tmp="$(mktemp -d)"
export FAKE_LOG="$tmp/args.log" OFICINA_CLAUDE="$here/fake_claude.sh" OFICINA_GH="$here/fake_gh.sh"
chmod +x "$here/fake_gh.sh"
export ANTHROPIC_API_KEY=nao-pode-vazar
chmod +x "$OFICINA_CLAUDE"

fails=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FALHA $1 -> $2"; fails=$((fails+1)); }
check() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "$3"; }
equal() { [[ "$3" == "$2" ]] && ok "$1" || bad "$1" "$3"; }

up() { for _ in $(seq 1 100); do curl -s -m1 -o /dev/null "http://127.0.0.1:$1/v1/health" && return; sleep 0.05; done; }

mkdir -p "$tmp/a" "$tmp/b"
OFICINA_HOME="$tmp/b" OFICINA_LISTEN=127.0.0.1:7902 OFICINA_BODY_LISTEN=127.0.0.1:7913 "$bin" 2>/dev/null & pb=$!
up 7902
tb=$(cat "$tmp/b/token")
cat > "$tmp/a/config.json" <<EOF
{"listen":"127.0.0.1:7901","execute_local":false,"repo":"dono/oficina",
 "machines":[{"name":"morta","url":"http://127.0.0.1:7999","token":"x"},
             {"name":"oficina-b","url":"http://127.0.0.1:7902","token":"$tb"}]}
EOF
OFICINA_HOME="$tmp/a" OFICINA_BODY_LISTEN=127.0.0.1:7914 OFICINA_VOICE_WAIT_MS=0 "$bin" 2>/dev/null & pa=$!
up 7901
trap 'kill $pa $pb 2>/dev/null; rm -rf "$tmp"' EXIT
ta=$(cat "$tmp/a/token")

api()  { curl -s -m 8 -H "Authorization: Bearer $ta" "$@"; }
send() { api -X POST -d "$1" -H 'content-type: application/json' http://127.0.0.1:7901/v1/messages | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])'; }
get()  { api "http://127.0.0.1:7901/v1/tasks/$1" | python3 -c "import json,sys;t=json.load(sys.stdin);print(t['$2'])"; }
py() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }
wait_for() { for _ in $(seq 1 40); do s=$(get "$1" status); [[ " $2 " == *" $s "* ]] && { echo "$s"; return; }; sleep 0.1; done; echo "timeout($s)"; }

echo 'segurança'
check 'saúde é pública' '"ok":true' "$(curl -s http://127.0.0.1:7901/v1/health)"
check 'sem token: 401' 401 "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7901/v1/tasks)"
check 'token errado: 401' 401 "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer ruim' http://127.0.0.1:7901/v1/tasks)"
check 'token com 0600' 600 "$(stat -f %Lp "$tmp/a/token")"
check 'vazia recusada' 400 "$(api -o /dev/null -w '%{http_code}' -X POST -d '{"text":"  "}' -H 'content-type: application/json' http://127.0.0.1:7901/v1/messages)"

echo 'conversa'
id=$(send '{"text":"olá"}'); check 'termina' done "$(wait_for "$id" done\ failed)"
check 'responde' 'eco: olá' "$(get "$id" output)"
conv=$(get "$id" conversation)
id=$(send "{\"text\":\"de novo\",\"conversation\":\"$conv\"}"); wait_for "$id" done >/dev/null
again=$id
check 'retoma a sessão' '--resume sess-1' "$(tail -2 "$tmp/args.log" | head -2)"
check 'sem ferramentas' '--tools  --setting-sources' "$(tail -1 "$tmp/args.log")"
id=$(send '{"text":"erro"}'); check 'erro vira falha' failed "$(wait_for "$id" failed\ done)"
check 'mostra o erro' 'Please run /login' "$(get "$id" error)"

check 'nova conversa' 204 "$(api -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:7901/v1/brain/reset)"
id=$(send '{"text":"depois do reset"}'); wait_for "$id" done >/dev/null
equal 'começa sem retomar' 0 "$(tail -1 "$tmp/args.log" | grep -c -- '--resume')"

echo 'conversas'
check 'mesma conversa' "$conv" "$(get "$again" conversation)"
other=$(send '{"text":"assunto novo"}'); wait_for "$other" done >/dev/null
equal 'conversa nova começa sem retomar' 0 "$(tail -1 "$tmp/args.log" | grep -c -- '--resume')"
convs=$(api http://127.0.0.1:7901/v1/conversations)
check 'lista com título da primeira mensagem' '"title":"olá"' "$convs"
check 'mais recente primeiro' "$(get "$other" conversation)" "$(echo "$convs" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])')"
check 'sessão do Claude guardada' '"session":"sess-1"' "$convs"
hist=$(api "http://127.0.0.1:7901/v1/conversations/$conv")
equal 'histórico da conversa' 2 "$(echo "$hist" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["tasks"]))')"
check 'renomear' 204 "$(api -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{"title":"Painel da cozinha"}' "http://127.0.0.1:7901/v1/conversations/$conv/rename")"
check 'apagar conversa' 204 "$(api -o /dev/null -w '%{http_code}' -X DELETE "http://127.0.0.1:7901/v1/conversations/$(get "$other" conversation)")"
check 'id inválido recusado' 404 "$(api -o /dev/null -w '%{http_code}' 'http://127.0.0.1:7901/v1/conversations/..%2Fstate')"

echo 'delegação'
id=$(send '{"text":"delegar-nuvem"}'); check 'nuvem termina' done "$(wait_for "$id" done\ failed)"
check 'link da sessão' session_fake123 "$(get "$id" url)"
check 'marcador oculto' Agente "$(get "$id" output)"
id=$(send '{"text":"delegar-pc"}'); check 'máquina pede aprovação' awaiting_approval "$(wait_for "$id" awaiting_approval\ done\ failed)"
n=$(grep -c 'acceptEdits' "$tmp/args.log")
equal 'nada roda antes de aprovar' 0 "$n"
api -X POST "http://127.0.0.1:7901/v1/tasks/$id/approve" >/dev/null
check 'aprovada termina' done "$(wait_for "$id" done\ failed)"
check 'escolhe máquina online' oficina-b "$(get "$id" machine)"
check 'executa instrução do cérebro' 'eco: fazer no pc' "$(get "$id" output)"
check 'aprovar duas vezes: 409' 409 "$(api -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:7901/v1/tasks/$id/approve")"

echo 'pedidos de melhoria'
id=$(send '{"text":"delegar-melhoria"}'); check 'melhoria pede aprovação' awaiting_approval "$(wait_for "$id" awaiting_approval\ done\ failed)"
equal 'nada no GitHub antes de aprovar' 0 "$(grep -c '^GH:' "$tmp/args.log")"
api -o /dev/null -X POST "http://127.0.0.1:7901/v1/tasks/$id/approve"
check 'abre a issue' done "$(wait_for "$id" done\ failed)"
check 'link da issue' 'issues/42' "$(get "$id" url)"
check 'título com o tipo' '[Roupa] chapéu de pirata' "$(grep '^GH:' "$tmp/args.log" | tail -1)"
check 'etiqueta do agente' '--label agente' "$(grep '^GH:' "$tmp/args.log" | tail -1)"
rid=$(api -X POST -H 'content-type: application/json' -d '{"kind":"widget","text":"Clima na Dock","agent":false}' http://127.0.0.1:7901/v1/requests | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
check 'pedido pelo menu' done "$(wait_for "$rid" done\ failed)"
equal 'sem agente quando não pedido' 0 "$(grep '^GH:' "$tmp/args.log" | tail -1 | grep -c 'agente')"

echo 'ajustes e fábrica'
post() { api -X POST -H 'content-type: application/json' -d "$2" "http://127.0.0.1:7901/v1/$1"; }
post settings '{"name":"Zeca","personality":"Bem-humorada.","brain_model":"opus","brain_effort":"high","body_color":"#3366FF"}' >/dev/null
check 'ajustes salvos' '"name":"Zeca"' "$(api http://127.0.0.1:7901/v1/settings)"
id=$(send '{"text":"olá de novo"}'); wait_for "$id" done >/dev/null
line=$(grep -- '--system-prompt' "$tmp/args.log" | tail -1)
check 'cérebro com o nome' 'Você é Zeca' "$line"
check 'cérebro com o modelo' '--model opus' "$line"
check 'cérebro com o esforço' '--effort high' "$line"
post settings '{"brain_model":"haiku"}' >/dev/null
ana=$(post agents '{"name":"Ana","role":"Revisa código","model":"sonnet","effort":"high"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
bia=$(post agents '{"name":"Bia","role":"Escreve testes","model":"opus","effort":"low"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
check 'nome repetido recusado' 400 "$(api -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{"name":"ana","role":"x"}' http://127.0.0.1:7901/v1/agents)"
conv_ana=$(api http://127.0.0.1:7901/v1/factory | py '[a for a in d["agents"] if a["name"]=="Ana"][0]["conversation"]')
id=$(send "{\"text\":\"oi Ana\",\"conversation\":\"$conv_ana\"}"); check 'mensagem direta ao agente' done "$(wait_for "$id" done\ failed)"
check 'agente responde' 'resposta do agente' "$(get "$id" output)"
line=$(grep -- '--append-system-prompt' "$tmp/args.log" | tail -1)
check 'agente com modelo e esforço' '--model sonnet --effort high' "$line"
id=$(send "{\"text\":\"mais uma\",\"conversation\":\"$conv_ana\"}"); wait_for "$id" done >/dev/null
check 'agente retoma a sessão' '--resume sess-agente' "$(grep -- '--append-system-prompt' "$tmp/args.log" | tail -1)"
id=$(send '{"text":"delegar-agente"}'); check 'cérebro delega ao agente' done "$(wait_for "$id" done\ failed)"
check 'resposta veio do agente' 'resposta do agente' "$(get "$id" output)"
id=$(send '{"text":"pedir-agente"}'); check 'criar agente pede aprovação' awaiting_approval "$(wait_for "$id" awaiting_approval\ done\ failed)"
api -o /dev/null -X POST "http://127.0.0.1:7901/v1/tasks/$id/approve"; sleep 0.2
check 'agente criado pelo cérebro' 'Nova' "$(api http://127.0.0.1:7901/v1/factory | py '[a["name"] for a in d["agents"]]')"
team=$(post teams "{\"name\":\"Qualidade\",\"members\":[\"$ana\",\"$bia\"]}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["conversation"])')
id=$(send "{\"text\":\"chama-colega\",\"conversation\":\"$team\"}"); wait_for "$id" done >/dev/null; sleep 0.5
replies=$(api "http://127.0.0.1:7901/v1/conversations/$team" | py '[t["output"] for t in d["tasks"]]')
check 'equipe: primeiro responde' '@Bia' "$replies"
check 'equipe: colega mencionado responde' 'recebi do colega' "$replies"
mission() { api http://127.0.0.1:7901/v1/factory | py "[a for a in d['agents'] if a['name']=='$1'][0]['mission']['$2']"; }
post "agents/$bia/missions" '{"goal":"melhorar testes"}' >/dev/null
for _ in $(seq 1 40); do [ "$(mission Bia status)" = aguardando ] && break; sleep 0.1; done
equal 'missão para antes de executar' aguardando "$(mission Bia status)"
check 'etapas de leitura sem editar' 'dontAsk' "$(grep -- '--append-system-prompt' "$tmp/args.log" | tail -1)"
wait=$(api "http://127.0.0.1:7901/v1/conversations/$(api http://127.0.0.1:7901/v1/factory | py '[a for a in d["agents"] if a["name"]=="Bia"][0]["conversation"]')" | py '[t["id"] for t in d["tasks"] if t["status"]=="awaiting_approval"][0]')
api -o /dev/null -X POST "http://127.0.0.1:7901/v1/tasks/$wait/approve"
for _ in $(seq 1 40); do [ "$(mission Bia status)" = concluida ] && break; sleep 0.1; done
equal 'missão concluída' concluida "$(mission Bia status)"
equal 'quatro etapas com veredito' 4 "$(api http://127.0.0.1:7901/v1/factory | py 'len([a for a in d["agents"] if a["name"]=="Bia"][0]["mission"]["log"])')"
post "agents/$ana/missions" '{"goal":"sem-prova"}' >/dev/null
for _ in $(seq 1 40); do [ "$(mission Ana status)" = falhou ] && break; sleep 0.1; done
equal 'sem evidência não passa' falhou "$(mission Ana status)"
# Modelo automático: o mais barato primeiro, sobe quando não dá conta.
caio=$(post agents '{"name":"Caio","role":"Faz de tudo"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
equal 'modelo automático por padrão' auto "$(api http://127.0.0.1:7901/v1/factory | py '[a for a in d["agents"] if a["name"]=="Caio"][0]["model"]')"
conv_caio=$(api http://127.0.0.1:7901/v1/factory | py '[a for a in d["agents"] if a["name"]=="Caio"][0]["conversation"]')
id=$(send "{\"text\":\"resuma este texto\",\"conversation\":\"$conv_caio\"}"); wait_for "$id" done >/dev/null
check 'pedido simples vai para o Haiku' '--model haiku' "$(grep -- '--append-system-prompt' "$tmp/args.log" | tail -1)"
id=$(send "{\"text\":\"corrija o bug no login\",\"conversation\":\"$conv_caio\"}"); wait_for "$id" done >/dev/null
check 'pedido de código vai para o Sonnet' '--model sonnet --effort medium' "$(grep -- '--append-system-prompt' "$tmp/args.log" | tail -1)"
equal 'o chat mostra o modelo' sonnet "$(api "http://127.0.0.1:7901/v1/tasks/$id" | py 'd["model"]')"
post "agents/$caio/missions" '{"goal":"sobe-modelo"}' >/dev/null
for _ in $(seq 1 60); do [ "$(mission Caio status)" = aguardando ] && break; sleep 0.1; done
equal 'etapa refeita um degrau acima' 'concluido' "$(api http://127.0.0.1:7901/v1/factory | py '[a for a in d["agents"] if a["name"]=="Caio"][0]["mission"]["log"][0]["verdict"]')"
check 'falha no Haiku sobe para o Sonnet' 'sonnet' "$(grep -- 'sess-agente\|--append-system-prompt' "$tmp/args.log" | tail -2 | head -1)"
equal 'subida anotada' 1 "$(api http://127.0.0.1:7901/v1/factory | py 'd["router"]["escalations"]')"
check 'apagar agente' 204 "$(api -o /dev/null -w '%{http_code}' -X DELETE "http://127.0.0.1:7901/v1/agents/$ana")"
post settings '{"name":"Faísca"}' >/dev/null

echo 'atalhos e cancelamento'
id=$(send '{"text":"/pc listar"}'); check '/pc roda direto' done "$(wait_for "$id" done\ failed)"
check '/pc sem o prefixo' 'eco: listar' "$(get "$id" output)"
id=$(send '{"text":"/nuvem falha-nuvem"}'); check 'nuvem sem login falha' failed "$(wait_for "$id" failed\ done)"
id=$(send '{"text":"x","target":"machine","machine":"morta"}'); check 'máquina offline falha' failed "$(wait_for "$id" failed\ done)"
check 'explica offline' offline "$(get "$id" error)"
id=$(send '{"text":"/chat lento"}'); sleep 0.3
api -X POST "http://127.0.0.1:7901/v1/tasks/$id/cancel" >/dev/null
check 'cancela' cancelled "$(wait_for "$id" cancelled)"
sleep 2.6; equal 'processo morreu' 0 "$(pgrep -fx 'sleep 30' | wc -l | tr -d ' ')"

echo 'isolamento'
equal 'não vaza chave de API' 0 "$(grep -c ANTHROPIC_API_KEY "$tmp/args.log")"

echo 'limpeza'
# HOME próprio: este bloco nunca pode enxergar a pasta real de quem roda o teste.
ch="$tmp/casa"; mkdir -p "$ch/Library/Caches/com.teste.app" "$tmp/c"
head -c 9000 /dev/zero > "$ch/Library/Caches/com.teste.app/x"
HOME="$ch" OFICINA_HOME="$tmp/c" OFICINA_LISTEN=127.0.0.1:7904 "$bin" 2>/dev/null & pc=$!
up 7904
cpost() { curl -s -m 8 -H "Authorization: Bearer $(cat "$tmp/c/token")" -H 'content-type: application/json' -X POST -d "$2" "http://127.0.0.1:7904/v1/clean/$1"; }
scan=$(cpost scan '{"mode":"junk"}')
check 'varredura acha cache' 'com.teste.app' "$scan"
equal 'varrer não apaga' 1 "$([ -f "$ch/Library/Caches/com.teste.app/x" ] && echo 1)"
equal 'id fora da lista não remove' 0 "$(cpost run '{"mode":"junk","ids":[9999]}' | py 'd["moved"]')"
equal 'continua no lugar' 1 "$([ -f "$ch/Library/Caches/com.teste.app/x" ] && echo 1)"
scan=$(cpost scan '{"mode":"junk"}')
cid=$(echo "$scan" | py '[i["id"] for g in d["groups"] for i in g["items"] if i["name"]=="com.teste.app"][0]')
body='{"mode":"junk","ids":['$cid']}'
equal 'remove o marcado' 1 "$(cpost run "$body" | py 'd["moved"]')"
equal 'foi para a Lixeira' 1 "$([ -f "$ch/.Trash/com.teste.app/x" ] && echo 1)"
equal 'a lista vale uma vez' 0 "$(cpost run "$body" | py 'd["moved"]')"
check 'desinstalar fora de Aplicativos recusa' 400 "$(curl -s -m 8 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "$tmp/c/token")" -H 'content-type: application/json' -X POST -d '{"mode":"uninstall","app":"/etc"}' http://127.0.0.1:7904/v1/clean/scan)"
kill $pc; wait $pc 2>/dev/null

echo 'uso do Claude'
mkdir -p "$tmp/proj/p"
ts=$(python3 -c 'import datetime as d;print(d.datetime.now(d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')
echo "{\"type\":\"assistant\",\"timestamp\":\"$ts\",\"requestId\":\"r\",\"message\":{\"id\":\"m\",\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tokens\":100,\"output_tokens\":23,\"cache_creation_input_tokens\":0}}}" > "$tmp/proj/p/s.jsonl"
tu="$tmp/u"; mkdir -p "$tu"
OFICINA_CLAUDE_PROJECTS="$tmp/proj" OFICINA_HOME="$tu" OFICINA_LISTEN=127.0.0.1:7903 "$bin" 2>/dev/null & pu=$!
up 7903
au="Authorization: Bearer $(cat "$tu/token")"
check 'primeira leitura responde na hora' '"limits":[]' "$(curl -s -m1 -H "$au" http://127.0.0.1:7903/v1/usage)"
for _ in $(seq 1 60); do u=$(curl -s -m1 -H "$au" http://127.0.0.1:7903/v1/usage); [[ "$u" == *'"percent":23.5'* ]] && break; sleep 0.05; done
check 'limites oficiais' '"percent":23.5' "$u"
check 'tokens locais' '"week":123' "$u"
check 'por família' '"model":"Opus"' "$u"
check 'sessão ativa' '"active_sessions":1' "$u"
n=$(grep -c '/usage' "$tmp/args.log" || true); calls=$(grep -c 'no-session-persistence' "$tmp/args.log")
curl -s -o /dev/null -H "$au" http://127.0.0.1:7903/v1/usage; sleep 0.3
equal 'cache evita rodar de novo' "$calls" "$(grep -c 'no-session-persistence' "$tmp/args.log")"
kill $pu 2>/dev/null

echo 'mente'
mind() { api http://127.0.0.1:7901/v1/mind; }
check 'estado da mente' '"drives"' "$(mind)"
check 'aceita eventos' 204 "$(api -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '[{"kind":"pet_petted"},{"kind":"app_focus","bundle":"com.anthropic.claude","name":"Claude"},{"kind":"presence","idle":3,"running":["com.apple.Safari"]}]' http://127.0.0.1:7901/v1/mind/events)"
id=$(send '{"text":"lembre que o painel da cozinha usa ESP32"}'); wait_for "$id" done >/dev/null
check 'lembra do fato' 'painel da cozinha usa ESP32' "$(mind | py 'd["memory"]["facts"]')"
check 'cérebro recebe a memória' 'painel da cozinha usa ESP32' "$(grep -- '--system-prompt' "$tmp/args.log" | tail -1)"
for t in 'quero um agente de IA' 'como treinar um modelo de IA com LLM'; do id=$(send "{\"text\":\"/chat $t\"}"); wait_for "$id" done >/dev/null; done
sug=$(api -X POST http://127.0.0.1:7901/v1/mind/suggest)
check 'propõe roupinha de IA' '"kind":"outfit"' "$sug"
check 'avisa que gasta tokens' 'tokens' "$sug"
iid=$(echo "$sug" | py 'd["id"]')
check 'aceitar devolve a ação' '"type":"outfit"' "$(api -X POST http://127.0.0.1:7901/v1/mind/initiatives/$iid/accept)"
check 'aceitar duas vezes: 409' 409 "$(api -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:7901/v1/mind/initiatives/$iid/accept)"
for _ in $(seq 1 40); do o=$(mind | py 'd["outfit"]["name"] if d.get("outfit") else ""'); [ -n "$o" ] && break; sleep 0.1; done
equal 'veste a roupinha criada' 'AI Engineer' "$o"
check 'tarefa visível no chat' 'Vesti a roupinha' "$(api http://127.0.0.1:7901/v1/tasks | py '[t["output"] for t in d if t["text"].startswith("Criar roupinha")]')"
check 'pede ao Claude sem ferramentas' 'no-session-persistence' "$(grep -B0 -- '--tools  --setting-sources  --no-session' "$tmp/args.log" | tail -1)"
check 'caminha padrão' 'padrao' "$(mind | py 'd["decor"]["id"]')"
check 'sugerir casinha' 201 "$(api -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{"suggestion":"tema de praia"}' http://127.0.0.1:7901/v1/mind/decor)"
for _ in $(seq 1 40); do dn=$(mind | py 'd["decor"]["name"]'); [ "$dn" = "Ninho de Praia" ] && break; sleep 0.1; done
equal 'casinha criada e em uso' 'Ninho de Praia' "$dn"
check 'pedido levou a sugestão' 'tema de praia' "$(api http://127.0.0.1:7901/v1/tasks | py '[t["text"] for t in d if t["text"].startswith("Decorar")]')"
check 'voltar à caminha padrão' 204 "$(api -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{"id":null}' http://127.0.0.1:7901/v1/mind/decor/use)"
check 'tirar a roupinha' 204 "$(api -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{"id":null}' http://127.0.0.1:7901/v1/mind/outfit)"
check 'descansar na Dock' 204 "$(api -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '[{"kind":"pet_rest","secs":600}]' http://127.0.0.1:7901/v1/mind/events)"
equal 'dorme ao descansar' 'True' "$(mind | py 'd["sleeping"]')"
api -o /dev/null -X POST -H 'content-type: application/json' -d '[{"kind":"pet_click"}]' http://127.0.0.1:7901/v1/mind/events
equal 'cutucar acorda' 'False' "$(mind | py 'd["sleeping"]')"
check 'esquecer' 204 "$(api -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:7901/v1/mind/forget)"
equal 'sem fatos depois de esquecer' '[]' "$(mind | py 'd["memory"]["facts"]')"
check 'roupinhas continuam guardadas' 'AI Engineer' "$(mind | py '[o["name"] for o in d["outfits"]]')"

echo 'chamadas e reuniões'
ev() { api -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d "$1" http://127.0.0.1:7901/v1/mind/events; }
check 'entrou em chamada' 204 "$(ev '[{"kind":"call_start","bundle":"us.zoom.xos","name":"Zoom"}]')"
check 'pergunta se deve ouvir' 'Ouvir' "$(mind | py 'd["initiative"]["accept"]')"
check 'oferece nunca neste app' 'Nunca no Zoom' "$(mind | py 'd["initiative"]["never"]')"
check 'sabe da chamada' 'Zoom' "$(mind | py 'd["call"]')"
lid=$(mind | py 'd["initiative"]["id"]')
check 'nunca no Zoom' 204 "$(api -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:7901/v1/mind/initiatives/$lid/never)"
ev '[{"kind":"call_end"}]' >/dev/null
ev '[{"kind":"call_start","bundle":"us.zoom.xos","name":"Zoom"}]' >/dev/null
equal 'não pergunta de novo no Zoom' 'None' "$(mind | py 'd["initiative"]')"
equal 'contexto em reunião' 'reunião' "$(sleep 1.2; mind | py 'd["context"]["activity"]')"
ev '[{"kind":"call_end"}]' >/dev/null
mid=$(api -X POST -H 'content-type: application/json' -d '{"app":"Teams","title":"Daily"}' http://127.0.0.1:7901/v1/meetings | py 'd["id"]')
check 'grava falas' 204 "$(api -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '[{"who":"Você","text":"vamos lançar sexta","at":1},{"who":"Outros","text":"combinado","at":2}]' http://127.0.0.1:7901/v1/meetings/$mid/segments)"
check 'fecha a reunião' 204 "$(api -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:7901/v1/meetings/$mid/end)"
check 'oferece o resumo' 'Resumir' "$(mind | py 'd["initiative"]["accept"]')"
check 'lista as reuniões' 'Daily' "$(api http://127.0.0.1:7901/v1/meetings | py '[m["title"] for m in d]')"
sid=$(api -X POST http://127.0.0.1:7901/v1/meetings/$mid/summarize | py 'd["id"]')
check 'resumo termina' done "$(wait_for "$sid" done\ failed)"
check 'resumo guardado' 'lançar sexta' "$(api http://127.0.0.1:7901/v1/meetings/$mid | py 'd["summary"] or ""')"
check 'apaga a reunião' 204 "$(api -o /dev/null -w '%{http_code}' -X DELETE http://127.0.0.1:7901/v1/meetings/$mid)"

echo 'oficina de hardware'
hv=$(api -X POST -H 'content-type: application/json' -d '{"name":"Óculos com IA","idea":"câmera, microfone e IA pelo celular"}' http://127.0.0.1:7901/v1/hardware)
hid=$(echo "$hv" | py 'd["id"]')
equal 'projeto com nome seguro' 'oculos-com-ia' "$hid"
check 'esqueleto do pacote' 'especificacao.json' "$(echo "$hv" | py 'd["files"]')"
check 'agente da missão' 'HW-oculos-com-ia' "$(api http://127.0.0.1:7901/v1/factory | py '[a["name"] for a in d["agents"]]')"
hdir="$tmp/a/hardware/$hid"
cat > "$hdir/especificacao.json" <<'JSON'
{"nome":"Óculos","requisitos":{"autonomia_h":4},"bateria":{"capacidade_mah":300},
 "modos":[{"nome":"BLE","corrente_ma":20,"fracao":0.85},{"nome":"Wi-Fi","corrente_ma":200,"fracao":0.1},{"nome":"Áudio","corrente_ma":80,"fracao":0.05}],
 "pecas":[{"nome":"XIAO ESP32-S3 Sense","massa_g":4,"preco_brl":120}]}
JSON
check 'simula sem tokens' '5,85 h' "$(api -X POST http://127.0.0.1:7901/v1/hardware/$hid/run/sim | py 'd["output"]')"
check 'relatório no projeto' 'Autonomia' "$(api http://127.0.0.1:7901/v1/hardware/$hid | py '[c["nome"] for c in d["report"]["checks"]]')"
check 'linha de comando do agente' 'Veredito: passou' "$(cd "$hdir" && OFICINA_HOME="$tmp/a" "$bin" hw sim .)"
check 'fora do projeto é recusado' 2 "$(cd "$tmp" && OFICINA_HOME="$tmp/a" "$bin" hw sim . >/dev/null 2>&1; echo $?)"
check 'diagrama posicionado' "('Projeto', 1)" "$(api http://127.0.0.1:7901/v1/hardware/$hid/diagram | py '[(n["label"], n["layer"]) for n in d["nodes"]]')"
check 'firmware sem projeto explica' 'platformio.ini' "$(api -X POST http://127.0.0.1:7901/v1/hardware/$hid/run/firmware | py 'd["output"]')"
check 'build sem modelo explica' 'modelo.py' "$(api -X POST http://127.0.0.1:7901/v1/hardware/$hid/run/build | py 'd["output"]')"
check 'apaga o projeto' 204 "$(api -o /dev/null -w '%{http_code}' -X DELETE http://127.0.0.1:7901/v1/hardware/$hid)"

echo 'presença única'
pres() { api http://127.0.0.1:7901/v1/presence | py "$1"; }
code=$(api -X POST http://127.0.0.1:7901/v1/bodies/pairing | py 'd["code"]')
up 7914
pair=$(curl -s -X POST -H 'content-type: application/json' -d "{\"code\":\"$code\",\"room\":\"Sala\"}" http://127.0.0.1:7914/v1/body/pair)
bt=$(echo "$pair" | py 'd["token"]'); bid=$(echo "$pair" | py 'd["id"]')
body() { curl -s -m 30 -H "Authorization: Bearer $bt" "$@"; }
check 'código vale uma vez' 403 "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d "{\"code\":\"$code\"}" http://127.0.0.1:7914/v1/body/pair)"
check 'dispositivo sem token: 401' 401 "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7914/v1/body/next)"
check 'token principal não vale lá' 401 "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ta" http://127.0.0.1:7914/v1/body/next)"
check 'porta dos dispositivos não tem a API' 404 "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ta" http://127.0.0.1:7914/v1/tasks)"
check 'dispositivo online' 'True' "$(pres '[b["online"] for b in d["bodies"]]')"
equal 'começa em casa' 'casa' "$(pres 'd["holder"]')"
id=$(send '{"text":"chamar-sala"}'); wait_for "$id" done >/dev/null
check 'cérebro manda ela para a sala' 'Fui até a Sala' "$(get "$id" output)"
equal 'uma Faísca só: está na sala' "$bid" "$(pres 'd["holder"]')"
got=""; for _ in 1 2 3; do got="$got$(body 'http://127.0.0.1:7914/v1/body/next?wait=3')"; [[ "$got" == *listen* ]] && break; done
check 'chega na sala' '"arrive"' "$got"
check 'fala lá' 'Ana, o Alan está te chamando' "$got"
check 'e espera a resposta' '"listen"' "$got"
check 'ouve a sala' 202 "$(body -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{"text":"já vou"}' http://127.0.0.1:7914/v1/body/heard)"
got=""; for _ in 1 2 3 4; do got="$got$(body 'http://127.0.0.1:7914/v1/body/next?wait=3')"; [[ "$got" == *"eco: já vou"* ]] && break; done
check 'responde falando na sala' 'eco: já vou' "$got"
check 'conversa viva: avisa e vem depois' 'will_come' "$(api -X POST -H 'content-type: application/json' -d '{}' http://127.0.0.1:7901/v1/presence/call | py 'd["outcome"]')"
equal 'ainda na sala' "$bid" "$(pres 'd["holder"]')"
check 'forçar sempre traz' 'came' "$(api -X POST -H 'content-type: application/json' -d '{"force":true}' http://127.0.0.1:7901/v1/presence/call | py 'd["outcome"]')"
equal 'voltou para casa' 'casa' "$(pres 'd["holder"]')"
got="$(body 'http://127.0.0.1:7914/v1/body/next?wait=2')"
check 'despede e sai da sala' '"leave"' "$got"
check 'na sala não ouve mais' 409 "$(body -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{"text":"oi"}' http://127.0.0.1:7914/v1/body/heard)"
check 'com você no Mac, o botão da caixa espera' 'ocupada' "$(body -X POST http://127.0.0.1:7914/v1/body/call | py 'd["result"]')"
check 'e ela te avisa' 'Alguém na Sala está me chamando' "$(mind | py 'd["thought"]["text"]')"
check 'áudio precisa ser WAV' 400 "$(body -o /dev/null -w '%{http_code}' -X POST --data-binary 'não é wav' http://127.0.0.1:7914/v1/body/audio)"
echo 'dispositivo sem pareamento'
found=$(python3 -c '
import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
s.sendto(b"oficina?", ("127.0.0.1", 7914)); print(s.recvfrom(64)[0].decode())')
check 'responde à descoberta na rede' 'oficina:7914:' "$found"
hello=$(curl -s -X POST -H 'content-type: application/json' -d '{"device":"AA:BB:CC:00:11:22","room":"Cozinha"}' http://127.0.0.1:7914/v1/body/hello)
check 'entra sozinho' 'Caixa' "$(echo "$hello" | py 'd["name"]')"
check 'ela avisa da caixa nova' 'Nova caixa na rede' "$(mind | py 'd["thought"]["text"]')"
hid2=$(echo "$hello" | py 'd["id"]')
check 'dar nome e cômodo' 'Copa' "$(api -X POST -H 'content-type: application/json' -d '{"room":"Copa"}' http://127.0.0.1:7901/v1/bodies/$hid2 | py '[b["room"] for b in d["bodies"]]')"
again=$(curl -s -X POST -H 'content-type: application/json' -d '{"device":"AA:BB:CC:00:11:22"}' http://127.0.0.1:7914/v1/body/hello | py 'd["id"]')
equal 'mesmo aparelho, mesmo dispositivo' "$hid2" "$again"
check 'tela do pet sem token' 200 "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7901/ui/pet.html)"
check 'tela também na porta dos dispositivos' 'Oficina.chat' "$(curl -s http://127.0.0.1:7914/ui/chat.html)"
check 'arquivo fora da lista: 404' 404 "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7901/ui/..%2Ftoken)"
pc=$(curl -s -X POST -H 'content-type: application/json' -d '{"device":"pc-notebook-1","name":"NOTEBOOK","room":"NOTEBOOK","kind":"pc"}' http://127.0.0.1:7914/v1/body/hello)
check 'notebook entra como corpo' 'Novo computador na rede: NOTEBOOK' "$(mind | py 'd["thought"]["text"]')"
pt=$(echo "$pc" | py 'd["token"]'); pid=$(echo "$pc" | py 'd["id"]')
api -o /dev/null -X POST -H 'content-type: application/json' -d "{\"to\":\"$pid\",\"text\":\"Oi, notebook!\"}" http://127.0.0.1:7901/v1/presence/move
got=$(curl -s -m 10 -H "Authorization: Bearer $pt" 'http://127.0.0.1:7914/v1/body/next?wait=2')
check 'no notebook ela fala com a própria voz (sem esperar o Mac)' '"audio":null,"kind":"say","text":"Oi, notebook!"' "$got"
api -o /dev/null -X POST -H 'content-type: application/json' -d '{"force":true}' http://127.0.0.1:7901/v1/presence/call
api -o /dev/null -X POST -H 'content-type: application/json' -d '{"on":false}' http://127.0.0.1:7901/v1/bodies/auto
check 'aceite desligado recusa' 403 "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{"device":"FF:EE:DD:CC:BB:AA"}' http://127.0.0.1:7914/v1/body/hello)"
check 'esquecer o dispositivo' 204 "$(api -o /dev/null -w '%{http_code}' -X DELETE http://127.0.0.1:7901/v1/bodies/$bid)"
check 'token esquecido não vale' 401 "$(body -o /dev/null -w '%{http_code}' http://127.0.0.1:7914/v1/body/next?wait=0)"

echo 'persistência'
last=$(send '{"text":"guardar"}'); wait_for "$last" done >/dev/null; sleep 1.3
kill "$pa"; wait "$pa" 2>/dev/null
OFICINA_HOME="$tmp/a" OFICINA_BODY_LISTEN=127.0.0.1:7914 OFICINA_VOICE_WAIT_MS=0 "$bin" 2>/dev/null & pa=$!
up 7901
check 'sobrevive a reinício' 'eco: guardar' "$(get "$last" output)"

echo
[ "$fails" = 0 ] && echo "e2e: tudo certo" || { echo "e2e: $fails falha(s)"; exit 1; }
