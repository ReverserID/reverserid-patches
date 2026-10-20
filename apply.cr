# reverser.id patch runner (Crystal port of apply.py) — applies a nuclei-style
# patch template to an APK, or validates templates against a decoded tree.
#
# Build:  crystal build --release apply.cr          # -> ./apply
# Usage:
#   ./apply --check <decoded_dir>     # validate rules against a decoded tree
#   ./apply --patch <decoded_dir>     # apply template in place (add --no-res on device)
#   ./apply --list                    # print the template index
#   ./apply <app.apk> [--out out.apk] # full decode -> patch -> build -> sign
#
# Semantics match apply.py exactly: matching is DOTALL, each rule must match at
# least `count` times (the first `count` are replaced), replacements expand
# $N / ${N} backrefs ($$ = literal $), CRLF is preserved, `must_contain` guards.

require "yaml"
require "option_parser"

HERE      = __DIR__
TPL_DIR   = File.join(HERE, "templates")
JAVA_OPTS = "-Xmx384M -XX:+UseSerialGC"
SIGN_OPTS = "-Xmx256M"

record Template, data : YAML::Any, path : String

def load_templates : Array(Template)
  # Dir.glob patterns use '/' on every platform; normalise the Windows join.
  Dir.glob("#{TPL_DIR}/*.yml".gsub('\\', '/')).sort.map do |p|
    Template.new(YAML.parse(File.read(p)), p)
  end
end

# Expand $N / ${N} capture-group backrefs ($$ -> $) against a match.
def expand(repl : String, md : Regex::MatchData) : String
  String.build do |io|
    chars = repl.chars
    i = 0
    while i < chars.size
      c = chars[i]
      if c == '$' && i + 1 < chars.size
        nxt = chars[i + 1]
        case
        when nxt == '$'
          io << '$'; i += 2
        when nxt == '{'
          j = i + 2
          while j < chars.size && chars[j] != '}'
            j += 1
          end
          if g = repl[(i + 2)...j].to_i?
            io << (md[g]? || "")
          end
          i = j + 1
        when nxt.ascii_number?
          j = i + 1
          while j < chars.size && chars[j].ascii_number?
            j += 1
          end
          g = repl[(i + 1)...j].to_i
          io << (md[g]? || "")
          i = j
        else
          io << '$'; i += 1
        end
      else
        io << c; i += 1
      end
    end
  end
end

def apply_rule(root : String, rule : YAML::Any, write : Bool)
  name = rule["name"].as_s
  file = rule["file"].as_s
  path = File.join([root].concat(file.split("/")))
  abort "PATCH FAILED [#{name}]: missing file #{file}" unless File.file?(path)

  raw = File.read(path)
  crlf = raw.includes?("\r\n")
  src = raw.gsub("\r\n", "\n")
  want = rule["count"]?.try(&.as_i) || 1
  # Crystal's MULTILINE option = PCRE2 DOTALL ('.' matches newlines); '^'/'$'
  # are line-level by default, matching re.DOTALL for these anchor-free patterns.
  rx = Regex.new(rule["find"].as_s, Regex::Options::MULTILINE)
  repl = rule["replace"].as_s

  replaced = 0
  new = src.gsub(rx) do |match|
    if replaced < want
      replaced += 1
      expand(repl, $~)
    else
      match
    end
  end

  if replaced != want
    abort "PATCH FAILED [#{name}]: anchor matched #{replaced}x (want #{want}) in #{file}"
  end

  if mc = rule["must_contain"]?
    mc.as_a.each do |anchor|
      a = anchor.as_s
      abort "PATCH FAILED [#{name}]: result missing #{a.inspect}" unless new.includes?(a)
    end
  end

  File.write(path, crlf ? new.gsub("\n", "\r\n") : new) if write
  puts "  ok [#{name}]"
end

def read_version(decoded : String) : {String, String}
  y = YAML.parse(File.read(File.join(decoded, "apktool.yml")))
  vi = y["versionInfo"]?
  vn = vi.try(&.["versionName"]?).try(&.raw.to_s) || ""
  vc = vi.try(&.["versionCode"]?).try(&.raw.to_s) || ""
  {vn, vc}
end

