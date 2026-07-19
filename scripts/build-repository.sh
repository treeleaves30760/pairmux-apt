#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUTPUT_DIR="$ROOT_DIR/public"
POOL_DIR="$OUTPUT_DIR/pool/main/p/pairmux"
DIST_DIR="$OUTPUT_DIR/dists/stable"
SOURCE_REPOSITORY=${SOURCE_REPOSITORY:-treeleaves30760/pairmux}
PUBLISHED_REPOSITORY_URL=${PUBLISHED_REPOSITORY_URL-https://treeleaves30760.github.io/pairmux-apt}
PER_PAGE=100

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

for command in apt-ftparchive curl dpkg-deb find gpg gzip jq sha256sum sha512sum touch; do
  command -v "$command" >/dev/null || die "required command not found: $command"
done

for path in \
  "$ROOT_DIR/pairmux-archive-keyring.asc" \
  "$ROOT_DIR/pairmux-archive-keyring.pgp" \
  "$ROOT_DIR/pairmux-archive-keyring.fingerprint" \
  "$ROOT_DIR/pairmux-archive-signing-subkey.fingerprint" \
  "$ROOT_DIR/config/keyring-version" \
  "$ROOT_DIR/config/keyring-source-date-epoch" \
  "$ROOT_DIR/config/keyring-package.sha256"
do
  [[ -f "$path" ]] || die "missing repository input: $path"
done

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

preserve_published_by_hash() {
  local base_url manifest status line_count relative_path target expected actual
  local previous_release previous_inrelease verify_home

  [[ -n "$PUBLISHED_REPOSITORY_URL" ]] || return 0
  base_url=${PUBLISHED_REPOSITORY_URL%/}
  previous_inrelease="$tmp_dir/previous-InRelease"
  status=$(curl --silent --show-error --location \
    --output "$previous_inrelease" \
    --write-out '%{http_code}' \
    "$base_url/dists/stable/InRelease") || die 'failed to query the published repository'
  case "$status" in
    200) ;;
    404) return 0 ;;
    *) die "published repository returned HTTP $status for InRelease" ;;
  esac

  verify_home="$tmp_dir/previous-gnupg"
  previous_release="$tmp_dir/previous-Release"
  install -d -m 0700 "$verify_home"
  GNUPGHOME="$verify_home" gpg --batch --import \
    "$ROOT_DIR/pairmux-archive-keyring.asc" >/dev/null 2>&1
  GNUPGHOME="$verify_home" gpg --batch --decrypt \
    "$previous_inrelease" > "$previous_release" 2>/dev/null || \
    die 'published InRelease signature verification failed'

  manifest="$tmp_dir/previous-by-hash-history.txt"
  status=$(curl --silent --show-error --location \
    --output "$manifest" \
    --write-out '%{http_code}' \
    "$base_url/dists/stable/by-hash-history.txt") || \
    die 'failed to download the published by-hash history'
  [[ "$status" == 200 ]] || die "published repository returned HTTP $status for by-hash history"

  expected=$(awk -F': ' '$1 == "X-Pairmux-By-Hash-History-SHA256" { print $2 }' \
    "$previous_release")
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die 'published Release has no valid by-hash history digest'
  actual=$(sha256sum "$manifest" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || die 'published by-hash history digest mismatch'
  expected=$(awk -F': ' '$1 == "X-Pairmux-By-Hash-History-Size" { print $2 }' \
    "$previous_release")
  [[ "$expected" =~ ^[0-9]+$ ]] || die 'published Release has no valid by-hash history size'
  [[ $(wc -c < "$manifest" | tr -d '[:space:]') == "$expected" ]] || \
    die 'published by-hash history size mismatch'

  line_count=$(wc -l < "$manifest" | tr -d '[:space:]')
  (( line_count <= 2000 )) || die 'published by-hash history is unexpectedly large'
  install -d -m 0755 "$tmp_dir/prior-by-hash"
  while IFS= read -r relative_path; do
    [[ "$relative_path" =~ ^dists/stable/main/binary-(amd64|arm64)/by-hash/(SHA256/[0-9a-f]{64}|SHA512/[0-9a-f]{128})$ ]] || \
      die "unsafe published by-hash path: $relative_path"
    target="$tmp_dir/prior-by-hash/$relative_path"
    install -d -m 0755 "$(dirname -- "$target")"
    curl --fail --silent --show-error --location --max-filesize 10485760 \
      --output "$target" "$base_url/$relative_path"
    expected=${relative_path##*/}
    case "$relative_path" in
      */SHA256/*) actual=$(sha256sum "$target" | awk '{print $1}') ;;
      */SHA512/*) actual=$(sha512sum "$target" | awk '{print $1}') ;;
    esac
    [[ "$actual" == "$expected" ]] || die "published by-hash content mismatch: $relative_path"
  done < "$manifest"
}

preserve_published_by_hash
rm -rf -- "$OUTPUT_DIR"
install -d -m 0755 "$POOL_DIR"

api_request() {
  local url=$1
  local -a args=(
    --fail
    --silent
    --show-error
    --location
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28'
  )
  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  curl "${args[@]}" "$url"
}

download_asset() {
  local tag=$1
  local name=$2
  local url=$3
  local digest=$4
  local expected_version expected_arch target actual_digest

  if [[ ! "$name" =~ ^pairmux_([0-9]+\.[0-9]+\.[0-9]+)_linux_(amd64|arm64)\.deb$ ]]; then
    die "unexpected release asset name: $name"
  fi
  expected_version=${BASH_REMATCH[1]}
  expected_arch=${BASH_REMATCH[2]}
  [[ "$tag" == "v$expected_version" ]] || die "asset $name does not match release tag $tag"
  [[ -z ${seen_assets["$expected_version:$expected_arch"]+x} ]] || \
    die "duplicate $expected_arch package for version $expected_version"
  target="$POOL_DIR/$name"
  [[ ! -e "$target" ]] || die "duplicate release asset: $name"

  curl --fail --silent --show-error --location --output "$target" "$url"

  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "missing or invalid GitHub digest for $name"
  actual_digest=$(sha256sum "$target" | awk '{print $1}')
  [[ "$actual_digest" == "${digest#sha256:}" ]] || die "SHA-256 mismatch for $name"

  [[ $(dpkg-deb --field "$target" Package) == pairmux ]] || die "wrong package name in $name"
  [[ $(dpkg-deb --field "$target" Version) == "$expected_version" ]] || die "wrong version in $name"
  [[ $(dpkg-deb --field "$target" Architecture) == "$expected_arch" ]] || die "wrong architecture in $name"
  seen_assets["$expected_version:$expected_arch"]=1
}

build_keyring_package() {
  local version source_date_epoch expected_digest actual_digest package_root package_path
  version=$(tr -d '[:space:]' < "$ROOT_DIR/config/keyring-version")
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'invalid keyring package version'
  source_date_epoch=$(tr -d '[:space:]' < "$ROOT_DIR/config/keyring-source-date-epoch")
  [[ "$source_date_epoch" =~ ^[0-9]{10}$ ]] || die 'invalid keyring SOURCE_DATE_EPOCH'
  expected_digest=$(tr -d '[:space:]' < "$ROOT_DIR/config/keyring-package.sha256")
  [[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || die 'invalid pinned keyring package digest'
  package_root="$tmp_dir/keyring-package"
  package_path="$POOL_DIR/pairmux-archive-keyring_${version}_all.deb"

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
  [[ "$actual_digest" == "$expected_digest" ]] || \
    die "keyring package digest changed; bump its version and pin $actual_digest"
}

page=1
package_count=0
declare -A stable_versions=()
declare -A seen_assets=()
while :; do
  response="$tmp_dir/releases-$page.json"
  tags="$tmp_dir/tags-$page.txt"
  manifest="$tmp_dir/assets-$page.tsv"
  api_request \
    "https://api.github.com/repos/$SOURCE_REPOSITORY/releases?per_page=$PER_PAGE&page=$page" \
    > "$response"

  release_count=$(jq 'length' "$response")
  jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name' \
    "$response" > "$tags"
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "unexpected stable release tag: $tag"
    stable_versions["${BASH_REMATCH[1]}"]=1
  done < "$tags"

  jq -r '
    .[] |
    select(.draft == false and .prerelease == false) as $release |
    $release.assets[] |
    select(.name | test("^pairmux_[0-9]+\\.[0-9]+\\.[0-9]+_linux_(amd64|arm64)\\.deb$")) |
    [$release.tag_name, .name, .browser_download_url, (.digest // "")] |
    @tsv
  ' "$response" > "$manifest"

  while IFS=$'\t' read -r tag name url digest; do
    [[ -n "$name" ]] || continue
    download_asset "$tag" "$name" "$url" "$digest"
    package_count=$((package_count + 1))
  done < "$manifest"

  (( release_count < PER_PAGE )) && break
  page=$((page + 1))
done

(( package_count > 0 )) || die "no stable pairmux Debian packages found in $SOURCE_REPOSITORY"
for version in "${!stable_versions[@]}"; do
  for arch in amd64 arm64; do
    [[ -n ${seen_assets["$version:$arch"]+x} ]] || \
      die "stable version $version is missing its $arch package"
  done
done

build_keyring_package

for arch in amd64 arm64; do
  binary_dir="$DIST_DIR/main/binary-$arch"
  install -d -m 0755 "$binary_dir"
  (
    cd "$OUTPUT_DIR"
    apt-ftparchive --arch "$arch" packages pool/main/p/pairmux
  ) > "$binary_dir/Packages"
  grep -q '^Package: pairmux$' "$binary_dir/Packages" || die "empty $arch package index"
  gzip -9 -n -c "$binary_dir/Packages" > "$binary_dir/Packages.gz"

  for index in Packages Packages.gz; do
    sha256=$(sha256sum "$binary_dir/$index" | awk '{print $1}')
    sha512=$(sha512sum "$binary_dir/$index" | awk '{print $1}')
    install -d -m 0755 "$binary_dir/by-hash/SHA256" "$binary_dir/by-hash/SHA512"
    cp "$binary_dir/$index" "$binary_dir/by-hash/SHA256/$sha256"
    cp "$binary_dir/$index" "$binary_dir/by-hash/SHA512/$sha512"
  done
done

if [[ -d "$tmp_dir/prior-by-hash" ]]; then
  while IFS= read -r prior_file; do
    relative_path=${prior_file#"$tmp_dir/prior-by-hash/"}
    target="$OUTPUT_DIR/$relative_path"
    install -d -m 0755 "$(dirname -- "$target")"
    if [[ -e "$target" ]]; then
      cmp -s "$prior_file" "$target" || die "by-hash collision: $relative_path"
    else
      install -m 0644 "$prior_file" "$target"
    fi
  done < <(find "$tmp_dir/prior-by-hash" -type f | sort)
fi

find "$DIST_DIR/main" -type f -path '*/by-hash/*' \
  | sed "s#^$OUTPUT_DIR/##" \
  | sort > "$DIST_DIR/by-hash-history.txt"
[[ -s "$DIST_DIR/by-hash-history.txt" ]] || die 'by-hash history is empty'

release_tmp="$tmp_dir/Release"
(
  cd "$OUTPUT_DIR"
  apt-ftparchive -c "$ROOT_DIR/config/release.conf" release dists/stable
) > "$release_tmp"
printf 'X-Pairmux-By-Hash-History-SHA256: %s\n' \
  "$(sha256sum "$DIST_DIR/by-hash-history.txt" | awk '{print $1}')" >> "$release_tmp"
printf 'X-Pairmux-By-Hash-History-Size: %s\n' \
  "$(wc -c < "$DIST_DIR/by-hash-history.txt" | tr -d '[:space:]')" >> "$release_tmp"
grep -Eq '[[:space:]][0-9]+[[:space:]]+(Release|InRelease|Release\.gpg)$' "$release_tmp" && \
  die 'Release metadata contains a self-reference'
install -m 0644 "$release_tmp" "$DIST_DIR/Release"

cp "$ROOT_DIR/pairmux-archive-keyring.asc" "$OUTPUT_DIR/pairmux-archive-keyring.asc"
cp "$ROOT_DIR/pairmux-archive-keyring.pgp" "$OUTPUT_DIR/pairmux-archive-keyring.pgp"
cp "$ROOT_DIR/pairmux-archive-keyring.fingerprint" "$OUTPUT_DIR/pairmux-archive-keyring.fingerprint"
cp "$ROOT_DIR/pairmux-archive-signing-subkey.fingerprint" \
  "$OUTPUT_DIR/pairmux-archive-signing-subkey.fingerprint"
cp "$ROOT_DIR/static/pairmux.sources" "$OUTPUT_DIR/pairmux.sources"
cp "$ROOT_DIR/static/pairmux.pref" "$OUTPUT_DIR/pairmux.pref"
cp "$ROOT_DIR/static/index.html" "$OUTPUT_DIR/index.html"
: > "$OUTPUT_DIR/.nojekyll"

printf 'built unsigned APT repository with %s pairmux package assets\n' "$package_count"
