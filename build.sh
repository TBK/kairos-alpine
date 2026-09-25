#!/usr/bin/env bash
# Build a Kairos Alpine OCI image and a bootable ISO with podman (rootless works).
#
# Env:
#   VERSION         semver of the OS image (bump for upgrades)          [1.0.0]
#   ALPINE_VERSION  Alpine base tag                                     [3.24]
#   ARCH            amd64 | arm64 | riscv64 (non-native needs qemu-user) [host]
#   VARIANT         core | standard (standard = with Kubernetes)        [core]
#   K8S_PROVIDER    k3s | k0s, used by the standard variant             [k3s]
#   K8S_VERSION     pin the Kubernetes version (empty = provider default)
#   FIRMWARE        server | full (see Dockerfile)                   [server]
#   IMAGE_REPO      image repository                  [localhost/kairos-alpine]
#   CLOUD_CONFIG    cloud-config file to embed in the ISO (optional)
#   ISO_NAME        output ISO name without .iso          [derived from tag]
#   SKIP_ISO=1      only build the image
#   SB_DB_KEY_FILE  Secure Boot db key: sign shim, GRUB and kernel (see secureboot/)
#   SB_CERTS        directory with db.der/db.crt       [secureboot/certs]
#
# Prints the image reference as the last line of stdout.
set -euo pipefail
cd "$(dirname "$0")"

# Run in podman's user namespace when rootless; directly when root.
as_ns() { if [[ $(id -u) == 0 ]]; then "$@"; else podman unshare "$@"; fi; }

host_arch() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;; aarch64) echo arm64 ;; riscv64) echo riscv64 ;;
    *) uname -m ;;
  esac
}

VERSION="${VERSION:-1.0.0}"
ALPINE_VERSION="${ALPINE_VERSION:-3.24}"
ARCH="${ARCH:-$(host_arch)}"
VARIANT="${VARIANT:-core}"
K8S_PROVIDER="${K8S_PROVIDER:-k3s}"
K8S_VERSION="${K8S_VERSION:-}"
FIRMWARE="${FIRMWARE:-server}"
IMAGE_REPO="${IMAGE_REPO:-localhost/kairos-alpine}"
AURORABOOT="${AURORABOOT:-quay.io/kairos/auroraboot:v0.27.1}"

# Same scheme as upstream Kairos images, e.g.
#   3.24-core-amd64-generic-v1.0.0
#   3.24-standard-arm64-generic-v1.0.0-k3s
case "$VARIANT" in
  core)     provider="";              suffix="" ;;
  standard) provider="$K8S_PROVIDER"; suffix="-${K8S_PROVIDER}${K8S_VERSION:+-${K8S_VERSION//+/-}}" ;;
  *) echo "VARIANT must be core or standard" >&2; exit 1 ;;
esac
# Non-default firmware sets get their own tag, e.g. ...-v4.3.0-fw-full
[[ $FIRMWARE == server ]] || suffix="${suffix}-fw-${FIRMWARE}"
TAG="${ALPINE_VERSION}-${VARIANT}-${ARCH}-generic-v${VERSION}${suffix}"
IMAGE="${IMAGE_REPO}:${TAG}"
ISO_NAME="${ISO_NAME:-kairos-alpine-${TAG}}"
ROOTFS="build/rootfs-${TAG}"

# Signing: the key goes in as a build secret; its fingerprint as a build arg so
# signed and unsigned builds never share cached layers.
secret=()
signer=unsigned
if [[ -n ${SB_DB_KEY_FILE:-} ]]; then
  secret=(--secret "id=sb_db_key,src=$SB_DB_KEY_FILE")
  signer=$(openssl pkey -in "$SB_DB_KEY_FILE" -pubout | sha256sum | cut -c1-16)
fi

podman build --platform "linux/${ARCH}" "${secret[@]}" \
  --build-arg VERSION="$VERSION" \
  --build-arg ALPINE_VERSION="$ALPINE_VERSION" \
  --build-arg K8S_PROVIDER="$provider" \
  --build-arg K8S_VERSION="$K8S_VERSION" \
  --build-arg FIRMWARE="$FIRMWARE" \
  --build-arg SB_CERTS="${SB_CERTS:-secureboot/certs}" \
  --build-arg SB_SIGNER="$signer" \
  -t "$IMAGE" . >&2

if [[ -z "${SKIP_ISO:-}" ]]; then
  mkdir -p build
  as_ns rm -rf "$ROOTFS"
  mkdir "$ROOTFS"
  # Flatten the image into a rootfs dir. Extract inside podman's user namespace
  # so root ownership and setuid bits survive (sudo etc. break otherwise).
  ctr=$(podman create --platform "linux/${ARCH}" "$IMAGE" /bin/true)
  trap 'podman rm -f "$ctr" >/dev/null 2>&1 || true; as_ns rm -rf "$ROOTFS"' EXIT
  podman export "$ctr" | as_ns tar --numeric-owner -xpf - -C "$ROOTFS"

  cc_args=()
  if [[ -n "${CLOUD_CONFIG:-}" ]]; then
    cp "$CLOUD_CONFIG" "build/cloud-config-${TAG}.yaml"
    cc_args=(--cloud-config "/output/cloud-config-${TAG}.yaml")
  fi

  # AuroraBoot runs natively; --arch selects the target architecture.
  podman run --rm --privileged \
    -v "$PWD/build:/output:z" \
    "$AURORABOOT" build-iso --arch "$ARCH" --override-name "$ISO_NAME" "${cc_args[@]}" \
    --output /output/ "dir:/output/rootfs-${TAG}" >&2
  rm -f "build/cloud-config-${TAG}.yaml"
  ls -lh "build/${ISO_NAME}.iso" >&2
fi

echo "$IMAGE"
