#!/usr/bin/env bash
set -euo pipefail

test_root=$(cd "$(dirname "$0")" && pwd)
fixture_dir="$test_root/fixture/app"
temp_dir="$test_root/.temp"
app_dir="$temp_dir/app"
feed_dir="$temp_dir/feed"
cache_dir="$temp_dir/nuget-packages"
binlog_dir="$temp_dir/binlogs"
nuget_config="$test_root/nuget.config"

nupkg_path="${1:-}"
if [[ -z "$nupkg_path" ]]; then
  echo "Usage: $0 /path/to/nupkg" >&2
  exit 1
fi
if [[ ! -f "$nupkg_path" ]]; then
  echo "Nupkg not found: $nupkg_path" >&2
  exit 1
fi
if [[ ! -d "$fixture_dir" ]]; then
  echo "Fixture app not found: $fixture_dir" >&2
  exit 1
fi

os_name="$(uname -s)"

hash_cmd=""
case "$os_name" in
  Darwin*)
    hash_cmd="shasum -a 256"
    ;;
  *)
    hash_cmd="sha256sum"
    ;;
esac

for tool in unzip dotnet; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing '$tool' in PATH" >&2
    exit 1
  fi
done
if ! command -v ${hash_cmd%% *} >/dev/null 2>&1; then
  echo "Missing '${hash_cmd%% *}' in PATH" >&2
  exit 1
fi

rm -rf "$temp_dir"
mkdir -p "$feed_dir" "$cache_dir" "$app_dir" "$binlog_dir"

cp -R "$fixture_dir/." "$app_dir/"

"$test_root/scripts/prepare-fixture.sh" "$app_dir"

