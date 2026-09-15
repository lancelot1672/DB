#!/bin/bash
# ============================================================
# 02.RUN_MIG.sh
# Data migration menu driven by DBADM.DBM_MIG_MSTR (spec : MIG_RUN_PLAN.md)
#
#   main menu : [R] Run (r / R) , [l] Total Log , [s] Status , [S] Stop , [h] Hint , [U] Unlock , [q] Quit
#               (s and S are case sensitive ; after one [R] action the main menu comes back)
#               menu keys are read without Enter ; the screen is cleared before every menu ;
#               after an action the result stays until any key is pressed
#               (y/N confirm, [h] degree and q in [l] Total Log still need Enter)
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
#   [S] Stop              : no new table is started ; running tables finish (remaining tables are not run)
#   [h] Hint              : WORKER degree (tables at once, default 1) / PARALLEL degree (default 4) in ./MIG_HINT.conf ;
#                           a running worker picks up both from the next table it starts
#   [U] Unlock            : no worker process only ; removes a stale lock and marks RUNNING rows FAIL
#                           (refused while a DB client of an earlier worker is still alive)
#   colour     : on the terminal only (menu, [s] Status, [l] Total Log, --tail / --color) ; log files stay plain
#                RUNNING green, FAIL / ERROR red, STALE / warning / STOP / CHECK yellow, OK / SUCCESS / DONE blue,
#                phase headers bold, menu keys [x] orange (menu screens only) ; MIG_COLOR=Y force, MIG_COLOR=N or NO_COLOR off
#   viewer     : 02.RUN_MIG.sh --tail [LOG_FILE]   /   tail -f <LOG_FILE> | 02.RUN_MIG.sh --color
#   menu start : DBM_MIG_MSTR / DBM_MIG_COL_MAP / DBM_XDN_LOG / ALL_TAB_COLUMNS are checked one by one ;
#                a missing object is shown as "! CHECK" under the status line (warning only)
#   generate   : DBM_MIG_MSTR is read first ; ALL_TAB_COLUMNS + DBM_MIG_COL_MAP only when TRANS_YN = 'Y' targets exist
#
#   - hints are put in at run time (2/3/5/6), .out files stay without hints :
#       INSERT INTO -> INSERT /*+ APPEND PARALLEL(n) */ INTO
#       SELECT      -> SELECT /*+ PARALLEL(n) */            (lines starting with SELECT, not already hinted)
#       ALTER SESSION ENABLE PARALLEL DML before the INSERT when n > 1
#     executed SQL (with hints) is kept in the _detail.log ; each table uses the PARALLEL degree read when it starts
#
#   - launch      : the menu writes a launcher $MIG_HOME/run/{RUN|RETRY}_{PHASE}_{MSTR_ID}_R{RUN_ID}_{ts}.sh
#                   and starts it as "nohup bash <launcher>" (no execute permission needed on any sh) ;
#                   the launcher execs "bash 02.RUN_MIG.sh --worker ..." and is removed when the worker ends
#                   (MIG_HOME : MIG.env, default = script directory)
#   - run / retry : preview + confirm in the menu, then a background worker (nohup) does the work ;
#                   it keeps running after the menu quits or the session disconnects
#                   only one worker at a time : running state = live worker process (ps) + ./log/.run.lock ;
#                   a check never deletes the lock ; run / retry is also refused while DBM_XDN_LOG has RUNNING rows
#   - logs        : ./log/MIG_TOTAL.log                                   integrated log ([l] Total Log) : every
#                                                                         GEN / RUN / RETRY start, table blocks,
#                                                                         progress, end (DONE / STOPPED / ERROR / ABORT)
#                   ./log/GEN_{PHASE}_{MSTR_ID}_{ts}.log                  SQL generate log
#                   ./log/{RUN|RETRY}_{PHASE}_{MSTR_ID}_R{RUN_ID}_{ts}.log  progress of one run, one block per table
#                   ./log/..._detail.log                                  executed SQL + DB client output
#                   ./log/current.log -> progress log of the latest run  (tail -F log/current.log)
#                   table events at once : "HH:MI:SS [Wn] START / RUNNING (every HEARTBEAT_SEC) / SUCCESS / FAIL" ;
#                   the table block (condition, counts, times, result, progress) is appended when the table ends
#                   menu actions (preview / cancel / [S] / [h]) are not written to the integrated log
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
#   - regenerate  : MIG.env SQL_REFRESH=Y only (default N : the .out files run as they are, a missing file on retry -> FAIL)
#                   run and retry rebuild each table's SQL from DBM_MIG_MSTR / DBM_MIG_COL_MAP right before it runs
#                   and overwrite ./cmd/<phase>/{TGT}__{SRC}.out (a changed file is kept as .bak ; hand edits are lost) ;
#                   a table that is no longer a target (row gone / MIG_YN = 'N' / MIG_TYPE, MIG_FULL changed) -> SKIP (not run)
#   - retry       : FAIL rows of MAX(RUN_ID) for MSTR_ID + phase, re-run ./cmd/<phase>/{TGT}__{SRC}.out
#                   the same DBM_XDN_LOG rows are updated (no new RUN_ID)
#   - parallel    : up to WORKER_DEGREE tables at once (one sub shell + DB sessions each), order TAB_SIZE small first ;
#                   a failed table is logged as FAIL and the run continues ; menu top shows WORKER / PARALLEL / each worker
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
# SQL_REFRESH=Y : run / retry regenerate each table's SQL right before it runs ; anything else (default) : run the .out as it is
case "${SQL_REFRESH}" in Y|y) SQL_REFRESH="Y" ;; *) SQL_REFRESH="N" ;; esac

DB_CONN="${DB_USER}/${DB_PASS}${DB_TNS:+@${DB_TNS}}"

MSTR_TAB="DBADM.DBM_MIG_MSTR"
LOG_TAB="DBADM.DBM_XDN_LOG"
MAP_TAB="DBADM.DBM_MIG_COL_MAP"

# DBM_XDN_LOG.ELAPSED_TIME : SYSDATE - START_TIME as 'HH24:MI:SS' (hours can exceed 24)
#   used in the UPDATE that sets END_TIME = SYSDATE (a SET expression sees the old END_TIME, so SYSDATE is used)
ELAPSED_SEC="ROUND((SYSDATE - START_TIME) * 86400)"
ELAPSED_SQL="LPAD(TRUNC(${ELAPSED_SEC} / 3600), GREATEST(2, LENGTH(TRUNC(${ELAPSED_SEC} / 3600))), '0')"
ELAPSED_SQL="${ELAPSED_SQL} || ':' || LPAD(TRUNC(MOD(${ELAPSED_SEC}, 3600) / 60), 2, '0') || ':' || LPAD(MOD(${ELAPSED_SEC}, 60), 2, '0')"

NL=$'\n'
SEP="============================================================"
DASH="------------------------------------------------------------"

CMD_DIR="${SCRIPT_DIR}/cmd"
LOG_DIR="${SCRIPT_DIR}/log"
TMP_DIR="${BASE_PATH}/tmp"
MIG_HOME="${MIG_HOME:-${SCRIPT_DIR}}"     # MIG.env (optional) ; default = script directory
RUN_DIR="${MIG_HOME}/run"                 # generated launcher sh of background workers
BASH_BIN="${BASH:-$(command -v bash)}"    # interpreter of the launcher (no execute permission needed)
mkdir -p "${CMD_DIR}/PRE" "${CMD_DIR}/DDAY" "${LOG_DIR}" "${TMP_DIR}" "${RUN_DIR}"

LOCK_FILE="${LOG_DIR}/.run.lock"      # PID|ACTION|PHASE|RUN_ID|LOG|START
STATE_FILE="${LOG_DIR}/.run.state"    # DONE|TOTAL|SUCCESS|FAIL|RUNNING|WAITING|SKIP (written by the worker every second)
STOP_FILE="${LOG_DIR}/.run.stop"      # exists = start no new table
SLOT_PREFIX="${LOG_DIR}/.run.slot."   # .run.slot.<n> : NUM|TOTAL|table|start epoch|PARALLEL of worker slot n
CURRENT_LOG="${LOG_DIR}/current.log"
TOTAL_LOG="${LOG_DIR}/MIG_TOTAL.log"      # integrated log of every phase (append only)
HINT_CONF="${SCRIPT_DIR}/MIG_HINT.conf"   # WORKER_DEGREE=<n> / PARALLEL_DEGREE=<n>

TMP_SQL="${TMP_DIR}/RUN_MIG_$$.sql"
TMP_OUT="${TMP_DIR}/RUN_MIG_$$.out"
TMP_LIST="${TMP_DIR}/RUN_MIG_LIST_$$.lst"
TMP_RUN="${TMP_DIR}/RUN_MIG_RUN_$$.lst"
TMP_COLS="${TMP_DIR}/RUN_MIG_COLS_$$.lst"
TMP_TCOL="${TMP_DIR}/RUN_MIG_TCOL_$$.lst"
TMP_GENBUF="${TMP_DIR}/RUN_MIG_GENBUF_$$.log"
TMP_TAILPID="${TMP_DIR}/RUN_MIG_TAIL_$$.pid"    # [l] Total Log : PID of the background tail

LOGFILE="/dev/null"     # progress log (menu actions : per action, worker : argument)
DETAIL_LOG=""           # worker only
TAIL_PID="" ; HB_PID=""
TOTAL_ON=""             # Y : _out / _file_out also append to TOTAL_DEST
TOTAL_DEST="${TOTAL_LOG}"   # integrated log (GEN writes to a buffer first, see _generate)

# colour on the terminal only ; log files stay plain (less / vi / grep)
#   MIG_COLOR=Y : force on (e.g. | less -R) , MIG_COLOR=N or NO_COLOR : off , default : on when stdout is a terminal
case "${MIG_COLOR}" in
    Y|y) COLOR_ON="Y" ;;
    N|n) COLOR_ON="" ;;
    *)   COLOR_ON="" ; [[ -t 1 && -z "${NO_COLOR}" && "${TERM:-dumb}" != "dumb" ]] && COLOR_ON="Y" ;;
esac

# _out: Print to terminal (coloured) and append to log file (+ integrated log when TOTAL_ON)
_out() {
    if [[ -n "${COLOR_ON}" ]] ; then printf "$@" | _colorize ; else printf "$@" ; fi
    printf "$@" >> ${LOGFILE}
    if [[ -n "${TOTAL_ON}" ]] ; then printf "$@" >> "${TOTAL_DEST}" ; fi
    return 0
}

# _file_out : log file (+ integrated log when TOTAL_ON), not the terminal
_file_out() {
    printf "$@" >> ${LOGFILE}
    if [[ -n "${TOTAL_ON}" ]] ; then printf "$@" >> "${TOTAL_DEST}" ; fi
    return 0
}

# _total : integrated log only
_total() { printf "$@" >> "${TOTAL_DEST}" ; }

# _colorize : stdin -> stdout with ANSI colours by keyword (one rule per line, first match wins)
#   red    : FAIL / ERROR / ABORT / ORA- TBR- SP2- errors     green : RUNNING / Running
#   yellow : STALE / warning / WARN / STOP / CHECK / <> SRC   blue  : OK / SUCCESS / DONE
#   bold   : [GEN] [RUN] [RETRY] [END] [STATUS] [HINT] [UNLOCK] headers ; "FAIL=n" (n > 0) red inside other lines
#   orange : menu keys [x] (one letter / digit) when called as "_colorize keys" (menu screens only)
_colorize() {
    awk -v R=$'\033[1;31m' -v G=$'\033[1;32m' -v Y=$'\033[1;33m' -v B=$'\033[1;34m' -v BD=$'\033[1m' -v X=$'\033[0m' \
        -v O=$'\033[1;38;5;208m' -v K="$([[ "$1" == "keys" ]] && echo 1 || echo 0)" '
    {
        l = $0 ; c = ""
        if      (l ~ /\[FAIL\]|Result +: FAIL|RESULT=ERROR|\[ABORT\]|^ FAILED :|(ORA|TBR|SP2)-[0-9]+|^  FAIL +: +[1-9]|--- FAIL|\[W[0-9-]+\] FAIL /) c = R
        else if (l ~ /\* RUNNING|Running +:|^  RUNNING +: +[1-9]|--- RUNNING|worker : RUNNING|\[W[0-9-]+\] RUNNING /)                  c = G
        else if (l ~ /\* STALE|warning :|\[WARN\]|\[STOP\]|! CHECK|RESULT=STOPPED|stop +: requested|stale lock :|NOT FOUND|no worker process|\[UNLOCK\]|<> SRC|\[W[0-9-]+\] (STOP|SKIP) |Result +: SKIP|^ SKIPPED/) c = Y
        else if (l ~ /\[OK\]|Result +: SUCCESS|RESULT=DONE|^  SUCCESS +: +[1-9]|\[W[0-9-]+\] SUCCESS /)                                c = B
        b = (l ~ /^ \[(GEN|RUN|RETRY|END|STATUS|HINT|UNLOCK)\]/) ? BD : ""
        if (c == "") gsub(/FAIL=[1-9][0-9]*/, R "&" X, l)
        if (K == 1) gsub(/\[[A-Za-z0-9]\]/, O "&" X b c, l)
        if (c != "" || b != "") l = b c l X
        print l
        fflush()
    }'
}

