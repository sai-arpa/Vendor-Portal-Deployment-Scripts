#!/bin/bash
# =============================================================================
# Backend Deployment Script
# Usage: ./deploy-backend.sh [config_file] [env_file]
# =============================================================================

set -e
# Prevent concurrent deployments
LOCK_FILE="/tmp/backend-deploy.lock"

exec 200>"$LOCK_FILE"
flock -n 200 || {
    echo "Another deployment is already running"
    echo "If no deployment is running, remove the lock with: rm $LOCK_FILE"
    exit 1
}

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/config.sh}"
ENV_FILE="${2:-.env.backend}"

if [[ "$ENV_FILE" != /* ]]; then
    ENV_FILE="$SCRIPT_DIR/$ENV_FILE"
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file $CONFIG_FILE not found."
    exit 1
fi
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: Env file $ENV_FILE not found."
    exit 1
fi

source "$CONFIG_FILE"

# Setup logging
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/backend-$TIMESTAMP.log"
MIGRATION_LOG="$LOG_DIR/migration-$TIMESTAMP.txt"
DEPLOYMENT_HISTORY_DIR="/opt/deployment/deployment-history"


exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
log()         { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
log_success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ $1"; }
log_error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $1"; }
# =============================================================================

# --- Rollback Function ---
rollback() {
    local BACKUP_DIR="$DEPLOY_BACKEND/../backend_backup_$TIMESTAMP"
    log_error "Initiating rollback..."
    if [ -d "$BACKUP_DIR" ]; then
        log_error "Restoring previous deployment from backup..."
        sudo rsync -av --delete \
            --exclude='.env' \
            --exclude='wwwroot/' \
            "$BACKUP_DIR/" "$DEPLOY_BACKEND/"
        log "Setting deployment ownership..."
        sudo chown -R www-data:www-data "$DEPLOY_BACKEND"
        log_success "Ownership changed to www-data"
        sudo systemctl restart "$BACKEND_SERVICE"
        sleep 10
        log_success "Rollback complete — previous binary restored"
    else
        log_error "No backup found — cannot rollback automatically"
        log_error "Manual intervention required"
    fi
}

# --- Retry the migration verifier until it passes or time runs out ---
# It exits 0/1 and can't tell "still migrating" apart from "genuinely failed",
# so we retry on a fixed interval until it passes or we hit the max wait.
MIGRATION_VERIFY_MAX_WAIT="${MIGRATION_VERIFY_MAX_WAIT:-120}"
MIGRATION_VERIFY_INTERVAL="${MIGRATION_VERIFY_INTERVAL:-10}"

wait_for_migration_verifier() {
    local elapsed=0
    local attempt=0

    log "Checking migration verifier every ${MIGRATION_VERIFY_INTERVAL}s (up to ${MIGRATION_VERIFY_MAX_WAIT}s)..."

    while [ "$elapsed" -lt "$MIGRATION_VERIFY_MAX_WAIT" ]; do
        attempt=$((attempt + 1))

        MIGRATION_CHECK=$(sudo -u www-data dotnet "$DEPLOY_BACKEND/eProcurement.MigrationVerifier.dll" 2>&1)
        MIGRATION_EXIT=$?

        if [ "$MIGRATION_EXIT" -eq 0 ]; then
            log_success "Migration verifier passed after ${elapsed}s (attempt $attempt)"
            return 0
        fi

        log "Attempt $attempt (${elapsed}s elapsed): verifier not passing yet — retrying in ${MIGRATION_VERIFY_INTERVAL}s"
        sleep "$MIGRATION_VERIFY_INTERVAL"
        elapsed=$((elapsed + MIGRATION_VERIFY_INTERVAL))
    done

    log_error "Migration verifier did not pass within ${MIGRATION_VERIFY_MAX_WAIT}s (last exit code: $MIGRATION_EXIT)"
    return 1
}

# --- Cleanup trap (always runs on exit) ---
trap 'log "Cleaning up..."; rm -rf "$CLONE_DIR/backend"; ssh-agent -k > /dev/null 2>&1; log "Cleanup done"' EXIT

log "=========================================="
log "  BACKEND DEPLOYMENT STARTED"
log "  Log:            $LOG_FILE"
log "  Migration log:  $MIGRATION_LOG"
log "=========================================="

# --- Step 1: SSH Agent ---
log "Setting up SSH agent..."
eval "$(ssh-agent -s)" > /dev/null
ssh-add "$SSH_KEY" || { log_error "Failed to load SSH key: $SSH_KEY"; exit 1; }
log_success "SSH agent ready"

# --- Step 2: Clone repo ---
log "Cloning backend repo (branch: $BRANCH_BACKEND)..."
rm -rf "$CLONE_DIR/backend"
mkdir -p "$CLONE_DIR/backend"
git clone --branch "$BRANCH_BACKEND" --single-branch "$GIT_BACKEND" "$CLONE_DIR/backend"
log_success "Repo cloned"

DEPLOY_COMMIT=$(git -C "$CLONE_DIR/backend" rev-parse HEAD)
DEPLOY_DATE=$(date '+%Y-%m-%d %H:%M:%S %Z')

# --- Step 2.5: Pin .NET 8 SDK ---
log "Pinning .NET SDK to version 8..."
echo '{"sdk":{"version":"8.0.0","rollForward":"latestMinor"}}' > "$CLONE_DIR/backend/global.json"
log_success "SDK pinned to .NET 8"

# --- Step 3: Build and publish ---
log "Building and publishing .NET app..."
cd "$CLONE_DIR/backend/Api"
dotnet publish -c Release -o publish
log_success "Build successful"

# --- Step 3.5: Backup current deployment ---
log "Backing up current deployment..."
BACKUP_DIR="$DEPLOY_BACKEND/../backend_backup_$TIMESTAMP"
if [ -d "$DEPLOY_BACKEND" ]; then
    sudo rsync -av \
       --exclude='wwwroot/' \
       --exclude='.env' \
       "$DEPLOY_BACKEND/" "$BACKUP_DIR/"
    log_success "Backup saved to: $BACKUP_DIR"
else
    log "No existing deployment found — skipping backup"
fi

# --- Step 4: Deploy files ---
log "Deploying to $DEPLOY_BACKEND..."
sudo mkdir -p "$DEPLOY_BACKEND"
sudo rsync -av --delete \
    --exclude='.env' \
    --exclude='wwwroot/' \
    "$CLONE_DIR/backend/Api/publish/" "$DEPLOY_BACKEND/"
log_success "Files deployed"
log "Setting deployment ownership..."
sudo chown -R www-data:www-data "$DEPLOY_BACKEND"
log_success "Deployment ownership updated to www-data"

# --- Step 5: Copy .env ---
log "Copying backend .env..."
sudo cp "$ENV_FILE" "$DEPLOY_BACKEND/.env"
sudo chown www-data:www-data "$DEPLOY_BACKEND/.env"
sudo chmod 600 "$DEPLOY_BACKEND/.env"
log_success ".env copied"

# --- Step 6: Restart service ---
log "Restarting $BACKEND_SERVICE..."
sudo systemctl restart "$BACKEND_SERVICE"

# --- Step 7: Service status check ---
log "Checking service status..."

set +e
SERVICE_STATUS=$(sudo systemctl is-active "$BACKEND_SERVICE")
SERVICE_CHECK_FAILED=false

if [ "$SERVICE_STATUS" != "active" ]; then
    SERVICE_CHECK_FAILED=true
    log_error "Service is not active (status: $SERVICE_STATUS)"
    log_error "Last 30 lines of service logs:"
    sudo journalctl -u "$BACKEND_SERVICE" -n 30 --no-pager
else
    log_success "Service is active"
fi
set -e

# --- Step 8: Migration Verifier (retried, not a single shot) ---
set +e
wait_for_migration_verifier
MIGRATION_CHECK_FAILED_CODE=$?
set -e

echo "$MIGRATION_CHECK" > "$MIGRATION_LOG"
log "Migration verifier output saved to: $MIGRATION_LOG"

MIGRATION_CHECK_FAILED=false

if [ "$MIGRATION_CHECK_FAILED_CODE" -ne 0 ]; then
    MIGRATION_CHECK_FAILED=true
    log_error "Migration verification failed — see $MIGRATION_LOG"
    echo "$MIGRATION_CHECK" | while IFS= read -r line; do
        log_error "  $line"
    done
else
    log_success "All migrations applied successfully"
fi

# --- Step 9: API Health Check (retried — app may still be finishing startup
#     right after migrations verify) ---
log "Checking API health..."

API_HEALTH_URL="${API_HEALTH_URL:-http://localhost:${BACKEND_PORT}/api/config/portal-setting}"
API_HEALTH_MAX_WAIT="${API_HEALTH_MAX_WAIT:-30}"
API_HEALTH_INTERVAL="${API_HEALTH_INTERVAL:-5}"

elapsed=0
HTTP_SUCCESS=""
set +e
while [ "$elapsed" -lt "$API_HEALTH_MAX_WAIT" ]; do
    HTTP_RESPONSE=$(curl -s --max-time 5 "$API_HEALTH_URL")
    HTTP_SUCCESS=$(echo "$HTTP_RESPONSE" | grep -o '"success":true')

    if [ -n "$HTTP_SUCCESS" ]; then
        break
    fi

    log "API not ready yet (${elapsed}s elapsed) — retrying in ${API_HEALTH_INTERVAL}s"
    sleep "$API_HEALTH_INTERVAL"
    elapsed=$((elapsed + API_HEALTH_INTERVAL))
done
set -e

API_CHECK_FAILED=false

if [ -z "$HTTP_SUCCESS" ]; then
    API_CHECK_FAILED=true

    log_error "API health check failed after ${API_HEALTH_MAX_WAIT}s ($API_HEALTH_URL). Last response: $HTTP_RESPONSE"
    sudo journalctl -u "$BACKEND_SERVICE" -n 30 --no-pager
else
    log_success "API health check passed after ${elapsed}s"
fi

# --- Step 10: Final Deployment Validation ---
if [ "$SERVICE_CHECK_FAILED" = true ] || \
   [ "$MIGRATION_CHECK_FAILED" = true ] || \
   [ "$API_CHECK_FAILED" = true ]; then

    log_error "Deployment validation failed"

    [ "$SERVICE_CHECK_FAILED" = true ] && log_error " - Service check failed"
    [ "$MIGRATION_CHECK_FAILED" = true ] && log_error " - Migration verification failed (see $MIGRATION_LOG)"
    [ "$API_CHECK_FAILED" = true ] && log_error " - API health check failed"

    rollback
    exit 1
fi

log_success "All deployment validations passed"

# --- Cleanup old backups (keep last 3) ---
log "Cleaning old backups..."
ls -dt "$DEPLOY_BACKEND/../backend_backup_"* 2>/dev/null | tail -n +4 | xargs sudo rm -rf 2>/dev/null || true
log_success "Old backups cleaned"

log "=========================================="
log_success "BACKEND DEPLOYMENT COMPLETED"
log "  Log saved to:       $LOG_FILE"
log "  Migration log:      $MIGRATION_LOG"
log "=========================================="