# nuxmux

Small shim multiplexer for tools. At build time it generates shims and a `nuxmux.config` file next to each shim directory. At runtime each shim resolves the real tool by its own filename and delegates execution to the first match in the configured roots.

## Quick start after NuGet import

1) Add the package.

```xml
<ItemGroup>
  <PackageReference Include="nuxmux" Version="x.y.z" PrivateAssets="all" />
</ItemGroup>
```

2) Provide tool globs (recursive supported) and a `Path` for shims (absolute, or relative to `NuxmuxBaseDir`).

```xml
<PropertyGroup>
  <NuxmuxBaseDir>$(MSBuildProjectDirectory)</NuxmuxBaseDir>
</PropertyGroup>
<ItemGroup>
  <NuxmuxDir Include="C:\tools1\*.exe" Path="mux\tools1" />
  <NuxmuxDir Include="C:\tools2\**\*.exe" Path="mux\tools2" />
  <NuxmuxDir Include="D:\llvm-pack\*.exe" Path="D:\mux\tools3" />
</ItemGroup>
```

3) Build.

```bash
dotnet build
```

4) Add the desired shim directories to `PATH` and call tools by name.

Each shim reads `nuxmux.config` located in the same directory. The config lists absolute root directories where the real binaries live. No binaries are copied; only shims are generated.

## Parameters

- `NuxmuxDir` (Item): glob patterns of tool binaries. Order matters for resolution.
- `Path` (metadata): directory where shims and `nuxmux.config` for this item are generated. Relative paths are resolved against `NuxmuxBaseDir`.
- `NuxmuxBaseDir` (Property): base directory for relative `Path` values. Defaults to the project obj path.

## What gets generated

- Shims are created in each `Path` (missing added, existing not overwritten).
- `nuxmux.config` is written next to the shims for each `Path` and rewritten whenever the target runs.
- Tool binaries are not copied.
- Extra files are never touched; extra shims are removed only when they match the current template.

## MSBuild target

The package adds a buildTransitive target `NuxmuxGenerate`. It runs before `CollectPackageReferences` when `@(NuxmuxDir)` is non-empty and depends on `Restore`. The target generates shims/configs and syncs template-based shims.

## Argument rewrite

Set `NUXMUX_ARGS_REWRITE` to rewrite arguments before the target tool is launched. Rules are applied to a merged argument string (with quotes added by nuxmux) and the result is split back into argv, in order.

Syntax (sed-like):

```
s<delim>pattern<delim>replacement<delim>[gims]
```

To scope a rule to a specific tool, prefix it with the tool name (without `.exe`), then a space:

```
tool s<delim>pattern<delim>replacement<delim>[gims]
```

Multiple rules can be separated by whitespace or `;`. Use quotes to group rules that contain spaces.

The merged argument string is space-separated and padded with leading/trailing spaces. If you want to match whole arguments, prefer patterns like `(^|\\s)--old(\\s|$)` instead of `^`/`$` alone.

Examples:

```
NUXMUX_ARGS_REWRITE='s|^--bad$|--version|'
NUXMUX_ARGS_REWRITE='uname s#^-s$#-r#; git s#^--noop$#--version#'
NUXMUX_ARGS_REWRITE="s#^--old\\$#--new#;${NUXMUX_ARGS_REWRITE}"
```

In POSIX shells, use single quotes (or escape `$` as `\$`) so `$#` in regex anchors is not expanded.

## Notes

- Roots in `nuxmux.config` are absolute directories that contain the real binaries.
- `Path` can be absolute or relative to `NuxmuxBaseDir`.
- Shims are flat inside each `Path` (no subfolder mirroring).
- If multiple roots contain the same tool name, the first root in `nuxmux.config` wins.
