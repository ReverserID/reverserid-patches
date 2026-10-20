# reverser.id patches

One repository, one **list** of patch templates — like [nuclei-templates](https://github.com/projectdiscovery/nuclei-templates),
but for APKs. A template declares a target package and, per app-version, a set
of **find/replace rules** over the apktool-decoded tree (smali + decoded res).
The **RevID Patcher** app reads a template and applies it on-device; `apply.cr`
is the reference runner with identical semantics.

## The list

| id | target | versions | what |
|----|--------|----------|------|
| `hidemyemulator-premium` | `net.wowsoftware.hidemyemulator` | 1.3, 1.4 | lifetime-premium unlock (all protections + Apply, no paywall) |

Machine-readable index: [`index.json`](index.json).

## Template format — `.rid`

Templates use the line-oriented [`.rid` format](FORMAT.md): `key: value`
metadata, `variant <regex>` sections, and `rule` blocks whose `find`/`replace`
bodies are written **verbatim** between `<<<` fences — so multi-line smali pastes
in exactly as apktool emits it, with no `\n` escaping.

```
id: hidemyemulator-premium
target: net.wowsoftware.hidemyemulator
name: HideMyEmulator Premium Unlock
author: reverser.id
tags: premium, license, unlock
versions: 1.3 · 1.4
source: https://play.google.com/store/apps/details?id=net.wowsoftware.hidemyemulator

variant ^1\.4

rule d9/b mapper -> premium
file: smali/d9/b.smali
count: 1
find <<<
\.method public static r\(Ljava/lang/String;Ljava/lang/String;Ljava/time/ZoneId;\)Lnb/s;.*?\.end method
<<<
replace <<<
.method public static r(Ljava/lang/String;Ljava/lang/String;Ljava/time/ZoneId;)Lnb/s;
    .locals 1
    new-instance p0, Lnb/p;
    const/4 v0, 0x0
    invoke-direct {p0, v0, v0}, Lnb/p;-><init>(Ljava/lang/Long;Ljava/lang/String;)V
    return-object p0
.end method
<<<
```

Key invariants (full spec in [FORMAT.md](FORMAT.md)):

- Matching is always **DOTALL** (`.` spans newlines). Each rule must match at
  least `count` times (default 1); the first `count` are replaced. Rules apply
  in order (later rules see earlier edits).
- Backrefs in `replace`: `$1` / `${1}`, literal `$` is `$$`.
- `file` is relative to the decoded root (`smali/…`, `res/…`). On-device builds
  skip `res/` rules (no aapt2) — keep functional edits in `smali/`.

## Run (reference runner)

`apply.cr` is a single-file [Crystal](https://crystal-lang.org) program. Full
decode/build/sign needs Apktool 3.x (`apktool.jar`), Android build-tools
(`zipalign`, `apksigner`), and a JDK; `--check` needs only a decoded tree.

```sh
crystal build --release apply.cr -o apply     # or: crystal run apply.cr -- <args>

./apply --list                                # print the list
./apply --check <decoded_dir>                 # validate rules against a decoded tree
./apply --patch <decoded_dir> --no-res        # apply in place (on-device parity: no res)
./apply app.apk --out patched.apk             # decode -> patch -> rebuild -> align -> sign
```

`--check` is the fast correctness gate: it confirms every rule still anchors the
required number of times against a clean decode — run it whenever a target app
updates.

## In the app

**RevID Patcher** (Flutter, Android + desktop) embeds the same engine and runs
patching **in-process**: decode → apply template → rebuild → sign. On Android
this happens inside the app's own ART runtime via `DexClassLoader` (an installed
app cannot spawn `dalvikvm`), with signing through the apksig API. The app reads
this repo's list, so adding or fixing a patch needs no app update.

## Authoring a new template

1. Decode a clean APK: `apktool d -r app.apk -o decoded`.
2. Find the gate; write each edit as a `rule` with `file` + `find` + `replace`.
3. `./apply --check decoded` until every rule anchors the required count.
4. `./apply app.apk` (or the app) → install → verify behavior on-device.
5. Add the `.rid` under `templates/` and an entry in `index.json`.

## Legal

Templates describe modifications to apps **you own or are authorized to
modify**, for interoperability/research. You are responsible for how you use
them.
