#!/usr/bin/env python3
"""reverser.id patch runner — applies a nuclei-style patch template to an APK.

A template (templates/*.yml) declares a target package and, per app-version,
a list of find/replace rules over the apktool-decoded tree (smali + decoded
res). This is the reference engine; the shipping patcher is the Rust engine in
the reverser.id app (src/template.rs) — identical template, same semantics.

Backref syntax in `replace`: $1 / ${1}  (literal '$' as $$). Matching is always
DOTALL, each rule must match exactly `count` times (default 1) or the run aborts.

Usage:
    python apply.py <app.apk>                 # decode -> patch -> rebuild -> sign
    python apply.py --check <decoded_dir>     # validate rules against a decoded tree
    python apply.py --list                    # print the template index
"""
import argparse, glob, os, re, shutil, subprocess, sys, tempfile
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
TPL_DIR = os.path.join(HERE, "templates")
JAVA_OPTS = "-Xmx384M -XX:+UseSerialGC"
SIGN_OPTS = "-Xmx256M"


def load_templates():
    out = []
    for p in sorted(glob.glob(os.path.join(TPL_DIR, "*.yml"))):
        with open(p, encoding="utf-8") as f:
            t = yaml.safe_load(f)
        t["_path"] = p
        out.append(t)
    return out


def conv_replace(repl):
    """$N / ${N} -> Python \\g<N>; $$ -> $; literal backslashes escaped."""
    out, i = [], 0
    while i < len(repl):
        c = repl[i]
        if c == "$":
            if repl[i + 1:i + 2] == "$":
                out.append("$"); i += 2; continue
            if repl[i + 1:i + 2] == "{":
                j = repl.index("}", i); out.append("\\g<%s>" % repl[i + 2:j]); i = j + 1; continue
            m = re.match(r"\d+", repl[i + 1:])
            if m:
                out.append("\\g<%s>" % m.group(0)); i += 1 + len(m.group(0)); continue
            out.append("$"); i += 1; continue
        if c == "\\":
            out.append("\\\\"); i += 1; continue
        out.append(c); i += 1
    return "".join(out)


def apply_rule(root, rule, write):
    path = os.path.join(root, rule["file"].replace("/", os.sep))
    if not os.path.isfile(path):
        sys.exit("PATCH FAILED [%s]: missing file %s" % (rule["name"], rule["file"]))
    with open(path, "r", encoding="utf-8", newline="") as f:
        raw = f.read()
    crlf = "\r\n" in raw
    src = raw.replace("\r\n", "\n")
    want = rule.get("count", 1)
    new, n = re.subn(rule["find"], conv_replace(rule["replace"]), src,
                     count=want, flags=re.DOTALL)
    if n != want:
        sys.exit("PATCH FAILED [%s]: anchor matched %dx (want %d) in %s"
                 % (rule["name"], n, want, rule["file"]))
    for anchor in rule.get("must_contain", []):
        if anchor not in new:
            sys.exit("PATCH FAILED [%s]: result missing %r" % (rule["name"], anchor))
    if write:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(new.replace("\n", "\r\n") if crlf else new)
    print("  ok [%s]" % rule["name"])


def read_version(decoded):
    with open(os.path.join(decoded, "apktool.yml"), encoding="utf-8") as f:
        y = yaml.safe_load(f)
    vi = y.get("versionInfo", {}) or {}
    return str(vi.get("versionName", "")), str(vi.get("versionCode", ""))


def select_variant(tpl, version_name):
    for v in tpl.get("variants", []):
        rx = v.get("match", {}).get("version_name", ".*")
        if re.search(rx, version_name):
            return v
    return None


def select_template(package, version_name, templates):
    for t in templates:
        if t.get("target", {}).get("package") != package:
            continue
        if select_variant(t, version_name):
            return t
    return None


def cmd_check(decoded, only):
    templates = [t for t in load_templates() if (not only or t["id"] == only or t["_path"].endswith(only))]
    ver, code = read_version(decoded)
    # package from a template that matches the tree; fall back to manifest scan
    pkg = None
    mf = os.path.join(decoded, "AndroidManifest.xml")
    if os.path.isfile(mf):
        with open(mf, encoding="utf-8", errors="ignore") as f:
            m = re.search(r'package="([^"]+)"', f.read())
            pkg = m.group(1) if m else None
    print("decoded: version=%s code=%s package=%s" % (ver, code, pkg))
    tpl = select_template(pkg, ver, templates) if pkg else None
    if not tpl:
        tpl = next((t for t in templates if select_variant(t, ver)), None)
    if not tpl:
        sys.exit("no template matches version %s" % ver)
    variant = select_variant(tpl, ver)
    print("template: %s  variant: %s  rules: %d"
          % (tpl["id"], variant["match"], len(variant["patches"])))
    for rule in variant["patches"]:
        apply_rule(decoded, rule, write=False)
    print("CHECK OK: all %d rules match" % len(variant["patches"]))


