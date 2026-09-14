#!/bin/bash
# ============================================================
# 01.LOAD_MIG_MSTR.sh
# Load a CSV file (comma separated, header row) into DBADM.DBM_MIG_MSTR.
#   - no validation in shell : every check is left to the DB
#     (any DB error rolls back the whole load)
#   - header names = INSERT column list (column order is free)
#   - "..." quoted values may contain commas, "" = literal double quote
#   - NUMBER columns (NUM_COLS) as-is, others as quoted literal, empty value -> NULL
#     (TRANS_YN / PARTITION_YN / MIG_YN / MIG_METHOD / SRC / TGT -> default value)
#   - DB client by DB_TYPE in MIG.env (ORACLE=sqlplus, TIBERO=tbsql)
#   - plain SQL only (no procedure / PL/SQL block)
# Usage: 01.LOAD_MIG_MSTR.sh <CSV_FILE>
# ============================================================

if [[ -z "$1" ]] ; then
  echo "Usage: 01.LOAD_MIG_MSTR.sh <CSV_FILE>"
  echo "  CSV_FILE : comma separated, 1st line = DBADM.DBM_MIG_MSTR column names"
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

TARGET_TAB="DBADM.DBM_MIG_MSTR"
# NUMBER columns : inserted without quotes (keep in sync with DDL_Script/DBM_MIG_MSTR.sql)
NUM_COLS="TAB_SIZE LOB_SIZE"
# empty value, or column absent from the CSV header -> this value
DEF_VALS="TRANS_YN=N PARTITION_YN=N MIG_YN=Y MIG_METHOD=DB_LINK SRC=ASIS TGT=TOBE"

SEP="============================================================"

mkdir -p "${BASE_PATH}/log" "${BASE_PATH}/tmp"

TMP_PREFIX="${BASE_PATH}/tmp/LOAD_MIG_MSTR"
TMP_CSV="${TMP_PREFIX}_CSV_$$.csv"
TMP_BODY="${TMP_PREFIX}_BODY_$$.sql"
TMP_INSERT_SQL="${TMP_PREFIX}_INSERT_$$.sql"
TMP_PREVIEW="${TMP_PREFIX}_PREVIEW_$$.txt"
TMP_OUT="${TMP_PREFIX}_OUT_$$.txt"

# --- Log File ---
LOGFILE="${BASE_PATH}/log/LOAD_MIG_MSTR_$(date '+%Y%m%d_%H%M%S').log"

# _out: Print to terminal and append to log file
_out() {
    printf "$@"
    printf "$@" >> ${LOGFILE}
}

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

_cleanup() {
    rm -f ${TMP_CSV} ${TMP_BODY} ${TMP_INSERT_SQL} ${TMP_PREVIEW} ${TMP_OUT}
}
trap _cleanup EXIT

# _run_sql <SQL_FILE> : run with the client for DB_TYPE (stdout + stderr)
_run_sql() {
    ${DB_CLIENT} -s "${DB_CONN}" @"$1" 2>&1
}

# _has_db_error <OUTPUT_FILE> : Oracle / Tibero / SQL*Plus error code in output
_has_db_error() {
    grep -Eq '(ORA|TBR|SP2)-[0-9]+' "$1"
}

# ============================================================
# 1. Build INSERT SQL from CSV
# ============================================================
_out "%s\n" "$SEP"
_log "Build INSERT SQL : ${CSV_FILE} (DB_TYPE=${DB_TYPE})"
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
    split(def_vals, a, " ")
    for (i in a) { split(a[i], kv, "="); defval[kv[1]] = kv[2] }
    split(num_cols, a, " ")
    for (i in a) numeric[a[i]] = 1
}

