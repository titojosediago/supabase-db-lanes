#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env.migration if present
if [ -f "$ROOT_DIR/.env.migration" ]; then
  # shellcheck disable=SC1090
  source "$ROOT_DIR/.env.migration"
fi

: "${SUPABASE_ACCESS_TOKEN:=}"
: "${SOURCE_PROJECT_REF:=}"
: "${TARGET_PROJECT_REF:=}"
: "${INCLUDE_FUNCTIONS:=}"     # comma-separated names; empty => auto-detect (best-effort)
: "${EXCLUDE_FUNCTIONS:=}"     # comma-separated names to skip
NO_VERIFY_JWT="false"
PRUNE="false"
JOBS="${JOBS:-1}"
DRY_RUN="false"
YES_FLAG="false"
SECRETS_ENV_FILE="${SECRETS_ENV_FILE:-}" # optional: set secrets on target from an env file

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --source-ref=REF           Source project ref (e.g. abcdefghijklmn)
  --target-ref=REF           Target project ref
  --include-functions=LIST   Comma-separated Edge Function names to migrate
  --exclude-functions=LIST   Comma-separated names to skip
  --no-verify-jwt            Deploy without JWT verification for functions (testing)
  --jobs=N                   Parallel deploy jobs (default: ${JOBS})
  --prune                    After deploy, delete target functions not in include set
  --secrets-env-file=PATH    Set target project secrets from an env file
  --dry-run                  Show actions without executing
  --yes                      Skip confirmation prompts
  -h, --help                 Show this help

Requirements:
  - Supabase CLI installed and in PATH
  - SUPABASE_ACCESS_TOKEN exported
EOF
}

for arg in "$@"; do
  case "$arg" in
    --source-ref=*) SOURCE_PROJECT_REF="${arg#*=}" ;;
    --target-ref=*) TARGET_PROJECT_REF="${arg#*=}" ;;
    --include-functions=*) INCLUDE_FUNCTIONS="${arg#*=}" ;;
    --exclude-functions=*) EXCLUDE_FUNCTIONS="${arg#*=}" ;;
    --no-verify-jwt) NO_VERIFY_JWT="true" ;;
    --jobs=*) JOBS="${arg#*=}" ;;
    --prune) PRUNE="true" ;;
    --secrets-env-file=*) SECRETS_ENV_FILE="${arg#*=}" ;;
    --dry-run) DRY_RUN="true" ;;
    --yes) YES_FLAG="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
  esac
done

command -v supabase >/dev/null 2>&1 || { echo "supabase CLI not found in PATH"; exit 1; }

if [ -z "${SUPABASE_ACCESS_TOKEN}" ]; then
  echo "SUPABASE_ACCESS_TOKEN is required."
  exit 1
fi
if [ -z "${SOURCE_PROJECT_REF}" ] || [ -z "${TARGET_PROJECT_REF}" ]; then
  echo "Both --source-ref and --target-ref are required."
  exit 1
fi

echo "-------------------------------------------"
echo "Edge Functions migration: ${SOURCE_PROJECT_REF} -> ${TARGET_PROJECT_REF}"
echo "Include: ${INCLUDE_FUNCTIONS:-<auto>}"
echo "Exclude: ${EXCLUDE_FUNCTIONS:-<none>}"
echo "No verify JWT: ${NO_VERIFY_JWT}"
echo "Jobs: ${JOBS}"
echo "Prune: ${PRUNE}"
echo "Secrets env: ${SECRETS_ENV_FILE:-<none>}"
echo "Dry run: ${DRY_RUN}"
echo "-------------------------------------------"

if [ "${YES_FLAG}" != "true" ]; then
  read -r -p "This will deploy functions INTO the target project. Continue? [y/N] " yn
  case "$yn" in
    [Yy]*) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Initialize a throwaway workspace to avoid touching current repo config.
pushd "$TMP_DIR" >/dev/null
supabase init >/dev/null

# Link to source and determine function names if not specified
if [ -z "${INCLUDE_FUNCTIONS}" ]; then
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY RUN] Would link to source: ${SOURCE_PROJECT_REF}"
    SOURCE_FUNCS=""
  else
    supabase link --project-ref "${SOURCE_PROJECT_REF}" >/dev/null
    # Parse plain table output from CLI; extract first column tokens that look like valid function names
    SOURCE_LIST="$(supabase functions list || true)"
    # Strip ANSI color codes if any
    SOURCE_LIST_CLEAN="$(printf "%s" "${SOURCE_LIST}" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')"
    SOURCE_FUNCS="$(echo "${SOURCE_LIST_CLEAN}" | awk '
      BEGIN {
        IGNORECASE=1;
      }
      /^[[:space:]]*$/ { next }
      /^[\|+-]/ { next }
      /NAME|ID|URL|VERIFY/ { next }
      {
        name=$1;
        # valid names: must start with letter, then letters/digits/_/-
        if (name ~ /^[A-Za-z][A-Za-z0-9_-]*$/) print name;
      }
    ' | tr '\n' ',' | sed 's/,$//')"
    INCLUDE_FUNCTIONS="${SOURCE_FUNCS}"
  fi
