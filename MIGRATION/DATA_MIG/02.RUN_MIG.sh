#!/bin/bash
# ============================================================
# 02.RUN_MIG.sh
# Data migration menu driven by DBADM.DBM_MIG_MSTR (spec : MIG_RUN_PLAN.md)
#
#   main menu : [R] Run (r / R) , [l] Total Log , [s] Status , [S] Stop , [h] Hint , [q] Quit
#               (s and S are case sensitive ; after one [R] action the main menu comes back)
#
#   [R] Run
#   [PRE]
#   [1] Generate PRE SQL  -> ./cmd/PRE/{TGT_OWNER}_{TGT_TABLE_NAME}__{SRC_OWNER}_{SRC_TABLE_NAME}.out
#        MIG_TYPE = PRE  AND MIG_FULL = COND : COL_CONDITION >= 'PRE1' AND COL_CONDITION < 'PRE2'
#   [2] Run PRE           : every .out file in ./cmd/PRE                   (background)
#   [3] Retry PRE FAILED  : FAIL tables of the latest PRE RUN_ID            (background)
#   [DDAY]
#   [4] Generate DDAY SQL -> ./cmd/DDAY/{TGT_OWNER}_{TGT_TABLE_NAME}__{SRC_OWNER}_{SRC_TABLE_NAME}.out
#        MIG_TYPE = PRE  AND MIG_FULL = COND : COL_CONDITION >= 'PRE3' (rest of the data)
#        MIG_TYPE = DDAY AND MIG_FULL = FULL : no condition (full)
#   [5] Run DDAY          : every .out file in ./cmd/DDAY                   (background)
#   [6] Retry DDAY FAILED : FAIL tables of the latest DDAY RUN_ID           (background)
#   [b] Back to the main menu
#
#   [l] Total Log         : tail -F of the running (or last) progress log, q + Enter returns
#   [s] Status            : DBM_XDN_LOG counts of the running (or last) RUN_ID
#   [S] Stop              : stop after the current table (remaining tables are not run)
#   [h] Hint              : PARALLEL degree saved in ./MIG_HINT.conf (default 4, 1 = serial)
#
#   - hints are put in at run time (2/3/5/6), .out files stay without hints :
#       INSERT INTO -> INSERT /*+ APPEND PARALLEL(n) */ INTO
#       SELECT      -> SELECT /*+ PARALLEL(n) */            (lines starting with SELECT, not already hinted)
#       ALTER SESSION ENABLE PARALLEL DML before the INSERT when n > 1
#     executed SQL (with hints) is kept in the _detail.log ; a running worker keeps the hint it started with
#
#   - run / retry : preview + confirm in the menu, then a background worker (nohup) does the work ;
#                   it keeps running after the menu quits or the session disconnects
#                   only one worker at a time (./log/.run.lock)
#   - logs        : ./log/{RUN|RETRY}_{PHASE}_{MSTR_ID}_R{RUN_ID}_{ts}.log  progress, one block per table
#                   ./log/..._detail.log                                  executed SQL + DB client output
#                   ./log/current.log -> progress log of the latest run  (tail -F log/current.log)
#                   a "Running" line every HEARTBEAT_SEC (MIG.env, default 300) while a table runs
#   - target rows : MSTR_ID (MIG.env) AND MIG_YN = 'Y' ; other MIG_TYPE / MIG_FULL combinations excluded
#   - TRANS_YN    : N -> INSERT INTO TGT SELECT * FROM SRC
#                   Y -> column list in target ALL_TAB_COLUMNS order ; same name unless DBM_MIG_COL_MAP says
#                        RENAME : SELECT SRC_COL        ADD : SELECT DEFAULT_VAL (NULL -> column left out)
#                        (DBM_MIG_COL_MAP key : target table + source table + TGT_COL -> N:1 merge per source)
#   - count check : Inserted rows vs SRC count ; ROW_CNT_TGT = target table count (1:N row split not supported)
#   - generate    : existing .out files of the phase directory are deleted first (confirm)
#                   .out header comments (-- KEY : value) keep the log key and count condition
#   - run         : new RUN_ID (MAX + 1) per run ; DBM_XDN_LOG.MIG_TYPE = phase (PRE / DDAY)
#                   PENDING -> RUNNING -> SUCCESS / FAIL, ROW_CNT_SRC / ROW_CNT_TGT, ERROR_MSG
#   - retry       : FAIL rows of MAX(RUN_ID) for MSTR_ID + phase, re-run ./cmd/<phase>/{TGT}__{SRC}.out
#                   the same DBM_XDN_LOG rows are updated (no new RUN_ID)
#   - sequential ; a failed table is logged as FAIL and the run continues
#   - INSERT only ; target data is never truncated / deleted
#   - connects to the target DB only (control tables live there) ; plain SQL only
# Usage: 02.RUN_MIG.sh                                                        (menu)
#        02.RUN_MIG.sh --worker <RUN|RETRY> <PRE|DDAY> <RUN_ID> <LOG_FILE>    (internal, started by the menu)
# ============================================================

# --- Load environment variables ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"
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

[[ "${HEARTBEAT_SEC}" =~ ^[1-9][0-9]*$ ]] || HEARTBEAT_SEC=300

DB_CONN="${DB_USER}/${DB_PASS}${DB_TNS:+@${DB_TNS}}"

MSTR_TAB="DBADM.DBM_MIG_MSTR"
LOG_TAB="DBADM.DBM_XDN_LOG"
MAP_TAB="DBADM.DBM_MIG_COL_MAP"

NL=$'\n'
SEP="============================================================"
DASH="------------------------------------------------------------"

CMD_DIR="${SCRIPT_DIR}/cmd"
LOG_DIR="${SCRIPT_DIR}/log"
TMP_DIR="${BASE_PATH}/tmp"
mkdir -p "${CMD_DIR}/PRE" "${CMD_DIR}/DDAY" "${LOG_DIR}" "${TMP_DIR}"

LOCK_FILE="${LOG_DIR}/.run.lock"      # PID|ACTION|PHASE|RUN_ID|LOG|START
STATE_FILE="${LOG_DIR}/.run.state"    # NUM|TOTAL|current table
STOP_FILE="${LOG_DIR}/.run.stop"      # exists = stop after the current table
CURRENT_LOG="${LOG_DIR}/current.log"
HINT_CONF="${SCRIPT_DIR}/MIG_HINT.conf"   # PARALLEL_DEGREE=<n>

TMP_SQL="${TMP_DIR}/RUN_MIG_$$.sql"
TMP_OUT="${TMP_DIR}/RUN_MIG_$$.out"
TMP_LIST="${TMP_DIR}/RUN_MIG_LIST_$$.lst"
TMP_RUN="${TMP_DIR}/RUN_MIG_RUN_$$.lst"
TMP_COLS="${TMP_DIR}/RUN_MIG_COLS_$$.lst"
TMP_TCOL="${TMP_DIR}/RUN_MIG_TCOL_$$.lst"

LOGFILE="/dev/null"     # progress log (menu actions : per action, worker : argument)
DETAIL_LOG=""           # worker only
TAIL_PID="" ; HB_PID=""

# _out: Print to terminal and append to log file
_out() {
    printf "$@"
    printf "$@" >> ${LOGFILE}
}

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

