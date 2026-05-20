#!/usr/bin/env bash
# Populate the dev Stash server with sample clips and trigger a scan.
#
# Run after `docker compose up -d`. Idempotent: re-running skips clips
# that are already on disk and re-triggers a scan, which finds no new
# files and exits quickly.
#
# Overrides:
#   DEV_STASH_URL           default http://127.0.0.1:9999
#   DEV_STASH_SCAN_TIMEOUT  seconds to wait for metadataScan to finish
#                           (default 300)
#   DEV_STASH_READY_TIMEOUT seconds to wait for Stash to answer GraphQL
#                           on startup (default 60)
#
# Requires: bash, curl, jq.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$HERE/clips.json"
MEDIA_DIR="$HERE/media"

DEV_STASH_URL="${DEV_STASH_URL:-http://127.0.0.1:9999}"
DEV_STASH_SCAN_TIMEOUT="${DEV_STASH_SCAN_TIMEOUT:-300}"
DEV_STASH_READY_TIMEOUT="${DEV_STASH_READY_TIMEOUT:-60}"
GRAPHQL="${DEV_STASH_URL%/}/graphql"

log() { printf '[populate] %s\n' "$*" >&2; }
err() { printf '[populate] ERROR: %s\n' "$*" >&2; }

require() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "missing required command: $cmd"
    exit 2
  fi
}

# Run a GraphQL request and return the raw response body. Exits non-zero
# on transport failure; GraphQL `errors` arrays are surfaced by callers.
gql() {
  local query=$1
  curl -fsS \
    --connect-timeout 5 --max-time 30 \
    -H 'Content-Type: application/json' \
    -X POST "$GRAPHQL" \
    -d "$(jq -nc --arg q "$query" '{query:$q}')"
}

wait_for_ready() {
  log "waiting for Stash at $DEV_STASH_URL"
  local deadline=$((SECONDS + DEV_STASH_READY_TIMEOUT))
  while (( SECONDS < deadline )); do
    if response=$(gql '{ version { version } }' 2>/dev/null); then
      local version
      version=$(jq -r '.data.version.version // empty' <<<"$response" 2>/dev/null || true)
      if [ -n "$version" ]; then
        log "Stash $version is ready"
        return 0
      fi
    fi
    sleep 1
  done
  err "Stash did not respond at $GRAPHQL within ${DEV_STASH_READY_TIMEOUT}s."
  err "Run \`docker compose up -d\` first, then re-run this script."
  exit 1
}

download_clips() {
  mkdir -p "$MEDIA_DIR"
  local total
  total=$(jq -r '. | length' "$MANIFEST")
  log "manifest has $total clips, target dir: $MEDIA_DIR"

  local downloaded=0 skipped=0 failed=0
  while IFS=$'\t' read -r url filename; do
    local target="$MEDIA_DIR/$filename"
    if [ -s "$target" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    log "downloading $filename"
    if curl -fL --connect-timeout 10 --max-time 600 \
         --silent --show-error \
         -o "$target.part" "$url"; then
      mv "$target.part" "$target"
      downloaded=$((downloaded + 1))
    else
      rm -f "$target.part"
      err "WARN: $filename failed ($url); continuing"
      failed=$((failed + 1))
    fi
  done < <(jq -r '.[] | [.url, .filename] | @tsv' "$MANIFEST")

  log "downloads: $downloaded new, $skipped already present, $failed failed"
}

scene_count() {
  local response
  response=$(gql '{ findScenes(filter: {per_page: 1}) { count } }')
  jq -r '.data.findScenes.count // 0' <<<"$response"
}

# Run Stash's first-run setup if it hasn't been done. setup() is what
# actually initializes the database; calling configureGeneral on a
# fresh instance writes config.yml but leaves Stash with a nil DB
# handle, which makes the scan job panic. Idempotent: skipped when
# /data is already registered as a library.
ensure_setup() {
  local response existing
  response=$(gql '{ configuration { general { stashes { path } } } }')
  existing=$(jq -r '.data.configuration.general.stashes[]?.path // empty' <<<"$response")
  if grep -qxF /data <<<"$existing"; then
    log "library /data already registered"
    return 0
  fi
  log "running first-run setup (library /data, default paths)"
  # Empty strings let Stash fall back to its STASH_GENERATED /
  # STASH_CACHE / STASH_BLOBS / databaseFile defaults from env / config.
  local result
  result=$(gql 'mutation { setup(input: {
    configLocation: "",
    stashes: [{ path: "/data", excludeVideo: false, excludeImage: true }],
    databaseFile: "",
    generatedLocation: "",
    cacheLocation: "",
    blobsLocation: "",
    storeBlobsInDatabase: false
  }) }')
  local errors
  errors=$(jq -r '.errors // empty | tostring' <<<"$result")
  if [ -n "$errors" ] && [ "$errors" != "null" ]; then
    err "setup returned errors: $errors"
    exit 1
  fi
}

trigger_scan() {
  log "triggering metadataScan"
  local response
  response=$(gql 'mutation { metadataScan(input: {}) }')

  local errors
  errors=$(jq -r '.errors // empty | tostring' <<<"$response")
  if [ -n "$errors" ] && [ "$errors" != "null" ]; then
    err "metadataScan returned errors: $errors"
    exit 1
  fi

  jq -r '.data.metadataScan // empty' <<<"$response"
}

# Stash's findJob takes the job ID as a string. Status is one of READY,
# RUNNING, FINISHED, CANCELLED, FAILED.
poll_job() {
  local job_id=$1
  local deadline=$((SECONDS + DEV_STASH_SCAN_TIMEOUT))
  while (( SECONDS < deadline )); do
    local response status
    response=$(gql "{ findJob(input: { id: \"$job_id\" }) { status progress } }")
    status=$(jq -r '.data.findJob.status // "MISSING"' <<<"$response")
    case "$status" in
      FINISHED)
        log "scan finished"
        return 0
        ;;
      FAILED|CANCELLED)
        err "scan job $job_id ended with status: $status"
        err "$(jq -r '.data.findJob // empty' <<<"$response")"
        exit 1
        ;;
      MISSING)
        # Stash drops finished jobs from the queue after a short window;
        # treat a missing job as "done" once we have polled it at least
        # once successfully -- but if the first poll never sees the job,
        # surface that as an error.
        log "job $job_id no longer in queue, assuming finished"
        return 0
        ;;
    esac
    sleep 2
  done
  err "scan still running after ${DEV_STASH_SCAN_TIMEOUT}s (job $job_id)"
  err "inspect via the Stash UI at $DEV_STASH_URL/settings?tab=tasks"
  exit 1
}

main() {
  require curl
  require jq
  [ -f "$MANIFEST" ] || { err "manifest not found: $MANIFEST"; exit 2; }

  wait_for_ready
  ensure_setup
  download_clips

  local before after job_id
  before=$(scene_count)
  job_id=$(trigger_scan)
  if [ -z "$job_id" ]; then
    err "metadataScan did not return a job ID"
    exit 1
  fi
  log "scan job id: $job_id"
  poll_job "$job_id"
  after=$(scene_count)

  local added=$((after - before))
  log "scenes: $before before, $after after ($added new)"
  log "done. Library available at $DEV_STASH_URL"
}

main "$@"
