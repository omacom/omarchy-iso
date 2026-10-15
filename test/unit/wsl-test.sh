#!/bin/bash
#
# WSL artifact tests, VM-free: the shipped WSL configuration files, what
# wsl-verify accepts and refuses, and what nightly-layout publishes and says
# when a .wsl is (and is not) handed to it.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
verify="$ROOT/test/vm-image/wsl-verify"
layout="$ROOT/test/vm-image/nightly-layout"
wsl_src="$ROOT/builder/wsl"
bash -n "$verify"
bash -n "$layout"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
equal() { [[ $2 == "$3" ]] || fail "$1: got '$2', expected '$3'"; }
refused() { # description, command...: it has to fail and say why
  local what=$1; shift
  if "$@" >"$tmp/refused.out" 2>"$tmp/refused.err"; then fail "$what was accepted"; fi
  [[ -s $tmp/refused.err ]] || fail "$what was refused without a word"
}
# wsl-verify reports FAIL on stdout (like test/vm-image/vm-verify), while
# nightly-layout reports through stderr; each refusal has to say why somewhere.
refused_out() { # description, command...: it has to fail and say why on stdout
  local what=$1; shift
  if "$@" >"$tmp/refused.out" 2>"$tmp/refused.err"; then fail "$what was accepted"; fi
  [[ -s $tmp/refused.out ]] || fail "$what was refused without a word"
}

# ------------------------------------------------------- shipped WSL files
[[ -f $wsl_src/wsl.conf ]] || fail "no builder/wsl/wsl.conf"
[[ -f $wsl_src/wsl-distribution.conf ]] || fail "no builder/wsl/wsl-distribution.conf"
[[ -f $wsl_src/terminal-profile.json ]] || fail "no builder/wsl/terminal-profile.json"
grep -q 'systemd=true' "$wsl_src/wsl.conf" || fail "wsl.conf does not enable systemd"
grep -q 'default=omarchy' "$wsl_src/wsl.conf" || fail "wsl.conf does not default to omarchy"
grep -q '^defaultName=Omarchy' "$wsl_src/wsl-distribution.conf" || fail "wsl-distribution.conf names no oobe.defaultName"
grep -q '^ProfileTemplate=/usr/lib/wsl/terminal-profile.json' "$wsl_src/wsl-distribution.conf" || fail "wsl-distribution.conf points at no shipped terminal profile"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$wsl_src/terminal-profile.json" \
  || fail "terminal-profile.json is not JSON"

# -------------------------------------------- vm-wsl: payload transfer
# The config files must not ride root()'s stdin: root() pipes the password
# into ssh, so `root "cat >file" <local` would land an empty file in the
# guest. send_root carries the payload base64-encoded inside the command
# instead; these stubs replay the pipe semantics locally to prove the bytes
# arrive.
vmwsl="$ROOT/test/vm-image/vm-wsl"
bash -n "$vmwsl"
grep -q 'root "cat >' "$vmwsl" && fail "vm-wsl feeds a config file through root()'s stdin again"
eval "$(sed -n '/^root() {/,/^}$/p; /^send_root() {/,/^}$/p' "$vmwsl")"
declare -F root send_root >/dev/null || fail "vm-wsl no longer defines root and send_root"

stub=$tmp/stub
mkdir -p "$stub"
# sudo -S -p '' <command...>: consume the password line, then run the command.
cat >"$stub/sudo" <<'STUB'
#!/bin/bash
read -r _
shift 2 # -S -p
shift   # '' (the empty prompt)
exec "$@"
STUB
# chown 0:0 needs root, which the tests do not run as; the ownership itself is
# checked on the real artifact by wsl-verify (and in the guest by vm-wsl).
printf '#!/bin/bash\nexit 0\n' >"$stub/chown"
chmod +x "$stub/sudo" "$stub/chown"

pw=omarchy
ssh_vm() { bash -c "$1"; } # the command string, with root()'s password pipe as stdin

mkdir -p "$tmp/xfer/out"
for file in wsl.conf wsl-distribution.conf terminal-profile.json; do
  PATH="$stub:$PATH" send_root "$wsl_src/$file" "$tmp/xfer/out/$file"
  cmp -s "$wsl_src/$file" "$tmp/xfer/out/$file" || fail "send_root did not deliver $file intact"
  equal "send_root sets $file to 0644" "$(stat -c %a "$tmp/xfer/out/$file")" "644"