_cleanup() {
    [[ -n "${TAIL_PID}" ]] && kill ${TAIL_PID} 2>/dev/null
    [[ -n "${HB_PID}" ]] && kill ${HB_PID} 2>/dev/null
    rm -f ${TMP_SQL} ${TMP_OUT} ${TMP_LIST} ${TMP_RUN} ${TMP_COLS} ${TMP_TCOL}
}
trap _cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

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
#   query result lines ("TAG|value", e.g. ERROR_MSG read back) are data, not errors
_db_errors() { grep -Ev '^[A-Z_]+\|' ${TMP_OUT} | grep -E '(ORA|TBR|SP2)-[0-9]+'; }

# _run_sql <SQL_FILE> : output -> TMP_OUT (+ DETAIL_LOG) ; returns 1 on client error or DB error code in output
_run_sql() {
    ${DB_CLIENT} -s "${DB_CONN}" @"$1" < /dev/null > ${TMP_OUT} 2>&1
    local _rc=$?
    if [[ -n "${DETAIL_LOG}" ]] ; then
        {
            echo "----- [$(date '+%Y-%m-%d %H:%M:%S')] SQL (rc=${_rc})"
            cat "$1"
            echo "----- output"
            cat ${TMP_OUT}
        } >> "${DETAIL_LOG}"
    fi
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

# _out_name <TGT_OWNER> <TGT_TABLE> <SRC_OWNER> <SRC_TABLE> : {TGT_OWNER}_{TGT_TABLE_NAME}__{SRC_OWNER}_{SRC_TABLE_NAME}.out
_out_name() { printf "%s_%s__%s_%s.out" "$1" "$2" "$3" "$4"; }

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

# _num <number> : 1234567 -> 1,234,567 (empty -> -)
_num() {
    if [[ "$1" =~ ^[0-9]+$ ]] ; then
        echo "$1" | awk '{ n = $0; s = ""; while (length(n) > 3) { s = "," substr(n, length(n) - 2) s; n = substr(n, 1, length(n) - 3) } printf "%s%s", n, s }'
    else
        printf "%s" "${1:--}"
    fi
}

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

# ============================================================
# Hint : PARALLEL degree from MIG_HINT.conf
# ============================================================
# _hint_load : PARALLEL_DEGREE / INS_HINT / SEL_HINT / PDML
_hint_load() {
    PARALLEL_DEGREE=""
    [[ -f "${HINT_CONF}" ]] && PARALLEL_DEGREE=$(sed -n 's/^PARALLEL_DEGREE=//p' "${HINT_CONF}" | tail -1 | tr -d '[:space:]')
    [[ "${PARALLEL_DEGREE}" =~ ^[1-9][0-9]*$ ]] || PARALLEL_DEGREE=4
    if [[ ${PARALLEL_DEGREE} -gt 1 ]] ; then
        INS_HINT="APPEND PARALLEL(${PARALLEL_DEGREE})"
        SEL_HINT="PARALLEL(${PARALLEL_DEGREE})"
        PDML="Y"
    else
        INS_HINT="APPEND"
        SEL_HINT=""
        PDML="N"
    fi
}

# _hint_text : one line description of the current hint
_hint_text() {
    local _sel="(no hint)"
    [[ -n "${SEL_HINT}" ]] && _sel="/*+ ${SEL_HINT} */"
    printf "INSERT /*+ %s */ , SELECT %s" "${INS_HINT}" "${_sel}"
    [[ "${PDML}" == "Y" ]] && printf " , PARALLEL DML"
    return 0
}

# _apply_hint <OUT_FILE> : .out content with the hints on lines starting with "INSERT INTO " / "SELECT "
#   a SELECT line that already has a hint (edited by hand) is left as it is
_apply_hint() {
    local _ins="" _sel=""
    [[ -n "${INS_HINT}" ]] && _ins="/*+ ${INS_HINT} */ "
    [[ -n "${SEL_HINT}" ]] && _sel="/*+ ${SEL_HINT} */ "
    sed -e "s#^INSERT INTO #INSERT ${_ins}INTO #" \
        -e "/^SELECT[[:space:]]*\/\*+/!s#^SELECT #SELECT ${_sel}#" "$1"
}

# _hint_setting : [h] Hint
_hint_setting() {
    local _n
    _hint_load
    echo "$SEP"
    printf " [HINT] PARALLEL degree = %s   (%s)\n" "${PARALLEL_DEGREE}" "${HINT_CONF}"
    printf "        %s\n" "$(_hint_text)"
    echo "$SEP"
    printf "New PARALLEL degree (1 = serial, Enter = keep %s): " "${PARALLEL_DEGREE}"
    read -r _n
    if [[ -z "${_n}" ]] ; then
        echo "[OK]   Hint unchanged"
        return 0
    fi
    if ! [[ "${_n}" =~ ^[1-9][0-9]*$ ]] ; then
        echo "[FAIL] PARALLEL degree must be a positive integer : ${_n}"
        return 1
    fi
    {
        echo "# 02.RUN_MIG.sh hint setting ([h] Hint) : INSERT /*+ APPEND PARALLEL(n) */, SELECT /*+ PARALLEL(n) */, 1 = serial"
        echo "PARALLEL_DEGREE=${_n}"
    } > "${HINT_CONF}"
    _hint_load
    echo "[OK]   Saved : $(_hint_text)"
    if _lock_read ; then
        echo "       running ${L_ACTION} ${L_PHASE} (RUN_ID=${L_RUN_ID}) keeps its hint ; applied from the next run / retry"
    fi
}

M_ID=$(_q "${MSTR_ID}")
TARGET_WHERE="MSTR_ID = '${M_ID}' AND MIG_YN = 'Y'"

# ============================================================
# Background worker lock
# ============================================================
# _lock_read : sets L_PID L_ACTION L_PHASE L_RUN_ID L_LOG L_START
#   returns 0 when a live worker holds the lock ; a stale lock (dead PID) is removed
_lock_read() {
    L_PID="" ; L_ACTION="" ; L_PHASE="" ; L_RUN_ID="" ; L_LOG="" ; L_START=""
    [[ -f "${LOCK_FILE}" ]] || return 1
    IFS='|' read -r L_PID L_ACTION L_PHASE L_RUN_ID L_LOG L_START < "${LOCK_FILE}"
    if [[ -n "${L_PID}" ]] && kill -0 "${L_PID}" 2>/dev/null ; then
        return 0
    fi
    rm -f "${LOCK_FILE}" "${STATE_FILE}"
    return 1
}

# _busy : 0 (blocked) when a background migration is running
_busy() {
    if _lock_read ; then
        echo "[FAIL] Background migration is running : ${L_ACTION} ${L_PHASE} RUN_ID=${L_RUN_ID} PID=${L_PID}"
        echo "       wait until it ends, or use [S] Stop"
        return 0
    fi
    return 1
}

# _busy_phase <PHASE> : 0 (blocked) when the running migration uses the same phase directory
_busy_phase() {
    if _lock_read && [[ "${L_PHASE}" == "$1" ]] ; then
        echo "[FAIL] ${L_ACTION} ${L_PHASE} is running (RUN_ID=${L_RUN_ID}) : cmd/$1 can not be regenerated now"
        return 0
    fi
    return 1
}

# _launch <RUN|RETRY> <PHASE> <RUN_ID> : start the background worker
_launch() {
    local _action="$1" _phase="$2" _rid="$3" _log _pid _now

    _log="${LOG_DIR}/${_action}_${_phase}_${MSTR_ID}_R${_rid}_$(date '+%Y%m%d_%H%M%S').log"
    _now=$(date '+%Y-%m-%d %H:%M:%S')

    _busy && return 1
    if ! ( set -o noclobber ; printf "%s|%s|%s|%s|%s|%s\n" "$$" "${_action}" "${_phase}" "${_rid}" "${_log}" "${_now}" > "${LOCK_FILE}" ) 2>/dev/null ; then
        echo "[FAIL] Could not create ${LOCK_FILE} (another migration just started?)"
        return 1
    fi
    rm -f "${STOP_FILE}" "${STATE_FILE}"

    nohup "${SCRIPT_PATH}" --worker "${_action}" "${_phase}" "${_rid}" "${_log}" > /dev/null 2>&1 < /dev/null &
    _pid=$!
    printf "%s|%s|%s|%s|%s|%s\n" "${_pid}" "${_action}" "${_phase}" "${_rid}" "${_log}" "${_now}" > "${LOCK_FILE}"

    sleep 1
    if ! kill -0 "${_pid}" 2>/dev/null && [[ ! -s "${_log}" ]] ; then
        rm -f "${LOCK_FILE}"
        echo "[FAIL] Background worker did not start (PID=${_pid})"
        return 1
    fi

    echo "[OK]   ${_action} ${_phase} started in background (RUN_ID=${_rid}, PID=${_pid})"
    echo "       log  : ${_log}"
    echo "       view : [l] Total Log   or   tail -F ${CURRENT_LOG}"
    return 0
}

# ============================================================
# [R] 1 / 4. Generate SQL : _generate <PRE|DDAY>   (foreground)
# ============================================================
_fmt_row() {
    local _t _c _tr _so _st _to _tt _mt _mf _w
    while IFS='|' read -r _t _c _tr _so _st _to _tt _mt _mf _w ; do
        _out "  %s.%s -> %s.%s [%s/%s%s] %s\n" "${_so}" "${_st}" "${_to}" "${_tt}" "${_mt}" "${_mf}" \
             "$([[ "${_tr}" == "Y" ]] && echo "/COL_MAP")" "${_w:-(no condition)}"
    done
}

_generate() {
    local PHASE="$1"
    local OUT_DIR="${CMD_DIR}/${PHASE}"
    local TGT_COND WHERE_EXPR TOTAL RUN_CNT EXCL_CNT MAP_CNT OLD_CNT GEN_CNT DUP_CNT
    local _t _c TR SO ST TO TT MT MF WHERE_CLAUSE OUT_FILE
    local _k _so _st _o _n _flag COL EXPR COL_CNT REN_CNT ADD_CNT SKIP_CNT COL_LIST SEL_LIST

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

    # ROW|RUN,EXCL|TRANS_YN|SRC_OWNER|SRC_TABLE_NAME|TGT_OWNER|TGT_TABLE_NAME|MIG_TYPE|MIG_FULL|WHERE clause
    # COL|SRC_OWNER|SRC_TABLE_NAME|TGT_OWNER|TGT_TABLE_NAME|MAP_FLAG|TGT column|SELECT expression
    #     (TRANS_YN = 'Y' targets, per source -> target pair, target COLUMN_ID order)
    cat > ${TMP_SQL} <<EOF
$(_sql_head)
SELECT 'ROW|'
       || CASE WHEN (${TGT_COND}) THEN 'RUN' ELSE 'EXCL' END
       || '|' || NVL(TRANS_YN, 'N')
       || '|' || SRC_OWNER || '|' || SRC_TABLE_NAME || '|' || TGT_OWNER || '|' || TGT_TABLE_NAME
       || '|' || MIG_TYPE || '|' || MIG_FULL || '|'
       || CASE WHEN (${TGT_COND}) THEN ${WHERE_EXPR} END
  FROM ${MSTR_TAB}
 WHERE ${TARGET_WHERE}
 ORDER BY SRC_OWNER, SRC_TABLE_NAME;
SELECT 'COL|' || M.SRC_OWNER || '|' || M.SRC_TABLE_NAME || '|' || M.TGT_OWNER || '|' || M.TGT_TABLE_NAME
       || '|' || NVL(P.MAP_FLAG, '-') || '|' || C.COLUMN_NAME || '|'
       || CASE WHEN P.MAP_FLAG = 'RENAME' THEN P.SRC_COL
               WHEN P.MAP_FLAG = 'ADD'    THEN P.DEFAULT_VAL
               ELSE C.COLUMN_NAME
          END
  FROM ${MSTR_TAB} M
  JOIN ALL_TAB_COLUMNS C
    ON C.OWNER = M.TGT_OWNER AND C.TABLE_NAME = M.TGT_TABLE_NAME
  LEFT JOIN ${MAP_TAB} P
    ON P.TGT_OWNER = M.TGT_OWNER AND P.TGT_TABLE_NAME = M.TGT_TABLE_NAME
   AND P.SRC_OWNER = M.SRC_OWNER AND P.SRC_TABLE_NAME = M.SRC_TABLE_NAME
   AND P.TGT_COL = C.COLUMN_NAME
 WHERE M.MSTR_ID = '${M_ID}' AND M.MIG_YN = 'Y' AND NVL(M.TRANS_YN, 'N') = 'Y'
   AND (${TGT_COND})
 ORDER BY M.SRC_OWNER, M.SRC_TABLE_NAME, M.TGT_OWNER, M.TGT_TABLE_NAME, C.COLUMN_ID;
EXIT;
EOF

    if ! _run_sql ${TMP_SQL} ; then
        _fail "Failed to read ${MSTR_TAB}"
        _show_db_errors
        return 1
    fi

    grep '^ROW|' ${TMP_OUT} | sed 's/[[:space:]]*$//' > ${TMP_LIST}
    grep '^COL|' ${TMP_OUT} | sed 's/[[:space:]]*$//' > ${TMP_COLS}
    awk -F'|' '$2 == "RUN"' ${TMP_LIST} > ${TMP_RUN}

    TOTAL=$(wc -l < ${TMP_LIST} | tr -d ' ')
    RUN_CNT=$(wc -l < ${TMP_RUN} | tr -d ' ')
    MAP_CNT=$(awk -F'|' '$3 == "Y"' ${TMP_RUN} | wc -l | tr -d ' ')
    EXCL_CNT=$(awk -F'|' '$2 == "EXCL"' ${TMP_LIST} | wc -l | tr -d ' ')
    OLD_CNT=$(_out_cnt ${PHASE})

    _out "  MIG_YN=Y rows  : %s\n" "${TOTAL}"
    _out "  Generate       : %s (TRANS_YN=Y column list by %s : %s)\n" "${RUN_CNT}" "${MAP_TAB}" "${MAP_CNT}"
    _out "  Excluded       : %s (not a %s target by MIG_TYPE / MIG_FULL)\n" "${EXCL_CNT}" "${PHASE}"
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

    while IFS='|' read -r _t _c TR SO ST TO TT MT MF WHERE_CLAUSE <&3 ; do
        OUT_FILE="${OUT_DIR}/$(_out_name "${TO}" "${TT}" "${SO}" "${ST}")"
        if [[ -f "${OUT_FILE}" ]] ; then
            _out "  [WARN] duplicate row %s.%s -> %s.%s : %s overwritten\n" "${SO}" "${ST}" "${TO}" "${TT}" "$(basename "${OUT_FILE}")"
            DUP_CNT=$(( DUP_CNT + 1 ))
        else
            GEN_CNT=$(( GEN_CNT + 1 ))
        fi

        # --- TRANS_YN = 'Y' : column list in target column order, RENAME / ADD from DBM_MIG_COL_MAP ---
        COL_LIST="" ; SEL_LIST="" ; COL_CNT=0 ; REN_CNT=0 ; ADD_CNT=0 ; SKIP_CNT=0
        if [[ "${TR}" == "Y" ]] ; then
            awk -F'|' -v so="${SO}" -v st="${ST}" -v o="${TO}" -v t="${TT}" \
                '$2 == so && $3 == st && $4 == o && $5 == t' ${TMP_COLS} > ${TMP_TCOL}
            while IFS='|' read -r _k _so _st _o _n _flag COL EXPR ; do
                [[ "${_flag}" == "RENAME" ]] && REN_CNT=$(( REN_CNT + 1 ))
                [[ "${_flag}" == "ADD" ]]    && ADD_CNT=$(( ADD_CNT + 1 ))
                if [[ -z "${EXPR}" ]] ; then
                    SKIP_CNT=$(( SKIP_CNT + 1 ))
                    continue
                fi
                COL_CNT=$(( COL_CNT + 1 ))
                if [[ ${COL_CNT} -eq 1 ]] ; then
                    COL_LIST="       (${COL}"
                    SEL_LIST="SELECT  ${EXPR}"
                else
                    COL_LIST="${COL_LIST}${NL}      , ${COL}"
                    SEL_LIST="${SEL_LIST}${NL}      , ${EXPR}"
                fi
            done < ${TMP_TCOL}
            if [[ ${COL_CNT} -eq 0 ]] ; then
                _out "  [WARN] %s.%s : TRANS_YN=Y but no column in ALL_TAB_COLUMNS, SELECT * written\n" "${TO}" "${TT}"
            fi
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
            echo "-- TRANS_YN       : ${TR}"
            if [[ "${TR}" == "Y" ]] ; then
                echo "-- COL_MAP        : columns ${COL_CNT} (RENAME ${REN_CNT}, ADD ${ADD_CNT}, left out ${SKIP_CNT})"
            fi
            echo "-- GENERATED      : $(date '+%Y-%m-%d %H:%M:%S')"
            echo "INSERT INTO ${TO}.${TT}"
            if [[ ${COL_CNT} -gt 0 ]] ; then
                echo "${COL_LIST})"
                echo "${SEL_LIST}"
                echo "  FROM ${SO}.${ST}@${SRC_DBLINK}${WHERE_CLAUSE:+ ${WHERE_CLAUSE}};"
            else
                echo "SELECT * FROM ${SO}.${ST}@${SRC_DBLINK}${WHERE_CLAUSE:+ ${WHERE_CLAUSE}};"
            fi
            echo "COMMIT;"
        } > "${OUT_FILE}"
    done 3< ${TMP_RUN}

    _ok "${GEN_CNT} SQL file(s) generated in ${OUT_DIR}"
    [[ ${DUP_CNT} -gt 0 ]] && _out "  [WARN] %s duplicate target row(s) overwritten\n" "${DUP_CNT}"
    return 0
}

