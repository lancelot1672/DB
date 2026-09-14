#!/bin/bash
# ============================================================
# 03.LOAD_COL_MAP.sh
# Load a CSV file (comma separated, header row) into DBADM.DBM_MIG_COL_MAP.
#   - no validation in shell : every check is left to the DB
#     (any DB error rolls back the whole load, DELETE included)
#   - header names = INSERT column list (column order is free)
#   - "..." quoted values may contain commas, "" = literal double quote
#   - every value is inserted as a quoted literal, empty value -> NULL
#   - TGT_OWNER / TGT_TABLE_NAME / SRC_OWNER / SRC_TABLE_NAME / TGT_COL / SRC_COL / MAP_FLAG -> upper case
#     (DEFAULT_VAL / REMARK as-is)
#   - table pairs (TGT_OWNER, TGT_TABLE_NAME, SRC_OWNER, SRC_TABLE_NAME) found in the CSV are replaced :
#     existing mapping rows of those pairs are deleted, then the CSV rows are inserted (one transaction)
#     mapping rows of other table pairs are kept
#   - DB client by DB_TYPE in MIG.env (ORACLE=sqlplus, TIBERO=tbsql)
#   - plain SQL only (no procedure / PL/SQL block)
# Usage: 03.LOAD_COL_MAP.sh <CSV_FILE>
# ============================================================

if [[ -z "$1" ]] ; then
  echo "Usage: 03.LOAD_COL_MAP.sh <CSV_FILE>"
  echo "  CSV_FILE : comma separated, 1st line = DBADM.DBM_MIG_COL_MAP column names"
  exit 1
fi

CSV_FILE="$1"
if [[ ! -f "${CSV_FILE}" ]] ; then
  echo "[FAIL] CSV file not found: ${CSV_FILE}"
  exit 1
fi

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

DB_CONN="${DB_USER}/${DB_PASS}${DB_TNS:+@${DB_TNS}}"

TARGET_TAB="DBADM.DBM_MIG_COL_MAP"
# name columns converted to upper case (dictionary names are upper case)
UPPER_COLS="TGT_OWNER TGT_TABLE_NAME SRC_OWNER SRC_TABLE_NAME TGT_COL SRC_COL MAP_FLAG"

SEP="============================================================"

mkdir -p "${BASE_PATH}/log" "${BASE_PATH}/tmp"

TMP_PREFIX="${BASE_PATH}/tmp/LOAD_COL_MAP"
TMP_CSV="${TMP_PREFIX}_CSV_$$.csv"
TMP_BODY="${TMP_PREFIX}_BODY_$$.sql"
TMP_PAIRS="${TMP_PREFIX}_PAIRS_$$.lst"
TMP_PREVIEW="${TMP_PREFIX}_PREVIEW_$$.txt"
TMP_SQL="${TMP_PREFIX}_SQL_$$.sql"
TMP_OUT="${TMP_PREFIX}_OUT_$$.txt"

# --- Log File ---
LOGFILE="${BASE_PATH}/log/LOAD_COL_MAP_$(date '+%Y%m%d_%H%M%S').log"

# _out: Print to terminal and append to log file
_out() {
    printf "$@"
    printf "$@" >> ${LOGFILE}
}

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

_cleanup() {
    rm -f ${TMP_CSV} ${TMP_BODY} ${TMP_PAIRS} ${TMP_PREVIEW} ${TMP_SQL} ${TMP_OUT}
}
trap _cleanup EXIT

# _q <text> : escape single quotes for a SQL literal
_q() { printf "%s" "${1//\'/\'\'}"; }

# _db_errors : DB error lines of the last _run_sql ("TAG|value" result lines are data)
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

# _pair_where <TGT_OWNER> <TGT_TABLE> <SRC_OWNER> <SRC_TABLE>
_pair_where() {
    printf "TGT_OWNER = '%s' AND TGT_TABLE_NAME = '%s' AND SRC_OWNER = '%s' AND SRC_TABLE_NAME = '%s'" \
           "$(_q "$1")" "$(_q "$2")" "$(_q "$3")" "$(_q "$4")"
}

# ============================================================
# 1. Build INSERT SQL and table pair list from CSV
# ============================================================
_out "%s\n" "$SEP"
_log "Build SQL : ${CSV_FILE} (DB_TYPE=${DB_TYPE})"
_out "%s\n" "$SEP"

# strip UTF-8 BOM and CR (Excel / Windows CSV)
sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "${CSV_FILE}" > ${TMP_CSV}

AWK_BUILD=$(cat <<'EOF'
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }

# split one CSV line into arr[1..n] ("..." quoting, "" = literal quote)
function parse_csv(line, arr,    n, i, c, len, fld, inq) {
    n = 0; fld = ""; inq = 0; len = length(line)
    for (i = 1; i <= len; i++) {
        c = substr(line, i, 1)
        if (inq) {
            if (c == "\"") {
                if (substr(line, i + 1, 1) == "\"") { fld = fld c; i++ }
                else inq = 0
            } else fld = fld c
        }
        else if (c == "\"") inq = 1
        else if (c == ",")  { arr[++n] = trim(fld); fld = "" }
        else                fld = fld c
    }
    arr[++n] = trim(fld)
    return n
}

BEGIN {
    split(upper_cols, a, " ")
    for (i in a) upper[a[i]] = 1
}

# --- header ---
NR == 1 {
    ncol = parse_csv($0, hdr)
    for (i = 1; i <= ncol; i++) {
        hdr[i] = toupper(hdr[i])
        col_list = col_list (i > 1 ? ", " : "") hdr[i]
    }
    next
}

# --- blank line ---
/^[ \t,]*$/ { next }

# --- data ---
{
    n = parse_csv($0, f)
    vals = ""
    split("", disp)
    for (i = 1; i <= n; i++) {
        h = hdr[i]; v = f[i]
        if (h in upper) v = toupper(v)
        disp[h] = v
        if (v == "") sqlv = "NULL"
        else         { gsub(sq, sq sq, v); sqlv = sq v sq }
        vals = vals (i > 1 ? ", " : "") sqlv
    }
    printf "INSERT INTO %s (%s) VALUES (%s);\n", tab, col_list, vals > bodyfile

    key = disp["TGT_OWNER"] "|" disp["TGT_TABLE_NAME"] "|" disp["SRC_OWNER"] "|" disp["SRC_TABLE_NAME"]
    if (!(key in pair_cnt)) pair_order[++npair] = key
    pair_cnt[key]++

    printf "LINE %-5d %s.%s <- %s.%s  %s <- %s [%s] %s\n", NR,
           disp["TGT_OWNER"], disp["TGT_TABLE_NAME"], disp["SRC_OWNER"], disp["SRC_TABLE_NAME"],
           disp["TGT_COL"], (disp["SRC_COL"] == "" ? "-" : disp["SRC_COL"]), disp["MAP_FLAG"], disp["DEFAULT_VAL"] > prevfile
}

# TGT_OWNER|TGT_TABLE_NAME|SRC_OWNER|SRC_TABLE_NAME|CSV rows  (CSV order)
END { for (i = 1; i <= npair; i++) print pair_order[i] "|" pair_cnt[pair_order[i]] > pairfile }
EOF
)

: > ${TMP_BODY} ; : > ${TMP_PAIRS} ; : > ${TMP_PREVIEW}

awk -v sq="'" -v tab="${TARGET_TAB}" -v upper_cols="${UPPER_COLS}" \
    -v bodyfile="${TMP_BODY}" -v pairfile="${TMP_PAIRS}" -v prevfile="${TMP_PREVIEW}" \
    "${AWK_BUILD}" ${TMP_CSV}

TOTAL=$(wc -l < ${TMP_BODY} | tr -d ' ')
PAIR_CNT=$(wc -l < ${TMP_PAIRS} | tr -d ' ')
if [[ ${TOTAL} -eq 0 ]] ; then
    _fail "No data rows in ${CSV_FILE}"
    exit 1
fi
_ok "SQL built : ${TOTAL} row(s), ${PAIR_CNT} table pair(s)"

# ============================================================
# 2. Existing mapping rows of the table pairs (rows to be deleted)
# ============================================================
{
    echo "SET HEADING OFF"
    echo "SET FEEDBACK OFF"
    echo "SET PAGESIZE 50000"
    echo "SET LINESIZE 32767"
    echo "SET DEFINE OFF"
    echo "WHENEVER SQLERROR EXIT FAILURE"
    while IFS='|' read -r TO TT SO ST _n ; do
        echo "SELECT 'DEL|' || COUNT(*) FROM ${TARGET_TAB} WHERE $(_pair_where "${TO}" "${TT}" "${SO}" "${ST}");"
    done < ${TMP_PAIRS}
    echo "EXIT;"
} > ${TMP_SQL}

if ! _run_sql ${TMP_SQL} ; then
    cat ${TMP_OUT} >> ${LOGFILE}
    _fail "Failed to read ${TARGET_TAB}"
    _db_errors | while IFS= read -r _line ; do _out "  %s\n" "${_line}" ; done
    exit 1
fi

