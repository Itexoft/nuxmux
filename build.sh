#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RID=$1
OUTPUT_DIR="$2"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT SIGTERM

GHP="$TMP/gh-pick.sh" && curl -fsSL "https://raw.githubusercontent.com/Itexoft/devops/refs/heads/master/gh-pick.sh" -o "$GHP" && chmod +x "$GHP"

ARGS=("-c" "Release" "$SCRIPT_DIR/src/Nuxmux/Nuxmux.csproj" "-o" "$OUTPUT_DIR" "-r" "$RID")
if [[ "$RID" == "linux-arm64" ]]; then
  ARGS+=("/p:ObjCopyName=aarch64-linux-gnu-objcopy")
fi

if [ -z "${P12_BASE64-}" ] || [ -z "${P12_BASE64// }" ]; then
  echo "P12_BASE64 is not defined " >&2
  exit 1
fi

SNK="$TMP/strongname.snk"
CCR=$("$GHP" "@master" "lib/cert-converter.sh")
"$CCR" "$P12_BASE64" snk "$SNK"
ARGS+=("-p:SignAssembly=true" "-p:PublicSign=false" "-p:AssemblyOriginatorKeyFile=$SNK" "--cert=$P12_BASE64")

mkdir -p "$OUTPUT_DIR"
DSP=$("$GHP" "@master" "lib/dotnet-sign-publish.sh")
"$DSP" "${ARGS[@]}"