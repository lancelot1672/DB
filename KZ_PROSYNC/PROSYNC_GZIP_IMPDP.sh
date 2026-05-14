if [[ -z "$1" ]] ; then
  echo "Not File.list"
  exit 0
fi

# --- Load environment variables ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [[ -f "${SCRIPT_DIR}/.env" ]] ; then
    . ${SCRIPT_DIR}/.env
else
    echo "[FAIL] .env file not found: ${SCRIPT_DIR}/.env"
    exit 1
fi

export BASE_PATH="/imsi/PUMP"
export FILE_LIST="${BASE_PATH}/lst/$1.lst"
export DB_DIR=$2
export TAR_DIR="${BASE_PATH}/$1"
export DUMP_DIR="${BASE_PATH}/$2"
export COMPLETE_DIR="${BASE_PATH}/mig_comp"

SEP="============================================================"
SUB="------------------------------------------------------------"

# --- Log file ---
LOGFILE="${BASE_PATH}/log/PROSYNC_GZIP_IMPDP_${1}_$(date '+%Y%m%d_%H%M%S').log"

_out() {
    printf "$@"
    printf "$@" >> ${LOGFILE}
}

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_step() { _out "\n%s\n  >> STEP %s\n%s\n" "$SUB" "$*" "$SUB"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

_elapsed() {
    _e_val=$(expr $2 - $1)
    _e_h=$(expr $_e_val / 3600)
    _e_m=$(expr $_e_val % 3600 / 60)
    _e_s=$(expr $_e_val % 60)
    printf "%02d:%02d:%02d" $_e_h $_e_m $_e_s
}

_cnt=0
_success=0
_failed=0
_fail_list=""
_total=$(egrep -vc "^$|^#" ${FILE_LIST})
_total_start=$(date '+%s')

_out "%s\n" "Start: $(date '+%Y-%m-%d %H:%M:%S')  LIST: ${FILE_LIST}  (Total: ${_total})"

egrep -v "^$|^#" ${FILE_LIST} |
while read owner table rest
do

_cnt=$(expr $_cnt + 1)
_tbl_start=$(date '+%s')

_out "\n%s\n  [%s/%s] %s.%s\n%s\n" "$SEP" "$_cnt" "$_total" "$owner" "$table" "$SEP"

# --- 1. GZIP Decompress ---
_step "1/3  GZIP Decompress"
_log "gzip -d ${TAR_DIR}/${owner}.${table}_*.dat.gz"
_s1=$(date '+%s')
gzip -d ${TAR_DIR}/${owner}.${table}_*.dat.gz
_e1=$(date '+%s')
_log "Elapsed: $(_elapsed $_s1 $_e1)"

# --- 2. Move dump file ---
_step "2/3  Move Dump File"
_log "mv ${TAR_DIR}/${owner}.${table}_*.dat -> ${DUMP_DIR}"
_s2=$(date '+%s')
mv ${TAR_DIR}/${owner}.${table}_*.dat ${DUMP_DIR}
_e2=$(date '+%s')
_log "Elapsed: $(_elapsed $_s2 $_e2)"

# --- 3. Import Data Pump ---
_step "3/3  IMPDP (Data Only)"
_log "impdp directory=${DB_DIR} dumpfile=${owner}.${table}_%U.dat logfile=imp_${owner}.${table}.log"
_s3=$(date '+%s')
impdp ${DB_USER}/${DB_PASS} directory=${DB_DIR} dumpfile=${owner}.${table}_%U.dat logfile=imp_${owner}.${table}.log content=data_only
_RESULT=$?
_e3=$(date '+%s')
_log "Elapsed: $(_elapsed $_s3 $_e3)"

_tbl_end=$(date '+%s')

if [[ ${_RESULT} -eq 0 ]] ; then
    _ok "IMPDP SUCCESS -- ${owner}.${table}  (Total: $(_elapsed $_tbl_start $_tbl_end))"
    _log "mv ${DUMP_DIR}/${owner}.${table}_*.dat -> ${COMPLETE_DIR}"
    mv ${DUMP_DIR}/${owner}.${table}_*.dat ${COMPLETE_DIR}
    _success=$(expr $_success + 1)
else
    _fail "IMPDP FAILED (rc=${_RESULT}) -- ${owner}.${table}  (Total: $(_elapsed $_tbl_start $_tbl_end))"
    _failed=$(expr $_failed + 1)
    if [[ -z "$_fail_list" ]] ; then
        _fail_list="${owner}.${table}"
    else
        _fail_list="${_fail_list}, ${owner}.${table}"
    fi
fi

done

_total_end=$(date '+%s')

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

exit