# ============================================================
# [R] 2 / 5. Run : preview + confirm in the menu, work in the background worker
# ============================================================
_fmt_file() {
    local _f _w
    while IFS= read -r _f ; do
        _w=$(_hdr CONDITION "${_f}")
        _out "  %s.%s -> %s.%s %s\n" "$(_hdr SRC_OWNER "${_f}")" "$(_hdr SRC_TABLE_NAME "${_f}")" \
             "$(_hdr TGT_OWNER "${_f}")" "$(_hdr TGT_TABLE_NAME "${_f}")" "${_w:-(no condition)}"
    done
}

_menu_run() {
    local PHASE="$1"
    local OUT_DIR="${CMD_DIR}/${PHASE}"
    local TOTAL RUN_ID

    _out "%s\n" "$SEP"
    _log "Run ${PHASE} migration : ${OUT_DIR}"
    _out "%s\n" "$SEP"

    find "${OUT_DIR}" -maxdepth 1 -name '*.out' 2>/dev/null | sort > ${TMP_LIST}
    TOTAL=$(wc -l < ${TMP_LIST} | tr -d ' ')
    if [[ ${TOTAL} -eq 0 ]] ; then
        _fail "No .out file in ${OUT_DIR} (generate ${PHASE} SQL first)"
        return 1
    fi

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
    _out "  SQL files : %s\n" "${TOTAL}"
    _out "  Hint      : %s\n\n" "$(_hint_text)"
    _head_tail ${TMP_LIST} _fmt_file

    if ! _confirm "Run ${TOTAL} ${PHASE} SQL file(s) in background (RUN_ID=${RUN_ID})?" ; then
        _log "Run ${PHASE} migration cancelled by user"
        return 0
    fi
    _launch RUN "${PHASE}" "${RUN_ID}"
}

