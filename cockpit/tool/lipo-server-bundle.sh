#!/usr/bin/env bash
# Junta a fatia x86_64 do cockpit-server (plano 58) ao bundle arm64 do host,
# deixando bin/ + lib/ utilizáveis nas DUAS arquiteturas. Necessário porque
# `dart build cli` não cross-compila: cada arquitetura sai de um build próprio
# (o CI monta o x64 num runner Intel). Sem isso, Mac Intel cai no fallback
# in-process.
#
# Uso:
#   tool/lipo-server-bundle.sh <target-bundle> <x64-bundle> [sign-identity]
#
#   <target-bundle>  bundle arm64 a completar, in place (ex.: o do .app em
#                    Resources/cockpit-server-bundle)
#   <x64-bundle>     bundle x86_64 vindo do runner Intel (bin/ + lib/)
#   [sign-identity]  opcional; se dado, reassina cada Mach-O tocado (o lipo
#                    invalida a assinatura anterior). Sem ela, o chamador assina.
#
# DUAS estratégias, e a diferença NÃO é estética:
#
# - dylibs e binários nativos (bin/cockpit, a CLI em Rust) viram Mach-O
#   universais via `lipo -create`. É o caminho normal do macOS.
#
# - o executável do servidor (`bin/cockpit-server`) é um AOT do Dart, e AOT do
#   Dart NÃO PODE ser lipado: o `dart build cli` anexa o snapshot ao fim do
#   Mach-O, e dentro de um container fat o `dartaotruntime` não o encontra mais
#   — ele passa a tratar o primeiro argumento como snapshot e morre com
#   "<arg> is not an AOT snapshot", nas duas arquiteturas. Foi o que quebrou o
#   sidecar (e o bootstrap remoto) da 1.28.0: o servidor nunca subia e todo
#   terminal caía no PTY in-process depois de ~5,8s de backoff.
#   Então ele sai do bundle como DOIS arquivos finos, `cockpit-server-arm64` e
#   `cockpit-server-x64`, e quem escolhe é o runtime (ver
#   `SidecarTerminalConnector.serverBinaryIn`).
#
# Idempotente: rodar duas vezes com o mesmo x64 dá o mesmo resultado.
set -euo pipefail

TARGET="${1:?target bundle ausente}"
X64="${2:?x64 bundle ausente}"
IDENTITY="${3:-}"

[ -d "$TARGET" ] || { echo "[lipo] target não existe: $TARGET" >&2; exit 1; }
[ -d "$X64" ] || { echo "[lipo] x64 bundle não existe: $X64" >&2; exit 1; }

# Executáveis AOT do Dart: fatias separadas, nunca fat (ver cabeçalho).
AOT_EXES="cockpit-server"

sign_if_asked() {
  [ -n "$IDENTITY" ] || return 0
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$1"
}

# Extrai de $1 a fatia $2 para $3 (cópia direta se o arquivo já for fino).
thin_to() {
  local src="$1" arch="$2" dst="$3"
  if lipo -archs "$src" 2>/dev/null | tr ' ' '\n' | grep -qx "$arch"; then
    if [ "$(lipo -archs "$src" | wc -w | tr -d ' ')" = "1" ]; then
      cp "$src" "$dst"
    else
      lipo "$src" -thin "$arch" -output "$dst"
    fi
    chmod +x "$dst"
    return 0
  fi
  return 1
}

# AOT: <exe> (arm64, do target) + contraparte x64 → <exe>-arm64 e <exe>-x64.
split_aot() {
  local rel="bin/$1"
  local dst="$TARGET/$rel"
  local src="$X64/$rel"
  # Já processado numa execução anterior? Então o nome sem sufixo não existe.
  if [ ! -f "$dst" ]; then
    if [ -f "$TARGET/$rel-arm64" ] && [ -f "$TARGET/$rel-x64" ]; then
      echo "[lipo] $rel: fatias já separadas"
    fi
    return 0 # exe ausente (ou já dividido): nada a fazer.
  fi
  if [ ! -f "$src" ]; then
    echo "::error::fatia x64 faltando para $rel (Mac Intel ficaria quebrado)" >&2
    exit 1
  fi
  thin_to "$dst" arm64 "$TARGET/$rel-arm64" || {
    echo "::error::$rel do target não tem fatia arm64" >&2; exit 1; }
  thin_to "$src" x86_64 "$TARGET/$rel-x64" || {
    echo "::error::$rel do bundle x64 não tem fatia x86_64" >&2; exit 1; }
  # O nome sem sufixo some: mantê-lo seria manter o binário fat quebrado como
  # fallback do resolver, exatamente o bug que este script passou a evitar.
  rm -f "$dst"
  sign_if_asked "$TARGET/$rel-arm64"
  sign_if_asked "$TARGET/$rel-x64"
  echo "[lipo] fatias separadas (AOT): $rel-arm64 + $rel-x64"
}

# Nativos: fusão normal em Mach-O universal.
merge_one() {
  local rel="$1"
  local dst="$TARGET/$rel"
  local src="$X64/$rel"
  [ -f "$dst" ] || return 0 # arquivo só existe num layout: nada a fundir.
  if [ ! -f "$src" ]; then
    echo "::error::fatia x64 faltando para $rel (Mac Intel ficaria quebrado)" >&2
    exit 1
  fi
  # Já universal? lipo -create rejeitaria fatias duplicadas; extrai a arm64.
  local armslice
  armslice="$(mktemp)"
  if lipo -archs "$dst" | grep -q x86_64; then
    lipo "$dst" -thin arm64 -output "$armslice"
  else
    cp "$dst" "$armslice"
  fi
  local x64slice="$src"
  if lipo -archs "$src" | grep -q arm64; then
    x64slice="$(mktemp)"
    lipo "$src" -thin x86_64 -output "$x64slice"
  fi
  lipo -create "$armslice" "$x64slice" -output "$dst"
  chmod +x "$dst"
  sign_if_asked "$dst"
  echo "[lipo] universal: $rel ($(lipo -archs "$dst"))"
}

is_aot() {
  local base="$1"
  for e in $AOT_EXES; do [ "$base" = "$e" ] && return 0; done
  return 1
}

for e in $AOT_EXES; do split_aot "$e"; done

# O resto de bin/ e todas as dylibs. libcockpit_pty já sai universal do
# build_server (cc -arch arm64 -arch x86_64), mas passar por aqui é inócuo.
for f in "$TARGET"/bin/*; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  if is_aot "$base"; then continue; fi
  case "$base" in *-arm64|*-x64) continue ;; esac # fatias já separadas
  merge_one "bin/$base"
done
for f in "$TARGET"/lib/*.dylib; do
  [ -f "$f" ] || continue
  merge_one "lib/$(basename "$f")"
done

echo "[lipo] bundle pronto para as duas arquiteturas: $TARGET"
