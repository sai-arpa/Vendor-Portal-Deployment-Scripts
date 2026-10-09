#!/bin/bash
# =============================================================================
# Central Configuration
# Edit this file to change deployment settings
# =============================================================================

# --- SSH / Git ---
SSH_KEY="$HOME/.ssh/keys/github-key"
GIT_BACKEND="git@github.com:Force-Intellect/eProcurement.git"
GIT_FRONTEND="git@github.com:Force-Intellect/e-procurement-user-interface.git"
GIT_GLOBALDATA="git@github.com:Force-Intellect/eProcurementDatabase.git"
GIT_ASSETS="git@github.com:Force-Intellect/E-Procurement-Assets.git"

BRANCH_BACKEND="Staging"
BRANCH_FRONTEND="staging"
BRANCH_GLOBALDATA="Develop"
BRANCH_ASSETS="Real"

# ------------------ Deployment Paths ------------------
DEPLOY_BACKEND="/var/www/eProcurement/backend"
DEPLOY_FRONTEND="/var/www/eProcurement/frontend/eProcurement-frontend"
DEPLOY_ASSETS="/var/www/eProcurement/frontend/eProcurement-assets"

# ------------------ Service Names ------------------
BACKEND_SERVICE="eProcurementapi.service"

# ------------------ Temp Clone Directory ------------------
CLONE_DIR="/tmp/deployment"

# ------------------ Logs Directory ------------------
LOG_DIR="/opt/deployment/logs"


# ------------------ GlobalData SQL file path inside repo ------------------
GLOBALDATA_SQL_FILES="SqlQueries/GlobalData.sql SqlQueries/ReportGlobalData.sql"

# ------------------ Database (for globaldata script) ------------------
DB_NAME="eProcurement_Reals_Staging_LH_Integrated"
DB_USER="postgres"

# ------
BACKEND_PORT=5000
