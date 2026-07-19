#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REPOSITORY_DIR=${1:-$ROOT_DIR/public}
FINGERPRINT_FILE="$ROOT_DIR/pairmux-archive-keyring.fingerprint"
SIGNING_FINGERPRINT_FILE="$ROOT_DIR/pairmux-archive-signing-subkey.fingerprint"
KEY_FILE="$ROOT_DIR/pairmux-archive-keyring.asc"
DIST_DIR="$REPOSITORY_DIR/dists/stable"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

for command in awk cmp dpkg-deb gpg gzip sha256sum sha512sum sort; do
  command -v "$command" >/dev/null || die "required command not found: $command"
done

for path in \
  "$KEY_FILE" \
  "$ROOT_DIR/pairmux-archive-keyring.pgp" \
  "$FINGERPRINT_FILE" \
  "$SIGNING_FINGERPRINT_FILE" \
  "$DIST_DIR/InRelease" \
  "$DIST_DIR/Release" \
  "$DIST_DIR/Release.gpg" \
  "$DIST_DIR/by-hash-history.txt"
do
  [[ -f "$path" ]] || die "missing repository file: $path"
done

for name in \
  pairmux-archive-keyring.asc \
  pairmux-archive-keyring.pgp \
  pairmux-archive-keyring.fingerprint \
  pairmux-archive-signing-subkey.fingerprint
do
  cmp -s "$ROOT_DIR/$name" "$REPOSITORY_DIR/$name" || \
    die "published $name differs from its source"
done
for name in pairmux.sources pairmux.pref; do
  cmp -s "$ROOT_DIR/static/$name" "$REPOSITORY_DIR/$name" || \
    die "published $name differs from its source"
done

fingerprint=$(tr -d '[:space:]' < "$FINGERPRINT_FILE")
signing_fingerprint=$(tr -d '[:space:]' < "$SIGNING_FINGERPRINT_FILE")
[[ "$fingerprint" =~ ^[A-F0-9]{40}$ ]] || die 'invalid primary key fingerprint'
[[ "$signing_fingerprint" =~ ^[A-F0-9]{40}$ ]] || die 'invalid signing subkey fingerprint'
verify_home=$(mktemp -d)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$verify_home" "$tmp_dir"' EXIT
chmod 0700 "$verify_home"
key_listing=$(GNUPGHOME="$verify_home" gpg --batch --show-keys --with-colons "$KEY_FILE")
key_fingerprint=$(awk -F: '$1 == "fpr" { print $10; exit }' <<< "$key_listing")
[[ "$key_fingerprint" == "$fingerprint" ]] || \
  die 'public key fingerprint does not match the pinned fingerprint'
grep -Fq "fpr:::::::::$signing_fingerprint:" <<< "$key_listing" || \
  die 'pinned signing subkey is absent from the public key'

GNUPGHOME="$verify_home" gpg --batch --import "$KEY_FILE" >/dev/null 2>&1
GNUPGHOME="$verify_home" gpg --batch --status-fd 1 \
  --output "$tmp_dir/inrelease-plaintext" --decrypt "$DIST_DIR/InRelease" \
  2>/dev/null > "$tmp_dir/inrelease-status" || die 'InRelease signature verification failed'
grep -Fq "[GNUPG:] VALIDSIG $signing_fingerprint " "$tmp_dir/inrelease-status" || \
  die 'InRelease was not signed by the pinned signing subkey'
cmp -s "$tmp_dir/inrelease-plaintext" "$DIST_DIR/Release" || \
  die 'InRelease plaintext differs from Release'
GNUPGHOME="$verify_home" gpg --batch --status-fd 1 --verify \
  "$DIST_DIR/Release.gpg" "$DIST_DIR/Release" \
  2>/dev/null > "$tmp_dir/release-gpg-status" || die 'Release.gpg signature verification failed'
grep -Fq "[GNUPG:] VALIDSIG $signing_fingerprint " "$tmp_dir/release-gpg-status" || \
  die 'Release.gpg was not signed by the pinned signing subkey'

grep -qx 'Suite: stable' "$DIST_DIR/Release" || die 'Release Suite is not stable'
grep -qx 'Codename: stable' "$DIST_DIR/Release" || die 'Release Codename is not stable'
grep -qx 'Architectures: amd64 arm64' "$DIST_DIR/Release" || die 'Release architectures are incomplete'
grep -qx 'Components: main' "$DIST_DIR/Release" || die 'Release component is not main'
grep -qx 'Acquire-By-Hash: yes' "$DIST_DIR/Release" || die 'Acquire-By-Hash is not enabled'

