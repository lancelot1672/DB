#!/bin/bash
# ============================================================
# 01.RUN_DATA_VERIFY.sh
# Pre-migration data verify (spec : DATA_MIG_VERIFY_PLAN.md)
#
#   Checks that the data already migrated (PRE phase) has not changed :
#   SUM() of every NUMBER column is taken on ASIS and on TOBE and the two are compared.
#
#   - target tables : DBADM.DBM_MIG_MSTR of the TOBE DB
#                     MSTR_ID = VERIFY.env MSTR_ID , MIG_YN = 'Y' , MIG_TYPE IN (MIG_TYPE_LIST)
#   - connects to ASIS and TOBE separately (no DB LINK) : Oracle (sqlplus) / Tibero (tbsql) may be mixed
#   - columns : TOBE ALL_TAB_COLUMNS , DATA_TYPE IN (NUM_DATA_TYPES) , COLUMN_ID order ,
#               first MAX_NUM_COLS columns (default 10)
#               TRANS_YN = 'Y' -> DBADM.DBM_MIG_COL_MAP gives the ASIS column name
#                 RENAME -> SRC_COL , ADD -> no ASIS source , the column is written as SKIP
#               a column missing on ASIS (or not a number there) is written as SKIP
#   - condition : MIG_TYPE = PRE  -> WHERE {COL_CONDITION} >= 'PRE1' AND {COL_CONDITION} < 'PRE2'
#                                    (operators : PRE1_OP / PRE2_OP)
#                 MIG_TYPE = DDAY -> no condition (whole table)
#                 COL_CONDITION holds the ASIS column name (same as the migration SQL) ;
#                 on TOBE the renamed name from DBM_MIG_COL_MAP is used when TRANS_YN = 'Y'
#   - result : DBADM.DBM_MIG_PRE_DATA_VERIFY on the TOBE DB , 1 row = 1 column
#              STATUS  일치 / 불일치 / SKIP / ERROR   (COUNT_CHECK=Y adds a *ROW_COUNT* row per table)
#              every run gets a new RUN_ID (MAX + 1) , earlier runs are kept
#   - WORKER_DEGREE tables at a time , smallest TAB_SIZE first ; plain SQL only (no PL/SQL)
#   - read only on both DBs except the INSERT of the result rows on TOBE
#
# Usage: 01.RUN_DATA_VERIFY.sh                       verify every target table and load the result
#        01.RUN_DATA_VERIFY.sh -t OWNER.TABLE[,...]  only these TOBE tables
#        01.RUN_DATA_VERIFY.sh -n                    dry run : build the SQL under cmd/ , run nothing
#        01.RUN_DATA_VERIFY.sh -r [RUN_ID]           report a past run (default : the latest one)
#        01.RUN_DATA_VERIFY.sh -y                    no confirmation prompt (batch / crontab)
#        01.RUN_DATA_VERIFY.sh -h                    this help
# ============================================================

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

OPT_TABLES=""
OPT_DRYRUN="N"
OPT_REPORT="N"
OPT_RUN_ID=""
OPT_YES="N"

while [[ $# -gt 0 ]] ; do
    case "$1" in
        -t|--table)   OPT_TABLES="$2" ; shift 2 ;;
        -n|--dry-run) OPT_DRYRUN="Y" ; shift ;;
        -r|--report)  OPT_REPORT="Y"
                      if [[ -n "$2" && "$2" != -* ]] ; then OPT_RUN_ID="$2" ; shift ; fi
                      shift ;;
        -y|--yes)     OPT_YES="Y" ; shift ;;
        -h|--help)    sed -n '2,/^# =\{10,\}$/p' "$0" | sed 's/^#\{1,\} \{0,1\}//' ; exit 0 ;;
        *)            echo "[FAIL] unknown option: $1  (-h for help)" ; exit 1 ;;
    esac
done

# ============================================================
# 1. Environment
# ============================================================
if [[ -f "${SCRIPT_DIR}/VERIFY.env" ]] ; then
    . "${SCRIPT_DIR}/VERIFY.env"
else
    echo "[FAIL] VERIFY.env not found: ${SCRIPT_DIR}/VERIFY.env  (cp VERIFY.env.example VERIFY.env)"
    exit 1
fi

# _client <ORACLE|TIBERO> : client binary of a DB type
_client() {
    case "$1" in
        ORACLE) echo "sqlplus" ;;
        TIBERO) echo "tbsql"   ;;
        *)      echo ""        ;;
    esac
}

ASIS_CLIENT=$(_client "${ASIS_DB_TYPE}")
TOBE_CLIENT=$(_client "${TOBE_DB_TYPE}")

[[ -z "${ASIS_CLIENT}" ]] && { echo "[FAIL] ASIS_DB_TYPE must be ORACLE or TIBERO (current: '${ASIS_DB_TYPE}')" ; exit 1 ; }
[[ -z "${TOBE_CLIENT}" ]] && { echo "[FAIL] TOBE_DB_TYPE must be ORACLE or TIBERO (current: '${TOBE_DB_TYPE}')" ; exit 1 ; }

for _c in "${ASIS_CLIENT}" "${TOBE_CLIENT}" ; do
    command -v "${_c}" > /dev/null 2>&1 || { echo "[FAIL] ${_c} not found in PATH" ; exit 1 ; }
done

