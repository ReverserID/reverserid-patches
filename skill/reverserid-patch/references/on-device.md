# On-device pipeline (RevID Patcher)

`RevID Patcher` patches an APK entirely on the phone. It is the fixed patcher;
templates come from this repo.

## Why in-process (not dalvikvm)

An installed app runs in the SELinux `untrusted_app` domain. Spawning
`/apex/com.android.art/bin/dalvikvm` from that domain aborts during runtime
init:

```
Check failed: system_class_loader != nullptr
java.lang.ExceptionInInitializerError  (SIGABRT)
```

This is a domain/runtime constraint, not an environment-variable problem —
adding `DEX2OATBOOTCLASSPATH` or laundering through `sh` does not fix it. Termux
only works because it ships a full OpenJDK and runs `java`, not dalvikvm.

So the patcher runs apktool and apksigner **in its own already-initialised ART
runtime**, with no child process:

- A `DexClassLoader` loads a **d8-compiled full apktool DEX bundle**
  (`apktool-rid.jar` = every apktool class as DEX + its resources). The bundled
  `classes.dex` from a desktop apktool jar is only a partial/CLI dex; a complete
  d8 build of the fat jar is required.
- `brut.apktool.Main.main(["d","-r","-f",…])` and `(["b",…])` are invoked by
  reflection. `Main.main` only calls `System.exit` on arg/IO errors, so with
  valid args and pre-cleaned outputs the happy path returns normally instead of
  killing the app.
- Signing uses the **apksig library API** (`com.android.apksig.ApkSigner` +
  `SignerConfig.Builder(name, PrivateKey, certs)`), not `ApkSignerTool.main`, to
  avoid any `System.exit`. Keystore is PKCS12.

Android 14+ refuses to load a DEX from a writable path
(`Writable dex file … is not allowed`); the loader marks the bundle read-only
(`setReadOnly()`) before `DexClassLoader`.

Run all of this off the main thread; return success/failure over a platform
channel.

## Resource rules are skipped on-device

Decode uses `apktool d -r` (raw resources) because there is no `aapt2` to
rebuild a full resource table on-device. Rules whose `file` starts with `res/`
are therefore **skipped** on-device and only land on desktop builds. Keep every
behavior-changing edit in `smali/`; `res/` edits are cosmetic.

`./apply --patch <dir> --no-res` reproduces this exactly on desktop — use it to
smoke the
on-device result before shipping.

## Output

Patched APKs are written to `/sdcard/Download/ReverserID/<stem>-<templateId>.apk`,
signed with the patcher's PKCS12 key (so the original signature is replaced — a
patched app installs as a separate signing identity, not an update over the
Play build).

## Catalog

The app reads `index.json` to list available patches, resolves a selected
patch's `target.package` + `versions`, and only enables **Patch** once the
chosen APK's package+version is compatible. Adding a template + index entry here
makes it appear in the app.
