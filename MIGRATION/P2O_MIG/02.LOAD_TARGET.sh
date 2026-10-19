#!/bin/bash
# ============================================================
# 02.LOAD_TARGET.sh
# Load a CSV file made by 01.UNLOAD_PG.sh into one Oracle / Tibero table.
#   - pick one CSV from ${BASE_PATH}/csv/*.csv with the Up / Down keys
#   - target OWNER / TABLE_NAME are typed in (source and target names differ)
#   - 1st CSV line (column names) -> loader control file, matched by name with ALL_TAB_COLUMNS
#   - DATE / TIMESTAMP target columns : fixed masks (DATE_MASK / TS_MASK below)
#   - loader by TARGET_DBMS in P2O.env (ORACLE = sqlplus + sqlldr, TIBERO = tbsql + tbloader)
#   - no validation in shell : rejected rows go to the loader bad file
# Usage: 02.LOAD_TARGET.sh
# ============================================================

# --- Load environment variables ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [[ -f "${SCRIPT_DIR}/P2O.env" ]] ; then
    . ${SCRIPT_DIR}/P2O.env
else
    echo "[FAIL] P2O.env file not found: ${SCRIPT_DIR}/P2O.env"
    exit 1
fi

case "${TARGET_DBMS}" in
    ORACLE) DB_CLIENT="sqlplus" ; LOADER="sqlldr"   ; CHARSET="${CHARSET:-AL32UTF8}" ;;
    TIBERO) DB_CLIENT="tbsql"   ; LOADER="tbloader" ; CHARSET="${CHARSET:-UTF8}" ;;
    *)      echo "[FAIL] TARGET_DBMS must be ORACLE or TIBERO in P2O.env (current: '${TARGET_DBMS}')" ; exit 1 ;;
esac

for C in ${DB_CLIENT} ${LOADER} ; do
    if ! command -v ${C} > /dev/null 2>&1 ; then
        echo "[FAIL] ${C} not found in PATH (TARGET_DBMS=${TARGET_DBMS}). Install the ${TARGET_DBMS} client first."
        exit 1
    fi
done

LOAD_MODE="${LOAD_MODE:-APPEND}"
case "${LOAD_MODE}" in
    APPEND|TRUNCATE) ;;
    *) echo "[FAIL] LOAD_MODE must be APPEND or TRUNCATE in P2O.env (current: '${LOAD_MODE}')" ; exit 1 ;;
esac

DIRECT="${DIRECT:-N}"
LOAD_ERRORS="${LOAD_ERRORS:-50}"

DB_CONN="${DB_USER}/${DB_PASS}${DB_TNS:+@${DB_TNS}}"

# masks of the date strings in the CSV (keep in sync with the to_char() rule in README.md)
DATE_MASK="YYYYMMDDHH24MISS"
TS_MASK="YYYYMMDDHH24MISSFF6"

SEP="============================================================"

# BASE_PATH (P2O.env, default = script directory) : ${BASE_PATH}/csv , /ctl , /bad , /log , /tmp
BASE_PATH="${BASE_PATH:-${SCRIPT_DIR}}"
CSV_DIR="${BASE_PATH}/csv"
mkdir -p "${CSV_DIR}" "${BASE_PATH}/ctl" "${BASE_PATH}/bad" "${BASE_PATH}/log" "${BASE_PATH}/tmp"

TMP_PREFIX="${BASE_PATH}/tmp/LOAD_TARGET"
TMP_SQL="${TMP_PREFIX}_SQL_$$.sql"
TMP_OUT="${TMP_PREFIX}_OUT_$$.txt"
TMP_COLS="${TMP_PREFIX}_COLS_$$.txt"
TMP_FIELDS="${TMP_PREFIX}_FIELDS_$$.txt"
TMP_MAP="${TMP_PREFIX}_MAP_$$.txt"

# --- Log File ---
RUN_TS=$(date '+%Y%m%d_%H%M%S')
LOGFILE="${BASE_PATH}/log/LOAD_TARGET_${RUN_TS}.log"

