#!/bin/bash
# ============================================================
# 00.P2O_MENU.sh
# P2O_MIG : PostgreSQL -> Oracle / Tibero data migration, one shell with a menu (Up / Down + Enter).
#
#   Menu
#     1. Source settings  : PG_HOST / PG_PORT / PG_DB / PG_ENV_FILE (P2O.env), PG_HOME (env file), connection test
#     2. Target settings  : TARGET_DBMS / DB_TNS / *_ENV_FILE (P2O.env), ORACLE_HOME / TB_HOME, NLS, connection test
#     3. Load options     : BASE_PATH / LOAD_MODE / DIRECT / LOAD_ERRORS / CHARSET / chunk rows
#     4. Unload module    : ./sql/*.sql -> psql COPY TO STDOUT -> ${BASE_PATH}/csv
#     5. Load module      : ${BASE_PATH}/csv -> sqlldr / tbloader -> target table
#     6. Outputs          : CSV files / chunk directories / logs
#
#   Modules (_unload_run / _load_run) run in a subshell : an exit ends the module only, and the
#   client environment it sources (PG_HOME / ORACLE_HOME ...) does not stay in the menu.
#   Settings are written back to P2O.env / env/*.env in place (KEY=VALUE line replaced, comments kept).
#   Account / password are always typed in, never saved, never put on a command line (except tbloader).
#
# Usage: 00.P2O_MENU.sh            menu
#        00.P2O_MENU.sh unload     run the unload module only
#        00.P2O_MENU.sh load       run the load module only
# ============================================================

# --- Load environment variables ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="${SCRIPT_DIR}/P2O.env"
if [[ ! -f "${ENV_FILE}" ]] ; then
    echo "[FAIL] P2O.env file not found: ${ENV_FILE}"
    if [[ ! -f "${ENV_FILE}.example" ]] ; then
        exit 1
    fi
    read -r -p "Create it from P2O.env.example? (y/N): " ANSWER
    if [[ "${ANSWER}" != "y" && "${ANSWER}" != "Y" ]] ; then
        exit 1
    fi
    cp "${ENV_FILE}.example" "${ENV_FILE}" || exit 1
    echo "[OK]   created : ${ENV_FILE}"
fi
. ${ENV_FILE}

SEP="============================================================"
LINE="------------------------------------------------------------"

# masks of the date strings in the CSV (keep in sync with the to_char() rule in README.md)
DATE_MASK="YYYYMMDDHH24MISS"
TS_MASK="YYYYMMDDHH24MISSFF6"

# BASE_PATH (P2O.env, default = script directory) : ${BASE_PATH}/csv , /ctl , /bad , /log , /tmp
BASE_PATH="${BASE_PATH:-${SCRIPT_DIR}}"
mkdir -p "${BASE_PATH}/log" "${BASE_PATH}/tmp"

TMP_ENV="${BASE_PATH}/tmp/P2O_MENU_ENV_$$.txt"

# --- Log File --- (a module switches LOGFILE to its own log inside its subshell)
LOGFILE="${BASE_PATH}/log/P2O_MENU_$(date '+%Y%m%d_%H%M%S').log"

# _out: Print to terminal and append to log file
_out() {
    printf "$@"
    printf "$@" >> ${LOGFILE}
}

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

_cleanup() {
    rm -f ${TMP_ENV}
    printf '\033[?25h'
}
trap _cleanup EXIT
# Ctrl+C stops a running module (its subshell) and comes back to the menu
trap ':' INT

_clear() { clear 2>/dev/null || printf '\033[2J\033[H' ; }
_pause() { echo ; read -r -p "Press Enter to return..." _ ; }