done

# ------------------------------------------------------------------ fixtures
# A minimal rootfs tarball with what vm-wsl ships, owned by root like the
# guest's `tar --numeric-owner` makes it.
make_rootfs() { # dir: writes the fixture files
  local dir=$1
  rm -rf "$dir"; mkdir -p "$dir/etc" "$dir/usr/lib/wsl" "$dir/boot"
  cp "$wsl_src/wsl.conf" "$dir/etc/wsl.conf"
  cp "$wsl_src/wsl-distribution.conf" "$dir/etc/wsl-distribution.conf"
  cp "$wsl_src/terminal-profile.json" "$dir/usr/lib/wsl/terminal-profile.json"
  printf 'root:x:0:0::/root:/bin/bash\nomarchy:x:1000:1000::/home/omarchy:/bin/bash\n' >"$dir/etc/passwd"
  chmod 0644 "$dir/etc/wsl.conf" "$dir/etc/wsl-distribution.conf" "$dir/usr/lib/wsl/terminal-profile.json"
}
pack() { # rootfs_dir output.wsl [tar-style]: tar-style is * (default) or ./*
  local dir=$1 out=$2 style=${3:-star}
  if [[ $style == dotstar ]]; then
    (cd "$dir" && tar --owner=0 --group=0 --numeric-owner -c ./* | gzip --best >"$out")
  else
    (cd "$dir" && tar --owner=0 --group=0 --numeric-owner -c * | gzip --best >"$out")
  fi
}

make_rootfs "$tmp/good"
pack "$tmp/good" "$tmp/good.wsl"
"$verify" "$tmp/good.wsl" >/dev/null || fail "a valid .wsl does not verify"
make_rootfs "$tmp/dotgood"
pack "$tmp/dotgood" "$tmp/dotgood.wsl" dotstar
"$verify" "$tmp/dotgood.wsl" >/dev/null || fail "a valid .wsl archived as ./* does not verify"

make_rootfs "$tmp/noweb"
rm "$tmp/noweb/etc/wsl.conf"
pack "$tmp/noweb" "$tmp/noweb.wsl"
refused_out "a .wsl without wsl.conf" "$verify" "$tmp/noweb.wsl"

make_rootfs "$tmp/resolv"
touch "$tmp/resolv/etc/resolv.conf"
pack "$tmp/resolv" "$tmp/resolv.wsl"
refused_out "a .wsl with etc/resolv.conf" "$verify" "$tmp/resolv.wsl"

make_rootfs "$tmp/kernel"
touch "$tmp/kernel/boot/vmlinuz-linux"
pack "$tmp/kernel" "$tmp/kernel.wsl"
refused_out "a .wsl with a kernel in /boot" "$verify" "$tmp/kernel.wsl"

make_rootfs "$tmp/wrapped-src"
mkdir -p "$tmp/wrapped"
mv "$tmp/wrapped-src" "$tmp/wrapped/rootfs"
(cd "$tmp/wrapped" && tar --owner=0 --group=0 --numeric-owner -c * | gzip --best >"$tmp/wrapped.wsl")
refused_out "a .wsl wrapped in a folder" "$verify" "$tmp/wrapped.wsl"

printf 'not gzip\n' >"$tmp/plain.wsl"
refused_out "a .wsl that is not gzip" "$verify" "$tmp/plain.wsl"

# ------------------------------------------------------------- nightly-layout
sealed() { # directory: what vm-seal leaves
  rm -rf "$1"; mkdir -p "$1"
  local file
  for file in base.qcow2 vmlinuz initrd cmdline; do echo "$file of ${1##*/}" >"$1/$file"; done
  echo "sums of the seal" >"$1/SHA256SUMS"
}
export SITE=https://nightly.example ISO_SITE=https://iso.example ISO_COMMIT=0123456789abcdef0123456789abcdef01234567

# Without a .wsl: the published files are unchanged and wsl is null.
mkdir -p "$tmp/release"
echo "an edge iso" >"$tmp/release/omarchy-2026.10.09-x86_64-edge.iso"
sealed "$tmp/sealed-edge"
printf '%s\n' "omarchy-dev 4.0.0.r6818.gc352b62-2" "omarchy-dev 4.0.0.r6818.gc352b62-2" \
  "/usr/lib/modules/7.2.8-5-omarchy-bore/pkgbase is owned by linux-omarchy-bore 7.2.8-5" "7.2.8-5-omarchy-bore" >"$tmp/edge-packages"