[[ -z "${MSTR_ID}"   ]] && { echo "[FAIL] MSTR_ID must be set in VERIFY.env"   ; exit 1 ; }
[[ -z "${BASE_PATH}" ]] && { echo "[FAIL] BASE_PATH must be set in VERIFY.env" ; exit 1 ; }

ASIS_CONN="${ASIS_DB_USER}/${ASIS_DB_PASS}${ASIS_DB_TNS:+@${ASIS_DB_TNS}}"
TOBE_CONN="${TOBE_DB_USER}/${TOBE_DB_PASS}${TOBE_DB_TNS:+@${TOBE_DB_TNS}}"

RESULT_TAB="DBADM.DBM_MIG_PRE_DATA_VERIFY"
MSTR_TAB="DBADM.DBM_MIG_MSTR"
COLMAP_TAB="DBADM.DBM_MIG_COL_MAP"

# --- defaults ---
MIG_TYPE_LIST="${MIG_TYPE_LIST:-PRE}"
MAX_NUM_COLS="${MAX_NUM_COLS:-10}"
COUNT_CHECK="${COUNT_CHECK:-Y}"
WORKER_DEGREE="${WORKER_DEGREE:-1}"
PARALLEL_DEGREE="${PARALLEL_DEGREE:-2}"
PRE_COND_COL="${PRE_COND_COL:-COL_CONDITION}"
NUM_DATA_TYPES="${NUM_DATA_TYPES:-NUMBER}"

[[ "${MAX_NUM_COLS}"    =~ ^[0-9]+$ ]] || MAX_NUM_COLS=10
[[ "${WORKER_DEGREE}"   =~ ^[0-9]+$ ]] || WORKER_DEGREE=1
[[ "${PARALLEL_DEGREE}" =~ ^[0-9]+$ ]] || PARALLEL_DEGREE=2
[[ ${MAX_NUM_COLS}  -lt 1 ]] && MAX_NUM_COLS=1
[[ ${WORKER_DEGREE} -lt 1 ]] && WORKER_DEGREE=1

# _op <value> <default> : comparison operator of the condition
_op() {
    case "$(echo "$1" | tr -d ' ' | tr '[:lower:]' '[:upper:]')" in
        '>'|GT)  echo '>'  ;;
        '>='|GE) echo '>=' ;;
        '<'|LT)  echo '<'  ;;
        '<='|LE) echo '<=' ;;
        *)       echo "$2" ;;
    esac
}
PRE1_OP=$(_op "${PRE1_OP}" '>=')
PRE2_OP=$(_op "${PRE2_OP}" '<')

# _in_list <comma separated> : PRE,DDAY -> 'PRE','DDAY'
_in_list() {
    echo "$1" | tr -d " \t" | tr '[:lower:]' '[:upper:]' | tr ',' '\n' \
        | awk 'NF { printf "%s\047%s\047", (n++ ? "," : ""), $0 }'
}

MIG_TYPE_IN=$(_in_list "${MIG_TYPE_LIST}")
[[ -z "${MIG_TYPE_IN}" ]] && MIG_TYPE_IN="'PRE'"
NUM_TYPE_IN=$(_in_list "${NUM_DATA_TYPES}")
[[ -z "${NUM_TYPE_IN}" ]] && NUM_TYPE_IN="'NUMBER'"

# ============================================================
# 2. Paths / logging
# ============================================================
LOG_DIR="${BASE_PATH}/log"
TMP_DIR="${BASE_PATH}/tmp/VERIFY_$$"
CMD_DIR="${BASE_PATH}/cmd"
RES_DIR="${TMP_DIR}/res"

mkdir -p "${LOG_DIR}" "${TMP_DIR}" "${RES_DIR}" "${CMD_DIR}/ASIS" "${CMD_DIR}/TOBE" "${CMD_DIR}/RESULT" || {
    echo "[FAIL] can not create the working directories under ${BASE_PATH}" ; exit 1 ; }

TS=$(date '+%Y%m%d_%H%M%S')
LOGFILE="${LOG_DIR}/DATA_VERIFY_${MSTR_ID}_${TS}.log"

# colour : terminal only, log files stay plain
if   [[ "${VERIFY_COLOR}" == "N" || -n "${NO_COLOR}" ]] ; then C_ON=0
elif [[ "${VERIFY_COLOR}" == "Y" ]] ;                    then C_ON=1
elif [[ -t 1 ]] ;                                        then C_ON=1
else                                                          C_ON=0
fi
if [[ ${C_ON} -eq 1 ]] ; then
    C_R=$'\033[31m' ; C_G=$'\033[32m' ; C_Y=$'\033[33m' ; C_0=$'\033[0m'
else
    C_R="" ; C_G="" ; C_Y="" ; C_0=""
fi

SEP="============================================================"

# _out <text...> : coloured on the screen, plain in the log file
_out() {
    local plain="$*" color
    color="${plain}"
    if [[ ${C_ON} -eq 1 ]] ; then
        # 불일치 first, kept aside as \001 so that the 일치 inside it is not matched again
        color="${color//불일치/$'\001'}"
        color="${color//일치/${C_G}일치${C_0}}"
        color="${color//$'\001'/${C_R}불일치${C_0}}"
        color="${color//'[FAIL]'/${C_R}[FAIL]${C_0}}"
        color="${color//ERROR/${C_R}ERROR${C_0}}"
        color="${color//'[OK]'/${C_G}[OK]${C_0}}"
        color="${color//SKIP/${C_Y}SKIP${C_0}}"
        color="${color//'[WARN]'/${C_Y}[WARN]${C_0}}"
    fi
    printf '%s\n' "${color}"
    printf '%s\n' "${plain}" >> "${LOGFILE}"
}
_log()  { _out "[$(date '+%H:%M:%S')] $*" ; }
_ok()   { _out "[OK]   $*" ; }
_warn() { _out "[WARN] $*" ; }
_fail() { _out "[FAIL] $*" ; }

