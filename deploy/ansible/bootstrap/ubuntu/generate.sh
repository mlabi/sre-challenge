#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/labi_lab_ed25519.pub}"

if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  echo "SSH public key not found: ${SSH_KEY_PATH}" >&2
  echo "Run bootstrap/00-generate-ssh-key.sh first." >&2
  exit 1
fi

SSH_PUBKEY="$(cat "${SSH_KEY_PATH}")"

render() {
  local hostname="$1"
  local outdir="${SCRIPT_DIR}/dist/${hostname}"
  mkdir -p "${outdir}"
  sed -e "s|@HOSTNAME@|${hostname}|g" \
      -e "s|@SSH_PUBKEY@|${SSH_PUBKEY}|g" \
      "${SCRIPT_DIR}/user-data.tpl" > "${outdir}/user-data"
  cp "${SCRIPT_DIR}/meta-data" "${outdir}/meta-data"
  echo "Rendered: ${outdir}/{user-data,meta-data}"
}

render "box-1"
render "box-2"
render "box-3"

cat <<EOF

Done. Next steps:
  1. Flash Ubuntu Server 26.04 ISO to a USB stick (e.g. via Etcher or
     'sudo dd if=ubuntu-26.04-live-server-amd64.iso of=/dev/diskN bs=4M').
  2. Format a second USB stick FAT32 with volume label CIDATA.
  3. Copy dist/box-N/user-data and dist/box-N/meta-data to that stick.
  4. Plug both USBs into the target box, boot from Ubuntu USB. Autoinstall runs.
  5. Repeat for each remaining box using its dist/box-N/* on a fresh CIDATA stick.
EOF
