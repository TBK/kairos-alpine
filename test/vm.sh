#!/usr/bin/env bash
# Headless UEFI QEMU VM (x86_64). SSH -> localhost:2222
#   test/vm.sh enroll <iso>    fresh firmware variables in Setup Mode, boot <iso> (SB=1 only)
#   test/vm.sh install <iso>   fresh 40G disk, boot the ISO (use an ISO with an auto-install config)
#   test/vm.sh disk            boot the installed disk only
#
# Env: SB=1         Secure Boot capable firmware. Variables persist between runs,
#                   so run "enroll" first to put the keys in.
#      SERIAL_SOCK  serial console on this unix socket (for test/serial-expect.py)
#                   instead of only the log. The log is always test/work/serial.log.
set -euo pipefail
mode=$1
[[ $mode == install || $mode == enroll ]] && ISO="$(realpath "$2")"
cd "$(dirname "$0")"; mkdir -p work; cd work

# OVMF location differs per distro (Fedora / Debian+Ubuntu). Secure Boot needs
# the 4M build: Microsoft's revocation list doesn't fit the 2M variable store.
if [[ -n ${SB:-} ]]; then
  pairs=(/usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.qcow2:/usr/share/edk2/ovmf/OVMF_VARS_4M.qcow2
         /usr/share/OVMF/OVMF_CODE_4M.secboot.fd:/usr/share/OVMF/OVMF_VARS_4M.fd)
  machine=(-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on)
else
  pairs=(/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd
         /usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd
         /usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd)
  machine=()
fi
for pair in "${pairs[@]}"; do
  [[ -f ${pair%%:*} ]] && { OVMF_CODE=${pair%%:*}; OVMF_VARS=${pair##*:}; break; }
done
[[ -n ${OVMF_CODE:-} ]] || { echo "OVMF firmware not found" >&2; exit 1; }
fmt() { [[ $1 == *.qcow2 ]] && echo qcow2 || echo raw; }
vars="vars${SB:+-sb}.$(fmt "$OVMF_VARS")"

fresh_vars() { cp "$OVMF_VARS" "$vars"; }
rm -f serial.log
args=()
case $mode in
  enroll)
    [[ -n ${SB:-} ]] || { echo "enroll needs SB=1" >&2; exit 1; }
    fresh_vars
    args=(-cdrom "$ISO") ;;
  install)
    [[ -n ${SB:-} ]] || fresh_vars
    [[ -f $vars ]] || { echo "no firmware variables, run enroll first" >&2; exit 1; }
    rm -f disk.qcow2
    qemu-img create -f qcow2 disk.qcow2 40G >/dev/null
    args=(-drive file=disk.qcow2,if=virtio -cdrom "$ISO") ;;
  disk)
    args=(-drive file=disk.qcow2,if=virtio) ;;
  *) echo "unknown mode $mode" >&2; exit 1 ;;
esac

if [[ -n ${SERIAL_SOCK:-} ]]; then
  rm -f "$SERIAL_SOCK"
  serial=(-chardev "socket,id=s0,path=$SERIAL_SOCK,server=on,wait=off,logfile=serial.log" -serial chardev:s0)
else
  serial=(-serial file:serial.log)
fi

exec qemu-system-x86_64 "${machine[@]}" -enable-kvm -m 4096 -smp 4 -cpu host \
  -drive if=pflash,format="$(fmt "$OVMF_CODE")",readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format="$(fmt "$OVMF_VARS")",file="$vars" \
  "${args[@]}" \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
  -display none "${serial[@]}"
