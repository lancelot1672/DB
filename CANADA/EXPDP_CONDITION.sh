#!/bin/bash
# ============================================================
# EXPDP_CONDITION.sh
# EXPDP based on DBADM.MIG_TAB_LIST (dynamic WHERE clause)
# Usage: EXPDP_CONDITION.sh <DB_DIR>
# ============================================================

if [[ -z "$1" ]] ; then
  echo "Usage: EXPDP_CONDITION.sh <DB_DIR>"
  echo "  DB_DIR : Oracle DIRECTORY object name"
  exit 1
fi

# --- Load environment variables ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [[ -f "${SCRIPT_DIR}/.env" ]] ; then
    . ${SCRIPT_DIR}/.env
else
    echo "[FAIL] .env file not found: ${SCRIPT_DIR}/.env"
    exit 1
fi

export DB_DIR=$1
export DUMP_DIR="${BASE_PATH}/$1"
export TMP_LIST="${BASE_PATH}/tmp/EXPDP_CONDITION_$$.dat"

SEP="============================================================"
SUB="------------------------------------------------------------"

# --- Log File ---
LOGFILE="${BASE_PATH}/log/EXPDP_CONDITION_$(date '+%Y%m%d_%H%M%S').log"

# _out: Print to terminal and append to log file
_out() {
    printf "$@"
    printf "$@" >> ${LOGFILE}
}