# ============================================================
# [R] 3 / 6. Retry FAILED : FAIL rows of the latest RUN_ID of the phase
# ============================================================
_fmt_fail() {
    local _t _so _st _to _tt _err _f
    while IFS='|' read -r _t _so _st _to _tt _err ; do
        _f="${CMD_DIR}/${PHASE}/$(_out_name "${_to}" "${_tt}" "${_so}" "${_st}")"
        _out "  %s.%s -> %s.%s : %s %s\n" "${_so}" "${_st}" "${_to}" "${_tt}" "$(basename "${_f}")" "$([[ -f "${_f}" ]] || echo "[SQL file missing]")"
        _out "      last error : %s\n" "${_err}"
    done
}

# _fail_rows_sql <PHASE> <RUN_ID expression> : ROW|SRC_OWNER|SRC_TABLE_NAME|TGT_OWNER|TGT_TABLE_NAME|ERROR_MSG
_fail_rows_sql() {
    cat <<EOF
SELECT 'ROW|' || SRC_OWNER || '|' || SRC_TABLE_NAME || '|' || TGT_OWNER || '|' || TGT_TABLE_NAME
       || '|' || SUBSTR(ERROR_MSG, 1, 200)
  FROM ${LOG_TAB}
 WHERE MSTR_ID = '${M_ID}'
   AND MIG_TYPE = '$1'
   AND STATUS = 'FAIL'
   AND RUN_ID = $2
 ORDER BY SRC_OWNER, SRC_TABLE_NAME;
EOF
}

