#!/bin/bash
# Imita o protocolo do `claude` para testar o core sem gastar assinatura.
echo "ARGS: $*" >> "${FAKE_LOG:-/dev/null}"
env | grep -E '^(ANTHROPIC_|CLAUDECODE)' >> "${FAKE_LOG:-/dev/null}"

for a in "$@"; do
  case "$a" in
    --cloud=*)
      [[ "$a" == *falha-nuvem* ]] && { echo "not logged in" >&2; exit 1; }
      echo "Created https://claude.ai/code/session_fake123"
      exit 0 ;;
  esac
done

prompt=$(cat)
if [ "$prompt" = "/usage" ]; then
  [ -n "${FAKE_NO_LIMITS:-}" ] && { echo '{"type":"result","result":"Total cost","is_error":false}'; exit 0; }
  echo '{"type":"assistant","message":{"role":"assistant","usage_report":{"rate_limits":{"limits":[{"kind":"session","percent":23.5,"resets_at":"2026-11-09T20:00:00Z"},{"kind":"weekly_all","percent":41,"resets_at":"2026-11-12T20:00:00Z"}]}}}}'
  echo '{"type":"result","result":"ok","is_error":false}'
  exit 0
fi
delta() { printf '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}}\n' "$1"; }
echo '{"type":"system","subtype":"init","session_id":"sess-1"}'

case "$prompt" in
  *delegar-nuvem*) t='@@delegar nuvem: fazer na nuvem' ;;
  *delegar-pc*)    t='@@delegar maquina: fazer no pc' ;;
  *lento*)         trap 'exit 130' INT; sleep 30 & wait; t='nunca' ;;
  *erro*)
    echo '{"type":"result","result":"Please run /login","is_error":true,"session_id":"sess-1"}'
    exit 1 ;;
  *)               t="eco: $prompt" ;;
esac
delta "${t:0:1}"; delta "${t:1}"
printf '{"type":"result","result":"%s","is_error":false,"session_id":"sess-1"}\n' "$t"