# --- header ---
NR == 1 {
    ncol = parse_csv($0, hdr)
    for (i = 1; i <= ncol; i++) {
        hdr[i] = toupper(hdr[i]); in_hdr[hdr[i]] = 1
        col_list = col_list (i > 1 ? ", " : "") hdr[i]
    }
    # default columns not in header are inserted with their default value
    for (c in defval) if (!(c in in_hdr)) {
        col_list = col_list ", " c
        extra_vals = extra_vals ", " sq defval[c] sq
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
        if (v == "" && (h in defval)) v = defval[h]
        disp[h] = v
        if (v == "")           sqlv = "NULL"
        else if (h in numeric) sqlv = v
        else                   { gsub(sq, sq sq, v); sqlv = sq v sq }
        vals = vals (i > 1 ? ", " : "") sqlv
    }
    printf "INSERT INTO %s (%s) VALUES (%s%s);\n", tab, col_list, vals, extra_vals > bodyfile
    printf "LINE %-5d %-30s %s.%s -> %s.%s [%s/%s]\n", NR, disp["MSTR_ID"], disp["SRC_OWNER"], disp["SRC_TABLE_NAME"], disp["TGT_OWNER"], disp["TGT_TABLE_NAME"], disp["MIG_TYPE"], disp["MIG_FULL"] > prevfile
}
EOF
)

: > ${TMP_BODY} ; : > ${TMP_PREVIEW}

awk -v sq="'" -v tab="${TARGET_TAB}" -v def_vals="${DEF_VALS}" -v num_cols="${NUM_COLS}" \
    -v bodyfile="${TMP_BODY}" -v prevfile="${TMP_PREVIEW}" \
    "${AWK_BUILD}" ${TMP_CSV}

TOTAL=$(wc -l < ${TMP_BODY} | tr -d ' ')
if [[ ${TOTAL} -eq 0 ]] ; then
    _fail "No data rows in ${CSV_FILE}"
    exit 1
fi
_ok "INSERT SQL built : ${TOTAL} row(s)"

# ============================================================
# 2. Preview and confirm
# ============================================================
_out "%s\n" "$SEP"
_log "INSERT preview"
_out "%s\n" "$SEP"
_out "  Target         : %s (%s)\n" "${TARGET_TAB}" "${DB_TYPE}"
_out "  Rows to INSERT : %s\n\n" "${TOTAL}"

_out "  --- TOP 5 ---\n"
head -5 ${TMP_PREVIEW} | while IFS= read -r _line ; do _out "  %s\n" "${_line}" ; done
if [[ ${TOTAL} -gt 5 ]] ; then
    _out "\n  --- BOTTOM 5 ---\n"
    tail -5 ${TMP_PREVIEW} | while IFS= read -r _line ; do _out "  %s\n" "${_line}" ; done
fi
_out "\n"

printf "Proceed with INSERT of %s row(s)? [y/N]: " "${TOTAL}"
read -r ANSWER
if [[ "${ANSWER}" != "y" && "${ANSWER}" != "Y" ]] ; then
    _log "INSERT cancelled by user"
    exit 0
fi

# ============================================================
# 3. Execute INSERT (all or nothing)
# ============================================================
_out "%s\n" "$SEP"
_log "Execute INSERT via ${DB_CLIENT}"
_out "%s\n" "$SEP"

{
    echo "SET DEFINE OFF"
    echo "SET FEEDBACK ON"
    echo "WHENEVER SQLERROR EXIT FAILURE ROLLBACK"
    cat ${TMP_BODY}
    echo "COMMIT;"
    echo "EXIT;"
} > ${TMP_INSERT_SQL}

_run_sql ${TMP_INSERT_SQL} > ${TMP_OUT}
RC=$?
cat ${TMP_OUT} >> ${LOGFILE}

if [[ ${RC} -ne 0 ]] || _has_db_error ${TMP_OUT} ; then
    # rows before the failing one print "1 row created." (sqlplus) / "1 row inserted." (tbsql)
    DONE=$(grep -c '^1 row' ${TMP_OUT})
    _fail "INSERT failed at row $((DONE + 1)) of ${TOTAL} - rolled back (rc=${RC})"
    sed -n "$((DONE + 1))p" ${TMP_PREVIEW} | while IFS= read -r _line ; do _out "  %s\n" "${_line}" ; done
    grep -E '(ORA|TBR|SP2)-[0-9]+' ${TMP_OUT} | while IFS= read -r _line ; do _out "  %s\n" "${_line}" ; done
    exit 1
fi

_ok "${TOTAL} row(s) inserted into ${TARGET_TAB}"
exit 0
