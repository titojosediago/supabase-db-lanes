#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env.migration if present
if [ -f "$ROOT_DIR/.env.migration" ]; then
  # shellcheck disable=SC1090
  source "$ROOT_DIR/.env.migration"
fi

# Defaults (can be overridden by env or flags)
: "${SOURCE_DB_URL:=}"
: "${TARGET_DB_URL:=}"
: "${EXCLUDE_SCHEMAS:=supabase_migrations,pgbouncer}"
: "${EXCLUDE_TABLES:=auth.schema_migrations,storage.migrations,auth.audit_log_entries,vault.secrets}"
YES_FLAG="false"
DRY_RUN="false"
TRUNCATE_FIRST="true"
MASK_SQL=""         # optional path to a SQL file with anonymization statements
OUTFILE="${ROOT_DIR}/.tmp/source-data-dump.sql"
DISABLE_TRIGGERS="false"
# Storage sync options
INCLUDE_STORAGE="false"
STORAGE_BUCKETS=""   # comma-separated list; empty => all buckets
STORAGE_FOLDERS_ONLY="true"  # create folders with placeholder objects; no file copying
SOURCE_SUPABASE_URL="${SOURCE_SUPABASE_URL:-}"
SOURCE_SERVICE_ROLE="${SOURCE_SERVICE_ROLE:-}"
TARGET_SUPABASE_URL="${TARGET_SUPABASE_URL:-}"
TARGET_SERVICE_ROLE="${TARGET_SERVICE_ROLE:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --source-url=URL         Source Postgres URL (overrides SOURCE_DB_URL)
  --target-url=URL         Target Postgres URL (overrides TARGET_DB_URL)
  --exclude-schemas=LIST   Comma-separated schemas to exclude (default: ${EXCLUDE_SCHEMAS})
  --exclude-tables=LIST    Comma-separated tables to exclude (schema.table)
  --no-truncate            Do not truncate target tables before import
  --mask-sql=FILE          Run this SQL after import to anonymize PII
  --outfile=FILE           Path to write dump (default: ${OUTFILE})
  --dry-run                Show actions without executing
  --disable-triggers       Include --disable-triggers in pg_dump (requires table ownership)
  --include-storage        Also migrate Storage buckets and objects
  --storage-buckets=LIST   Comma-separated bucket names to include (default: all)
  --storage-folders-only   Only create folder structure (no file copy). Default: true
  --source-supabase-url=U  Source project URL (e.g. https://xyz.supabase.co)
  --source-service-role=K  Source service_role key
  --target-supabase-url=U  Target project URL
  --target-service-role=K  Target service_role key
  --yes                    Skip confirmation prompts
  -h, --help               Show this help

Requires pg_dump and psql in PATH. Runs on Windows via Git Bash.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --source-url=*) SOURCE_DB_URL="${arg#*=}" ;;
    --target-url=*) TARGET_DB_URL="${arg#*=}" ;;
    --exclude-schemas=*) EXCLUDE_SCHEMAS="${arg#*=}" ;;
    --exclude-tables=*) EXCLUDE_TABLES="${arg#*=}" ;;
    --no-truncate) TRUNCATE_FIRST="false" ;;
    --mask-sql=*) MASK_SQL="${arg#*=}" ;;
    --outfile=*) OUTFILE="${arg#*=}" ;;
    --dry-run) DRY_RUN="true" ;;
    --disable-triggers) DISABLE_TRIGGERS="true" ;;
    --include-storage) INCLUDE_STORAGE="true" ;;
    --storage-buckets=*) STORAGE_BUCKETS="${arg#*=}" ;;
    --storage-folders-only) STORAGE_FOLDERS_ONLY="true" ;;
    --source-supabase-url=*) SOURCE_SUPABASE_URL="${arg#*=}" ;;
    --source-service-role=*) SOURCE_SERVICE_ROLE="${arg#*=}" ;;
    --target-supabase-url=*) TARGET_SUPABASE_URL="${arg#*=}" ;;
    --target-service-role=*) TARGET_SERVICE_ROLE="${arg#*=}" ;;
    --yes) YES_FLAG="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
  esac
done

# If syncing storage structure, exclude storage metadata tables from DB import to avoid conflicts
if [ "${INCLUDE_STORAGE}" = "true" ]; then
  if [ -z "${EXCLUDE_TABLES}" ]; then
    EXCLUDE_TABLES="storage.objects,storage.prefixes"
  else
    EXCLUDE_TABLES="${EXCLUDE_TABLES},storage.objects,storage.prefixes"
  fi
fi

command -v pg_dump >/dev/null 2>&1 || { echo "pg_dump not found in PATH"; exit 1; }
command -v psql >/dev/null 2>&1 || { echo "psql not found in PATH"; exit 1; }

if [ -z "${SOURCE_DB_URL}" ] || [ -z "${TARGET_DB_URL}" ]; then
  echo "Both SOURCE_DB_URL and TARGET_DB_URL are required (env or flags)."
  exit 1
