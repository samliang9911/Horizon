#!/usr/bin/env bash
# Horizon push script — runs after Horizon completes, sends output to
# PushPlus (primary) and WeCom Bot (fallback).
# Usage: ./scripts/push.sh <burst|daily> [summary_zh.md] [summary_en.md]
set -euo pipefail

MODE="${1:-burst}"
ZH_FILE="${2:-}"
EN_FILE="${3:-}"

PUSHPLUS_TOKEN="${PUSHPLUS_TOKEN:-}"
WECOM_WEBHOOK="${WECOM_WEBHOOK:-}"

if [ -z "$PUSHPLUS_TOKEN" ] && [ -z "$WECOM_WEBHOOK" ]; then
  echo "[push] No PUSHPLUS_TOKEN or WECOM_WEBHOOK configured, skip."
  exit 0
fi

# --- Read content -----------------------------------------------------------
BODY=""
TITLE=""

if [ -n "$ZH_FILE" ] && [ -f "$ZH_FILE" ]; then
  # Extract the headline line (e.g. "# Horizon 每日速递 - 2026-11-03")
  TITLE="$(head -n 1 "$ZH_FILE" | sed 's/^# //' | cut -c1-64)"
  BODY="$(cat "$ZH_FILE")"
elif [ -n "$EN_FILE" ] && [ -f "$EN_FILE" ]; then
  TITLE="$(head -n 1 "$EN_FILE" | sed 's/^# //' | cut -c1-64)"
  BODY="$(cat "$EN_FILE")"
else
  echo "[push] No summary file found, skip."
  exit 0
fi

# --- Burst-mode empty guard -------------------------------------------------
if [ "$MODE" = "burst" ]; then
  # If the summary says "no items reached threshold", skip pushing entirely.
  if echo "$BODY" | grep -qiE "没有达到重要性阈值|no (important|significant|high)"; then
    echo "[push] Burst mode: no items ≥ threshold, skip."
    exit 0
  fi
fi

# --- Escape for enterprise WeCom markdown -----------------------------------
# WeCom bot markdown doesn't support full Markdown — convert to plain text
# with bullet points, strip heading hashes.
WECOM_BODY="$(echo "$BODY" \
  | sed 's/^###\? /\n**/; s/$/**/' \
  | sed 's/^> //g' \
  | sed 's/\*\*\{2,\}/\n/g' \
  | head -c 3900)"  # WeCom limit 4096

# --- PushPlus ---------------------------------------------------------------
if [ -n "$PUSHPLUS_TOKEN" ]; then
  echo "[push] Sending via PushPlus..."
  pp_resp=$(curl -fsS -G "http://www.pushplus.plus/send" \
    --data-urlencode "token=${PUSHPLUS_TOKEN}" \
    --data-urlencode "title=${TITLE}" \
    --data-urlencode "content=${BODY}" \
    --data-urlencode "template=html" \
    --data-urlencode "timestamp=$(date +%s)" 2>&1) || true
  pp_code=$(echo "$pp_resp" | python3 -c "import json,sys;print(json.loads(sys.stdin.read()).get('code','?'))" 2>/dev/null || echo "ERR")
  pp_msg=$(echo "$pp_resp" | python3 -c "import json,sys;print(json.loads(sys.stdin.read()).get('msg',''))" 2>/dev/null || echo "")
  echo "[push] PushPlus code=$pp_code msg=$pp_msg"
  if [ -n "$GITHUB_STEP_SUMMARY" ]; then
    echo "- PushPlus: code=$pp_code msg=$pp_msg" >> "$GITHUB_STEP_SUMMARY"
  fi
fi

# --- WeCom Bot (fallback) ---------------------------------------------------
if [ -n "$WECOM_WEBHOOK" ]; then
  echo "[push] Sending via WeCom bot..."
  WECOM_PAYLOAD="$(python3 -c "
import json
print(json.dumps({
  'msgtype': 'markdown',
  'markdown': {'content': '''## ${TITLE}
${WECOM_BODY}'''}
}))
")"
  wc_resp=$(curl -fsS -X POST "${WECOM_WEBHOOK}" \
    -H "Content-Type: application/json" \
    -d "${WECOM_PAYLOAD}" 2>&1) || true
  wc_code=$(echo "$wc_resp" | python3 -c "import json,sys;print(json.loads(sys.stdin.read()).get('errcode','?'))" 2>/dev/null || echo "ERR")
  wc_msg=$(echo "$wc_resp" | python3 -c "import json,sys;print(json.loads(sys.stdin.read()).get('errmsg',''))" 2>/dev/null || echo "")
  echo "[push] WeCom errcode=$wc_code errmsg=$wc_msg"
  if [ -n "$GITHUB_STEP_SUMMARY" ]; then
    echo "- WeCom: errcode=$wc_code errmsg=$wc_msg" >> "$GITHUB_STEP_SUMMARY"
  fi
fi

echo "[push] Done (${MODE})."
