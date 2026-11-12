#!/bin/bash
# Gera build/Oficina.app com o core embutido.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

(cd "$root/core" && cargo build --release --quiet)
(cd "$root/app" && swift build -c release 2>&1 | tail -1)

out="$root/build/Oficina.app/Contents"
rm -rf "$root/build/Oficina.app"
mkdir -p "$out/MacOS"
cp "$root/app/.build/release/Oficina" "$out/MacOS/Oficina"
cp "$root/core/target/release/oficinad" "$out/MacOS/oficinad"
mkdir -p "$out/Resources"
cp -R "$root/app/Localization/"*.lproj "$out/Resources/"
strip "$out/MacOS/Oficina" 2>/dev/null || true
strip "$out/MacOS/oficinad" 2>/dev/null || true

cat > "$out/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Oficina</string>
  <key>CFBundleIdentifier</key><string>dev.oficina.app</string>
  <key>CFBundleExecutable</key><string>Oficina</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>CFBundleLocalizations</key><array><string>pt-BR</string><string>en</string></array>
  <key>NSMicrophoneUsageDescription</key><string>Com a sua permissão em cada chamada, a Faísca ouve sua voz para anotar a reunião. A transcrição é feita no Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>A transcrição das reuniões é feita no próprio Mac, sem internet.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Para anotar o que os outros dizem na chamada, a Faísca ouve só o áudio do app da chamada, nunca a tela.</string>
  <key>NSAppleEventsUsageDescription</key><string>A Oficina usa automação para esvaziar a Lixeira e trocar o modo escuro quando você pede.</string>
</dict></plist>
EOF

codesign --force --deep --sign - "$root/build/Oficina.app" >/dev/null 2>&1
du -sh "$root/build/Oficina.app"