fi

mkdir -p "$(dirname "$OUTFILE")"

echo "-------------------------------------------"
echo "Data-only migration: source -> target"
echo "Source host:  $(echo "$SOURCE_DB_URL" | sed -E 's|^.*@([^:/]+).*$|\1|' || true)"
echo "Target host:  $(echo "$TARGET_DB_URL" | sed -E 's|^.*@([^:/]+).*$|\1|' || true)"
echo "Exclude schemas: ${EXCLUDE_SCHEMAS}"
echo "Exclude tables:  ${EXCLUDE_TABLES}"
echo "Truncate first:  ${TRUNCATE_FIRST}"
echo "Mask SQL:        ${MASK_SQL:-<none>}"
echo "Outfile:         ${OUTFILE}"
echo "Dry run:         ${DRY_RUN}"
echo "Disable triggers:${DISABLE_TRIGGERS}"
echo "Include storage: ${INCLUDE_STORAGE}"
if [ "${INCLUDE_STORAGE}" = "true" ]; then
  echo "Storage buckets:  ${STORAGE_BUCKETS:-<all>}"
  echo "Source SB URL:    ${SOURCE_SUPABASE_URL:-<unset>}"
  echo "Target SB URL:    ${TARGET_SUPABASE_URL:-<unset>}"
  echo "Folders only:     ${STORAGE_FOLDERS_ONLY}"
fi
echo "-------------------------------------------"

if [ "${YES_FLAG}" != "true" ]; then
  read -r -p "This will migrate data INTO the target database. Continue? [y/N] " yn
  case "$yn" in
    [Yy]*) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# Build pg_dump excludes
PG_DUMP_EXCLUDES=()
IFS=',' read -ra SCHEMAS <<< "${EXCLUDE_SCHEMAS}"
for s in "${SCHEMAS[@]}"; do
  s_trim="$(echo "$s" | xargs || true)"
  [ -n "$s_trim" ] && PG_DUMP_EXCLUDES+=( "--exclude-schema=${s_trim}" )
done
IFS=',' read -ra TABLES <<< "${EXCLUDE_TABLES}"
for t in "${TABLES[@]}"; do
  t_trim="$(echo "$t" | xargs || true)"
  [ -n "$t_trim" ] && PG_DUMP_EXCLUDES+=( "--exclude-table=${t_trim}" )
done

if [ "${DRY_RUN}" = "true" ]; then
  echo "[DRY RUN] Would run:"
  if [ "${DISABLE_TRIGGERS}" = "true" ]; then
    echo "pg_dump \"\$SOURCE_DB_URL\" --format=plain --no-owner --no-privileges --data-only --disable-triggers ${PG_DUMP_EXCLUDES[*]} > \"${OUTFILE}\""
  else
    echo "pg_dump \"\$SOURCE_DB_URL\" --format=plain --no-owner --no-privileges --data-only ${PG_DUMP_EXCLUDES[*]} > \"${OUTFILE}\""
  fi
else
  echo "Dumping source data..."
  if [ "${DISABLE_TRIGGERS}" = "true" ]; then
    pg_dump "$SOURCE_DB_URL" \
      --format=plain \
      --no-owner --no-privileges \
      --data-only \
      --disable-triggers \
      "${PG_DUMP_EXCLUDES[@]}" \
      > "$OUTFILE"
  else
    pg_dump "$SOURCE_DB_URL" \
      --format=plain \
      --no-owner --no-privileges \
      --data-only \
      "${PG_DUMP_EXCLUDES[@]}" \
      > "$OUTFILE"
  fi
  echo "Dump written to: ${OUTFILE}"
fi

if [ "${TRUNCATE_FIRST}" = "true" ]; then
  echo "Preparing TRUNCATE script for target database..."
  TRUNCATE_SQL="$(mktemp)"
  EXCLUDE_LIST="'pg_catalog','information_schema','pg_toast'"
  # Add user excludes to the list safely
  for s in "${SCHEMAS[@]}"; do
    s_trim="$(echo "$s" | xargs || true)"
    [ -n "$s_trim" ] && EXCLUDE_LIST="${EXCLUDE_LIST},'${s_trim}'"
  done
  # Build table-level excludes for TRUNCATE (schema.table)
  EXCLUDE_TABLES_Q=""
  for t in "${TABLES[@]}"; do
    t_trim="$(echo "$t" | xargs || true)"
    if [ -n "$t_trim" ]; then
      if [ -n "$EXCLUDE_TABLES_Q" ]; then
        EXCLUDE_TABLES_Q="${EXCLUDE_TABLES_Q},'${t_trim}'"
      else
        EXCLUDE_TABLES_Q="'${t_trim}'"
      fi
    fi
  done
  if [ -n "$EXCLUDE_TABLES_Q" ]; then
    EXCLUDE_TABLES_WHERE="      AND format('%I.%I', n.nspname, c.relname) NOT IN (${EXCLUDE_TABLES_Q})"
  else
    EXCLUDE_TABLES_WHERE=""
  fi
  cat > "$TRUNCATE_SQL" <<EOSQL
