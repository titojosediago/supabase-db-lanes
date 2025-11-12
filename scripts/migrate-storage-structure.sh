#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env.migration if present
if [ -f "$ROOT_DIR/.env.migration" ]; then
  # shellcheck disable=SC1090
  source "$ROOT_DIR/.env.migration"
fi

: "${SOURCE_SUPABASE_URL:=}"
: "${SOURCE_SERVICE_ROLE:=}"
: "${TARGET_SUPABASE_URL:=}"
: "${TARGET_SERVICE_ROLE:=}"
: "${STORAGE_BUCKETS:=}"        # comma-separated list; empty => all
STORAGE_FOLDERS_ONLY="true"     # structure only
DRY_RUN="false"
YES_FLAG="false"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --source-supabase-url=U  Source project URL (e.g. https://xyz.supabase.co)
  --source-service-role=K  Source service_role key
  --target-supabase-url=U  Target project URL
  --target-service-role=K  Target service_role key
  --storage-buckets=LIST   Comma-separated bucket names to include (default: all)
  --dry-run                Show actions without executing
  --yes                    Skip confirmation prompts
  -h, --help               Show this help

Requires curl and jq in PATH. Runs on Windows via Git Bash.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --source-supabase-url=*) SOURCE_SUPABASE_URL="${arg#*=}" ;;
    --source-service-role=*) SOURCE_SERVICE_ROLE="${arg#*=}" ;;
    --target-supabase-url=*) TARGET_SUPABASE_URL="${arg#*=}" ;;
    --target-service-role=*) TARGET_SERVICE_ROLE="${arg#*=}" ;;
    --storage-buckets=*) STORAGE_BUCKETS="${arg#*=}" ;;
    --dry-run) DRY_RUN="true" ;;
    --yes) YES_FLAG="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "curl not found in PATH"; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found in PATH. Please install jq to continue."
  exit 1
fi

if [ -z "${SOURCE_SUPABASE_URL}" ] || [ -z "${TARGET_SUPABASE_URL}" ] || [ -z "${SOURCE_SERVICE_ROLE}" ] || [ -z "${TARGET_SERVICE_ROLE}" ]; then
  echo "SOURCE_SUPABASE_URL, TARGET_SUPABASE_URL, SOURCE_SERVICE_ROLE, TARGET_SERVICE_ROLE are required."
  exit 1
fi

echo "-------------------------------------------"
echo "Storage structure migration: source -> target"
echo "Source SB URL:    ${SOURCE_SUPABASE_URL}"
echo "Target SB URL:    ${TARGET_SUPABASE_URL}"
echo "Buckets:          ${STORAGE_BUCKETS:-<all>}"
echo "Folders only:     ${STORAGE_FOLDERS_ONLY}"
echo "Dry run:          ${DRY_RUN}"
echo "-------------------------------------------"

if [ "${YES_FLAG}" != "true" ]; then
  read -r -p "This will mirror bucket structure INTO the target project. Continue? [y/N] " yn
  case "$yn" in
    [Yy]*) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

STORAGE_TMP_DIR="${ROOT_DIR}/.tmp/storage-sync"
mkdir -p "$STORAGE_TMP_DIR"

echo "Listing source buckets..."
BUCKETS_JSON="$(curl -sfL -H "Authorization: Bearer ${SOURCE_SERVICE_ROLE}" "${SOURCE_SUPABASE_URL%/}/storage/v1/bucket")"
if [ -z "${BUCKETS_JSON}" ]; then
  echo "Failed to list source buckets."
  exit 1
fi
if [ -n "${STORAGE_BUCKETS}" ]; then
  FILTERED="$(echo "$BUCKETS_JSON" | jq --arg buckets "${STORAGE_BUCKETS}" -c '
    [ .[] | select( (.name) as $n | ($buckets | split(",")) | index($n) ) ]
  ')"
  BUCKETS_JSON="$FILTERED"
fi

echo "Ensuring target buckets exist..."
echo "$BUCKETS_JSON" | jq -c '.[] | {name, public}' | while read -r b; do
  NAME="$(echo "$b" | jq -r '.name')"
  PUBLIC="$(echo "$b" | jq -r '.public')"
  echo "  -> Bucket: ${NAME} (public=${PUBLIC})"
  if [ "${DRY_RUN}" = "true" ]; then
    echo "     [DRY RUN] Would create bucket ${NAME} on target if missing."
  else
    curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${TARGET_SERVICE_ROLE}" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${NAME}\",\"public\":${PUBLIC}}" \
      "${TARGET_SUPABASE_URL%/}/storage/v1/bucket" | grep -qE '^(200|201|409)$' || {
        echo "     Warning: could not create bucket ${NAME} (may already exist)."
      }
  fi
done

echo "Syncing folder structure..."
echo "$BUCKETS_JSON" | jq -r '.[].name' | while read -r BUCKET; do
  echo "Bucket: ${BUCKET}"
  OFFSET=0
  LIMIT=1000
  while :; do
    LIST_PAYLOAD=$(jq -nc --arg prefix "" --argjson limit $LIMIT --argjson offset $OFFSET \
      '{prefix:$prefix, limit:$limit, offset:$offset, sortBy:{column:"name",order:"asc"}}')
    RESP="$(curl -sfL -H "Authorization: Bearer ${SOURCE_SERVICE_ROLE}" \
      -H "Content-Type: application/json" \
      -d "$LIST_PAYLOAD" \
      "${SOURCE_SUPABASE_URL%/}/storage/v1/object/list/${BUCKET}")" || {
        echo "  Failed to list objects for ${BUCKET}"
        break
      }
    COUNT="$(echo "$RESP" | jq 'length')"
    if [ "$COUNT" -eq 0 ]; then
      break
    fi
    # Derive folder prefixes and create placeholder files to represent folders
    FOLDERS_FILE="$(mktemp)"
    echo "$RESP" | jq -r '.[].name' | while read -r OBJ; do
      IFS='/' read -ra PARTS <<< "$OBJ"
      ACC=""
      for (( i=0; i<${#PARTS[@]}-1; i++ )); do
        if [ -z "$ACC" ]; then
          ACC="${PARTS[$i]}"
        else
          ACC="${ACC}/${PARTS[$i]}"
        fi
        echo "$ACC" >> "$FOLDERS_FILE"
      done
    done
    if [ -s "$FOLDERS_FILE" ]; then
      sort -u "$FOLDERS_FILE" | while read -r PREFIX; do
        PLACEHOLDER_PATH="${PREFIX}/.keep"
        PLACEHOLDER_ENC="$(jq -rn --arg x "$PLACEHOLDER_PATH" '$x|@uri')"
        if [ "${DRY_RUN}" = "true" ]; then
          echo "  [DRY RUN] Would create folder placeholder ${BUCKET}/${PLACEHOLDER_PATH}"
        else
          curl -sfL -X POST \
            -H "Authorization: Bearer ${TARGET_SERVICE_ROLE}" \
            -H "x-upsert: true" \
            -H "Content-Type: application/octet-stream" \
            --data-binary "" \
            "${TARGET_SUPABASE_URL%/}/storage/v1/object/${BUCKET}/${PLACEHOLDER_ENC}" >/dev/null || {
              echo "   Warn: failed to create placeholder for ${BUCKET}/${PLACEHOLDER_PATH}"
            }
        fi
      done
    fi
    rm -f "$FOLDERS_FILE"
    OFFSET=$((OFFSET + LIMIT))
  done
done

echo "Done."