# _paint : stdin -> stdout, coloured when COLOR_ON
_paint() { if [[ -n "${COLOR_ON}" ]] ; then _colorize ; else cat ; fi ; }

# _paint_menu : same as _paint + menu keys [x] in orange (menu screens only)
_paint_menu() { if [[ -n "${COLOR_ON}" ]] ; then _colorize keys ; else cat ; fi ; }

# _say <text> : one message line on the terminal (coloured when COLOR_ON), not logged
_say() { printf "%s\n" "$*" | _paint ; }

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

_cleanup() {
    [[ -n "${TAIL_PID}" ]] && kill ${TAIL_PID} 2>/dev/null
    [[ -n "${HB_PID}" ]] && kill ${HB_PID} 2>/dev/null
    rm -f ${TMP_SQL} ${TMP_OUT} ${TMP_LIST} ${TMP_RUN} ${TMP_COLS} ${TMP_TCOL} ${TMP_GENBUF} ${TMP_TAILPID}
}
trap _cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# _new_log <ACTION> : ./log/<ACTION>_<MSTR_ID>_<timestamp>.log
_new_log() { LOGFILE="${LOG_DIR}/${1}_${MSTR_ID}_$(date '+%Y%m%d_%H%M%S').log"; }

# _clear : clear the screen before a menu is drawn (terminal only)
_clear() {
    [[ -t 1 ]] || return 0
    clear 2>/dev/null || printf '\033[H\033[2J'
}

# _key : one key without Enter -> KEY ("" = Enter, "ESC" = escape / arrow keys) ; returns 1 on end of input
_key() {
    local _junk
    KEY=""
    IFS= read -rsn1 KEY || return 1
    if [[ "${KEY}" == $'\e' ]] ; then
        read -rsn5 -t 0.05 _junk 2>/dev/null     # rest of an arrow / function key sequence
        KEY="ESC"
    fi
    printf "%s\n" "${KEY}"
    return 0
}

# _pause : keep the result on the screen until any key is pressed ; returns 1 on end of input
_pause() {
    local _k _junk
    if [[ -t 0 ]] ; then
        while IFS= read -rsn1 -t 0.01 _junk ; do : ; done   # drop keys typed while the action was running
    fi
    printf "\n%s\n Press any key to return to the menu ...\n" "$DASH"
    IFS= read -rsn1 _k || return 1
    [[ "${_k}" == $'\e' ]] && read -rsn5 -t 0.05 _junk 2>/dev/null
    return 0
}

# _confirm <message> : 0 when answered y / Y (Enter required)
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

# _out_headers : stdin = .out file paths -> "TAB_SIZE|FILE|MSTR_ID|SRC_OWNER|SRC_TABLE_NAME|TGT_OWNER|TGT_TABLE_NAME"
#   one awk reads every header (one sed per value per file is too slow with hundreds of tables)
_out_headers() {
    awk '
    {
        f = $0
        split("", v) ; v["TAB_SIZE"] = "0"
        while ((getline line < f) > 0) {
            if (line !~ /^-- /) break
            sub(/^-- /, "", line)
            k = line ; sub(/ *:.*$/, "", k)
            val = line ; sub(/^[^:]*: */, "", val) ; sub(/[ \t\r]+$/, "", val)
            v[k] = val
        }
        close(f)
        sz = (v["TAB_SIZE"] ~ /^[0-9.]+$/) ? v["TAB_SIZE"] : "0"
        print sz "|" f "|" v["MSTR_ID"] "|" v["SRC_OWNER"] "|" v["SRC_TABLE_NAME"] "|" v["TGT_OWNER"] "|" v["TGT_TABLE_NAME"]
    }'
}

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
# Hint : WORKER degree (tables at once) / PARALLEL degree from MIG_HINT.conf
# ============================================================
# _hint_load : WORKER_DEGREE / PARALLEL_DEGREE / INS_HINT / SEL_HINT / PDML
#   read again by the running worker every second (WORKER) and at the start of every table (PARALLEL)
_hint_load() {
    PARALLEL_DEGREE="" ; WORKER_DEGREE=""
    if [[ -f "${HINT_CONF}" ]] ; then
        PARALLEL_DEGREE=$(sed -n 's/^PARALLEL_DEGREE=//p' "${HINT_CONF}" | tail -1 | tr -d '[:space:]')
        WORKER_DEGREE=$(sed -n 's/^WORKER_DEGREE=//p' "${HINT_CONF}" | tail -1 | tr -d '[:space:]')
    fi
    [[ "${PARALLEL_DEGREE}" =~ ^[1-9][0-9]*$ ]] || PARALLEL_DEGREE=4
    [[ "${WORKER_DEGREE}" =~ ^[1-9][0-9]?$ ]] || WORKER_DEGREE=1
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
    local _w _n
    _hint_load
    echo "$SEP"
    printf " [HINT] WORKER = %s (tables at once)   PARALLEL = %s   -> DB load max %s   (%s)\n" \
           "${WORKER_DEGREE}" "${PARALLEL_DEGREE}" "$(( WORKER_DEGREE * PARALLEL_DEGREE ))" "${HINT_CONF}"
    printf "        %s\n" "$(_hint_text)"
    echo "$SEP"
    printf "New WORKER degree   (tables at once 1-99, Enter = keep %s): " "${WORKER_DEGREE}"
    read -r _w
    if [[ -n "${_w}" ]] && ! [[ "${_w}" =~ ^[1-9][0-9]?$ ]] ; then
        _say "[FAIL] WORKER degree must be 1-99 : ${_w}"
        return 1
    fi
    printf "New PARALLEL degree (1 = serial, Enter = keep %s): " "${PARALLEL_DEGREE}"
    read -r _n
    if [[ -n "${_n}" ]] && ! [[ "${_n}" =~ ^[1-9][0-9]*$ ]] ; then
        _say "[FAIL] PARALLEL degree must be a positive integer : ${_n}"
        return 1
    fi
    if [[ -z "${_w}" && -z "${_n}" ]] ; then
        _say "[OK]   Hint unchanged"
        return 0
    fi
    _w="${_w:-${WORKER_DEGREE}}" ; _n="${_n:-${PARALLEL_DEGREE}}"
    # written to a temp file and moved : a running worker reading it never sees a half written file
    {
        echo "# 02.RUN_MIG.sh hint setting ([h] Hint)"
        echo "#   WORKER_DEGREE   : tables migrated at once by the background worker (1 = one by one)"
        echo "#   PARALLEL_DEGREE : INSERT /*+ APPEND PARALLEL(n) */, SELECT /*+ PARALLEL(n) */, 1 = serial"
        echo "WORKER_DEGREE=${_w}"
        echo "PARALLEL_DEGREE=${_n}"
    } > "${HINT_CONF}.tmp" && mv -f "${HINT_CONF}.tmp" "${HINT_CONF}"
    _hint_load
    _say "[OK]   Saved : WORKER ${WORKER_DEGREE} x PARALLEL ${PARALLEL_DEGREE} (DB load max $(( WORKER_DEGREE * PARALLEL_DEGREE ))) : $(_hint_text)"
    if _lock_read && [[ "${W_STATE}" == "RUNNING" ]] ; then
        echo "       running ${L_ACTION} ${L_PHASE} (RUN_ID=${L_RUN_ID}) : applied from the next table it starts"
        echo "       (tables already running keep their PARALLEL ; a lower WORKER degree waits for running tables to end)"
    fi
}

M_ID=$(_q "${MSTR_ID}")
TARGET_WHERE="MSTR_ID = '${M_ID}' AND MIG_YN = 'Y'"

