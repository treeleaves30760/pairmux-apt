#!/usr/bin/env bash

set -euo pipefail

BASE_URL=${1:?usage: test-apt-client.sh REPOSITORY_URL}
EXPECTED_VERSION=${EXPECTED_VERSION:-0.1.0}
EXPECTED_FINGERPRINT=FC58F25C9526AE4D03AA73A1543AD39E6FFAB8AA
terminal_name="apt-install-smoke-$$"
tmp_dir=$(mktemp -d)

cleanup() {
  pairmux kill "$terminal_name" >/dev/null 2>&1 || true
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

[[ $(id -u) == 0 ]] || {
  printf 'error: this client test must run as root\n' >&2
  exit 1
}

architecture=$(dpkg --print-architecture)
case "$architecture" in
  amd64|arm64) ;;
  *)
    printf 'error: unsupported test architecture: %s\n' "$architecture" >&2
    exit 1
    ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg jq >/dev/null

curl --fail --silent --show-error --location \
  --output "$tmp_dir/pairmux-archive-keyring.pgp" \
  "$BASE_URL/pairmux-archive-keyring.pgp"
actual_fingerprint=$(gpg --batch --show-keys --with-colons \
  "$tmp_dir/pairmux-archive-keyring.pgp" | awk -F: '$1 == "fpr" { print $10; exit }')
[[ "$actual_fingerprint" == "$EXPECTED_FINGERPRINT" ]] || {
  printf 'error: archive key fingerprint mismatch\n' >&2
  exit 1
}

install -d -m 0755 /usr/share/keyrings
install -o root -g root -m 0644 "$tmp_dir/pairmux-archive-keyring.pgp" \
  /usr/share/keyrings/pairmux-archive-keyring.pgp
cat > /etc/apt/sources.list.d/pairmux.sources <<EOF
Types: deb
URIs: $BASE_URL
Suites: stable
Components: main
Architectures: $architecture
Signed-By: /usr/share/keyrings/pairmux-archive-keyring.pgp
EOF
repository_host=${BASE_URL#*://}
repository_host=${repository_host%%/*}
repository_host=${repository_host%%:*}
cat > /etc/apt/preferences.d/pairmux.pref <<EOF
Package: *
Pin: origin $repository_host
Pin-Priority: 100
EOF

apt-get update -o Debug::Acquire::http=true 2>&1 | tee "$tmp_dir/apt-update.log"
grep -Eq '/by-hash/(SHA256/[0-9a-f]{64}|SHA512/[0-9a-f]{128})' \
  "$tmp_dir/apt-update.log" || {
  printf 'error: APT did not acquire the package index by hash\n' >&2
  exit 1
}
apt-cache policy pairmux | tee "$tmp_dir/policy.log"
grep -Eq "Candidate: ${EXPECTED_VERSION}([[:space:]]|$)" "$tmp_dir/policy.log"
grep -Fq "$BASE_URL" "$tmp_dir/policy.log"

apt-get install -y pairmux-archive-keyring "pairmux=$EXPECTED_VERSION"
[[ $(dpkg-query -W -f='${db:Status-Abbrev}' pairmux) == ii\  ]]
[[ $(dpkg-query -W -f='${Version}' pairmux) == "$EXPECTED_VERSION" ]]
[[ $(dpkg-query -W -f='${Architecture}' pairmux) == "$architecture" ]]
[[ $(dpkg-query -W -f='${db:Status-Abbrev}' pairmux-archive-keyring) == ii\  ]]
cmp -s "$tmp_dir/pairmux-archive-keyring.pgp" \
  /usr/share/keyrings/pairmux-archive-keyring.pgp
[[ $(pairmux version) == "$EXPECTED_VERSION" ]]
pairmux --json doctor | tee "$tmp_dir/doctor.json"
jq -e '.ok == true and .status == "ok"' "$tmp_dir/doctor.json" >/dev/null

pairmux --json new --name "$terminal_name" | tee "$tmp_dir/new.json"
jq -e '.ok == true and .status == "created"' "$tmp_dir/new.json" >/dev/null
pairmux --json run "$terminal_name" "printf apt-ok" | tee "$tmp_dir/run.json"
jq -e '.ok == true and .status == "done" and .exit_code == 0 and (.output | contains("apt-ok"))' \
  "$tmp_dir/run.json" >/dev/null
pairmux kill "$terminal_name" >/dev/null

os_version=$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2 }' /etc/os-release)
printf 'APT client smoke test passed on Ubuntu %s %s\n' "$os_version" "$architecture"
