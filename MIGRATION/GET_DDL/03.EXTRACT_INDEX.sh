#!/bin/bash
# ============================================================
# 03.EXTRACT_INDEX.sh
# Extract INDEX DDL for the tables in DBADM.MIG_TAB_LIST_{OWNER}.
#   Pass 1 : generate GET_DDL SELECT statements (get_ddl file)
#   Pass 2 : run them and spool the actual DDL
#   LOCAL partitioned index : partition list is removed, only LOCAL kept.
#   TBS_IND of ${MIG_TAB} set : LOCAL index -> ... TABLESPACE "TBS_IND" LOCAL
#                               other index -> ... TABLESPACE "TBS_IND";
#   (SEGMENT_ATTRIBUTES is removed, so the source tablespace never appears)
# Usage: 03.EXTRACT_INDEX.sh <OWNER>
# ============================================================

if [[ -z "$1" ]] ; then
  echo "Usage: 03.EXTRACT_INDEX.sh <OWNER>"
  echo "  OWNER : owner suffix of DBADM.MIG_TAB_LIST_{OWNER}"
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

LABEL="INDEX"
MIG_TAB="DBADM.MIG_TAB_LIST_${OWNER}"

GEN_SQL="${BASE_PATH}/tmp/get_ddl_${OWNER}_${LABEL}_$$.sql"
DDL_OUT="${BASE_PATH}/ddl/${OWNER}_${LABEL}_${YMD}_${HMS}.sql"

# --- Log File ---
LOGFILE="${BASE_PATH}/log/EXTRACT_${LABEL}_$(date '+%Y%m%d_%H%M%S').log"

# _out: Print to terminal and append to log file
_out() {
    printf "$@"
    printf "$@" >> ${LOGFILE}
}

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

# ============================================================
# Target tablespace : MAX(TBS_IND) of ${MIG_TAB}
#   (empty, or column missing in an old list table -> not set)
# ============================================================
TBS_IND=$(sqlplus -s ${DB_USER}/${DB_PASS} <<_EOF | tr -d '[:space:]'
set pagesize 0 feedback off heading off verify off
SELECT MAX(TBS_IND) FROM ${MIG_TAB};
exit
_EOF
)
[[ "${TBS_IND}" =~ ^[A-Z][A-Z0-9_\$#]*$ ]] || TBS_IND=""

if [[ -n "${TBS_IND}" ]] ; then
    LOCAL_REPL=" TABLESPACE \"${TBS_IND}\" LOCAL"
    ELSE_SELECT="'SELECT REGEXP_REPLACE(DBMS_METADATA.GET_DDL(''INDEX'',''' || I.INDEX_NAME || ''',''' || I.OWNER || '''),''\s*;\s*$'','' TABLESPACE \"${TBS_IND}\";'') AS DDL FROM DUAL;'"
else
    LOCAL_REPL=" LOCAL"
    ELSE_SELECT="'SELECT DBMS_METADATA.GET_DDL(''INDEX'',''' || I.INDEX_NAME || ''',''' || I.OWNER || ''') AS DDL FROM DUAL;'"
fi

# ============================================================
# Pass 1. Generate GET_DDL SELECT statements -> ${GEN_SQL}
#   - DBA_INDEXES is joined on (TABLE_OWNER, TABLE_NAME)
#   - GET_DDL uses the index OWNER
# ============================================================
_out "%s\n" "$SEP"
_log "Pass 1: generate GET_DDL statements (${LABEL}) from ${MIG_TAB}"
_log "Target INDEX TABLESPACE : ${TBS_IND:-(not set : tablespace clause removed)}"
_out "%s\n" "$SEP"

sqlplus -s ${DB_USER}/${DB_PASS} <<_EOF
set pagesize 0
set linesize 1000
set long 9999
set feedback off
set heading off
set echo off
set verify off
set trimspool on

spool ${GEN_SQL}
-- LOCAL index : LOCAL (PARTITION ...) -> [TABLESPACE "TBS_IND"] LOCAL (partitions follow the table)
SELECT DISTINCT
       CASE WHEN P.LOCALITY = 'LOCAL' THEN
            'SELECT REGEXP_REPLACE(DBMS_METADATA.GET_DDL(''INDEX'',''' || I.INDEX_NAME || ''',''' || I.OWNER || '''),'
            || '''\s+LOCAL\s*\(.*\)'',''${LOCAL_REPL}'',1,1,''n'') AS DDL FROM DUAL;'
       ELSE
            ${ELSE_SELECT}
       END
  FROM DBA_INDEXES I
  LEFT JOIN DBA_PART_INDEXES P
    ON P.OWNER = I.OWNER AND P.INDEX_NAME = I.INDEX_NAME
 WHERE (I.TABLE_OWNER, I.TABLE_NAME) IN (SELECT OWNER, TABLE_NAME FROM ${MIG_TAB} WHERE NVL(USE_YN, 'Y') <> 'N')
 AND I.INDEX_NAME NOT LIKE 'SYS%'
 ORDER BY 1;
spool off
exit
_EOF

if [[ ! -s "${GEN_SQL}" ]] ; then
    _fail "No ${LABEL} found (empty get_ddl file): ${GEN_SQL}"
    rm -f ${GEN_SQL}
    exit 1
fi

# Remove empty lines from generated script
egrep -v "^$" ${GEN_SQL} > ${GEN_SQL}.tmp
mv ${GEN_SQL}.tmp ${GEN_SQL}
_cnt=$(grep -c 'GET_DDL' ${GEN_SQL})
_ok "Generated ${_cnt} statement(s) : ${GEN_SQL}"

# ============================================================
# Pass 2. Run generated statements -> spool DDL to ${DDL_OUT}
# ============================================================
_out "%s\n" "$SEP"
_log "Pass 2: extract DDL -> ${DDL_OUT}"
_out "%s\n" "$SEP"

sqlplus -s ${DB_USER}/${DB_PASS} <<_EOF
set long 9999
set lines 700
set pagesize 10000
set linesize 700
set feedback off
set heading off
col ddl format a7000

execute dbms_metadata.set_transform_param (dbms_metadata.session_transform,'SQLTERMINATOR',true);
execute dbms_metadata.set_transform_param (dbms_metadata.session_transform,'PRETTY',false);
execute dbms_metadata.set_transform_param (dbms_metadata.session_transform,'STORAGE',false);
execute dbms_metadata.set_transform_param (dbms_metadata.session_transform,'SEGMENT_ATTRIBUTES',false);

spool ${DDL_OUT}
@${GEN_SQL}
spool off
exit
_EOF

if [[ ! -s "${DDL_OUT}" ]] ; then
    _fail "Failed to extract ${LABEL} DDL: ${DDL_OUT}"
    rm -f ${GEN_SQL}
    exit 1
fi

rm -f ${GEN_SQL}

# Readability: strip trailing spaces + remove blank lines
#   (vi)  :%s/\s\+$//    :g/^\s*$/d
sed -i -e 's/[[:space:]]\{1,\}$//' -e '/^[[:space:]]*$/d' ${DDL_OUT}

_ok "${LABEL} DDL extracted (${_cnt} object(s)) : ${DDL_OUT}"
exit 0
