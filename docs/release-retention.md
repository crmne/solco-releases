# Release retention

Only current application downloads remain available after a successful release.
An alpha replaces older alphas and keeps stable releases available to clients on
the stable update channel. A stable release replaces older stable and alpha
application releases. Drafts and unrelated tags, including model staging tags,
are preserved. Git tags and repository history are always retained.

This policy applies only to `crmne/solco-releases`. It cannot delete private
source releases, model sources, Git refs or assets from other repositories.
Removing an old release removes its attached downloads. Existing local copies
and the updater's local rollback files are unaffected.

## Publication and verification

The release workflow builds in parallel, then serializes publication and
retirement across versions behind the existing `release-signing` environment.
The environment approval and `contents: write` token cover both publication and
the retirement policy. No extra token or repository permission is needed.

Immediately before any release creation, upload or edit, the same locked job
checks that no newer published application version exists. A rebuilt retired
tag therefore cannot restore older downloads before the retirement step gets
a chance to reject it. Drafts and unrelated tags do not block publication;
rerunning the current version remains supported.

Before publishing, alpha notes must be the reviewed `release/notes.md` in the
private source tag. Stable notes must be committed at
`packaging/release-notes/vX.Y.Z.md`; missing notes stop the preflight. All ten
platform packages, including both architectures' DEBs and RPMs, enter the same
signed checksum manifest before upload.

After publishing, `scripts/release_retention.rb plan`:

1. Inventories all public releases and records the exact older release IDs and
   their asset IDs, sizes, names, digests and timestamps. Unknown assets on an
   otherwise eligible old application release require review and stop retirement.
2. Downloads all ten platform packages and `checksums.txt` plus its signature.
   It checks sizes and available GitHub digests, verifies the Ed25519 signature
   against the publisher key committed in the private source tag, and compares
   every package with the signed SHA-256 manifest. Missing, duplicate or extra
   assets fail verification. No application binary is executed.
3. Checks the public release page and every HTTPS download, screenshot, video
   and other link present in the release notes. Links into a release selected
   for retirement are rejected. Release media must already be available; the
   current exact asset set does not allow extra release attachments.
4. Saves a JSON retirement plan as the public workflow artifact
   `release-retirement-vVERSION`. It contains only public release metadata and
   verification results, never source, credentials or model plaintext.

`apply` rechecks the saved inventory, downloads/signature and links. Immediately
before each deletion it checks the live inventory again. A newer published
application version, changed release or changed asset stops retirement. Only the
release IDs in the saved plan are deleted, and the final inventory must confirm
the result. The script never calls a Git tag or ref deletion endpoint.

A failed check leaves remaining older releases in place and fails the workflow.
If some releases were already removed before an external change or API failure,
inspect the inventory and generate a fresh plan for what remains. Do not edit a
saved plan to bypass a failed check. Publication and deletion are separate GitHub
API operations, so failures cannot roll back already deleted release objects.

## Maintainer commands

The normal path is the public `Build release` workflow, dispatched with the
version and its private source tag:

```sh
gh workflow run release.yml --repo crmne/solco-releases \
  -f version=0.8.0-alpha.1 -f source_ref=v0.8.0-alpha.1
```

To inspect a published release without deleting anything, use a fresh directory
under `~/.cache` and the public key from that exact private source tag:

```sh
ruby scripts/release_retention.rb plan \
  --tag v0.8.0-alpha.1 \
  --directory "$HOME/.cache/solco-release-verification-v0.8.0-alpha.1" \
  --public-key /path/to/tagged-source/assets/update-public-key.hex \
  --manifest "$HOME/.cache/solco-release-retirement-v0.8.0-alpha.1.json"
```

The printed JSON lists all proposed removals. The download directory must be
new or carry this verifier's matching ownership marker; existing unrelated
folders and symlinks are rejected. Existing plan files are never overwritten.
After reviewing the concrete inventory, run the same command with `apply` in
place of `plan`. It verifies the plan again before deleting anything. Keep the
plan and workflow results, then remove the verification downloads to reclaim
space.

For the first use on 2026-10-05, the approved scope after verifying
`v0.8.0-alpha.1` is public release `v0.7.0-alpha.1` (release ID `402724739`) and
its 12 assets. All tags remain. The private repository has no GitHub releases;
its pinned model source commit remains untouched.

## Release checklist

- Build from the reviewed private source tag reachable from its default branch.
- Check the workflow's complete, signed download set and published notes/media.
- Review the saved retirement inventory and confirm only intended older
  application releases disappeared. Confirm all Git tags remain.
- Do not run intentional failure QA against official release binaries with
  network access enabled. QA builds must omit `SOLCO_OFFICIAL_RELEASE=1` so
  local validation cannot send production error reports. Download verification
  only reads bytes and does not start Solco.
- Record the published release URL and verification result before announcing it.
