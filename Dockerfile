# Kairos on Alpine Linux, generic model. Multi-arch: amd64, arm64.
# Kairos builds release vX.Y.Z with kairos-init vX.Y.Z, so this is the Kairos
# release we follow (follow-kairos.yml bumps it, build.yml checks it on tags).
ARG KAIROS_INIT=v4.5.2
ARG ALPINE_VERSION=3.24

FROM quay.io/kairos/kairos-init:${KAIROS_INIT} AS kairos-init

# shim with the project's db certificate built in as vendor certificate: the
# first stage boot loader for Secure Boot. Firmware verifies shim (db), shim
# verifies GRUB and GRUB asks shim to verify the kernel. Alpine has no shim
# package and ours can't be signed by Microsoft, so the machine needs the
# project keys enrolled (secureboot/). Skipped when there is no certificate
# yet.
FROM docker.io/library/alpine:${ALPINE_VERSION} AS shim
ARG TARGETARCH
ARG SHIM_VERSION=16.1
ARG SHIM_SHA256=46319cd228d8f2c06c744241c0f342412329a7c630436fce7f82cf6936b1d603
# Directory with db.der / db.crt (secureboot/genkeys.sh)
ARG SB_CERTS=secureboot/certs
COPY ${SB_CERTS}/ /out/certs/
RUN set -e; \
    if [ ! -f /out/certs/db.der ]; then \
        echo "not building shim"; exit 0; \
    fi; \
    apk add --no-cache build-base bash curl bzip2 elfutils-dev dos2unix openssl-dev perl util-linux-misc; \
    cd /tmp; \
    curl -fsSL -o shim.tar.bz2 "https://github.com/rhboot/shim/releases/download/${SHIM_VERSION}/shim-${SHIM_VERSION}.tar.bz2"; \
    echo "${SHIM_SHA256}  shim.tar.bz2" | sha256sum -c -; \
    tar xjf shim.tar.bz2; cd "shim-${SHIM_VERSION}"; \
    make -j"$(nproc)" VENDOR_CERT_FILE=/out/certs/db.der DEFAULT_LOADER='\\grub.efi'; \
    cp shim*.efi /out/; ls -l /out

FROM docker.io/library/alpine:${ALPINE_VERSION}
ARG TARGETARCH
# Semver; bump on every rebuild you intend to upgrade to
ARG VERSION=1.0.0
# Empty = core variant. "k3s" (or "k0s") = standard variant with that distro.
ARG K8S_PROVIDER=""
# Optional pinned provider version, e.g. v1.35.0+k3s1 (empty = provider default)
ARG K8S_VERSION=""
# SBAT generation of GRUB, see https://github.com/rhboot/shim/blob/main/SBAT.md
ARG GRUB_SBAT_GENERATION=5
# Fingerprint of the sb_db_key secret, or "unsigned". Build secrets are not
# part of the layer cache key, this is: signed and unsigned builds must never
# reuse each other's boot loader layer.
ARG SB_SIGNER=unsigned

# Firmware. The kernel package pulls in all of linux-firmware (~780 MB) unless
# something else provides linux-firmware-any first.
#   server  (default) network cards, storage controllers, server VGA, AMD CPU
#           (SEV, microcode). No GPU, Wi-Fi/Bluetooth (except what shares a
#           package with Intel NICs), phone/SoC or switch-ASIC firmware.
#   full    all firmware: boots on anything
ARG FIRMWARE=server
RUN set -e; \
    case "$FIRMWARE" in \
      full) ;; \
      server) \
        apk add --no-cache $(for f in 3com acenic adaptec advansys amd amd-ucode bnx2 bnx2x \
            cxgb3 cxgb4 e100 intel isci liquidio matrox myricom netronome qed qlogic \
            rtl_nic tigon vxge; do printf 'linux-firmware-%s ' "$f"; done) ;; \
      *) echo "FIRMWARE must be full or server"; exit 1 ;; \
    esac

# The base image must be the target architecture. Some podman versions have
# silently used another platform's image for a stage; fail instead.
RUN want=$(case "$TARGETARCH" in amd64) echo x86_64;; arm64) echo aarch64;; *) echo "$TARGETARCH";; esac); \
    have=$(apk --print-arch); \
    [ "$have" = "$want" ] || { echo "ERROR: building $TARGETARCH on a $have base image"; exit 1; }

# Extra packages you want on the server go here
# RUN apk add --no-cache htop