# ============================================================
# Background worker lock / process check
#   the live worker process list (ps) is the source of truth ; a check never deletes the lock file
#   (only the worker at its end, a failed start in _launch, or [U] Unlock remove it)
# ============================================================
# _is_worker_pid <PID> : 0 when the PID is alive (not a zombie) and looks like this script
#   args not available, or probably truncated by ps -> alive is enough
_is_worker_pid() {
    local _st _args
    [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null || return 1
    _st=$(ps -p "$1" -o stat= 2>/dev/null | tr -d ' ')
    [[ "${_st}" == Z* ]] && return 1
    _args=$(ps -p "$1" -o args= 2>/dev/null)
    [[ -z "${_args}" ]] && return 0
    [[ "${_args}" == *"$(basename "${SCRIPT_PATH}")"* || "${_args}" == *--worker* ]] && return 0
    [[ ${#_args} -ge 79 ]] && return 0
    return 1
}

# _worker_scan : "PID|ACTION|PHASE|RUN_ID|LOG" of each live worker of this directory, one line each
#   forked sub shells of a worker (same args, parent is a worker) and a nohup wrapper are skipped
#   returns 2 when "ps -eo" is not available
_worker_scan() {
    local _ps
    _ps=$(ps -eo pid=,ppid=,args= 2>/dev/null) || return 2
    [[ -n "${_ps}" ]] || return 2
    printf "%s\n" "${_ps}" | awk -v logdir="${LOG_DIR}/" '
        {
            w = 0
            for (i = 3; i <= NF; i++) if ($i == "--worker") { w = i ; break }
            if (!w || index($0, logdir) == 0 || $3 ~ /(^|\/)nohup$/) next
            n++ ; PP[n] = $2 ; isw[$1] = 1
            L[n] = $1 "|" $(w + 1) "|" $(w + 2) "|" $(w + 3) "|" $(w + 4)
        }
        END { for (i = 1; i <= n; i++) if (!(PP[i] in isw)) print L[i] }'
    return 0
}

# _lock_read : sets L_PID L_ACTION L_PHASE L_RUN_ID L_LOG L_START , W_STATE (RUNNING / STALE / IDLE) , W_NOTE
#   RUNNING : a worker process is alive (a missing / wrong lock is written again from that process)
#   STALE   : the lock file exists but no worker process
#   returns 0 for RUNNING / STALE, 1 for IDLE
_lock_read() {
    local _scan _rc _cnt _wpid _wact _wph _wrid _wlog
    L_PID="" ; L_ACTION="" ; L_PHASE="" ; L_RUN_ID="" ; L_LOG="" ; L_START="" ; W_STATE="IDLE" ; W_NOTE=""
    [[ -f "${LOCK_FILE}" ]] && IFS='|' read -r L_PID L_ACTION L_PHASE L_RUN_ID L_LOG L_START < "${LOCK_FILE}"

    _scan=$(_worker_scan) ; _rc=$?
    if [[ ${_rc} -eq 2 ]] ; then
        # no "ps -eo" : lock PID only
        if _is_worker_pid "${L_PID}" ; then
            W_STATE="RUNNING"
        elif [[ -f "${LOCK_FILE}" ]] ; then
            W_STATE="STALE"
        fi
        [[ "${W_STATE}" != "IDLE" ]]
        return
    fi

    _cnt=$(printf "%s" "${_scan}" | grep -c .)
    if [[ ${_cnt} -eq 0 ]] ; then
        [[ -f "${LOCK_FILE}" ]] || return 1
        if _is_worker_pid "${L_PID}" ; then
            # alive but not matched in the ps list (e.g. ps truncates long args) : trust the lock PID
            W_STATE="RUNNING"
            W_NOTE="worker PID ${L_PID} alive but not matched by ps args"
            return 0
        fi
        W_STATE="STALE"
        return 0
    fi

    W_STATE="RUNNING"
    [[ ${_cnt} -gt 1 ]] && W_NOTE="${_cnt} worker processes : $(printf "%s\n" "${_scan}" | cut -d'|' -f1 | tr '\n' ' ')"
    IFS='|' read -r _wpid _wact _wph _wrid _wlog <<< "$(printf "%s\n" "${_scan}" | head -1)"
    if [[ "${L_PID}" != "${_wpid}" ]] ; then
        [[ -z "${W_NOTE}" ]] && W_NOTE="lock $([[ -f "${LOCK_FILE}" ]] && echo "PID ${L_PID:-?}" || echo "file missing") -> restored from worker PID ${_wpid}"
        if [[ "${L_RUN_ID}" != "${_wrid}" || "${L_ACTION}" != "${_wact}" ]] ; then
            L_START=$(sed -n 's/^ *START=\([0-9-]* [0-9:]*\).*/\1/p' "${_wlog}" 2>/dev/null | head -1)
        fi
        L_PID="${_wpid}" ; L_ACTION="${_wact}" ; L_PHASE="${_wph}" ; L_RUN_ID="${_wrid}" ; L_LOG="${_wlog}" ; L_START="${L_START:-?}"
        if [[ ${_cnt} -eq 1 ]] ; then
            printf "%s|%s|%s|%s|%s|%s\n" "${L_PID}" "${L_ACTION}" "${L_PHASE}" "${L_RUN_ID}" "${L_LOG}" "${L_START}" > "${LOCK_FILE}"
        fi
    fi
    return 0
}

# _db_running : DB_RUN_CNT / DB_RUN_RID = RUNNING rows of MSTR_ID in DBM_XDN_LOG ; returns 1 when the query fails
_db_running() {
    DB_RUN_CNT="" ; DB_RUN_RID=""
    cat > ${TMP_SQL} <<EOF
$(_sql_head)
SELECT 'DBRUN|' || COUNT(*) || '|' || MAX(RUN_ID) FROM ${LOG_TAB} WHERE MSTR_ID = '${M_ID}' AND STATUS = 'RUNNING';
EXIT;
EOF
    _run_sql ${TMP_SQL} || return 1
    DB_RUN_CNT=$(grep '^DBRUN|' ${TMP_OUT} | head -1 | cut -d'|' -f2 | tr -d '[:space:]')
    DB_RUN_RID=$(grep '^DBRUN|' ${TMP_OUT} | head -1 | cut -d'|' -f3 | tr -d '[:space:]')
    [[ -n "${DB_RUN_CNT}" ]]
}

# _busy : 0 (blocked) when a worker is running, a stale lock exists, or DBM_XDN_LOG still has RUNNING rows
_busy() {
    if _lock_read ; then
        if [[ "${W_STATE}" == "RUNNING" ]] ; then
            _say "[FAIL] Background migration is running : ${L_ACTION} ${L_PHASE} RUN_ID=${L_RUN_ID} PID=${L_PID}"
            [[ -n "${W_NOTE}" ]] && _say "       warning : ${W_NOTE}"
            echo "       wait until it ends, or use [S] Stop"
        else
            _say "[FAIL] Lock file exists but no worker process : ${L_ACTION} ${L_PHASE} RUN_ID=${L_RUN_ID} PID=${L_PID}"
            echo "       check [s] Status and the DB session, then [U] Unlock"
        fi
        return 0
    fi
    if ! _db_running ; then
        _say "[FAIL] Could not check RUNNING rows in ${LOG_TAB}"
        _db_errors | sed 's/^/  /'
        return 0
    fi
    if [[ "${DB_RUN_CNT}" -gt 0 ]] ; then
        _say "[FAIL] ${DB_RUN_CNT} RUNNING row(s) in ${LOG_TAB} (RUN_ID=${DB_RUN_RID}) but no worker process : interrupted run"
        echo "       check [s] Status and the DB session, then [U] Unlock"
        return 0
    fi
    return 1
}

# _busy_phase <PHASE> : 0 (blocked) when the running (or stale) migration uses the same phase directory
_busy_phase() {
    if _lock_read && [[ "${L_PHASE}" == "$1" ]] ; then
        if [[ "${W_STATE}" == "RUNNING" ]] ; then
            _say "[FAIL] ${L_ACTION} ${L_PHASE} is running (RUN_ID=${L_RUN_ID}) : cmd/$1 can not be regenerated now"
        else
            _say "[FAIL] Stale lock of ${L_ACTION} ${L_PHASE} (RUN_ID=${L_RUN_ID}) : check [s] Status, then [U] Unlock"
        fi
        return 0
    fi
    return 1
}

# _launch <RUN|RETRY> <PHASE> <RUN_ID> : start the background worker
_launch() {
    local _action="$1" _phase="$2" _rid="$3" _log _err _run_sh _pid _now _i _p

    _log="${LOG_DIR}/${_action}_${_phase}_${MSTR_ID}_R${_rid}_$(date '+%Y%m%d_%H%M%S').log"
    _err="${_log%.log}_worker.err"     # worker startup output / shell errors (removed at the end when empty)
    _run_sh="${RUN_DIR}/$(basename "${_log%.log}").sh"   # launcher (removed when the worker ends)
    _now=$(date '+%Y-%m-%d %H:%M:%S')

    _busy && return 1
    if ! ( set -o noclobber ; printf "%s|%s|%s|%s|%s|%s\n" "$$" "${_action}" "${_phase}" "${_rid}" "${_log}" "${_now}" > "${LOCK_FILE}" ) 2>/dev/null ; then
        _say "[FAIL] Could not create ${LOCK_FILE} (another migration just started?)"
        return 1
    fi
    rm -f "${STOP_FILE}" "${STATE_FILE}" "${SLOT_PREFIX}"*

    # launcher sh : run by the interpreter explicitly, so neither 02.RUN_MIG.sh nor the launcher needs
    # execute permission ; exec keeps the PID and the worker args ("bash 02.RUN_MIG.sh --worker ...")
    {
        echo "#!${BASH_BIN}"
        echo "# generated by $(basename "${SCRIPT_PATH}") : background worker launcher (removed when the worker ends)"
        echo "# MSTR_ID=${MSTR_ID}  ACTION=${_action}  PHASE=${_phase}  RUN_ID=${_rid}  CREATED=${_now}"
        printf "cd %q || exit 1\n" "${SCRIPT_DIR}"
        printf "export MIG_RUN_SH=%q\n" "${_run_sh}"
        printf "exec %q %q --worker %q %q %q %q\n" "${BASH_BIN}" "${SCRIPT_PATH}" "${_action}" "${_phase}" "${_rid}" "${_log}"
    } > "${_run_sh}"
    chmod 700 "${_run_sh}" 2>/dev/null

    nohup "${BASH_BIN}" "${_run_sh}" > "${_err}" 2>&1 < /dev/null &
    _pid=$!
    printf "%s|%s|%s|%s|%s|%s\n" "${_pid}" "${_action}" "${_phase}" "${_rid}" "${_log}" "${_now}" > "${LOCK_FILE}"

    # wait until the worker is seen in the process list (the worker writes its own PID into the lock)
    for _i in 1 2 3 4 5 6 7 8 9 10 ; do
        sleep 1
        if _lock_read && [[ "${W_STATE}" == "RUNNING" && "${L_RUN_ID}" == "${_rid}" ]] ; then
            _pid="${L_PID}"
            break
        fi
        # a very short run can already be over : the worker removes the lock at its end
        [[ ! -f "${LOCK_FILE}" && -s "${_log}" ]] && break
    done

    if [[ "${W_STATE}" != "RUNNING" ]] && ! [[ ! -f "${LOCK_FILE}" && -s "${_log}" ]] ; then
        _say "[FAIL] Background worker not confirmed within 10 seconds (PID=${_pid})"
        if kill -0 "${_pid}" 2>/dev/null ; then
            # alive : never remove the lock of a process that may be the worker
            echo "       process : PID ${_pid} is alive -> lock kept, check [s] Status / [l] Total Log"
            echo "       ps args : $(ps -p "${_pid}" -o args= 2>/dev/null)"
        else
            echo "       process : PID ${_pid} not found -> the worker ended at startup"
            rm -f "${_run_sh}"
            { IFS='|' read -r _p _ < "${LOCK_FILE}" ; } 2>/dev/null
            if [[ -n "${_p}" ]] && [[ "${_p}" == "${_pid}" || "${_p}" == "$$" ]] && ! _is_worker_pid "${_p}" ; then
                rm -f "${LOCK_FILE}"
                echo "       lock    : removed"
            fi
        fi
        if [[ -s "${_err}" ]] ; then
            echo "       startup output (${_err}) :"
            tail -10 "${_err}" | sed 's/^/         /'
        fi
        if [[ -s "${_log}" ]] ; then
            echo "       log (${_log}) :"
            tail -5 "${_log}" | sed 's/^/         /'
        fi
        return 1
    fi

    _say "[OK]   ${_action} ${_phase} started in background (RUN_ID=${_rid}, PID=${_pid})"
    echo "       log  : ${_log}"
    echo "       run  : ${_run_sh}"
    echo "       view : [l] Total Log   or   bash $(basename "${SCRIPT_PATH}") --tail"
    return 0
}

# ============================================================
# SQL building shared by [R] 1 / 4 (generate) and the table slots of run / retry (regenerate before each table)
# ============================================================
# _phase_cond <PRE|DDAY> : TGT_COND (target rows of the phase) / WHERE_EXPR (migration condition)
_phase_cond() {
    case "$1" in
        PRE)
            TGT_COND="MIG_TYPE = 'PRE' AND MIG_FULL = 'COND'"
            WHERE_EXPR="'WHERE ' || COL_CONDITION || ' >= ''' || REPLACE(PRE1, '''', '''''') || ''' AND ' || COL_CONDITION || ' < ''' || REPLACE(PRE2, '''', '''''') || ''''"
            ;;
        DDAY)
            TGT_COND="(MIG_TYPE = 'PRE' AND MIG_FULL = 'COND') OR (MIG_TYPE = 'DDAY' AND MIG_FULL = 'FULL')"
            WHERE_EXPR="CASE WHEN MIG_TYPE = 'PRE' THEN 'WHERE ' || COL_CONDITION || ' >= ''' || REPLACE(PRE3, '''', '''''') || '''' END"
            ;;
    esac
}

# _row_sql <WHERE on DBM_MIG_MSTR> : target rows (uses TGT_COND / WHERE_EXPR of _phase_cond)
#   ROW|RUN,EXCL|TRANS_YN|SRC_OWNER|SRC_TABLE_NAME|TGT_OWNER|TGT_TABLE_NAME|MIG_TYPE|MIG_FULL|TAB_SIZE+LOB_SIZE|WHERE clause
_row_sql() {
    cat <<EOF
SELECT 'ROW|'
       || CASE WHEN (${TGT_COND}) THEN 'RUN' ELSE 'EXCL' END
       || '|' || NVL(TRANS_YN, 'N')
       || '|' || SRC_OWNER || '|' || SRC_TABLE_NAME || '|' || TGT_OWNER || '|' || TGT_TABLE_NAME
       || '|' || MIG_TYPE || '|' || MIG_FULL || '|' || (NVL(TAB_SIZE, 0) + NVL(LOB_SIZE, 0)) || '|'
       || CASE WHEN (${TGT_COND}) THEN ${WHERE_EXPR} END
  FROM ${MSTR_TAB}
 WHERE $1
 ORDER BY SRC_OWNER, SRC_TABLE_NAME;
EOF
}

# _col_sql <MSTR_ID (quote escaped)> <extra condition on M, e.g. "AND M.SRC_OWNER = 'X' ..."> : TRANS_YN = 'Y' column lists
#   COL|SRC_OWNER|SRC_TABLE_NAME|TGT_OWNER|TGT_TABLE_NAME|MAP_FLAG|TGT column|SELECT expression (target COLUMN_ID order)
_col_sql() {
    cat <<EOF
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
 WHERE M.MSTR_ID = '$1' AND M.MIG_YN = 'Y' AND NVL(M.TRANS_YN, 'N') = 'Y'
   AND (${TGT_COND}) $2
 ORDER BY M.SRC_OWNER, M.SRC_TABLE_NAME, M.TGT_OWNER, M.TGT_TABLE_NAME, C.COLUMN_ID;
EOF
}

# _write_out <PHASE> <MSTR_ID> <TRANS_YN> <SO> <ST> <TO> <TT> <MIG_TYPE> <MIG_FULL> <TAB_SIZE> <WHERE> <COLS_FILE> <TCOL_TMP> <OUT_FILE>
#   one .out file : header comments + INSERT INTO SELECT + COMMIT
#   TRANS_YN = 'Y' : column list from COLS_FILE (COL| lines) ; sets W_COL_CNT / W_REN_CNT / W_ADD_CNT / W_SKIP_CNT
_write_out() {
    local PHASE="$1" MID="$2" TR="$3" SO="$4" ST="$5" TO="$6" TT="$7" MT="$8" MF="$9" SZ="${10}" WHERE_CLAUSE="${11}"
    local COLS="${12}" TCOL="${13}" OUT_FILE="${14}"
    local _k _so _st _o _n _flag COL EXPR COL_LIST="" SEL_LIST=""

    W_COL_CNT=0 ; W_REN_CNT=0 ; W_ADD_CNT=0 ; W_SKIP_CNT=0
    if [[ "${TR}" == "Y" ]] ; then
        awk -F'|' -v so="${SO}" -v st="${ST}" -v o="${TO}" -v t="${TT}" \
            '$2 == so && $3 == st && $4 == o && $5 == t' "${COLS}" > "${TCOL}"
        while IFS='|' read -r _k _so _st _o _n _flag COL EXPR ; do
            [[ "${_flag}" == "RENAME" ]] && W_REN_CNT=$(( W_REN_CNT + 1 ))
            [[ "${_flag}" == "ADD" ]]    && W_ADD_CNT=$(( W_ADD_CNT + 1 ))
            if [[ -z "${EXPR}" ]] ; then
                W_SKIP_CNT=$(( W_SKIP_CNT + 1 ))
                continue
            fi
            W_COL_CNT=$(( W_COL_CNT + 1 ))
            if [[ ${W_COL_CNT} -eq 1 ]] ; then
                COL_LIST="       (${COL}"
                SEL_LIST="SELECT  ${EXPR}"
            else
                COL_LIST="${COL_LIST}${NL}      , ${COL}"
                SEL_LIST="${SEL_LIST}${NL}      , ${EXPR}"
            fi
        done < "${TCOL}"
    fi

    {
        echo "-- MSTR_ID        : ${MID}"
        echo "-- MIG_PHASE      : ${PHASE}"
        echo "-- MSTR_MIG_TYPE  : ${MT} / ${MF}"
        echo "-- SRC_OWNER      : ${SO}"
        echo "-- SRC_TABLE_NAME : ${ST}"
        echo "-- TGT_OWNER      : ${TO}"
        echo "-- TGT_TABLE_NAME : ${TT}"
        echo "-- SRC_DBLINK     : ${SRC_DBLINK}"
        echo "-- CONDITION      : ${WHERE_CLAUSE}"
        echo "-- TRANS_YN       : ${TR}"
        echo "-- TAB_SIZE       : ${SZ}"
        if [[ "${TR}" == "Y" ]] ; then
            echo "-- COL_MAP        : columns ${W_COL_CNT} (RENAME ${W_REN_CNT}, ADD ${W_ADD_CNT}, left out ${W_SKIP_CNT})"
        fi
        echo "-- GENERATED      : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "INSERT INTO ${TO}.${TT}"
        if [[ ${W_COL_CNT} -gt 0 ]] ; then
            echo "${COL_LIST})"
            echo "${SEL_LIST}"
            echo "  FROM ${SO}.${ST}@${SRC_DBLINK}${WHERE_CLAUSE:+ ${WHERE_CLAUSE}};"
        else
            echo "SELECT * FROM ${SO}.${ST}@${SRC_DBLINK}${WHERE_CLAUSE:+ ${WHERE_CLAUSE}};"
        fi
        echo "COMMIT;"
    } > "${OUT_FILE}"
}

# _refresh_out <OUT_FILE> <PHASE> <MSTR_ID> <SO> <ST> <TO> <TT> : regenerate one table's SQL right before it runs
#   reads DBM_MIG_MSTR (+ DBM_MIG_COL_MAP) again and overwrites OUT_FILE ; a changed file is kept as OUT_FILE.bak
#   REFRESH_STATUS : OK (REFRESH_NOTE = created / no change / changed) / SKIP (no longer a target) / ERROR (query failed)
_refresh_out() {
    local F="$1" PHASE="$2" MID="$3" SO="$4" ST="$5" TO="$6" TT="$7"
    local _mid _row _pair _t _c TR _so _st _to _tt MT MF SZ WHERE_CLAUSE
    local _new="${TMP_SQL%.sql}.gen" _cols="${TMP_SQL%.sql}.cols" _tcol="${TMP_SQL%.sql}.tcol"

    REFRESH_STATUS="" ; REFRESH_NOTE=""
    _mid=$(_q "${MID}")
    _pair="SRC_OWNER = '$(_q "${SO}")' AND SRC_TABLE_NAME = '$(_q "${ST}")' AND TGT_OWNER = '$(_q "${TO}")' AND TGT_TABLE_NAME = '$(_q "${TT}")'"
    _phase_cond "${PHASE}"

    { _sql_head ; _row_sql "MSTR_ID = '${_mid}' AND MIG_YN = 'Y' AND ${_pair}" ; echo "EXIT;" ; } > ${TMP_SQL}
    if ! _run_sql ${TMP_SQL} ; then
        REFRESH_STATUS="ERROR" ; REFRESH_NOTE="SQL regenerate failed : $(_db_errors | head -1)"
        return 1
    fi
    _row=$(grep '^ROW|' ${TMP_OUT} | sed 's/[[:space:]]*$//' | awk -F'|' '$2 == "RUN"' | head -1)
    if [[ -z "${_row}" ]] ; then
        REFRESH_STATUS="SKIP"
        if grep -q '^ROW|' ${TMP_OUT} ; then
            REFRESH_NOTE="not a ${PHASE} target in ${MSTR_TAB} anymore (MIG_TYPE / MIG_FULL)"
        else
            REFRESH_NOTE="no MIG_YN = 'Y' row in ${MSTR_TAB} anymore"
        fi
        return 2
    fi
    IFS='|' read -r _t _c TR _so _st _to _tt MT MF SZ WHERE_CLAUSE <<< "${_row}"

    : > "${_cols}"
    if [[ "${TR}" == "Y" ]] ; then
        { _sql_head ; _col_sql "${_mid}" "AND M.$(printf "%s" "${_pair}" | sed 's/ AND / AND M./g')" ; echo "EXIT;" ; } > ${TMP_SQL}
        if ! _run_sql ${TMP_SQL} ; then
            REFRESH_STATUS="ERROR" ; REFRESH_NOTE="SQL regenerate failed (column list) : $(_db_errors | head -1)"
            rm -f "${_cols}"
            return 1
        fi
        grep '^COL|' ${TMP_OUT} | sed 's/[[:space:]]*$//' > "${_cols}"
    fi

    _write_out "${PHASE}" "${MID}" "${TR}" "${SO}" "${ST}" "${TO}" "${TT}" "${MT}" "${MF}" "${SZ}" "${WHERE_CLAUSE}" "${_cols}" "${_tcol}" "${_new}"

    # compare with the current file, the GENERATED line ignored
    if [[ -f "${F}" ]] ; then
        grep -v '^-- GENERATED' "${F}"    > "${_new}.old"
        grep -v '^-- GENERATED' "${_new}" > "${_new}.cur"
        if cmp -s "${_new}.old" "${_new}.cur" ; then
            REFRESH_NOTE="regenerated from ${MSTR_TAB} (no change)"
        else
            cp -p "${F}" "${F}.bak"
            REFRESH_NOTE="regenerated from ${MSTR_TAB} (changed, previous file -> $(basename "${F}").bak)"
        fi
        rm -f "${_new}.old" "${_new}.cur"
    else
        REFRESH_NOTE="regenerated from ${MSTR_TAB} (file was missing)"
    fi
    mv -f "${_new}" "${F}"
    [[ "${TR}" == "Y" && ${W_COL_CNT} -eq 0 ]] && REFRESH_NOTE="${REFRESH_NOTE} ; WARN TRANS_YN=Y but no column in ALL_TAB_COLUMNS, SELECT * written"
    rm -f "${_cols}" "${_tcol}"
    REFRESH_STATUS="OK"
    return 0
}

# ============================================================
# [R] 1 / 4. Generate SQL : _generate <PRE|DDAY>   (foreground)
# ============================================================
_fmt_row() {
    local _t _c _tr _so _st _to _tt _mt _mf _sz _w
    while IFS='|' read -r _t _c _tr _so _st _to _tt _mt _mf _sz _w ; do
        _out "  %s.%s -> %s.%s [%s/%s%s] %s\n" "${_so}" "${_st}" "${_to}" "${_tt}" "${_mt}" "${_mf}" \
             "$([[ "${_tr}" == "Y" ]] && echo "/COL_MAP")" "${_w:-(no condition)}"
    done
}

_generate() {
    local PHASE="$1"
    local OUT_DIR="${CMD_DIR}/${PHASE}"
    local TGT_COND WHERE_EXPR TOTAL RUN_CNT EXCL_CNT MAP_CNT OLD_CNT GEN_CNT DUP_CNT
    local _t _c TR SO ST TO TT MT MF SZ WHERE_CLAUSE OUT_FILE
    local _k _so _st _o _n _flag COL EXPR COL_CNT REN_CNT ADD_CNT SKIP_CNT COL_LIST SEL_LIST
    local NUM WARN_CNT GEN_START GEN_START_STR _map

    _new_log "GEN_${PHASE}"
    _out "%s\n" "$SEP"
    _log "Generate ${PHASE} SQL : MSTR_ID=${MSTR_ID} -> ${OUT_DIR}"
    _out "%s\n" "$SEP"

    _phase_cond "${PHASE}"

    # 1) target rows : DBM_MIG_MSTR only
    { _sql_head ; _row_sql "${TARGET_WHERE}" ; echo "EXIT;" ; } > ${TMP_SQL}

    if ! _run_sql ${TMP_SQL} ; then
        _fail "Failed to read ${MSTR_TAB}"
        _show_db_errors
        return 1
    fi

    grep '^ROW|' ${TMP_OUT} | sed 's/[[:space:]]*$//' > ${TMP_LIST}
    awk -F'|' '$2 == "RUN"' ${TMP_LIST} > ${TMP_RUN}

    TOTAL=$(wc -l < ${TMP_LIST} | tr -d ' ')
    RUN_CNT=$(wc -l < ${TMP_RUN} | tr -d ' ')
    MAP_CNT=$(awk -F'|' '$3 == "Y"' ${TMP_RUN} | wc -l | tr -d ' ')
    EXCL_CNT=$(awk -F'|' '$2 == "EXCL"' ${TMP_LIST} | wc -l | tr -d ' ')
    OLD_CNT=$(_out_cnt ${PHASE})

    # 2) column list : only when TRANS_YN = 'Y' targets exist (ALL_TAB_COLUMNS + DBM_MIG_COL_MAP)
    : > ${TMP_COLS}
    if [[ ${MAP_CNT} -gt 0 ]] ; then
        { _sql_head ; _col_sql "${M_ID}" "" ; echo "EXIT;" ; } > ${TMP_SQL}
        if ! _run_sql ${TMP_SQL} ; then
            _fail "Failed to read the column list of ${MAP_CNT} TRANS_YN=Y table(s) : ALL_TAB_COLUMNS / ${MAP_TAB}"
            _show_db_errors
            return 1
        fi
        grep '^COL|' ${TMP_OUT} | sed 's/[[:space:]]*$//' > ${TMP_COLS}
    fi

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
    GEN_CNT=0 ; DUP_CNT=0 ; WARN_CNT=0 ; NUM=0
    GEN_START=$(date +%s) ; GEN_START_STR=$(date '+%Y-%m-%d %H:%M:%S')

    # --- integrated log : the GEN block is buffered and appended at once,
    #     so it does not get mixed into a table block of a running background worker ---
    : > ${TMP_GENBUF}
    TOTAL_DEST="${TMP_GENBUF}"
    _total "\n%s\n" "$SEP"
    _total " [GEN] %s  MSTR_ID=%s  TABLES=%s  PID=%s\n" "${PHASE}" "${MSTR_ID}" "${RUN_CNT}" "$$"
    _total "       START=%s  DB=%s  DBLINK=%s\n" "${GEN_START_STR}" "${DB_TYPE}" "${SRC_DBLINK}"
    _total "       MIG_YN=Y rows %s  generate %s (COL_MAP %s)  excluded %s  deleted old .out %s\n" \
           "${TOTAL}" "${RUN_CNT}" "${MAP_CNT}" "${EXCL_CNT}" "${OLD_CNT}"
    _total "       DIR=%s\n" "${OUT_DIR}"
    _total "       LOG=%s\n" "${LOGFILE}"
    _total "%s\n\n" "$SEP"
    TOTAL_ON="Y"

    while IFS='|' read -r _t _c TR SO ST TO TT MT MF SZ WHERE_CLAUSE <&3 ; do
        NUM=$(( NUM + 1 ))
        OUT_FILE="${OUT_DIR}/$(_out_name "${TO}" "${TT}" "${SO}" "${ST}")"
        if [[ -f "${OUT_FILE}" ]] ; then
            _out "  [WARN] duplicate row %s.%s -> %s.%s : %s overwritten\n" "${SO}" "${ST}" "${TO}" "${TT}" "$(basename "${OUT_FILE}")"
            DUP_CNT=$(( DUP_CNT + 1 )) ; WARN_CNT=$(( WARN_CNT + 1 ))
        else
            GEN_CNT=$(( GEN_CNT + 1 ))
        fi

        # --- header + INSERT INTO SELECT (TRANS_YN = 'Y' : column list, RENAME / ADD from DBM_MIG_COL_MAP) ---
        _write_out "${PHASE}" "${MSTR_ID}" "${TR}" "${SO}" "${ST}" "${TO}" "${TT}" "${MT}" "${MF}" "${SZ}" "${WHERE_CLAUSE}" \
                   "${TMP_COLS}" "${TMP_TCOL}" "${OUT_FILE}"
        if [[ "${TR}" == "Y" && ${W_COL_CNT} -eq 0 ]] ; then
            _out "  [WARN] %s.%s : TRANS_YN=Y but no column in ALL_TAB_COLUMNS, SELECT * written\n" "${TO}" "${TT}"
            WARN_CNT=$(( WARN_CNT + 1 ))
        fi

        # one line per generated file : GEN log + integrated log (not the terminal)
        _map="" ; [[ "${TR}" == "Y" ]] && _map="  COL_MAP(columns ${W_COL_CNT}, RENAME ${W_REN_CNT}, ADD ${W_ADD_CNT})"
        _file_out "  [%*d/%s]  %s.%s -> %s.%s  %s  %s%s\n" "${#RUN_CNT}" "${NUM}" "${RUN_CNT}" \
                  "${SO}" "${ST}" "${TO}" "${TT}" "$(basename "${OUT_FILE}")" "${WHERE_CLAUSE:-(no condition)}" "${_map}"
    done 3< ${TMP_RUN}

    _ok "${GEN_CNT} SQL file(s) generated in ${OUT_DIR}"
    [[ ${DUP_CNT} -gt 0 ]] && _out "  [WARN] %s duplicate target row(s) overwritten\n" "${DUP_CNT}"

    _file_out "\n%s\n" "$SEP"
    _file_out " [END] GEN %s  MSTR_ID=%s  RESULT=DONE\n" "${PHASE}" "${MSTR_ID}"
    _file_out "       FILES=%s  DUPLICATE=%s  WARN=%s\n" "${GEN_CNT}" "${DUP_CNT}" "${WARN_CNT}"
    _file_out "       START=%s  END=%s  ELAPSED=%s\n" "${GEN_START_STR}" "$(date '+%Y-%m-%d %H:%M:%S')" "$(_fmt_sec $(( $(date +%s) - GEN_START )))"
    _file_out "%s\n" "$SEP"

    TOTAL_ON=""
    TOTAL_DEST="${TOTAL_LOG}"
    cat ${TMP_GENBUF} >> "${TOTAL_LOG}"
    rm -f ${TMP_GENBUF}
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
    _out "  Worker    : %s table(s) at once, order TAB_SIZE small first\n" "${WORKER_DEGREE}"
    if [[ "${SQL_REFRESH}" == "Y" ]] ; then
        _out "  SQL       : SQL_REFRESH=Y : regenerated from %s right before each table (cmd/%s/*.out overwritten, changed -> .bak, no longer a target -> SKIP)\n" "${MSTR_TAB}" "${PHASE}"
    else
        _out "  SQL       : SQL_REFRESH=N : cmd/%s/*.out run as they are (MIG.env SQL_REFRESH=Y : regenerate before each table)\n" "${PHASE}"
    fi
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
        _out "  %s.%s -> %s.%s : %s %s\n" "${_so}" "${_st}" "${_to}" "${_tt}" "$(basename "${_f}")" "$([[ -f "${_f}" ]] || { [[ "${SQL_REFRESH}" == "Y" ]] && echo "[SQL file missing : regenerated before run]" || echo "[SQL file missing]" ; })"
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
    if [[ "${SQL_REFRESH}" == "Y" ]] ; then
        _out "  SQL file missing  : %s (regenerated before run while still a target)\n" "${MISS_CNT}"
        _out "  SQL               : SQL_REFRESH=Y : regenerated from %s right before each table (changed -> .bak, no longer a target -> SKIP)\n" "${MSTR_TAB}"
    else
        _out "  SQL file missing  : %s (will stay FAIL)\n" "${MISS_CNT}"
        _out "  SQL               : SQL_REFRESH=N : .out files run as they are (MIG.env SQL_REFRESH=Y : regenerate before each table)\n"
    fi
    _out "  Worker            : %s table(s) at once, order TAB_SIZE small first\n" "${WORKER_DEGREE}"
    _out "  Hint              : %s\n\n" "$(_hint_text)"
    _head_tail ${TMP_LIST} _fmt_fail

    if ! _confirm "Retry ${TOTAL} FAIL table(s) of ${PHASE} RUN_ID=${RUN_ID} in background?" ; then
        _log "Retry ${PHASE} FAILED cancelled by user"
        return 0
    fi
    _launch RETRY "${PHASE}" "${RUN_ID}"
}

# ============================================================
# [l] Total Log : tail -F of the integrated log, only "q" + Enter returns (tail is killed, Ctrl+C ignored)
# ============================================================
_view_log() {
    local _key

    if [[ ! -f "${TOTAL_LOG}" ]] ; then
        _say "[FAIL] No integrated log yet : ${TOTAL_LOG}"
        return 1
    fi

    echo "$SEP"
    echo " tail -F ${TOTAL_LOG}"
    if _lock_read ; then
        if [[ "${W_STATE}" == "RUNNING" ]] ; then
            echo " running : ${L_ACTION} ${L_PHASE} RUN_ID=${L_RUN_ID}  (this run only : ${L_LOG})"
        else
            echo " stale lock : ${L_ACTION} ${L_PHASE} RUN_ID=${L_RUN_ID} PID=${L_PID} (worker process not found)"
        fi
    fi
    echo " >>> type q + Enter to return to the menu <<<"
    echo "$SEP"

    trap '' INT
    # "tail | colour filter" in the background ; the tail PID is written to a file so that killing tail
    # ends the whole pipeline (process substitution is not used : it is not reliable on every bash / OS)
    local _pipe _i
    rm -f "${TMP_TAILPID}"
    { tail -n 40 -F "${TOTAL_LOG}" & echo $! > "${TMP_TAILPID}" ; wait ; } | _paint &
    _pipe=$!
    for _i in 1 2 3 ; do
        [[ -s "${TMP_TAILPID}" ]] && break
        sleep 1
    done
    TAIL_PID=$(cat "${TMP_TAILPID}" 2>/dev/null)
    while read -r _key ; do
        [[ "${_key}" == "q" || "${_key}" == "Q" ]] && break
    done
    [[ -n "${TAIL_PID}" ]] && kill ${TAIL_PID} 2>/dev/null
    wait ${_pipe} 2>/dev/null
    rm -f "${TMP_TAILPID}"
    TAIL_PID=""
    trap 'exit 130' INT
}

# ============================================================
# [s] Status : DBM_XDN_LOG of the running RUN_ID (or the latest RUN_ID of MSTR_ID)
# ============================================================
_status() {
    local RID_EXPR WORKER RID TYPE _s _c TOTAL DONE PCT T_START T_END _tbl _since _sec _err _fail_n
    local P_CNT R_CNT S_CNT F_CNT

    if _lock_read && [[ "${L_RUN_ID}" =~ ^[0-9]+$ ]] ; then
        RID_EXPR="${L_RUN_ID}"
        if [[ "${W_STATE}" == "RUNNING" ]] ; then
            WORKER="RUNNING  ${L_ACTION} ${L_PHASE}  PID=${L_PID}  since ${L_START}${W_NOTE:+  (${W_NOTE})}"
        else
            WORKER="NOT FOUND  (stale lock : ${L_ACTION} ${L_PHASE} PID=${L_PID} since ${L_START})"
        fi
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
        _say "[FAIL] Failed to read ${LOG_TAB}"
        _db_errors | sed 's/^/  /'
        return 1
    fi

    RID=$(_get RID)
    if [[ -z "${RID}" ]] ; then
        _say "[FAIL] No run in ${LOG_TAB} for MSTR_ID='${MSTR_ID}'"
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
        [[ "${W_STATE}" != "RUNNING" ]] && printf "  (no worker process : these rows were interrupted -> check the DB session, then [U] Unlock)\n"
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
# [S] Stop : the worker starts no new table ; running tables finish
# ============================================================
_stop() {
    if ! _lock_read ; then
        _say "[FAIL] No background migration is running"
        return 1
    fi
    if [[ "${W_STATE}" != "RUNNING" ]] ; then
        _say "[FAIL] No worker process for ${L_ACTION} ${L_PHASE} RUN_ID=${L_RUN_ID} (stale lock) : nothing to stop, use [U] Unlock"
        return 1
    fi
    if [[ -f "${STOP_FILE}" ]] ; then
        _say "[OK]   Stop already requested : ${L_ACTION} ${L_PHASE} RUN_ID=${L_RUN_ID} starts no new table"
        return 0
    fi
    if ! _confirm "Stop ${L_ACTION} ${L_PHASE} RUN_ID=${L_RUN_ID} (no new table ; running tables finish)?" ; then
        return 0
    fi
    touch "${STOP_FILE}"
    _say "[OK]   Stop requested : no new table is started, running tables finish ([l] Total Log to follow)"
}

# ============================================================
# [U] Unlock : remove a stale lock and mark interrupted RUNNING rows as FAIL (only when no worker process)
# ============================================================
_unlock() {
    local _ps _cli _rows _cnt _lock_txt="" _now _t _rid _mt _tbl _st

    if _lock_read && [[ "${W_STATE}" == "RUNNING" ]] ; then
        _say "[FAIL] Worker is running : ${L_ACTION} ${L_PHASE} RUN_ID=${L_RUN_ID} PID=${L_PID} (use [S] Stop)"
        return 1
    fi
    [[ "${W_STATE}" == "STALE" ]] && _lock_txt="${L_ACTION} ${L_PHASE} RUN_ID=${L_RUN_ID} PID=${L_PID} since ${L_START}"

    # a DB client started by a worker of this directory is still alive : its INSERT may still commit
    _ps=$(ps -eo pid=,args= 2>/dev/null)
    _cli=$(printf "%s\n" "${_ps}" | awk -v tmp="${TMP_DIR}/RUN_MIG_" 'index($0, tmp) { print "  PID " $0 }')
    if [[ -n "${_cli}" ]] ; then
        _say "[FAIL] A DB client of an earlier worker is still running (its INSERT may still commit) :"
        echo "${_cli}"
        echo "       wait until it ends (or check the DB session and kill it), then [U] Unlock again"
        return 1
    fi

    cat > ${TMP_SQL} <<EOF
$(_sql_head)
SELECT 'ULROW|' || RUN_ID || '|' || MIG_TYPE || '|' || SRC_OWNER || '.' || SRC_TABLE_NAME || ' -> ' || TGT_OWNER || '.' || TGT_TABLE_NAME
       || '|' || TO_CHAR(START_TIME, 'YYYY-MM-DD HH24:MI:SS')
  FROM ${LOG_TAB} WHERE MSTR_ID = '${M_ID}' AND STATUS = 'RUNNING'
 ORDER BY RUN_ID, SRC_OWNER, SRC_TABLE_NAME;
EXIT;
EOF
    if ! _run_sql ${TMP_SQL} ; then
        _say "[FAIL] Failed to read ${LOG_TAB}"
        _db_errors | sed 's/^/  /'
        return 1
    fi
    _rows=$(grep '^ULROW|' ${TMP_OUT} | sed 's/[[:space:]]*$//')
    _cnt=$(printf "%s" "${_rows}" | grep -c .)

    if [[ -z "${_lock_txt}" && ${_cnt} -eq 0 ]] ; then
        _say "[OK]   Nothing to unlock (no lock file, no RUNNING row in ${LOG_TAB})"
        return 0
    fi

    echo "$SEP"
    echo " [UNLOCK] MSTR_ID=${MSTR_ID}"
    echo "$SEP"
    printf "  Lock file    : %s\n" "${_lock_txt:-(none)}"
    printf "  RUNNING rows : %s  (-> STATUS = FAIL, retried by [R] Run -> Retry FAILED)\n" "${_cnt}"
    printf "%s\n" "${_rows}" | head -10 | while IFS='|' read -r _t _rid _mt _tbl _st ; do
        [[ -n "${_rid}" ]] && printf "    RUN_ID=%s  %-4s  %s  since %s\n" "${_rid}" "${_mt}" "${_tbl}" "${_st}"
    done
    [[ ${_cnt} -gt 10 ]] && printf "    ... %s more\n" "$(( _cnt - 10 ))"
    echo
    echo "  * make sure no DB session of the migration is still active (v\$session) before unlocking"
    echo "  * an interrupted table may have committed : check the target count before retry"
    if ! _confirm "Remove the lock and mark ${_cnt} RUNNING row(s) as FAIL?" ; then
        _say "[OK]   Unlock cancelled"
        return 0
    fi

    _now=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ ${_cnt} -gt 0 ]] ; then
        cat > ${TMP_SQL} <<EOF
$(_sql_head)
UPDATE ${LOG_TAB}
   SET STATUS = 'FAIL', END_TIME = SYSDATE, ELAPSED_TIME = ${ELAPSED_SQL},
       ERROR_MSG = 'INTERRUPTED : worker process not found, unlocked by user at ${_now}'
 WHERE MSTR_ID = '${M_ID}' AND STATUS = 'RUNNING';
COMMIT;
EXIT;
EOF
        if ! _run_sql ${TMP_SQL} ; then
            _say "[FAIL] Failed to update ${LOG_TAB} (lock file kept)"
            _db_errors | sed 's/^/  /'
            return 1
        fi
    fi
    rm -f "${LOCK_FILE}" "${STATE_FILE}" "${STOP_FILE}" "${SLOT_PREFIX}"*

    # completion record of the interrupted run in the integrated log
    printf "\n%s\n [UNLOCK] MSTR_ID=%s  AT=%s\n       LOCK=%s\n       RUNNING -> FAIL : %s row(s)\n%s\n" \
           "$SEP" "${MSTR_ID}" "${_now}" "${_lock_txt:-(none)}" "${_cnt}" "$SEP" >> "${TOTAL_LOG}"

    _say "[OK]   Unlocked : lock removed, ${_cnt} RUNNING row(s) marked FAIL ([R] Run -> Retry FAILED to run them again)"
}

# ============================================================
# Worker : one table / progress / header / footer
# ============================================================
# _hb_start <start epoch> <label> : one "RUNNING" event line every HEARTBEAT_SEC until _hb_stop
_hb_start() {
    local _t0="$1" _lbl="$2"
    (
        trap - EXIT INT TERM HUP
        _s=0
        while sleep 1 ; do
            _s=$(( _s + 1 ))
            if (( _s % HEARTBEAT_SEC == 0 )) ; then
                _event "${W_SLOT:-1}" "RUNNING  ${_lbl}  $(_fmt_sec $(( $(date +%s) - _t0 ))) elapsed"
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

# _exec_table <OUT_FILE> <RUN_ID> <PHASE> <MSTR_ID> <SRC_OWNER> <SRC_TABLE> <TGT_OWNER> <TGT_TABLE> <NUM> <TOTAL> [PRE_ERROR]
#   run one .out file, update its DBM_XDN_LOG row, write one block to the progress log
#   PRE_ERROR (e.g. SQL regenerate failed) : FAIL without running ; result -> EXEC_STATUS / EXEC_ERR / EXEC_LABEL
_exec_table() {
    local F="$1" RID="$2" PHASE="$3" MID="$4" SO="$5" ST="$6" TO="$7" TT="$8" NUM="$9" TOTAL="${10}"
    local DBL WHERE_CLAUSE SRC_OBJ TGT_OBJ KEY ERR_SQL CNT_SRC CNT_INS CNT_TGT T_START T_END _cmp

    TGT_OBJ="${TO}.${TT}"
    KEY="RUN_ID = ${RID} AND MSTR_ID = '$(_q "${MID}")' AND SRC_OWNER = '$(_q "${SO}")' AND SRC_TABLE_NAME = '$(_q "${ST}")' AND TGT_OWNER = '$(_q "${TO}")' AND TGT_TABLE_NAME = '$(_q "${TT}")' AND MIG_TYPE = '${PHASE}'"
    EXEC_STATUS="SUCCESS" ; EXEC_ERR="" ; EXEC_LABEL="${SO}.${ST} -> ${TGT_OBJ}" ; EXEC_ELAPSED="00:00:00"

    _out "\n%s\n" "$DASH"
    _out "[%*d/%s]  %s%s\n" "${#TOTAL}" "${NUM}" "${TOTAL}" "${EXEC_LABEL}" "${W_SLOT:+   (W${W_SLOT})}"
    _out "%s\n" "$DASH"
    _out "  File      : %s\n" "$(basename "${F}")"
    [[ -n "${REFRESH_NOTE}" ]] && _out "  SQL file  : %s\n" "${REFRESH_NOTE}"

    # --- SQL could not be (re)generated / SQL file missing : FAIL without running ---
    if [[ -n "${11}" || ! -f "${F}" ]] ; then
        EXEC_STATUS="FAIL" ; EXEC_ERR="${11:-SQL file not found : ${F}}"
        cat > ${TMP_SQL} <<EOF
$(_sql_head)
UPDATE ${LOG_TAB} SET STATUS = 'FAIL', START_TIME = SYSDATE, END_TIME = SYSDATE, ELAPSED_TIME = '00:00:00', ERROR_MSG = '$(_q "${EXEC_ERR}")' WHERE ${KEY};
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
    _out "  Parallel  : %s  (worker W%s)\n" "${PARALLEL_DEGREE}" "${W_SLOT:-1}"
    T_START=$(date +%s)
    _out "  Start     : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    _hb_start "${T_START}" "$(printf "[%*d/%s] %s" "${#TOTAL}" "${NUM}" "${TOTAL}" "${EXEC_LABEL}")"

    # --- RUNNING, START_TIME, ROW_CNT_SRC ---
    cat > ${TMP_SQL} <<EOF
$(_sql_head)
UPDATE ${LOG_TAB} SET STATUS = 'RUNNING', START_TIME = SYSDATE, END_TIME = NULL, ELAPSED_TIME = NULL, ERROR_MSG = NULL WHERE ${KEY};
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
UPDATE ${LOG_TAB} SET STATUS = '${EXEC_STATUS}', END_TIME = SYSDATE, ELAPSED_TIME = ${ELAPSED_SQL}, ERROR_MSG = ${ERR_SQL} WHERE ${KEY};
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
    EXEC_ELAPSED=$(_fmt_sec $(( T_END - T_START )))
    _out "  TGT count : %s\n" "$(_num "${CNT_TGT}")"
    _out "  End       : %s  (%s)\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$(_fmt_sec $(( T_END - T_START )))"

    if [[ "${EXEC_STATUS}" == "SUCCESS" ]] ; then
        _out "  Result    : SUCCESS\n"
    else
        _out "  Result    : FAIL  %s\n" "${EXEC_ERR}"
    fi
}

# _count_result : add the last table result to SUCC_CNT / FAIL_CNT / FAIL_LIST / SKIP_CNT / SKIP_LIST
_count_result() {
    if [[ "${EXEC_STATUS}" == "SUCCESS" ]] ; then
        SUCC_CNT=$(( SUCC_CNT + 1 ))
    elif [[ "${EXEC_STATUS}" == "SKIP" ]] ; then
        SKIP_CNT=$(( SKIP_CNT + 1 ))
        SKIP_LIST="${SKIP_LIST}   ${EXEC_LABEL}  ${EXEC_ERR}\n"
    else
        FAIL_CNT=$(( FAIL_CNT + 1 ))
        FAIL_LIST="${FAIL_LIST}   ${EXEC_LABEL}  $(printf "%s" "${EXEC_ERR}" | awk '{ print substr($0, 1, 100) }')\n"
    fi
}

# _event <slot | -> <text> : one time-stamped line to the run log and the integrated log at once
#   "HH:MI:SS [Wn] START / RUNNING / SUCCESS / FAIL / STOP ..." (a short single write : safe with parallel tables)
_event() {
    local _l
    _l="$(date '+%H:%M:%S') [W$1] $2"
    printf "%s\n" "${_l}" >> "${RUN_LOG:-${LOGFILE}}"
    printf "%s\n" "${_l}" >> "${TOTAL_LOG}"
}

# _slot_run <SLOT> <NUM> <TOTAL> <FILE> <RUN_ID> <PHASE> <MSTR_ID> <SO> <ST> <TO> <TT> : one table (background sub shell)
#   own temp files <base>.sql / .out ; START event at once ; table block -> <base>.blk , SQL detail -> <base>.det ,
#   result "STATUS|ELAPSED|ERROR" -> <base>.res ; the coordinator (_dispatch) writes them to the logs when it ends
_slot_run() {
    local SLOT="$1" NUM="$2" TOTAL="$3" F="$4" RID="$5" PHASE="$6" MID="$7" SO="$8" ST="$9" TO="${10}" TT="${11}"
    local _base="${TMP_DIR}/RUN_MIG_${COORD_PID}_W${SLOT}"

    trap - EXIT
    trap 'exit 143' TERM
    W_SLOT="${SLOT}"
    TMP_SQL="${_base}.sql" ; TMP_OUT="${_base}.out"
    LOGFILE="${_base}.blk" ; : > "${LOGFILE}"
    DETAIL_LOG="${_base}.det" ; : > "${DETAIL_LOG}"
    TOTAL_ON="" ; HB_PID=""
    rm -f "${_base}.res"

    _hint_load      # PARALLEL of this table = value in MIG_HINT.conf when it starts
    printf "%s|%s|%s|%s|%s\n" "${NUM}" "${TOTAL}" "${SO}.${ST} -> ${TO}.${TT}" "$(date +%s)" "${PARALLEL_DEGREE}" > "${SLOT_PREFIX}${SLOT}"
    _event "${SLOT}" "$(printf "START    [%*d/%s] %s.%s -> %s.%s  (PARALLEL %s)" "${#TOTAL}" "${NUM}" "${TOTAL}" "${SO}" "${ST}" "${TO}" "${TT}" "${PARALLEL_DEGREE}")"

    # SQL_REFRESH=Y : SQL of this table regenerated from DBM_MIG_MSTR / DBM_MIG_COL_MAP right before it runs (cmd/<PHASE>/*.out overwritten)
    REFRESH_STATUS="" ; REFRESH_NOTE=""
    [[ "${SQL_REFRESH}" == "Y" ]] && _refresh_out "${F}" "${PHASE}" "${MID}" "${SO}" "${ST}" "${TO}" "${TT}"
    case "${REFRESH_STATUS}" in
        SKIP)
            EXEC_STATUS="SKIP" ; EXEC_ERR="${REFRESH_NOTE}" ; EXEC_ELAPSED="00:00:00"
            _out "\n%s\n" "$DASH"
            _out "[%*d/%s]  %s.%s -> %s.%s   (W%s)\n" "${#TOTAL}" "${NUM}" "${TOTAL}" "${SO}" "${ST}" "${TO}" "${TT}" "${SLOT}"
            _out "%s\n" "$DASH"
            _out "  File      : %s\n" "$(basename "${F}")"
            _out "  Result    : SKIP  %s (not run, %s row left as it is)\n" "${REFRESH_NOTE}" "${LOG_TAB}"
            ;;
        ERROR)
            _exec_table "${F}" "${RID}" "${PHASE}" "${MID}" "${SO}" "${ST}" "${TO}" "${TT}" "${NUM}" "${TOTAL}" "${REFRESH_NOTE}"
            ;;
        *)
            _exec_table "${F}" "${RID}" "${PHASE}" "${MID}" "${SO}" "${ST}" "${TO}" "${TT}" "${NUM}" "${TOTAL}"
            ;;
    esac

    printf "%s|%s|%s\n" "${EXEC_STATUS}" "${EXEC_ELAPSED}" "${EXEC_ERR}" > "${_base}.res"
    rm -f "${TMP_SQL}" "${TMP_OUT}" "${SLOT_PREFIX}${SLOT}"
}

# _dispatch <PHASE> <RUN_ID> <QUEUE_FILE> <TOTAL> <start epoch>
#   QUEUE_FILE lines : TAB_SIZE|FILE|MSTR_ID|SRC_OWNER|SRC_TABLE|TGT_OWNER|TGT_TABLE (already in run order)
#   up to WORKER_DEGREE tables at once ; MIG_HINT.conf and the stop file are checked every second
#   a finished table : SUCCESS / FAIL event + its block + Progress are appended to the logs by this one process
_dispatch() {
    local PHASE="$1" RID="$2" QUEUE="$3" TOTAL="$4" RSTART="$5"
    local -a S_PID S_NUM S_LABEL
    local NUM=0 RUNNING=0 S_MAX=0 _s _base _st _el _err _msg _sz F MID SO ST TO TT

    exec 4< "${QUEUE}"
    while : ; do
        # --- 1) finished tables ---
        for (( _s = 1 ; _s <= S_MAX ; _s++ )) ; do
            [[ -n "${S_PID[_s]}" ]] || continue
            kill -0 "${S_PID[_s]}" 2>/dev/null && continue
            wait "${S_PID[_s]}" 2>/dev/null
            _base="${TMP_DIR}/RUN_MIG_$$_W${_s}"
            _st="" ; _el="" ; _err=""
            [[ -f "${_base}.res" ]] && IFS='|' read -r _st _el _err < "${_base}.res"
            if [[ -z "${_st}" ]] ; then
                _st="FAIL" ; _err="worker W${_s} ended without a result (see ${LOGFILE%.log}_worker.err)"
            fi
            EXEC_STATUS="${_st}" ; EXEC_ERR="${_err}" ; EXEC_LABEL="${S_LABEL[_s]}"
            _count_result
            RUNNING=$(( RUNNING - 1 )) ; S_PID[_s]=""

            _msg=$(printf "%-8s [%*d/%s] %s  %s" "${_st}" "${#TOTAL}" "${S_NUM[_s]}" "${TOTAL}" "${S_LABEL[_s]}" "${_el:-?}")
            [[ "${_st}" != "SUCCESS" && -n "${_err}" ]] && _msg="${_msg}  $(printf "%s" "${_err}" | awk '{ print substr($0, 1, 100) }')"
            _event "${_s}" "${_msg}"
            {
                [[ -f "${_base}.blk" ]] && cat "${_base}.blk"
                printf "  Progress  : %s/%s done (%s%%)  SUCCESS %s  FAIL %s  SKIP %s  running %s  waiting %s  total elapsed %s\n" \
                       "$(( SUCC_CNT + FAIL_CNT + SKIP_CNT ))" "${TOTAL}" "$(( (SUCC_CNT + FAIL_CNT + SKIP_CNT) * 100 / TOTAL ))" \
                       "${SUCC_CNT}" "${FAIL_CNT}" "${SKIP_CNT}" "${RUNNING}" "$(( TOTAL - NUM ))" "$(_fmt_sec $(( $(date +%s) - RSTART )))"
            } > "${_base}.blk2"
            cat "${_base}.blk2" >> "${LOGFILE}"
            cat "${_base}.blk2" >> "${TOTAL_LOG}"
            [[ -f "${_base}.det" && -n "${DETAIL_LOG}" ]] && cat "${_base}.det" >> "${DETAIL_LOG}"
            rm -f "${_base}.blk" "${_base}.blk2" "${_base}.res" "${_base}.det"
        done

        # --- 2) stop request : no new table ---
        if [[ "${STOPPED}" != "Y" && -f "${STOP_FILE}" ]] ; then
            rm -f "${STOP_FILE}"
            STOPPED="Y"
            _event "-" "STOP     stop requested : $(( TOTAL - NUM )) table(s) not started, ${RUNNING} running table(s) finish"
        fi

        # --- 3) start tables up to WORKER_DEGREE (changed live by [h] Hint) ---
        _hint_load
        if [[ "${STOPPED}" != "Y" ]] ; then
            # RUNNING < WORKER_DEGREE : after the degree is lowered, new tables wait until enough running tables end
            for (( _s = 1 ; _s <= WORKER_DEGREE && RUNNING < WORKER_DEGREE && NUM < TOTAL ; _s++ )) ; do
                [[ -z "${S_PID[_s]}" ]] || continue
                if ! IFS='|' read -r _sz F MID SO ST TO TT <&4 ; then
                    NUM=${TOTAL}
                    break
                fi
                NUM=$(( NUM + 1 )) ; RUNNING=$(( RUNNING + 1 ))
                S_NUM[_s]="${NUM}" ; S_LABEL[_s]="${SO}.${ST} -> ${TO}.${TT}"
                (( _s > S_MAX )) && S_MAX=${_s}
                _slot_run "${_s}" "${NUM}" "${TOTAL}" "${F}" "${RID}" "${PHASE}" "${MID}" "${SO}" "${ST}" "${TO}" "${TT}" &
                S_PID[_s]=$!
            done
        fi

        printf "%s|%s|%s|%s|%s|%s|%s\n" "$(( SUCC_CNT + FAIL_CNT + SKIP_CNT ))" "${TOTAL}" "${SUCC_CNT}" "${FAIL_CNT}" "${RUNNING}" "$(( TOTAL - NUM ))" "${SKIP_CNT}" > "${STATE_FILE}"

        if (( RUNNING == 0 )) && [[ "${STOPPED}" == "Y" ]] || (( RUNNING == 0 && NUM >= TOTAL )) ; then
            break
        fi
        sleep 1
    done
    exec 4<&-
}

# _run_header <RUN|RETRY> <PHASE> <RUN_ID> <TOTAL>
_run_header() {
    if [[ -n "${TOTAL_ON}" ]] ; then _total "\n" ; fi
    _out "%s\n" "$SEP"
    _out " [%s] %s  MSTR_ID=%s  RUN_ID=%s  TABLES=%s  PID=%s\n" "$1" "$2" "${MSTR_ID}" "$3" "$4" "$$"
    _out "       START=%s  DB=%s  DBLINK=%s  HEARTBEAT=%ss  SQL_REFRESH=%s\n" "${RUN_START_STR}" "${DB_TYPE}" "${SRC_DBLINK}" "${HEARTBEAT_SEC}" "${SQL_REFRESH}"
    _out "       WORKER=%s  HINT=%s   (changeable while running : [h] Hint)\n" "${WORKER_DEGREE}" "$(_hint_text)"
    _out "       LOG=%s\n" "${LOGFILE}"
    _out "       DETAIL=%s\n" "${DETAIL_LOG}"
    _out "%s\n" "$SEP"
}

# _run_footer <RUN|RETRY> <PHASE> <RUN_ID> <TOTAL> <start epoch>
#   RESULT : ERROR (RUN_RESULT set by an early failure) / STOPPED / DONE
_run_footer() {
    local _end _result _menu
    _end=$(date +%s)
    _result="${RUN_RESULT:-DONE}" ; [[ "${STOPPED}" == "Y" ]] && _result="STOPPED"
    [[ "$2" == "PRE" ]] && _menu=3 || _menu=6

    _out "\n%s\n" "$SEP"
    _out " [END] %s %s  MSTR_ID=%s  RUN_ID=%s  RESULT=%s\n" "$1" "$2" "${MSTR_ID}" "$3" "${_result}"
    _out "       TOTAL=%s  SUCCESS=%s  FAIL=%s  SKIP=%s  NOT_RUN=%s\n" "$4" "${SUCC_CNT}" "${FAIL_CNT}" "${SKIP_CNT}" "$(( $4 - SUCC_CNT - FAIL_CNT - SKIP_CNT ))"
    _out "       START=%s  END=%s  ELAPSED=%s\n" "${RUN_START_STR}" "$(date '+%Y-%m-%d %H:%M:%S')" "$(_fmt_sec $(( _end - $5 )))"
    if [[ ${FAIL_CNT} -gt 0 ]] ; then
        _out " FAILED :\n"
        _out "%b" "${FAIL_LIST}"
        _out " RETRY  : 02.RUN_MIG.sh -> [R] Run -> [%s] Retry %s FAILED\n" "${_menu}" "$2"
    fi
    if [[ ${SKIP_CNT} -gt 0 ]] ; then
        _out " SKIPPED (no longer a target in %s, not run) :\n" "${MSTR_TAB}"
        _out "%b" "${SKIP_LIST}"
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
    local TOTAL RUN_START

    find "${OUT_DIR}" -maxdepth 1 -name '*.out' 2>/dev/null | sort > ${TMP_LIST}
    TOTAL=$(wc -l < ${TMP_LIST} | tr -d ' ')
    RUN_START=$(date +%s) ; RUN_START_STR=$(date '+%Y-%m-%d %H:%M:%S')
    _run_header RUN "${PHASE}" "${RUN_ID}" "${TOTAL}"

    if [[ ${TOTAL} -eq 0 ]] ; then
        _fail "No .out file in ${OUT_DIR}"
        RUN_RESULT="ERROR"
        _run_footer RUN "${PHASE}" "${RUN_ID}" 0 "${RUN_START}"
        return 1
    fi

    # every .out header in one pass : TAB_SIZE|FILE|MSTR_ID|SRC_OWNER|SRC_TABLE_NAME|TGT_OWNER|TGT_TABLE_NAME
    _out_headers < ${TMP_LIST} > ${TMP_COLS}

    {
        _sql_head
        awk -F'|' -v q="'" -v tab="${LOG_TAB}" -v rid="${RUN_ID}" -v ph="${PHASE}" '
            function lit(s) { gsub(q, q q, s) ; return q s q }
            { printf "INSERT INTO %s (MSTR_ID, RUN_ID, SRC_OWNER, SRC_TABLE_NAME, TGT_OWNER, TGT_TABLE_NAME, MIG_TYPE, STATUS) VALUES (%s, %s, %s, %s, %s, %s, %s, %s);\n",
                     tab, lit($3), rid, lit($4), lit($5), lit($6), lit($7), lit(ph), lit("PENDING") }' ${TMP_COLS}
        echo "COMMIT;"
        echo "EXIT;"
    } > ${TMP_SQL}

    if ! _run_sql ${TMP_SQL} ; then
        _fail "Failed to register PENDING rows in ${LOG_TAB}"
        _show_db_errors
        RUN_RESULT="ERROR"
        _run_footer RUN "${PHASE}" "${RUN_ID}" "${TOTAL}" "${RUN_START}"
        return 1
    fi
    _ok "${TOTAL} table(s) registered as PENDING"

    # queue : the header list in run order, TAB_SIZE (.out header) small first
    sort -t'|' -k1,1n -k2,2 ${TMP_COLS} > ${TMP_RUN}

    _dispatch "${PHASE}" "${RUN_ID}" "${TMP_RUN}" "${TOTAL}" "${RUN_START}"

    _run_footer RUN "${PHASE}" "${RUN_ID}" "${TOTAL}" "${RUN_START}"
}

# _worker_retry <PHASE> <RUN_ID> : FAIL rows of RUN_ID, same log rows are updated
_worker_retry() {
    local PHASE="$1" RUN_ID="$2"
    local OUT_DIR="${CMD_DIR}/${PHASE}"
    local TOTAL RUN_START _t SO ST TO TT _err F _sz

    RUN_START=$(date +%s) ; RUN_START_STR=$(date '+%Y-%m-%d %H:%M:%S')

    cat > ${TMP_SQL} <<EOF
$(_sql_head)
$(_fail_rows_sql "${PHASE}" "${RUN_ID}")
EXIT;
EOF
    if ! _run_sql ${TMP_SQL} ; then
        _run_header RETRY "${PHASE}" "${RUN_ID}" 0
        _fail "Failed to read FAIL rows from ${LOG_TAB}"
        _show_db_errors
        RUN_RESULT="ERROR"
        _run_footer RETRY "${PHASE}" "${RUN_ID}" 0 "${RUN_START}"
        return 1
    fi
    grep '^ROW|' ${TMP_OUT} | sed 's/[[:space:]]*$//' > ${TMP_LIST}
    TOTAL=$(wc -l < ${TMP_LIST} | tr -d ' ')
    _run_header RETRY "${PHASE}" "${RUN_ID}" "${TOTAL}"

    if [[ ${TOTAL} -eq 0 ]] ; then
        _ok "No FAIL table in ${PHASE} RUN_ID=${RUN_ID}"
        _run_footer RETRY "${PHASE}" "${RUN_ID}" 0 "${RUN_START}"
        return 0
    fi

    # queue (same format as a run) : a missing SQL file gets TAB_SIZE 0 and is regenerated in its slot
    while IFS='|' read -r _t SO ST TO TT _err ; do
        F="${OUT_DIR}/$(_out_name "${TO}" "${TT}" "${SO}" "${ST}")"
        _sz=0
        [[ -f "${F}" ]] && _sz=$(_hdr TAB_SIZE "${F}")
        [[ "${_sz}" =~ ^[0-9.]+$ ]] || _sz=0
        printf "%s|%s|%s|%s|%s|%s|%s\n" "${_sz}" "${F}" "${MSTR_ID}" "${SO}" "${ST}" "${TO}" "${TT}"
    done < ${TMP_LIST} | sort -t'|' -k1,1n -k2,2 > ${TMP_RUN}

    _dispatch "${PHASE}" "${RUN_ID}" "${TMP_RUN}" "${TOTAL}" "${RUN_START}"

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
    [[ "${W_DONE}" == "Y" ]] && rm -f "${SLOT_PREFIX}"*
    rm -f ${TMP_SQL} ${TMP_OUT} ${TMP_LIST} ${TMP_RUN} ${TMP_COLS} ${TMP_TCOL}
    [[ -s "${LOGFILE%.log}_worker.err" ]] || rm -f "${LOGFILE%.log}_worker.err"
    # launcher sh made by _launch (re-running it would insert the same data again)
    [[ -n "${MIG_RUN_SH}" && "${MIG_RUN_SH}" == "${RUN_DIR}/"*.sh ]] && rm -f "${MIG_RUN_SH}"
}

# ============================================================
# Log viewer with colour (log files stay plain)
#   02.RUN_MIG.sh --tail [LOG_FILE]          tail -F of ./log/MIG_TOTAL.log (or LOG_FILE), Ctrl+C to quit
#   tail -f <LOG_FILE> | 02.RUN_MIG.sh --color
# ============================================================
if [[ "$1" == "--tail" ]] ; then
    _vf="${2:-${TOTAL_LOG}}"
    if [[ ! -f "${_vf}" ]] ; then
        _say "[FAIL] Log file not found : ${_vf}"
        exit 1
    fi
    tail -n 40 -F "${_vf}" | _paint
    exit 0
fi
if [[ "$1" == "--color" ]] ; then
    [[ "${MIG_COLOR}" == [Nn] ]] || COLOR_ON="Y"
    _paint
    exit 0
fi

# ============================================================
# Worker entry (started by _launch through nohup)
# ============================================================
if [[ "$1" == "--worker" ]] ; then
    W_ACTION="$2" ; W_PHASE="$3" ; W_RUN_ID="$4" ; LOGFILE="$5"
    DETAIL_LOG="${LOGFILE%.log}_detail.log"
    # progress goes to the log files ; stderr stays in ..._worker.err for unexpected shell errors
    exec 1>/dev/null
    COLOR_ON=""
    _hint_load
    SUCC_CNT=0 ; FAIL_CNT=0 ; FAIL_LIST="" ; SKIP_CNT=0 ; SKIP_LIST="" ; STOPPED="N" ; W_DONE="N" ; RUN_RESULT=""

    trap '' HUP INT
    trap _worker_exit EXIT
    trap 'exit 143' TERM

    # write the real worker PID into the lock ($! seen by the menu can differ, e.g. a nohup wrapper)
    { IFS='|' read -r _lp _la _lph _lrid _llog W_START < "${LOCK_FILE}" ; } 2>/dev/null
    printf "%s|%s|%s|%s|%s|%s\n" "$$" "${W_ACTION}" "${W_PHASE}" "${W_RUN_ID}" "${LOGFILE}" \
           "${W_START:-$(date '+%Y-%m-%d %H:%M:%S')}" > "${LOCK_FILE}"

    : >> "${LOGFILE}"
    ln -sfn "${LOGFILE}" "${CURRENT_LOG}" 2>/dev/null

    # everything the worker writes also goes to the integrated log
    : >> "${TOTAL_LOG}"
    TOTAL_ON="Y" ; TOTAL_DEST="${TOTAL_LOG}"
    RUN_LOG="${LOGFILE}" ; COORD_PID=$$     # kept by the table sub shells (_slot_run)

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
# _check_objects : are the control tables / dictionary view readable ? -> OBJ_WARN (empty = all OK)
#   one statement each, errors do not stop the check ; warning only, nothing is blocked
_check_objects() {
    local _o _tag _miss="" _err
    OBJ_WARN=""
    {
        _sql_head | sed 's/^WHENEVER SQLERROR .*/WHENEVER SQLERROR CONTINUE/'
        echo "SELECT 'CHK|MSTR|'    || COUNT(*) FROM ${MSTR_TAB} WHERE ROWNUM = 1;"
        echo "SELECT 'CHK|COL_MAP|' || COUNT(*) FROM ${MAP_TAB} WHERE ROWNUM = 1;"
        echo "SELECT 'CHK|XDN_LOG|' || COUNT(*) FROM ${LOG_TAB} WHERE ROWNUM = 1;"
        echo "SELECT 'CHK|DICT|'    || COUNT(*) FROM ALL_TAB_COLUMNS WHERE ROWNUM = 1;"
        echo "EXIT;"
    } > ${TMP_SQL}
    _run_sql ${TMP_SQL}

    if ! grep -q '^CHK|' ${TMP_OUT} ; then
        _err=$(_db_errors | head -1)
        OBJ_WARN="control table check failed : ${_err:-no output from ${DB_CLIENT}}"
        return 1
    fi
    for _o in "MSTR:${MSTR_TAB}" "COL_MAP:${MAP_TAB} (needed for TRANS_YN=Y)" "XDN_LOG:${LOG_TAB}" "DICT:ALL_TAB_COLUMNS (needed for TRANS_YN=Y)" ; do
        _tag="${_o%%:*}"
        grep -q "^CHK|${_tag}|" ${TMP_OUT} || _miss="${_miss:+${_miss}, }${_o#*:}"
    done
    [[ -n "${_miss}" ]] && OBJ_WARN="not found or no privilege : ${_miss}"
    return 0
}

# _menu_status_line : dashboard at the top of the menus
#   RUNNING : progress, WORKER / PARALLEL / DB load, one line per worker slot (table, PARALLEL, elapsed)
_menu_status_line() {
    local _d _t _sc _fc _rc _wc _kc _pct _s _sf _num _tot _tbl _t0 _par _busy
    if _lock_read ; then
        if [[ "${W_STATE}" == "RUNNING" ]] ; then
            _d="" ; _t="" ; _sc="" ; _fc="" ; _rc="" ; _wc="" ; _kc=""
            [[ -f "${STATE_FILE}" ]] && IFS='|' read -r _d _t _sc _fc _rc _wc _kc < "${STATE_FILE}"
            _pct="" ; [[ "${_t}" =~ ^[1-9][0-9]*$ && "${_d}" =~ ^[0-9]+$ ]] && _pct=" ($(( _d * 100 / _t ))%)"
            printf " * RUNNING : %s %s  RUN_ID=%s  done %s/%s%s  PID=%s  since %s\n" \
                   "${L_ACTION}" "${L_PHASE}" "${L_RUN_ID}" "${_d:-0}" "${_t:-?}" "${_pct}" "${L_PID}" "${L_START}"
            _busy=$(ls "${SLOT_PREFIX}"* 2>/dev/null | wc -l | tr -d ' ')
            printf "   WORKER %s (busy %s) x PARALLEL %s = DB load max %s    SUCCESS=%s  FAIL=%s  SKIP=%s  WAIT=%s\n" \
                   "${WORKER_DEGREE}" "${_busy}" "${PARALLEL_DEGREE}" "$(( WORKER_DEGREE * PARALLEL_DEGREE ))" "${_sc:-0}" "${_fc:-0}" "${_kc:-0}" "${_wc:-?}"
            _s=1
            while [[ ${_s} -le ${WORKER_DEGREE} || -f "${SLOT_PREFIX}${_s}" ]] ; do
                _sf="${SLOT_PREFIX}${_s}"
                if [[ -f "${_sf}" ]] && IFS='|' read -r _num _tot _tbl _t0 _par < "${_sf}" && [[ "${_t0}" =~ ^[0-9]+$ ]] ; then
                    printf "   [W%s] [%*s/%s] %-44s P%-3s %s\n" "${_s}" "${#_tot}" "${_num}" "${_tot}" "${_tbl}" "${_par}" "$(_fmt_sec $(( $(date +%s) - _t0 )))"
                elif [[ ${_s} -le ${WORKER_DEGREE} ]] ; then
                    printf "   [W%s] (idle)\n" "${_s}"
                fi
                _s=$(( _s + 1 ))
                [[ ${_s} -gt 99 ]] && break
            done
            [[ -f "${STOP_FILE}" ]] && printf "   stop    : requested (no new table ; running tables finish)\n"
            [[ -n "${W_NOTE}" ]] && printf "   warning : %s\n" "${W_NOTE}"
        else
            printf " * STALE   : lock %s %s  RUN_ID=%s  PID=%s  since %s : worker process not found\n" \
                   "${L_ACTION}" "${L_PHASE}" "${L_RUN_ID}" "${L_PID}" "${L_START}"
            printf "   check [s] Status and the DB session, then [U] Unlock\n"
        fi
    else
        printf " * IDLE    : no background migration    (WORKER %s x PARALLEL %s = DB load max %s)\n" \
               "${WORKER_DEGREE}" "${PARALLEL_DEGREE}" "$(( WORKER_DEGREE * PARALLEL_DEGREE ))"
    fi
}

# _run_menu : [R] Run sub menu ; one action then back to the main menu ([b] = back without action)
#   key without Enter, screen cleared on every draw, result kept until a key is pressed
#   returns 1 when stdin is closed (main menu ends too)
_run_menu() {
    local _msg=""
    while true ; do
        _clear
        {
            printf "%s\n" "$SEP"
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
            [[ -n "${_msg}" ]] && printf "%s\n" "${_msg}"
        } | _paint_menu
        printf "Select: "
        _key || return 1
        _msg=""

        case "${KEY}" in
            1)   _busy_phase PRE  || _generate PRE ;;
            2)   _busy            || _menu_run PRE ;;
            3)   _busy            || _menu_retry PRE ;;
            4)   _busy_phase DDAY || _generate DDAY ;;
            5)   _busy            || _menu_run DDAY ;;
            6)   _busy            || _menu_retry DDAY ;;
            b|B) return 0 ;;
            "")  continue ;;
            *)   _msg="[FAIL] Invalid selection: ${KEY}" ; continue ;;
        esac
        _pause || return 1
        return 0
    done
}