def read_package(decoded : String) : String?
  mf = File.join(decoded, "AndroidManifest.xml")
  return nil unless File.file?(mf)
  if m = File.read(mf).match(/package="([^"]+)"/)
    m[1]
  end
end

def select_variant(data : YAML::Any, version_name : String) : YAML::Any?
  (data["variants"]?.try(&.as_a) || [] of YAML::Any).each do |v|
    rx = v["match"]?.try(&.["version_name"]?).try(&.as_s) || ".*"
    return v if Regex.new(rx).matches?(version_name)
  end
  nil
end

def select_template(package : String?, version_name : String, templates : Array(Template)) : Template?
  return nil if package.nil?
  templates.each do |t|
    next unless t.data["target"]?.try(&.["package"]?).try(&.as_s) == package
    return t if select_variant(t.data, version_name)
  end
  nil
end

def cmd_check(decoded : String, only : String?)
  templates = load_templates
  if o = only
    templates = templates.select { |t| t.data["id"].as_s == o || t.path.ends_with?(o) }
  end
  ver, code = read_version(decoded)
  pkg = read_package(decoded)
  puts "decoded: version=#{ver} code=#{code} package=#{pkg}"

  tpl = select_template(pkg, ver, templates)
  tpl ||= templates.find { |t| select_variant(t.data, ver) }
  abort "no template matches version #{ver}" unless tpl

  variant = select_variant(tpl.data, ver).not_nil!
  patches = variant["patches"].as_a
  puts "template: #{tpl.data["id"].as_s}  variant: #{variant["match"]?}  rules: #{patches.size}"
  patches.each { |rule| apply_rule(decoded, rule, false) }
  puts "CHECK OK: all #{patches.size} rules match"
end

def cmd_patch(decoded : String, only : String?, no_res : Bool)
  templates = load_templates
  if o = only
    templates = templates.select { |t| t.data["id"].as_s == o }
  end
  ver, _ = read_version(decoded)
  pkg = read_package(decoded)

  tpl = select_template(pkg, ver, templates)
  tpl ||= templates.find { |t| select_variant(t.data, ver) }
  abort "no template matches version #{ver}" unless tpl

  variant = select_variant(tpl.data, ver).not_nil!
  applied = 0
  skipped = 0
  variant["patches"].as_a.each do |rule|
    if no_res && rule["file"].as_s.starts_with?("res/")
      puts "  skip (res) [#{rule["name"].as_s}]"
      skipped += 1
      next
    end
    apply_rule(decoded, rule, true)
    applied += 1
  end
  puts "PATCH OK: #{applied} applied, #{skipped} skipped (template #{tpl.data["id"].as_s})"
end

def cmd_list
  load_templates.each do |t|
    d = t.data
    variants = d["variants"].as_a
    vers = variants.map { |v| v["match"]?.try(&.["version_name"]?).try(&.as_s) || "*" }.join(", ")
    name = d["info"]?.try(&.["name"]?).try(&.as_s) || ""
    puts "%-28s %s" % [d["id"].as_s, name]
    puts "    target : #{d["target"]["package"].as_s}  versions: #{vers}"
    puts "    rules  : #{variants.map { |v| v["patches"].as_a.size.to_s }.join(", ")}"
  end
end

def run(cmd : Array(String), env : Hash(String, String) = {} of String => String)
  puts "+ #{cmd.join(" ")}"
  STDOUT.flush
  status = Process.run(cmd[0], cmd[1..], env: env, output: STDOUT, error: STDERR)
  abort "command failed: #{cmd.join(" ")}" unless status.success?
end

