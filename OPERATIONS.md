# Repository operations

## Release synchronization

The publish workflow reconstructs the repository from all stable releases in
`treeleaves30760/pairmux`. A daily schedule picks up new versions without a
cross-repository token. To publish immediately, run the `Publish APT
repository` workflow from the default branch.

The build fails closed when an asset has an unexpected filename, its GitHub
SHA-256 digest differs, its Debian metadata is wrong, either architecture is
missing from the generated indexes, or repository signature verification
fails.

## Signing-key storage

The archive key was created on 2026-07-19 UTC with this key structure:

- Certification-only RSA3072 primary key:
  `FC58F25C9526AE4D03AA73A1543AD39E6FFAB8AA`, expires 2031-07-18 UTC.
- Signing-only RSA3072 subkey:
  `5F5C8AA5670BF52DACE0F9A0BE7D428E33BEAD5A`, expires 2027-07-19 UTC.

The local recovery directory is `~/.config/pairmux-apt`. It contains the
encrypted complete secret key, public key, primary fingerprint, and revocation
certificate. Its passphrase is stored in the macOS login Keychain under service
`pairmux-apt-signing-key` and account `treeleaves30760`.

The important local files are:

- `primary-secret-key.asc`: encrypted complete primary and subkey backup.
- `online-signing-subkeys.asc`: encrypted signing-subkey export used by CI.
- `revocation-certificate.rev`: primary-key revocation certificate.
- `public-key.asc` and `public-key.pgp`: public backup copies.
- `primary.fingerprint` and `signing-subkey.fingerprint`: pinned identifiers.

GitHub environment `apt-signing` contains:

- `APT_GPG_PRIVATE_KEY_B64`: a single-line base64 encoding of the encrypted
  `gpg --armor --export-secret-subkeys` output.
- `APT_GPG_PASSPHRASE`: the subkey export passphrase.

The complete certification-capable primary secret key must never be uploaded
to GitHub or copied into a workflow artifact.

The local directory and login Keychain are on the same Mac, so they are not an
offline disaster-recovery copy. Keep another encrypted copy of
`primary-secret-key.asc` and `revocation-certificate.rev` on an offline device
or in a separately administered credential vault. Verify that copy at least
once per quarter in an isolated temporary `GNUPGHOME`: import it, check both
fingerprints, capabilities and expiry dates, create and verify a sample
signature, then destroy the temporary keyring.

## Signing-subkey rotation

Start rotation at least 90 days before the signing subkey expires. Rotation is
a two-deployment operation:

1. Retrieve the passphrase from Keychain and import the complete encrypted
   backup into a temporary isolated `GNUPGHOME`.
2. Add a new signing-only subkey with `gpg --quick-add-key PRIMARY_FINGERPRINT
   rsa3072 sign 1y`.
3. Re-export the minimal public key and encrypted recovery copies. Bump
   `config/keyring-version`, reset `config/keyring-source-date-epoch`, and pin
   the new deterministic package digest in `config/keyring-package.sha256`.
4. Deployment A must still be signed by the old subkey. Publish `.pgp`, `.asc`
   and `pairmux-archive-keyring` containing both old and new public subkeys.
   Confirm that a client with the old keyring can run `apt-get update` and
   upgrade the keyring package. Keep this overlap deployment live for at least
   30 days.
5. Replace `APT_GPG_PRIVATE_KEY_B64` with a base64 encoding of a fresh
   `gpg --armor --export-secret-subkeys PRIMARY_FINGERPRINT` export.
6. Deployment B switches `pairmux-archive-signing-subkey.fingerprint` to the
   new subkey. Run clean-client installs and an upgraded-old-client test before
   completing the deployment.
7. Retain the old public subkey for rollback until it expires or is revoked,
   and preserve the existing primary revocation certificate.

Clients keep the same `Signed-By` path and primary fingerprint, but they must
install the updated `pairmux-archive-keyring` package before the signer
switches. A new subkey is not learned automatically from repository metadata.

## Metadata freshness

The repository does not currently set `Valid-Until`. This avoids disabling
installs if GitHub automatically pauses scheduled workflows after prolonged
repository inactivity, but it permits replay of older correctly signed
metadata. Continue the daily rebuild schedule and monitor Pages. Add a bounded
`Valid-Until` only together with external failure alerting that is independent
of this repository.

Once a month, inspect the public key without loading any secret material and
alert when either active key has fewer than 90 days remaining. Plan a new
primary key and separately authenticated client migration well before the
primary expires in 2031.

## Verification

Before publication, build twice on Ubuntu 24.04 and confirm that
`pairmux-archive-keyring_1.0.0_all.deb` has the pinned SHA-256 on both runs.
Sign into a temporary `GNUPGHOME`, then run `scripts/verify-repository.sh`.

Client verification covers Ubuntu 22.04 and 24.04 on both amd64 and arm64:

```bash
docker run --rm --platform linux/amd64 -v "$PWD:/repo:ro" ubuntu:24.04 \
  bash /repo/scripts/test-apt-client.sh REPOSITORY_URL
```

Repeat with `linux/arm64` and both Ubuntu tags. The test hard-checks the key
fingerprint, verifies APT uses `by-hash`, checks the candidate and installed
package metadata, runs `pairmux doctor`, and completes a real
`new`/`run`/`kill` workflow.

Run `scripts/test-apt-fail-closed.sh` in clean containers against fixtures for
`wrong-key`, `tampered-inrelease`, `tampered-index`, and `tampered-package`.
Every mode must reject the repository or package with a signature or hash
error. Rehearse the old-client keyring upgrade as part of every signer rotation.

## Recovery and revocation

If the online signing subkey may be compromised, immediately disable the
publish workflow and Pages deployment and delete the environment secrets.
Revoke the subkey with the primary key. A compromised signer is not a safe way
to distribute its replacement: automatic recovery is possible only when the
replacement public subkey was delivered by the keyring package before the
incident. Otherwise require a separately authenticated manual keyring update
before publishing with a new subkey.

If the primary key may be compromised, publish its revocation certificate,
create a new primary fingerprint, and require every client to re-bootstrap the
new key through independently authenticated GitHub release notes and project
documentation. Do not present this as an automatic keyring-package rollover.

For Mac loss or local corruption, restore the encrypted primary backup and
revocation certificate from the independent copy, retrieve its passphrase from
the separately administered store, run the isolated restore drill described
above, and only then recreate the GitHub signing-subkey secret.
