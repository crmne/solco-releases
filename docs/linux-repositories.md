# Linux package repositories

Solco installs and updates through each Linux distribution's own package
manager. Every route installs the official release downloads unchanged, with
Solco's licence notice; nothing is rebuilt or repackaged.

| Route | What it serves | Where it lives |
| --- | --- | --- |
| apt (Debian 13+, Ubuntu 24.04+) | the release's `.deb` files | `linux/apt/` |
| dnf (Fedora 40+) | the release's `.rpm` files | `linux/rpm/` |
| AUR `solco-bin` (Arch) | the files of the release's `.deb` | [aur.archlinux.org/packages/solco-bin](https://aur.archlinux.org/packages/solco-bin) |
| Nix flake (NixOS, Nix) | the release's portable `.tar.gz` | `flake.nix`, `nix/` |

The install commands are in the [README](../README.md#linux).

## Channels

`beta` follows the newest published release, alpha or stable. `stable` follows
the newest stable release and appears in apt and dnf with the first one. The
AUR package and the flake follow `beta` while Solco is in private beta.

## How the repositories work

The apt and dnf repositories hold only signed metadata. The packages stay on
the GitHub releases, so a release adds a few kilobytes here, not 600 MB.

- apt fetches `https://github.com/crmne/solco-releases/raw/main/linux/apt/dists/<channel>/InRelease`
  (GitHub redirects `/raw/main/` to raw.githubusercontent.com). Each package's
  `Filename` is relative to that URL, `../../../../releases/download/<tag>/<file>`,
  which is the release download on the same host. `Acquire-By-Hash` lets a
  client holding a cached `InRelease` still find the indexes it names; the
  previous release's indexes are kept for that.
- dnf reads `linux/rpm/<channel>/repodata/`. Each package's `xml:base` is the
  release's download URL. `repo_gpgcheck=1` checks the signed `repomd.xml`,
  which carries each package's SHA-256. From the release after 1.0.0-alpha.1
  the release job also signs the RPMs with the same key, and the `.repo` file
  sets `gpgcheck=1`. A `.repo` downloaded earlier keeps `gpgcheck=0` until it
  is downloaded again; 1.0.0-alpha.1's RPMs are unsigned, so dnf prints
  "skipped OpenPGP checks" for them.
- `linux/state.json` records which release each channel serves, and the
  SHA-256 of every Linux download, so a run with nothing new does nothing.

Fedora's Copr and Ubuntu's PPAs only take free software, so Solco hosts its
own repositories. Debian 12 and Ubuntu 22.04 cannot install the package: it
needs glibc 2.39.

## Signing key

`linux/solco-packages.asc` (RSA 4096, no expiry) signs `InRelease`,
`Release.gpg`, `repomd.xml.asc` and the RPMs. Its fingerprint is
`61A8 5B1F 7706 63CC D1A9  D262 5DF3 0EBB 7D46 44E7`.

The private key and its revocation certificate are in 1Password ("Solco Linux
package repository signing key (2026-10-28)"). Workflows read it from the
`LINUX_REPOSITORY_SIGNING_KEY` secret, together with `AUR_SSH_KEY` and
`AUR_KNOWN_HOSTS`. All three are in the `release-signing` environment (the
release job, behind its approval) and in the `linux-repositories` environment
(the catch-up workflow), which only `main` may use.

To replace the key, commit the new public key to `linux/solco-packages.asc`,
update the secret, run the workflow with **force**, and tell users to fetch
their `.sources` or `.repo` file again: the `.sources` file carries the key
inline.

## Automation

The release job updates every repository right after it publishes a release
and before it removes older releases, so apt, dnf and the AUR never name a
deleted download. The steps live in `.github/actions/linux-repositories`;
the release job runs them from the published workflow revision, and a failure
stops the retirement of older releases.

`.github/workflows/linux-repositories.yml` runs the same steps when a release
build finishes, every six hours and by hand, to catch up after a failure. A
first job compares the releases with `linux/state.json` and the AUR's
version, without secrets. When something lags, the second job:

1. checks out the publisher key from the release's private source tag, as the
   release job does, and downloads each channel's `checksums.txt`, its
   signature and the `.deb` and `.rpm` files, refusing any that do not match;
2. writes and signs the apt and dnf metadata, the `.sources` and `.repo`
   files and `nix/release.json` (`scripts/linux_repositories.rb update`);
3. commits them to `main` through the GitHub API, so GitHub signs the commit,
   and stops if `main` moved meanwhile (the next run starts again);
4. renders `packaging/aur/solco-bin/PKGBUILD.erb`, writes `.SRCINFO` with
   `makepkg` in an Arch container and pushes both to the AUR. `pkgrel` goes up
   when only the recipe changes.

Versions are `MAJOR.MINOR.PATCH`, `-alpha.N` or `-beta.N`, ordered alpha <
beta < final: apt and dnf as `1.0.0~beta.1`, the AUR as `1.0.0beta.1`.

`scripts/test_linux_repositories.rb` covers the channel choice, signature and
checksum checks, metadata layout, pruning and the AUR versioning.

## Nix

`nix/package.nix` patches the portable archive with `autoPatchelfHook`. The
libraries Solco opens at run time (Vulkan, OpenGL, Wayland, X11, xkbcommon,
D-Bus) are in its run path. The flake allows only Solco as unfree, so
`nix run github:crmne/solco-releases` needs no `NIXPKGS_ALLOW_UNFREE`. The
overlay (`overlays.default`) leaves that to the user's configuration.

Graphics need the system's drivers: on NixOS this works as is. With Nix on
another distribution, the window may need a wrapper such as nixGL.

The polkit prompt for making a USB drive write quickly falls back to pkexec's
generic prompt, since the packaged policy names `/opt/solco/solco`.

### A nixpkgs package later

nixpkgs would need:

- downloads that stay available: nixpkgs pins a URL and hash, and release
  retention deletes a release's downloads when the next one is out. Keep the
  packaged version's downloads (for example, stop retiring stable releases),
  or mirror them somewhere permanent;
- a maintainer entry for Carmine in `maintainers/maintainer-list.nix`;
- `pkgs/by-name/so/solco/package.nix`, essentially `nix/package.nix` with
  `fetchurl` in place of `release.json`, `meta.license = lib.licenses.unfree`
  and `sourceProvenance = binaryNativeCode`, plus an update script;
- stable releases only: nixpkgs does not track private betas, and Hydra does
  not build unfree packages, so users build it from the download.
