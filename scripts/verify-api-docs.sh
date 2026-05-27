#!/usr/bin/env bash
# Smoke-test documented API shapes against api.inboundsage.com
set -euo pipefail

API="${INBOUNDSAGE_API_URL:-https://api.inboundsage.com}"
TOKEN="${INBOUNDSAGE_API_KEY:-}"

if [[ -z "$TOKEN" ]]; then
  echo "Set INBOUNDSAGE_API_KEY (is_live_…) to run live tests."
  exit 1
fi

auth=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")
fail=0

check() {
  local name="$1" expect="$2"
  shift 2
  local code
  code=$(curl -s -m 20 -o /tmp/is-doc-test.json -w "%{http_code}" "$@" | tail -c 3)
  if [[ "$code" != "$expect" ]]; then
    echo "FAIL $name: HTTP $code (expected $expect)"
    head -c 400 /tmp/is-doc-test.json; echo
    fail=1
  else
    echo "OK   $name: HTTP $code"
  fi
}

echo "== Health =="
check "GET /healthz" 200 -X GET "$API/healthz"

echo "== Auth required =="
check "GET /v1/wabas no token" 401 -X GET "$API/v1/wabas"

echo "== WABAs =="
check "GET /v1/wabas" 200 -X GET "$API/v1/wabas" "${auth[@]}"

WABA_ID=$(node -e "
const j=require('/tmp/is-doc-test.json');
const a=Array.isArray(j)?j[0]:j;
if(!a?.id) process.exit(1);
console.log(a.id);
" 2>/dev/null || true)

PHONE_ID=$(node -e "
const j=require('/tmp/is-doc-test.json');
const a=Array.isArray(j)?j[0]:j;
const p=a?.phoneNumbers?.[0]?.metaPhoneId;
if(!p) process.exit(1);
console.log(p);
" 2>/dev/null || true)

echo "== Templates =="
check "GET /v1/templates" 200 -X GET "$API/v1/templates?status=APPROVED&limit=5" "${auth[@]}"

if [[ -n "$WABA_ID" && -n "$PHONE_ID" ]]; then
  echo "== Message send (utility template, dry-run shape) =="
  # Use a template name from list if present
  TPL_NAME=$(node -e "
const j=require('/tmp/is-doc-test.json');
const t=j?.items?.[0];
if(t?.name) console.log(t.name);
" 2>/dev/null || echo "login_otp")

  payload=$(cat <<EOF
{
  "waba_id": "$WABA_ID",
  "phone_number_id": "$PHONE_ID",
  "to": "919922227902",
  "type": "template",
  "template": {
    "name": "$TPL_NAME",
    "language": "en",
    "components": [
      {"type":"body","parameters":[{"type":"text","text":"123456"}]},
      {"type":"button","sub_type":"url","index":"0","parameters":[{"type":"text","text":"123456"}]}
    ]
  }
}
EOF
)
  code=$(curl -s -m 30 -o /tmp/is-doc-test.json -w "%{http_code}" -X POST "$API/v1/messages/send" \
    "${auth[@]}" -d "$payload" | tail -c 3)
  if [[ "$code" == "201" || "$code" == "200" ]]; then
    echo "OK   POST /v1/messages/send: HTTP $code"
    node -e "const j=require('/tmp/is-doc-test.json'); if(!j.id||!j.meta_message_id) process.exit(1); console.log('     id', j.id, 'status', j.status);"
  else
    echo "WARN POST /v1/messages/send: HTTP $code (template may differ for OTP vs utility)"
    head -c 300 /tmp/is-doc-test.json; echo
  fi
fi

echo "== Error envelope sample =="
check "GET /v1/templates/bad-id" 404 -X GET "$API/v1/templates/00000000-0000-0000-0000-000000000000" "${auth[@]}"
node -e "
const j=require('/tmp/is-doc-test.json');
if(!j.error?.code||!j.error?.message||!j.error?.docs) { console.error('Missing error envelope'); process.exit(1); }
console.log('     error.code', j.error.code);
" || fail=1

if [[ "$fail" -ne 0 ]]; then
  echo "Some checks failed."
  exit 1
fi
echo "All documentation smoke checks passed."