_cleanup() { [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}" ; }
trap _cleanup EXIT

# ============================================================
# 3. SQL helpers
# ============================================================
# _sql_head : SET commands understood by both sqlplus and tbsql
_sql_head() {
    echo "SET HEADING OFF"
    echo "SET FEEDBACK OFF"
    echo "SET PAGESIZE 0"
    echo "SET LINESIZE 32767"
    echo "SET TRIMSPOOL ON"
    echo "SET VERIFY OFF"
    echo "SET ECHO OFF"
    echo "WHENEVER SQLERROR EXIT FAILURE"
}

# _run_sql <ASIS|TOBE> <SQL_FILE> <OUT_FILE> : 0 = no DB error
_run_sql() {
    local side="$1" sqlf="$2" outf="$3" rc=0
    if [[ "${side}" == "ASIS" ]] ; then
        ${ASIS_CLIENT} -s "${ASIS_CONN}" @"${sqlf}" > "${outf}" 2>&1
    else
        ${TOBE_CLIENT} -s "${TOBE_CONN}" @"${sqlf}" > "${outf}" 2>&1
    fi
    rc=$?
    if [[ ${rc} -ne 0 ]] || grep -Eq '(ORA|TBR|SP2|TSQ|DPI)-[0-9]+' "${outf}" ; then
        return 1
    fi
    return 0
}

# _db_err <OUT_FILE> : first error line
_db_err() {
    grep -Em1 '(ORA|TBR|SP2|TSQ|DPI)-[0-9]+' "$1" 2>/dev/null | tr -d '\r' | sed 's/^[ \t]*//' | cut -c1-500
}

# _q <text> : single quotes doubled, for a SQL literal
_q() { printf '%s' "$1" | sed "s/'/''/g" ; }

# _lit <text> : SQL literal, empty -> NULL
_lit() {
    if [[ -z "$1" ]] ; then printf 'NULL' ; else printf "'%s'" "$(_q "$1")" ; fi
}

# _norm <number text> : canonical form, so that 0010.500 and 10.5 compare equal
_norm() {
    local v
    v=$(printf '%s' "$1" | tr -d ' \t\r')
    [[ -z "${v}" ]] && { printf 'NULL' ; return ; }
    printf '%s' "${v}" | sed -e 's/^+//' \
        -e '/[Ee]/b end' \
        -e '/\./ { s/0*$// ; s/\.$// }' \
        -e 's/^\(-\{0,1\}\)0*\([0-9]\)/\1\2/' \
        -e 's/^\(-\{0,1\}\)\./\10./' \
        -e ':end'
}

# _diff <asis> <tobe> : informational difference (double precision, may be rounded on huge values)
_diff() {
    [[ "$1" == "NULL" || "$2" == "NULL" ]] && { printf '' ; return ; }
    awk -v a="$1" -v b="$2" 'BEGIN { d = a - b
        if (d == int(d)) printf "%.0f", d ; else printf "%.10g", d }' 2>/dev/null
}

# _sum_expr <column> : TO_CHAR( [ROUND](SUM(col)[,n]) [,fmt] )
_sum_expr() {
    local e="SUM(\"$1\")"
    [[ -n "${SUM_ROUND}" ]] && e="ROUND(${e}, ${SUM_ROUND})"
    if [[ -n "${SUM_FMT}" ]] ; then e="TO_CHAR(${e}, '${SUM_FMT}')" ; else e="TO_CHAR(${e})" ; fi
    printf '%s' "${e}"
}

# ============================================================
# 4. Report mode ( -r )
# ============================================================
_report() {
    local sqlf="${TMP_DIR}/report.sql" outf="${TMP_DIR}/report.out"
    local run_cond
    if [[ -n "${OPT_RUN_ID}" ]] ; then
        run_cond="RUN_ID = ${OPT_RUN_ID}"
    else
        run_cond="RUN_ID = (SELECT MAX(RUN_ID) FROM ${RESULT_TAB} WHERE MSTR_ID = '$(_q "${MSTR_ID}")')"
    fi
    {
        _sql_head
        echo "SET LINESIZE 200"
        echo "SET PAGESIZE 1000"
        echo "SET HEADING ON"
        echo "COLUMN OWNER       FORMAT A20"
        echo "COLUMN TABLE_NAME  FORMAT A30"
        echo "COLUMN COLUMN_NAME FORMAT A30"
        echo "COLUMN ASIS_COL    FORMAT A22"
        echo "COLUMN TOBE_COL    FORMAT A22"
        echo "COLUMN STATUS      FORMAT A8"
        echo "PROMPT === SUMMARY ==="
        echo "SELECT RUN_ID, STATUS, COUNT(*) AS CNT"
        echo "  FROM ${RESULT_TAB}"
        echo " WHERE MSTR_ID = '$(_q "${MSTR_ID}")' AND ${run_cond}"
        echo " GROUP BY RUN_ID, STATUS ORDER BY RUN_ID, STATUS;"
        echo "PROMPT"
        echo "PROMPT === NOT 일치 ==="
        echo "SELECT OWNER, TABLE_NAME, COLUMN_NAME, ASIS_COL, TOBE_COL, STATUS"
        echo "  FROM ${RESULT_TAB}"
        echo " WHERE MSTR_ID = '$(_q "${MSTR_ID}")' AND ${run_cond}"
        echo "   AND STATUS <> '일치'"
        echo " ORDER BY STATUS, OWNER, TABLE_NAME, COLUMN_NAME;"
        echo "EXIT"
    } > "${sqlf}"

    if ! _run_sql TOBE "${sqlf}" "${outf}" ; then
        _fail "report query failed : $(_db_err "${outf}")"
        return 1
    fi
    while IFS= read -r l ; do _out "${l}" ; done < "${outf}"
    return 0
}