# DEL counts come back in the same order as TMP_PAIRS
grep '^DEL|' ${TMP_OUT} | cut -d'|' -f2 | tr -d ' ' > ${TMP_OUT}.cnt
paste -d'|' ${TMP_PAIRS} ${TMP_OUT}.cnt > ${TMP_PAIRS}.new && mv ${TMP_PAIRS}.new ${TMP_PAIRS}
rm -f ${TMP_OUT}.cnt
DEL_TOTAL=$(awk -F'|' '{ s += $6 } END { print s + 0 }' ${TMP_PAIRS})

# ============================================================
# 3. Preview and confirm
# ============================================================
_out "%s\n" "$SEP"
_log "Preview"
_out "%s\n" "$SEP"
_out "  Target          : %s (%s)\n" "${TARGET_TAB}" "${DB_TYPE}"
_out "  Table pairs     : %s\n" "${PAIR_CNT}"
_out "  Rows to DELETE  : %s (existing mapping of these pairs)\n" "${DEL_TOTAL}"
_out "  Rows to INSERT  : %s\n\n" "${TOTAL}"

_fmt_pair() {
    local _to _tt _so _st _n _d
    while IFS='|' read -r _to _tt _so _st _n _d ; do
        _out "  %s.%s <- %s.%s   insert %s / delete %s\n" "${_to}" "${_tt}" "${_so}" "${_st}" "${_n}" "${_d:-?}"
    done
}
_fmt_line() { while IFS= read -r _line ; do _out "  %s\n" "${_line}" ; done; }

# _head_tail <FILE> <FORMAT_FUNC> <TITLE>
_head_tail() {
    local _n
    _n=$(wc -l < "$1" | tr -d ' ')
    _out "  --- %s : TOP 5 ---\n" "$3"
    head -5 "$1" | $2
    if [[ ${_n} -gt 5 ]] ; then
        _out "  --- %s : BOTTOM 5 ---\n" "$3"
        tail -5 "$1" | $2
    fi
    _out "\n"
}
_head_tail ${TMP_PAIRS} _fmt_pair "TABLE PAIRS"
_head_tail ${TMP_PREVIEW} _fmt_line "ROWS"

printf "Replace mapping of %s table pair(s) : delete %s, insert %s row(s)? [y/N]: " "${PAIR_CNT}" "${DEL_TOTAL}" "${TOTAL}"
read -r ANSWER
if [[ "${ANSWER}" != "y" && "${ANSWER}" != "Y" ]] ; then
    _log "Load cancelled by user"
    exit 0
fi

# ============================================================
# 4. DELETE pairs + INSERT rows (all or nothing)
# ============================================================
_out "%s\n" "$SEP"
_log "Execute DELETE + INSERT via ${DB_CLIENT}"
_out "%s\n" "$SEP"

{
    echo "SET DEFINE OFF"
    echo "SET FEEDBACK ON"
    echo "WHENEVER SQLERROR EXIT FAILURE ROLLBACK"
    while IFS='|' read -r TO TT SO ST _n _d ; do
        echo "DELETE FROM ${TARGET_TAB} WHERE $(_pair_where "${TO}" "${TT}" "${SO}" "${ST}");"
    done < ${TMP_PAIRS}
    cat ${TMP_BODY}
    echo "COMMIT;"
    echo "EXIT;"
} > ${TMP_SQL}

_run_sql ${TMP_SQL}
RC=$?
cat ${TMP_OUT} >> ${LOGFILE}

if [[ ${RC} -ne 0 ]] ; then
    # feedback lines before the failing statement : "N rows deleted." / "1 row created." (sqlplus) / "1 row inserted." (tbsql)
    DEL_DONE=$(grep -Ec '^[0-9]+ rows? deleted' ${TMP_OUT})
    INS_DONE=$(grep -Ec '^1 row (created|inserted)' ${TMP_OUT})
    if [[ ${DEL_DONE} -lt ${PAIR_CNT} ]] ; then
        _fail "DELETE failed at table pair $((DEL_DONE + 1)) of ${PAIR_CNT} - rolled back"
        sed -n "$((DEL_DONE + 1))p" ${TMP_PAIRS} | _fmt_pair
    else
        _fail "INSERT failed at row $((INS_DONE + 1)) of ${TOTAL} - rolled back"
        sed -n "$((INS_DONE + 1))p" ${TMP_PREVIEW} | _fmt_line
    fi
    _db_errors | while IFS= read -r _line ; do _out "  %s\n" "${_line}" ; done
    exit 1
fi

_ok "${TARGET_TAB} : ${PAIR_CNT} table pair(s) replaced (deleted ${DEL_TOTAL}, inserted ${TOTAL})"
exit 0
