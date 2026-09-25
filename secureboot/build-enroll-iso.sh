#!/usr/bin/env bash
# Build the standalone Secure Boot enrollment ISO (UEFI x64 + aa64, USB-bootable).
#
#   secureboot/build-enroll-iso.sh [KEYDIR]       default KEYDIR: secureboot/
#
# KEYDIR/auth/*.auth come from genkeys.sh. Output: build/kairos-alpine-sb-enroll.iso
#
# Env: SB_DB_KEY_FILE  sign the tool with this key (cert: KEYDIR/certs/db.crt)
#      ISO_NAME        output name without .iso      [kairos-alpine-sb-enroll]
#      ENROLL_ARCHES   architectures to include       [amd64 arm64]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
keydir="$(cd "${1:-$root/secureboot}" && pwd)"
name="${ISO_NAME:-kairos-alpine-sb-enroll}"
arches="${ENROLL_ARCHES:-amd64 arm64}"

# Microsoft revocation lists (signed by Microsoft's KEK), same pinned revision as genkeys.sh
MS_REV=f75f97f6da5ca70ac23c7daf12cac069131601aa
MS_DBX="https://raw.githubusercontent.com/microsoft/secureboot_objects/$MS_REV/PostSignedObjects/DBX"

for f in PK KEK KEK-ms db db-ms; do
  [[ -f $keydir/auth/$f.auth ]] || { echo "missing $keydir/auth/$f.auth (run genkeys.sh)" >&2; exit 1; }
done

work="$root/build/sb-enroll"
rm -rf "$work"; mkdir -p "$work/efi/EFI/BOOT" "$work/efi/EFI/sbkeys" "$work/iso"
cp "$keydir"/auth/{PK,KEK,KEK-ms,db,db-ms}.auth "$work/efi/EFI/sbkeys/"

for arch in $arches; do
  case $arch in
    amd64) boot=BOOTX64.EFI;  sfx=x64;  dbx=amd64 ;;
    arm64) boot=BOOTAA64.EFI; sfx=aa64; dbx=arm64 ;;
    *) echo "unsupported arch $arch" >&2; exit 1 ;;
  esac
  podman build -q --platform "linux/$arch" -o "type=local,dest=$work/tool-$arch" "$root/secureboot/enroll" >/dev/null
  cp "$work/tool-$arch/sb-enroll.efi" "$work/efi/EFI/BOOT/$boot"
  curl -fsSL "$MS_DBX/$dbx/DBXUpdate.bin" -o "$work/efi/EFI/sbkeys/dbx-$sfx.auth"
done

cat > "$work/iso/README.TXT" <<'EOF'
Kairos Alpine - Secure Boot key enrollment

Boot this medium in UEFI mode with the firmware in Setup Mode (Secure Boot
keys cleared). The tool enrolls the Kairos Alpine signing keys, optionally
together with Microsoft's UEFI certificates.
EOF

sign=""
if [[ -n ${SB_DB_KEY_FILE:-} ]]; then
  cp "$SB_DB_KEY_FILE" "$work/db.key"
  cp "$keydir/certs/db.crt" "$work/db.crt"
  sign=1
fi

# Sign (optional), then pack the EFI system partition image and the hybrid ISO.
podman run --rm --arch "$(uname -m | sed "s/x86_64/amd64/;s/aarch64/arm64/")" -e SIGN="$sign" -v "$work:/w:z" docker.io/library/alpine:3.24 sh -euc '
  apk add -q xorriso mtools dosfstools sbsigntool >/dev/null
  if [ -n "$SIGN" ]; then
    for f in /w/efi/EFI/BOOT/*.EFI; do
      sbsign --key /w/db.key --cert /w/db.crt --output "$f" "$f" 2>/dev/null
    done
    rm -f /w/db.key
  fi
  mkfs.vfat -C -n SB_ENROLL /w/efi.img 4096 >/dev/null
  mcopy -s -i /w/efi.img /w/efi/EFI ::/
  xorriso -as mkisofs -quiet -iso-level 3 -V SB_ENROLL -o /w/out.iso \
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B /w/efi.img \
    -appended_part_as_gpt -e --interval:appended_partition_2:all:: -no-emul-boot \
    /w/iso
'
mv "$work/out.iso" "$root/build/$name.iso"
(cd "$root/build" && sha256sum "$name.iso" > "$name.iso.sha256")
rm -rf "$work"
ls -lh "$root/build/$name.iso"