if [[ "${OPT_REPORT}" == "Y" ]] ; then
    _out "${SEP}"
    _out " DATA VERIFY REPORT   MSTR_ID=${MSTR_ID}   RUN_ID=${OPT_RUN_ID:-latest}"
    _out "${SEP}"
    _report
    _log "log : ${LOGFILE}"
    exit $?
fi

# ============================================================
# 5. Read the control tables (TOBE)
# ============================================================
MSTR_DAT="${TMP_DIR}/mstr.dat"
TGTCOL_DAT="${TMP_DIR}/tgt_cols.dat"
ASISCOL_DAT="${TMP_DIR}/asis_cols.dat"
COLMAP_DAT="${TMP_DIR}/colmap.dat"

_out "${SEP}"
_out " DATA MIGRATION PRE-VERIFY"
_out "  MSTR_ID        : ${MSTR_ID}"
_out "  MIG_TYPE       : ${MIG_TYPE_LIST}"
_out "  ASIS           : ${ASIS_DB_TYPE} (${ASIS_CLIENT})  ${ASIS_DB_USER}${ASIS_DB_TNS:+@${ASIS_DB_TNS}}"
_out "  TOBE           : ${TOBE_DB_TYPE} (${TOBE_CLIENT})  ${TOBE_DB_USER}${TOBE_DB_TNS:+@${TOBE_DB_TNS}}"
_out "  MAX_NUM_COLS   : ${MAX_NUM_COLS}   COUNT_CHECK : ${COUNT_CHECK}   NUM TYPE : ${NUM_DATA_TYPES}"
_out "  WORKER/PARALLEL: ${WORKER_DEGREE} / ${PARALLEL_DEGREE}"
_out "  LOG            : ${LOGFILE}"
_out "${SEP}"

# --- 5.1 target tables ---
_log "read ${MSTR_TAB} ..."
{
    _sql_head
    echo "SELECT '#R#'||TGT_OWNER||'|'||TGT_TABLE_NAME||'|'||SRC_OWNER||'|'||SRC_TABLE_NAME||'|'||"
    echo "       NVL(TRANS_YN,'N')||'|'||MIG_TYPE||'|'||NVL(${PRE_COND_COL},'')||'|'||NVL(PRE1,'')||'|'||NVL(PRE2,'')"
    echo "  FROM ${MSTR_TAB}"
    echo " WHERE MSTR_ID = '$(_q "${MSTR_ID}")'"
    echo "   AND MIG_YN  = 'Y'"
    echo "   AND MIG_TYPE IN (${MIG_TYPE_IN})"
    echo " ORDER BY NVL(TAB_SIZE,0), TGT_OWNER, TGT_TABLE_NAME;"
    echo "EXIT"
} > "${TMP_DIR}/q_mstr.sql"

if ! _run_sql TOBE "${TMP_DIR}/q_mstr.sql" "${TMP_DIR}/q_mstr.out" ; then
    _fail "can not read ${MSTR_TAB} : $(_db_err "${TMP_DIR}/q_mstr.out")"
    exit 1
fi
grep '^#R#' "${TMP_DIR}/q_mstr.out" | sed -e 's/^#R#//' -e 's/\r$//' > "${MSTR_DAT}"

# -t filter : OWNER.TABLE of the TOBE side
if [[ -n "${OPT_TABLES}" ]] ; then
    : > "${TMP_DIR}/mstr_f.dat"
    echo "${OPT_TABLES}" | tr ',' '\n' | tr '[:lower:]' '[:upper:]' | tr -d ' ' | while read -r t ; do
        [[ -z "${t}" ]] && continue
        awk -F'|' -v k="${t}" '(($1 "." $2) == k) || ($2 == k)' "${MSTR_DAT}" >> "${TMP_DIR}/mstr_f.dat"
    done
    mv "${TMP_DIR}/mstr_f.dat" "${MSTR_DAT}"
fi

TAB_CNT=$(wc -l < "${MSTR_DAT}" | tr -d ' ')
if [[ "${TAB_CNT}" -eq 0 ]] ; then
    _fail "no target table (MSTR_ID=${MSTR_ID}, MIG_YN='Y', MIG_TYPE IN (${MIG_TYPE_IN}))"
    exit 1
fi
_ok "target tables : ${TAB_CNT}"

# --- 5.2 number columns of both sides ---
TGT_OWNER_IN=$(awk -F'|' '{print $1}' "${MSTR_DAT}" | sort -u | awk '{ printf "%s\047%s\047", (n++ ? "," : ""), $0 }')
SRC_OWNER_IN=$(awk -F'|' '{print $3}' "${MSTR_DAT}" | sort -u | awk '{ printf "%s\047%s\047", (n++ ? "," : ""), $0 }')

