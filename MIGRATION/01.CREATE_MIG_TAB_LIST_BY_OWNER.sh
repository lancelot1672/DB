#!/bin/bash
# ============================================================
# CREATE_MIG_TAB_LIST_BY_OWNER.sh
# Read a file of "OWNER TABLE_NAME" (space separated) lines and
# create per-owner table DBADM.MIG_TAB_LIST_{OWNER},
# then insert the table list for each owner.
# Usage: CREATE_MIG_TAB_LIST_BY_OWNER.sh <LIST_FILE>
# ============================================================

if [[ -z "$1" ]] ; then
  echo "Usage: CREATE_MIG_TAB_LIST_BY_OWNER.sh <LIST_FILE>"
  echo "  LIST_FILE : text file, each line = OWNER TABLE_NAME (space separated)"
  exit 1
fi

LIST_FILE="$1"
if [[ ! -f "${LIST_FILE}" ]] ; then
  echo "[FAIL] List file not found: ${LIST_FILE}"
  exit 1
fi

# --- Load environment variables ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [[ -f "${SCRIPT_DIR}/MIG.env" ]] ; then
    . ${SCRIPT_DIR}/MIG.env
else
    echo "[FAIL] MIG.env file not found: ${SCRIPT_DIR}/MIG.env"
    exit 1
fi

SEP="============================================================"

export TMP_CREATE_SQL="${BASE_PATH}/tmp/CREATE_MIG_TAB_LIST_BY_OWNER_CREATE_$$.sql"
export TMP_INSERT_SQL="${BASE_PATH}/tmp/CREATE_MIG_TAB_LIST_BY_OWNER_INSERT_$$.sql"

# --- Log File ---
LOGFILE="${BASE_PATH}/log/CREATE_MIG_TAB_LIST_BY_OWNER_$(date '+%Y%m%d_%H%M%S').log"

# _out: Print to terminal and append to log file
_out() {
    printf "$@"
    printf "$@" >> ${LOGFILE}
}

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

_cleanup() { rm -f ${TMP_CREATE_SQL} ${TMP_INSERT_SQL}; }

# ============================================================
# 1. Build CREATE / INSERT SQL from list file
#    - one CREATE TABLE per distinct OWNER (PK added separately)
#    - table name : DBADM.MIG_TAB_LIST_{OWNER}
#    - SEQ resets per owner, NODE default 2
# ============================================================
_out "%s\n" "$SEP"
_log "Build SQL from list file : ${LIST_FILE}"
_out "%s\n" "$SEP"

# Distinct owners (1st column), keep file order
OWNERS=$(awk 'NF>=2 {print $1}' "${LIST_FILE}" | awk '!seen[$0]++')

if [[ -z "${OWNERS}" ]] ; then
    _fail "No valid 'OWNER TABLE_NAME' lines in ${LIST_FILE}"
    _cleanup
    exit 1
fi

: > ${TMP_CREATE_SQL}
: > ${TMP_INSERT_SQL}

echo "SET ECHO ON FEED ON"  >> ${TMP_CREATE_SQL}
echo ""                     >> ${TMP_CREATE_SQL}
echo "SET ECHO OFF FEED ON" >> ${TMP_INSERT_SQL}
echo ""                     >> ${TMP_INSERT_SQL}

for OWNER in ${OWNERS} ; do
    TAB="DBADM.MIG_TAB_LIST_${OWNER}"

    # --- CREATE TABLE (no inline PK) + ADD CONSTRAINT ---
    {
        echo "-- ---------- ${TAB} ----------"
        echo "CREATE TABLE ${TAB} ("
        echo "    SEQ         NUMBER,"
        echo "    NODE        NUMBER        DEFAULT 2,"
        echo "    OWNER       VARCHAR2(10),"
        echo "    TABLE_NAME  VARCHAR2(50),"
        echo "    USE_YN      VARCHAR2(10),"
        echo "    WHERE_COL   VARCHAR2(30),"
        echo "    PRE1        VARCHAR2(100),"
        echo "    PRE2        VARCHAR2(100)"
        echo ");"
        echo "ALTER TABLE ${TAB} ADD CONSTRAINT PK_MIG_TAB_LIST_${OWNER} PRIMARY KEY (SEQ);"
        echo ""
    } >> ${TMP_CREATE_SQL}

    # --- INSERT rows for this owner (SEQ resets per owner) ---
    awk -v owner="${OWNER}" -v tab="${TAB}" '
        NF>=2 && $1==owner {
            seq++
            printf "INSERT INTO %s (SEQ, OWNER, TABLE_NAME) VALUES (%d, '\''%s'\'', '\''%s'\'');\n", tab, seq, $1, $2
        }
    ' "${LIST_FILE}" >> ${TMP_INSERT_SQL}
done

echo ""        >> ${TMP_INSERT_SQL}
echo "COMMIT;" >> ${TMP_INSERT_SQL}
echo "EXIT;"   >> ${TMP_INSERT_SQL}
echo "EXIT;"   >> ${TMP_CREATE_SQL}

# ============================================================
# 2. Create tables via sqlplus
# ============================================================
_out "%s\n" "$SEP"
_log "Create tables via sqlplus"
_out "%s\n" "$SEP"

for OWNER in ${OWNERS} ; do
    _log "  -> DBADM.MIG_TAB_LIST_${OWNER}"
done

sqlplus -s ${DB_USER}/${DB_PASS} @${TMP_CREATE_SQL} >> ${LOGFILE}

if [[ $? -ne 0 ]] ; then
    _fail "Failed to create per-owner MIG_TAB_LIST tables"
    _cleanup
    exit 1
fi
_ok "Tables created"

# ============================================================
# 3. Preview INSERT rows and confirm
# ============================================================
TOTAL=$(grep -c '^INSERT INTO' ${TMP_INSERT_SQL})

_out "%s\n" "$SEP"
_log "INSERT preview"
_out "%s\n" "$SEP"
_out "  Rows to INSERT : %s\n\n" "${TOTAL}"

_out "  --- TOP 5 ---\n"
grep '^INSERT INTO' ${TMP_INSERT_SQL} | head -5 | while read -r _line ; do _out "  %s\n" "${_line}"; done
_out "\n  --- BOTTOM 5 ---\n"
grep '^INSERT INTO' ${TMP_INSERT_SQL} | tail -5 | while read -r _line ; do _out "  %s\n" "${_line}"; done
_out "\n"

printf "Proceed with INSERT of %s row(s)? [y/N]: " "${TOTAL}"
read -r ANSWER
if [[ "${ANSWER}" != "y" && "${ANSWER}" != "Y" ]] ; then
    _log "INSERT cancelled by user (tables were created, no rows inserted)"
    _cleanup
    exit 0
fi

# ============================================================
# 4. Execute INSERT via sqlplus
# ============================================================
_out "%s\n" "$SEP"
_log "Execute INSERT via sqlplus"
_out "%s\n" "$SEP"

sqlplus -s ${DB_USER}/${DB_PASS} @${TMP_INSERT_SQL} >> ${LOGFILE}

if [[ $? -ne 0 ]] ; then
    _fail "Failed to INSERT rows"
    _cleanup
    exit 1
fi

_cleanup
_ok "Per-owner MIG_TAB_LIST tables created and ${TOTAL} row(s) inserted"
exit 0
