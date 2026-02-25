#!/usr/bin/env bash
set -euo pipefail

API_BASE="${RENDER_API_BASE:-https://api.render.com/v1}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
MAX_POLLS="${MAX_POLLS:-120}"
COMMIT_SHA="${COMMIT_SHA:-${GITHUB_SHA:-}}"

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

is_failure_status() {
  case "$1" in
    build_failed|update_failed|failed|canceled|cancelled|deactivated)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

api_request() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local response_file
  local http_code

  response_file="$(mktemp)"

  if [[ -n "${body}" ]]; then
    http_code="$(curl -sS -o "${response_file}" -w "%{http_code}" \
      -X "${method}" \
      -H "authorization: Bearer ${RENDER_API_KEY}" \
      -H "content-type: application/json" \
      -H "accept: application/json" \
      -d "${body}" \
      "${url}")"
  else
    http_code="$(curl -sS -o "${response_file}" -w "%{http_code}" \
      -X "${method}" \
      -H "authorization: Bearer ${RENDER_API_KEY}" \
      -H "accept: application/json" \
      "${url}")"
  fi

  if [[ "${http_code}" -lt 200 || "${http_code}" -gt 299 ]]; then
    echo "Render API request failed (${method} ${url}) with status ${http_code}" >&2
    cat "${response_file}" >&2
    rm -f "${response_file}"
    exit 1
  fi

  cat "${response_file}"
  rm -f "${response_file}"
}

trigger_deploy() {
  local service_id="$1"
  local payload
  local response
  local deploy_id

  if [[ -n "${COMMIT_SHA}" ]]; then
    payload="$(jq -cn --arg clear_cache "do_not_clear" --arg commit_id "${COMMIT_SHA}" '{clearCache: $clear_cache, commitId: $commit_id}')"
  else
    payload='{"clearCache":"do_not_clear"}'
  fi

  response="$(api_request "POST" "${API_BASE}/services/${service_id}/deploys" "${payload}")"
  deploy_id="$(echo "${response}" | jq -r '.id // .deploy.id // empty')"

  if [[ -z "${deploy_id}" ]]; then
    echo "Unable to read deploy id for service ${service_id}" >&2
    echo "${response}" >&2
    exit 1
  fi

  echo "${deploy_id}"
}

deploy_status() {
  local service_id="$1"
  local deploy_id="$2"
  api_request "GET" "${API_BASE}/services/${service_id}/deploys/${deploy_id}" | jq -r '.status // .deploy.status // "unknown"'
}

wait_for_deploy() {
  local service_id="$1"
  local deploy_id="$2"
  local attempt
  local status

  for ((attempt = 1; attempt <= MAX_POLLS; attempt += 1)); do
    status="$(deploy_status "${service_id}" "${deploy_id}")"
    echo "service=${service_id} deploy=${deploy_id} status=${status} attempt=${attempt}/${MAX_POLLS}"

    if [[ "${status}" == "live" ]]; then
      return 0
    fi

    if is_failure_status "${status}"; then
      return 1
    fi

    sleep "${POLL_INTERVAL_SECONDS}"
  done

  echo "Deploy polling timed out for service ${service_id} deploy ${deploy_id}" >&2
  return 1
}

require_var "RENDER_API_KEY"

declare -a service_ids

if [[ -n "${RENDER_SERVICE_IDS:-}" ]]; then
  IFS=',' read -r -a service_ids <<<"${RENDER_SERVICE_IDS}"
else
  require_var "RENDER_API_SERVICE_ID"
  require_var "RENDER_EDITOR_SERVICE_ID"
  require_var "RENDER_READER_SERVICE_ID"
  service_ids=("${RENDER_API_SERVICE_ID}" "${RENDER_EDITOR_SERVICE_ID}" "${RENDER_READER_SERVICE_ID}")
fi

declare -A deploy_ids

for raw_service_id in "${service_ids[@]}"; do
  service_id="${raw_service_id//[[:space:]]/}"
  if [[ -z "${service_id}" ]]; then
    continue
  fi

  deploy_id="$(trigger_deploy "${service_id}")"
  deploy_ids["${service_id}"]="${deploy_id}"
  echo "Triggered deploy for ${service_id}: ${deploy_id}"
done

for service_id in "${!deploy_ids[@]}"; do
  deploy_id="${deploy_ids[${service_id}]}"

  if ! wait_for_deploy "${service_id}" "${deploy_id}"; then
    echo "Deploy failed for service ${service_id} (deploy ${deploy_id})" >&2
    exit 1
  fi
done

echo "All Render deploys reached live status."
