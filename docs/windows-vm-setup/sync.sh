#!/usr/bin/env bash
# Sync the cydo working tree (and optionally the ae library) onto the
# Windows dev VM via rsync over SSH.
#
# Defaults are tuned for the libvirt-managed VM brought up by the
# Vagrantfile in this directory. Override the IP via $CYDO_WINDEV_IP if
# the VM gets a different address (check `virsh net-dhcp-leases ...`).
#
# Usage:
#   ./sync.sh           # sync cydo + ae
#   ./sync.sh cydo      # sync only cydo
#   ./sync.sh ae        # sync only ae
#   CYDO_WINDEV_IP=192.168.121.42 ./sync.sh

set -euo pipefail

VM_IP="${CYDO_WINDEV_IP:-192.168.121.208}"
VM_USER="vagrant"
KEY_PATH="$(dirname "$(readlink -f "$0")")/agent_id_ed25519"
CYDO_SRC="$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)/"
AE_SRC="${AE_SRC:-$HOME/work/ae-container/ae/}"

if [[ ! -f "$KEY_PATH" ]]; then
    echo "Agent key not found at $KEY_PATH" >&2
    echo "Run \`vagrant up\` once to generate it." >&2
    exit 1
fi

# Target what was requested. Default: both.
TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    TARGETS=(cydo ae)
fi

# Linux -> Windows rsync caveats:
#  --no-perms --no-owner --no-group:  POSIX <-> NTFS ACL mismatch.
#  --filter=':- .gitignore':           apply each tree's gitignore as merge rule.
#  -e ssh ...:                         use the dedicated agent key.
RSYNC_OPTS=(
    -av
    --delete
    --no-perms --no-owner --no-group
    --filter=':- .gitignore'
    --exclude='.cydo/'
    --exclude='.vagrant/'
    --exclude='.direnv/'
    --exclude='result'
    --exclude='result-*'
    --exclude='build/'
    --exclude='web/dist/'
    --exclude='web/node_modules/'
    --exclude='tests/node_modules/'
    --exclude='data/'
    -e "ssh -i $KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
)

sync_cydo() {
    if [[ ! -d "$CYDO_SRC" ]]; then
        echo "cydo source not found at $CYDO_SRC" >&2
        return 1
    fi
    echo "==> Syncing cydo: $CYDO_SRC -> $VM_USER@$VM_IP:cydo/"
    rsync "${RSYNC_OPTS[@]}" "$CYDO_SRC" "$VM_USER@$VM_IP:cydo/"
}

sync_ae() {
    if [[ ! -d "$AE_SRC" ]]; then
        echo "ae source not found at $AE_SRC (set \$AE_SRC to override)" >&2
        return 1
    fi
    echo "==> Syncing ae: $AE_SRC -> $VM_USER@$VM_IP:ae/"
    rsync "${RSYNC_OPTS[@]}" "$AE_SRC" "$VM_USER@$VM_IP:ae/"
}

for t in "${TARGETS[@]}"; do
    case "$t" in
        cydo) sync_cydo ;;
        ae)   sync_ae ;;
        *)    echo "Unknown target: $t (expected: cydo, ae)" >&2; exit 1 ;;
    esac
done

echo "==> Done."