DO \$\$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT format('%I.%I', n.nspname, c.relname) AS fqtn
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND n.nspname NOT IN (${EXCLUDE_LIST})
${EXCLUDE_TABLES_WHERE}
  LOOP
    EXECUTE 'TRUNCATE TABLE ' || r.fqtn || ' CASCADE';
  END LOOP;
END
\$\$;
EOSQL

  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY RUN] Would TRUNCATE tables in target (excluding: ${EXCLUDE_LIST})."
  else
    echo "Truncating target tables..."
    psql "$TARGET_DB_URL" -v ON_ERROR_STOP=1 -f "$TRUNCATE_SQL"
  fi
fi

if [ "${DRY_RUN}" = "true" ]; then
  echo "[DRY RUN] Would import dump into target:"
  echo "psql \"\$TARGET_DB_URL\" -v ON_ERROR_STOP=1 -f \"${OUTFILE}\""
else
  echo "Importing dump into target..."
  psql "$TARGET_DB_URL" -v ON_ERROR_STOP=1 -f "$OUTFILE"
fi

if [ -n "${MASK_SQL}" ]; then
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY RUN] Would run mask SQL: ${MASK_SQL}"
  else
    echo "Running masking SQL..."
    psql "$TARGET_DB_URL" -v ON_ERROR_STOP=1 -f "$MASK_SQL"
  fi
fi

echo "Verifying a quick row-count sample..."
VERIFY_SQL="$(mktemp)"
cat > "$VERIFY_SQL" <<'EOSQL'
WITH counts AS (
  SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    pg_total_relation_size(format('%I.%I', n.nspname, c.relname)) AS bytes
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r'
    AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast','pgbouncer','supabase_migrations')
)
SELECT schema_name, table_name, bytes
FROM counts
ORDER BY bytes DESC
LIMIT 15;
EOSQL

if [ "${DRY_RUN}" = "true" ]; then
  echo "[DRY RUN] Would show largest tables in target."
else
  psql "$TARGET_DB_URL" -At -f "$VERIFY_SQL" | awk -F"|" '{printf "%-24s %-36s %12d\n", $1, $2, $3}'
fi

# -----------------------------------------------------------------------------
# Optional: Storage migration (buckets + folders structure)
# -----------------------------------------------------------------------------
if [ "${INCLUDE_STORAGE}" = "true" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "Warning: jq not found; skipping storage structure sync. Install jq to enable this step."
  elif [ -z "${SOURCE_SUPABASE_URL}" ] || [ -z "${TARGET_SUPABASE_URL}" ] || [ -z "${SOURCE_SERVICE_ROLE}" ] || [ -z "${TARGET_SERVICE_ROLE}" ]; then
    echo "Warning: Missing Storage credentials/URLs; skipping storage structure sync."
  else

  STORAGE_TMP_DIR="${ROOT_DIR}/.tmp/storage-sync"
  mkdir -p "$STORAGE_TMP_DIR"

  echo "Listing source buckets..."
  BUCKETS_JSON="$(curl -sfL -H "Authorization: Bearer ${SOURCE_SERVICE_ROLE}" "${SOURCE_SUPABASE_URL%/}/storage/v1/bucket")"
  if [ -z "${BUCKETS_JSON}" ]; then
    echo "Failed to list source buckets."
    exit 1
  fi
  if [ -n "${STORAGE_BUCKETS}" ]; then
    # Filter to only requested buckets
    FILTERED="$(echo "$BUCKETS_JSON" | jq --arg buckets "${STORAGE_BUCKETS}" -c '
      [ .[] | select( (.name) as $n | ($buckets | split(\",\")) | index($n) ) ]
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
      # Try create; ignore conflict errors
      curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${TARGET_SERVICE_ROLE}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${NAME}\",\"public\":${PUBLIC}}" \
        "${TARGET_SUPABASE_URL%/}/storage/v1/bucket" | grep -qE '^(200|201|409)$' || {
          echo "     Warning: could not create bucket ${NAME} (may already exist)."
        }
    fi
  done

  echo "Syncing storage structure..."
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
      if [ "${STORAGE_FOLDERS_ONLY}" = "true" ]; then
        # Derive folder prefixes and create placeholder files to represent folders
        FOLDERS_FILE="$(mktemp)"
        echo "$RESP" | jq -r '.[].name' | while read -r OBJ; do
          # For each object path, emit all parent prefixes
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
      else
        echo "  Skipping folder-only check disabled. (No file copying implemented here.)"
      fi
      OFFSET=$((OFFSET + LIMIT))
    done
  done
  echo "Storage structure sync completed."
fi

fi

echo "Done."