"$layout" edge 2026.10.09.431 edge/2026.10.09.431 "$tmp/release/omarchy-2026.10.09-x86_64-edge.iso" \
  "$tmp/sealed-edge" "$tmp/edge-packages" "$tmp/out" >/dev/null
equal "no .wsl, no .wsl files" "$(find "$tmp/out" -name '*.wsl*' | wc -l)" "0"
equal "no .wsl, wsl is null" "$(jq -r '.wsl' "$tmp/out/edge/latest.json")" "null"

# With a .wsl: it is published beside the image and described in latest.json.
mkdir -p "$tmp/release2"
echo "an edge iso" >"$tmp/release2/omarchy-2026.10.09-x86_64-edge.iso"
sealed "$tmp/sealed-edge2"
make_rootfs "$tmp/wslroot"
pack "$tmp/wslroot" "$tmp/publish.wsl"
"$layout" edge 2026.10.09.431 edge/2026.10.09.431 "$tmp/release2/omarchy-2026.10.09-x86_64-edge.iso" \
  "$tmp/sealed-edge2" "$tmp/edge-packages" "$tmp/out2" "$tmp/publish.wsl" >/dev/null
equal "a .wsl is published" "$(basename "$(find "$tmp/out2" -name '*.wsl' | head -1)")" "omarchy-edge-2026.10.09.431.wsl"
(cd "$tmp/out2/edge/2026.10.09.431" && sha256sum -c --quiet omarchy-edge-2026.10.09.431.wsl.sha256) \
  || fail "the .wsl checksum file does not match it"
equal "latest.json points at the .wsl" "$(jq -r '.wsl.url' "$tmp/out2/edge/latest.json")" \
  "https://nightly.example/edge/2026.10.09.431/omarchy-edge-2026.10.09.431.wsl"
equal "latest.json checksums the .wsl" "$(jq -r '.wsl.sha256' "$tmp/out2/edge/latest.json")" \
  "$(sha256sum "$tmp/out2/edge/2026.10.09.431/omarchy-edge-2026.10.09.431.wsl" | cut -d' ' -f1)"
[[ $(jq -r '.wsl.size' "$tmp/out2/edge/latest.json") -gt 0 ]] || fail "latest.json gives the .wsl no size"
"$verify" "$tmp/out2/edge/2026.10.09.431/omarchy-edge-2026.10.09.431.wsl" >/dev/null \
  || fail "the published .wsl does not verify"

# Stable names the .wsl after the release.
mkdir -p "$tmp/release3"
echo "a released iso" >"$tmp/release3/omarchy-4.0.4.iso"
sealed "$tmp/sealed-stable"
printf '%s\n' "omarchy 4.0.4-1" "/usr/lib/modules/7.2.5-3-omarchy/pkgbase is owned by linux-omarchy 7.2.5-3" "7.2.5-3-omarchy" >"$tmp/stable-packages"
make_rootfs "$tmp/wslroot3"
pack "$tmp/wslroot3" "$tmp/publish3.wsl"
"$layout" stable 4.0.4 stable/4.0.4/431 "$tmp/release3/omarchy-4.0.4.iso" \
  "$tmp/sealed-stable" "$tmp/stable-packages" "$tmp/out3" "$tmp/publish3.wsl" >/dev/null
equal "stable: the .wsl is named after the release" "$(basename "$(find "$tmp/out3" -name '*.wsl' | head -1)")" "omarchy-4.0.4.wsl"
equal "stable: no ISO is published" "$(find "$tmp/out3" -name '*.iso*' | wc -l)" "0"

# Nothing half-made is described.
sealed "$tmp/sealed-badwsl"
printf 'not gzip\n' >"$tmp/bad.wsl"
refused "a .wsl that does not verify" "$layout" stable 4.0.4 stable/4.0.4/9 "$tmp/release3/omarchy-4.0.4.iso" \
  "$tmp/sealed-badwsl" "$tmp/stable-packages" "$tmp/out-bad" "$tmp/bad.wsl"
refused "a missing .wsl file" "$layout" stable 4.0.4 stable/4.0.4/9 "$tmp/release3/omarchy-4.0.4.iso" \
  "$tmp/sealed-badwsl" "$tmp/stable-packages" "$tmp/out-bad2" "$tmp/no-such.wsl"

echo "wsl tests passed"