nuspec_content=$(unzip -p "$nupkg_path" "*.nuspec")
pkg_id=$(printf '%s\n' "$nuspec_content" | sed -n 's:.*<id>\([^<]*\)</id>.*:\1:p' | head -n1)
pkg_version=$(printf '%s\n' "$nuspec_content" | sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' | head -n1)

if [[ -z "$pkg_id" || -z "$pkg_version" ]]; then
  echo "Failed to parse package id/version from nupkg" >&2
  exit 1
fi

cp -f "$nupkg_path" "$feed_dir/$pkg_id.$pkg_version.nupkg"

export NUGET_PACKAGES="$cache_dir"

dotnet restore "$app_dir/TestApp.csproj" --configfile "$nuget_config" \
  -p:NuxmuxPackageId="$pkg_id" -p:NuxmuxPackageVersion="$pkg_version"

run_build() {
  local name="$1"
  local binlog="$binlog_dir/$name.binlog"

  dotnet build "$app_dir/TestApp.csproj" -c Release \
    -p:NuxmuxPackageId="$pkg_id" -p:NuxmuxPackageVersion="$pkg_version" \
    -bl:"$binlog"
}

run_build "build-1"

mux_dir="$app_dir/mux"
manifest_file="$app_dir/tools-src/manifest.txt"

if [[ ! -f "$manifest_file" ]]; then
  echo "Missing manifest file: $manifest_file" >&2
  exit 1
fi

tool_names=()
tool_args=()
tool_groups=()
while IFS='|' read -r tool args group; do
  if [[ -z "$tool" || "$tool" == \#* ]]; then
    continue
  fi
  tool_names+=("$tool")
  tool_args+=("$args")
  tool_groups+=("$group")
done < "$manifest_file"

for i in "${!tool_names[@]}"; do
  tool="${tool_names[$i]}"
  group="${tool_groups[$i]}"
  shim="$mux_dir/$group/$tool"
  dest="$app_dir/tools-src/$group/$tool"

  if [[ ! -x "$shim" ]]; then
    echo "Missing shim or not executable: $shim" >&2
    exit 1
  fi
  if [[ ! -f "$dest" ]]; then
    echo "Missing source tool: $dest" >&2
    exit 1
  fi

done

normalize_paths() {
  local line drive
  while IFS= read -r line; do
    line=${line//\\//}
    while [[ "$line" == */ ]]; do
      line=${line%/}
    done
    if [[ "$line" =~ ^/([A-Za-z])/ ]]; then
      drive=${BASH_REMATCH[1]}
      drive=${drive,,}
      line="${drive}:/${line:3}"
    elif [[ "$line" =~ ^([A-Za-z]):/ ]]; then
      drive=${BASH_REMATCH[1]}
      drive=${drive,,}
      line="${drive}${line:1}"
    fi
    printf '%s\n' "$line"
  done
}

core_tool=""
core_group=""
for i in "${!tool_names[@]}"; do
  if [[ "${tool_groups[$i]}" == "core" ]]; then
    core_tool="${tool_names[$i]}"
    core_group="${tool_groups[$i]}"
    break
  fi
done

if [[ -z "$core_tool" || -z "$core_group" ]]; then
  echo "No core tool found" >&2
  exit 1
fi

unique_groups=()
for group in "${tool_groups[@]}"; do
  found=0
  for existing in "${unique_groups[@]-}"; do
    if [[ "$existing" == "$group" ]]; then
      found=1
      break
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    unique_groups+=("$group")
  fi
done

bom=$(printf '\357\273\277')
for group in "${unique_groups[@]}"; do
  config_file="$mux_dir/$group/nuxmux.config"
  expected_root="$app_dir/tools-src/$group"

  if [[ ! -f "$config_file" ]]; then
    echo "Missing config file: $config_file" >&2
    exit 1
  fi

  expected_sorted=$(printf '%s\n' "$expected_root" | normalize_paths | LC_ALL=C sort -u)
  actual_sorted=$(sed "1s/^$bom//" "$config_file" | normalize_paths | LC_ALL=C sort -u)

  if [[ "$expected_sorted" != "$actual_sorted" ]]; then
    echo "Config roots mismatch for group '$group'" >&2
    echo "Expected:" >&2
    printf '%s\n' "$expected_sorted" >&2
    echo "Actual:" >&2
    printf '%s\n' "$actual_sorted" >&2
    exit 1
  fi
done

for i in "${!tool_names[@]}"; do
  tool="${tool_names[$i]}"
  args="${tool_args[$i]}"
  group="${tool_groups[$i]}"
  shim="$mux_dir/$group/$tool"

  if [[ -n "$args" ]]; then
    read -r -a arg_array <<< "$args"
    if ! "$shim" "${arg_array[@]}" >/dev/null 2>&1; then
      echo "Tool failed: $tool" >&2
      exit 1
    fi
  else
    if ! "$shim" >/dev/null 2>&1; then
      echo "Tool failed: $tool" >&2
      exit 1
    fi
  fi

done

rewrite_tool=""
rewrite_group=""
rewrite_rule=""
rewrite_expected=""
rewrite_args=()
rewrite_expected_args=()

if [[ "$os_name" == MINGW* || "$os_name" == MSYS* || "$os_name" == CYGWIN* ]]; then
  rewrite_tool="cmd.exe"
  rewrite_rule='cmd s#(^|\s)HI(\s|$)#$1BYE$2#'
  rewrite_args=(/c echo HI)
  rewrite_expected_args=(/c echo BYE)
else
  rewrite_tool="uname"
  rewrite_rule='uname s#(^|\s)-s(\s|$)#$1-r$2#'
  rewrite_args=(-s)
  rewrite_expected_args=(-r)
fi

for i in "${!tool_names[@]}"; do
  if [[ "${tool_names[$i]}" == "$rewrite_tool" ]]; then
    rewrite_group="${tool_groups[$i]}"
    break
  fi
done

if [[ -z "$rewrite_group" ]]; then
  echo "No tool found for rewrite test: $rewrite_tool" >&2
  exit 1
fi

rewrite_shim="$mux_dir/$rewrite_group/$rewrite_tool"
if [[ ! -x "$rewrite_shim" ]]; then
  echo "Missing shim for rewrite test: $rewrite_shim" >&2
  exit 1
fi

rewrite_tool_path="$app_dir/tools-src/$rewrite_group/$rewrite_tool"
if [[ ! -x "$rewrite_tool_path" ]]; then
  echo "Missing source tool for rewrite test: $rewrite_tool_path" >&2
  exit 1
fi

rewrite_expected_err_file="$temp_dir/rewrite-expected.err"
if ! rewrite_expected=$( "$rewrite_tool_path" "${rewrite_expected_args[@]}" 2>"$rewrite_expected_err_file"); then
  echo "Rewrite expected command failed for $rewrite_tool" >&2
  if [[ -s "$rewrite_expected_err_file" ]]; then
    cat "$rewrite_expected_err_file" >&2
  fi
  exit 1
fi

rewrite_err_file="$temp_dir/rewrite.err"
if ! rewrite_output=$(NUXMUX_ARGS_REWRITE="$rewrite_rule" "$rewrite_shim" "${rewrite_args[@]}" 2>"$rewrite_err_file"); then
  echo "Rewrite command failed for $rewrite_tool" >&2
  if [[ -s "$rewrite_err_file" ]]; then
    cat "$rewrite_err_file" >&2
  fi
  exit 1
fi

rewrite_output=$(printf '%s' "$rewrite_output" | tr -d '\r\n')
rewrite_output=$(printf '%s' "$rewrite_output" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
rewrite_expected=$(printf '%s' "$rewrite_expected" | tr -d '\r\n')
rewrite_expected=$(printf '%s' "$rewrite_expected" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if [[ "$rewrite_output" != "$rewrite_expected" ]]; then
  echo "Args rewrite failed for $rewrite_tool" >&2
  echo "Expected: $rewrite_expected" >&2
  echo "Actual: $rewrite_output" >&2
  exit 1
fi

extra_dir="$mux_dir/$core_group"
mkdir -p "$extra_dir"
printf 'extra' > "$extra_dir/extra-tool"

extra_shim="$extra_dir/extra-shim"
if [[ ! -f "$extra_dir/$core_tool" ]]; then
  echo "Missing shim for extra file test: $extra_dir/$core_tool" >&2
  exit 1
fi
cp "$extra_dir/$core_tool" "$extra_shim"

extra_source_dir="$app_dir/tools-src/extra-core"
mkdir -p "$extra_source_dir"
cp "$app_dir/tools-src/$core_group/$core_tool" "$extra_source_dir/$core_tool"

cat > "$app_dir/Directory.Build.targets" <<EOF
<Project>
  <ItemGroup>
    <NuxmuxDir Include="\$(MSBuildProjectDirectory)/tools-src/extra-core/*" Path="$core_group" />
  </ItemGroup>
</Project>
EOF

run_build "build-2"

if [[ ! -e "$extra_dir/extra-tool" ]]; then
  echo "Extra tool was removed (should be preserved): $extra_dir/extra-tool" >&2
  exit 1
fi
if [[ -e "$extra_shim" ]]; then
  echo "Extra shim not removed: $extra_shim" >&2
  exit 1
fi

core_config="$mux_dir/$core_group/nuxmux.config"
if [[ ! -f "$core_config" ]]; then
  echo "Missing config file: $core_config" >&2
  exit 1
fi

expected_roots=(
  "$app_dir/tools-src/$core_group"
  "$extra_source_dir"
)
expected_sorted=$(printf '%s\n' "${expected_roots[@]}" | normalize_paths | LC_ALL=C sort -u)
actual_sorted=$(sed "1s/^$bom//" "$core_config" | normalize_paths | LC_ALL=C sort -u)

if [[ "$expected_sorted" != "$actual_sorted" ]]; then
  echo "Config roots mismatch for extra roots" >&2
  echo "Expected:" >&2
  printf '%s\n' "$expected_sorted" >&2
  echo "Actual:" >&2
  printf '%s\n' "$actual_sorted" >&2
  exit 1
fi

rm -f "$app_dir/Directory.Build.targets"

mut_tool="${tool_names[0]}"
mut_group="${tool_groups[0]}"
mut_dest="$mux_dir/$mut_group/$mut_tool"

printf 'mutate' >> "$mut_dest"
hash_before=$($hash_cmd "$mut_dest" | awk '{print $1}')

run_build "build-3"

hash_after=$($hash_cmd "$mut_dest" | awk '{print $1}')
if [[ "$hash_before" != "$hash_after" ]]; then
  echo "Shim was overwritten: $mut_dest" >&2
  exit 1
fi

remove_tool=""
remove_group=""
for i in "${!tool_names[@]}"; do
  if [[ "${tool_groups[$i]}" == "dev" ]]; then
    remove_tool="${tool_names[$i]}"
    remove_group="${tool_groups[$i]}"
    break
  fi
done

if [[ -z "$remove_tool" || -z "$remove_group" ]]; then
  echo "No dev tool found for removal test" >&2
  exit 1
fi

remove_source="$app_dir/tools-src/$remove_group/$remove_tool"
if [[ ! -f "$remove_source" ]]; then
  echo "Removal source not found: $remove_source" >&2
  exit 1
fi

cat > "$app_dir/Directory.Build.targets" <<EOF
<Project>
  <ItemGroup>
    <NuxmuxDir Remove="\$(MSBuildProjectDirectory)/tools-src/$remove_group/$remove_tool" />
  </ItemGroup>
</Project>
EOF

run_build "build-4"

if [[ -e "$mux_dir/$remove_group/$remove_tool" ]]; then
  echo "Removed shim still present: $mux_dir/$remove_group/$remove_tool" >&2
  exit 1
fi
echo "All tests passed."
echo "Binlogs: $binlog_dir" >&2
