#!/bin/bash
# ============================================================
# 02.EXPDP_META_PARFILE.sh
# Build an EXPDP parfile to export TABLE METADATA for one OWNER.
#   - DB directory list : ./SQL/db_dir.sql
#   - table list        : DBADM.MIG_TAB_LIST_{OWNER} (built by 01 script)
# Usage: 02.EXPDP_META_PARFILE.sh <OWNER> [DIRECTORY_NAME]
# ============================================================

if [[ -z "$1" ]] ; then
  echo "Usage: 02.EXPDP_META_PARFILE.sh <OWNER>"
  echo "  OWNER : owner suffix of DBADM.MIG_TAB_LIST_{OWNER}"
  echo "  (DIRECTORY_NAME is entered interactively after the DB directory list is shown)"
  exit 1
fi

OWNER="$1"

# --- Load environment variables ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [[ -f "${SCRIPT_DIR}/MIG.env" ]] ; then
    . ${SCRIPT_DIR}/MIG.env
else
    echo "[FAIL] MIG.env file not found: ${SCRIPT_DIR}/MIG.env"
    exit 1
fi

SEP="============================================================"
YMD=$(date '+%Y%m%d')
HMS=$(date '+%H%M%S')

MIG_TAB="DBADM.MIG_TAB_LIST_${OWNER}"

export TMP_TAB="${BASE_PATH}/tmp/EXPDP_META_TABLES_$$.dat"
PARFILE="${BASE_PATH}/parfile/EXP_${OWNER}_META_${YMD}_${HMS}.par"

# --- Log File ---
LOGFILE="${BASE_PATH}/log/EXPDP_META_PARFILE_$(date '+%Y%m%d_%H%M%S').log"

# _out: Print to terminal and append to log file
_out() {
    printf "$@"
    printf "$@" >> ${LOGFILE}
}

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

# ============================================================
# 1. Query DB directories (./SQL/db_dir.sql) and select one
# ============================================================
_out "%s\n" "$SEP"
_log "Query DB directories : ${SCRIPT_DIR}/SQL/db_dir.sql"
_out "%s\n" "$SEP"

sqlplus -s ${DB_USER}/${DB_PASS} <<EOF | tee -a ${LOGFILE}
@${SCRIPT_DIR}/SQL/db_dir.sql
EXIT;
EOF

if [[ ${PIPESTATUS[0]} -ne 0 ]] ; then
    _fail "sqlplus failed. check connection."
    exit 1
fi

# Enter DIRECTORY_NAME interactively after reviewing the list above
printf "\n  Enter DIRECTORY_NAME to use : "
read -r DIR_NAME

if [[ -z "${DIR_NAME}" ]] ; then
    _fail "No DIRECTORY_NAME selected"
    exit 1
fi
_log "Selected directory : ${DIR_NAME}"

# ============================================================
# 2. Query OWNER, TABLE_NAME list from MIG_TAB_LIST_{OWNER}
# ============================================================
_out "%s\n" "$SEP"
_log "Query table list from ${MIG_TAB}"
_out "%s\n" "$SEP"

sqlplus -s ${DB_USER}/${DB_PASS} <<EOF > ${TMP_TAB}
SET HEAD OFF FEED OFF PAGES 0 LINES 300 TRIM ON
SET TRIMSPOOL ON
SELECT OWNER || '.' || TABLE_NAME
  FROM ${MIG_TAB}
 WHERE NVL(USE_YN, 'Y') <> 'N'
 ORDER BY SEQ;
EOF

if [[ $? -ne 0 ]] ; then
    _fail "sqlplus failed querying ${MIG_TAB}"
    rm -f ${TMP_TAB}
    exit 1
fi

# Remove empty lines
egrep -v "^$" ${TMP_TAB} > ${TMP_TAB}.tmp
mv ${TMP_TAB}.tmp ${TMP_TAB}

_total=$(cat ${TMP_TAB} | wc -l | tr -d ' ')
if [[ ${_total} -eq 0 ]] ; then
    _fail "No rows in ${MIG_TAB}"
    rm -f ${TMP_TAB}
    exit 1
fi

# ============================================================
# 3. Build EXPDP parfile (metadata only)
# ============================================================
_out "%s\n" "$SEP"
_log "Build parfile : ${PARFILE}  (tables: ${_total})"
_out "%s\n" "$SEP"

{
    echo "userid=${DB_USER}/${DB_PASS}"
    echo "directory=${DIR_NAME}"
    echo "dumpfile=${OWNER}_META_${YMD}_${HMS}.dmp"
    echo "logfile=EXP_${OWNER}_META_${YMD}_${HMS}.log"
    echo "content=metadata_only"
    echo "exclude=INDEX,GRANT,CONSTRAINT,STATISTICS"
    awk '{ if (NR==1) printf "tables=%s", $0; else printf ",\n       %s", $0 } END { if (NR>0) print "" }' ${TMP_TAB}
    echo "logtime=all"
    echo "cluster=n"
} > ${PARFILE}

rm -f ${TMP_TAB}

if [[ ! -s "${PARFILE}" ]] ; then
    _fail "Failed to write parfile"
    exit 1
fi

# --- Show generated parfile ---
_out "\n%s\n" "$SEP"
_out "  Generated parfile : %s\n" "${PARFILE}"
_out "%s\n" "$SEP"
while IFS= read -r _line ; do _out "  %s\n" "${_line}"; done < ${PARFILE}
_out "%s\n\n" "$SEP"

_ok "EXPDP META parfile created : ${PARFILE}"
_out "  Run with : expdp parfile=%s\n" "${PARFILE}"
exit 0
