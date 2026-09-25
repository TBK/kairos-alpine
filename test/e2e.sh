#!/usr/bin/env bash
# End-to-end test: unattended install from an ISO built with test/cloud-config.yaml,
# then boot the installed disk and check the system over SSH.
#   test/e2e.sh <autoinstall-iso> [core|standard] [enroll-iso]
#
# With an enrollment ISO (secureboot/build-enroll-iso.sh) the whole run is under
# Secure Boot: enroll the keys in a Setup Mode firmware first, then install and
# boot with Secure Boot enforcing. The autoinstall ISO must be signed with the
# same keys.
set -euo pipefail
ISO=$1
VARIANT=${2:-core}
ENROLL_ISO=${3:-}
here="$(cd "$(dirname "$0")" && pwd)"
work="$here/work"
mkdir -p "$work"

fail() {
  echo "FAIL: $*" >&2
  echo "--- serial console (tail) ---" >&2
  tr -d '\r' < "$work/serial.log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | tail -60 >&2 || true
  exit 1
}

if [[ -n $ENROLL_ISO ]]; then
  export SB=1
  echo "== enroll Secure Boot keys"
  SERIAL_SOCK="$work/serial.sock" "$here/vm.sh" enroll "$ENROLL_ISO" &
  vm=$!
  python3 "$here/serial-expect.py" "$work/serial.sock" 120 \
    'Trust Microsoft certificates?=>y' 'Enroll now?=>y' 'quit to the firmware boot menu=>s' >/dev/null \
    || { kill $vm 2>/dev/null; fail "enrollment dialog"; }
  wait $vm || true
  grep -aq 'PK <- PK.auth: ok' "$work/serial.log" || fail "enrollment failed"
  ! grep -aq 'FAILED' "$work/serial.log" || fail "enrollment reported a failure"
fi

echo "== install (VM powers off when done)"
timeout 1200 "$here/vm.sh" install "$ISO" || fail "install VM did not power off in time"
grep -aq 'reboot: Power down' "$work/serial.log" || fail "install did not finish with power down"
if [[ -n $ENROLL_ISO ]]; then
  grep -aq 'Secure boot enabled' "$work/serial.log" || fail "installer did not run under Secure Boot"
fi

echo "== boot installed disk"
"$here/vm.sh" disk &
vm=$!
trap 'kill $vm 2>/dev/null || true' EXIT

# Password SSH without sshpass
cat > "$work/askpass" <<'EOF'
#!/bin/sh
echo kairos
EOF
chmod +x "$work/askpass"
vssh() {
  SSH_ASKPASS="$work/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=x setsid -w \
    ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=5 -o PubkeyAuthentication=no \
    -o IdentityAgent=none -o PreferredAuthentications=password,keyboard-interactive \
    kairos@127.0.0.1 "$@" < /dev/null
}

for _ in $(seq 1 60); do
  vssh true 2>/dev/null && break
  kill -0 $vm 2>/dev/null || fail "VM exited while booting from disk"
  sleep 5
done
vssh true || fail "no SSH on installed system"

boot=$(vssh 'sudo kairos-agent state get boot')
echo "boot state: $boot"
[[ $boot == active_boot ]] || fail "expected active_boot, got '$boot'"
vssh 'cat /etc/kairos-release'
if [[ $VARIANT == standard ]]; then
  # The ISO must enable it (test/cloud-config-k3s.yaml / -k0s.yaml)
  k8s=$(vssh 'basename "$(command -v k3s || command -v k0s)"') || fail "no kubernetes binary in standard image"
  echo "waiting for the $k8s node to be Ready"
  nodes=""
  for _ in $(seq 1 60); do
    nodes=$(vssh "sudo $k8s kubectl get nodes --no-headers 2>&1") || true
    grep -q ' Ready ' <<< "$nodes" && break
    sleep 10
  done
  echo "$nodes"
  grep -q ' Ready ' <<< "$nodes" || fail "$k8s node not Ready after 10 minutes"
fi
if [[ -n $ENROLL_ISO ]]; then
  # Last byte of the SecureBoot EFI variable: 1 = enforcing
  sb=$(vssh 'od -An -tu1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c | awk "{print \$NF}"')
  echo "SecureBoot variable: $sb"
  [[ $sb == 1 ]] || fail "Secure Boot not enabled on the installed system"
fi
echo "PASS"
