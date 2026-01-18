#!/usr/bin/env bash
set -euo pipefail

app_dir="${1:-}"
if [[ -z "$app_dir" ]]; then
  echo "Usage: $0 /abs/path/to/app" >&2
  exit 1
fi
if [[ ! -d "$app_dir" ]]; then
  echo "App dir not found: $app_dir" >&2
  exit 1
fi
tools_src="$app_dir/tools-src"
mux_dir="$app_dir/mux"
manifest_file="$tools_src/manifest.txt"

rm -rf "$tools_src" "$mux_dir"
mkdir -p "$tools_src"

os_name="$(uname -s)"
win_sysroot=""
if [[ "$os_name" == MINGW* || "$os_name" == MSYS* || "$os_name" == CYGWIN* ]]; then
  sysroot="${SYSTEMROOT:-C:\\Windows}"
  sysroot_unix="${sysroot//\\//}"
  if [[ "$sysroot_unix" =~ ^([A-Za-z]): ]]; then
    drive=${BASH_REMATCH[1],,}
    sysroot_unix="/${drive}${sysroot_unix:2}"
  fi
  win_sysroot="$sysroot_unix/System32"
fi

case "$os_name" in
  Linux*)
    cat <<'MANIFEST' > "$manifest_file"
# tool|args|group
ls||core
uname||core
date||core
curl|--version|net/http/clients
getent|--version|net/dns
git|--version|dev
make|--version|dev
MANIFEST
    ;;
  Darwin*)
    cat <<'MANIFEST' > "$manifest_file"
# tool|args|group
ls||core
uname||core
date||core
curl|--version|net/http/clients
scutil|--dns|net/dns
git|--version|dev
make|--version|dev
MANIFEST
    ;;
  MINGW*|MSYS*|CYGWIN*)
    cat <<'MANIFEST' > "$manifest_file"
# tool|args|group
cmd.exe|/c ver|core
hostname.exe||core
where.exe|cmd.exe|net/dns
whoami.exe||dev
tasklist.exe||dev
MANIFEST
    ;;
  *)
    echo "Unsupported OS: $os_name" >&2
    exit 1
    ;;
esac

copy_tool() {
  local tool="$1"
  local dest_dir="$2"
  local src

  if [[ -n "$win_sysroot" && -f "$win_sysroot/$tool" ]]; then
    src="$win_sysroot/$tool"
  else
    src=$(command -v "$tool" || true)
  fi
  if [[ -z "$src" ]]; then
    echo "Missing tool in PATH: $tool" >&2
    exit 1
  fi

  mkdir -p "$dest_dir"
  cp -L "$src" "$dest_dir/$tool"
  chmod +x "$dest_dir/$tool"
  chmod +w "$dest_dir/$tool"
}

while IFS='|' read -r tool args group; do
  if [[ -z "$tool" || "$tool" == \#* ]]; then
    continue
  fi
  if [[ -z "$group" ]]; then
    echo "Missing group for tool: $tool" >&2
    exit 1
  fi
  copy_tool "$tool" "$tools_src/$group"
done < "$manifest_file"
