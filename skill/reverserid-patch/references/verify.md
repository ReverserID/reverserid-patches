# Verify a patch actually works

A template that passes `--check` only proves the anchors matched — **not** that
the app behaves differently, or even still runs. A patch is not done until you
build it, install it, and watch the gated feature actually unlock. Treat
`--check` as the compile step and this as the test step.

## 1. Produce the patched APK

- **On device:** RevID Patcher → pick the patch → select/download the APK →
  Patch → Install. Output lands in `/sdcard/Download/ReverserID/`.
- **Desktop:** `./apply app.apk --out patched.apk` (decode → patch → build →
  align → sign). Add `--no-res` parity by patching a `-r` decode if you want to
  mirror the on-device result exactly.

## 2. Install (mind the signature)

The patch re-signs with its own key, so the result installs as a **new signing
identity**, not an update over the store build.

```sh
adb uninstall <package>            # remove the original first
adb install patched.apk
```

`INSTALL_FAILED_UPDATE_INCOMPATIBLE` means you skipped the uninstall — the
signatures differ by design.

## 3. Smoke it — did it even launch?

A wrong register or a broken method body **compiles and signs fine but crashes
at runtime**. This is the most common real failure, and `--check` never catches
it. Launch and confirm no immediate crash:

```sh
adb logcat -c
adb shell monkey -p <package> -c android.intent.category.LAUNCHER 1
adb logcat -d | grep -iE "FATAL|AndroidRuntime|<package>"
```

Zero `FATAL` / `AndroidRuntime` lines = it runs. A `java.lang.VerifyError` or
`NoSuchMethodError` here means the smali edit is structurally wrong.

## 4. Exercise the gated feature

Drive the UI to exactly where the lock / paywall / trial banner was, and confirm
it is gone.

- `uiautomator2` MCP (`dump_hierarchy`, `click_element`, `screenshot`) or raw
  `adb shell input tap/text` + `adb exec-out screencap -p`. Device taps use
  real pixels, not screenshot-scaled coordinates — read bounds from the
  hierarchy dump.
- Compare against the unpatched build's locked state so "unlocked" is a real
  delta, not wishful reading.
- When the app is debuggable, read the persisted flag directly:
  `adb shell run-as <package> cat shared_prefs/*.xml`.

## 5. Confirm it's the patch, not a cache

```sh
adb shell pm clear <package>       # drop any cached entitlement/trial
```

Re-launch and re-check step 4 from a clean state. Optional dynamic proof: attach
Frida (`frida` MCP: `java_hook_method` / `java_run`) to the running app and
confirm the patched method now returns the unlocked value (e.g. the premium
state object) or that the gate branch is never taken.

## Pass / fail

- **PASS** — app launches, the gated feature is available, and the state
  survives `pm clear` + relaunch.
- **FAIL** —
  - crash on launch → a structurally bad edit (registers/`.locals`/method body);
  - feature still locked → wrong gate, or the anchor replaced the wrong site;
  - reverts after restart → a second gate was missed.

  Re-open the gate in jadx, re-anchor, and (if the version moved) add a new
  `variant`. Then re-run `--check` and this whole loop.

## Worked result — `hidemyemulator-premium`

Patched `net.wowsoftware.hidemyemulator` 1.4 on-device (12 smali rules applied,
6 `res/` rules skipped — no aapt2), installed, launched: **Premium** badge,
**Module Active**, all **12 protection toggles ON**, and the "Patched by
reverser.id" launch toast — and it holds across relaunch. That observed behavior,
not a green `--check`, is the bar for "done".