_menu_retry() {
    local PHASE="$1"
    local OUT_DIR="${CMD_DIR}/${PHASE}"
    local RUN_ID TOTAL MISS_CNT _t SO ST TO TT _err

    _out "%s\n" "$SEP"
    _log "Retry ${PHASE} FAILED : MSTR_ID=${MSTR_ID}"
    _out "%s\n" "$SEP"

    cat > ${TMP_SQL} <<EOF
$(_sql_head)
SELECT 'RUN_ID|' || MAX(RUN_ID) FROM ${LOG_TAB} WHERE MSTR_ID = '${M_ID}' AND MIG_TYPE = '${PHASE}';
$(_fail_rows_sql "${PHASE}" "(SELECT MAX(RUN_ID) FROM ${LOG_TAB} WHERE MSTR_ID = '${M_ID}' AND MIG_TYPE = '${PHASE}')")
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
        [[ -f "${OUT_DIR}/$(_out_name "${TO}" "${TT}" "${SO}" "${ST}")" ]] || MISS_CNT=$(( MISS_CNT + 1 ))
    done < ${TMP_LIST}

    _out "  RUN_ID            : %s (latest %s run)\n" "${RUN_ID}" "${PHASE}"
    _out "  FAIL tables       : %s\n" "${TOTAL}"
    _out "  SQL file missing  : %s (will stay FAIL)\n" "${MISS_CNT}"
    _out "  Hint              : %s\n\n" "$(_hint_text)"
    _head_tail ${TMP_LIST} _fmt_fail

    if ! _confirm "Retry ${TOTAL} FAIL table(s) of ${PHASE} RUN_ID=${RUN_ID} in background?" ; then
        _log "Retry ${PHASE} FAILED cancelled by user"
        return 0
    fi
    _launch RETRY "${PHASE}" "${RUN_ID}"
}

# ============================================================
# [l] Total Log : tail -F, only "q" + Enter returns (tail is killed, Ctrl+C ignored)
# ============================================================
_view_log() {
    local _log _key

    if _lock_read ; then
        _log="${L_LOG}"
    else
        _log=$(ls -t "${LOG_DIR}"/RUN_*.log "${LOG_DIR}"/RETRY_*.log 2>/dev/null | grep -v '_detail\.log$' | head -1)
    fi
    if [[ -z "${_log}" || ! -f "${_log}" ]] ; then
        echo "[FAIL] No migration log yet"
        return 1
    fi

    echo "$SEP"
    echo " tail -F ${_log}"
    echo " >>> type q + Enter to return to the menu <<<"
    echo "$SEP"

    trap '' INT
    tail -n 40 -F "${_log}" &
    TAIL_PID=$!
    while read -r _key ; do
        [[ "${_key}" == "q" || "${_key}" == "Q" ]] && break
    done
    kill ${TAIL_PID} 2>/dev/null
    wait ${TAIL_PID} 2>/dev/null
    TAIL_PID=""
    trap 'exit 130' INT
}

# ============================================================
# [s] Status : DBM_XDN_LOG of the running RUN_ID (or the latest RUN_ID of MSTR_ID)
# ============================================================
_status() {
    local RID_EXPR WORKER RID TYPE _s _c TOTAL DONE PCT T_START T_END _tbl _since _sec _err _fail_n
    local P_CNT R_CNT S_CNT F_CNT

    if _lock_read ; then
        RID_EXPR="${L_RUN_ID}"
        WORKER="RUNNING  ${L_ACTION} ${L_PHASE}  PID=${L_PID}  since ${L_START}"
    else
        RID_EXPR="(SELECT MAX(RUN_ID) FROM ${LOG_TAB} WHERE MSTR_ID = '${M_ID}')"
        WORKER="not running"
    fi

    cat > ${TMP_SQL} <<EOF
$(_sql_head)
SELECT 'RID|' || MAX(RUN_ID) || '|' || MAX(MIG_TYPE) FROM ${LOG_TAB} WHERE MSTR_ID = '${M_ID}' AND RUN_ID = ${RID_EXPR};
SELECT 'ST|' || STATUS || '|' || COUNT(*) FROM ${LOG_TAB} WHERE MSTR_ID = '${M_ID}' AND RUN_ID = ${RID_EXPR} GROUP BY STATUS;
SELECT 'TM|' || TO_CHAR(MIN(START_TIME), 'YYYY-MM-DD HH24:MI:SS') || '|' || TO_CHAR(MAX(END_TIME), 'YYYY-MM-DD HH24:MI:SS')
  FROM ${LOG_TAB} WHERE MSTR_ID = '${M_ID}' AND RUN_ID = ${RID_EXPR};
SELECT 'RUNNING|' || SRC_OWNER || '.' || SRC_TABLE_NAME || ' -> ' || TGT_OWNER || '.' || TGT_TABLE_NAME
       || '|' || TO_CHAR(START_TIME, 'YYYY-MM-DD HH24:MI:SS') || '|' || ROUND((SYSDATE - START_TIME) * 86400)
  FROM ${LOG_TAB} WHERE MSTR_ID = '${M_ID}' AND RUN_ID = ${RID_EXPR} AND STATUS = 'RUNNING';
SELECT 'FAIL|' || SRC_OWNER || '.' || SRC_TABLE_NAME || ' -> ' || TGT_OWNER || '.' || TGT_TABLE_NAME
       || '|' || SUBSTR(ERROR_MSG, 1, 100)
  FROM ${LOG_TAB} WHERE MSTR_ID = '${M_ID}' AND RUN_ID = ${RID_EXPR} AND STATUS = 'FAIL'
 ORDER BY SRC_OWNER, SRC_TABLE_NAME;
EXIT;
EOF

    if ! _run_sql ${TMP_SQL} ; then
        echo "[FAIL] Failed to read ${LOG_TAB}"
        _db_errors | sed 's/^/  /'
        return 1
    fi

    RID=$(_get RID)
    if [[ -z "${RID}" ]] ; then
        echo "[FAIL] No run in ${LOG_TAB} for MSTR_ID='${MSTR_ID}'"
        return 1
    fi
    TYPE=$(grep '^RID|' ${TMP_OUT} | head -1 | cut -d'|' -f3 | tr -d '[:space:]')

    _cnt_of() { grep "^ST|$1|" ${TMP_OUT} | head -1 | cut -d'|' -f3 | tr -d '[:space:]'; }
    P_CNT=$(_cnt_of PENDING) ; R_CNT=$(_cnt_of RUNNING) ; S_CNT=$(_cnt_of SUCCESS) ; F_CNT=$(_cnt_of FAIL)
    P_CNT=${P_CNT:-0} ; R_CNT=${R_CNT:-0} ; S_CNT=${S_CNT:-0} ; F_CNT=${F_CNT:-0}
    TOTAL=$(( P_CNT + R_CNT + S_CNT + F_CNT ))
    DONE=$(( S_CNT + F_CNT ))
    [[ ${TOTAL} -gt 0 ]] && PCT=$(( DONE * 100 / TOTAL )) || PCT=0
    T_START=$(grep '^TM|' ${TMP_OUT} | head -1 | cut -d'|' -f2 | sed 's/[[:space:]]*$//')
    T_END=$(grep '^TM|' ${TMP_OUT} | head -1 | cut -d'|' -f3 | sed 's/[[:space:]]*$//')

    echo "$SEP"
    printf " [STATUS] MSTR_ID=%s  RUN_ID=%s  MIG_TYPE=%s\n" "${MSTR_ID}" "${RID}" "${TYPE}"
    printf "          worker : %s\n" "${WORKER}"
    echo "$SEP"
    printf "  PENDING  : %7s\n" "$(_num ${P_CNT})"
    printf "  RUNNING  : %7s\n" "$(_num ${R_CNT})"
    printf "  SUCCESS  : %7s\n" "$(_num ${S_CNT})"
    printf "  FAIL     : %7s\n" "$(_num ${F_CNT})"
    printf "  ------------------\n"
    printf "  TOTAL    : %7s   (done %s, %s%%)\n" "$(_num ${TOTAL})" "$(_num ${DONE})" "${PCT}"
    printf "  Start    : %s\n" "${T_START:--}"
    printf "  Last end : %s\n" "${T_END:--}"

    if [[ ${R_CNT} -gt 0 ]] ; then
        printf "\n  --- RUNNING ---\n"
        grep '^RUNNING|' ${TMP_OUT} | while IFS='|' read -r _t _tbl _since _sec ; do
            _sec=$(printf "%s" "${_sec}" | tr -d '[:space:]')
            printf "  %s   since %s  (%s)\n" "${_tbl}" "${_since}" "$(_fmt_sec ${_sec:-0})"
        done
        [[ "${WORKER}" == "not running" ]] && printf "  (worker is not running : these rows were interrupted)\n"
    fi

    if [[ ${F_CNT} -gt 0 ]] ; then
        printf "\n  --- FAIL (top 10 of %s) ---\n" "${F_CNT}"
        grep '^FAIL|' ${TMP_OUT} | head -10 | while IFS='|' read -r _t _tbl _err ; do
            printf "  %s   %s\n" "${_tbl}" "$(printf "%s" "${_err}" | sed 's/[[:space:]]*$//')"
        done
    fi
    echo "$SEP"
}