def cmd_list():
    for t in load_templates():
        vers = ", ".join(v["match"].get("version_name", "*") for v in t.get("variants", []))
        info = t.get("info", {})
        print("%-28s %s" % (t["id"], info.get("name", "")))
        print("    target : %s  versions: %s" % (t["target"]["package"], vers))
        print("    rules  : %s" % ", ".join(str(len(v["patches"])) for v in t["variants"]))


def run(cmd, env_extra=None):
    env = dict(os.environ); env.update(env_extra or {})
    print("+", " ".join(str(c) for c in cmd), flush=True)
    subprocess.run(cmd, check=True, env=env)


def cmd_apply(a):
    templates = load_templates()
    apktool = ["java", "-jar", a.apktool]
    work = a.workdir or tempfile.mkdtemp(prefix="rid-patch-")
    dec = os.path.join(work, "decoded")
    unsigned = os.path.join(work, "unsigned.apk")
    aligned = os.path.join(work, "aligned.apk")
    jenv = {"_JAVA_OPTIONS": JAVA_OPTS}
    senv = {"_JAVA_OPTIONS": SIGN_OPTS}

    run(apktool + ["d", "-f", a.apk, "-o", dec], jenv)
    ver, code = read_version(dec)
    pkg = None
    with open(os.path.join(dec, "AndroidManifest.xml"), encoding="utf-8", errors="ignore") as f:
        m = re.search(r'package="([^"]+)"', f.read()); pkg = m.group(1) if m else None
    print("detected: %s %s (code %s)" % (pkg, ver, code))
    tpl = select_template(pkg, ver, templates)
    if not tpl:
        sys.exit("no template for %s %s" % (pkg, ver))
    variant = select_variant(tpl, ver)
    print("applying template %s (%d rules)" % (tpl["id"], len(variant["patches"])))
    for rule in variant["patches"]:
        apply_rule(dec, rule, write=True)
    run(apktool + ["b", dec, "-o", unsigned], jenv)

    if a.no_sign:
        shutil.copyfile(unsigned, a.out); print("unsigned ->", a.out); return
    zipalign = os.path.join(a.build_tools, "zipalign.exe")
    apksigner = os.path.join(a.build_tools, "apksigner.bat")
    run([zipalign, "-f", "4", unsigned, aligned])
    ks = a.keystore
    if not ks:
        ks = os.path.join(work, "sign.keystore")
        run(["keytool", "-genkeypair", "-keystore", ks, "-alias", "key",
             "-keyalg", "RSA", "-keysize", "2048", "-validity", "10950",
             "-storepass", a.storepass, "-keypass", a.keypass, "-dname", "CN=reverser.id"], senv)
        alias = "key"
    else:
        alias = a.keyalias or "androiddebugkey"
    run([apksigner, "sign", "--ks", ks, "--ks-key-alias", alias,
         "--ks-pass", "pass:" + a.storepass, "--key-pass", "pass:" + a.keypass,
         "--out", a.out, aligned], senv)
    run([apksigner, "verify", a.out], senv)
    print("signed ->", a.out)


def main():
    ap = argparse.ArgumentParser(description="reverser.id patch runner")
    ap.add_argument("apk", nargs="?")
    ap.add_argument("--check", metavar="DECODED_DIR")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--only", help="restrict to one template id/path (with --check)")
    ap.add_argument("--out")
    ap.add_argument("--apktool", default="C:/bin/apktool/apktool.jar")
    ap.add_argument("--build-tools", dest="build_tools",
                    default=os.path.join(os.environ.get("ANDROID_HOME", ""), "build-tools", "36.0.0"))
    ap.add_argument("--keystore"); ap.add_argument("--keyalias")
    ap.add_argument("--storepass", default="android")
    ap.add_argument("--keypass", default="android")
    ap.add_argument("--no-sign", action="store_true")
    ap.add_argument("--workdir")
    a = ap.parse_args()
    if a.list:
        cmd_list(); return
    if a.check:
        cmd_check(a.check, a.only); return
    if not a.apk:
        ap.error("need an APK, or --check DIR, or --list")
    if not a.out:
        stem = os.path.splitext(os.path.basename(a.apk))[0]
        a.out = os.path.join(os.path.dirname(a.apk) or ".", stem + "-patched-signed.apk")
    cmd_apply(a)


if __name__ == "__main__":
    main()
