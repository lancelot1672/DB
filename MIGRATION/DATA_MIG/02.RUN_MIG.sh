#!/bin/bash
# ============================================================
# 02.RUN_MIG.sh
# Data migration menu driven by DBADM.DBM_MIG_MSTR (spec : MIG_RUN_PLAN.md)
#
#   [PRE]
#   1. Generate PRE SQL   -> ./cmd/PRE/{TGT_OWNER}_{TGT_TABLE_NAME}.out
#        MIG_TYPE = PRE  AND MIG_FULL = COND : COL_CONDITION >= 'PRE1' AND COL_CONDITION < 'PRE2'
#   2. Run PRE            : every .out file in ./cmd/PRE
#   3. Retry PRE FAILED   : FAIL tables of the latest PRE RUN_ID
#   [DDAY]
#   4. Generate DDAY SQL  -> ./cmd/DDAY/{TGT_OWNER}_{TGT_TABLE_NAME}.out
#        MIG_TYPE = PRE  AND MIG_FULL = COND : COL_CONDITION >= 'PRE3' (rest of the data)
#        MIG_TYPE = DDAY AND MIG_FULL = FULL : no condition (full)
#   5. Run DDAY           : every .out file in ./cmd/DDAY
#   6. Retry DDAY FAILED  : FAIL tables of the latest DDAY RUN_ID
#
#   - target rows : MSTR_ID (MIG.env) AND MIG_YN = 'Y'
#                   TRANS_YN = 'Y' on hold ; other MIG_TYPE / MIG_FULL combinations excluded
#   - generate    : existing .out files of the phase directory are deleted first (confirm)
#                   .out header comments (-- KEY : value) keep the log key and count condition
#   - run         : new RUN_ID (MAX + 1) per run ; DBM_XDN_LOG.MIG_TYPE = phase (PRE / DDAY)
#                   PENDING -> RUNNING -> SUCCESS / FAIL, ROW_CNT_SRC / ROW_CNT_TGT, ERROR_MSG
#   - retry       : FAIL rows of MAX(RUN_ID) for MSTR_ID + phase, re-run ./cmd/<phase>/{TGT}.out
#                   the same DBM_XDN_LOG rows are updated (no new RUN_ID)
#   - sequential ; a failed table is logged as FAIL and the run continues
#   - INSERT only ; target data is never truncated / deleted
#   - ./log/      : progress log (table, count by condition, start / end / elapsed)
#   - connects to the target DB only (control tables live there) ; plain SQL only
# Usage: 02.RUN_MIG.sh   (menu)
# ============================================================

# --- Load environment variables ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [[ -f "${SCRIPT_DIR}/MIG.env" ]] ; then
    . ${SCRIPT_DIR}/MIG.env
else
    echo "[FAIL] MIG.env file not found: ${SCRIPT_DIR}/MIG.env"
    exit 1
fi

case "${DB_TYPE}" in
    ORACLE) DB_CLIENT="sqlplus" ;;
    TIBERO) DB_CLIENT="tbsql" ;;
    *)      echo "[FAIL] DB_TYPE must be ORACLE or TIBERO in MIG.env (current: '${DB_TYPE}')" ; exit 1 ;;
esac

if ! command -v ${DB_CLIENT} > /dev/null 2>&1 ; then
    echo "[FAIL] ${DB_CLIENT} not found in PATH (DB_TYPE=${DB_TYPE})"
    exit 1
fi

if [[ -z "${MSTR_ID}" || -z "${SRC_DBLINK}" ]] ; then
    echo "[FAIL] MSTR_ID and SRC_DBLINK must be set in MIG.env"
    exit 1
fi

DB_CONN="${DB_USER}/${DB_PASS}${DB_TNS:+@${DB_TNS}}"

MSTR_TAB="DBADM.DBM_MIG_MSTR"
LOG_TAB="DBADM.DBM_XDN_LOG"

SEP="============================================================"

CMD_DIR="${SCRIPT_DIR}/cmd"
LOG_DIR="${SCRIPT_DIR}/log"
TMP_DIR="${BASE_PATH}/tmp"
mkdir -p "${CMD_DIR}/PRE" "${CMD_DIR}/DDAY" "${LOG_DIR}" "${TMP_DIR}"

