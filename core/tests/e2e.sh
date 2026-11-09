#!/bin/bash
# Fluxo completo com dois daemons reais e um `claude` falso.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../target/release/oficinad"
tmp="$(mktemp -d)"
export FAKE_LOG="$tmp/args.log" OFICINA_CLAUDE="$here/fake_claude.sh"
export ANTHROPIC_API_KEY=nao-pode-vazar
chmod +x "$OFICINA_CLAUDE"

fails=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FALHA $1 -> $2"; fails=$((fails+1)); }
check() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "$3"; }
equal() { [[ "$3" == "$2" ]] && ok "$1" || bad "$1" "$3"; }

up() { for _ in $(seq 1 100); do curl -s -m1 -o /dev/null "http://127.0.0.1:$1/v1/health" && return; sleep 0.05; done; }

mkdir -p "$tmp/a" "$tmp/b"
OFICINA_HOME="$tmp/b" OFICINA_LISTEN=127.0.0.1:7902 "$bin" 2>/dev/null & pb=$!
up 7902
tb=$(cat "$tmp/b/token")
cat > "$tmp/a/config.json" <<EOF
{"listen":"127.0.0.1:7901","execute_local":false,
 "machines":[{"name":"morta","url":"http://127.0.0.1:7999","token":"x"},
             {"name":"oficina-b","url":"http://127.0.0.1:7902","token":"$tb"}]}
EOF
OFICINA_HOME="$tmp/a" "$bin" 2>/dev/null & pa=$!
up 7901
trap 'kill $pa $pb 2>/dev/null; rm -rf "$tmp"' EXIT
ta=$(cat "$tmp/a/token")

api()  { curl -s -m 8 -H "Authorization: Bearer $ta" "$@"; }
send() { api -X POST -d "$1" -H 'content-type: application/json' http://127.0.0.1:7901/v1/messages | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])'; }
get()  { api "http://127.0.0.1:7901/v1/tasks/$1" | python3 -c "import json,sys;t=json.load(sys.stdin);print(t['$2'])"; }
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
id=$(send '{"text":"de novo"}'); wait_for "$id" done >/dev/null
check 'retoma a sessão' '--resume sess-1' "$(tail -2 "$tmp/args.log" | head -2)"
check 'sem ferramentas' '--tools  --setting-sources' "$(tail -1 "$tmp/args.log")"
id=$(send '{"text":"erro"}'); check 'erro vira falha' failed "$(wait_for "$id" failed\ done)"
check 'mostra o erro' 'Please run /login' "$(get "$id" error)"

check 'nova conversa' 204 "$(api -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:7901/v1/brain/reset)"
id=$(send '{"text":"depois do reset"}'); wait_for "$id" done >/dev/null
equal 'começa sem retomar' 0 "$(tail -1 "$tmp/args.log" | grep -c -- '--resume')"

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

echo 'persistência'
last=$(send '{"text":"guardar"}'); wait_for "$last" done >/dev/null; sleep 1.3
kill "$pa"; wait "$pa" 2>/dev/null
OFICINA_HOME="$tmp/a" "$bin" 2>/dev/null & pa=$!
up 7901
check 'sobrevive a reinício' 'eco: guardar' "$(get "$last" output)"

echo
[ "$fails" = 0 ] && echo "e2e: tudo certo" || { echo "e2e: $fails falha(s)"; exit 1; }