echo "Checking control tables ..."
_check_objects

MENU_MSG=""
while true ; do
    LOGFILE="/dev/null"
    _hint_load
    _clear
    {
        printf "%s\n" "$SEP"
        printf " DATA MIGRATION   MSTR_ID=%s  DB_TYPE=%s  SRC_DBLINK=%s  SQL_REFRESH=%s\n" "${MSTR_ID}" "${DB_TYPE}" "${SRC_DBLINK}" "${SQL_REFRESH}"
        printf "%s\n" "$DASH"
        _menu_status_line
        [[ -n "${OBJ_WARN}" ]] && printf " ! CHECK   : %s  (checked at menu start)\n" "${OBJ_WARN}"
        printf "%s\n" "$SEP"
        printf "  [R] Run         (SQL generate / migration / retry)\n"
        printf "  [l] Total Log   (tail -F, q + Enter to return)\n"
        printf "  [s] Status      (%s)\n" "${LOG_TAB}"
        printf "  [S] Stop        (no new table ; running tables finish)\n"
        printf "  [h] Hint        (WORKER %s x PARALLEL %s : %s)\n" "${WORKER_DEGREE}" "${PARALLEL_DEGREE}" "$(_hint_text)"
        printf "  [U] Unlock      (stale lock / interrupted RUNNING rows, only when no worker)\n"
        printf "  [q] Quit        (background migration keeps running)\n"
        printf "%s\n" "$SEP"
        [[ -n "${MENU_MSG}" ]] && printf "%s\n" "${MENU_MSG}"
    } | _paint_menu
    printf "Select: "
    _key || break
    MENU_MSG=""

    case "${KEY}" in
        r|R) _run_menu || break ;;
        l|L) _view_log || _pause || break ;;
        s)   _status | _paint ; _pause || break ;;
        S)   _stop ; _pause || break ;;
        h|H) _hint_setting ; _pause || break ;;
        u|U) _unlock ; _pause || break ;;
        q|Q) break ;;
        "")  ;;
        *)   MENU_MSG="[FAIL] Invalid selection: ${KEY}" ;;
    esac
done
echo

if _lock_read && [[ "${W_STATE}" == "RUNNING" ]] ; then
    _say "[OK]   Menu closed. ${L_ACTION} ${L_PHASE} RUN_ID=${L_RUN_ID} keeps running in background (PID=${L_PID})"
    echo "       view : bash $(basename "${SCRIPT_PATH}") --tail"
fi
exit 0
