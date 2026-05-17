#!/usr/bin/env bash
set -euo pipefail

CA="${CA:-/tmp/lab-ca.crt}"
SKIP_CA_CHECK="${SKIP_CA_CHECK:-0}"

FRONT_URL="${FRONT_URL:-https://front.192.168.10.51.nip.io}"
READER_URL="${READER_URL:-https://reader.192.168.10.51.nip.io}"
WAIT_SECONDS="${WAIT_SECONDS:-15}"

CURL_OPTS=()
if [[ "${SKIP_CA_CHECK}" != "1" ]]; then
  if [[ ! -f "${CA}" ]]; then
    echo "Lab CA not found at ${CA}. Extract it first:" >&2
    echo "  kubectl -n cert-manager get secret lab-ca-secret \\" >&2
    echo "    -o 'jsonpath={.data.ca\\.crt}' | base64 -d > ${CA}" >&2
    exit 1
  fi
  CURL_OPTS+=(--cacert "${CA}")
fi

MSG="smoke-$(date +%s)-$$"

echo "==> POST to ${FRONT_URL}/api/v1/command"
echo "    message=${MSG}"
http_code=$(curl -sS "${CURL_OPTS[@]}" -o /tmp/front-resp -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  -d "{\"message\":\"${MSG}\",\"loadFront\":1,\"loadBack\":1}" \
  "${FRONT_URL}/api/v1/command")

if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
  echo "FAIL: front POST returned HTTP ${http_code}"
  cat /tmp/front-resp 2>/dev/null
  exit 1
fi
echo "    OK (HTTP ${http_code})"

echo "==> Waiting ${WAIT_SECONDS}s for pipeline: front → kafka → back → postgres"
sleep "${WAIT_SECONDS}"

echo "==> GET ${READER_URL}/api/v1/testEntity?size=100"
result=$(curl -fsS "${CURL_OPTS[@]}" "${READER_URL}/api/v1/testEntity?size=100")

found=$(echo "${result}" | jq --arg m "${MSG}" '.content[]? | select(.message == $m)' 2>/dev/null || true)
if [[ -z "${found}" ]]; then
  echo
  echo "FAIL: message '${MSG}' not found in reader response"
  echo "First few entries reader returned:"
  echo "${result}" | jq '.content[:5]' 2>/dev/null || echo "${result}"
  exit 1
fi

echo
echo "PASS: end-to-end pipeline working"
echo "Found entry:"
echo "${found}" | jq