_fetch_cols() {   # <ASIS|TOBE> <owner in list> <out file>
    local side="$1" owners="$2" out="$3"
    {
        _sql_head
        echo "SELECT '#C#'||OWNER||'|'||TABLE_NAME||'|'||COLUMN_NAME||'|'||TO_CHAR(COLUMN_ID)"
        echo "  FROM ALL_TAB_COLUMNS"
        echo " WHERE DATA_TYPE IN (${NUM_TYPE_IN})"
        echo "   AND OWNER IN (${owners})"
        echo " ORDER BY OWNER, TABLE_NAME, COLUMN_ID;"
        echo "EXIT"
    } > "${TMP_DIR}/q_col_${side}.sql"
    if ! _run_sql "${side}" "${TMP_DIR}/q_col_${side}.sql" "${TMP_DIR}/q_col_${side}.out" ; then
        _fail "can not read ${side} ALL_TAB_COLUMNS : $(_db_err "${TMP_DIR}/q_col_${side}.out")"
        return 1
    fi
    grep '^#C#' "${TMP_DIR}/q_col_${side}.out" | sed -e 's/^#C#//' -e 's/\r$//' > "${out}"
    return 0
}

_log "read TOBE ALL_TAB_COLUMNS ..."
_fetch_cols TOBE "${TGT_OWNER_IN}" "${TGTCOL_DAT}" || exit 1
_ok "TOBE number columns : $(wc -l < "${TGTCOL_DAT}" | tr -d ' ')"

_log "read ASIS ALL_TAB_COLUMNS ..."
_fetch_cols ASIS "${SRC_OWNER_IN}" "${ASISCOL_DAT}" || exit 1
_ok "ASIS number columns : $(wc -l < "${ASISCOL_DAT}" | tr -d ' ')"

# --- 5.3 column mapping (only when a TRANS_YN = 'Y' table is in the list) ---
: > "${COLMAP_DAT}"
if awk -F'|' '$5 == "Y" { f = 1 } END { exit f ? 0 : 1 }' "${MSTR_DAT}" ; then
    _log "read ${COLMAP_TAB} ..."
    {
        _sql_head
        echo "SELECT '#M#'||SRC_OWNER||'|'||SRC_TABLE_NAME||'|'||TGT_OWNER||'|'||TGT_TABLE_NAME||'|'||"
        echo "       TGT_COL||'|'||NVL(SRC_COL,'')||'|'||MAP_FLAG"
        echo "  FROM ${COLMAP_TAB};"
        echo "EXIT"
    } > "${TMP_DIR}/q_map.sql"
    if _run_sql TOBE "${TMP_DIR}/q_map.sql" "${TMP_DIR}/q_map.out" ; then
        grep '^#M#' "${TMP_DIR}/q_map.out" | sed -e 's/^#M#//' -e 's/\r$//' > "${COLMAP_DAT}"
        _ok "column mappings : $(wc -l < "${COLMAP_DAT}" | tr -d ' ')"
    else
        _warn "can not read ${COLMAP_TAB}, every column is matched by name : $(_db_err "${TMP_DIR}/q_map.out")"
    fi
fi

# --- 5.4 RUN_ID ---
{
    _sql_head
    echo "SELECT '#N#'||TO_CHAR(NVL(MAX(RUN_ID),0)+1) FROM ${RESULT_TAB} WHERE MSTR_ID = '$(_q "${MSTR_ID}")';"
    echo "EXIT"
} > "${TMP_DIR}/q_run.sql"
if ! _run_sql TOBE "${TMP_DIR}/q_run.sql" "${TMP_DIR}/q_run.out" ; then
    _fail "can not read ${RESULT_TAB} (create DDL_Script/DBM_MIG_PRE_DATA_VERIFY.sql first) : $(_db_err "${TMP_DIR}/q_run.out")"
    exit 1
fi
RUN_ID=$(grep '^#N#' "${TMP_DIR}/q_run.out" | head -1 | sed -e 's/^#N#//' -e 's/[^0-9]//g')
[[ -z "${RUN_ID}" ]] && RUN_ID=1
_ok "RUN_ID : ${RUN_ID}"

# ============================================================
# 6. Confirm
# ============================================================
if [[ "${OPT_YES}" != "Y" ]] ; then
    _out ""
    _out "  tables : ${TAB_CNT}    RUN_ID : ${RUN_ID}    dry run : ${OPT_DRYRUN}"
    printf '  run the verify ? (y/N) : '
    read -r ans
    case "${ans}" in
        y|Y) ;;
        *) _log "cancelled by the user" ; exit 0 ;;
    esac
fi

