#!/bin/bash
# Imita o `gh issue create` para testar pedidos de melhoria sem abrir issues.
echo "GH: $(printf '%s ' "$@" | tr '\n' ' ')" >> "${FAKE_LOG:-/dev/null}"
case "$*" in
  *"--label sem-etiqueta"*) echo "could not add label: 'sem-etiqueta' not found" >&2; exit 1 ;;
esac
echo "Creating issue in dono/oficina"
echo "https://github.com/dono/oficina/issues/42"
