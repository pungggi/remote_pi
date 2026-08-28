#!/usr/bin/env bash
# Wave 0 (plano 58) — gate FFI: compila o cockpit_pty como dylib standalone,
# fora do build do Flutter, para consumo via DynamicLibrary.open em Dart puro.
# Saída: cockpit/build/wave0/libcockpit_pty.dylib (ou .so no Linux).
set -euo pipefail

cd "$(dirname "$0")/../.."
SRC=plugins/cockpit_pty/src
OUT=build/wave0
mkdir -p "$OUT"

case "$(uname -s)" in
  Darwin)
    cc -dynamiclib -O2 -DDART_SHARED_LIB \
      -o "$OUT/libcockpit_pty.dylib" "$SRC/cockpit_pty.c" -I"$SRC" -lpthread
    echo "ok: $OUT/libcockpit_pty.dylib"
    ;;
  Linux)
    cc -shared -fPIC -O2 -DDART_SHARED_LIB \
      -o "$OUT/libcockpit_pty.so" "$SRC/cockpit_pty.c" -I"$SRC" -lpthread
    echo "ok: $OUT/libcockpit_pty.so"
    ;;
  *)
    echo "wave0: plataforma não suportada pelo script ($(uname -s))" >&2
    exit 1
    ;;
esac
