#!/bin/bash
# ============================================================
# 01.UNLOAD_PG.sh
# Unload PostgreSQL data to a comma separated CSV file on this server.
#   - pick one extract SQL from ./sql/*.sql with the Up / Down keys
#   - COPY (<SQL>) TO STDOUT WITH (FORMAT csv, HEADER) -> ${BASE_PATH}/csv/<SQL_NAME>.csv
#     (client side file : no file privilege needed on the PG server)
#   - 1st CSV line = column aliases of the SQL (= target column names, used by 02.LOAD_TARGET.sh)
#   - the SQL is run as it is : WHERE condition / date format are written in the SQL file
#   - PG account / password are typed in at start (not kept in P2O.env)
# Usage: 01.UNLOAD_PG.sh
# ============================================================

# --- Load environment variables ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [[ -f "${SCRIPT_DIR}/P2O.env" ]] ; then
    . ${SCRIPT_DIR}/P2O.env
else
    echo "[FAIL] P2O.env file not found: ${SCRIPT_DIR}/P2O.env"
    exit 1
fi

if ! command -v psql > /dev/null 2>&1 ; then
    echo "[FAIL] psql not found in PATH. Install the PostgreSQL client first."
    exit 1
fi

for V in PG_HOST PG_PORT PG_DB ; do
    if [[ -z "${!V}" ]] ; then
        echo "[FAIL] ${V} is empty in P2O.env"
        exit 1
    fi
done

SEP="============================================================"

# BASE_PATH (P2O.env, default = script directory) : ${BASE_PATH}/csv , /log , /tmp
BASE_PATH="${BASE_PATH:-${SCRIPT_DIR}}"
SQL_DIR="${SCRIPT_DIR}/sql"
CSV_DIR="${BASE_PATH}/csv"
mkdir -p "${CSV_DIR}" "${BASE_PATH}/log" "${BASE_PATH}/tmp"

TMP_PREFIX="${BASE_PATH}/tmp/UNLOAD_PG"
TMP_QUERY="${TMP_PREFIX}_QUERY_$$.sql"
TMP_COPY="${TMP_PREFIX}_COPY_$$.sql"
TMP_ERR="${TMP_PREFIX}_ERR_$$.txt"
# written next to the final CSV so that the last mv is a rename on the same filesystem
TMP_PART="${CSV_DIR}/.UNLOAD_PG_$$.part"

# --- Log File ---
LOGFILE="${BASE_PATH}/log/UNLOAD_PG_$(date '+%Y%m%d_%H%M%S').log"

# _out: Print to terminal and append to log file
_out() {
    printf "$@"
    printf "$@" >> ${LOGFILE}
}

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

_cleanup() {
    rm -f ${TMP_QUERY} ${TMP_COPY} ${TMP_ERR} ${TMP_PART}
    printf '\033[?25h'
}
trap _cleanup EXIT

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

# _ask_login <LABEL> : read account and password (password not echoed) until not empty
#   -> LOGIN_USER / LOGIN_PASS ; return 1 = cancelled (EOF)
_ask_login() {
    while true ; do
        read -r -p "$1 user     : " LOGIN_USER || { echo ; return 1 ; }
        LOGIN_USER=$(echo "${LOGIN_USER}" | tr -d '[:space:]')
        [[ -n "${LOGIN_USER}" ]] && break
        echo "  -> empty. Try again."
    done
    while true ; do
        IFS= read -r -s -p "$1 password : " LOGIN_PASS || { echo ; return 1 ; }
        echo
        [[ -n "${LOGIN_PASS}" ]] && break
        echo "  -> empty. Try again."
    done
    return 0
}

# ============================================================
# 0. Source login
# ============================================================
_out "%s\n" "$SEP"
_log "Source login : ${PG_HOST}:${PG_PORT}/${PG_DB}"
_out "%s\n" "$SEP"

_ask_login "PG" || { _log "Cancelled." ; exit 0 ; }
PG_USER="${LOGIN_USER}"
PG_PASS="${LOGIN_PASS}"

PGPASSWORD="${PG_PASS}" \
psql -X -q -t -v ON_ERROR_STOP=1 \
     -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" \
     -c "SELECT 1" > /dev/null 2> ${TMP_ERR}
if [[ $? -ne 0 ]] ; then
    _out "%s\n" "$(cat ${TMP_ERR})"
    _fail "Cannot connect to PostgreSQL as ${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB}"
    exit 1
fi
_ok "Connected : ${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB}"

