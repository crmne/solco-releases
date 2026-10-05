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
The environment approval covers publication and retirement. Only that job has
`contents: write` and `actions: write`, the latter for deleting the narrowly
selected package artifacts. No additional secret or personal token is needed.

Before checking out private source or starting builds, preflight checks that no
newer published application version exists. Immediately before any release
creation, upload or edit, the same locked job repeats that check. New dispatches
for retired tags cannot rebuild public package artifacts or restore releases.
Drafts and unrelated tags do not block publication; rebuilding the current
version remains supported.

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

## Build package artifacts

GitHub Actions package artifacts are another download copy. Removing a release
does not remove them. After successful publication and the verification above,
`scripts/release_artifact_retention.rb plan` repeats signed-download and link
verification, then records exact artifact IDs, names, byte counts, digests,
timestamps and owning run metadata. Its `apply` repeats verification before
deleting only the recorded artifact IDs.

Eligible names are exactly the four historical targets
`x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`,
`x86_64-pc-windows-msvc`, `macos-arm64`; those names prefixed by `application-`;
and `native-packages-linux-amd64`, `native-packages-linux-arm64`,
`native-packages-windows-amd64`, `native-packages-macos-arm64`. Every artifact
must belong to this public repository's `.github/workflows/release.yml`, with
matching repository IDs and commit SHA. Similar names in another workflow or
repository are excluded.

Historical runs must be completed, regardless of success, failure or
cancellation, and both run and artifact must predate the verified publication.
Versioned run titles must identify the same or an older application version;
a completed build for a future unpublished version is preserved. The eight
legacy runs without version titles are limited to the exact reviewed run IDs
in the initial inventory. Other unversioned runs are preserved, never inferred
to be old from their timestamps.
The currently publishing run can additionally retire its own packages once
verification succeeds. That exception requires its actual `GITHUB_RUN_ID`,
repository and matching version title. Other active runs and artifacts created
after publication are preserved. The release objects for supported stable and
alpha channels remain available even when their redundant build artifacts go.

Before each deletion, the script checks the current release, artifact metadata
and run identity, status and attempt again. A newer release, changed artifact
or restarted run stops it. Newly discovered IDs are never silently added; a
changed final inventory requires a fresh plan. No workflow run, log, cache,
Git tag or private repository is deleted. Both `release-retirement-vVERSION`
and `package-artifact-retirement-vVERSION` audit artifacts remain available.
These public metadata records contain no model bytes or credentials.

Package uploads explicitly use one-day retention. Successful publication
removes them immediately after verification; failed builds or approval delays
leave them to expire. Approve within that retention window, or start a fresh
dispatch for the current version if its build inputs expired. The new artifact
retirement inventory is retained for 90 days.

Builds can overlap across versions. An older build admitted before a newer
publication can still upload artifacts afterward, but the locked publication
guard blocks its release and its one-day artifact retention bounds the extra
copy. For the initial cleanup, confirm no older release run is active and
recheck the repository artifact inventory afterward. API checks and deletions
are separate operations, so a concurrent external action can cause partial
cleanup; review a new plan rather than editing the saved one.

Do not use GitHub's **Re-run jobs** on workflow revisions predating these
guards. Re-runs retain the original workflow commit and do not acquire current
policy. Instead dispatch `release.yml` from current `main`, supplying both
`version` and `source_ref`. See GitHub's documentation on
[re-running workflows](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs)
and [artifact retention](https://github.com/actions/upload-artifact#retention-period).

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

The package-copy inventory is read-only and does not download or execute any
artifact. Its output is an inspection report, not an applicable deletion plan:

```sh
ruby scripts/release_artifact_retention.rb inventory
```

After the replacement downloads pass verification, use the same four
verification options with `release_artifact_retention.rb plan`, choosing a
separate manifest path. Review its exact IDs, then run `apply` with the same
options. Local maintenance omits `--publishing-run`; only the active publishing
workflow may include its own unfinished run. Never apply the initial package
cleanup before the new `v0.8.0-alpha.1` downloads are verified.

For the first use on 2026-10-05, the approved scope after verifying
`v0.8.0-alpha.1` is public release `v0.7.0-alpha.1` (release ID `402724739`) and
its 12 assets. All tags remain. The private repository has no GitHub releases;
its pinned model source commit remains untouched.

The accompanying read-only package inventory found **63 artifacts across 11
completed release runs, 9,119,836,426 bytes (8.49 GiB)**. Exact IDs and per-run
counts are in the [2026-10-05 inventory](release-artifact-inventory-2026-10-05.md).
This is a preparation record, not evidence that anything has been deleted.

## Release checklist

- Build from the reviewed private source tag reachable from its default branch.
- Check the workflow's complete, signed download set and published notes/media.
- Review the saved retirement inventory and confirm only intended older
  application releases disappeared. Confirm all Git tags remain.
- Review the package-artifact plan, confirm its listed IDs disappeared, and
  confirm audit manifests, workflow runs, logs and unrelated artifacts remain.
- Do not run intentional failure QA against official release binaries with
  network access enabled. QA builds must omit `SOLCO_OFFICIAL_RELEASE=1` so
  local validation cannot send production error reports. Download verification
  only reads bytes and does not start Solco.
- Record the published release URL and verification result before announcing it.