# ============================================================
# Common : input
# ============================================================
# _select_menu <TITLE> <ITEM>... : Up / Down (k / j) move, Enter select, q cancel
#   selected item -> MENU_VAL , its index -> MENU_IDX ; return 1 = cancelled
_select_menu() {
    local title="$1" ; shift
    local -a items=("$@")
    local n=${#items[@]} cur=0 top=0 rows i key rest drawn=0

    # visible rows : the list scrolls when it is longer than the terminal
    rows=$(( $(tput lines 2>/dev/null || echo 24) - 6 ))
    (( rows < 5 )) && rows=5
    (( rows > n )) && rows=$n

    printf "%s\n" "${title}"
    printf "  (Up/Down or k/j : move , Enter : select , q : back)\n"
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
    MENU_IDX=${cur}
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
# Common : settings files
# ============================================================
# _env_get <FILE> <KEY> : raw value of the first "KEY=" / "export KEY=" line (empty when missing)
#   a trailing CR (file edited on Windows) is not part of the value
_env_get() {
    [[ -f "$1" ]] || return 0
    awk -v k="$2" '
        { line = $0 ; sub(/\r$/, "", line) ; sub(/^[[:space:]]*/, "", line) ; sub(/^export[[:space:]]+/, "", line) }
        index(line, k "=") == 1 { print substr(line, length(k) + 2) ; exit }' "$1"
}

# _env_set <FILE> <KEY> <VALUE> <PREFIX> : replace the first KEY= line (its "export " kept),
#   append "<PREFIX>KEY=VALUE" when missing. Comments and other lines are kept as they are.
#   (cat > file keeps the owner / mode of the file)
_env_set() {
    P2O_VAL="$3" awk -v k="$2" -v pre="$4" '
        BEGIN { v = ENVIRON["P2O_VAL"] }
        !done {
            line = $0 ; lead = ""
            if (match(line, /^[[:space:]]*(export[[:space:]]+)?/) && RLENGTH > 0) {
                lead = substr(line, 1, RLENGTH) ; line = substr(line, RLENGTH + 1)
            }
            # keep the line ending of the file (CR of a CRLF line)
            if (index(line, k "=") == 1) { print lead k "=" v (line ~ /\r$/ ? "\r" : "") ; done = 1 ; next }
        }
        { print }
        END { if (!done) print pre k "=" v }' "$1" > ${TMP_ENV} || return 1
    cat ${TMP_ENV} > "$1"
}

# _abs_path <PATH> : relative = from the script directory
_abs_path() {
    if [[ "$1" == /* ]] ; then echo "$1" ; else echo "${SCRIPT_DIR}/$1" ; fi
}

# _client_env <ENV_FILE_KEY> : absolute path of the client env file named in P2O.env (empty = not set)
_client_env() {
    local f
    f=$(_env_get "${ENV_FILE}" "$1")
    [[ -n "${f}" ]] && _abs_path "${f}"
}

# ============================================================
# Common : CSV
# ============================================================
# _rec_count <FILE>... : CSV records of all files, header lines included
#   a line ends a record only when the double quotes are balanced
#   (a quoted value may contain line breaks, so wc -l is not a row count)
_rec_count() {
    awk 'FNR == 1 { q = 0 } { q += gsub(/"/, "&") ; if (q % 2 == 0) r++ } END { print r + 0 }' "$@"
}

# _rows_per_file <FILE>... : data rows (header excluded) of each file, one line per file
_rows_per_file() {
    local f
    for f in "$@" ; do
        echo $(( $(_rec_count "${f}") - 1 ))
    done
}

# _split_csv <CHUNK_ROWS> <OUT_DIR> <NAME> : CSV on stdin -> <OUT_DIR>/<NAME>_00001.csv , _00002.csv ...
#   1st line = header, written at the top of every chunk ; a record is never cut in two
#   prints one progress line per finished chunk (header only input -> one chunk with 0 rows)
_split_csv() {
    awk -v n="$1" -v dir="$2" -v name="$3" '
        function finish() {
            if (f == "") return
            close(f)
            printf "  chunk %05d : %d rows (total %d)\n", idx, crows, total
            fflush()
        }
        NR == 1 { hdr = $0 ; next }
        {
            if (!inrec && (f == "" || crows >= n)) {
                finish()
                idx++ ; crows = 0
                f = sprintf("%s/%s_%05d.csv", dir, name, idx)
                print hdr > f
            }
            if (!inrec) { crows++ ; total++ }
            print > f
            q += gsub(/"/, "&")
            if (q % 2 == 0) { inrec = 0 ; q = 0 } else { inrec = 1 }
        }
        END {
            if (NR >= 1 && f == "") {
                idx = 1 ; f = sprintf("%s/%s_%05d.csv", dir, name, idx)
                print hdr > f
            }
            finish()
        }'
}

# ============================================================
# Common : clients and login (P2O.env must be sourced ; call in a subshell, the env files change PATH)
# ============================================================
# _load_pg_client : source PG_ENV_FILE (PG_HOME / PATH / LD_LIBRARY_PATH) and check psql ; return 1 = not usable
_load_pg_client() {
    local f
    if [[ -n "${PG_ENV_FILE}" ]] ; then
        f=$(_abs_path "${PG_ENV_FILE}")
        if [[ ! -f "${f}" ]] ; then
            _fail "PG_ENV_FILE not found: ${f} (cp env/PG.env.example env/PG.env , or menu 1)"
            return 1
        fi
        . "${f}"
    fi
    if ! command -v psql > /dev/null 2>&1 ; then
        _fail "psql not found in PATH. Install the PostgreSQL client and check PG_ENV_FILE (${PG_ENV_FILE:-not set})."
        return 1
    fi
    return 0
}

# _pg_login : PG account / password typed in and checked by a connection -> PG_USER / PG_PASS
#   return 1 = cancelled , 2 = connection failed (message printed)
_pg_login() {
    local out
    _ask_login "PG" || return 1
    PG_USER="${LOGIN_USER}"
    PG_PASS="${LOGIN_PASS}"

    out=$(PGPASSWORD="${PG_PASS}" \
          psql -X -q -t -A -v ON_ERROR_STOP=1 \
               -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" \
               -c "SELECT version()" 2>&1)
    if [[ $? -ne 0 ]] ; then
        _out "%s\n" "${out}"
        _fail "Cannot connect to PostgreSQL as ${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB}"
        return 2
    fi
    _ok "Connected : ${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB} ($(echo "${out}" | head -n 1 | cut -c 1-50))"
    return 0
}

# _load_tgt_client : by TARGET_DBMS set DB_CLIENT / DB_NOLOG / LOADER / CHARSET default,
#   source ORACLE_ENV_FILE or TIBERO_ENV_FILE and check the client + loader ; return 1 = not usable
#   DB_NOLOG : start the client without login (CONNECT is sent on stdin, see _run_sql)
_load_tgt_client() {
    local key f c
    case "${TARGET_DBMS}" in
        ORACLE) DB_CLIENT="sqlplus" ; DB_NOLOG="/nolog" ; LOADER="sqlldr"   ; CHARSET="${CHARSET:-AL32UTF8}" ; key="ORACLE_ENV_FILE" ;;
        TIBERO) DB_CLIENT="tbsql"   ; DB_NOLOG=""       ; LOADER="tbloader" ; CHARSET="${CHARSET:-UTF8}"     ; key="TIBERO_ENV_FILE" ;;
        *)      _fail "TARGET_DBMS must be ORACLE or TIBERO in P2O.env (current: '${TARGET_DBMS}')" ; return 1 ;;
    esac
    if [[ -n "${!key}" ]] ; then
        f=$(_abs_path "${!key}")
        if [[ ! -f "${f}" ]] ; then
            _fail "${key} not found: ${f} (cp env/${TARGET_DBMS}.env.example env/${TARGET_DBMS}.env , or menu 2)"
            return 1
        fi
        . "${f}"
    fi
    for c in ${DB_CLIENT} ${LOADER} ; do
        if ! command -v ${c} > /dev/null 2>&1 ; then
            _fail "${c} not found in PATH (TARGET_DBMS=${TARGET_DBMS}). Install the ${TARGET_DBMS} client and check ${key} (${!key:-not set})."
            return 1
        fi
    done
    return 0
}

# _run_sql [SQL_FILE] : run SQL (file, or stdin) with the client for TARGET_DBMS (stdout + stderr)
#   the password is not put on the command line (visible in ps) : CONNECT goes on stdin
#   (echo is a shell builtin), and an echoed CONNECT line is dropped from the output
_run_sql() {
    { echo "CONNECT ${DB_CONN}" ; cat "${1:--}" ; } \
      | ${DB_CLIENT} -s ${DB_NOLOG} 2>&1 \
      | P2O_PW="${DB_PASS}" awk '!(toupper($0) ~ /CONN/ && index($0, ENVIRON["P2O_PW"]))'
    return ${PIPESTATUS[1]}
}

# _has_db_error <OUTPUT_FILE> : Oracle / Tibero / SQL*Plus / tbSQL error code in output
_has_db_error() {
    grep -Eq '(ORA|TBR|TBS|SP2)-[0-9]+' "$1"
}

# _tgt_login : target account / password typed in and checked by a connection -> DB_USER / DB_PASS / DB_CONN
#   return 1 = cancelled , 2 = connection failed (message printed)
_tgt_login() {
    local out rc
    _ask_login "${TARGET_DBMS}" || return 1
    DB_USER="${LOGIN_USER}"
    DB_PASS="${LOGIN_PASS}"
    DB_CONN="${DB_USER}/${DB_PASS}${DB_TNS:+@${DB_TNS}}"

    out=$(printf '%s\n' "SET HEADING OFF" "SET FEEDBACK OFF" "SET PAGESIZE 0" \
                        "SELECT 'LOGIN|OK' FROM DUAL;" "EXIT" | _run_sql)
    rc=$?
    if [[ ${rc} -ne 0 ]] || grep -Eq '(ORA|TBR|TBS|SP2)-[0-9]+' <<< "${out}" || ! grep -q 'LOGIN|OK' <<< "${out}" ; then
        _out "%s\n" "${out}"
        _fail "Cannot connect to ${TARGET_DBMS} as ${DB_USER}${DB_TNS:+@${DB_TNS}}"
        return 2
    fi
    _ok "Connected : ${DB_USER}${DB_TNS:+@${DB_TNS}}"
    return 0
}

# ============================================================
# Module : unload  (PostgreSQL -> CSV)
#   - pick one extract SQL from ./sql/*.sql with the Up / Down keys
#   - COPY (<SQL>) TO STDOUT WITH (FORMAT csv, HEADER) -> ${BASE_PATH}/csv/<SQL_NAME>.csv
#     (client side file : no file privilege needed on the PG server)
#   - 1st CSV line = column aliases of the SQL (= target column names, used by the load module)
#   - the SQL is run as it is : WHERE condition / date format are written in the SQL file
#   - UNLOAD_CHUNK_ROWS > 0 : the one COPY stream is split into chunk files
#       ${BASE_PATH}/csv/<SQL_NAME>/<SQL_NAME>_00001.csv ...  (each with the header line)
#   - run in a subshell (_run_module) : exit ends the module only
# ============================================================
_unload_cleanup() {
    rm -f ${TMP_QUERY} ${TMP_COPY} ${TMP_ERR} ${TMP_PART}
    rm -rf "${TMP_PART_DIR}"
    printf '\033[?25h'
}

_unload_run() {
    # settings may have been changed in the menu : read them again
    . ${ENV_FILE}

    # BASE_PATH (P2O.env, default = script directory) : ${BASE_PATH}/csv , /log , /tmp
    BASE_PATH="${BASE_PATH:-${SCRIPT_DIR}}"
    SQL_DIR="${SCRIPT_DIR}/sql"
    CSV_DIR="${BASE_PATH}/csv"
    mkdir -p "${CSV_DIR}" "${BASE_PATH}/log" "${BASE_PATH}/tmp"

    LOGFILE="${BASE_PATH}/log/UNLOAD_PG_$(date '+%Y%m%d_%H%M%S').log"

    TMP_PREFIX="${BASE_PATH}/tmp/UNLOAD_PG"
    TMP_QUERY="${TMP_PREFIX}_QUERY_$$.sql"
    TMP_COPY="${TMP_PREFIX}_COPY_$$.sql"
    TMP_ERR="${TMP_PREFIX}_ERR_$$.txt"
    # written next to the final CSV so that the last mv is a rename on the same filesystem
    TMP_PART="${CSV_DIR}/.UNLOAD_PG_$$.part"
    TMP_PART_DIR="${CSV_DIR}/.UNLOAD_PG_$$.partdir"

    trap _unload_cleanup EXIT
    trap 'exit 130' INT TERM

    _load_pg_client || exit 1

    for V in PG_HOST PG_PORT PG_DB ; do
        if [[ -z "${!V}" ]] ; then
            _fail "${V} is empty in P2O.env"
            exit 1
        fi
    done

    # rows per chunk file : 0 / empty = one CSV file
    UNLOAD_CHUNK_ROWS="${UNLOAD_CHUNK_ROWS:-0}"
    if [[ ! "${UNLOAD_CHUNK_ROWS}" =~ ^[0-9]+$ ]] ; then
        _fail "UNLOAD_CHUNK_ROWS must be a number (0 = no split) in P2O.env (current: '${UNLOAD_CHUNK_ROWS}')"
        exit 1
    fi

    # ============================================================
    # 0. Source login
    # ============================================================
    _out "%s\n" "$SEP"
    _log "Source login : ${PG_HOST}:${PG_PORT}/${PG_DB}"
    _out "%s\n" "$SEP"

    _pg_login
    case $? in
        1) _log "Cancelled." ; exit 0 ;;
        2) exit 1 ;;
    esac

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
    OUT_NAME="${SQL_NAME%.sql}"
    CSV_FILE="${CSV_DIR}/${OUT_NAME}.csv"
    CHUNK_DIR="${CSV_DIR}/${OUT_NAME}"
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
    if (( UNLOAD_CHUNK_ROWS > 0 )) ; then
        _out "  CSV     : %s/%s_NNNNN.csv (%s rows per chunk)\n" "${CHUNK_DIR}" "${OUT_NAME}" "${UNLOAD_CHUNK_ROWS}"
    else
        _out "  CSV     : %s\n" "${CSV_FILE}"
    fi
    _out "\n"
    _out "%s\n" "--- SQL preview (first 30 lines) ---"
    _out "%s\n" "$(head -n 30 ${TMP_QUERY})"
    if [[ $(wc -l < ${TMP_QUERY}) -ge 30 ]] ; then
        _out "%s\n" "..."
    fi
    _out "%s\n" "------------------------------------"
    _out "\n"

    # an earlier output of this SQL (single CSV or chunk directory) is replaced on success
    if [[ -f "${CSV_FILE}" || -d "${CHUNK_DIR}" ]] ; then
        [[ -f "${CSV_FILE}" ]] && _out "  existing : %s\n" "${CSV_FILE}"
        [[ -d "${CHUNK_DIR}" ]] && _out "  existing : %s/ (%s files)\n" "${CHUNK_DIR}" "$(ls "${CHUNK_DIR}" | wc -l | tr -d ' ')"
        read -r -p "CSV output already exists. Overwrite? (y/N): " ANSWER
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

    # output is written to a hidden .part file / directory next to the final one, then renamed
    if (( UNLOAD_CHUNK_ROWS > 0 )) ; then
        mkdir -p "${TMP_PART_DIR}"
        PGPASSWORD="${PG_PASS}" PGCLIENTENCODING=UTF8 \
        psql -X -q -v ON_ERROR_STOP=1 \
             -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" \
             -f ${TMP_COPY} 2> ${TMP_ERR} \
          | _split_csv "${UNLOAD_CHUNK_ROWS}" "${TMP_PART_DIR}" "${OUT_NAME}" | tee -a ${LOGFILE}
        RC=${PIPESTATUS[0]}
        SPLIT_RC=${PIPESTATUS[1]}
    else
        PGPASSWORD="${PG_PASS}" PGCLIENTENCODING=UTF8 \
        psql -X -q -v ON_ERROR_STOP=1 \
             -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" \
             -f ${TMP_COPY} > ${TMP_PART} 2> ${TMP_ERR}
        RC=$?
        SPLIT_RC=0
    fi

    if [[ ${RC} -ne 0 || -s ${TMP_ERR} ]] ; then
        _out "%s\n" "$(cat ${TMP_ERR})"
    fi

    if [[ ${RC} -ne 0 ]] ; then
        _fail "psql failed (rc=${RC}). CSV not created."
        exit 1
    fi

    if [[ ${SPLIT_RC} -ne 0 ]] ; then
        _fail "Chunk split failed (awk rc=${SPLIT_RC}, disk full?). CSV not created."
        exit 1
    fi

    if (( UNLOAD_CHUNK_ROWS > 0 )) ; then
        OUT_FILES=( "${TMP_PART_DIR}"/*.csv )
        [[ -f "${OUT_FILES[0]}" ]] || OUT_FILES=()
    else
        OUT_FILES=()
        [[ -s ${TMP_PART} ]] && OUT_FILES=( "${TMP_PART}" )
    fi

    if [[ ${#OUT_FILES[@]} -eq 0 ]] ; then
        _fail "psql returned no output (not even a header line). CSV not created."
        exit 1
    fi

    # counted before the rename (the .part names are still valid)
    REC_CNT=$(_rec_count "${OUT_FILES[@]}")
    ROW_CNT=$(( REC_CNT - ${#OUT_FILES[@]} ))
    (( ROW_CNT < 0 )) && ROW_CNT=0
    SIZE=$(cat "${OUT_FILES[@]}" | wc -c | tr -d ' ')

    # replace the earlier output of this SQL (single CSV and / or chunk directory)
    rm -f "${CSV_FILE}"
    rm -rf "${CHUNK_DIR}"
    if (( UNLOAD_CHUNK_ROWS > 0 )) ; then
        OUT_PATH="${CHUNK_DIR}/ (${#OUT_FILES[@]} chunk files)"
        mv -f "${TMP_PART_DIR}" "${CHUNK_DIR}"
    else
        OUT_PATH="${CSV_FILE}"
        mv -f ${TMP_PART} "${CSV_FILE}"
    fi
    if [[ $? -ne 0 ]] ; then
        _fail "Cannot write CSV output : ${OUT_PATH}"
        exit 1
    fi

    ELAPSED=$(( $(date '+%s') - START_TS ))

    _out "\n"
    _out "  Rows    : %s (header lines excluded)\n" "${ROW_CNT}"
    _out "  Size    : %s bytes\n" "${SIZE}"
    _out "  Elapsed : %s sec\n" "${ELAPSED}"
    _out "  CSV     : %s\n" "${OUT_PATH}"
    _out "  Log     : %s\n" "${LOGFILE}"
    _out "\n"
    _ok "Unload finished : ${SQL_NAME}"
    exit 0
}

# ============================================================
# Module : load  (CSV -> Oracle / Tibero)
#   - pick one CSV ${BASE_PATH}/csv/*.csv or one chunk directory csv/<NAME>/ (unload with UNLOAD_CHUNK_ROWS)
#   - target OWNER / TABLE_NAME are typed in (source and target names differ)
#   - 1st CSV line (column names) -> loader control file, matched by name with ALL_TAB_COLUMNS
#   - DATE / TIMESTAMP target columns : fixed masks (DATE_MASK / TS_MASK)
#   - loader by TARGET_DBMS in P2O.env (ORACLE = sqlplus + sqlldr, TIBERO = tbsql + tbloader)
#   - chunk load : the chunk files are loaded one by one (one loader run each) and checked after each;
#       a single CSV is split first when LOAD_CHUNK_ROWS > 0 (P2O.env).
#       on a failed chunk the run stops ; rerun and type that chunk number to resume
#   - no validation in shell : rejected rows go to the loader bad file
#   - result : loaded / rejected rows from the loader log + COUNT(*) before / after
#   - run in a subshell (_run_module) : exit ends the module only
# ============================================================
_load_cleanup() {
    rm -f ${TMP_SQL} ${TMP_OUT} ${TMP_COLS} ${TMP_FIELDS} ${TMP_MAP} ${TMP_PAR}
    rm -rf "${TMP_CHUNK_DIR}"
    printf '\033[?25h'
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

# _ldr_count <ERE> : first number in the first loader log match of ERE (empty = not found)
_ldr_count() {
    [[ -f "${LDR_LOG}" ]] || return 0
    grep -Eio "$1" "${LDR_LOG}" | head -n 1 | grep -Eo '[0-9]+' | head -n 1
}

# _write_ctl <MODE> <CTL_FILE> : loader control file (no INFILE : the chunk file is given by data=)
_write_ctl() {
    {
        echo "LOAD DATA"
        echo "CHARACTERSET ${CHARSET}"
        echo "$1"
        echo "INTO TABLE ${TGT_OWNER}.${TGT_TABLE}"
        echo "FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '\"'"
        echo "TRAILING NULLCOLS"
        # header line of every chunk : tbloader skips it in the control file, sqlldr by skip=1
        [[ "${TARGET_DBMS}" == "TIBERO" ]] && echo "IGNORE 1 LINES"
        echo "("
        cat ${TMP_FIELDS}
        echo ")"
    } > "$2"
}

# _run_loader <CTL> <DATA> <LOG> <BAD> : one loader run, output to terminal + log -> loader rc
_run_loader() {
    local rc
    if [[ "${TARGET_DBMS}" == "ORACLE" ]] ; then
        [[ "${DIRECT}" == "Y" ]] && DIRECT_OPT="true" || DIRECT_OPT="false"
        # userid in a parfile, not on the command line (visible in ps)
        ( umask 077 ; echo "userid=${DB_CONN}" > ${TMP_PAR} )
        sqlldr parfile="${TMP_PAR}" control="$1" data="$2" log="$3" bad="$4" \
               skip=1 errors=${LOAD_ERRORS} direct=${DIRECT_OPT} ${LOAD_COMMIT_ROWS:+rows=${LOAD_COMMIT_ROWS}} \
               silent=header,feedback 2>&1 | tee -a ${LOGFILE}
        rc=${PIPESTATUS[0]}
        rm -f ${TMP_PAR}
    else
        # tbloader takes userid on the command line only (no parfile) : the password is visible in ps while it runs
        tbloader userid="${DB_CONN}" control="$1" data="$2" log="$3" bad="$4" \
                 errors=${LOAD_ERRORS} direct=${DIRECT} ${LOAD_COMMIT_ROWS:+rows=${LOAD_COMMIT_ROWS}} \
                 2>&1 | tee -a ${LOGFILE}
        rc=${PIPESTATUS[0]}
    fi
    return ${rc}
}

_load_run() {
    # settings may have been changed in the menu : read them again
    . ${ENV_FILE}

    # BASE_PATH (P2O.env, default = script directory) : ${BASE_PATH}/csv , /ctl , /bad , /log , /tmp
    BASE_PATH="${BASE_PATH:-${SCRIPT_DIR}}"
    CSV_DIR="${BASE_PATH}/csv"
    mkdir -p "${CSV_DIR}" "${BASE_PATH}/ctl" "${BASE_PATH}/bad" "${BASE_PATH}/log" "${BASE_PATH}/tmp"

    RUN_TS=$(date '+%Y%m%d_%H%M%S')
    LOGFILE="${BASE_PATH}/log/LOAD_TARGET_${RUN_TS}.log"

    TMP_PREFIX="${BASE_PATH}/tmp/LOAD_TARGET"
    TMP_SQL="${TMP_PREFIX}_SQL_$$.sql"
    TMP_OUT="${TMP_PREFIX}_OUT_$$.txt"
    TMP_COLS="${TMP_PREFIX}_COLS_$$.txt"
    TMP_FIELDS="${TMP_PREFIX}_FIELDS_$$.txt"
    TMP_MAP="${TMP_PREFIX}_MAP_$$.txt"
    # sqlldr parfile holding userid (mode 600, removed right after each load and in _load_cleanup)
    TMP_PAR="${TMP_PREFIX}_PAR_$$.par"
    # chunks of a single CSV split by LOAD_CHUNK_ROWS (same file + same LOAD_CHUNK_ROWS = same chunks on rerun)
    TMP_CHUNK_DIR="${TMP_PREFIX}_CHUNK_$$"

    trap _load_cleanup EXIT
    trap 'exit 130' INT TERM

    _load_tgt_client || exit 1

    LOAD_MODE="${LOAD_MODE:-APPEND}"
    case "${LOAD_MODE}" in
        APPEND|TRUNCATE) ;;
        *) _fail "LOAD_MODE must be APPEND or TRUNCATE in P2O.env (current: '${LOAD_MODE}')" ; exit 1 ;;
    esac

    DIRECT="${DIRECT:-N}"
    LOAD_ERRORS="${LOAD_ERRORS:-50}"

    # LOAD_CHUNK_ROWS : split a single CSV into chunks of this many rows (0 / empty = load it in one run)
    # LOAD_COMMIT_ROWS : loader rows= (rows per commit / data save) , empty = loader default
    LOAD_CHUNK_ROWS="${LOAD_CHUNK_ROWS:-0}"
    if [[ ! "${LOAD_CHUNK_ROWS}" =~ ^[0-9]+$ ]] ; then
        _fail "LOAD_CHUNK_ROWS must be a number (0 = no split) in P2O.env (current: '${LOAD_CHUNK_ROWS}')"
        exit 1
    fi
    if [[ -n "${LOAD_COMMIT_ROWS}" && ! "${LOAD_COMMIT_ROWS}" =~ ^[1-9][0-9]*$ ]] ; then
        _fail "LOAD_COMMIT_ROWS must be empty or a positive number in P2O.env (current: '${LOAD_COMMIT_ROWS}')"
        exit 1
    fi

    # ============================================================
    # 0. Target login
    # ============================================================
    _out "%s\n" "$SEP"
    _log "Target login : ${TARGET_DBMS}${DB_TNS:+ (${DB_TNS})}"
    _out "%s\n" "$SEP"

    _tgt_login
    case $? in
        1) _log "Cancelled." ; exit 0 ;;
        2) exit 1 ;;
    esac

    # ============================================================
    # 1. Select CSV file / chunk directory
    # ============================================================
    # SRC_LIST = menu labels , SRC_PATH = same index -> file or directory
    SRC_LIST=()
    SRC_PATH=()
    for F in "${CSV_DIR}"/*.csv ; do
        [[ -f "${F}" ]] || continue
        SRC_LIST+=("$(basename "${F}")")
        SRC_PATH+=("${F}")
    done
    for D in "${CSV_DIR}"/*/ ; do
        D="${D%/}"
        [[ -d "${D}" ]] || continue
        N=$(ls "${D}"/*.csv 2>/dev/null | wc -l | tr -d ' ')
        (( N > 0 )) || continue
        SRC_LIST+=("$(basename "${D}")/  (${N} chunk files)")
        SRC_PATH+=("${D}")
    done

    if [[ ${#SRC_LIST[@]} -eq 0 ]] ; then
        _fail "No CSV file / chunk directory in ${CSV_DIR} (run the unload module first)"
        exit 1
    fi

    _out "%s\n" "$SEP"
    _log "Select CSV : ${CSV_DIR} (TARGET_DBMS=${TARGET_DBMS})"
    _out "%s\n" "$SEP"

    if ! _select_menu "CSV files / chunk directories (${#SRC_LIST[@]})" "${SRC_LIST[@]}" ; then
        _log "Cancelled."
        exit 0
    fi

    SRC="${SRC_PATH[MENU_IDX]}"
    CSV_NAME="$(basename "${SRC}")"
    _log "Selected : ${MENU_VAL}"

    # CHUNK_FILES = the files loaded one by one (one file = one chunk)
    if [[ -d "${SRC}" ]] ; then
        CHUNK_FILES=( "${SRC}"/*.csv )
        SRC_KIND="chunk directory (unload)"
    else
        CHUNK_FILES=( "${SRC}" )
        SRC_KIND="single CSV"
    fi

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
    HEADER_RAW=$(head -n 1 "${CHUNK_FILES[0]}")
    HEADER=$(echo "${HEADER_RAW}" | sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/"//g')
    IFS=',' read -r -a HDR_COLS <<< "${HEADER}"

    if [[ ${#HDR_COLS[@]} -eq 0 ]] ; then
        _fail "CSV file has no header line : ${CHUNK_FILES[0]}"
        exit 1
    fi

    # every chunk of a directory must carry the same header (one control file for all)
    for F in "${CHUNK_FILES[@]:1}" ; do
        if [[ "$(head -n 1 "${F}")" != "${HEADER_RAW}" ]] ; then
            _fail "Header line differs from the 1st chunk : ${F}"
            exit 1
        fi
    done

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

    # ============================================================
    # 4. Chunks
    # ============================================================
    # a single CSV is split when LOAD_CHUNK_ROWS > 0 and it has more rows than that
    if [[ ! -d "${SRC}" ]] && (( LOAD_CHUNK_ROWS > 0 )) ; then
        SRC_ROWS=$(( $(_rec_count "${SRC}") - 1 ))
        if (( SRC_ROWS > LOAD_CHUNK_ROWS )) ; then
            _log "Split ${CSV_NAME} : ${SRC_ROWS} rows -> chunks of ${LOAD_CHUNK_ROWS} rows (${TMP_CHUNK_DIR})"
            mkdir -p "${TMP_CHUNK_DIR}"
            _split_csv "${LOAD_CHUNK_ROWS}" "${TMP_CHUNK_DIR}" "${CSV_NAME%.csv}" < "${SRC}" | tee -a ${LOGFILE}
            if [[ ${PIPESTATUS[0]} -ne 0 ]] ; then
                _fail "Chunk split failed (disk full?) : ${TMP_CHUNK_DIR}"
                exit 1
            fi
            CHUNK_FILES=( "${TMP_CHUNK_DIR}"/*.csv )
            SRC_KIND="single CSV split by LOAD_CHUNK_ROWS=${LOAD_CHUNK_ROWS}"
        fi
    elif [[ -d "${SRC}" ]] && (( LOAD_CHUNK_ROWS > 0 )) ; then
        _log "LOAD_CHUNK_ROWS ignored : the chunk files of ${CSV_NAME}/ are loaded as they are"
    fi

    N_CHUNK=${#CHUNK_FILES[@]}
    mapfile -t CHUNK_ROWS < <(_rows_per_file "${CHUNK_FILES[@]}")
    CSV_ROWS=0
    for R in "${CHUNK_ROWS[@]}" ; do CSV_ROWS=$(( CSV_ROWS + R )) ; done

    # resume : start from a later chunk (the chunks before it are already in the table)
    START_CHUNK=1
    if (( N_CHUNK > 1 )) ; then
        _out "\n"
        while true ; do
            read -r -p "Start from chunk (1-${N_CHUNK}, Enter = 1) : " ANSWER || { _log "Cancelled." ; exit 0 ; }
            ANSWER=$(echo "${ANSWER}" | tr -d '[:space:]')
            [[ -z "${ANSWER}" ]] && ANSWER=1
            if [[ "${ANSWER}" =~ ^[0-9]+$ ]] && (( ANSWER >= 1 && ANSWER <= N_CHUNK )) ; then
                START_CHUNK=$(( 10#${ANSWER} ))
                break
            fi
            echo "  -> a number from 1 to ${N_CHUNK}. Try again."
        done
    fi

    ROWS_TO_LOAD=0
    for (( k = START_CHUNK ; k <= N_CHUNK ; k++ )) ; do
        ROWS_TO_LOAD=$(( ROWS_TO_LOAD + CHUNK_ROWS[k-1] ))
    done

    # TRUNCATE only empties the table before the 1st chunk ; a resumed run keeps the loaded chunks
    FIRST_MODE="${LOAD_MODE}"
    if [[ "${LOAD_MODE}" == "TRUNCATE" ]] && (( START_CHUNK > 1 )) ; then
        FIRST_MODE="APPEND"
    fi

    CTL_FILE="${BASE_PATH}/ctl/${LOAD_NAME}.ctl"
    _write_ctl "${FIRST_MODE}" "${CTL_FILE}"
    CTL_APPEND="${CTL_FILE}"
    if [[ "${FIRST_MODE}" != "APPEND" ]] && (( N_CHUNK > START_CHUNK )) ; then
        CTL_APPEND="${BASE_PATH}/ctl/${LOAD_NAME}_APPEND.ctl"
        _write_ctl "APPEND" "${CTL_APPEND}"
    fi

    # ============================================================
    # 5. Preview / confirm
    # ============================================================
    CNT_BEFORE=$(_count_target)
    if [[ -z "${CNT_BEFORE}" ]] ; then
        _out "%s\n" "$(cat ${TMP_OUT})"
        _fail "Cannot count ${TGT_OWNER}.${TGT_TABLE}"
        exit 1
    fi

    if [[ "${FIRST_MODE}" == "TRUNCATE" ]] ; then
        EXPECT_CNT="${ROWS_TO_LOAD}"
    else
        EXPECT_CNT=$(( CNT_BEFORE + ROWS_TO_LOAD ))
    fi

    _out "\n"
    _out "%s\n" "$SEP"
    _out "  Target DBMS  : %s (%s)\n" "${TARGET_DBMS}" "${LOADER}"
    _out "  Target table : %s.%s\n" "${TGT_OWNER}" "${TGT_TABLE}"
    _out "  CSV          : %s (%s)\n" "${SRC}" "${SRC_KIND}"
    _out "  CSV rows     : %s\n" "${CSV_ROWS}"
    _out "  Chunks       : %s (start chunk %s , rows to load %s)\n" "${N_CHUNK}" "${START_CHUNK}" "${ROWS_TO_LOAD}"
    _out "  Current rows : %s (expected after load %s)\n" "${CNT_BEFORE}" "${EXPECT_CNT}"
    _out "  Load mode    : %s (direct=%s, errors=%s per chunk, rows=%s)\n" \
         "${LOAD_MODE}" "${DIRECT}" "${LOAD_ERRORS}" "${LOAD_COMMIT_ROWS:-default}"
    _out "  Control file : %s\n" "${CTL_FILE}"
    _out "  Column mapping (%s of %s table columns) :\n" "${N_COL}" "$(wc -l < ${TMP_COLS} | tr -d ' ')"
    _out "%s\n" "$(cat ${TMP_MAP})"
    _out "%s\n" "$SEP"

    if [[ "${FIRST_MODE}" == "TRUNCATE" ]] ; then
        _out "  !!! TRUNCATE mode : the %s existing rows of %s.%s are deleted and can not be recovered.\n" \
             "${CNT_BEFORE}" "${TGT_OWNER}" "${TGT_TABLE}"
    elif [[ "${LOAD_MODE}" == "TRUNCATE" ]] ; then
        _out "  !!! resume from chunk %s : TRUNCATE is skipped, all chunks are APPENDed to the %s existing rows.\n" \
             "${START_CHUNK}" "${CNT_BEFORE}"
    fi

    read -r -p "Load into ${TGT_OWNER}.${TGT_TABLE}? (y/N): " ANSWER
    if [[ "${ANSWER}" != "y" && "${ANSWER}" != "Y" ]] ; then
        _log "Cancelled. (control file kept : ${CTL_FILE})"
        exit 0
    fi

    # ============================================================
    # 6. Load chunk by chunk
    # ============================================================
    _out "%s\n" "$SEP"
    _log "Load start : ${LOADER} , chunk ${START_CHUNK} .. ${N_CHUNK}"
    _out "%s\n" "$SEP"

    START_TS=$(date '+%s')
    LOADED_TOTAL=0
    REJECTED_TOTAL=0
    BAD_TOTAL=0
    DONE_CHUNKS=0
    FAILED_CHUNK=""

    for (( k = START_CHUNK ; k <= N_CHUNK ; k++ )) ; do
        DATA="${CHUNK_FILES[k-1]}"
        C_ROWS=${CHUNK_ROWS[k-1]}
        # one CSV loaded in one run keeps the plain names ; chunks get _NNNNN
        if (( N_CHUNK > 1 )) ; then TAG=$(printf '_%05d' ${k}) ; else TAG="" ; fi
        LDR_LOG="${BASE_PATH}/log/${LOAD_NAME}${TAG}_${LOADER}.log"
        BAD_FILE="${BASE_PATH}/bad/${LOAD_NAME}${TAG}.bad"
        if (( k == START_CHUNK )) ; then CTL="${CTL_FILE}" ; else CTL="${CTL_APPEND}" ; fi

        _log "chunk ${k}/${N_CHUNK} : $(basename "${DATA}") (${C_ROWS} rows)"
        C_START=$(date '+%s')
        _run_loader "${CTL}" "${DATA}" "${LDR_LOG}" "${BAD_FILE}"
        RC=$?

        # loaded / rejected rows from the loader log
        #   sqlldr   : "  10 Rows successfully loaded." / "  0 Rows not loaded due to data errors."
        #   tbloader : "5 Rows were loaded successfully." / "3 Rows were failed to load because of some errors"
        if [[ "${TARGET_DBMS}" == "ORACLE" ]] ; then
            LDR_LOADED=$(_ldr_count '[0-9]+[[:space:]]+Rows? successfully loaded')
            LDR_REJECTED=$(_ldr_count '[0-9]+[[:space:]]+Rows? not loaded due to data errors')
        else
            LDR_LOADED=$(_ldr_count '[0-9]+[[:space:]]+Rows? were loaded successfully')
            LDR_REJECTED=$(_ldr_count '[0-9]+[[:space:]]+Rows? were failed to load')
        fi
        BAD_ROWS=0
        [[ -s "${BAD_FILE}" ]] && BAD_ROWS=$(_rec_count "${BAD_FILE}")

        LOADED_TOTAL=$(( LOADED_TOTAL + ${LDR_LOADED:-0} ))
        REJECTED_TOTAL=$(( REJECTED_TOTAL + ${LDR_REJECTED:-0} ))
        BAD_TOTAL=$(( BAD_TOTAL + BAD_ROWS ))

        _out "  [%d/%d] rows %s , loaded %s , rejected %s , bad %s , rc %s , %s sec\n" \
             "${k}" "${N_CHUNK}" "${C_ROWS}" "${LDR_LOADED:-?}" "${LDR_REJECTED:-?}" "${BAD_ROWS}" "${RC}" \
             "$(( $(date '+%s') - C_START ))"

        # a chunk is good when the loader ended clean, nothing was rejected and (if readable) all rows loaded
        if [[ ${RC} -ne 0 || ${BAD_ROWS} -gt 0 ]] || [[ -n "${LDR_LOADED}" && "${LDR_LOADED}" != "${C_ROWS}" ]] ; then
            FAILED_CHUNK=${k}
            break
        fi
        DONE_CHUNKS=$(( DONE_CHUNKS + 1 ))
    done

    ELAPSED=$(( $(date '+%s') - START_TS ))

    # ============================================================
    # 7. Result
    # ============================================================
    CNT_AFTER=$(_count_target)

    _out "\n"
    _out "%s\n" "$SEP"
    _out "  Chunks done  : %s of %s (start chunk %s)\n" "${DONE_CHUNKS}" "$(( N_CHUNK - START_CHUNK + 1 ))" "${START_CHUNK}"
    _out "  Loaded rows  : %s (loader log)\n" "${LOADED_TOTAL}"
    _out "  Rejected rows: %s (loader log)\n" "${REJECTED_TOTAL}"
    _out "  Bad rows     : %s\n" "${BAD_TOTAL}"
    _out "  Rows to load : %s\n" "${ROWS_TO_LOAD}"
    _out "  Rows before  : %s\n" "${CNT_BEFORE}"
    _out "  Rows after   : %s (expected %s)\n" "${CNT_AFTER:-?}" "${EXPECT_CNT}"
    _out "  Loader logs  : %s/log/%s*_%s.log\n" "${BASE_PATH}" "${LOAD_NAME}" "${LOADER}"
    (( BAD_TOTAL > 0 )) && _out "  Bad files    : %s/bad/%s*.bad\n" "${BASE_PATH}" "${LOAD_NAME}"
    _out "  Elapsed      : %s sec\n" "${ELAPSED}"
    _out "  Log          : %s\n" "${LOGFILE}"
    _out "%s\n" "$SEP"

    if [[ -n "${FAILED_CHUNK}" ]] ; then
        _fail "Chunk ${FAILED_CHUNK}/${N_CHUNK} failed (loader rc=${RC}). Stopped ; chunks after it were not loaded."
        _out "       chunk file : %s\n" "${CHUNK_FILES[FAILED_CHUNK-1]}"
        _out "       loader log : %s\n" "${LDR_LOG}"
        if (( N_CHUNK > 1 )) ; then
            _out "       resume     : fix the cause, then rerun the load module with the same CSV and start chunk %s\n" "${FAILED_CHUNK}"
            if [[ "${LDR_LOADED}" != "0" ]] ; then
                _out "       note       : rows of chunk %s already committed (loader log : %s) are loaded again on resume.\n" \
                     "${FAILED_CHUNK}" "${LDR_LOADED:-?}"
                _out "                    delete them first (or resume from chunk %s if chunk %s is handled separately).\n" \
                     "$(( FAILED_CHUNK + 1 ))" "${FAILED_CHUNK}"
            fi
        fi
        exit 1
    fi

    if [[ -z "${CNT_AFTER}" ]] ; then
        _fail "Cannot count ${TGT_OWNER}.${TGT_TABLE} after the load. Check the loader log."
        exit 1
    fi

    if [[ "${CNT_AFTER}" == "${EXPECT_CNT}" ]] ; then
        _ok "Load finished : ${CSV_NAME} -> ${TGT_OWNER}.${TGT_TABLE} (${ROWS_TO_LOAD} rows, ${DONE_CHUNKS} chunks)"
        exit 0
    fi

    _fail "Row count mismatch : ${CNT_AFTER} rows after the load, expected ${EXPECT_CNT}. Check the loader logs."
    exit 1
}

# _run_module <unload|load> : run a module in a subshell (its exit / env / traps stay there)
_run_module() {
    local rc
    ( "_${1}_run" )
    rc=$?
    return ${rc}
}

# ============================================================
# Menu : settings editor
# ============================================================
# _valid_value <VALUE> : safe to write unquoted into a file that bash sources
#   (no blank / quote / backtick / ; & | < > \)
_valid_value() {
    local re='^[A-Za-z0-9_./:@%+,={}$-]*$'
    [[ "$1" =~ $re ]]
}

# _edit_field <FILE> <KEY> <TYPE> <PREFIX> : ask a new value and write it
#   TYPE : text (not empty) | opt (may be empty) | port | num0 (>= 0) | num1e (empty or >= 1)
#          | ch:A,B,... (choose with the menu)
_edit_field() {
    local file="$1" key="$2" type="$3" pre="$4" cur new
    cur=$(_env_get "${file}" "${key}")
    echo
    if [[ "${type}" == ch:* ]] ; then
        local -a opts
        IFS=',' read -r -a opts <<< "${type#ch:}"
        _select_menu "${key} (current : ${cur:-<empty>})" "${opts[@]}" || return 0
        new="${MENU_VAL}"
    else
        echo "  file    : ${file}"
        echo "  current : ${key}=${cur}"
        if [[ "${type}" == "opt" || "${type}" == "num1e" ]] ; then
            echo "  (Enter = keep , - = clear)"
        else
            echo "  (Enter = keep)"
        fi
        read -r -p "  new ${key} = " new || return 0
        new=$(echo "${new}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [[ -z "${new}" ]] && return 0
        if [[ "${new}" == "-" ]] ; then
            if [[ "${type}" != "opt" && "${type}" != "num1e" ]] ; then
                echo "  -> ${key} can not be empty." ; _pause ; return 0
            fi
            new=""
        fi
        if ! _valid_value "${new}" ; then
            echo "  -> letters, digits and _ . / : @ % + , = { } \$ - only (no blank / quote)." ; _pause ; return 0
        fi
        case "${type}" in
            port)
                if [[ ! "${new}" =~ ^[0-9]+$ ]] || (( new < 1 || new > 65535 )) ; then
                    echo "  -> a port number (1-65535)." ; _pause ; return 0
                fi ;;
            num0)
                if [[ ! "${new}" =~ ^[0-9]+$ ]] ; then
                    echo "  -> a number (0 or more)." ; _pause ; return 0
                fi ;;
            num1e)
                if [[ -n "${new}" && ! "${new}" =~ ^[1-9][0-9]*$ ]] ; then
                    echo "  -> empty or a number (1 or more)." ; _pause ; return 0
                fi ;;
        esac
    fi

    [[ "${new}" == "${cur}" ]] && return 0
    if _env_set "${file}" "${key}" "${new}" "${pre}" ; then
        _log "SET ${key} : '${cur}' -> '${new}' (${file})"
    else
        _fail "Cannot write ${file}"
        _pause
    fi
}

# _edit_client_var <ENV_FILE_KEY> <VAR> <TEMPLATE> <TYPE> : edit "export VAR=" in the client env file
#   the file is created from env/<TEMPLATE>.env.example when it does not exist yet
_edit_client_var() {
    local f
    f=$(_client_env "$1")
    echo
    if [[ -z "${f}" ]] ; then
        echo "  $1 is empty in P2O.env. Set it first (e.g. env/$3.env)."
        _pause ; return 0
    fi
    if [[ ! -f "${f}" ]] ; then
        echo "  $1 file not found : ${f}"
        if [[ ! -f "${SCRIPT_DIR}/env/$3.env.example" ]] ; then
            _pause ; return 0
        fi
        read -r -p "  Create it from env/$3.env.example? (y/N): " ANSWER
        [[ "${ANSWER}" != "y" && "${ANSWER}" != "Y" ]] && return 0
        mkdir -p "$(dirname "${f}")" && cp "${SCRIPT_DIR}/env/$3.env.example" "${f}" || { _fail "Cannot create ${f}" ; _pause ; return 0 ; }
        _log "CREATE ${f} (from env/$3.env.example)"
    fi
    _edit_field "${f}" "$2" "$4" "export "
}

# _client_status <ENV_FILE_KEY> <COMMAND>... : "OK" or what is missing (checked in a subshell)
_client_status() {
    local key="$1" f
    shift
    f=$(_client_env "${key}")
    (
        if [[ -n "${f}" ]] ; then
            [[ -f "${f}" ]] || { echo "env file missing" ; exit 0 ; }
            . "${f}" > /dev/null 2>&1
        fi
        for c in "$@" ; do
            command -v "${c}" > /dev/null 2>&1 || { echo "${c} not found" ; exit 0 ; }
        done
        echo "OK"
    )
}

# ============================================================
# Menu : connection tests (subshell : the client env does not stay in the menu)
# ============================================================
_test_source() {
    _clear
    (
        . ${ENV_FILE}
        _out "%s\n" "$SEP"
        _log "Source connection test : ${PG_HOST}:${PG_PORT}/${PG_DB}"
        _out "%s\n" "$SEP"
        _load_pg_client || exit 1
        _out "  psql : %s\n" "$(command -v psql)"
        _pg_login
    )
    _pause
}

_test_target() {
    _clear
    (
        . ${ENV_FILE}
        _out "%s\n" "$SEP"
        _log "Target connection test : ${TARGET_DBMS}${DB_TNS:+ @${DB_TNS}}"
        _out "%s\n" "$SEP"
        _load_tgt_client || exit 1
        _out "  %-8s : %s\n" "${DB_CLIENT}" "$(command -v ${DB_CLIENT})" "${LOADER}" "$(command -v ${LOADER})"
        _tgt_login
    )
    _pause
}

# ============================================================
# Menu : screens
# ============================================================
# _screen_header : current settings summary (read from the files each time)
_screen_header() {
    local base tgt
    base=$(_env_get "${ENV_FILE}" BASE_PATH)
    tgt=$(_env_get "${ENV_FILE}" TARGET_DBMS)
    printf "%s\n" "$SEP"
    printf " P2O_MIG  PostgreSQL -> %s\n" "${tgt:-?}"
    printf " %s\n" "${ENV_FILE}"
    printf "%s\n" "$SEP"
    printf " Source : %s:%s/%s  [psql %s]\n" \
        "$(_env_get "${ENV_FILE}" PG_HOST)" "$(_env_get "${ENV_FILE}" PG_PORT)" "$(_env_get "${ENV_FILE}" PG_DB)" \
        "$(_client_status PG_ENV_FILE psql)"
    case "${tgt}" in
        ORACLE) printf " Target : ORACLE%s  [sqlplus/sqlldr %s]\n" \
                    "$(_env_get "${ENV_FILE}" DB_TNS | sed 's/^./ @&/')" "$(_client_status ORACLE_ENV_FILE sqlplus sqlldr)" ;;
        TIBERO) printf " Target : TIBERO%s  [tbsql/tbloader %s]\n" \
                    "$(_env_get "${ENV_FILE}" DB_TNS | sed 's/^./ @&/')" "$(_client_status TIBERO_ENV_FILE tbsql tbloader)" ;;
        *)      printf " Target : TARGET_DBMS is not ORACLE / TIBERO ('%s')\n" "${tgt}" ;;
    esac
    printf " Load   : %s , direct %s , chunk unload %s / load %s\n" \
        "$(_env_get "${ENV_FILE}" LOAD_MODE)" "$(_env_get "${ENV_FILE}" DIRECT)" \
        "$(_env_get "${ENV_FILE}" UNLOAD_CHUNK_ROWS)" "$(_env_get "${ENV_FILE}" LOAD_CHUNK_ROWS)"
    printf " Output : %s\n" "${base:-${SCRIPT_DIR}}"
    printf "%s\n" "$LINE"
}

# _fmt <KEY> <VALUE> : one aligned settings line for a menu item
_fmt() { printf "%-18s : %s" "$1" "${2:-<empty>}" ; }

_screen_source() {
    local f items
    while true ; do
        _clear
        _screen_header
        f=$(_client_env PG_ENV_FILE)
        items=(
            "$(_fmt PG_HOST     "$(_env_get "${ENV_FILE}" PG_HOST)")"
            "$(_fmt PG_PORT     "$(_env_get "${ENV_FILE}" PG_PORT)")"
            "$(_fmt PG_DB       "$(_env_get "${ENV_FILE}" PG_DB)")"
            "$(_fmt PG_ENV_FILE "$(_env_get "${ENV_FILE}" PG_ENV_FILE)")"
            "$(_fmt "  PG_HOME"  "$(_env_get "${f}" PG_HOME)")"
            "Connection test (psql)"
            "Back"
        )
        _select_menu "Source : PostgreSQL" "${items[@]}" || return 0
        case ${MENU_IDX} in
            0) _edit_field "${ENV_FILE}" PG_HOST     text  "" ;;
            1) _edit_field "${ENV_FILE}" PG_PORT     port  "" ;;
            2) _edit_field "${ENV_FILE}" PG_DB       text  "" ;;
            3) _edit_field "${ENV_FILE}" PG_ENV_FILE opt   "" ;;
            4) _edit_client_var PG_ENV_FILE PG_HOME PG text ;;
            5) _test_source ;;
            *) return 0 ;;
        esac
    done
}

_screen_target() {
    local tgt key f home nls tmpl items
    while true ; do
        _clear
        _screen_header
        tgt=$(_env_get "${ENV_FILE}" TARGET_DBMS)
        if [[ "${tgt}" == "TIBERO" ]] ; then
            key="TIBERO_ENV_FILE" ; home="TB_HOME"     ; nls="TB_NLS_LANG" ; tmpl="TIBERO"
        else
            key="ORACLE_ENV_FILE" ; home="ORACLE_HOME" ; nls="NLS_LANG"    ; tmpl="ORACLE"
        fi
        f=$(_client_env ${key})
        items=(
            "$(_fmt TARGET_DBMS "${tgt}")"
            "$(_fmt DB_TNS      "$(_env_get "${ENV_FILE}" DB_TNS)")"
            "$(_fmt ${key}      "$(_env_get "${ENV_FILE}" ${key})")"
            "$(_fmt "  ${home}" "$(_env_get "${f}" ${home})")"
            "$(_fmt "  ${nls}"  "$(_env_get "${f}" ${nls})")"
            "Connection test (${tgt:-?})"
            "Back"
        )
        _select_menu "Target : ${tgt:-?}  (the ${home} / ${nls} lines are in ${key})" "${items[@]}" || return 0
        case ${MENU_IDX} in
            0) _edit_field "${ENV_FILE}" TARGET_DBMS "ch:ORACLE,TIBERO" "" ;;
            1) _edit_field "${ENV_FILE}" DB_TNS      opt "" ;;
            2) _edit_field "${ENV_FILE}" ${key}      opt "" ;;
            3) _edit_client_var ${key} ${home} ${tmpl} text ;;
            4) _edit_client_var ${key} ${nls}  ${tmpl} text ;;
            5) _test_target ;;
            *) return 0 ;;
        esac
    done
}

_screen_options() {
    local items
    while true ; do
        _clear
        _screen_header
        items=(
            "$(_fmt BASE_PATH         "$(_env_get "${ENV_FILE}" BASE_PATH)")"
            "$(_fmt LOAD_MODE         "$(_env_get "${ENV_FILE}" LOAD_MODE)")"
            "$(_fmt DIRECT            "$(_env_get "${ENV_FILE}" DIRECT)")"
            "$(_fmt LOAD_ERRORS       "$(_env_get "${ENV_FILE}" LOAD_ERRORS)")"
            "$(_fmt CHARSET           "$(_env_get "${ENV_FILE}" CHARSET)")"
            "$(_fmt UNLOAD_CHUNK_ROWS "$(_env_get "${ENV_FILE}" UNLOAD_CHUNK_ROWS)")"
            "$(_fmt LOAD_CHUNK_ROWS   "$(_env_get "${ENV_FILE}" LOAD_CHUNK_ROWS)")"
            "$(_fmt LOAD_COMMIT_ROWS  "$(_env_get "${ENV_FILE}" LOAD_COMMIT_ROWS)")"
            "Back"
        )
        _select_menu "Load options (P2O.env)" "${items[@]}" || return 0
        case ${MENU_IDX} in
            0) _edit_field "${ENV_FILE}" BASE_PATH         opt   "" ;;
            1) _edit_field "${ENV_FILE}" LOAD_MODE         "ch:APPEND,TRUNCATE" "" ;;
            2) _edit_field "${ENV_FILE}" DIRECT            "ch:N,Y" "" ;;
            3) _edit_field "${ENV_FILE}" LOAD_ERRORS       num0  "" ;;
            4) _edit_field "${ENV_FILE}" CHARSET           opt   "" ;;
            5) _edit_field "${ENV_FILE}" UNLOAD_CHUNK_ROWS num0  "" ;;
            6) _edit_field "${ENV_FILE}" LOAD_CHUNK_ROWS   num0  "" ;;
            7) _edit_field "${ENV_FILE}" LOAD_COMMIT_ROWS  num1e "" ;;
            *) return 0 ;;
        esac
    done
}

# _screen_outputs : CSV / chunk directories and recent logs under BASE_PATH ; pick a log to view it
_screen_outputs() {
    local base d f n logs items
    base=$(_env_get "${ENV_FILE}" BASE_PATH)
    base="${base:-${SCRIPT_DIR}}"
    while true ; do
        _clear
        _screen_header
        printf " CSV (%s/csv)\n" "${base}"
        n=0
        for f in "${base}"/csv/*.csv ; do
            [[ -f "${f}" ]] || continue
            printf "   %-40s %14s bytes\n" "$(basename "${f}")" "$(wc -c < "${f}" | tr -d ' ')"
            n=$(( n + 1 ))
        done
        for d in "${base}"/csv/*/ ; do
            d="${d%/}"
            [[ -d "${d}" ]] || continue
            printf "   %-40s %5s chunks %10s KB\n" "$(basename "${d}")/" \
                "$(ls "${d}"/*.csv 2>/dev/null | wc -l | tr -d ' ')" "$(du -sk "${d}" | awk '{ print $1 }')"
            n=$(( n + 1 ))
        done
        (( n == 0 )) && printf "   (none)\n"
        printf "%s\n" "$LINE"

        logs=()
        while IFS= read -r f ; do
            logs+=("${f}")
        done < <(ls -t "${base}"/log/*.log 2>/dev/null | head -n 15)
        items=()
        for f in "${logs[@]}" ; do
            items+=("view log : $(basename "${f}")")
        done
        items+=("Back")
        _select_menu "Recent logs (${base}/log)" "${items[@]}" || return 0
        (( MENU_IDX >= ${#logs[@]} )) && return 0
        _clear
        if command -v less > /dev/null 2>&1 ; then
            less "${logs[MENU_IDX]}"
        else
            tail -n 60 "${logs[MENU_IDX]}"
            _pause
        fi
    done
}

# _menu_module <unload|load> : run a module from the menu and wait before redrawing
_menu_module() {
    local rc
    _clear
    _log "RUN module ${1}"
    _run_module "${1}"
    rc=$?
    _log "END module ${1} (rc=${rc})"
    _pause
}

# ============================================================
# Main
# ============================================================
case "$1" in
    unload|load)
        _run_module "$1"
        exit $?
        ;;
    "")
        ;;
    *)
        echo "Usage: $0 [unload|load]   (no argument = menu)"
        exit 1
        ;;
esac

_log "Menu start : ${ENV_FILE}"
while true ; do
    _clear
    _screen_header
    MAIN=(
        "1. Source (PostgreSQL) settings / connection test"
        "2. Target (Oracle / Tibero) settings / connection test"
        "3. Load options (BASE_PATH, mode, chunk ...)"
        "4. Unload : PostgreSQL -> CSV"
        "5. Load   : CSV -> target table"
        "6. Outputs : CSV files / logs"
        "q. Quit"
    )
    _select_menu "Main menu" "${MAIN[@]}" || break
    case ${MENU_IDX} in
        0) _screen_source ;;
        1) _screen_target ;;
        2) _screen_options ;;
        3) _menu_module unload ;;
        4) _menu_module load ;;
        5) _screen_outputs ;;
        *) break ;;
    esac
done
_log "Menu end"
exit 0