# ============================================================
# [S] Stop : the worker stops before its next table
# ============================================================
_stop() {
    if ! _lock_read ; then
        echo "[FAIL] No background migration is running"
        return 1
    fi
    if [[ -f "${STOP_FILE}" ]] ; then
        echo "[OK]   Stop already requested : ${L_ACTION} ${L_PHASE} RUN_ID=${L_RUN_ID} stops after the current table"
        return 0
    fi
    if ! _confirm "Stop ${L_ACTION} ${L_PHASE} RUN_ID=${L_RUN_ID} after the current table?" ; then
        return 0
    fi
    touch "${STOP_FILE}"
    echo "[OK]   Stop requested : the worker stops after the current table ([l] Total Log to follow)"
}

# ============================================================
# Worker : one table / progress / header / footer
# ============================================================
# _hb_start <start epoch> : "Running" line every HEARTBEAT_SEC until _hb_stop
_hb_start() {
    local _t0="$1"
    (
        trap - EXIT INT TERM HUP
        _s=0
        while sleep 1 ; do
            _s=$(( _s + 1 ))
            if (( _s % HEARTBEAT_SEC == 0 )) ; then
                _out "  Running   : %s elapsed  (%s)\n" "$(_fmt_sec $(( $(date +%s) - _t0 )))" "$(date '+%H:%M:%S')"
            fi
        done
    ) &
    HB_PID=$!
}

_hb_stop() {
    if [[ -n "${HB_PID}" ]] ; then
        kill ${HB_PID} 2>/dev/null
        wait ${HB_PID} 2>/dev/null
    fi
    HB_PID=""
}

# _exec_table <OUT_FILE> <RUN_ID> <PHASE> <MSTR_ID> <SRC_OWNER> <SRC_TABLE> <TGT_OWNER> <TGT_TABLE> <NUM> <TOTAL>
#   run one .out file, update its DBM_XDN_LOG row, write one block to the progress log
#   result -> EXEC_STATUS / EXEC_ERR / EXEC_LABEL
_exec_table() {
    local F="$1" RID="$2" PHASE="$3" MID="$4" SO="$5" ST="$6" TO="$7" TT="$8" NUM="$9" TOTAL="${10}"
    local DBL WHERE_CLAUSE SRC_OBJ TGT_OBJ KEY ERR_SQL CNT_SRC CNT_INS CNT_TGT T_START T_END _cmp

    TGT_OBJ="${TO}.${TT}"
    KEY="RUN_ID = ${RID} AND MSTR_ID = '$(_q "${MID}")' AND SRC_OWNER = '$(_q "${SO}")' AND SRC_TABLE_NAME = '$(_q "${ST}")' AND TGT_OWNER = '$(_q "${TO}")' AND TGT_TABLE_NAME = '$(_q "${TT}")' AND MIG_TYPE = '${PHASE}'"
    EXEC_STATUS="SUCCESS" ; EXEC_ERR="" ; EXEC_LABEL="${SO}.${ST} -> ${TGT_OBJ}"

    _out "\n%s\n" "$DASH"
    _out "[%*d/%s]  %s\n" "${#TOTAL}" "${NUM}" "${TOTAL}" "${EXEC_LABEL}"
    _out "%s\n" "$DASH"
    _out "  File      : %s\n" "$(basename "${F}")"

    # --- SQL file missing (retry only) : FAIL without running ---
    if [[ ! -f "${F}" ]] ; then
        EXEC_STATUS="FAIL" ; EXEC_ERR="SQL file not found : ${F}"
        cat > ${TMP_SQL} <<EOF
$(_sql_head)
UPDATE ${LOG_TAB} SET STATUS = 'FAIL', START_TIME = SYSDATE, END_TIME = SYSDATE, ERROR_MSG = '$(_q "${EXEC_ERR}")' WHERE ${KEY};
COMMIT;
EXIT;
EOF
        _run_sql ${TMP_SQL} || { _out "  Warning   : %s update error\n" "${LOG_TAB}" ; _show_db_errors ; }
        _out "  Result    : FAIL  %s\n" "${EXEC_ERR}"
        return
    fi

    DBL=$(_hdr SRC_DBLINK "${F}")
    WHERE_CLAUSE=$(_hdr CONDITION "${F}")
    SRC_OBJ="${SO}.${ST}@${DBL}"

    _out "  Condition : %s\n" "${WHERE_CLAUSE:-(none)}"
    T_START=$(date +%s)
    _out "  Start     : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    _hb_start "${T_START}"

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
        _out "  SRC count : %s\n" "$(_num "${CNT_SRC}")"

        # --- INSERT INTO SELECT + COMMIT from the .out file ---
        {
            echo "SET DEFINE OFF"
            echo "SET FEEDBACK ON"
            echo "WHENEVER SQLERROR EXIT FAILURE ROLLBACK"
            [[ "${PDML}" == "Y" ]] && echo "ALTER SESSION ENABLE PARALLEL DML;"
            _apply_hint "${F}"
            echo "EXIT;"
        } > ${TMP_SQL}

        if _run_sql ${TMP_SQL} ; then
            # "N rows created." (sqlplus) / "N rows inserted." (tbsql)
            CNT_INS=$(grep -Eo '^[0-9]+ rows? (created|inserted)' ${TMP_OUT} | head -1 | cut -d' ' -f1)
            # match check by inserted rows (target table count may include other sources of an N:1 merge)
            if [[ -z "${CNT_INS}" ]] ; then _cmp=""
            elif [[ "${CNT_INS}" == "${CNT_SRC}" ]] ; then _cmp="(= SRC)"
            else _cmp="(<> SRC)" ; fi
            _out "  Inserted  : %s %s\n" "$(_num "${CNT_INS}")" "${_cmp}"
        else
            EXEC_STATUS="FAIL"
        fi
    else
        EXEC_STATUS="FAIL"
    fi

    if [[ "${EXEC_STATUS}" == "FAIL" ]] ; then
        EXEC_ERR=$(_db_errors | tr '\n' ' ' | sed 's/[[:space:]]*$//' | awk '{ print substr($0, 1, 1000) }')
        [[ -z "${EXEC_ERR}" ]] && EXEC_ERR=$(tail -3 ${TMP_OUT} | tr '\n' ' ' | sed 's/[[:space:]]*$//' | awk '{ print substr($0, 1, 1000) }')
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
        _out "  Warning   : %s end update / target count error\n" "${LOG_TAB}"
        _db_errors | while IFS= read -r _line ; do _out "              %s\n" "${_line}" ; done
    fi
    CNT_TGT=$(_get CNT)
    _hb_stop

    T_END=$(date +%s)
    _out "  TGT count : %s\n" "$(_num "${CNT_TGT}")"
    _out "  End       : %s  (%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$(_fmt_sec $(( T_END - T_START )))"

    if [[ "${EXEC_STATUS}" == "SUCCESS" ]] ; then
        _out "  Result    : SUCCESS\n"
    else
        _out "  Result    : FAIL  %s\n" "${EXEC_ERR}"
    fi
}