TMP_SQL="${TMP_DIR}/RUN_MIG_$$.sql"
TMP_OUT="${TMP_DIR}/RUN_MIG_$$.out"
TMP_LIST="${TMP_DIR}/RUN_MIG_LIST_$$.lst"
TMP_RUN="${TMP_DIR}/RUN_MIG_RUN_$$.lst"

# log file is opened per menu action (_new_log)
LOGFILE="/dev/null"

# _out: Print to terminal and append to log file
_out() {
    printf "$@"
    printf "$@" >> ${LOGFILE}
}

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

_cleanup() { rm -f ${TMP_SQL} ${TMP_OUT} ${TMP_LIST} ${TMP_RUN}; }
trap _cleanup EXIT

# _new_log <ACTION> : ./log/<ACTION>_<MSTR_ID>_<timestamp>.log
_new_log() { LOGFILE="${LOG_DIR}/${1}_${MSTR_ID}_$(date '+%Y%m%d_%H%M%S').log"; }

# _confirm <message> : 0 when answered y / Y
_confirm() {
    local _ans
    printf "%s [y/N]: " "$1"
    read -r _ans
    [[ "${_ans}" == "y" || "${_ans}" == "Y" ]]
}

# _q <text> : escape single quotes for a SQL literal
_q() { printf "%s" "${1//\'/\'\'}"; }

# _db_errors : DB error lines of the last _run_sql
#   query result lines ("TAG|value", e.g. ERROR_MSG read back by retry) are data, not errors
_db_errors() { grep -Ev '^[A-Z_]+\|' ${TMP_OUT} | grep -E '(ORA|TBR|SP2)-[0-9]+'; }

# _run_sql <SQL_FILE> : output -> TMP_OUT ; returns 1 on client error or DB error code in output
_run_sql() {
    ${DB_CLIENT} -s "${DB_CONN}" @"$1" < /dev/null > ${TMP_OUT} 2>&1
    local _rc=$?
    if [[ ${_rc} -ne 0 ]] || _db_errors > /dev/null ; then
        return 1
    fi
    return 0
}

# _get <TAG> : value of the first "TAG|value" line of the last _run_sql
_get() { grep "^$1|" ${TMP_OUT} | head -1 | cut -d'|' -f2 | tr -d '[:space:]'; }

# _hdr <KEY> <OUT_FILE> : value of the "-- KEY : value" header comment
_hdr() { sed -n "s/^-- $1 *: *//p" "$2" | head -1 | sed 's/[[:space:]]*$//'; }

# _out_cnt <PHASE> : number of .out files in ./cmd/<PHASE>
_out_cnt() { find "${CMD_DIR}/$1" -maxdepth 1 -name '*.out' 2>/dev/null | wc -l | tr -d ' '; }

# _sql_head : common settings for query / update SQL files
_sql_head() {
    echo "SET HEADING OFF"
    echo "SET FEEDBACK OFF"
    echo "SET PAGESIZE 50000"
    echo "SET LINESIZE 32767"
    echo "SET TRIMOUT ON"
    echo "SET DEFINE OFF"
    echo "WHENEVER SQLERROR EXIT FAILURE ROLLBACK"
}

# _fmt_sec <seconds> : HH:MM:SS
_fmt_sec() { printf "%02d:%02d:%02d" $(( $1 / 3600 )) $(( $1 % 3600 / 60 )) $(( $1 % 60 )); }

# _show_db_errors : print DB error lines of the last _run_sql
_show_db_errors() { _db_errors | while IFS= read -r _line ; do _out "  %s\n" "${_line}" ; done; }

# _head_tail <FILE> <FORMAT_FUNC> : TOP 5 / BOTTOM 5 through a formatter reading stdin
_head_tail() {
    local _n
    _n=$(wc -l < "$1" | tr -d ' ')
    _out "  --- TOP 5 ---\n"
    head -5 "$1" | $2
    if [[ ${_n} -gt 5 ]] ; then
        _out "\n  --- BOTTOM 5 ---\n"
        tail -5 "$1" | $2
    fi
    _out "\n"
}

M_ID=$(_q "${MSTR_ID}")
TARGET_WHERE="MSTR_ID = '${M_ID}' AND MIG_YN = 'Y'"

# ============================================================
# Generate SQL : _generate <PRE|DDAY>
# ============================================================
_fmt_row() {
    local _t _c _so _st _to _tt _mt _mf _w
    while IFS='|' read -r _t _c _so _st _to _tt _mt _mf _w ; do
        _out "  %s.%s -> %s.%s [%s/%s] %s\n" "${_so}" "${_st}" "${_to}" "${_tt}" "${_mt}" "${_mf}" "${_w:-(no condition)}"
    done
}