# ============================================================
# 7. Verify one table
# ============================================================
# arguments : <idx> <mstr line>
# writes    : ${RES_DIR}/<idx>.sql  INSERT statements
#             ${RES_DIR}/<idx>.stat OWNER.TABLE|match|mismatch|skip|error|seconds
_verify_table() {
    local idx="$1" line="$2"
    local tgt_owner tgt_tab src_owner src_tab trans_yn mig_type cond_col pre1 pre2
    IFS='|' read -r tgt_owner tgt_tab src_owner src_tab trans_yn mig_type cond_col pre1 pre2 <<< "${line}"

    local resf="${RES_DIR}/${idx}.sql" statf="${RES_DIR}/${idx}.stat"
    local key="${tgt_owner}.${tgt_tab}"
    local t0 t1 elapsed
    t0=$(date '+%s')
    : > "${resf}"

    local n_match=0 n_mis=0 n_skip=0 n_err=0

    # --- row writer ---
    # _row <tgt_col> <src_col> <asis> <tobe> <diff> <status> <errmsg>
    _row() {
        local vc
        vc=$(printf '%s' "$7" | cut -c1-1000)
        printf 'INSERT INTO %s (RUN_ID, MSTR_ID, OWNER, TABLE_NAME, COLUMN_NAME, SRC_OWNER, SRC_TABLE_NAME, SRC_COLUMN_NAME, MIG_TYPE, VERIFY_COND, ASIS_COL, TOBE_COL, DIFF, STATUS, ERROR_MSG, VERIFY_DT) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, SYSDATE);\n' \
            "${RESULT_TAB}" "${RUN_ID}" "$(_lit "${MSTR_ID}")" \
            "$(_lit "${tgt_owner}")" "$(_lit "${tgt_tab}")" "$(_lit "$1")" \
            "$(_lit "${src_owner}")" "$(_lit "${src_tab}")" "$(_lit "$2")" \
            "$(_lit "${mig_type}")" "$(_lit "$(printf '%s' "${VCOND_TXT}" | cut -c1-4000)")" \
            "$(_lit "$(printf '%s' "$3" | cut -c1-200)")" "$(_lit "$(printf '%s' "$4" | cut -c1-200)")" \
            "$(_lit "$(printf '%s' "$5" | cut -c1-200)")" "$(_lit "$6")" "$(_lit "${vc}")" >> "${resf}"
    }

    # --- 7.1 condition ---
    local asis_cond="" tobe_cond="" tobe_cond_col=""
    VCOND_TXT=""
    if [[ "${mig_type}" == "PRE" ]] ; then
        if [[ -z "${cond_col}" || -z "${pre1}" || -z "${pre2}" ]] ; then
            VCOND_TXT=""
            _row "*NONE*" "" "" "" "" "ERROR" "MIG_TYPE=PRE but ${PRE_COND_COL}/PRE1/PRE2 is empty in ${MSTR_TAB}"
            n_err=1
            t1=$(date '+%s')
            printf '%s|0|0|0|1|%s\n' "${key}" "$((t1 - t0))" > "${statf}"
            _out "  ${key} : ERROR  (condition is not set)"
            return
        fi
        tobe_cond_col="${cond_col}"
        if [[ "${trans_yn}" == "Y" ]] ; then
            local m
            m=$(awk -F'|' -v so="${src_owner}" -v st="${src_tab}" -v to="${tgt_owner}" -v tt="${tgt_tab}" -v sc="${cond_col}" \
                '$1==so && $2==st && $3==to && $4==tt && $7=="RENAME" && $6==sc { print $5 ; exit }' "${COLMAP_DAT}")
            [[ -n "${m}" ]] && tobe_cond_col="${m}"
        fi
        asis_cond="WHERE \"${cond_col}\" ${PRE1_OP} '$(_q "${pre1}")' AND \"${cond_col}\" ${PRE2_OP} '$(_q "${pre2}")'"
        tobe_cond="WHERE \"${tobe_cond_col}\" ${PRE1_OP} '$(_q "${pre1}")' AND \"${tobe_cond_col}\" ${PRE2_OP} '$(_q "${pre2}")'"
        VCOND_TXT="${cond_col} ${PRE1_OP} '${pre1}' AND ${cond_col} ${PRE2_OP} '${pre2}'"
    fi

    # --- 7.2 column list (target, COLUMN_ID order, max MAX_NUM_COLS) ---
    local tgt_cols
    tgt_cols=$(awk -F'|' -v o="${tgt_owner}" -v t="${tgt_tab}" '$1==o && $2==t { print $4 "|" $3 }' "${TGTCOL_DAT}" \
               | sort -t'|' -k1,1n | head -n "${MAX_NUM_COLS}" | awk -F'|' '{print $2}')

    local -a use_tgt=() use_src=()
    local c sc
    while read -r c ; do
        [[ -z "${c}" ]] && continue
        sc="${c}"
        if [[ "${trans_yn}" == "Y" ]] ; then
            local mrow flag msrc
            mrow=$(awk -F'|' -v so="${src_owner}" -v st="${src_tab}" -v to="${tgt_owner}" -v tt="${tgt_tab}" -v tc="${c}" \
                   '$1==so && $2==st && $3==to && $4==tt && $5==tc { print $7 "|" $6 ; exit }' "${COLMAP_DAT}")
            if [[ -n "${mrow}" ]] ; then
                flag="${mrow%%|*}" ; msrc="${mrow#*|}"
                if [[ "${flag}" == "ADD" ]] ; then
                    _row "${c}" "" "" "" "" "SKIP" "DBM_MIG_COL_MAP : ADD column (no ASIS source)"
                    n_skip=$((n_skip + 1)) ; continue
                fi
                [[ -n "${msrc}" ]] && sc="${msrc}"
            fi
        fi
        if ! awk -F'|' -v o="${src_owner}" -v t="${src_tab}" -v c="${sc}" \
               '$1==o && $2==t && $3==c { f=1 } END { exit f ? 0 : 1 }' "${ASISCOL_DAT}" ; then
            _row "${c}" "${sc}" "" "" "" "SKIP" "ASIS ${src_owner}.${src_tab}.${sc} not found (or not ${NUM_DATA_TYPES})"
            n_skip=$((n_skip + 1)) ; continue
        fi
        use_tgt+=("${c}") ; use_src+=("${sc}")
    done <<< "${tgt_cols}"

    # --- 7.3 SUM SQL ---
    local hint=""
    [[ ${PARALLEL_DEGREE} -gt 1 ]] && hint="/*+ PARALLEL(${PARALLEL_DEGREE}) */ "

    local asis_sql="${CMD_DIR}/ASIS/${tgt_owner}_${tgt_tab}.sql"
    local tobe_sql="${CMD_DIR}/TOBE/${tgt_owner}_${tgt_tab}.sql"
    local i expr_list

    expr_list=""
    for i in "${!use_src[@]}" ; do expr_list="${expr_list}||$(_sum_expr "${use_src[$i]}")||'|'" ; done
    {
        _sql_head
        echo "-- ASIS ${src_owner}.${src_tab}   MSTR_ID=${MSTR_ID} RUN_ID=${RUN_ID} MIG_TYPE=${mig_type}"
        echo "SELECT ${hint}'#S#'${expr_list}||TO_CHAR(COUNT(*))"
        echo "  FROM \"${src_owner}\".\"${src_tab}\""
        echo " ${asis_cond};"
        echo "EXIT"
    } > "${asis_sql}"

    expr_list=""
    for i in "${!use_tgt[@]}" ; do expr_list="${expr_list}||$(_sum_expr "${use_tgt[$i]}")||'|'" ; done
    {
        _sql_head
        echo "-- TOBE ${tgt_owner}.${tgt_tab}   MSTR_ID=${MSTR_ID} RUN_ID=${RUN_ID} MIG_TYPE=${mig_type}"
        echo "SELECT ${hint}'#S#'${expr_list}||TO_CHAR(COUNT(*))"
        echo "  FROM \"${tgt_owner}\".\"${tgt_tab}\""
        echo " ${tobe_cond};"
        echo "EXIT"
    } > "${tobe_sql}"

    if [[ "${OPT_DRYRUN}" == "Y" ]] ; then
        t1=$(date '+%s')
        printf '%s|0|0|0|0|%s\n' "${key}" "$((t1 - t0))" > "${statf}"
        _out "  ${key} : SQL only (${#use_tgt[@]} columns)"
        return
    fi

    # --- 7.4 run both sides ---
    local aout="${TMP_DIR}/${idx}_asis.out" tout="${TMP_DIR}/${idx}_tobe.out"
    local aerr="" terr=""
    _run_sql ASIS "${asis_sql}" "${aout}" || aerr=$(_db_err "${aout}")
    _run_sql TOBE "${tobe_sql}" "${tout}" || terr=$(_db_err "${tout}")

    local aline tline
    aline=$(grep '^#S#' "${aout}" 2>/dev/null | head -1 | sed -e 's/^#S#//' -e 's/\r$//')
    tline=$(grep '^#S#' "${tout}" 2>/dev/null | head -1 | sed -e 's/^#S#//' -e 's/\r$//')

    if [[ -n "${aerr}" || -n "${terr}" || -z "${aline}" || -z "${tline}" ]] ; then
        local msg="${aerr:+ASIS: ${aerr}} ${terr:+TOBE: ${terr}}"
        [[ -z "${aerr}${terr}" ]] && msg="no result row returned (ASIS='${aline}' TOBE='${tline}')"
        _row "*NONE*" "" "" "" "" "ERROR" "${msg}"
        t1=$(date '+%s')
        printf '%s|0|0|0|1|%s\n' "${key}" "$((t1 - t0))" > "${statf}"
        _out "  ${key} : ERROR  ${msg}"
        return
    fi

    # --- 7.5 compare ---
    local -a av tv
    IFS='|' read -r -a av <<< "${aline}"
    IFS='|' read -r -a tv <<< "${tline}"

    local n=${#use_tgt[@]}
    local a b d st
    for ((i = 0 ; i < n ; i++)) ; do
        a=$(_norm "${av[$i]}") ; b=$(_norm "${tv[$i]}")
        if [[ "${a}" == "${b}" ]] ; then
            st="일치" ; d="" ; n_match=$((n_match + 1))
        else
            st="불일치" ; d=$(_diff "${a}" "${b}") ; n_mis=$((n_mis + 1))
        fi
        _row "${use_tgt[$i]}" "${use_src[$i]}" "${a}" "${b}" "${d}" "${st}" ""
    done

    if [[ "${COUNT_CHECK}" == "Y" ]] ; then
        a=$(_norm "${av[$n]}") ; b=$(_norm "${tv[$n]}")
        if [[ "${a}" == "${b}" ]] ; then
            st="일치" ; d="" ; n_match=$((n_match + 1))
        else
            st="불일치" ; d=$(_diff "${a}" "${b}") ; n_mis=$((n_mis + 1))
        fi
        _row "*ROW_COUNT*" "*ROW_COUNT*" "${a}" "${b}" "${d}" "${st}" ""
    fi

    if [[ ${n} -eq 0 && "${COUNT_CHECK}" != "Y" ]] ; then
        _row "*NONE*" "" "" "" "" "SKIP" "no ${NUM_DATA_TYPES} column on TOBE ${tgt_owner}.${tgt_tab}"
        n_skip=$((n_skip + 1))
    fi

    t1=$(date '+%s') ; elapsed=$((t1 - t0))
    printf '%s|%s|%s|%s|%s|%s\n' "${key}" "${n_match}" "${n_mis}" "${n_skip}" "${n_err}" "${elapsed}" > "${statf}"
    if [[ ${n_mis} -gt 0 ]] ; then
        _out "  ${key} : 불일치 ${n_mis} / 일치 ${n_match} / SKIP ${n_skip}   (${elapsed}s)"
    else
        _out "  ${key} : 일치 ${n_match} / SKIP ${n_skip}   (${elapsed}s)"
    fi
}

# ============================================================
# 8. Worker pool
# ============================================================
declare -a PIDS=()

_alive() {
    local p n=0
    for p in "${PIDS[@]}" ; do
        [[ -n "${p}" ]] && kill -0 "${p}" 2>/dev/null && n=$((n + 1))
    done
    echo "${n}"
}

_out ""
_log "verify start : ${TAB_CNT} tables, ${WORKER_DEGREE} at a time"
_out "${SEP}"

IDX=0
while IFS= read -r line ; do
    [[ -z "${line}" ]] && continue
    IDX=$((IDX + 1))
    while [[ $(_alive) -ge ${WORKER_DEGREE} ]] ; do sleep 1 ; done
    _verify_table "${IDX}" "${line}" &
    PIDS+=("$!")
done < "${MSTR_DAT}"
wait

_out "${SEP}"
_log "verify done"

# ============================================================
# 9. Load the result rows (TOBE)
# ============================================================
if [[ "${OPT_DRYRUN}" == "Y" ]] ; then
    _out ""
    _ok "dry run : SQL written under ${CMD_DIR}/ASIS and ${CMD_DIR}/TOBE (nothing was run, nothing inserted)"
    _log "log : ${LOGFILE}"
    exit 0
fi

ALL_SQL="${TMP_DIR}/result_all.sql"
: > "${ALL_SQL}"
for ((i = 1 ; i <= IDX ; i++)) ; do
    [[ -f "${RES_DIR}/${i}.sql" ]] && cat "${RES_DIR}/${i}.sql" >> "${ALL_SQL}"
done

ROW_CNT=$(wc -l < "${ALL_SQL}" | tr -d ' ')
if [[ "${ROW_CNT}" -eq 0 ]] ; then
    _warn "no result row to insert"
else
    _log "insert ${ROW_CNT} rows into ${RESULT_TAB} (RUN_ID=${RUN_ID}) ..."
    rm -f "${CMD_DIR}/RESULT/RESULT_${MSTR_ID}_R${RUN_ID}"_*.sql
    split -l 400 -d -a 4 "${ALL_SQL}" "${TMP_DIR}/part_"
    LOAD_RC=0
    for part in "${TMP_DIR}"/part_* ; do
        pn=$(basename "${part}")
        sqlf="${CMD_DIR}/RESULT/RESULT_${MSTR_ID}_R${RUN_ID}_${pn##part_}.sql"
        { _sql_head ; cat "${part}" ; echo "COMMIT;" ; echo "EXIT" ; } > "${sqlf}"
        if ! _run_sql TOBE "${sqlf}" "${TMP_DIR}/${pn}.out" ; then
            _fail "insert failed (${sqlf}) : $(_db_err "${TMP_DIR}/${pn}.out")"
            LOAD_RC=1
        fi
    done
    if [[ ${LOAD_RC} -eq 0 ]] ; then
        _ok "result loaded : ${ROW_CNT} rows, RUN_ID=${RUN_ID}"
    else
        _fail "some result rows were not loaded : check ${CMD_DIR}/RESULT"
    fi
fi

# ============================================================
# 10. Summary
# ============================================================
T_MATCH=0 ; T_MIS=0 ; T_SKIP=0 ; T_ERR=0 ; MIS_TABS=""
for ((i = 1 ; i <= IDX ; i++)) ; do
    [[ -f "${RES_DIR}/${i}.stat" ]] || continue
    IFS='|' read -r k m x s e el < "${RES_DIR}/${i}.stat"
    T_MATCH=$((T_MATCH + m)) ; T_MIS=$((T_MIS + x)) ; T_SKIP=$((T_SKIP + s)) ; T_ERR=$((T_ERR + e))
    [[ ${x} -gt 0 || ${e} -gt 0 ]] && MIS_TABS="${MIS_TABS}    ${k}  불일치=${x} ERROR=${e}"$'\n'
done

_out ""
_out "${SEP}"
_out " SUMMARY   MSTR_ID=${MSTR_ID}   RUN_ID=${RUN_ID}   tables=${TAB_CNT}"
_out "   일치   : ${T_MATCH}"
_out "   불일치 : ${T_MIS}"
_out "   SKIP   : ${T_SKIP}"
_out "   ERROR  : ${T_ERR}"
_out "${SEP}"
if [[ -n "${MIS_TABS}" ]] ; then
    _out " tables to check :"
    printf '%s' "${MIS_TABS}" | while IFS= read -r l ; do _out "${l}" ; done
    _out "${SEP}"
fi
_log "log : ${LOGFILE}"
_out " detail : bash $(basename "$0") -r ${RUN_ID}"

if [[ ${T_MIS} -gt 0 || ${T_ERR} -gt 0 ]] ; then exit 2 ; fi
exit 0