# _out: Print to terminal and append to log file
_out() {
    printf "$@"
    printf "$@" >> ${LOGFILE}
}

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

_cleanup() {
    rm -f ${TMP_SQL} ${TMP_OUT} ${TMP_COLS} ${TMP_FIELDS} ${TMP_MAP}
    printf '\033[?25h'
}
trap _cleanup EXIT

# _run_sql <SQL_FILE> : run with the client for TARGET_DBMS (stdout + stderr)
_run_sql() {
    ${DB_CLIENT} -s "${DB_CONN}" @"$1" < /dev/null 2>&1
}

# _has_db_error <OUTPUT_FILE> : Oracle / Tibero / SQL*Plus error code in output
_has_db_error() {
    grep -Eq '(ORA|TBR|SP2)-[0-9]+' "$1"
}

# _count_target : print COUNT(*) of the target table (empty on error)
_count_target() {
    {
        echo "SET HEADING OFF"
        echo "SET FEEDBACK OFF"
        echo "SET PAGESIZE 0"
        echo "SELECT 'CNT|' || COUNT(*) FROM ${TGT_OWNER}.${TGT_TABLE};"
        echo "EXIT"
    } > ${TMP_SQL}
    _run_sql ${TMP_SQL} > ${TMP_OUT}
    _has_db_error ${TMP_OUT} && return 1
    sed -n 's/^[[:space:]]*CNT|\([0-9][0-9]*\)[[:space:]]*$/\1/p' ${TMP_OUT} | head -n 1
}

# _select_menu <TITLE> <ITEM>... : Up / Down (k / j) move, Enter select, q cancel
#   selected item -> MENU_VAL ; return 1 = cancelled
_select_menu() {
    local title="$1" ; shift
    local -a items=("$@")
    local n=${#items[@]} cur=0 top=0 rows i key rest drawn=0

    # visible rows : the list scrolls when it is longer than the terminal
    rows=$(( $(tput lines 2>/dev/null || echo 24) - 6 ))
    (( rows < 5 )) && rows=5
    (( rows > n )) && rows=$n

    printf "%s\n" "${title}"
    printf "  (Up/Down or k/j : move , Enter : select , q : cancel)\n"
    printf '\033[?25l'
    while true ; do
        (( cur < top )) && top=$cur
        (( cur >= top + rows )) && top=$(( cur - rows + 1 ))
        (( drawn )) && printf '\033[%dA' "$(( rows + 1 ))"
        for (( i = top ; i < top + rows ; i++ )) ; do
            if (( i == cur )) ; then
                printf '\r\033[K \033[7m> %s\033[0m\n' "${items[i]}"
            else
                printf '\r\033[K   %s\n' "${items[i]}"
            fi
        done
        printf '\r\033[K  [%d/%d]\n' "$(( cur + 1 ))" "$n"
        drawn=1

        IFS= read -rsn1 key || { printf '\033[?25h' ; return 1 ; }
        if [[ "${key}" == $'\033' ]] ; then
            rest=""
            read -rsn2 -t 0.1 rest
            key="${key}${rest}"
        fi
        case "${key}" in
            $'\033[A'|$'\033OA'|k) (( cur > 0 )) && cur=$(( cur - 1 )) ;;
            $'\033[B'|$'\033OB'|j) (( cur < n - 1 )) && cur=$(( cur + 1 )) ;;
            "")                    break ;;
            q|Q|$'\033')           printf '\033[?25h' ; return 1 ;;
        esac
    done
    printf '\033[?25h'
    MENU_VAL="${items[cur]}"
    return 0
}

