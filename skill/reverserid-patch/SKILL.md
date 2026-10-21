---
name: reverserid-patch
description: Reverse-engineer an Android app, author a reverser.id `.rid` patch template, then actually patch, install, and verify it works — on device with RevID Patcher or via apply.cr. `--check` is the compile step; building, installing, and exercising the gated feature is the test step. Use when adding or fixing a patch in the reverserid-patches repo, or reasoning about the on-device patch/verify pipeline. Not for ordinary source-repo analysis.
metadata:
  version: "1"
  repo: reverserid-patches
---

# reverser.id patch authoring

A **reverser.id patch** is a declarative template in the `.rid` format: a target
package plus per-version find/replace rules over an **apktool-decoded** tree.
`RevID Patcher` (the on-device app) and `apply.cr` (the Crystal runner) execute
the same semantics. Patches live in one repo; the app is the fixed patcher and
pulls templates from it.

Use this skill to: add a new app/version, repair a template whose anchors
drifted after an app update, or reason about the on-device pipeline.

Only author patches for targets you are authorized to modify.

## Repo layout

```
templates/<package>.rid       one template per target package (.rid format)
index.json                    catalog the app reads (id, name, target, versions, path)
FORMAT.md                     the .rid format spec
apply.cr                      Crystal reference runner: --check / --patch / --no-res / --list
README.md
```

Build the runner once: `crystal build --release apply.cr -o apply`. A template
is correct when `./apply --check <decoded_dir>` passes: **every rule matches its
`find` regex at least `count` times** against a freshly decoded tree (the first
`count` are replaced). That check is the gate — run it before every commit.

## Pipeline (same semantics everywhere)

```
APK ──apktool d──► decoded tree ──rules (find/replace)──► apktool b ──► apksigner ──► patched APK
```

- **On-device** (`RevID Patcher`): apktool + apksigner run **in-process** via
  `DexClassLoader` inside the app's own ART runtime. An installed
  `untrusted_app` cannot `exec` `dalvikvm` (SELinux aborts its runtime init with
  `system_class_loader != nullptr`), so the patcher loads a d8-compiled apktool
  DEX bundle and the apksig API by reflection — no child VM. Decode uses
  `apktool d -r` (raw resources, no aapt2), so **rules under `res/` are skipped
  on-device**; the functional unlock must live in `smali/`.
- **Desktop** (`apply.cr` + `apktool.jar` + build-tools `apksigner`): full
  decode, so `res/` rules also apply (branding/cosmetic).

Keep every behavior-changing rule in `smali/`. Treat `res/` rules as cosmetic
extras that only land on desktop builds.

## Author a new patch

1. **Acquire + identify.** Get the exact target APK. Read package + version from
   the binary manifest (`aapt dump badging`, or the app's AXML parser). The
   template's `target` and each `variant` regex must match the installed
   APK's package and versionName.
2. **Decode.** `apktool d -r -f <apk> -o <dir>` (smali-only, matches on-device).
   Use a full decode only when authoring `res/` rules.
3. **Locate the gate — decompile + observe, never guess.** Decompile with
   **JADX** (jadx MCP: `search_classes_by_keyword`, `get_class_source`,
   `get_xrefs_to_method`, `get_smali_of_class`) to find the deciding
   method/field and get the exact smali to anchor on. Then confirm it is the
   *real* gate at runtime with **Frida** (frida MCP: `java_hook_method` to log
   return values, `android_ssl_unpin` for pinning). See
   `references/reverse-engineering.md`.
4. **Design minimal rules.** Change the smallest surface that flips behavior —
   force a return value, rewrite one branch, or map a state constructor. Prefer
   a handful of exact, guarded edits over broad rewrites. See
   `references/authoring.md` and `FORMAT.md` for the block/backref/`count`/`must`
   rules.
5. **Write the template** in the `.rid` format (metadata, `variant <regex>`,
   `rule` blocks with verbatim `find`/`replace` fenced by `<<<`). Every patch
   MUST also inject a **styled** "Patched by ReverserID" launch toast — a
   code-built `TextView` + rounded `GradientDrawable`, never a plain
   `Toast.makeText` and never a layout/`R.*` resource (no aapt2 on-device). See
   `references/credit-toast.md`.
6. **Verify:** `./apply --check <decoded_dir>` — every rule must anchor its
   `count` (no misses). Fix anchors until clean.
7. **Register** the template in `index.json` (id, name, author, target,
   versions, path, description, tags).
8. **Patch for real.** Build the signed APK — RevID Patcher on device, or
   `./apply app.apk --out out.apk` on desktop (`--patch <dir> --no-res` for
   on-device/no-aapt2 parity). `--check` matched anchors; it does NOT prove the
   app runs or unlocks.
9. **Verify it works** (`references/verify.md`): uninstall the original, install
   the patched APK, confirm it **launches without crashing**, then drive the UI
   to the gated feature and confirm it is unlocked. Re-check after `pm clear` so
   it is the patch, not a cached trial. A green `--check` with a crash or a
   still-locked feature is a FAIL — re-open the gate and re-anchor.
10. **Commit + push** (see below).

## Template semantics (correctness-critical)

- Matching is **DOTALL** (`.` spans newlines). Anchor on stable, unique smali
  (method signatures, `const`/`sget`/`invoke` lines), never on volatile register
  numbers or line comments that shift between builds.
- Each rule MUST hit its `find` exactly `count` times. If an anchor appears more
  than once, tighten the pattern or raise `count` deliberately — never leave it
  ambiguous.
- Replacements expand `$N` / `${N}` capture-group backrefs; `$$` is a literal
  `$`. Keep captured context (`$1...`) rather than retyping surrounding code.
- `must` is a pre-flight guard: list substrings that must exist in the result,
  so a wrong/updated file fails loudly instead of silently no-op'ing.
- `file` paths are relative to the decoded tree (`smali/...`, `smali_classesN/`,
  `res/...`).

When an app updates and `--check` starts failing, the anchors drifted: re-decode
the new version, add a new `variants[]` entry with its `version_name` regex and
re-anchored rules; keep the old variant for the old version.

## Reference files

- `references/authoring.md` — the `.rid` format field-by-field, regex/backref
  rules, worked example.
- `references/credit-toast.md` — the mandatory styled "Patched by ReverserID"
  launch toast: self-contained smali recipe (no resources), register/`.locals`
  cautions, `.rid` rule shape.
- `references/reverse-engineering.md` — the research loop: JADX decompilation
  (keyword → Java → xref → smali) + Frida dynamic confirmation (hook returns,
  resolve obfuscated/live classes, SSL-unpin), plus REA headless equivalents.
- `references/on-device.md` — how `RevID Patcher` runs apktool/apksigner
  in-process, the SELinux constraint, the DEX bundle, and res-rule skipping.
- `references/verify.md` — install + functional test loop (launch/crash check,
  exercise the feature, `pm clear`, optional Frida/uiautomator2 proof), pass/fail.

## Finish

A patch is done when: `./apply --check` is clean on every supported version, the
template is in `index.json`, and — the real bar — the patched APK **installs,
launches, and the gated feature is observably unlocked and survives a
`pm clear`** (see `references/verify.md`). Then commit + push; it appears in the
`RevID Patcher` catalog automatically. Never call a patch done on a green
`--check` alone.