verify_release_checksum() {
  local section=$1
  local relative_path=$2
  local file=$3
  local entry expected_digest expected_size actual_digest actual_size

  entry=$(awk -v header="$section:" -v path="$relative_path" '
    $0 == header { inside = 1; next }
    inside && $0 !~ /^ / { inside = 0 }
    inside && $3 == path { print $1 " " $2; count++ }
    END { if (count != 1) exit 1 }
  ' "$DIST_DIR/Release") || die "Release has no unique $section entry for $relative_path"
  read -r expected_digest expected_size <<< "$entry"
  actual_size=$(wc -c < "$file" | tr -d '[:space:]')
  [[ "$actual_size" == "$expected_size" ]] || die "Release size mismatch for $relative_path"
  case "$section" in
    SHA256) actual_digest=$(sha256sum "$file" | awk '{print $1}') ;;
    SHA512) actual_digest=$(sha512sum "$file" | awk '{print $1}') ;;
    *) die "unsupported Release checksum: $section" ;;
  esac
  [[ "$actual_digest" == "$expected_digest" ]] || \
    die "Release $section mismatch for $relative_path"
}

history="$DIST_DIR/by-hash-history.txt"
history_digest=$(awk -F': ' '$1 == "X-Pairmux-By-Hash-History-SHA256" { print $2 }' \
  "$DIST_DIR/Release")
history_size=$(awk -F': ' '$1 == "X-Pairmux-By-Hash-History-Size" { print $2 }' \
  "$DIST_DIR/Release")
[[ "$history_digest" =~ ^[0-9a-f]{64}$ ]] || die 'Release has no valid by-hash history digest'
[[ "$history_size" =~ ^[0-9]+$ ]] || die 'Release has no valid by-hash history size'
[[ $(sha256sum "$history" | awk '{print $1}') == "$history_digest" ]] || \
  die 'by-hash history digest mismatch'
[[ $(wc -c < "$history" | tr -d '[:space:]') == "$history_size" ]] || \
  die 'by-hash history size mismatch'
