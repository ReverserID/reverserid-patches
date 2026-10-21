# Finding the gate — static (JADX) + dynamic (Frida)

Do not guess the gate. Locate it with **JADX decompilation**, confirm it at
runtime with **Frida**, then anchor the `.rid` rule on the exact smali. Static
tells you *where*; dynamic proves *which* method actually decides and, after
patching, that it flipped.

## Static research with JADX (jadx MCP)

Load the APK, then work keyword → Java → xref → smali:

1. **Map it.** `get_android_manifest`, `get_package_tree`,
   `get_main_activity_class`, `get_strings` — find the app package, entry
   points, and any telltale strings ("premium", "trial", "rooted",
   "CertificatePinner", server status codes).
2. **Search for the gate.** `search_classes_by_keyword` /
   `search_method_by_name` for the concept (license, premium, isPaid, isRooted,
   pinning, check). For paywalls, search the string the UI shows and xref it.
3. **Read it in Java.** `get_class_source` / `get_method_by_name` to understand
   the control flow: what the method returns, which field gates the feature,
   which branch shows the lock.
4. **Follow the decision.** `get_xrefs_to_method` / `get_xrefs_to_field` to see
   where the value is consumed. Patch the single method whose return the rest of
   the app trusts, not every call site.
5. **Get the exact anchor.** `get_smali_of_class` for the real smali (register
   names, `.locals`, opcode order). The `.rid` `find` regex anchors on *this*
   text — never on the decompiled Java, which differs from smali.
6. Obfuscated names (`a/b/c`, `hc/s`) are fine — anchor on signatures and
   `invoke`/`sget`/`const` lines, which survive across builds better than the
   class name.

REA is the headless equivalent when there is no GUI:
`inspect_android_package`, `search_android_classes`, `inspect_android_class`,
`inspect_android_method`, `trace_android_references`.

## Dynamic research with Frida (frida MCP)

Static analysis of a big obfuscated app leaves candidates. Frida resolves which
one is real and confirms the fix.

1. **Attach.** `list_applications` then `spawn_and_attach` (to catch startup
   gates like splash root checks) or `attach` to the running app. Confirm the
   Java runtime with `java_available`.
2. **Find the live class.** `java_list_classes` / `java_choose` (scan the heap
   for live instances), `java_dump_class` to list methods/fields when the name
   is obfuscated.
3. **Observe the decision.** `java_hook_method` on each candidate to log
   arguments and **return values**; drive the app to the gate and read
   `get_messages`. The method whose return changes the UI from locked to
   unlocked is the gate. `java_run` can call a method directly or read a field to
   inspect state.
4. **Pinning / root specifically.**
   - `android_ssl_unpin` to confirm TLS pinning is what blocks interception; if
     traffic flows after unpinning, the pinning methods (okhttp3 / squareup
     `CertificatePinner.check`, custom `TrustManager`) are your targets.
   - Hook the suspected `check` methods and watch them throw
     `SSLPeerUnverifiedException`, or hook the root/emulator check and watch it
     return true on splash.

## Confirm the patch with Frida (not just a green `--check`)

After building, installing, and launching the patched APK, re-attach with Frida
and prove the behavior changed:

- Hook the patched method and confirm it now returns the unlocked value (e.g.
  the premium state object) or that the gate branch is never taken.
- For unpinning, confirm `CertificatePinner.check` is now a no-op (returns
  without throwing) and your proxy sees cleartext.

See `verify.md` for the full install + functional test loop.

## Discipline

- Change the fewest methods that make the rest of the app observe "unlocked".
  One trusted return beats many scattered edits.
- Anchor on signatures and opcodes, never register numbers or line comments.
- Add `must` guards so a renamed/updated file fails loudly.
- Re-verify with `./apply --check` on each supported version; a new version gets
  its own `variant` section (the dex layout and `smali_classesN` paths shift
  between versions even when the methods don't — re-point `file:` and re-check),
  the old one stays.