# _count_result : add the last _exec_table result to SUCC_CNT / FAIL_CNT / FAIL_LIST
_count_result() {
    if [[ "${EXEC_STATUS}" == "SUCCESS" ]] ; then
        SUCC_CNT=$(( SUCC_CNT + 1 ))
    else
        FAIL_CNT=$(( FAIL_CNT + 1 ))
        FAIL_LIST="${FAIL_LIST}   ${EXEC_LABEL}  $(printf "%s" "${EXEC_ERR}" | awk '{ print substr($0, 1, 100) }')\n"
    fi
}

# _progress <NUM> <TOTAL> <start epoch>
_progress() {
    _out "  Progress  : %s/%s (%s%%)  SUCCESS %s  FAIL %s  total elapsed %s\n" \
         "$1" "$2" "$(( $1 * 100 / $2 ))" "${SUCC_CNT}" "${FAIL_CNT}" "$(_fmt_sec $(( $(date +%s) - $3 )))"
}

# _stop_requested <NUM done> <TOTAL> : 0 when the stop file exists (consumed)
_stop_requested() {
    [[ -f "${STOP_FILE}" ]] || return 1
    rm -f "${STOP_FILE}"
    STOPPED="Y"
    _out "\n[STOP] Stop requested by user : %s table(s) not run\n" "$(( $2 - $1 ))"
    return 0
}

# _run_header <RUN|RETRY> <PHASE> <RUN_ID> <TOTAL>
_run_header() {
    _out "%s\n" "$SEP"
    _out " [%s] %s  MSTR_ID=%s  RUN_ID=%s  TABLES=%s  PID=%s\n" "$1" "$2" "${MSTR_ID}" "$3" "$4" "$$"
    _out "       START=%s  DB=%s  DBLINK=%s  HEARTBEAT=%ss\n" "${RUN_START_STR}" "${DB_TYPE}" "${SRC_DBLINK}" "${HEARTBEAT_SEC}"
    _out "       HINT=%s\n" "$(_hint_text)"
    _out "       LOG=%s\n" "${LOGFILE}"
    _out "       DETAIL=%s\n" "${DETAIL_LOG}"
    _out "%s\n" "$SEP"
}

# _run_footer <RUN|RETRY> <PHASE> <RUN_ID> <TOTAL> <start epoch>
_run_footer() {
    local _end _result _menu
    _end=$(date +%s)
    _result="DONE" ; [[ "${STOPPED}" == "Y" ]] && _result="STOPPED"
    [[ "$2" == "PRE" ]] && _menu=3 || _menu=6

    _out "\n%s\n" "$SEP"
    _out " [END] %s %s  MSTR_ID=%s  RUN_ID=%s  RESULT=%s\n" "$1" "$2" "${MSTR_ID}" "$3" "${_result}"
    _out "       TOTAL=%s  SUCCESS=%s  FAIL=%s  NOT_RUN=%s\n" "$4" "${SUCC_CNT}" "${FAIL_CNT}" "$(( $4 - SUCC_CNT - FAIL_CNT ))"
    _out "       START=%s  END=%s  ELAPSED=%s\n" "${RUN_START_STR}" "$(date '+%Y-%m-%d %H:%M:%S')" "$(_fmt_sec $(( _end - $5 )))"
    if [[ ${FAIL_CNT} -gt 0 ]] ; then
        _out " FAILED :\n"
        _out "%b" "${FAIL_LIST}"
        _out " RETRY  : 02.RUN_MIG.sh -> [R] Run -> [%s] Retry %s FAILED\n" "${_menu}" "$2"
    fi
    if [[ "${STOPPED}" == "Y" && "$1" == "RUN" ]] ; then
        _out " NOT_RUN tables stay PENDING in %s (RUN_ID=%s)\n" "${LOG_TAB}" "$3"
    fi
    _out "%s\n" "$SEP"
}

# _worker_run <PHASE> <RUN_ID> : PENDING for every .out file, then run them in order
_worker_run() {
    local PHASE="$1" RUN_ID="$2"
    local OUT_DIR="${CMD_DIR}/${PHASE}"
    local TOTAL NUM F RUN_START

    find "${OUT_DIR}" -maxdepth 1 -name '*.out' 2>/dev/null | sort > ${TMP_LIST}
    TOTAL=$(wc -l < ${TMP_LIST} | tr -d ' ')
    RUN_START=$(date +%s) ; RUN_START_STR=$(date '+%Y-%m-%d %H:%M:%S')
    _run_header RUN "${PHASE}" "${RUN_ID}" "${TOTAL}"

    if [[ ${TOTAL} -eq 0 ]] ; then
        _fail "No .out file in ${OUT_DIR}"
        return 1
    fi

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
    _ok "${TOTAL} table(s) registered as PENDING"

    NUM=0
    while IFS= read -r F <&3 ; do
        _stop_requested "${NUM}" "${TOTAL}" && break
        NUM=$(( NUM + 1 ))
        printf "%s|%s|%s\n" "${NUM}" "${TOTAL}" "$(_hdr SRC_OWNER "${F}").$(_hdr SRC_TABLE_NAME "${F}") -> $(_hdr TGT_OWNER "${F}").$(_hdr TGT_TABLE_NAME "${F}")" > "${STATE_FILE}"
        _exec_table "${F}" "${RUN_ID}" "${PHASE}" "$(_hdr MSTR_ID "${F}")" \
                    "$(_hdr SRC_OWNER "${F}")" "$(_hdr SRC_TABLE_NAME "${F}")" \
                    "$(_hdr TGT_OWNER "${F}")" "$(_hdr TGT_TABLE_NAME "${F}")" "${NUM}" "${TOTAL}"
        _count_result
        _progress "${NUM}" "${TOTAL}" "${RUN_START}"
    done 3< ${TMP_LIST}

    _run_footer RUN "${PHASE}" "${RUN_ID}" "${TOTAL}" "${RUN_START}"
}

