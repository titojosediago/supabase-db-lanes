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
: "${EXCLUDE_TABLES:=auth.schema_migrations,storage.migrations,auth.audit_log_entries,vault.secrets,storage.objects,storage.prefixes}"
: "${INCLUDE_TABLES:=}"
YES_FLAG="false"
DRY_RUN="false"
TRUNCATE_FIRST="true"
MASK_SQL=""         # optional path to a SQL file with anonymization statements
OUTFILE="${ROOT_DIR}/.tmp/source-data-dump.sql"
DISABLE_TRIGGERS="false"
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --source-url=URL         Source Postgres URL (overrides SOURCE_DB_URL)
  --target-url=URL         Target Postgres URL (overrides TARGET_DB_URL)
  --exclude-schemas=LIST   Comma-separated schemas to exclude (default: ${EXCLUDE_SCHEMAS})
  --exclude-tables=LIST    Comma-separated tables to exclude (schema.table)
  --include-tables=LIST    Comma-separated tables to include only (schema.table). Overrides excludes.
  --no-truncate            Do not truncate target tables before import
  --mask-sql=FILE          Run this SQL after import to anonymize PII
  --outfile=FILE           Path to write dump (default: ${OUTFILE})
  --dry-run                Show actions without executing
  --disable-triggers       Include --disable-triggers in pg_dump (requires table ownership)
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
    --include-tables=*) INCLUDE_TABLES="${arg#*=}" ;;
    --no-truncate) TRUNCATE_FIRST="false" ;;
    --mask-sql=*) MASK_SQL="${arg#*=}" ;;
    --outfile=*) OUTFILE="${arg#*=}" ;;
    --dry-run) DRY_RUN="true" ;;
    --disable-triggers) DISABLE_TRIGGERS="true" ;;
    --yes) YES_FLAG="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
  esac
done

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
echo "Include tables:  ${INCLUDE_TABLES}"
echo "Truncate first:  ${TRUNCATE_FIRST}"
echo "Mask SQL:        ${MASK_SQL:-<none>}"
echo "Outfile:         ${OUTFILE}"
echo "Dry run:         ${DRY_RUN}"
echo "Disable triggers:${DISABLE_TRIGGERS}"
echo "-------------------------------------------"

if [ "${YES_FLAG}" != "true" ]; then
  read -r -p "This will migrate data INTO the target database. Continue? [y/N] " yn
  case "$yn" in
    [Yy]*) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# Build pg_dump include/exclude args
PG_DUMP_EXCLUDES=()
PG_DUMP_INCLUDES=()
IFS=',' read -ra SCHEMAS <<< "${EXCLUDE_SCHEMAS}"
IFS=',' read -ra TABLES_EXC <<< "${EXCLUDE_TABLES}"
IFS=',' read -ra TABLES_INC <<< "${INCLUDE_TABLES}"
if [ -n "${INCLUDE_TABLES}" ]; then
  for t in "${TABLES_INC[@]}"; do
    t_trim="$(echo "$t" | xargs || true)"
    [ -n "$t_trim" ] && PG_DUMP_INCLUDES+=( "--table=${t_trim}" )
  done
else
  for s in "${SCHEMAS[@]}"; do
    s_trim="$(echo "$s" | xargs || true)"
    [ -n "$s_trim" ] && PG_DUMP_EXCLUDES+=( "--exclude-schema=${s_trim}" )
  done
  for t in "${TABLES_EXC[@]}"; do
    t_trim="$(echo "$t" | xargs || true)"
    [ -n "$t_trim" ] && PG_DUMP_EXCLUDES+=( "--exclude-table=${t_trim}" )
  done
fi

## Build final dump args (include takes precedence)
DUMP_ARGS=()
if [ -n "${INCLUDE_TABLES}" ]; then
  DUMP_ARGS=("${PG_DUMP_INCLUDES[@]}")
else
  DUMP_ARGS=("${PG_DUMP_EXCLUDES[@]}")
fi

if [ "${DRY_RUN}" = "true" ]; then
  echo "[DRY RUN] Would run:"
  if [ "${DISABLE_TRIGGERS}" = "true" ]; then
    echo "pg_dump \"\$SOURCE_DB_URL\" --format=plain --no-owner --no-privileges --data-only --disable-triggers ${DUMP_ARGS[*]} > \"${OUTFILE}\""
  else
    echo "pg_dump \"\$SOURCE_DB_URL\" --format=plain --no-owner --no-privileges --data-only ${DUMP_ARGS[*]} > \"${OUTFILE}\""
  fi
else
  echo "Dumping source data..."
  if [ "${DISABLE_TRIGGERS}" = "true" ]; then
    pg_dump "$SOURCE_DB_URL" \
      --format=plain \
      --no-owner --no-privileges \
      --data-only \
      --disable-triggers \
      "${DUMP_ARGS[@]}" \
      > "$OUTFILE"
  else
    pg_dump "$SOURCE_DB_URL" \
      --format=plain \
      --no-owner --no-privileges \
      --data-only \
      "${DUMP_ARGS[@]}" \
      > "$OUTFILE"
  fi
  echo "Dump written to: ${OUTFILE}"
fi

if [ "${TRUNCATE_FIRST}" = "true" ]; then
  echo "Preparing TRUNCATE script for target database..."
  TRUNCATE_SQL="$(mktemp)"
  if [ -n "${INCLUDE_TABLES}" ]; then
    # Truncate only included tables
    > "$TRUNCATE_SQL"
    for t in "${TABLES_INC[@]}"; do
      t_trim="$(echo "$t" | xargs || true)"
      [ -z "$t_trim" ] && continue
      schema_part="${t_trim%%.*}"
      table_part="${t_trim#*.}"
      if [ "$schema_part" = "$table_part" ]; then
        schema_part="public"
      fi
      echo "TRUNCATE TABLE \"${schema_part}\".\"${table_part}\" CASCADE;" >> "$TRUNCATE_SQL"
    done
  else
    EXCLUDE_LIST="'pg_catalog','information_schema','pg_toast'"
    # Add user excludes to the list safely
    for s in "${SCHEMAS[@]}"; do
      s_trim="$(echo "$s" | xargs || true)"
      [ -n "$s_trim" ] && EXCLUDE_LIST="${EXCLUDE_LIST},'${s_trim}'"
    done
    # Build table-level excludes for TRUNCATE (schema.table)
    EXCLUDE_TABLES_Q=""
    for t in "${TABLES_EXC[@]}"; do
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
  fi

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

echo "Done."


