#!/usr/bin/env bash
set -euo pipefail

KEY_PATH="${KEY_PATH:-${HOME}/.ssh/labi_lab_ed25519}"
KEY_COMMENT="${KEY_COMMENT:-labi-sre-lab-$(date +%Y%m%d)}"

if [[ -f "${KEY_PATH}" ]]; then
  echo "Key already exists at ${KEY_PATH} — skipping generation."
else
  ssh-keygen -t ed25519 -N "" -C "${KEY_COMMENT}" -f "${KEY_PATH}"
  echo "Generated: ${KEY_PATH}"
fi

echo
echo "Public key (to paste anywhere needed):"
cat "${KEY_PATH}.pub"
