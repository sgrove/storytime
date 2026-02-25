#!/usr/bin/env bash
set -euo pipefail

API_BASE="${API_BASE:-https://storytime-api-091733.onrender.com}"
EDITOR_BASE="${EDITOR_BASE:-https://storytime-editor-092113.onrender.com}"
READER_BASE="${READER_BASE:-https://storytime-reader-092117.onrender.com}"
STORY_ID="${STORY_ID:-}"
STORY_SLUG="${STORY_SLUG:-}"
EDITOR_DEEP_LINK="${EDITOR_DEEP_LINK:-/stories/demo}"
READER_DEEP_LINK="${READER_DEEP_LINK:-/story/demo}"
MUTATE="${MUTATE:-0}"

pass=0
fail=0
skip=0

pass_check() {
  local name="$1"
  echo "PASS  $name"
  pass=$((pass + 1))
}

fail_check() {
  local name="$1"
  local detail="${2:-}"
  echo "FAIL  $name"
  if [[ -n "$detail" ]]; then
    echo "      $detail"
  fi
  fail=$((fail + 1))
}

skip_check() {
  local name="$1"
  echo "SKIP  $name"
  skip=$((skip + 1))
}

check() {
  local name="$1"
  local cmd="$2"
  if bash -lc "$cmd"; then
    pass_check "$name"
  else
    fail_check "$name"
  fi
}

for dep in curl jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "Missing dependency: $dep"
    exit 2
  fi
done

check "AC-014 /health returns 200" \
  "[[ \"\$(curl -sS -o /dev/null -w \"%{http_code}\" \"${API_BASE}/health\")\" == \"200\" ]]"

check "Version endpoint returns commit metadata" \
  "curl -sS \"${API_BASE}/api/version\" | jq -e '.commit | strings | length > 0' >/dev/null"

check "Voices endpoint rejects unsupported provider with 400" \
  "[[ \"\$(curl -sS -o /dev/null -w \"%{http_code}\" \"${API_BASE}/api/voices/unknown\")\" == \"400\" ]]"

stories_json="$(curl -sS "${API_BASE}/api/stories" || echo '{}')"

if [[ -z "$STORY_ID" ]]; then
  STORY_ID="$(echo "$stories_json" | jq -r '.stories[0].id // empty' 2>/dev/null || true)"
fi

if [[ -z "$STORY_SLUG" ]]; then
  STORY_SLUG="$(echo "$stories_json" | jq -r '.stories[0].slug // empty' 2>/dev/null || true)"
fi

if [[ "$MUTATE" == "1" ]]; then
  create_title="AC Verify $(date +%s)"
  create_payload="$(jq -nc --arg title "$create_title" --arg style "storybook watercolor" '{title:$title, art_style:$style}')"
  create_resp="$(curl -sS -X POST "${API_BASE}/api/stories" -H "content-type: application/json" -d "$create_payload" || echo '{}')"
  created_id="$(echo "$create_resp" | jq -r '.story.id // empty' 2>/dev/null || true)"
  created_slug="$(echo "$create_resp" | jq -r '.story.slug // empty' 2>/dev/null || true)"
  created_status="$(echo "$create_resp" | jq -r '.story.status // empty' 2>/dev/null || true)"

  if [[ -n "$created_id" && -n "$created_slug" && "$created_status" == "draft" ]]; then
    pass_check "AC-001 create story persists id/slug/status=draft"
    STORY_ID="$created_id"
    STORY_SLUG="$created_slug"
  else
    fail_check "AC-001 create story persists id/slug/status=draft" "$(echo "$create_resp" | jq -c '.' 2>/dev/null || echo "$create_resp")"
  fi
else
  skip_check "AC-001 create story mutation check (set MUTATE=1 to enable)"
fi

if [[ -n "$STORY_ID" ]]; then
  check "Story detail endpoint returns graph with arrays" \
    "curl -sS \"${API_BASE}/api/stories/${STORY_ID}\" | jq -e '.story | (.characters | arrays) and (.pages | arrays) and (.music_tracks | arrays)' >/dev/null"

  check "Jobs endpoint returns jobs array" \
    "curl -sS \"${API_BASE}/api/stories/${STORY_ID}/jobs\" | jq -e '.jobs | arrays' >/dev/null"

  check "AC-009 StoryPack endpoint returns schemaVersion 1" \
    "curl -sS \"${API_BASE}/api/stories/${STORY_ID}/pack\" | jq -e '.schemaVersion == 1' >/dev/null"

  check "AC-009 StoryPack includes pages array" \
    "curl -sS \"${API_BASE}/api/stories/${STORY_ID}/pack\" | jq -e '.pages | arrays' >/dev/null"

  scene_url="$(
    curl -sS "${API_BASE}/api/stories/${STORY_ID}/pack" |
      jq -r '.pages[0].scene.url // empty' 2>/dev/null || true
  )"
  if [[ -n "$scene_url" ]]; then
    check "AC-009 First scene asset URL resolves" \
      "[[ \"\$(curl -sS -o /dev/null -w \"%{http_code}\" \"$scene_url\")\" == \"200\" ]]"
  else
    skip_check "AC-009 First scene asset URL resolves (no scene on page 1)"
  fi
else
  skip_check "Story checks (no story available)"
fi

if [[ -n "$STORY_SLUG" ]]; then
  check "Story slug pack endpoint resolves schemaVersion 1" \
    "curl -sS \"${API_BASE}/api/story-slugs/${STORY_SLUG}/pack\" | jq -e '.schemaVersion == 1' >/dev/null"
else
  skip_check "Story slug pack endpoint (no slug available)"
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
