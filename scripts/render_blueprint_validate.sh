#!/usr/bin/env bash
set -euo pipefail

BLUEPRINT_PATH="${1:-render.yaml}"

if ! command -v render >/dev/null 2>&1; then
  echo "render CLI is required to validate blueprint files" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to validate blueprint files" >&2
  exit 1
fi

: "${RENDER_API_KEY:?Missing RENDER_API_KEY}"

workspace_id="${RENDER_WORKSPACE_ID:-}"

if [[ -z "${workspace_id}" ]]; then
  workspace_id="$(render workspaces -o json | jq -r '.[0].id // empty')"
fi

if [[ -z "${workspace_id}" ]]; then
  echo "Unable to resolve Render workspace id for blueprint validation" >&2
  exit 1
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

render blueprints validate "${BLUEPRINT_PATH}" --workspace "${workspace_id}" -o json | tee "${tmp_file}"
jq -e '.valid == true' "${tmp_file}" >/dev/null
