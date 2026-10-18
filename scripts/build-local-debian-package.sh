#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/build-local-debian-package.sh [--skip-tests]

Build local Debian packages from this Snapper checkout into the configured
build sibling. The script never installs packages on the host.

SNAPPER_BUILD_ROOT may override the default sibling build directory.
JOBS may override the number of parallel build jobs. The test suite runs
outside fakeroot in a private D-Bus session; package assembly skips its
redundant fakeroot test run.
EOF
}

skip_tests=0
case "${1:-}" in
    "") ;;
    --skip-tests) skip_tests=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

source_root=$(git rev-parse --show-toplevel)
source_root=$(realpath "$source_root")
if [[ $(basename "$source_root") != snapper ]]; then
    echo "Error: expected to run from the Snapper source checkout, got $source_root" >&2
    exit 1
fi

if ! git -C "$source_root" diff --quiet || ! git -C "$source_root" diff --cached --quiet; then
    echo "Error: commit or discard source changes before making a reproducible package" >&2
    exit 1
fi

source_commit=$(git -C "$source_root" rev-parse HEAD)
upstream_url=$(git -C "$source_root" remote get-url upstream)
upstream_commit=$(git ls-remote "$upstream_url" refs/heads/master | awk 'NR == 1 {print $1}')
if [[ ! $upstream_commit =~ ^[0-9a-f]{40}$ ]]; then
    echo "Error: could not read the current official upstream master tip" >&2
    exit 1
fi
if ! git -C "$source_root" merge-base --is-ancestor "$upstream_commit" "$source_commit"; then
    echo "Error: HEAD $source_commit does not contain current upstream master $upstream_commit" >&2
    echo "Rebase or merge the latest upstream source before building." >&2
    exit 1
fi

version=$(sed -n '1p' "$source_root/VERSION")
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: unexpected Snapper VERSION value: $version" >&2
    exit 1
fi

case "$source_root" in
    */@home/*) ;;
    *)
        echo "Error: source checkout must be under an @home tree: $source_root" >&2
        exit 1
        ;;
esac
storage_root=${source_root%%/@home/*}
source_relative=${source_root#*/@home/}
expected_build_root="$storage_root/builds/${source_relative%/*}/$(basename "$source_root").build"
build_root=$(realpath -m "${SNAPPER_BUILD_ROOT:-$expected_build_root}")
case "$build_root" in
    "$expected_build_root"|"$expected_build_root"/*) ;;
    *)
        echo "Error: build output must remain in the Snapper sibling build tree: $build_root" >&2
        exit 1
        ;;
esac

stamp=$(date -u +%Y%m%dT%H%M%SZ)
work_root="$build_root/local-package-builds/${version}-${source_commit:0:12}-${stamp}"
mkdir -p "$(dirname "$work_root")"
if [[ -e $work_root ]]; then
    echo "Error: refusing to overwrite existing build output: $work_root" >&2
    exit 1
fi
mkdir "$work_root"
source_build="$work_root/source"
mkdir "$source_build"
cpto_bin=${CPTO:-$(command -v cpto)}
if [[ ! -x $cpto_bin ]]; then
    echo "Error: cpto was not found or is not executable: $cpto_bin" >&2
    exit 1
fi
"$cpto_bin" --nogit --no-lngit "$source_root" "$source_build"

export TMPDIR=${TMPDIR:-/var/tmp}
make_bin=${MAKE_BIN:-/usr/bin/make}
GIT_DIR="$source_root/.git" GIT_WORK_TREE="$source_root" \
    "$make_bin" -C "$source_build" -f Makefile.repo configure
GIT_DIR="$source_root/.git" GIT_WORK_TREE="$source_root" \
    "$make_bin" -C "$source_build" package

package_source="$work_root/package-source"
mkdir "$package_source"
tar -xJf "$source_build/package/snapper-$version.tar.xz" \
    --strip-components=1 -C "$package_source"
tar -xzf "$source_build/package/debian.tar.gz" -C "$package_source"

local_version="${version}-1+local1"
changelog="$package_source/debian/changelog"
changelog_tmp="$work_root/changelog.new"
{
    printf 'snapper (%s) local; urgency=medium\n\n' "$local_version"
    printf '  * Build the latest-upstream local package with Btrfs quota support.\n\n'
    printf ' -- Local Snapper Builder <snapper-build@localhost>  %s\n\n' "$(date -R -u)"
    cat "$changelog"
} > "$changelog_tmp"
mv "$changelog_tmp" "$changelog"

python3 - "$package_source/debian/rules" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "--disable-btrfs-quota"
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected exactly one {old!r} in {path}, found {count}")
path.write_text(text.replace(old, "", 1))
PY

jobs=${JOBS:-$(nproc)}
if [[ ! $jobs =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: JOBS must be a positive integer, got $jobs" >&2
    exit 1
fi
build_options=${DEB_BUILD_OPTIONS:-}
if (( skip_tests )); then
    build_options="${build_options:+$build_options }nocheck"
fi
locale_root="/var/tmp/snapper-locales-${source_commit:0:12}"
mkdir -p "$locale_root"
for locale_name in en_US de_DE de_CH fr_FR en_GB; do
    localedef --no-archive -i "$locale_name" -f UTF-8 \
        "$locale_root/$locale_name.UTF-8"
done

if (( ! skip_tests )); then
    echo "Running the Snapper test suite outside fakeroot in a private D-Bus session."
    make -C "$package_source" -f debian/rules override_dh_auto_configure
    LOCPATH="$locale_root" dbus-run-session -- \
        "$make_bin" -C "$package_source" -j"$jobs" check
else
    build_options="${build_options:+$build_options }nocheck"
fi

case " $build_options " in
    *" nocheck "*) ;;
    *) build_options="${build_options:+$build_options }nocheck" ;;
esac
(
    cd "$package_source"
    DEB_BUILD_OPTIONS="$build_options" fakeroot \
        dpkg-buildpackage -b -uc -us -nc -j"$jobs"
)

shopt -s nullglob
packages=("$work_root"/*.deb)
if (( ${#packages[@]} == 0 )); then
    echo "Error: package build produced no .deb files in $work_root" >&2
    exit 1
fi
snapper_deb=
libsnapper_deb=
for package in "${packages[@]}"; do
    case $(basename "$package") in
        snapper_*.deb) snapper_deb=$package ;;
        libsnapper_*.deb) libsnapper_deb=$package ;;
    esac
done
if [[ -z $snapper_deb || -z $libsnapper_deb ]]; then
    echo "Error: expected snapper and libsnapper packages; found: ${packages[*]}" >&2
    exit 1
fi

audit_root="$work_root/binary-audit"
mkdir "$audit_root"
dpkg-deb -x "$snapper_deb" "$audit_root"
dpkg-deb -x "$libsnapper_deb" "$audit_root"
lib_dirs=$(find "$audit_root/usr" -type d \( -name 'lib' -o -name 'lib64' -o -name 'x86_64-linux-gnu' \) -print | paste -sd:)
features=$(LD_LIBRARY_PATH="$lib_dirs" "$audit_root/usr/bin/snapper" --version)
printf '%s\n' "$features"
if ! grep -q 'btrfs-quota' <<<"$features"; then
    echo "Error: built Snapper binary does not report btrfs-quota" >&2
    exit 1
fi

printf '\nAPT install simulation (no packages will be installed):\n'
apt-get -s --no-install-recommends install "${packages[@]}"
printf '\nBuilt packages are in: %s\n' "$work_root"

