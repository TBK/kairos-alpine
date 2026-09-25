# Kairos on Alpine

Builds [Kairos](https://kairos.io) images (immutable Alpine) and installer ISOs
for amd64, arm64 and riscv64 (experimental), as a *core* variant (no Kubernetes)
and *standard* variants with k3s or k0s (amd64 and arm64).

| Component   | Version |
|-------------|---------|
| Alpine      | 3.24    |
| kairos-init | v0.17.3 |
| AuroraBoot  | v0.27.1 |
| shim        | 16.1    |

## Pre-built images

Releases follow Kairos: release `vX.Y.Z` is built with the same kairos-init,
and so the same Kairos components, as the upstream Kairos release `vX.Y.Z`.
Each release publishes:

- **ISOs** on the GitHub release: `kairos-alpine-<tag>.iso`, plus
  `kairos-alpine-sb-enroll.iso` for Secure Boot
- **Images** on GHCR: `ghcr.io/<owner>/kairos-alpine:<tag>`

Tag scheme (same as upstream Kairos):

| Variant  | Per-arch tag                                   | Multi-arch tag                           |
|----------|------------------------------------------------|------------------------------------------|
| core     | `3.24-core-amd64-generic-v4.3.0`               | `3.24-core-generic-v4.3.0`               |
| standard | `3.24-standard-arm64-generic-v4.3.0-k3s`       | `3.24-standard-generic-v4.3.0-k3s`       |
| standard | `3.24-standard-amd64-generic-v4.3.0-k0s`       | `3.24-standard-generic-v4.3.0-k0s`       |

### Automation

| Workflow | When | What |
|----------|------|------|
| `build.yml` | PRs, `main` | Builds every combination and runs VM install tests on amd64: one under Secure Boot, and on the standard variants until the Kubernetes node is Ready. Nothing is published. |
| `build.yml` | tag `vX.Y.Z` | A release. Checks that Kairos `vX.Y.Z` pins our kairos-init, then builds and tests. Publishes only if everything passed; the experimental riscv64 build is left out if it failed. |
| `follow-kairos.yml` | daily | On a new Kairos release: bumps `KAIROS_INIT` on `main`, tags the version and starts the release build. |
| `alpine-updates.yml` | daily | If the latest release's image has Alpine package updates, rebuilds that release and re-publishes it under the same tag. |

Notes:

- **Rebuilds keep the version number**, because Kairos versions leave no room
  for our own revisions. Servers get a rebuild with an explicit
  `kairos-agent upgrade --source oci:<image>`. The release notes list each
  rebuild date.
- **Failed release builds** stay tagged without a GitHub release, and you get
  GitHub's failure email. Push a fix to `main`; the next `follow-kairos` run
  moves the unreleased tag to it and retries. You can also run the workflow by
  hand from the Actions tab.
- **Releasing by hand:** `git tag v4.3.0 && git push origin v4.3.0`.
- **The GHCR package starts out private.** Make `kairos-alpine` public once,
  after the first release.

## Build locally

Needs podman. Rootless works.

    ./build.sh                                   # core, host arch
    VARIANT=standard ./build.sh                  # with k3s
    VARIANT=standard K8S_PROVIDER=k0s ./build.sh # with k0s
    ARCH=arm64 ./build.sh                        # cross-build (needs qemu-user-static)
    VERSION=1.0.1 ./build.sh                     # bump for every build you upgrade to
    K8S_VERSION=v1.35.0+k3s1 VARIANT=standard ./build.sh   # pin k3s
    CLOUD_CONFIG=cloud-config.yaml ./build.sh    # embed a config (unattended install)
    FIRMWARE=full ./build.sh                     # all firmware (tag suffix -fw-full)

Output is `build/kairos-alpine-<tag>.iso`. Add packages with `RUN apk add ...`
in the `Dockerfile`.

**Firmware:** Linux firmware is most of an image, so by default (and in
releases) only server firmware is included: network cards, storage
controllers, server VGA and AMD CPUs, about 150 MB. GPU, Wi-Fi/Bluetooth,
phone/SoC and switch-ASIC firmware is left out. Check your hardware against the
list in the `Dockerfile`: a network card without its firmware means no network.
`FIRMWARE=full` includes all firmware (~780 MB) for machines that need
something outside that list. In both cases GPU drivers are left out of the
initramfs; they load from the root filesystem.

## Install on a server

1. For Secure Boot, enroll the keys first (see below). Otherwise turn Secure
   Boot off.
2. Write the ISO to a USB stick: `sudo dd if=<iso> of=/dev/sdX bs=4M oflag=sync status=progress`
3. Boot from it in UEFI mode.
4. Either use the web installer at `http://<ip>:8080`, or log in on the console
   (`kairos`/`kairos`) and run `sudo kairos-agent manual-install cloud-config.yaml`.
   See `cloud-config.example.yaml`.
5. Remove the stick when it's done. The installer doesn't change the firmware
   boot order.

Upgrade: `sudo kairos-agent upgrade --source oci:ghcr.io/<owner>/kairos-alpine:<tag>`.

## Secure Boot

Release images for amd64 and arm64 are signed. The chain is the one mainstream
distributions use:

    firmware --(db)--> shim --(vendor cert)--> GRUB --(shim)--> kernel

Alpine has no shim, and a Microsoft-signed one isn't an option. So the images
carry their own shim (built from source, with the project's db certificate
built in), and the machine must trust the project's keys. Microsoft's
certificates can be kept alongside them.

**Enrolling the keys** (once per machine, before installing):

1. In the firmware setup, clear the Secure Boot keys. This is usually called
   "Reset to Setup Mode", "Clear Secure Boot keys" or "Delete all Secure Boot
   variables".
2. Boot `kairos-alpine-sb-enroll.iso` from the release (CD or USB, UEFI x64 or
   ARM64). It shows the firmware's Secure Boot state and asks two questions:
   - *Trust Microsoft certificates?* Answer **yes** unless you know the machine
     has no add-in cards (GPU, NIC, RAID/HBA). Their firmware is signed by
     Microsoft, and without it they stop working under Secure Boot. Yes also
     installs Microsoft's revocation list (dbx).
   - *Enroll now?* Writes db, dbx, KEK and finally PK. If anything fails
     before PK, the machine stays in Setup Mode and nothing is lost.
3. Reboot. Some firmware also needs Secure Boot switched on in its setup; the
   tool can reboot straight into it.

Scope: this verifies the boot loaders and the kernel. It does not verify the
initramfs or the OS image on disk, so it isn't Kairos "Trusted Boot" (UKI +
measured boot). Kairos supports that only on systemd distributions.