# _log:     Print message with timestamp [HH:MM:SS]
# _step:    Print step header with separator lines
# _ok:      Print success message with [OK] prefix
# _fail:    Print failure message with [FAIL] prefix
_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_step() { _out "\n%s\n  >> STEP %s\n%s\n" "$SUB" "$*" "$SUB"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

# _elapsed: Calculate elapsed time between two epoch seconds
#           Args: $1=start_epoch  $2=end_epoch
#           Returns: HH:MM:SS format
_elapsed() {
    _e_val=$(expr $2 - $1)
    _e_h=$(expr $_e_val / 3600)
    _e_m=$(expr $_e_val % 3600 / 60)
    _e_s=$(expr $_e_val % 60)
    printf "%02d:%02d:%02d" $_e_h $_e_m $_e_s
}

# ============================================================
# 1. Query MIG_TAB_LIST via sqlplus -> generate temp file
# ============================================================
sqlplus -s ${DB_USER}/${DB_PASS} <<EOF > ${TMP_LIST}
SET HEAD OFF FEED OFF PAGES 0 LINES 300 TRIM ON
SET TRIMSPOOL ON
SELECT OWNER || ',' ||
       TABLE_NAME || ',' ||
       NVL(WHERE_COL1, 'NONE') || ',' ||
       NVL(PRE1, 'NONE') || ',' ||
       NVL(WHERE_COL2, 'NONE') || ',' ||
       NVL(PRE2, 'NONE')
  FROM DBADM.MIG_TAB_LIST
 ORDER BY OWNER, TABLE_NAME;
EOF

if [[ $? -ne 0 ]] ; then
    _fail "sqlplus failed. check connection."
    exit 1
fi

# Remove empty lines
egrep -v "^$" ${TMP_LIST} > ${TMP_LIST}.tmp
mv ${TMP_LIST}.tmp ${TMP_LIST}

_total=$(cat ${TMP_LIST} | wc -l | tr -d ' ')
if [[ ${_total} -eq 0 ]] ; then
    _fail "No rows in DBADM.MIG_TAB_LIST"
    rm -f ${TMP_LIST}
    exit 1
fi

# ============================================================
# 2. Display target list and confirm
# ============================================================
printf "\n%s\n" "$SEP"
printf "  EXPDP Target List (Total: %s)  DIR: %s\n" "$_total" "$DB_DIR"
printf "%s\n\n" "$SEP"
printf "  %-4s %-15s %-15s %s\n" "No" "OWNER" "TABLE_NAME" "WHERE CONDITION"
printf "  %-4s %-15s %-15s %s\n" "----" "---------------" "---------------" "------------------------------"

_n=0
while IFS=',' read _o _t _w1 _p1 _w2 _p2
do
    _n=$(expr $_n + 1)
    if [ "$_w1" != "NONE" ] && [ "$_w2" != "NONE" ] ; then
        _cond="WHERE ${_w1} >= '${_p1}' AND ${_w2} < '${_p2}'"
    elif [ "$_w1" != "NONE" ] ; then
        _cond="WHERE ${_w1} >= '${_p1}'"
    else
        _cond="(full export)"
    fi
    printf "  %-4s %-15s %-15s %s\n" "$_n" "$_o" "$_t" "$_cond"
done < ${TMP_LIST}

printf "\n%s\n" "$SEP"
printf "  Proceed with EXPDP? (Y/N) : "
read _confirm
if [[ "$_confirm" != "Y" ]] && [[ "$_confirm" != "y" ]] ; then
    echo "  Cancelled."
    rm -f ${TMP_LIST}
    exit 0
fi
printf "%s\n\n" "$SEP"

_cnt=0
_success=0
_failed=0
_fail_list=""
_total_start=$(date '+%s')

_out "%s\n" "Start: $(date '+%Y-%m-%d %H:%M:%S')  DIR: ${DB_DIR}  (Total: ${_total})"

# ============================================================
# 3. Loop processing
# ============================================================
while IFS=',' read owner table wcol1 pre1 wcol2 pre2
do

_cnt=$(expr $_cnt + 1)
_tbl_start=$(date '+%s')

_out "\n%s\n  [%s/%s] %s.%s\n%s\n" "$SEP" "$_cnt" "$_total" "$owner" "$table" "$SEP"

# --- STEP 1/2 : Query Build ---
_step "1/2  Query Build"

QUERY_PARAM=""
if [ "$wcol1" != "NONE" ] && [ "$wcol2" != "NONE" ] ; then
    QUERY_PARAM="QUERY=${owner}.${table}:\"WHERE ${wcol1} >= '${pre1}' AND ${wcol2} < '${pre2}'\""
    _log "WHERE ${wcol1} >= '${pre1}' AND ${wcol2} < '${pre2}'"
elif [ "$wcol1" != "NONE" ] ; then
    QUERY_PARAM="QUERY=${owner}.${table}:\"WHERE ${wcol1} >= '${pre1}'\""
    _log "WHERE ${wcol1} >= '${pre1}'"
else
    _log "No WHERE condition (full export)"
fi

# --- STEP 2/2 : EXPDP ---
_step "2/2  EXPDP"

if [ -z "${QUERY_PARAM}" ] ; then
    _log "expdp directory=${DB_DIR} tables=${owner}.${table} dumpfile=${owner}.${table}_%U.dat"
    _s2=$(date '+%s')
    expdp ${DB_USER}/${DB_PASS} \
        directory=${DB_DIR} \
        dumpfile=${owner}.${table}_%U.dat \
        logfile=exp_${owner}.${table}.log \
        tables=${owner}.${table} \
        content=DATA_ONLY
else
    _log "expdp directory=${DB_DIR} tables=${owner}.${table} dumpfile=${owner}.${table}_%U.dat ${QUERY_PARAM}"
    _s2=$(date '+%s')
    expdp ${DB_USER}/${DB_PASS} \
        directory=${DB_DIR} \
        dumpfile=${owner}.${table}_%U.dat \
        logfile=exp_${owner}.${table}.log \
        tables=${owner}.${table} \
        content=DATA_ONLY \
        ${QUERY_PARAM}
fi

_RESULT=$?
_e2=$(date '+%s')
_log "Elapsed: $(_elapsed $_s2 $_e2)"

_tbl_end=$(date '+%s')

if [[ ${_RESULT} -eq 0 ]] ; then
    _ok "EXPDP SUCCESS -- ${owner}.${table}  (Total: $(_elapsed $_tbl_start $_tbl_end))"
    _success=$(expr $_success + 1)
else
    _fail "EXPDP FAILED (rc=${_RESULT}) -- ${owner}.${table}  (Total: $(_elapsed $_tbl_start $_tbl_end))"
    _failed=$(expr $_failed + 1)
    if [[ -z "$_fail_list" ]] ; then
        _fail_list="${owner}.${table}"
    else
        _fail_list="${_fail_list}, ${owner}.${table}"
    fi
fi

done < ${TMP_LIST}

_total_end=$(date '+%s')

# ============================================================
# 4. SUMMARY
# ============================================================
_out "\n\n%s\n" "$SEP"
_out "  SUMMARY\n"
_out "%s\n\n" "$SEP"
_out "  Total Elapsed : %s\n" "$(_elapsed $_total_start $_total_end)"
_out "  Total Tables  : %s\n" "$_cnt"
_out "  Success       : %s\n" "$_success"
_out "  Failed        : %s\n" "$_failed"
if [[ $_failed -gt 0 ]] ; then
    _out "  Failed Tables : %s\n" "$_fail_list"
fi
_out "\n%s\n" "$SEP"

_log "Log saved: ${LOGFILE}"

# Remove temp file
rm -f ${TMP_LIST}

exit