_generate() {
    local PHASE="$1"
    local OUT_DIR="${CMD_DIR}/${PHASE}"
    local TGT_COND WHERE_EXPR TOTAL RUN_CNT EXCL_CNT HOLD_CNT OLD_CNT GEN_CNT DUP_CNT
    local _t _c SO ST TO TT MT MF WHERE_CLAUSE OUT_FILE

    _new_log "GEN_${PHASE}"
    _out "%s\n" "$SEP"
    _log "Generate ${PHASE} SQL : MSTR_ID=${MSTR_ID} -> ${OUT_DIR}"
    _out "%s\n" "$SEP"

    case "${PHASE}" in
        PRE)
            TGT_COND="MIG_TYPE = 'PRE' AND MIG_FULL = 'COND'"
            WHERE_EXPR="'WHERE ' || COL_CONDITION || ' >= ''' || REPLACE(PRE1, '''', '''''') || ''' AND ' || COL_CONDITION || ' < ''' || REPLACE(PRE2, '''', '''''') || ''''"
            ;;
        DDAY)
            TGT_COND="(MIG_TYPE = 'PRE' AND MIG_FULL = 'COND') OR (MIG_TYPE = 'DDAY' AND MIG_FULL = 'FULL')"
            WHERE_EXPR="CASE WHEN MIG_TYPE = 'PRE' THEN 'WHERE ' || COL_CONDITION || ' >= ''' || REPLACE(PRE3, '''', '''''') || '''' END"
            ;;
    esac

    # ROW|RUN,EXCL,HOLD|SRC_OWNER|SRC_TABLE_NAME|TGT_OWNER|TGT_TABLE_NAME|MIG_TYPE|MIG_FULL|WHERE clause
    cat > ${TMP_SQL} <<EOF
$(_sql_head)
SELECT 'ROW|'
       || CASE WHEN NVL(TRANS_YN, 'N') = 'Y' THEN 'HOLD'
               WHEN (${TGT_COND}) THEN 'RUN'
               ELSE 'EXCL'
          END
       || '|' || SRC_OWNER || '|' || SRC_TABLE_NAME || '|' || TGT_OWNER || '|' || TGT_TABLE_NAME
       || '|' || MIG_TYPE || '|' || MIG_FULL || '|'
       || CASE WHEN NVL(TRANS_YN, 'N') <> 'Y' AND (${TGT_COND}) THEN ${WHERE_EXPR} END
  FROM ${MSTR_TAB}
 WHERE ${TARGET_WHERE}
 ORDER BY SRC_OWNER, SRC_TABLE_NAME;