fi

# Build arrays
IFS=',' read -ra INCLUDE_ARR <<< "${INCLUDE_FUNCTIONS}"
IFS=',' read -ra EXCLUDE_ARR <<< "${EXCLUDE_FUNCTIONS}"

# Filter include - exclude
FILTERED_FUNCS=()
for f in "${INCLUDE_ARR[@]}"; do
  # trim whitespace and CR, validate name
  f_trim="$(printf "%s" "$f" | tr -d '\r' | xargs || true)"
  [ -z "$f_trim" ] && continue
  skip="false"
  for e in "${EXCLUDE_ARR[@]}"; do
    e_trim="$(echo "$e" | xargs || true)"
    [ "$f_trim" = "$e_trim" ] && { skip="true"; break; }
  done
  if [ "$skip" = "false" ]; then
    if [[ "$f_trim" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
      FILTERED_FUNCS+=("$f_trim")
    else
      echo "Skipping invalid function name detected: '$f_trim'"
    fi
  fi
done

if [ ${#FILTERED_FUNCS[@]} -eq 0 ]; then
  echo "No functions to migrate. Provide --include-functions or ensure source has functions."
  popd >/dev/null
  exit 0
fi

echo "Functions to migrate: ${FILTERED_FUNCS[*]}"

# Download from source
if [ "${DRY_RUN}" = "true" ]; then
  echo "[DRY RUN] Would download functions from ${SOURCE_PROJECT_REF}: ${FILTERED_FUNCS[*]}"
else
  supabase link --project-ref "${SOURCE_PROJECT_REF}" >/dev/null
  for name in "${FILTERED_FUNCS[@]}"; do
    echo "Downloading: ${name}"
    if supabase functions download "${name}" >/dev/null 2>&1; then
      :
    else
      echo "Warning: failed to download ${name} from source; continuing."
    fi
  done
fi

# Optionally set secrets on target (from env file)
if [ -n "${SECRETS_ENV_FILE}" ]; then
  # Resolve relative path to project root if needed
  if [ ! -f "${SECRETS_ENV_FILE}" ]; then
    CANDIDATE="${ROOT_DIR}/${SECRETS_ENV_FILE}"
    if [ -f "${CANDIDATE}" ]; then
      SECRETS_ENV_FILE="${CANDIDATE}"
    fi
  fi
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY RUN] Would set secrets from ${SECRETS_ENV_FILE} on target ${TARGET_PROJECT_REF}"
  else
    echo "Setting secrets from ${SECRETS_ENV_FILE}..."
    supabase secrets set --env-file "${SECRETS_ENV_FILE}" --project-ref "${TARGET_PROJECT_REF}"
  fi
fi

# Deploy to target
DEPLOY_FLAGS=()
[ "${NO_VERIFY_JWT}" = "true" ] && DEPLOY_FLAGS+=( "--no-verify-jwt" )
[ "${JOBS}" != "1" ] && DEPLOY_FLAGS+=( "--jobs=${JOBS}" )

if [ "${DRY_RUN}" = "true" ]; then
  echo "[DRY RUN] Would link to target ${TARGET_PROJECT_REF} and deploy: ${FILTERED_FUNCS[*]} ${DEPLOY_FLAGS[*]}"
else
  supabase link --project-ref "${TARGET_PROJECT_REF}" >/dev/null
  for name in "${FILTERED_FUNCS[@]}"; do
    echo "Deploying: ${name}"
    # final validation guard
    if ! [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
      echo "Warning: invalid function name '$name', skipping."
      continue
    fi
    supabase functions deploy "${name}" "${DEPLOY_FLAGS[@]}"
  done
  if [ "${PRUNE}" = "true" ]; then
    echo "Pruning target functions not in include set..."
    TARGET_LIST="$(supabase functions list || true)"
    TARGET_LIST_CLEAN="$(printf "%s" "${TARGET_LIST}" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')"
    TARGET_FUNCS="$(echo "${TARGET_LIST_CLEAN}" | awk '
      BEGIN { IGNORECASE=1 }
      /^[[:space:]]*$/ { next }
      /^[\|+-]/ { next }
      /NAME|ID|URL|VERIFY/ { next }
      {
        name=$1;
        if (name ~ /^[A-Za-z][A-Za-z0-9_-]*$/) print name;
      }
    ')"
    # Delete those not in FILTERED_FUNCS
    for t in $TARGET_FUNCS; do
      keep="false"
      for k in "${FILTERED_FUNCS[@]}"; do
        [ "$t" = "$k" ] && { keep="true"; break; }
      done
      if [ "$keep" = "false" ]; then
        echo "Deleting: ${t}"
        supabase functions delete "${t}" --yes
      fi
    done
  fi
fi

popd >/dev/null
echo "Done."


