#!/bin/bash
#
# The offline mirror is indexed by several repo-add processes whose databases
# are then joined (builder/index-offline-mirror.sh). The result has to be the
# database one repo-add writes over the same packages, and two versions of one
# package have to be an error, since apart they would both be kept.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
index="$ROOT/builder/index-offline-mirror.sh"
bash -n "$index"
if ! command -v repo-add >/dev/null; then
  echo "offline mirror index tests skipped: no repo-add here"
  exit 0
fi

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

package() { # directory name version: the least repo-add accepts as a package
  local stage="$fixture/stage"
  rm -rf "$stage"; mkdir -p "$stage/usr/share/$2"
  echo "$2 $3" >"$stage/usr/share/$2/version"
  printf 'pkgname = %s\npkgver = %s\npkgdesc = fixture\narch = any\nsize = 1\n' "$2" "$3" >"$stage/.PKGINFO"
  bsdtar -czf "$1/$2-$3-any.pkg.tar.gz" -C "$stage" .PKGINFO usr
}
contents() { # database file -> directory holding its entries
  mkdir -p "$2"; bsdtar -xf "$1" -C "$2"
}

mkdir "$fixture/one" "$fixture/many"
for name in alpha bravo charlie delta echo foxtrot golf; do
  package "$fixture/one" "$name" 1.0-1
  cp "$fixture/one/$name-1.0-1-any.pkg.tar.gz" "$fixture/many/"
done
: >"$fixture/many/alpha-1.0-1-any.pkg.tar.gz.sig"   # a signature is not a package

repo-add -q "$fixture/one/offline.db.tar.gz" "$fixture"/one/*.pkg.tar.gz >/dev/null 2>&1
bash "$index" "$fixture/many" 3 >/dev/null || fail "indexing seven packages with three processes failed"
for kind in db files; do
  [[ -L $fixture/many/offline.$kind ]] || fail "offline.$kind, the name pacman fetches, is missing"
  contents "$fixture/one/offline.$kind.tar.gz" "$fixture/x-one-$kind"
  contents "$fixture/many/offline.$kind" "$fixture/x-many-$kind"
  diff -r "$fixture/x-one-$kind" "$fixture/x-many-$kind" >/dev/null \
    || fail "the joined $kind database differs from one repo-add's"
done

# More processes than packages, and a second run over an indexed mirror.
bash "$index" "$fixture/many" 64 >/dev/null || fail "more processes than packages failed"
contents "$fixture/many/offline.db" "$fixture/x-again"
diff -r "$fixture/x-one-db" "$fixture/x-again" >/dev/null || fail "indexing an already indexed mirror changed it"

package "$fixture/many" alpha 2.0-1
bash "$index" "$fixture/many" 3 >/dev/null 2>&1 && fail "two versions of one package were indexed"

mkdir "$fixture/empty"
bash "$index" "$fixture/empty" >/dev/null 2>&1 && fail "an empty mirror was indexed"

grep -Fq 'bash /builder/index-offline-mirror.sh "$offline_mirror_dir"' "$ROOT/builder/build-iso.sh" \
  || fail "the build does not use the parallel index"

echo "offline mirror index tests passed"