# _ask_name <PROMPT> : read an identifier until it is valid, upper-cased -> ASK_VAL
_ask_name() {
    while true ; do
        read -r -p "$1" ASK_VAL || return 1
        ASK_VAL=$(echo "${ASK_VAL}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
        if [[ "${ASK_VAL}" =~ ^[A-Z][A-Z0-9_\$#]*$ ]] ; then
            return 0
        fi
        echo "  -> letters, digits, _ \$ # only, starting with a letter. Try again."
    done
}

# ============================================================
# 1. Select CSV file
# ============================================================
CSV_LIST=()
for F in "${CSV_DIR}"/*.csv ; do
    [[ -f "${F}" ]] && CSV_LIST+=("$(basename "${F}")")
done

if [[ ${#CSV_LIST[@]} -eq 0 ]] ; then
    _fail "No CSV file in ${CSV_DIR} (run 01.UNLOAD_PG.sh first)"
    exit 1
fi

_out "%s\n" "$SEP"
_log "Select CSV file : ${CSV_DIR} (TARGET_DBMS=${TARGET_DBMS})"
_out "%s\n" "$SEP"

if ! _select_menu "CSV files (${#CSV_LIST[@]})" "${CSV_LIST[@]}" ; then
    _log "Cancelled."
    exit 0
fi

CSV_NAME="${MENU_VAL}"
CSV_FILE="${CSV_DIR}/${CSV_NAME}"
_log "Selected : ${CSV_NAME}"

# ============================================================
# 2. Target table
# ============================================================
_out "\n"
_ask_name "Target OWNER      : " || { _log "Cancelled." ; exit 0 ; }
TGT_OWNER="${ASK_VAL}"
_ask_name "Target TABLE_NAME : " || { _log "Cancelled." ; exit 0 ; }
TGT_TABLE="${ASK_VAL}"
_log "Target : ${TGT_OWNER}.${TGT_TABLE}"

{
    echo "SET HEADING OFF"
    echo "SET FEEDBACK OFF"
    echo "SET PAGESIZE 0"
    echo "SET LINESIZE 32767"
    echo "SELECT COLUMN_NAME || '|' || DATA_TYPE || '|' || DATA_LENGTH"
    echo "  FROM ALL_TAB_COLUMNS"
    echo " WHERE OWNER = '${TGT_OWNER}'"
    echo "   AND TABLE_NAME = '${TGT_TABLE}'"
    echo " ORDER BY COLUMN_ID;"
    echo "EXIT"
} > ${TMP_SQL}

_run_sql ${TMP_SQL} > ${TMP_OUT}
if [[ $? -ne 0 ]] || _has_db_error ${TMP_OUT} ; then
    _out "%s\n" "$(cat ${TMP_OUT})"
    _fail "Cannot read the columns of ${TGT_OWNER}.${TGT_TABLE}"
    exit 1
fi

# keep only NAME|TYPE|LENGTH lines, trimmed
sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' ${TMP_OUT} \
  | grep -E '^[^|]+\|[^|]+\|[0-9]+$' > ${TMP_COLS}

if [[ ! -s ${TMP_COLS} ]] ; then
    _fail "Table not found (or no privilege) : ${TGT_OWNER}.${TGT_TABLE}"
    exit 1
fi

# ============================================================
# 3. Build control file
# ============================================================
HEADER=$(head -n 1 "${CSV_FILE}" | sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/"//g')
IFS=',' read -r -a HDR_COLS <<< "${HEADER}"

if [[ ${#HDR_COLS[@]} -eq 0 ]] ; then
    _fail "CSV file has no header line : ${CSV_FILE}"
    exit 1
fi

MISSING=""
UNSUPPORTED=""
: > ${TMP_FIELDS}
: > ${TMP_MAP}
N_COL=${#HDR_COLS[@]}
for (( i = 0 ; i < N_COL ; i++ )) ; do
    COL=$(echo "${HDR_COLS[i]}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    INFO=$(awk -F'|' -v c="${COL}" '$1 == c { print $2 "|" $3 ; exit }' ${TMP_COLS})
    if [[ -z "${INFO}" ]] ; then
        MISSING="${MISSING} ${COL}"
        continue
    fi
    DTYPE="${INFO%%|*}"
    DLEN="${INFO##*|}"

    case "${DTYPE}" in
        DATE)
            SPEC=" DATE \"${DATE_MASK}\"" ;;
        TIMESTAMP*)
            SPEC=" TIMESTAMP \"${TS_MASK}\"" ;;
        CLOB|NCLOB|BLOB|BFILE|LONG*|RAW|XMLTYPE)
            UNSUPPORTED="${UNSUPPORTED} ${COL}(${DTYPE})"
            continue ;;
        *CHAR*)
            # sqlldr reads a field as CHAR(255) unless a length is given ; tbloader sizes it from the table
            if [[ "${TARGET_DBMS}" == "ORACLE" ]] ; then
                (( DLEN < 4000 )) && DLEN=4000
                SPEC=" CHAR(${DLEN})"
            else
                SPEC=""
            fi ;;
        *)
            SPEC="" ;;
    esac

    if (( i < N_COL - 1 )) ; then
        echo "  ${COL}${SPEC}," >> ${TMP_FIELDS}
    else
        echo "  ${COL}${SPEC}" >> ${TMP_FIELDS}
    fi
    printf "    %-30s <- CSV #%-3s %s\n" "${COL}" "$(( i + 1 ))" "${DTYPE}" >> ${TMP_MAP}
done

if [[ -n "${MISSING}" ]] ; then
    _fail "CSV header columns not in ${TGT_OWNER}.${TGT_TABLE} :${MISSING}"
    _out "       (column alias in the extract SQL must be the target column name)\n"
    exit 1
fi

if [[ -n "${UNSUPPORTED}" ]] ; then
    _fail "Column type not supported by this script :${UNSUPPORTED}"
    exit 1
fi

LOAD_NAME="${TGT_OWNER}.${TGT_TABLE}_${RUN_TS}"
CTL_FILE="${BASE_PATH}/ctl/${LOAD_NAME}.ctl"
BAD_FILE="${BASE_PATH}/bad/${LOAD_NAME}.bad"
LDR_LOG="${BASE_PATH}/log/${LOAD_NAME}_${LOADER}.log"

{
    echo "LOAD DATA"
    echo "CHARACTERSET ${CHARSET}"
    echo "INFILE '${CSV_FILE}'"
    echo "${LOAD_MODE}"
    echo "INTO TABLE ${TGT_OWNER}.${TGT_TABLE}"
    echo "FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '\"'"
    echo "TRAILING NULLCOLS"
    # header line : tbloader skips it in the control file, sqlldr by skip=1 on the command line
    [[ "${TARGET_DBMS}" == "TIBERO" ]] && echo "IGNORE 1 LINES"
    echo "("
    cat ${TMP_FIELDS}
    echo ")"
} > "${CTL_FILE}"

# ============================================================
# 4. Preview / confirm
# ============================================================
# record count : a line ends a record only when the double quotes are balanced
REC_CNT=$(awk '{ q += gsub(/"/, "&") ; if (q % 2 == 0) r++ } END { print r + 0 }' "${CSV_FILE}")
CSV_ROWS=$(( REC_CNT > 0 ? REC_CNT - 1 : 0 ))

CNT_BEFORE=$(_count_target)
if [[ -z "${CNT_BEFORE}" ]] ; then
    _out "%s\n" "$(cat ${TMP_OUT})"
    _fail "Cannot count ${TGT_OWNER}.${TGT_TABLE}"
    exit 1
fi

_out "\n"
_out "%s\n" "$SEP"
_out "  Target DBMS  : %s (%s)\n" "${TARGET_DBMS}" "${LOADER}"
_out "  Target table : %s.%s\n" "${TGT_OWNER}" "${TGT_TABLE}"
_out "  CSV file     : %s\n" "${CSV_FILE}"
_out "  CSV rows     : %s\n" "${CSV_ROWS}"
_out "  Current rows : %s\n" "${CNT_BEFORE}"
_out "  Load mode    : %s (direct=%s, errors=%s)\n" "${LOAD_MODE}" "${DIRECT}" "${LOAD_ERRORS}"
_out "  Control file : %s\n" "${CTL_FILE}"
_out "  Column mapping (%s of %s table columns) :\n" "${N_COL}" "$(wc -l < ${TMP_COLS} | tr -d ' ')"
_out "%s\n" "$(cat ${TMP_MAP})"
_out "%s\n" "$SEP"

if [[ "${LOAD_MODE}" == "TRUNCATE" ]] ; then
    _out "  !!! TRUNCATE mode : the %s existing rows of %s.%s are deleted and can not be recovered.\n" \
         "${CNT_BEFORE}" "${TGT_OWNER}" "${TGT_TABLE}"
fi

read -r -p "Load into ${TGT_OWNER}.${TGT_TABLE}? (y/N): " ANSWER
if [[ "${ANSWER}" != "y" && "${ANSWER}" != "Y" ]] ; then
    _log "Cancelled. (control file kept : ${CTL_FILE})"
    exit 0
fi

# ============================================================
# 5. Load
# ============================================================
_out "%s\n" "$SEP"
_log "Load start : ${LOADER}"
_out "%s\n" "$SEP"

START_TS=$(date '+%s')

if [[ "${TARGET_DBMS}" == "ORACLE" ]] ; then
    [[ "${DIRECT}" == "Y" ]] && DIRECT_OPT="true" || DIRECT_OPT="false"
    sqlldr userid="${DB_CONN}" control="${CTL_FILE}" log="${LDR_LOG}" bad="${BAD_FILE}" \
           skip=1 errors=${LOAD_ERRORS} direct=${DIRECT_OPT} silent=header,feedback 2>&1 | tee -a ${LOGFILE}
    RC=${PIPESTATUS[0]}
else
    tbloader userid="${DB_CONN}" control="${CTL_FILE}" log="${LDR_LOG}" bad="${BAD_FILE}" \
             errors=${LOAD_ERRORS} direct=${DIRECT} 2>&1 | tee -a ${LOGFILE}
    RC=${PIPESTATUS[0]}
fi

ELAPSED=$(( $(date '+%s') - START_TS ))

# ============================================================
# 6. Result
# ============================================================
CNT_AFTER=$(_count_target)

if [[ "${LOAD_MODE}" == "TRUNCATE" ]] ; then
    EXPECT_CNT="${CSV_ROWS}"
else
    EXPECT_CNT=$(( CNT_BEFORE + CSV_ROWS ))
fi

BAD_ROWS=0
if [[ -s "${BAD_FILE}" ]] ; then
    BAD_ROWS=$(awk '{ q += gsub(/"/, "&") ; if (q % 2 == 0) r++ } END { print r + 0 }' "${BAD_FILE}")
fi

_out "\n"
_out "%s\n" "$SEP"
_out "  Loader rc    : %s\n" "${RC}"
_out "  CSV rows     : %s\n" "${CSV_ROWS}"
_out "  Rows before  : %s\n" "${CNT_BEFORE}"
_out "  Rows after   : %s (expected %s)\n" "${CNT_AFTER:-?}" "${EXPECT_CNT}"
_out "  Bad rows     : %s\n" "${BAD_ROWS}"
[[ -s "${BAD_FILE}" ]] && _out "  Bad file     : %s\n" "${BAD_FILE}"
_out "  Loader log   : %s\n" "${LDR_LOG}"
_out "  Elapsed      : %s sec\n" "${ELAPSED}"
_out "  Log          : %s\n" "${LOGFILE}"
_out "%s\n" "$SEP"

if [[ -z "${CNT_AFTER}" ]] ; then
    _fail "Cannot count ${TGT_OWNER}.${TGT_TABLE} after the load. Check the loader log."
    exit 1
fi

if [[ "${CNT_AFTER}" == "${EXPECT_CNT}" && ${BAD_ROWS} -eq 0 ]] ; then
    _ok "Load finished : ${CSV_NAME} -> ${TGT_OWNER}.${TGT_TABLE} (${CSV_ROWS} rows)"
    exit 0
fi

_fail "Row count mismatch or rejected rows (loader rc=${RC}). Check the loader log / bad file."
exit 1
