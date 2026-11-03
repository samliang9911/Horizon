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
  curl -fsS -G "http://www.pushplus.plus/send" \
    --data-urlencode "token=${PUSHPLUS_TOKEN}" \
    --data-urlencode "title=${TITLE}" \
    --data-urlencode "content=${BODY}" \
    --data-urlencode "template=html" \
    --data-urlencode "timestamp=$(date +%s)" > /dev/null \
    && echo "[push] PushPlus OK" \
    || echo "[push] PushPlus FAILED (continuing)"
fi

# --- WeCom Bot (fallback) ---------------------------------------------------
if [ -n "$WECOM_WEBHOOK" ]; then
  echo "[push] Sending via WeCom bot..."
  # WeCom requires a JSON POST with markdown body
  WECOM_PAYLOAD="$(python3 -c "
import json, sys
print(json.dumps({
  'msgtype': 'markdown',
  'markdown': {'content': '''## ${TITLE}\n${WECOM_BODY}'''}
}))
")"
  curl -fsS -X POST "${WECOM_WEBHOOK}" \
    -H "Content-Type: application/json" \
    -d "${WECOM_PAYLOAD}" > /dev/null \
    && echo "[push] WeCom OK" \
    || echo "[push] WeCom FAILED (non-fatal)"
fi

echo "[push] Done (${MODE})."
