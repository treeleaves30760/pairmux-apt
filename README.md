# pairmux APT repository

Signed APT repository metadata and automation for
[`treeleaves30760/pairmux`](https://github.com/treeleaves30760/pairmux).
The published repository is rebuilt from every non-draft, non-prerelease
GitHub release so older stable versions remain installable.

## Install

```bash
(
set -euo pipefail

sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
expected_fingerprint=FC58F25C9526AE4D03AA73A1543AD39E6FFAB8AA
keyring=$(mktemp)
trap 'rm -f -- "$keyring"' EXIT
curl -fsSL --output "$keyring" \
  https://treeleaves30760.github.io/pairmux-apt/pairmux-archive-keyring.pgp
actual_fingerprint=$(gpg --batch --show-keys --with-colons "$keyring" \
  | awk -F: '$1 == "fpr" { print $10; exit }')
test "$actual_fingerprint" = "$expected_fingerprint"
sudo install -d -m 0755 /usr/share/keyrings
sudo install -o root -g root -m 0644 "$keyring" \
  /usr/share/keyrings/pairmux-archive-keyring.pgp

architecture=$(dpkg --print-architecture)
case "$architecture" in
  amd64|arm64) ;;
  *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac
cat <<EOF | sudo tee /etc/apt/sources.list.d/pairmux.sources >/dev/null
Types: deb
URIs: https://treeleaves30760.github.io/pairmux-apt
Suites: stable
Components: main
Architectures: $architecture
Signed-By: /usr/share/keyrings/pairmux-archive-keyring.pgp
EOF
cat <<'EOF' | sudo tee /etc/apt/preferences.d/pairmux.pref >/dev/null
Package: *
Pin: origin treeleaves30760.github.io
Pin-Priority: 100
EOF

sudo apt-get update
sudo apt-get install pairmux-archive-keyring pairmux
pairmux version
pairmux doctor
)
```

The bootstrap command rejects a key unless its primary fingerprint is exactly:

```text
FC58 F25C 9526 AE4D 03AA  73A1 543A D39E 6FFA B8AA
```

The same value is published in
[`pairmux-archive-keyring.fingerprint`](./pairmux-archive-keyring.fingerprint).

## Publication

The Pages workflow runs on changes to `main`, once per day, and on manual
dispatch. It downloads stable `.deb` assets, checks their GitHub SHA-256
digests and Debian metadata, generates per-architecture indexes with
`apt-ftparchive`, signs `Release` as both `InRelease` and `Release.gpg`, and
deploys the verified repository to GitHub Pages.

The `apt-signing` GitHub environment holds only a base64-encoded encrypted
signing-subkey export and its passphrase. The certification-capable primary
key is excluded from CI and retained in encrypted recovery copies. Installing
`pairmux-archive-keyring` lets APT deliver future public signing-subkey updates
before the active signer rotates.
See [OPERATIONS.md](./OPERATIONS.md) for rotation and recovery procedures.
