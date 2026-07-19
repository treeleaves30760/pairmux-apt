#!/usr/bin/env bash

set -euo pipefail

BASE_URL=${1:?usage: test-apt-fail-closed.sh REPOSITORY_URL MODE}
MODE=${2:?usage: test-apt-fail-closed.sh REPOSITORY_URL MODE}
EXPECTED_FINGERPRINT=FC58F25C9526AE4D03AA73A1543AD39E6FFAB8AA
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ $(id -u) == 0 ]] || die 'this client test must run as root'
architecture=$(dpkg --print-architecture)
[[ "$architecture" == amd64 || "$architecture" == arm64 ]] || \
  die "unsupported test architecture: $architecture"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg >/dev/null
install -d -m 0755 /usr/share/keyrings

case "$MODE" in
  wrong-key)
    wrong_home="$tmp_dir/wrong-gnupg"
    install -d -m 0700 "$wrong_home"
    GNUPGHOME="$wrong_home" gpg --batch --passphrase '' \
      --quick-gen-key 'Wrong APT Test Key <wrong@example.invalid>' rsa2048 sign 1d \
      >/dev/null 2>&1
    GNUPGHOME="$wrong_home" gpg --batch --export \
      > /usr/share/keyrings/pairmux-archive-keyring.pgp
    ;;
  tampered-inrelease|tampered-index|tampered-package)
    curl --fail --silent --show-error --location \
      --output "$tmp_dir/pairmux-archive-keyring.pgp" \
      "$BASE_URL/pairmux-archive-keyring.pgp"
    actual_fingerprint=$(gpg --batch --show-keys --with-colons \
      "$tmp_dir/pairmux-archive-keyring.pgp" | awk -F: '$1 == "fpr" { print $10; exit }')
    [[ "$actual_fingerprint" == "$EXPECTED_FINGERPRINT" ]] || \
      die 'archive key fingerprint mismatch'
    install -o root -g root -m 0644 "$tmp_dir/pairmux-archive-keyring.pgp" \
      /usr/share/keyrings/pairmux-archive-keyring.pgp
    ;;
  *) die "unknown fail-closed mode: $MODE" ;;
esac

cat > /etc/apt/sources.list.d/pairmux.sources <<EOF
Types: deb
URIs: $BASE_URL
Suites: stable
Components: main
Architectures: $architecture
Signed-By: /usr/share/keyrings/pairmux-archive-keyring.pgp
EOF

case "$MODE" in
  wrong-key|tampered-inrelease|tampered-index)
    if apt-get update > "$tmp_dir/failure.log" 2>&1; then
      die "APT unexpectedly accepted $MODE repository metadata"
    fi
    case "$MODE" in
      wrong-key)
        grep -Eiq 'NO_PUBKEY|signatures couldn.t be verified|not signed' "$tmp_dir/failure.log" || \
          die 'wrong-key failure did not report signature authentication'
        ;;
      tampered-inrelease)
        grep -Eiq 'BADSIG|invalid signature|not signed|Clearsigned file.*not valid' \
          "$tmp_dir/failure.log" || \
          die 'tampered InRelease failure did not report an invalid signature'
        ;;
      tampered-index)
        grep -Eiq 'Hash Sum mismatch|unexpected size|Failed to fetch' "$tmp_dir/failure.log" || \
          die 'tampered index failure did not report an integrity error'
        ;;
    esac
    ;;
  tampered-package)
    apt-get update -qq
    if apt-get install -y pairmux=0.1.0 > "$tmp_dir/failure.log" 2>&1; then
      die 'APT unexpectedly installed the tampered package'
    fi
    grep -Eiq 'Hash Sum mismatch|unexpected size|Failed to fetch' "$tmp_dir/failure.log" || \
      die 'tampered package failure did not report an integrity error'
    ;;
esac

printf 'APT fail-closed test passed: %s on %s\n' "$MODE" "$architecture"