### Maintainer: keys and signing

    secureboot/genkeys.sh

This creates the PK/KEK/db hierarchy:

| Path | What | Where it goes |
|------|------|---------------|
| `secureboot/certs/` | certificates | commit |
| `secureboot/auth/` | signed variable updates for the enrollment tool | commit |
| `secureboot/private/db.key` | signing key | GitHub secret `SB_DB_KEY` |
| `secureboot/private/{PK,KEK}.key` | key hierarchy | offline storage, not in CI |

`secureboot/private/` is git-ignored.

- Tag builds fail unless the certificates are committed and `SB_DB_KEY` is set.
  Other builds without the secret (e.g. PRs from forks) come out unsigned.
- Local signed build: `SB_DB_KEY_FILE=secureboot/private/db.key ./build.sh`.
  The enrollment ISO: `SB_DB_KEY_FILE=... secureboot/build-enroll-iso.sh`.
- Replacing the db key means rebuilding shim, so machines need the new keys
  enrolled again.
- riscv64 images are never signed, because shim doesn't support riscv64.

## Alpine-specific fixes

Upstream Kairos stopped publishing Alpine images after v3.7.2, and a stock
kairos-init Alpine image has several problems. The `Dockerfile` fixes them:

- **Installing fails** with *could not find any grub efi file to copy*, because
  Alpine's `grub-efi` ships no prebuilt GRUB EFI binary. A standalone GRUB is
  built with `grub-mkimage` and put, together with shim, at
  `/usr/share/efi/<arch>/{grub,shim}.efi`, where kairos-agent and AuroraBoot
  look.
- **Every machine is called `kairos-`**, an invalid Kubernetes node name. The
  hostname is derived from the machine ID before OpenRC systems have one.
  `files/system/oem/32_openrc-hostname.yaml` creates the machine ID first, and
  repairs machines already installed with that hostname.
- **k0s never starts.** Kairos's OpenRC support only knows k3s. The k0s variant
  rebuilds provider-kairos with `patches/kairos-sdk-openrc-k0s.patch`, and its
  init scripts take the arguments and environment from Kairos's config. Set
  `k0s.args: [--single]` for a single-node cluster. `follow-kairos` keeps the
  rebuilt provider version (`PROVIDER_KAIROS`) in step with kairos-init. When a
  kairos-sdk release fixes this upstream, the patch stops applying and the
  build fails; then drop it.
- **riscv64 builds fail**, because kairos-init installs VMware tools Alpine
  doesn't build for riscv64. They're satisfied with empty placeholder packages.
- **The initramfs carries all GPU drivers and firmware** (mkinitfs `kms`
  feature). It's rebuilt without them.

Some GRUB errors appear at boot (`hiddenentry`, `grubenv`, `unicode.pf2`,
`rmmod`). They're harmless.

## Test in a VM (x86_64, KVM)

    CLOUD_CONFIG=test/cloud-config.yaml ISO_NAME=autoinstall-test ./build.sh
    test/e2e.sh build/autoinstall-test.iso core    # install, boot from disk, check over SSH

With Secure Boot, using throwaway keys:

    secureboot/genkeys.sh test/work/sb
    SB_CERTS=test/work/sb/certs SB_DB_KEY_FILE=test/work/sb/private/db.key \
      CLOUD_CONFIG=test/cloud-config.yaml ISO_NAME=autoinstall-sb ./build.sh
    SB_DB_KEY_FILE=test/work/sb/private/db.key ISO_NAME=sb-enroll-test \
      secureboot/build-enroll-iso.sh test/work/sb
    test/e2e.sh build/autoinstall-sb.iso core build/sb-enroll-test.iso

Or step by step: `test/vm.sh install <iso>` (powers off when done), then
`test/vm.sh disk` and `ssh -p 2222 kairos@localhost` (password `kairos`).
