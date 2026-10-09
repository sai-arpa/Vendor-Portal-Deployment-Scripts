#!/bin/bash
# =============================================================================
# GlobalData SQL Script Runner
# Usage: ./run-globaldata.sh <env-file>
#
# Examples:
#   ./run-globaldata.sh .env.backend           # staging
#   ./run-globaldata.sh .env.backend.prod      # production
#
# Runs in this order:
#   1. GlobalData/GlobalData.sql
#   2. GlobalData/ReportGlobalData.sql
#   3. ClientScripts/<CLIENT_SCRIPT> (configured below)
# =============================================================================

set -e

# --- Client script to run from ClientScripts/ folder ---
# Change this when deploying for a different client
CLIENT_SCRIPT="RealDeals.sql"

# =============================================================================

# --- Validate argument ---
if [ -z "$1" ]; then
    echo "Usage: ./run-globaldata.sh <env-file>"
    echo ""
    echo "Examples:"
    echo "  ./run-globaldata.sh .env.backend"
    echo "  ./run-globaldata.sh .env.backend.prod"
    exit 1
fi

ENV_FILE="$1"

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Resolve env file path — allow relative or absolute
if [[ "$ENV_FILE" != /* ]]; then
    ENV_FILE="$SCRIPT_DIR/$ENV_FILE"
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Env file not found: $ENV_FILE"
    exit 1
fi

# --- Parse DB connection from env file ---
DB_CONN=$(grep "^ConnectionStrings__Default=" "$ENV_FILE" | cut -d'=' -f2-)

if [ -z "$DB_CONN" ]; then
    echo "❌ ConnectionStrings__Default not found in $ENV_FILE"
    exit 1
fi

# Extract database name from connection string for display
DB_DISPLAY=$(echo "$DB_CONN" | grep -oiP '(?<=Database=)[^;]+' || echo "unknown")

# Setup logging
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/globaldata-$TIMESTAMP.log"

exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
log()         { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
log_success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ $1"; }
log_error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $1"; }
# =============================================================================

# Cleanup trap
trap 'rm -rf "$CLONE_DIR/globaldata"; ssh-agent -k > /dev/null 2>&1' EXIT

log "=========================================="
log "  GLOBALDATA SQL RUNNER STARTED"
log "  Env file:   $ENV_FILE"
log "  Database:   $DB_DISPLAY"
log "  Client:     $CLIENT_SCRIPT"
log "  Log:        $LOG_FILE"
log "=========================================="

# --- Step 1: SSH Agent ---
log "Setting up SSH agent..."
eval "$(ssh-agent -s)" > /dev/null
ssh-add "$SSH_KEY" || { log_error "Failed to load SSH key: $SSH_KEY"; exit 1; }
log_success "SSH agent ready"

# --- Step 2: Clone globaldata repo ---
log "Cloning globaldata repo (branch: $BRANCH_GLOBALDATA)..."
rm -rf "$CLONE_DIR/globaldata"
mkdir -p "$CLONE_DIR/globaldata"
git clone --branch "$BRANCH_GLOBALDATA" --single-branch "$GIT_GLOBALDATA" "$CLONE_DIR/globaldata"
log_success "Repo cloned"

# --- Step 3: Define SQL files to run in order ---
# GlobalData files always run first, client script runs last
GLOBALDATA_FILES=(
    "GlobalData/GlobalData.sql"
    "GlobalData/ReportGlobalData.sql"
)
CLIENT_FILE="ClientScripts/$CLIENT_SCRIPT"

ALL_FILES=("${GLOBALDATA_FILES[@]}" "$CLIENT_FILE")

# --- Step 4: Verify all files exist BEFORE running any ---
log "Verifying SQL files..."
for SQL_NAME in "${ALL_FILES[@]}"; do
    SQL_PATH="$CLONE_DIR/globaldata/$SQL_NAME"
    if [ ! -f "$SQL_PATH" ]; then
        log_error "SQL file not found: $SQL_NAME"
        log_error "Searching repo for '$(basename "$SQL_NAME")'..."
        FOUND=$(find "$CLONE_DIR/globaldata" -iname "$(basename "$SQL_NAME")" 2>/dev/null)
        if [ -n "$FOUND" ]; then
            log_error "Found it here instead — update the script to match:"
            echo "$FOUND" | while IFS= read -r f; do
                log_error "  ${f#$CLONE_DIR/globaldata/}"
            done
        else
            log_error "File does not exist anywhere in the repo (branch: $BRANCH_GLOBALDATA)"
        fi
        exit 1
    fi
    log_success "Found: $SQL_NAME"
done

# --- Step 5: Run each SQL file in order ---
for SQL_NAME in "${ALL_FILES[@]}"; do
    SQL_PATH="$CLONE_DIR/globaldata/$SQL_NAME"
    TMP_FILE="/tmp/globaldata_run_$(basename "$SQL_NAME")"

    log "---"
    log "Running: $SQL_NAME"

    cp "$SQL_PATH" "$TMP_FILE"
    chmod 644 "$TMP_FILE"

    set +e
    sudo -u "$DB_USER" psql -d "$DB_DISPLAY" -f "$TMP_FILE" 2>&1
    SQL_EXIT=$?
    set -e

    rm -f "$TMP_FILE"

    if [ $SQL_EXIT -ne 0 ]; then
        log_error "$SQL_NAME failed with exit code $SQL_EXIT"
        exit 1
    fi

    log_success "$SQL_NAME executed successfully"
done

log "=========================================="
log_success "GLOBALDATA SQL RUNNER COMPLETED"
log "  Database:     $DB_DISPLAY"
log "  Client:       $CLIENT_SCRIPT"
log "  Log saved to: $LOG_FILE"
log "=========================================="