RUN --mount=type=bind,from=kairos-init,src=/kairos-init,dst=/kairos-init \
    set -e; args=""; \
    if [ -n "$K8S_PROVIDER" ]; then \
        args="-p $K8S_PROVIDER"; \
        [ -z "$K8S_VERSION" ] || args="$args --provider-$K8S_PROVIDER-version $K8S_VERSION"; \
    fi; \
    /kairos-init -m generic --version "${VERSION}" $args

# kairos-init builds Alpine's initramfs with mkinitfs and its "kms" feature,
# which packs every GPU driver and its firmware (~140 MB with full firmware)
# into it. Nothing needs them before the root filesystem is mounted: the
# kernel's built-in simpledrm/efifb keep the console, and GPU drivers still
# load from the root filesystem. Rebuild the initramfs without "kms".
RUN set -e; \
    . /etc/mkinitfs/mkinitfs.conf; \
    keep=$(for f in $features; do [ "$f" = kms ] || printf '%s ' "$f"; done); \
    sed -i "s|^features=.*|features=\"${keep% }\"|" /etc/mkinitfs/mkinitfs.conf; \
    grep '^features=' /etc/mkinitfs/mkinitfs.conf; \
    mkinitfs -o /boot/initrd "$(ls /lib/modules)"

# Fix the default hostname on OpenRC (see the file).
COPY files/system/oem/32_openrc-hostname.yaml /system/oem/

# Boot loader. Alpine's grub-efi ships only modules, no prebuilt GRUB EFI
# binary, so build a standalone one and put it where kairos-agent and
# AuroraBoot look (SUSE layout): shim.efi is copied to the removable-media
# path (bootx64.efi etc) and loads grub.efi next to it. Without shim, GRUB
# itself doubles as "shim.efi". Prefix is upper case so it matches both the
# ISO (iso9660) and the ESP (FAT).
#
# With the sb_db_key build secret, shim, GRUB and the kernel get signed for
# Secure Boot. GRUB embeds all modules it needs: under Secure Boot it may not
# load modules from disk.
RUN --mount=type=bind,from=shim,src=/out,dst=/shim \
    --mount=type=secret,id=sb_db_key,required=false \
    set -e; \
    case "$TARGETARCH" in \
      amd64)   fmt=x86_64-efi;  dir=x86_64 ;; \
      arm64)   fmt=arm64-efi;   dir=aarch64 ;; \
      *) echo "unsupported arch $TARGETARCH"; exit 1 ;; \
    esac; \
    d=/usr/lib/grub/$fmt; mods=""; \
    for m in part_gpt part_msdos fat ext2 iso9660 squash4 loopback normal \
             linux configfile search search_label search_fs_uuid search_fs_file \
             echo test regexp eval gzio xzio lzopio all_video efi_gop video_bochs \
             video_cirrus font gfxterm gfxmenu serial terminal loadenv chain \
             reboot halt true sleep minicmd cat ls probe keystatus smbios \
             lvm mdraid1x diskfilter; do \
        [ -f "$d/$m.mod" ] && mods="$mods $m"; \
    done; \
    grubver=$(apk info -e -v grub | sed 's/^grub-//'); \
    printf '%s\n' \
      'sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md' \
      "grub,${GRUB_SBAT_GENERATION},Free Software Foundation,grub,${grubver%-r*},https://www.gnu.org/software/grub/" \
      "grub.alpine,1,Alpine Linux,grub,${grubver},https://alpinelinux.org/" > /tmp/sbat.csv; \
    out=/usr/share/efi/$dir; mkdir -p "$out"; \
    grub-mkimage -O $fmt --sbat /tmp/sbat.csv -p /EFI/BOOT -o "$out/grub.efi" $mods; \
    shim=$(ls /shim/shim*.efi 2>/dev/null | grep -v -e mm -e fb | head -n1 || true); \
    if [ -n "$shim" ]; then cp "$shim" "$out/shim.efi"; else cp "$out/grub.efi" "$out/shim.efi"; fi; \
    rm -f /tmp/sbat.csv; \
    if [ "$SB_SIGNER" != unsigned ]; then \
        [ -f /run/secrets/sb_db_key ] || { echo "SB_SIGNER set but no sb_db_key secret"; exit 1; }; \
        [ -n "$shim" ] || { echo "sb_db_key given but no shim was built (missing certificate?)"; exit 1; }; \
        apk add --no-cache --virtual .sbsign sbsigntool; \
        for f in "$out/shim.efi" "$out/grub.efi" $(find /boot -maxdepth 1 -type f -name 'vmlinuz*'); do \
            sbsign --key /run/secrets/sb_db_key --cert /shim/certs/db.crt --output "$f" "$f"; \
            sbverify --cert /shim/certs/db.crt "$f"; \
        done; \
        apk del .sbsign; \
    fi