[[ -s "$history" ]] || die 'by-hash history is empty'
[[ -z $(sort "$history" | uniq -d) ]] || die 'by-hash history contains duplicate paths'
while IFS= read -r relative_path; do
  [[ "$relative_path" =~ ^dists/stable/main/binary-(amd64|arm64)/by-hash/(SHA256/[0-9a-f]{64}|SHA512/[0-9a-f]{128})$ ]] || \
    die "unsafe by-hash history path: $relative_path"
  file="$REPOSITORY_DIR/$relative_path"
  [[ -f "$file" ]] || die "missing retained by-hash file: $relative_path"
  expected_digest=${relative_path##*/}
  case "$relative_path" in
    */SHA256/*) actual_digest=$(sha256sum "$file" | awk '{print $1}') ;;
    */SHA512/*) actual_digest=$(sha512sum "$file" | awk '{print $1}') ;;
  esac
  [[ "$actual_digest" == "$expected_digest" ]] || \
    die "retained by-hash file does not match its name: $relative_path"
done < "$history"

package_count=0
keyring_version=$(tr -d '[:space:]' < "$ROOT_DIR/config/keyring-version")
keyring_digest=$(tr -d '[:space:]' < "$ROOT_DIR/config/keyring-package.sha256")
for arch in amd64 arm64; do
  binary_dir="$DIST_DIR/main/binary-$arch"
  packages="$binary_dir/Packages"
  compressed="$binary_dir/Packages.gz"
  [[ -s "$packages" && -s "$compressed" ]] || die "missing $arch package indexes"
  gzip -cd "$compressed" > "$tmp_dir/Packages-$arch"
  cmp -s "$packages" "$tmp_dir/Packages-$arch" || die "compressed $arch index differs"

  relative_packages="main/binary-$arch/Packages"
  relative_compressed="$relative_packages.gz"
  verify_release_checksum SHA256 "$relative_packages" "$packages"
  verify_release_checksum SHA512 "$relative_packages" "$packages"
  verify_release_checksum SHA256 "$relative_compressed" "$compressed"
  verify_release_checksum SHA512 "$relative_compressed" "$compressed"

  records="$tmp_dir/records-$arch"
  awk '
    BEGIN { RS = ""; FS = "\n"; OFS = "\t" }
    {
      package = version = architecture = filename = size = sha256 = sha512 = ""
      for (i = 1; i <= NF; i++) {
        split($i, parts, ": ")
        key = parts[1]
        value = substr($i, length(key) + 3)
        if (key == "Package") package = value
        else if (key == "Version") version = value
        else if (key == "Architecture") architecture = value
        else if (key == "Filename") filename = value
        else if (key == "Size") size = value
        else if (key == "SHA256") sha256 = value
        else if (key == "SHA512") sha512 = value
      }
      if (!package || !version || !architecture || !filename || !size || !sha256 || !sha512) exit 2
      print filename, package, version, architecture, size, sha256, sha512
    }
  ' "$packages" > "$records" || die "invalid package stanza in $arch index"
  [[ -s "$records" ]] || die "no package records in $arch index"
  cut -f1 "$records" | sort > "$tmp_dir/paths-$arch"
  [[ -z $(uniq -d "$tmp_dir/paths-$arch") ]] || die "duplicate package path in $arch index"

  pairmux_count=0
  keyring_count=0
  : > "$tmp_dir/pairmux-versions-$arch"
  while IFS=$'\t' read -r relative_path indexed_name indexed_version indexed_arch \
    indexed_size indexed_sha256 indexed_sha512
  do
    [[ "$relative_path" =~ ^pool/main/p/pairmux/[^/]+\.deb$ ]] || \
      die "unsafe package path: $relative_path"
    package="$REPOSITORY_DIR/$relative_path"
    [[ -f "$package" ]] || die "indexed package is missing: $relative_path"
    [[ $(wc -c < "$package" | tr -d '[:space:]') == "$indexed_size" ]] || \
      die "package size mismatch: $relative_path"
    [[ $(sha256sum "$package" | awk '{print $1}') == "$indexed_sha256" ]] || \
      die "package SHA256 mismatch: $relative_path"
    [[ $(sha512sum "$package" | awk '{print $1}') == "$indexed_sha512" ]] || \
      die "package SHA512 mismatch: $relative_path"
    [[ $(dpkg-deb --field "$package" Package) == "$indexed_name" ]] || \
      die "package name mismatch: $relative_path"
    [[ $(dpkg-deb --field "$package" Version) == "$indexed_version" ]] || \
      die "package version mismatch: $relative_path"
    [[ $(dpkg-deb --field "$package" Architecture) == "$indexed_arch" ]] || \
      die "package architecture mismatch: $relative_path"

    case "$indexed_name" in
      pairmux)
        [[ "$indexed_arch" == "$arch" ]] || die "wrong architecture in $relative_path"
        [[ "$relative_path" == "pool/main/p/pairmux/pairmux_${indexed_version}_linux_${arch}.deb" ]] || \
          die "unexpected pairmux filename: $relative_path"
        printf '%s\n' "$indexed_version" >> "$tmp_dir/pairmux-versions-$arch"
        pairmux_count=$((pairmux_count + 1))
        ;;
      pairmux-archive-keyring)
        [[ "$indexed_arch" == all ]] || die 'keyring package is not architecture all'
        [[ "$indexed_version" == "$keyring_version" ]] || die 'wrong keyring package version'
        [[ "$indexed_sha256" == "$keyring_digest" ]] || die 'wrong keyring package digest'
        [[ "$relative_path" == "pool/main/p/pairmux/pairmux-archive-keyring_${keyring_version}_all.deb" ]] || \
          die "unexpected keyring package filename: $relative_path"
        cmp -s "$ROOT_DIR/package/pairmux-archive-keyring_${keyring_version}_all.deb" \
          "$package" || die 'published keyring package differs from the immutable artifact'
        extract_dir="$tmp_dir/keyring-$arch"
        dpkg-deb --extract "$package" "$extract_dir"
        cmp -s "$ROOT_DIR/pairmux-archive-keyring.pgp" \
          "$extract_dir/usr/share/keyrings/pairmux-archive-keyring.pgp" || \
          die 'keyring package contains the wrong public key'
        keyring_count=$((keyring_count + 1))
        ;;
      *) die "unexpected package in index: $indexed_name" ;;
    esac
    package_count=$((package_count + 1))
  done < "$records"

  (( pairmux_count > 0 )) || die "pairmux is missing from the $arch index"
  (( keyring_count == 1 )) || die "$arch index does not contain exactly one keyring package"
  sort -u "$tmp_dir/pairmux-versions-$arch" -o "$tmp_dir/pairmux-versions-$arch"

  for index in Packages Packages.gz; do
    sha256=$(sha256sum "$binary_dir/$index" | awk '{print $1}')
    sha512=$(sha512sum "$binary_dir/$index" | awk '{print $1}')
    cmp -s "$binary_dir/$index" "$binary_dir/by-hash/SHA256/$sha256" || \
      die "missing SHA256 by-hash index for $arch/$index"
    cmp -s "$binary_dir/$index" "$binary_dir/by-hash/SHA512/$sha512" || \
      die "missing SHA512 by-hash index for $arch/$index"
    grep -Fxq "dists/stable/main/binary-$arch/by-hash/SHA256/$sha256" "$history" || \
      die "current SHA256 by-hash index is absent from history for $arch/$index"
    grep -Fxq "dists/stable/main/binary-$arch/by-hash/SHA512/$sha512" "$history" || \
      die "current SHA512 by-hash index is absent from history for $arch/$index"
  done
done

cmp -s "$tmp_dir/pairmux-versions-amd64" "$tmp_dir/pairmux-versions-arm64" || \
  die 'pairmux versions differ between architecture indexes'
(( package_count > 0 )) || die 'no packages verified'
printf 'verified signed APT repository with %s indexed packages\n' "$package_count"
