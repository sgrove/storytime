#!/usr/bin/env bash
set -euo pipefail

API_BASE="${API_BASE:-https://storytime-api-091733.onrender.com}"
EDITOR_BASE="${EDITOR_BASE:-https://storytime-editor-092113.onrender.com}"
READER_BASE="${READER_BASE:-https://storytime-reader-092117.onrender.com}"
STORY_ID="${STORY_ID:-}"
EDITOR_DEEP_LINK="${EDITOR_DEEP_LINK:-/stories/demo}"
READER_DEEP_LINK="${READER_DEEP_LINK:-/story/demo}"

pass=0
fail=0
skip=0

check() {
  local name="$1"
  local cmd="$2"
  if bash -lc "$cmd"; then
    echo "PASS  $name"
    pass=$((pass + 1))
  else
    echo "FAIL  $name"
    fail=$((fail + 1))
  fi
}

skip_check() {
  local name="$1"
  echo "SKIP  $name"
  skip=$((skip + 1))
}

check "AC-014 /health returns 200" \
  "[[ \"\$(curl -sS -o /dev/null -w \"%{http_code}\" \"${API_BASE}/health\")\" == \"200\" ]]"

check "Version endpoint returns commit metadata" \
  "curl -sS \"${API_BASE}/api/version\" | jq -e '.commit | strings | length > 0' >/dev/null"

check "Voices endpoint rejects unsupported provider with 400" \
  "[[ \"\$(curl -sS -o /dev/null -w \"%{http_code}\" \"${API_BASE}/api/voices/unknown\")\" == \"400\" ]]"

if [[ -z "$STORY_ID" ]]; then
  STORY_ID="$(curl -sS "${API_BASE}/api/stories" | jq -r '.stories[0].id // empty')"
fi

if [[ -n "$STORY_ID" ]]; then
  check "AC-009 StoryPack endpoint returns schemaVersion 1" \
    "curl -sS \"${API_BASE}/api/stories/${STORY_ID}/pack\" | jq -e '.schemaVersion == 1' >/dev/null"

  check "AC-009 StoryPack includes pages array" \
    "curl -sS \"${API_BASE}/api/stories/${STORY_ID}/pack\" | jq -e '.pages | arrays' >/dev/null"
else
  skip_check "AC-009 StoryPack checks (no story available)"
fi

check "AC-015 Editor deep link rewrites to index" \
  "[[ \"\$(curl -sS -o /dev/null -w \"%{http_code}\" \"${EDITOR_BASE}${EDITOR_DEEP_LINK}\")\" == \"200\" ]]"

check "AC-015 Reader deep link rewrites to index" \
  "[[ \"\$(curl -sS -o /dev/null -w \"%{http_code}\" \"${READER_BASE}${READER_DEEP_LINK}\")\" == \"200\" ]]"

echo
echo "Verification summary: pass=${pass} fail=${fail} skip=${skip}"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
