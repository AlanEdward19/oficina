#!/bin/bash
# Gera build/Oficina-Windows.zip: Oficina.exe (pet, conversa, bandeja), oficinad.exe (o core)
# e WebView2Loader.dll. Roda no Windows (Git Bash, alvo msvc) ou em Linux/macOS com mingw-w64.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${OS:-}" == "Windows_NT" ]]; then
  target=x86_64-pc-windows-msvc
else
  target=x86_64-pc-windows-gnu
  export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="${CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER:-x86_64-w64-mingw32-gcc}"
  rustup target add "$target" >/dev/null
fi
(cd "$root/core" && cargo build --release --quiet --target "$target")
(cd "$root/desktop" && cargo build --release --quiet --target "$target")
out="$root/build/Oficina-Windows"
rm -rf "$out" && mkdir -p "$out"
cp "$root/core/target/$target/release/oficinad.exe" "$out/"
cp "$root/desktop/target/$target/release/Oficina.exe" "$out/"
loader=$(find "$root/desktop/target/$target/release/build" -path "*webview2-com-sys*/out/x64/WebView2Loader.dll" | head -1)
[ -n "$loader" ] && cp "$loader" "$out/"
cat > "$out/LEIA-ME.txt" <<'TXT'
Faísca para Windows

1. Deixe os três arquivos na mesma pasta e abra Oficina.exe.
2. Se o Mac com a Oficina estiver no mesmo Wi-Fi, este computador vira um corpo
   da mesma Faísca: ela aparece aqui quando vem para cá. Senão, a Faísca mora aqui.
3. O Windows pode perguntar sobre o firewall: permita em redes privadas.

Para a Faísca morar aqui, instale o Claude Code e faça login (claude).
TXT
(cd "$root/build" && rm -f Oficina-Windows.zip && (zip -qr Oficina-Windows.zip Oficina-Windows 2>/dev/null || python3 -m zipfile -c Oficina-Windows.zip Oficina-Windows 2>/dev/null || python -m zipfile -c Oficina-Windows.zip Oficina-Windows)) || true
du -sh "$root/build/Oficina-Windows"* 2>/dev/null || true
