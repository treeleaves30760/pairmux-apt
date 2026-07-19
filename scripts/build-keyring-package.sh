#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MODE=${1:---check}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ "$MODE" == --check || "$MODE" == --write ]] || \
  die 'usage: build-keyring-package.sh [--check|--write]'
for command in cmp dpkg-deb find sha256sum touch; do
  command -v "$command" >/dev/null || die "required command not found: $command"
done

version=$(tr -d '[:space:]' < "$ROOT_DIR/config/keyring-version")
source_date_epoch=$(tr -d '[:space:]' < "$ROOT_DIR/config/keyring-source-date-epoch")
expected_digest=$(tr -d '[:space:]' < "$ROOT_DIR/config/keyring-package.sha256")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'invalid keyring package version'
[[ "$source_date_epoch" =~ ^[0-9]{10}$ ]] || die 'invalid keyring SOURCE_DATE_EPOCH'
[[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || die 'invalid pinned keyring package digest'

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
package_root="$tmp_dir/keyring-package"
package_path="$tmp_dir/pairmux-archive-keyring_${version}_all.deb"
committed_path="$ROOT_DIR/package/pairmux-archive-keyring_${version}_all.deb"

install -d -m 0755 \
  "$package_root/DEBIAN" \
  "$package_root/usr/share/keyrings" \
  "$package_root/usr/share/doc/pairmux-archive-keyring"
printf '%s\n' \
  'Package: pairmux-archive-keyring' \
  "Version: $version" \
  'Section: misc' \
  'Priority: optional' \
  'Architecture: all' \
  'Maintainer: treeleaves30760 <treeleaves30760.ai@gmail.com>' \
  'Description: OpenPGP archive key for the pairmux APT repository' \
  ' This package distributes the public key used to authenticate pairmux' \
  ' repository metadata.' \
  > "$package_root/DEBIAN/control"
install -m 0644 "$ROOT_DIR/pairmux-archive-keyring.pgp" \
  "$package_root/usr/share/keyrings/pairmux-archive-keyring.pgp"
install -m 0644 "$ROOT_DIR/LICENSE" \
  "$package_root/usr/share/doc/pairmux-archive-keyring/copyright"
find "$package_root" -exec touch -h --date="@$source_date_epoch" {} +
SOURCE_DATE_EPOCH="$source_date_epoch" \
  dpkg-deb --build --root-owner-group "$package_root" "$package_path" >/dev/null
actual_digest=$(sha256sum "$package_path" | awk '{print $1}')

if [[ "$MODE" == --write ]]; then
  install -d -m 0755 "$ROOT_DIR/package"
  install -m 0644 "$package_path" "$committed_path"
  printf 'wrote %s\n' "$committed_path"
  printf 'set config/keyring-package.sha256 to %s\n' "$actual_digest"
else
  [[ -f "$committed_path" ]] || die 'committed keyring package is missing'
  [[ "$actual_digest" == "$expected_digest" ]] || die 'rebuilt keyring package digest differs'
  cmp -s "$package_path" "$committed_path" || die 'rebuilt keyring package bytes differ'
  printf 'verified reproducible keyring package %s\n' "$actual_digest"
fi