EXIT;
EOF

    if ! _run_sql ${TMP_SQL} ; then
        _fail "Failed to read ${MSTR_TAB}"
        _show_db_errors
        return 1
    fi

    grep '^ROW|' ${TMP_OUT} | sed 's/[[:space:]]*$//' > ${TMP_LIST}
    awk -F'|' '$2 == "RUN"' ${TMP_LIST} > ${TMP_RUN}

    TOTAL=$(wc -l < ${TMP_LIST} | tr -d ' ')
    RUN_CNT=$(wc -l < ${TMP_RUN} | tr -d ' ')
    EXCL_CNT=$(awk -F'|' '$2 == "EXCL"' ${TMP_LIST} | wc -l | tr -d ' ')
    HOLD_CNT=$(awk -F'|' '$2 == "HOLD"' ${TMP_LIST} | wc -l | tr -d ' ')
    OLD_CNT=$(_out_cnt ${PHASE})

    _out "  MIG_YN=Y rows  : %s\n" "${TOTAL}"
    _out "  Generate       : %s\n" "${RUN_CNT}"
    _out "  Excluded       : %s (not a %s target by MIG_TYPE / MIG_FULL)\n" "${EXCL_CNT}" "${PHASE}"
    _out "  On hold        : %s (TRANS_YN=Y)\n" "${HOLD_CNT}"
    _out "  Existing .out  : %s (deleted before generate)\n\n" "${OLD_CNT}"

    if [[ ${RUN_CNT} -eq 0 ]] ; then
        _fail "No ${PHASE} target table for MSTR_ID='${MSTR_ID}'"
        return 1
    fi

    _head_tail ${TMP_RUN} _fmt_row

    if ! _confirm "Delete ${OLD_CNT} existing .out and generate ${RUN_CNT} SQL file(s) in cmd/${PHASE}?" ; then
        _log "Generate ${PHASE} SQL cancelled by user"
        return 0
    fi

    rm -f "${OUT_DIR}"/*.out
    GEN_CNT=0 ; DUP_CNT=0

    while IFS='|' read -r _t _c SO ST TO TT MT MF WHERE_CLAUSE <&3 ; do
        OUT_FILE="${OUT_DIR}/${TO}_${TT}.out"
        if [[ -f "${OUT_FILE}" ]] ; then
            _out "  [WARN] duplicate target %s.%s : %s overwritten by %s.%s\n" "${TO}" "${TT}" "$(basename "${OUT_FILE}")" "${SO}" "${ST}"
            DUP_CNT=$(( DUP_CNT + 1 ))
        else
            GEN_CNT=$(( GEN_CNT + 1 ))
        fi

        {
            echo "-- MSTR_ID        : ${MSTR_ID}"
            echo "-- MIG_PHASE      : ${PHASE}"
            echo "-- MSTR_MIG_TYPE  : ${MT} / ${MF}"
            echo "-- SRC_OWNER      : ${SO}"
            echo "-- SRC_TABLE_NAME : ${ST}"
            echo "-- TGT_OWNER      : ${TO}"
            echo "-- TGT_TABLE_NAME : ${TT}"
            echo "-- SRC_DBLINK     : ${SRC_DBLINK}"
            echo "-- CONDITION      : ${WHERE_CLAUSE}"
            echo "-- GENERATED      : $(date '+%Y-%m-%d %H:%M:%S')"
            echo "INSERT INTO ${TO}.${TT}"
            echo "SELECT * FROM ${SO}.${ST}@${SRC_DBLINK}${WHERE_CLAUSE:+ ${WHERE_CLAUSE}};"
            echo "COMMIT;"
        } > "${OUT_FILE}"
    done 3< ${TMP_RUN}

    _ok "${GEN_CNT} SQL file(s) generated in ${OUT_DIR}"
    [[ ${DUP_CNT} -gt 0 ]] && _out "  [WARN] %s duplicate target row(s) overwritten\n" "${DUP_CNT}"
    return 0
}

# ============================================================
# Execute one table : _exec_table <OUT_FILE> <RUN_ID> <PHASE> <MSTR_ID> <SRC_OWNER> <SRC_TABLE> <TGT_OWNER> <TGT_TABLE> <NUM> <TOTAL>
#   updates the DBM_XDN_LOG row identified by the arguments ; result -> EXEC_STATUS / EXEC_ERR
#   caller keeps SUCC_CNT / FAIL_CNT / FAIL_LIST (see _count_result)
# ============================================================
_exec_table() {
    local F="$1" RID="$2" PHASE="$3" MID="$4" SO="$5" ST="$6" TO="$7" TT="$8" NUM="$9" TOTAL="${10}"
    local DBL WHERE_CLAUSE SRC_OBJ TGT_OBJ KEY ERR_SQL CNT_SRC CNT_INS CNT_TGT T_START T_END _cmp

    TGT_OBJ="${TO}.${TT}"
    KEY="RUN_ID = ${RID} AND MSTR_ID = '$(_q "${MID}")' AND SRC_OWNER = '$(_q "${SO}")' AND SRC_TABLE_NAME = '$(_q "${ST}")' AND TGT_OWNER = '$(_q "${TO}")' AND TGT_TABLE_NAME = '$(_q "${TT}")' AND MIG_TYPE = '${PHASE}'"
    EXEC_STATUS="SUCCESS" ; EXEC_ERR=""

    _out "%s\n" "$SEP"
    _log "[${NUM}/${TOTAL}] ${SO}.${ST} -> ${TGT_OBJ} (${PHASE}, RUN_ID=${RID}) : $(basename "${F}")"
    _out "%s\n" "$SEP"

    # --- SQL file missing (retry only) : FAIL without running ---
    if [[ ! -f "${F}" ]] ; then
        EXEC_STATUS="FAIL" ; EXEC_ERR="SQL file not found : ${F}"
        cat > ${TMP_SQL} <<EOF
$(_sql_head)
UPDATE ${LOG_TAB} SET STATUS = 'FAIL', START_TIME = SYSDATE, END_TIME = SYSDATE, ERROR_MSG = '$(_q "${EXEC_ERR}")' WHERE ${KEY};
COMMIT;
EXIT;
EOF
        _run_sql ${TMP_SQL} || { _out "  [WARN] ${LOG_TAB} update error\n" ; _show_db_errors ; }
        _fail "FAIL    ${SO}.${ST} -> ${TGT_OBJ} : ${EXEC_ERR}"
        return
    fi

    DBL=$(_hdr SRC_DBLINK "${F}")
    WHERE_CLAUSE=$(_hdr CONDITION "${F}")
    SRC_OBJ="${SO}.${ST}@${DBL}"

    _out "  Condition  : %s\n" "${WHERE_CLAUSE:-(none)}"
    T_START=$(date +%s)
    _out "  Start time : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"

    # --- RUNNING, START_TIME, ROW_CNT_SRC ---
    cat > ${TMP_SQL} <<EOF
$(_sql_head)
UPDATE ${LOG_TAB} SET STATUS = 'RUNNING', START_TIME = SYSDATE, END_TIME = NULL, ERROR_MSG = NULL WHERE ${KEY};
COMMIT;
UPDATE ${LOG_TAB} SET ROW_CNT_SRC = (SELECT COUNT(*) FROM ${SRC_OBJ} ${WHERE_CLAUSE}) WHERE ${KEY};
COMMIT;
SELECT 'CNT|' || ROW_CNT_SRC FROM ${LOG_TAB} WHERE ${KEY};
EXIT;
EOF

    if _run_sql ${TMP_SQL} ; then
        CNT_SRC=$(_get CNT)
        _out "  SRC count  : %s\n" "${CNT_SRC}"

        # --- INSERT INTO SELECT + COMMIT from the .out file ---
        {
            echo "SET DEFINE OFF"
            echo "SET FEEDBACK ON"
            echo "WHENEVER SQLERROR EXIT FAILURE ROLLBACK"
            cat "${F}"
            echo "EXIT;"
        } > ${TMP_SQL}

        if _run_sql ${TMP_SQL} ; then
            # "N rows created." (sqlplus) / "N rows inserted." (tbsql)
            CNT_INS=$(grep -Eo '^[0-9]+ rows? (created|inserted)' ${TMP_OUT} | head -1 | cut -d' ' -f1)
            _out "  Inserted   : %s\n" "${CNT_INS:-?}"
        else
            EXEC_STATUS="FAIL"
        fi
    else
        EXEC_STATUS="FAIL"
    fi

    if [[ "${EXEC_STATUS}" == "FAIL" ]] ; then
        EXEC_ERR=$(_db_errors | tr '\n' ' ' | awk '{ print substr($0, 1, 1000) }')
        [[ -z "${EXEC_ERR}" ]] && EXEC_ERR=$(tail -3 ${TMP_OUT} | tr '\n' ' ' | awk '{ print substr($0, 1, 1000) }')
    fi

    # --- SUCCESS / FAIL, END_TIME, ERROR_MSG, ROW_CNT_TGT ---
    if [[ -n "${EXEC_ERR}" ]] ; then ERR_SQL="'$(_q "${EXEC_ERR}")'" ; else ERR_SQL="NULL" ; fi

    cat > ${TMP_SQL} <<EOF
$(_sql_head)
UPDATE ${LOG_TAB} SET STATUS = '${EXEC_STATUS}', END_TIME = SYSDATE, ERROR_MSG = ${ERR_SQL} WHERE ${KEY};
COMMIT;
WHENEVER SQLERROR CONTINUE
UPDATE ${LOG_TAB} SET ROW_CNT_TGT = (SELECT COUNT(*) FROM ${TGT_OBJ} ${WHERE_CLAUSE}) WHERE ${KEY};
COMMIT;
SELECT 'CNT|' || ROW_CNT_TGT FROM ${LOG_TAB} WHERE ${KEY};
EXIT;
EOF

    if ! _run_sql ${TMP_SQL} ; then
        _out "  [WARN] ${LOG_TAB} end update / target count error\n"
        _db_errors | while IFS= read -r _line ; do _out "         %s\n" "${_line}" ; done
    fi
    CNT_TGT=$(_get CNT)

    T_END=$(date +%s)
    if [[ -n "${CNT_TGT}" && "${CNT_TGT}" == "${CNT_SRC}" ]] ; then _cmp="(= SRC)"
    elif [[ -n "${CNT_TGT}" ]] ; then _cmp="(<> SRC ${CNT_SRC:-?})"
    else _cmp="" ; fi
    _out "  TGT count  : %s %s\n" "${CNT_TGT:-?}" "${_cmp}"
    _out "  End time   : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    _out "  Elapsed    : %s\n" "$(_fmt_sec $(( T_END - T_START )))"

    if [[ "${EXEC_STATUS}" == "SUCCESS" ]] ; then
        _ok "SUCCESS ${SO}.${ST} -> ${TGT_OBJ}"
    else
        _fail "FAIL    ${SO}.${ST} -> ${TGT_OBJ} : ${EXEC_ERR}"
    fi
}

# _count_result <label> : add the last _exec_table result to the caller's counters
_count_result() {
    if [[ "${EXEC_STATUS}" == "SUCCESS" ]] ; then
        SUCC_CNT=$(( SUCC_CNT + 1 ))
    else
        FAIL_CNT=$(( FAIL_CNT + 1 ))
        FAIL_LIST="${FAIL_LIST}  $1\n"
    fi
}

# _summary <title> <total> <start epoch> : uses the caller's SUCC_CNT / FAIL_CNT / FAIL_LIST
_summary() {
    local _end
    _end=$(date +%s)
    _out "%s\n" "$SEP"
    _log "Summary $1"
    _out "%s\n" "$SEP"
    _out "  Total   : %s\n" "$2"
    _out "  Success : %s\n" "${SUCC_CNT}"
    _out "  Fail    : %s\n" "${FAIL_CNT}"
    _out "  Elapsed : %s\n" "$(_fmt_sec $(( _end - $3 )))"
    _out "  Log     : %s\n" "${LOGFILE}"
    if [[ ${FAIL_CNT} -gt 0 ]] ; then
        _out "\n  --- FAILED ---\n"
        _out "${FAIL_LIST}"
    fi
}

# ============================================================
# Run migration : _run <PRE|DDAY>
# ============================================================
_fmt_file() {
    local _f _w
    while IFS= read -r _f ; do
        _w=$(_hdr CONDITION "${_f}")
        _out "  %s.%s -> %s.%s %s\n" "$(_hdr SRC_OWNER "${_f}")" "$(_hdr SRC_TABLE_NAME "${_f}")" \
             "$(_hdr TGT_OWNER "${_f}")" "$(_hdr TGT_TABLE_NAME "${_f}")" "${_w:-(no condition)}"
    done
}

_run() {
    local PHASE="$1"
    local OUT_DIR="${CMD_DIR}/${PHASE}"
    local TOTAL RUN_ID NUM SUCC_CNT FAIL_CNT FAIL_LIST RUN_START F

    _new_log "RUN_${PHASE}"
    _out "%s\n" "$SEP"
    _log "Run ${PHASE} migration : ${OUT_DIR}"
    _out "%s\n" "$SEP"

    find "${OUT_DIR}" -maxdepth 1 -name '*.out' 2>/dev/null | sort > ${TMP_LIST}
    TOTAL=$(wc -l < ${TMP_LIST} | tr -d ' ')
    if [[ ${TOTAL} -eq 0 ]] ; then
        _fail "No .out file in ${OUT_DIR} (generate ${PHASE} SQL first)"
        return 1
    fi

    # --- new RUN_ID for this run ---
    cat > ${TMP_SQL} <<EOF
$(_sql_head)
SELECT 'RUN_ID|' || (NVL(MAX(RUN_ID), 0) + 1) FROM ${LOG_TAB};
EXIT;
EOF
    if ! _run_sql ${TMP_SQL} ; then
        _fail "Failed to read ${LOG_TAB}"
        _show_db_errors
        return 1
    fi
    RUN_ID=$(_get RUN_ID)

    _out "  RUN_ID    : %s\n" "${RUN_ID}"
    _out "  SQL files : %s\n\n" "${TOTAL}"
    _head_tail ${TMP_LIST} _fmt_file

    if ! _confirm "Run ${TOTAL} ${PHASE} SQL file(s) (RUN_ID=${RUN_ID})?" ; then
        _log "Run ${PHASE} migration cancelled by user"
        return 0
    fi

    # --- DBM_XDN_LOG : PENDING for every file of this run ---
    {
        _sql_head
        while IFS= read -r F ; do
            echo "INSERT INTO ${LOG_TAB} (MSTR_ID, RUN_ID, SRC_OWNER, SRC_TABLE_NAME, TGT_OWNER, TGT_TABLE_NAME, MIG_TYPE, STATUS)" \
                 "VALUES ('$(_q "$(_hdr MSTR_ID "${F}")")', ${RUN_ID}," \
                 "'$(_q "$(_hdr SRC_OWNER "${F}")")', '$(_q "$(_hdr SRC_TABLE_NAME "${F}")")'," \
                 "'$(_q "$(_hdr TGT_OWNER "${F}")")', '$(_q "$(_hdr TGT_TABLE_NAME "${F}")")', '${PHASE}', 'PENDING');"
        done < ${TMP_LIST}
        echo "COMMIT;"
        echo "EXIT;"
    } > ${TMP_SQL}

    if ! _run_sql ${TMP_SQL} ; then
        _fail "Failed to register PENDING rows in ${LOG_TAB}"
        _show_db_errors
        return 1
    fi
    _ok "${TOTAL} table(s) registered as PENDING (RUN_ID=${RUN_ID})"

    RUN_START=$(date +%s)
    NUM=0 ; SUCC_CNT=0 ; FAIL_CNT=0 ; FAIL_LIST=""

    while IFS= read -r F <&3 ; do
        NUM=$(( NUM + 1 ))
        _exec_table "${F}" "${RUN_ID}" "${PHASE}" "$(_hdr MSTR_ID "${F}")" \
                    "$(_hdr SRC_OWNER "${F}")" "$(_hdr SRC_TABLE_NAME "${F}")" \
                    "$(_hdr TGT_OWNER "${F}")" "$(_hdr TGT_TABLE_NAME "${F}")" "${NUM}" "${TOTAL}"
        _count_result "$(_hdr SRC_OWNER "${F}").$(_hdr SRC_TABLE_NAME "${F}") -> $(basename "${F}")"
    done 3< ${TMP_LIST}

    _summary "${PHASE} (MSTR_ID=${MSTR_ID}, RUN_ID=${RUN_ID})" "${TOTAL}" "${RUN_START}"
    return 0
}

# ============================================================
# Retry FAILED : _retry <PRE|DDAY>
#   FAIL rows of MAX(RUN_ID) for MSTR_ID + phase ; same log rows are updated
# ============================================================
_fmt_fail() {
    local _t _so _st _to _tt _err _f
    while IFS='|' read -r _t _so _st _to _tt _err ; do
        _f="${CMD_DIR}/${PHASE}/${_to}_${_tt}.out"
        _out "  %s.%s -> %s.%s : %s %s\n" "${_so}" "${_st}" "${_to}" "${_tt}" "$(basename "${_f}")" "$([[ -f "${_f}" ]] || echo "[SQL file missing]")"
        _out "      last error : %s\n" "${_err}"
    done
}

_retry() {
    local PHASE="$1"
    local OUT_DIR="${CMD_DIR}/${PHASE}"
    local RUN_ID TOTAL MISS_CNT NUM SUCC_CNT FAIL_CNT FAIL_LIST RUN_START
    local _t SO ST TO TT _err F

    _new_log "RETRY_${PHASE}"
    _out "%s\n" "$SEP"
    _log "Retry ${PHASE} FAILED : MSTR_ID=${MSTR_ID}"
    _out "%s\n" "$SEP"

    # ROW|SRC_OWNER|SRC_TABLE_NAME|TGT_OWNER|TGT_TABLE_NAME|ERROR_MSG (first 200)
    cat > ${TMP_SQL} <<EOF
$(_sql_head)
SELECT 'RUN_ID|' || MAX(RUN_ID) FROM ${LOG_TAB} WHERE MSTR_ID = '${M_ID}' AND MIG_TYPE = '${PHASE}';
SELECT 'ROW|' || SRC_OWNER || '|' || SRC_TABLE_NAME || '|' || TGT_OWNER || '|' || TGT_TABLE_NAME
       || '|' || SUBSTR(ERROR_MSG, 1, 200)
  FROM ${LOG_TAB}
 WHERE MSTR_ID = '${M_ID}'
   AND MIG_TYPE = '${PHASE}'
   AND STATUS = 'FAIL'
   AND RUN_ID = (SELECT MAX(RUN_ID) FROM ${LOG_TAB} WHERE MSTR_ID = '${M_ID}' AND MIG_TYPE = '${PHASE}')
 ORDER BY SRC_OWNER, SRC_TABLE_NAME;
EXIT;
EOF

    if ! _run_sql ${TMP_SQL} ; then
        _fail "Failed to read ${LOG_TAB}"
        _show_db_errors
        return 1
    fi

    RUN_ID=$(_get RUN_ID)
    if [[ -z "${RUN_ID}" ]] ; then
        _fail "No ${PHASE} run in ${LOG_TAB} for MSTR_ID='${MSTR_ID}'"
        return 1
    fi

    grep '^ROW|' ${TMP_OUT} | sed 's/[[:space:]]*$//' > ${TMP_LIST}
    TOTAL=$(wc -l < ${TMP_LIST} | tr -d ' ')
    if [[ ${TOTAL} -eq 0 ]] ; then
        _ok "No FAIL table in the latest ${PHASE} run (RUN_ID=${RUN_ID})"
        return 0
    fi

    MISS_CNT=0
    while IFS='|' read -r _t SO ST TO TT _err ; do
        [[ -f "${OUT_DIR}/${TO}_${TT}.out" ]] || MISS_CNT=$(( MISS_CNT + 1 ))
    done < ${TMP_LIST}

    _out "  RUN_ID            : %s (latest %s run)\n" "${RUN_ID}" "${PHASE}"
    _out "  FAIL tables       : %s\n" "${TOTAL}"
    _out "  SQL file missing  : %s (will stay FAIL)\n\n" "${MISS_CNT}"
    _head_tail ${TMP_LIST} _fmt_fail

    if ! _confirm "Retry ${TOTAL} FAIL table(s) of ${PHASE} RUN_ID=${RUN_ID}?" ; then
        _log "Retry ${PHASE} FAILED cancelled by user"
        return 0
    fi

    RUN_START=$(date +%s)
    NUM=0 ; SUCC_CNT=0 ; FAIL_CNT=0 ; FAIL_LIST=""

    while IFS='|' read -r _t SO ST TO TT _err <&3 ; do
        NUM=$(( NUM + 1 ))
        F="${OUT_DIR}/${TO}_${TT}.out"
        _exec_table "${F}" "${RUN_ID}" "${PHASE}" "${MSTR_ID}" "${SO}" "${ST}" "${TO}" "${TT}" "${NUM}" "${TOTAL}"
        _count_result "${SO}.${ST} -> $(basename "${F}")"
    done 3< ${TMP_LIST}

    _summary "Retry ${PHASE} FAILED (MSTR_ID=${MSTR_ID}, RUN_ID=${RUN_ID})" "${TOTAL}" "${RUN_START}"
    return 0
}

# ============================================================
# Menu
# ============================================================
while true ; do
    LOGFILE="/dev/null"
    printf "\n%s\n" "$SEP"
    printf " DATA MIGRATION   MSTR_ID=%s  DB_TYPE=%s  SRC_DBLINK=%s\n" "${MSTR_ID}" "${DB_TYPE}" "${SRC_DBLINK}"
    printf "%s\n" "$SEP"
    printf " [PRE]\n"
    printf "  1. Generate PRE  SQL      (cmd/PRE  : %s file(s))\n" "$(_out_cnt PRE)"
    printf "  2. Run      PRE  migration\n"
    printf "  3. Retry    PRE  FAILED\n"
    printf " [DDAY]\n"
    printf "  4. Generate DDAY SQL      (cmd/DDAY : %s file(s))\n" "$(_out_cnt DDAY)"
    printf "  5. Run      DDAY migration\n"
    printf "  6. Retry    DDAY FAILED\n"
    printf "\n  q. Quit\n"
    printf "%s\n" "$SEP"
    printf "Select: "
    read -r SEL || break

    case "${SEL}" in
        1)   _generate PRE ;;
        2)   _run PRE ;;
        3)   _retry PRE ;;
        4)   _generate DDAY ;;
        5)   _run DDAY ;;
        6)   _retry DDAY ;;
        q|Q) break ;;
        *)   echo "[FAIL] Invalid selection: ${SEL}" ;;
    esac
done

exit 0
