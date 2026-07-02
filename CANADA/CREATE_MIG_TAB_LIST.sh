#!/bin/bash
# ============================================================
# CREATE_MIG_TAB_LIST.sh
# Create DBADM.MIG_TAB_LIST table
# Usage: CREATE_MIG_TAB_LIST.sh
# ============================================================

# --- Load environment variables ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [[ -f "${SCRIPT_DIR}/.env" ]] ; then
    . ${SCRIPT_DIR}/.env
else
    echo "[FAIL] .env file not found: ${SCRIPT_DIR}/.env"
    exit 1
fi

SEP="============================================================"

# --- Log File ---
LOGFILE="${BASE_PATH}/log/CREATE_MIG_TAB_LIST_$(date '+%Y%m%d_%H%M%S').log"

# _out: Print to terminal and append to log file
_out() {
    printf "$@"
    printf "$@" >> ${LOGFILE}
}

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

# ============================================================
# Create table DBADM.MIG_TAB_LIST
#   SEQ        : sequence no. (front)
#   NODE       : node no. (front, default 2)
#   OWNER      : schema name        VARCHAR2(10)
#   TABLE_NAME : table name         VARCHAR2(50)
#   USE_YN     : use flag           VARCHAR2(10)
#   WHERE_COL  : where column (single column for range condition)
#   PRE1       : predicate 1 (>=)
#   PRE2       : predicate 2 (<)
# ============================================================
_out "%s\n" "$SEP"
_log "Create table DBADM.MIG_TAB_LIST"
_out "%s\n" "$SEP"

sqlplus -s ${DB_USER}/${DB_PASS} <<EOF >> ${LOGFILE}
SET ECHO ON FEED ON

CREATE TABLE DBADM.MIG_TAB_LIST (
    SEQ         NUMBER,
    NODE        NUMBER        DEFAULT 2,
    OWNER       VARCHAR2(10),
    TABLE_NAME  VARCHAR2(50),
    USE_YN      VARCHAR2(10),
    WHERE_COL   VARCHAR2(30),
    PRE1        VARCHAR2(100),
    PRE2        VARCHAR2(100),
    CONSTRAINT PK_MIG_TAB_LIST PRIMARY KEY (SEQ)
);

EXIT;
EOF

if [[ $? -ne 0 ]] ; then
    _fail "Failed to create DBADM.MIG_TAB_LIST"
    exit 1
fi

_ok "DBADM.MIG_TAB_LIST created"
exit 0
