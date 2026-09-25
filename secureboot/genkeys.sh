#!/usr/bin/env bash
# Generate the Secure Boot key hierarchy and the signed variable updates
# (.auth files) that sb-enroll writes into the firmware.
#
#   secureboot/genkeys.sh [OUTDIR]        default OUTDIR: secureboot/
#
# Creates:
#   OUTDIR/certs/{PK,KEK,db}.{crt,der}, GUID   public, commit these
#   OUTDIR/auth/*.auth                         public, commit these
#     PK.auth                  platform key (self-signed)
#     KEK.auth / KEK-ms.auth   own KEK / own + Microsoft KEKs    (signed by PK)
#     db.auth  / db-ms.auth    own db  / own + Microsoft UEFI CAs (signed by KEK)
#   OUTDIR/private/{PK,KEK,db}.key             SECRET, never commit
#
# Only db.key is needed to sign releases: store it as the SB_DB_KEY GitHub
# secret. Keep PK.key and KEK.key offline. They are only needed to re-sign
# the .auth files, e.g. when adding new Microsoft certificates.
#
# Env: SB_NAME  common-name prefix of the certificates  [Kairos Alpine]
#      SB_DAYS  certificate validity                     [7300]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mkdir -p "${1:-$here}" && cd "${1:-$here}" && pwd)"
name="${SB_NAME:-Kairos Alpine}"
days="${SB_DAYS:-7300}"

# Microsoft certificates, from https://github.com/microsoft/secureboot_objects
MS_REV=f75f97f6da5ca70ac23c7daf12cac069131601aa
MS_BASE="https://raw.githubusercontent.com/microsoft/secureboot_objects/$MS_REV/PreSignedObjects"
MS_GUID=77fa9abd-0359-4d32-bd60-28f4e78f784b
MS_KEK=("KEK/Certificates/MicCorKEKCA2011_2011-06-24.der"
        "KEK/Certificates/microsoft corporation kek 2k ca 2023.der")
# Third-party UEFI CAs: option ROMs on add-in cards, shim/boot loaders of
# other distributions. Windows' own CAs are deliberately not included.
MS_DB=("DB/Certificates/MicCorUEFCA2011_2011-06-27.der"
       "DB/Certificates/microsoft uefi ca 2023.der"
       "DB/Certificates/microsoft option rom uefi ca 2023.der")

if [[ -e $out/private/PK.key ]]; then
  echo "refusing to overwrite existing keys in $out/private" >&2
  exit 1
fi

# The work needs openssl + efitools; run in an Alpine container unless present.
if ! command -v sign-efi-sig-list >/dev/null || ! command -v cert-to-efi-sig-list >/dev/null; then
  exec podman run --rm --arch "$(uname -m | sed "s/x86_64/amd64/;s/aarch64/arm64/")" \
    -e SB_NAME="$name" -e SB_DAYS="$days" -e OUT_DISPLAY="$out" \
    -v "$here:/sb:ro,z" -v "$out:/out:z" docker.io/library/alpine:3.24 \
    sh -c 'apk add -q bash openssl efitools curl >/dev/null && bash /sb/genkeys.sh /out'
fi
shown="${OUT_DISPLAY:-$out}"

mkdir -p "$out"/{certs,auth,private}
chmod 700 "$out/private"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

guid=$(cat /proc/sys/kernel/random/uuid)
echo "$guid" > "$out/certs/GUID"

for k in PK KEK db; do
  openssl req -new -x509 -newkey rsa:2048 -sha256 -nodes -days "$days" \
    -subj "/CN=$name $k/" -keyout "$out/private/$k.key" -out "$out/certs/$k.crt" 2>/dev/null
  openssl x509 -in "$out/certs/$k.crt" -outform DER -out "$out/certs/$k.der"
  cert-to-efi-sig-list -g "$guid" "$out/certs/$k.crt" "$tmp/$k.esl"
done

ms_esl() {  # ms_esl <out.esl> <paths...>
  local dst=$1; shift; : > "$dst"
  for p in "$@"; do
    curl -fsSL "$MS_BASE/${p// /%20}" -o "$tmp/ms.der"
    openssl x509 -inform DER -in "$tmp/ms.der" -out "$tmp/ms.crt"
    cert-to-efi-sig-list -g "$MS_GUID" "$tmp/ms.crt" "$tmp/one.esl"
    cat "$tmp/one.esl" >> "$dst"
  done
}
ms_esl "$tmp/ms-kek.esl" "${MS_KEK[@]}"
ms_esl "$tmp/ms-db.esl" "${MS_DB[@]}"
cat "$tmp/KEK.esl" "$tmp/ms-kek.esl" > "$tmp/KEK-ms.esl"
cat "$tmp/db.esl" "$tmp/ms-db.esl" > "$tmp/db-ms.esl"

sign() {  # sign <signer> <var> <esl> <auth>
  sign-efi-sig-list -g "$guid" -k "$out/private/$1.key" -c "$out/certs/$1.crt" "$2" "$3" "$4" >/dev/null
}
sign PK  PK  "$tmp/PK.esl"     "$out/auth/PK.auth"
sign PK  KEK "$tmp/KEK.esl"    "$out/auth/KEK.auth"
sign PK  KEK "$tmp/KEK-ms.esl" "$out/auth/KEK-ms.auth"
sign KEK db  "$tmp/db.esl"     "$out/auth/db.auth"
sign KEK db  "$tmp/db-ms.esl"  "$out/auth/db-ms.auth"

echo "Keys written to $shown (owner GUID $guid)"
echo "Private keys: $shown/private. Put db.key in the SB_DB_KEY secret, keep PK/KEK offline."