# ============================================================
# 1. Select extract SQL
# ============================================================
SQL_LIST=()
for F in "${SQL_DIR}"/*.sql ; do
    [[ -f "${F}" ]] && SQL_LIST+=("$(basename "${F}")")
done

if [[ ${#SQL_LIST[@]} -eq 0 ]] ; then
    _fail "No SQL file in ${SQL_DIR} (*.sql)"
    exit 1
fi

_out "%s\n" "$SEP"
_log "Select extract SQL : ${SQL_DIR}"
_out "%s\n" "$SEP"

if ! _select_menu "Extract SQL files (${#SQL_LIST[@]})" "${SQL_LIST[@]}" ; then
    _log "Cancelled."
    exit 0
fi

SQL_NAME="${MENU_VAL}"
SQL_FILE="${SQL_DIR}/${SQL_NAME}"
CSV_FILE="${CSV_DIR}/${SQL_NAME%.sql}.csv"
_log "Selected : ${SQL_NAME}"

# ============================================================
# 2. Build COPY SQL
# ============================================================
# strip UTF-8 BOM and CR, then trailing blanks / semicolons (the SQL goes inside COPY ( ... ))
sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "${SQL_FILE}" \
  | sed -e ':a' -e '$!{N;ba}' -e 's/[[:space:];]*$//' > ${TMP_QUERY}

FIRST_WORD=$(sed -e 's/--.*$//' ${TMP_QUERY} | awk 'NF { print toupper($1) ; exit }')
case "${FIRST_WORD}" in
    SELECT*|WITH*) ;;
    *)
        _fail "SQL must start with SELECT or WITH (found: '${FIRST_WORD}') : ${SQL_FILE}"
        exit 1
        ;;
esac

{
    echo "COPY ("
    cat ${TMP_QUERY}
    echo ""
    echo ") TO STDOUT WITH (FORMAT csv, HEADER true, DELIMITER ',', QUOTE '\"', NULL '');"
} > ${TMP_COPY}

_out "\n"
_out "  Source  : %s@%s:%s/%s\n" "${PG_USER}" "${PG_HOST}" "${PG_PORT}" "${PG_DB}"
_out "  SQL     : %s\n" "${SQL_FILE}"
_out "  CSV     : %s\n" "${CSV_FILE}"
_out "\n"
_out "%s\n" "--- SQL preview (first 30 lines) ---"
_out "%s\n" "$(head -n 30 ${TMP_QUERY})"
if [[ $(wc -l < ${TMP_QUERY}) -ge 30 ]] ; then
    _out "%s\n" "..."
fi
_out "%s\n" "------------------------------------"
_out "\n"

if [[ -f "${CSV_FILE}" ]] ; then
    read -r -p "CSV file already exists. Overwrite? (y/N): " ANSWER
    if [[ "${ANSWER}" != "y" && "${ANSWER}" != "Y" ]] ; then
        _log "Cancelled. (existing CSV kept)"
        exit 0
    fi
else
    read -r -p "Unload to CSV? (y/N): " ANSWER
    if [[ "${ANSWER}" != "y" && "${ANSWER}" != "Y" ]] ; then
        _log "Cancelled."
        exit 0
    fi
fi

# ============================================================
# 3. Unload
# ============================================================
_out "%s\n" "$SEP"
_log "Unload start"
_out "%s\n" "$SEP"

START_TS=$(date '+%s')

PGPASSWORD="${PG_PASS}" PGCLIENTENCODING=UTF8 \
psql -X -q -v ON_ERROR_STOP=1 \
     -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" \
     -f ${TMP_COPY} > ${TMP_PART} 2> ${TMP_ERR}
RC=$?

if [[ ${RC} -ne 0 || -s ${TMP_ERR} ]] ; then
    _out "%s\n" "$(cat ${TMP_ERR})"
fi

if [[ ${RC} -ne 0 ]] ; then
    _fail "psql failed (rc=${RC}). CSV not created : ${CSV_FILE}"
    exit 1
fi

if [[ ! -s ${TMP_PART} ]] ; then
    _fail "psql returned no output (not even a header line). CSV not created : ${CSV_FILE}"
    exit 1
fi

mv -f ${TMP_PART} "${CSV_FILE}"
if [[ $? -ne 0 ]] ; then
    _fail "Cannot write CSV file : ${CSV_FILE}"
    exit 1
fi

# record count : a line ends a record only when the double quotes are balanced
# (a quoted value may contain line breaks, so wc -l is not a row count)
REC_CNT=$(awk '{ q += gsub(/"/, "&") ; if (q % 2 == 0) r++ } END { print r + 0 }' "${CSV_FILE}")
ROW_CNT=$(( REC_CNT > 0 ? REC_CNT - 1 : 0 ))
ELAPSED=$(( $(date '+%s') - START_TS ))

_out "\n"
_out "  Rows    : %s (header line excluded)\n" "${ROW_CNT}"
_out "  Size    : %s bytes\n" "$(wc -c < "${CSV_FILE}" | tr -d ' ')"
_out "  Elapsed : %s sec\n" "${ELAPSED}"
_out "  CSV     : %s\n" "${CSV_FILE}"
_out "  Log     : %s\n" "${LOGFILE}"
_out "\n"
_ok "Unload finished : ${SQL_NAME}"
exit 0
