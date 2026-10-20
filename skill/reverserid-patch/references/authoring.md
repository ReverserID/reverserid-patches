# Template authoring (`.rid`)

A template is one `.rid` file under `templates/<package>.rid`. The format is
line-oriented: `key: value` metadata, `variant <regex>` sections, and `rule`
blocks whose `find`/`replace` bodies are verbatim multi-line text fenced by
`<<<` — so smali pastes in with no `\n` escaping.

## Structure

```
id: <stable-kebab-id>            # unique across the repo; used in output filename
target: <package name>           # must equal the APK's package exactly
name: Human Readable Name
author: reverser.id
tags: premium, license, unlock   # comma-separated
versions: 1.3 · 1.4              # display string for supported versions
source: https://…               # where to get the original/unpatched APK
desc: One sentence shown in the app catalog.

variant ^1\.4                    # regex matched against versionName; bare = any

rule short rule label
file: smali/x/y.smali            # path relative to the decoded tree
count: 1                         # required match count (default 1)
must: a substring that must exist in the result   # optional, repeatable
find <<<
<regex, verbatim, may span lines>
<<<
replace <<<
<replacement, verbatim; $N / ${N} backrefs, $$ = literal $>
<<<
```

The first `variant` whose regex matches `versionName` wins; order specific
before general. Rules belong to the most recent `variant`.

## Blocks

- `find <<<` … `<<<` and `replace <<<` … `<<<` capture everything between the
  fences verbatim; body lines are joined with `\n`.
- In `find`, that joined text is the **regex** (always DOTALL). Write a
  multi-line anchor as real lines, or keep a literal `\n` on one line — both
  produce the same pattern.
- In `replace`, newlines are literal output; `$1`/`${1}` insert capture groups,
  `$$` is a literal `$`.
- A body line equal to `<<<` (trimmed) closes the block, so neither side may
  contain a line that is exactly `<<<`. Smali and resource XML never do.

## Writing good anchors

- Anchor on **signatures and opcodes**, not register numbers. `p1`, `v0` get
  reallocated across builds; `invoke-direct {...}, Lnb/p;-><init>(…)V` is stable.
- Capture a stable prefix and re-emit it with `$1`:
  ```
  find <<<
  (:cond_0
  )    sget-object p1, Lnb/r;->a:Lnb/r;
  <<<
  replace <<<
  $1    new-instance p1, Lnb/p;
      const/4 v1, 0x0
      invoke-direct {p1, v1, v0}, Lnb/p;-><init>(Ljava/lang/Long;Ljava/lang/String;)V
  <<<
  ```
- Make each `find` unique enough to hit exactly `count` times; extend the
  pattern with a neighbouring unique line if smali repeats.
- To force a return value, replace a whole method body:
  ```
  find <<<
  \.method public static r\(…\)Lnb/s;.*?\.end method
  <<<
  replace <<<
  .method public static r(…)Lnb/s;
      .locals 1
      new-instance p0, Lnb/p;
      const/4 v0, 0x0
      invoke-direct {p0, v0, v0}, Lnb/p;-><init>(Ljava/lang/Long;Ljava/lang/String;)V
      return-object p0
  .end method
  <<<
  ```

## Verify

```sh
crystal build --release apply.cr -o apply   # once
./apply --check <decoded_dir>               # every rule must anchor its count
./apply --list                              # print the catalog
```

A clean `--check` on a freshly decoded tree of each supported version is the
release gate. A miss (fewer matches than `count`) means the anchor is wrong or
the version differs — re-decode and re-anchor; add a new `variant` for a new
version, keep the old one.
