# Finding the gate

Goal: locate the smallest code that decides the locked/unlocked (or free/paid)
state, then express the flip as exact smali find/replace rules.

## Tools

- **jadx / jadx-gui** (or the JADX MCP tools): decompile to readable Java to
  understand control flow, then map the method back to its smali file/signature.
  `search_classes_by_keyword`, `get_method_by_name`, `get_xrefs_to_method`,
  `get_smali_of_class` are the fast path from "where is premium decided" to the
  exact smali anchor.
- **apktool**: `d -r -f` produces the smali tree you actually patch. The `-r`
  (raw resources) decode matches the on-device build.
- **REA** (`inspect_android_package`, `inspect_android_class`,
  `inspect_android_method`, `trace_android_references`): package/class/method
  inventory, decomp/smali, and incoming static references without a GUI.

Work from Java (to understand) to smali (to anchor). Always confirm the smali
in the actual decoded tree before writing the rule — decompiled Java names may
differ from the smali signature you must match.

## Common gate shapes

- **Boolean check.** A method returns `Z`; free path returns `0x0`. Flip the
  `const/4 vX, 0x0` that feeds `return vX` to `0x1`, anchored on the method
  signature + `.locals`.
- **Enum / sealed state.** License status is an object (e.g. `Free` vs
  `Premium`). Rewrite the method to construct and return the premium variant
  (`new-instance` + `invoke-direct` + `return-object`), replacing the whole body
  between signature and `.end method`.
- **Equality / branch gate.** `if-ne pX, vY, :cond_*` guards the locked branch.
  Force the comparison result, or insert the unlocked value before the branch,
  keeping the captured `:cond_*` label.
- **Server/receipt validation.** A verifier returns valid/invalid. Short-circuit
  the local decision; prefer the single method whose return the rest of the app
  trusts over patching every call site.
- **Paywall UI.** Separate cosmetic from functional. The functional unlock is in
  `smali/`; hiding a paywall view is often a `res/` edit (desktop-only on this
  pipeline). Ship the functional flip; treat UI as an optional `res/` extra.

## Discipline

- Change the fewest methods that make the rest of the app observe "unlocked".
  One trusted return beats many scattered edits.
- Anchor on signatures and opcodes, never register numbers or line comments.
- Add `must` guards so a renamed/updated file fails loudly.
- Re-verify with `./apply --check` on each supported version; a new version
  gets its own `variant` section, the old one stays.