# _worker_retry <PHASE> <RUN_ID> : FAIL rows of RUN_ID, same log rows are updated
_worker_retry() {
    local PHASE="$1" RUN_ID="$2"
    local OUT_DIR="${CMD_DIR}/${PHASE}"
    local TOTAL NUM RUN_START _t SO ST TO TT _err

    RUN_START=$(date +%s) ; RUN_START_STR=$(date '+%Y-%m-%d %H:%M:%S')

    cat > ${TMP_SQL} <<EOF
$(_sql_head)
$(_fail_rows_sql "${PHASE}" "${RUN_ID}")
EXIT;
EOF
    if ! _run_sql ${TMP_SQL} ; then
        _run_header RETRY "${PHASE}" "${RUN_ID}" "?"
        _fail "Failed to read FAIL rows from ${LOG_TAB}"
        _show_db_errors
        return 1
    fi
    grep '^ROW|' ${TMP_OUT} | sed 's/[[:space:]]*$//' > ${TMP_LIST}
    TOTAL=$(wc -l < ${TMP_LIST} | tr -d ' ')
    _run_header RETRY "${PHASE}" "${RUN_ID}" "${TOTAL}"

    if [[ ${TOTAL} -eq 0 ]] ; then
        _ok "No FAIL table in ${PHASE} RUN_ID=${RUN_ID}"
        return 0
    fi

    NUM=0
    while IFS='|' read -r _t SO ST TO TT _err <&3 ; do
        _stop_requested "${NUM}" "${TOTAL}" && break
        NUM=$(( NUM + 1 ))
        printf "%s|%s|%s\n" "${NUM}" "${TOTAL}" "${SO}.${ST} -> ${TO}.${TT}" > "${STATE_FILE}"
        _exec_table "${OUT_DIR}/$(_out_name "${TO}" "${TT}" "${SO}" "${ST}")" "${RUN_ID}" "${PHASE}" "${MSTR_ID}" "${SO}" "${ST}" "${TO}" "${TT}" "${NUM}" "${TOTAL}"
        _count_result
        _progress "${NUM}" "${TOTAL}" "${RUN_START}"
    done 3< ${TMP_LIST}

    _run_footer RETRY "${PHASE}" "${RUN_ID}" "${TOTAL}" "${RUN_START}"
}

# _worker_exit : EXIT trap of the worker
_worker_exit() {
    local _p
    _hb_stop
    if [[ "${W_DONE}" != "Y" ]] ; then
        _out "\n[ABORT] worker terminated before the end (%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    fi
    { IFS='|' read -r _p _ < "${LOCK_FILE}" ; } 2>/dev/null
    [[ "${_p}" == "$$" ]] && rm -f "${LOCK_FILE}" "${STATE_FILE}"
    rm -f ${TMP_SQL} ${TMP_OUT} ${TMP_LIST} ${TMP_RUN} ${TMP_COLS} ${TMP_TCOL}
}

# ============================================================
# Worker entry (started by _launch through nohup)
# ============================================================
if [[ "$1" == "--worker" ]] ; then
    W_ACTION="$2" ; W_PHASE="$3" ; W_RUN_ID="$4" ; LOGFILE="$5"
    DETAIL_LOG="${LOGFILE%.log}_detail.log"
    _hint_load
    SUCC_CNT=0 ; FAIL_CNT=0 ; FAIL_LIST="" ; STOPPED="N" ; W_DONE="N"

    trap '' HUP INT
    trap _worker_exit EXIT
    trap 'exit 143' TERM

    : >> "${LOGFILE}"
    ln -sfn "${LOGFILE}" "${CURRENT_LOG}" 2>/dev/null

    case "${W_ACTION}" in
        RUN)   _worker_run   "${W_PHASE}" "${W_RUN_ID}" ;;
        RETRY) _worker_retry "${W_PHASE}" "${W_RUN_ID}" ;;
        *)     _fail "Unknown worker action : ${W_ACTION}" ;;
    esac
    W_DONE="Y"
    exit 0
fi

# ============================================================
# Menu
# ============================================================
_menu_status_line() {
    local _n _t _tbl
    if _lock_read ; then
        _n="" ; _t="" ; _tbl=""
        [[ -f "${STATE_FILE}" ]] && IFS='|' read -r _n _t _tbl < "${STATE_FILE}"
        printf " * RUNNING : %s %s  RUN_ID=%s  %s/%s  PID=%s  since %s\n" \
               "${L_ACTION}" "${L_PHASE}" "${L_RUN_ID}" "${_n:-0}" "${_t:-?}" "${L_PID}" "${L_START}"
        [[ -n "${_tbl}" ]] && printf "   current : %s\n" "${_tbl}"
        [[ -f "${STOP_FILE}" ]] && printf "   stop    : requested (stops after the current table)\n"
    else
        printf " * IDLE    : no background migration\n"
    fi
}

# _run_menu : [R] Run sub menu ; one action then back to the main menu ([b] = back without action)
#   returns 1 when stdin is closed (main menu ends too)
_run_menu() {
    local _sel
    while true ; do
        printf "\n%s\n" "$SEP"
        printf " RUN MENU   MSTR_ID=%s\n" "${MSTR_ID}"
        printf "%s\n" "$DASH"
        _menu_status_line
        printf "%s\n" "$SEP"
        printf " [PRE]\n"
        printf "  [1] Generate PRE  SQL      (cmd/PRE  : %s file(s))\n" "$(_out_cnt PRE)"
        printf "  [2] Run      PRE  migration   (background)\n"
        printf "  [3] Retry    PRE  FAILED      (background)\n"
        printf " [DDAY]\n"
        printf "  [4] Generate DDAY SQL      (cmd/DDAY : %s file(s))\n" "$(_out_cnt DDAY)"
        printf "  [5] Run      DDAY migration   (background)\n"
        printf "  [6] Retry    DDAY FAILED      (background)\n"
        printf "\n  [b] Back\n"
        printf "%s\n" "$SEP"
        printf "Select: "
        read -r _sel || return 1

        case "${_sel}" in
            1)   _busy_phase PRE  || _generate PRE ;;
            2)   _busy            || _menu_run PRE ;;
            3)   _busy            || _menu_retry PRE ;;
            4)   _busy_phase DDAY || _generate DDAY ;;
            5)   _busy            || _menu_run DDAY ;;
            6)   _busy            || _menu_retry DDAY ;;
            b|B) return 0 ;;
            *)   echo "[FAIL] Invalid selection: ${_sel}" ; continue ;;
        esac
        return 0
    done
}

while true ; do
    LOGFILE="/dev/null"
    _hint_load
    printf "\n%s\n" "$SEP"
    printf " DATA MIGRATION   MSTR_ID=%s  DB_TYPE=%s  SRC_DBLINK=%s\n" "${MSTR_ID}" "${DB_TYPE}" "${SRC_DBLINK}"
    printf "%s\n" "$DASH"
    _menu_status_line
    printf "%s\n" "$SEP"
    printf "  [R] Run         (SQL generate / migration / retry)\n"
    printf "  [l] Total Log   (tail -F, q + Enter to return)\n"
    printf "  [s] Status      (%s)\n" "${LOG_TAB}"
    printf "  [S] Stop        (after the current table)\n"
    printf "  [h] Hint        (PARALLEL %s : %s)\n" "${PARALLEL_DEGREE}" "$(_hint_text)"
    printf "  [q] Quit        (background migration keeps running)\n"
    printf "%s\n" "$SEP"
    printf "Select: "
    read -r SEL || break

    case "${SEL}" in
        r|R) _run_menu || break ;;
        l|L) _view_log ;;
        s)   _status ;;
        S)   _stop ;;
        h|H) _hint_setting ;;
        q|Q) break ;;
        *)   echo "[FAIL] Invalid selection: ${SEL}" ;;
    esac
done

if _lock_read ; then
    echo "[OK]   Menu closed. ${L_ACTION} ${L_PHASE} RUN_ID=${L_RUN_ID} keeps running in background (PID=${L_PID})"
    echo "       tail -F ${CURRENT_LOG}"
fi
exit 0
