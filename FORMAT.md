# The `.rid` patch format

A reverser.id patch template is a `.rid` file: line-oriented metadata plus
`find`/`replace` bodies written **verbatim** (no escaping), so multi-line smali
pastes in exactly as apktool emits it. It replaces the old YAML format, whose
single-line `\n`-escaped strings made smali edits painful.

## Shape

```
# comments start with # (only outside <<< blocks)
id: <stable-kebab-id>
target: <package name, exactly as it ships>
name: <human name>
author: reverser.id
tags: premium, license, unlock          # comma-separated
versions: 1.3 · 1.4                      # display string
source: https://…                        # where to get the original APK
desc: one-line description for the app catalog

variant <version_name regex>             # opens a variant; rules below belong to it

rule <short label>
file: smali/path/Foo.smali               # relative to the decoded tree
count: 1                                  # required matches (default 1)
must: <substring>                         # optional guard, repeatable
find <<<
<regex, verbatim, may span lines>
<<<
replace <<<
<replacement, verbatim, may span lines; $N / ${N} backrefs, $$ = literal $>
<<<
```

## Rules of the format

- **Directives** are `key: value` or `variant …` / `rule …`, matched on the
  trimmed line. Blank lines and `#` comments are ignored outside blocks.
- **`variant <regex>`** opens a variant; its `<regex>` is matched (search, not
  anchored-full) against the APK `versionName`. The first matching variant wins;
  a bare `variant` with no regex matches any version. Order specific before
  general.
- **`rule <label>`** opens a rule under the current variant. Its `file`,
  `count`, and `must` directives follow, then the two blocks.
- **`find <<<` … `<<<`** and **`replace <<<` … `<<<`** capture everything
  between the fence lines **verbatim**. The body lines are joined with `\n`:
  - In `find`, that `\n`-joined text is the **regex** (always DOTALL — `.`
    matches newlines). You may write a multi-line anchor as real lines, or keep
    a literal `\n` on one line; both yield the same pattern.
  - In `replace`, newlines are literal output; `$1`/`${1}` insert capture
    groups, `$$` is a literal `$`.
  - A rule needs both blocks plus a `file`.

## Semantics (identical to the engine)

- Each rule must match **at least `count`** times; the first `count` matches are
  replaced. Fewer matches is an error (the anchor drifted or the version
  differs).
- `must` substrings must be present in the result, or the rule fails loudly.
- `file` paths live in the apktool-decoded tree (`smali/…`, `smali_classesN/…`,
  `res/…`). On-device builds skip `res/` rules (no aapt2); keep functional edits
  in `smali/`.

## Fence caveat

A body line that is exactly `<<<` (after trimming) closes the block, so neither
the regex nor the replacement may contain a line equal to `<<<`. Smali and
resource XML never do.

## Validate

`./apply --check <decoded_dir>` confirms every rule anchors the required number
of times against a clean decode. Run it before committing and whenever the
target app updates.
