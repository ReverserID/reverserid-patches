# reverser.id patches

One repository, one **list** of patch templates — like [nuclei-templates](https://github.com/projectdiscovery/nuclei-templates), but for APKs.
A template declares a target package and, per app-version, a set of
**find/replace rules** over the apktool-decoded tree (smali + decoded res).
The reverser.id patcher app (egui, Android + desktop) reads a template and
applies it on-device; `apply.py` is the reference engine with identical
semantics.

## The list

| id | target | versions | what |
|----|--------|----------|------|
| `hidemyemulator-premium` | `net.wowsoftware.hidemyemulator` | 1.3, 1.4 | lifetime-premium unlock (all protections + Apply, no paywall) |

Machine-readable index: [`index.json`](index.json).

## Template format

Nuclei-style YAML (schema: [`schema/template.schema.json`](schema/template.schema.json)):

```yaml
id: hidemyemulator-premium
info:
  name: HideMyEmulator Premium Unlock
  author: reverser.id
  severity: info
  tags: [premium, license, unlock]
  description: ...
target:
  package: net.wowsoftware.hidemyemulator
variants:                       # first variant whose match passes is applied
  - match: { version_name: "^1\\.4" }   # regex over versionName
    patches:
      - name: "d9/b mapper -> premium"
        file: "smali/d9/b.smali"         # path inside the decoded tree
        find: "\\.method public static r\\(...\\)Lnb/s;.*?\\.end method"
        replace: |-
          .method public static r(...)Lnb/s;
              ...
        count: 1                          # required match count (abort on mismatch)
        must_contain: ["reverser.id"]     # optional post-apply assertions
build:
  tool: apktool
  sign: ephemeral
```

Rules:

- **Matching is always DOTALL.** Each rule must match exactly `count` times
  (default 1) or the whole run aborts — the same safety invariant as a
  hand-written patch. Rules apply in order (later rules see earlier edits).
- **Backrefs in `replace`:** `$1` / `${1}`; literal `$` is `$$`. This is the
  Rust/ECMAScript convention — the Rust engine uses it natively; `apply.py`
  translates to Python `\g<N>`.
- **`file`** is relative to the apktool-decoded root (`smali/…`, `res/…`,
  `AndroidManifest.xml`).

## Run (reference engine)

Requires Apktool 3.x (`apktool.jar`), Android build-tools (`zipalign`,
`apksigner`), and a JDK.

```sh
python apply.py --list                       # print the list
python apply.py --check <decoded_dir>         # validate rules against a decoded tree
python apply.py app.apk --out patched.apk     # decode -> patch -> rebuild -> align -> sign
```

A Crystal port with identical semantics ships as `apply.cr` (verified against
`apply.py`: same `--list`/`--check` output, all rules anchor identically):

```sh
crystal build --release apply.cr -o apply   # or: crystal run apply.cr -- <args>
./apply --check <decoded_dir>
```

`--check` is the fast correctness gate: it confirms every rule still anchors
exactly `count` times against a clean decode — run it whenever a target app
updates.

## In the app

The shipping patcher embeds the same engine in Rust (`src/template.rs` in the
reverser.id patcher), so patching runs in-app on **Android and desktop**:
decode → apply template (in-process) → rebuild → sign. Templates are fetched
from this repo's list; no app update needed to add or fix a patch.

## Authoring a new template

1. Decode a clean APK: `apktool d app.apk -o decoded`.
2. Find the patch sites; write each as a `file` + `find` regex + `replace`.
3. `python apply.py --check decoded` until all rules anchor `1x`.
4. `python apply.py app.apk` → install → verify behavior on-device.
5. Add the template under `templates/` and an entry to `index.json`.

## Legal

Templates describe modifications to apps **you own or are authorized to
modify**, for interoperability/research. You are responsible for how you use
them.