def cmd_apply(apk : String, out_path : String, apktool_jar : String, build_tools : String,
              keystore : String?, keyalias : String?, storepass : String,
              keypass : String, no_sign : Bool, workdir : String?)
  templates = load_templates
  apktool = ["java", "-jar", apktool_jar]
  work = workdir || File.tempname("rid-patch")
  Dir.mkdir_p(work)
  dec = File.join(work, "decoded")
  unsigned = File.join(work, "unsigned.apk")
  aligned = File.join(work, "aligned.apk")
  jenv = {"_JAVA_OPTIONS" => JAVA_OPTS}
  senv = {"_JAVA_OPTIONS" => SIGN_OPTS}

  run(apktool + ["d", "-f", apk, "-o", dec], jenv)
  ver, code = read_version(dec)
  pkg = read_package(dec)
  puts "detected: #{pkg} #{ver} (code #{code})"

  tpl = select_template(pkg, ver, templates)
  abort "no template for #{pkg} #{ver}" unless tpl
  variant = select_variant(tpl.data, ver).not_nil!
  patches = variant["patches"].as_a
  puts "applying template #{tpl.data["id"].as_s} (#{patches.size} rules)"
  patches.each { |rule| apply_rule(dec, rule, true) }
  run(apktool + ["b", dec, "-o", unsigned], jenv)

  if no_sign
    File.copy(unsigned, out_path)
    puts "unsigned -> #{out_path}"
    return
  end

  zipalign = File.join(build_tools, "zipalign.exe")
  apksigner = File.join(build_tools, "apksigner.bat")
  run([zipalign, "-f", "4", unsigned, aligned])

  if ks = keystore
    alias_name = keyalias || "androiddebugkey"
  else
    ks = File.join(work, "sign.keystore")
    run(["keytool", "-genkeypair", "-keystore", ks, "-alias", "key",
         "-keyalg", "RSA", "-keysize", "2048", "-validity", "10950",
         "-storepass", storepass, "-keypass", keypass, "-dname", "CN=reverser.id"], senv)
    alias_name = "key"
  end

  run([apksigner, "sign", "--ks", ks, "--ks-key-alias", alias_name,
       "--ks-pass", "pass:#{storepass}", "--key-pass", "pass:#{keypass}",
       "--out", out_path, aligned], senv)
  run([apksigner, "verify", out_path], senv)
  puts "signed -> #{out_path}"
end

# ---- CLI --------------------------------------------------------------------

check_dir : String? = nil
patch_dir : String? = nil
no_res = false
do_list = false
only : String? = nil
out_path : String? = nil
apk : String? = nil
apktool_jar = "C:/bin/apktool/apktool.jar"
build_tools = File.join(ENV["ANDROID_HOME"]? || "", "build-tools", "36.0.0")
keystore : String? = nil
keyalias : String? = nil
storepass = "android"
keypass = "android"
no_sign = false
workdir : String? = nil

OptionParser.parse do |parser|
  parser.banner = "reverser.id patch runner"
  parser.on("--check DIR", "validate rules against a decoded tree") { |v| check_dir = v }
  parser.on("--patch DIR", "apply in place to a decoded tree") { |v| patch_dir = v }
  parser.on("--no-res", "skip res/ rules (on-device, no aapt2)") { no_res = true }
  parser.on("--list", "print the template index") { do_list = true }
  parser.on("--only ID", "restrict to one template id/path (with --check)") { |v| only = v }
  parser.on("--out FILE", "output apk path") { |v| out_path = v }
  parser.on("--apktool PATH", "apktool.jar path") { |v| apktool_jar = v }
  parser.on("--build-tools DIR", "android build-tools dir") { |v| build_tools = v }
  parser.on("--keystore PATH", "signing keystore") { |v| keystore = v }
  parser.on("--keyalias NAME", "signing key alias") { |v| keyalias = v }
  parser.on("--storepass PASS", "keystore password") { |v| storepass = v }
  parser.on("--keypass PASS", "key password") { |v| keypass = v }
  parser.on("--no-sign", "emit the unsigned apk") { no_sign = true }
  parser.on("--workdir DIR", "scratch directory") { |v| workdir = v }
  parser.on("-h", "--help", "show this help") { puts parser; exit }
  parser.unknown_args { |before, _after| apk = before[0]? }
end

if do_list
  cmd_list
elsif d = check_dir
  cmd_check(d, only)
elsif d = patch_dir
  cmd_patch(d, only, no_res)
elsif a = apk
  out_path ||= File.join(File.dirname(a), "#{File.basename(a, File.extname(a))}-patched-signed.apk")
  cmd_apply(a, out_path.not_nil!, apktool_jar, build_tools, keystore, keyalias,
    storepass, keypass, no_sign, workdir)
else
  abort "need an APK, or --check DIR, or --list"
end
