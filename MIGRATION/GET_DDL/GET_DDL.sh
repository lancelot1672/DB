#!/bin/bash
# ============================================================
# GET_DDL.sh
# GET_DDL dashboard (menu) for the 01 / 03.EXTRACT_*.sh scripts.
#   [SETUP] 0. Build MIG_TAB_LIST  *.lst in the current directory -> DBADM.MIG_TAB_LIST_{OWNER}
#                                  (+ TABLE / INDEX tablespace -> TBS_TAB / TBS_IND)
#                                  built schemas are recorded in GET_DDL_SCHEMA.json
#           1. MIG_TAB_LIST        grid of DBADM.MIG_TAB_LIST_{OWNER} (schemas of GET_DDL_SCHEMA.json)
#   [RUN]   2. Run one GET_DDL     (TABLE / CONSTRAINT_C / INDEX / CONSTRAINT_P)
#           3. Run all             TABLE -> CONSTRAINT_C -> INDEX -> CONSTRAINT_P
#   [VIEW]  4. Logs                ${BASE_PATH}/log/*.log
#           5. DDL output          ${BASE_PATH}/ddl/*.sql
#           6. Count by schema     latest result per OWNER / type (run history JSON)
#   [EXIT]  7. Quit
# Run history    : ${BASE_PATH}/log/GET_DDL_HISTORY.json (one object per step run)
# Built schemas  : ${BASE_PATH}/log/GET_DDL_SCHEMA.json  (one object per OWNER , [0] Build)
# Usage: GET_DDL.sh   (no argument)   , NO_COLOR=1 GET_DDL.sh : no color
# ============================================================

# --- Load environment variables ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [[ -f "${SCRIPT_DIR}/MIG.env" ]] ; then
    . ${SCRIPT_DIR}/MIG.env
else
    echo "[FAIL] MIG.env file not found: ${SCRIPT_DIR}/MIG.env"
    exit 1
fi

SEP="============================================================"
LINE="------------------------------------------------------------"

mkdir -p "${BASE_PATH}/log" "${BASE_PATH}/tmp" "${BASE_PATH}/ddl"

LIST_DIR="${PWD}"   # *.lst for [0] Build MIG_TAB_LIST : the directory GET_DDL.sh is started from
HIST_FILE="${BASE_PATH}/log/GET_DDL_HISTORY.json"
SCHEMA_FILE="${BASE_PATH}/log/GET_DDL_SCHEMA.json"
RUN_OUT="${BASE_PATH}/tmp/GET_DDL_RUN_$$.txt"
OWN_OUT="${BASE_PATH}/tmp/GET_DDL_OWNER_$$.txt"
LIST_OUT="${BASE_PATH}/tmp/GET_DDL_LIST_$$.txt"

# Step order of "Run all" : label (LABEL in each script) / script
STEP_LABELS=(TABLE CONSTRAINT_C INDEX CONSTRAINT_P)
STEP_SCRIPTS=(03.EXTRACT_TABLE.sh 03.EXTRACT_CONSTRAINT_C.sh 03.EXTRACT_INDEX.sh 03.EXTRACT_CONSTRAINT_P.sh)

# --- Screen ---
W=78            # screen width
HEADER_ROWS=8   # lines printed by _header
if [[ -t 1 && -z "${NO_COLOR}" ]] ; then
    C_0=$'\033[0m'  ; C_B=$'\033[1m'  ; C_DIM=$'\033[2m' ; C_RV=$'\033[7m'
    C_RD=$'\033[31m' ; C_GR=$'\033[32m' ; C_YL=$'\033[33m' ; C_CY=$'\033[36m'
else
    C_0= ; C_B= ; C_DIM= ; C_RV= ; C_RD= ; C_GR= ; C_YL= ; C_CY=
fi

# --- Log File ---
LOGFILE="${BASE_PATH}/log/GET_DDL_MENU_$(date '+%Y%m%d_%H%M%S').log"

# _out: Print to terminal and append to log file (colors stripped in the log)
_out() {
    printf "$@"
    printf "$@" | sed 's/\x1b\[[0-9;]*m//g' >> ${LOGFILE}
}

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()   { _out "[OK]   %s\n" "$*"; }
_fail() { _out "[FAIL] %s\n" "$*"; }

_cleanup() {
    rm -f ${RUN_OUT} ${OWN_OUT} ${LIST_OUT}
    printf '\033[?25h'
}
trap _cleanup EXIT
# Ctrl+C stops a running script and comes back to the menu
trap ':' INT

_clear() { clear 2>/dev/null || printf '\033[2J\033[H' ; }
_pause() { echo ; read -r -p "  Press Enter to return..." _ ; }
_tcols() { tput cols 2>/dev/null || echo 80 ; }
_tlines() { tput lines 2>/dev/null || echo 24 ; }

# ============================================================
# Common : drawing
# ============================================================
_rep() { (( $2 > 0 )) && printf '%*s' "$2" '' | tr ' ' "$1" ; }

# _fit <WIDTH> <TEXT> : cut TEXT to WIDTH , keep the tail ("..." + tail) : for paths
_fit() {
    local w=$1 s="$2"
    (( ${#s} > w )) && s="...${s: -$(( w - 3 ))}"
    printf '%s' "${s}"
}

# _cut <WIDTH> <TEXT> : cut TEXT to WIDTH , keep the head (head + "..")
_cut() {
    local w=$1 s="$2"
    (( ${#s} > w )) && s="${s:0:$(( w - 2 ))}.."
    printf '%s' "${s}"
}

_box_top()  { printf "+%s+\n" "$(_rep "${1:-=}" $(( W - 2 )))" ; }
_box_line() { printf "|  %-*s|\n" $(( W - 4 )) "$(_fit $(( W - 5 )) "$1")" ; }

# _title <TEXT> : screen title bar under the header
_title() {
    local t ; t=$(_cut $(( W - 6 )) "$1")
    printf "\n %s%s %s %s%s\n" "${C_B}${C_CY}" "==" "${t}" "$(_rep '=' $(( W - ${#t} - 5 )))" "${C_0}"
}

# _section <TEXT> : section line inside a screen
_section() {
    if [[ -z "$1" ]] ; then
        printf "  %s%s%s\n" "${C_DIM}" "$(_rep '-' $(( W - 4 )))" "${C_0}"
    else
        printf "  %s%s %s%s\n" "${C_YL}${C_B}" "$1" "$(_rep '-' $(( W - ${#1} - 4 )))" "${C_0}"
    fi
}

# _st <STATUS> <WIDTH> : status padded to WIDTH, colored
_st() {
    local c="${C_RD}"
    case "$1" in
        OK)   c="${C_GR}" ;;
        NONE) c="${C_DIM}" ;;
    esac
    printf "%s%-*s%s" "${c}" "$2" "$1" "${C_0}"
}

# _grid_lines <MAX WIDTH> <HEADER> : rows from stdin -> boxed grid lines on stdout
#   HEADER / rows = cells separated by "|"
#   header cell suffix  ">" : right-justified   "*" : narrowed last (e.g. TABLE_NAME)
#   output : top bar , header , "=" bar , rows ... , bottom bar
#   too wide : the widest column is narrowed first (down to 6 , "*" column down to 12)
_grid_lines() {
    awk -F'|' -v maxw="$1" -v head="$2" '
        function cell(v, wd, right) {
            if (length(v) > wd) v = substr(v, 1, wd - 2) ".."
            return right ? sprintf("%" wd "s", v) : sprintf("%-" wd "s", v)
        }
        BEGIN {
            nc = split(head, h, "|")
            for (i = 1 ; i <= nc ; i++) {
                rj[i] = 0 ; pri[i] = 0
                while (h[i] ~ /[>*]$/) {
                    if (h[i] ~ />$/) rj[i] = 1 ; else pri[i] = 1
                    h[i] = substr(h[i], 1, length(h[i]) - 1)
                }
                w[i] = length(h[i])
            }
        }
        { n++ ; for (i = 1 ; i <= nc ; i++) { d[n, i] = $i ; if (length($i) > w[i]) w[i] = length($i) } }
        END {
            for (i = 1 ; i <= nc ; i++) if (w[i] > (pri[i] ? 60 : 40)) w[i] = (pri[i] ? 60 : 40)
            total = 1
            for (i = 1 ; i <= nc ; i++) total += w[i] + 3
            while (total > maxw) {
                m = 0
                for (i = 1 ; i <= nc ; i++) {
                    if (w[i] <= (pri[i] ? 12 : 6)) continue
                    e = w[i] - (pri[i] ? 12 : 0)
                    if (m == 0 || e > em) { m = i ; em = e }
                }
                if (m == 0) break
                w[m]-- ; total--
            }
            bar = "+"
            for (i = 1 ; i <= nc ; i++) bar = bar sprintf("%" (w[i] + 2) "s", "") "+"
            gsub(/ /, "-", bar)
            bar2 = bar ; gsub(/-/, "=", bar2)
            line = "|"
            for (i = 1 ; i <= nc ; i++) line = line " " cell(h[i], w[i], rj[i]) " |"
            print bar ; print line ; print bar2
            for (r = 1 ; r <= n ; r++) {
                line = "|"
                for (i = 1 ; i <= nc ; i++) line = line " " cell(d[r, i], w[i], rj[i]) " |"
                print line
            }
            print bar
        }'
}

# _grid <HEADER> <ROW>... : print a static grid (indent 2)
_grid() {
    local head="$1" ; shift
    printf '%s\n' "$@" | _grid_lines $(( $(_tcols) - 3 )) "${head}" | sed 's/^/  /'
}

# _header : status panel on top of every screen
_header() {
    local sq="NOT FOUND"
    command -v sqlplus > /dev/null 2>&1 && sq="OK"
    _box_top "="
    printf "|  %s%-*s%s%*s  |\n" "${C_B}" 30 "GET_DDL DASHBOARD" "${C_0}" $(( W - 36 )) "$(date '+%Y-%m-%d %H:%M')"
    _box_top "-"
    _box_line "$(printf "%-10s: %-28s %-8s: %s" "DB_USER" "${DB_USER}" "sqlplus" "${sq}")"
    _box_line "$(printf "%-10s: %s" "BASE_PATH" "$(_fit $(( W - 17 )) "${BASE_PATH}")")"
    _box_line "$(printf "%-10s: %s run(s)  (log/%s)" "HISTORY" "$(_hist_cnt)" "$(basename "${HIST_FILE}")")"
    _box_line "$(printf "%-10s: %s" "LAST RUN" "$(_cut $(( W - 17 )) "$(_last_run)")")"
    _box_top "="
}

# ============================================================
# Common : input
# ============================================================
# _menu <TITLE> <HEADER> <ROW>... : grid menu
#   HEADER = column names separated by "|" (see _grid_lines)
#   ROW    = "KEY|cell|cell..." ; KEY (one char, optional, not j/k/q) selects the row directly
#   Up / Down (k / j) move , Enter select , KEY direct , q back
#   -> MENU_KEY / MENU_VAL (first cell) / MENU_IDX (row index) ; return 1 = back
_menu() {
    local title="$1" head="$2" ; shift 2
    local -a rows=("$@") keys=() cells=() g
    local r n i cur=0 top=0 vis key rest drawn=0 found hint=""

    for r in "${rows[@]}" ; do
        keys+=("${r%%|*}")
        cells+=("${r#*|}")
        [[ -n "${r%%|*}" ]] && hint="   [key] : direct"
    done
    n=${#rows[@]}
    mapfile -t g < <(printf '%s\n' "${cells[@]}" | _grid_lines $(( $(_tcols) - 4 )) "${head}")

    # visible rows : the grid scrolls when it is longer than the terminal
    vis=$(( $(_tlines) - HEADER_ROWS - 8 ))   # title 2 , grid head 3 , bottom 1 , hint 1 , spare 1
    (( vis < 3 )) && vis=3
    (( vis > n )) && vis=$n

    _title "${title}"
    printf "   %s\n" "${g[0]}" "${g[1]}" "${g[2]}"
    printf '\033[?25l'
    while true ; do
        (( cur < top )) && top=${cur}
        (( cur >= top + vis )) && top=$(( cur - vis + 1 ))

        (( drawn )) && printf '\033[%dA' "$(( vis + 2 ))"
        for (( i = top ; i < top + vis ; i++ )) ; do
            if (( i == cur )) ; then
                printf '\r\033[K %s>%s %s%s%s\n' "${C_B}${C_CY}" "${C_0}" "${C_RV}" "${g[i + 3]}" "${C_0}"
            else
                printf '\r\033[K   %s\n' "${g[i + 3]}"
            fi
        done
        printf '\r\033[K   %s\n' "${g[n + 3]}"
        printf '\r\033[K  %sUp/Down j/k : move   Enter : select%s   q : back   [%d/%d]%s\n' \
            "${C_DIM}" "${hint}" "$(( cur + 1 ))" "${n}" "${C_0}"
        drawn=1

        IFS= read -rsn1 key || { printf '\033[?25h' ; return 1 ; }
        if [[ "${key}" == $'\033' ]] ; then
            rest=""
            read -rsn2 -t 0.1 rest
            key="${key}${rest}"
        fi
        case "${key}" in
            $'\033[A'|$'\033OA'|k) (( cur > 0 )) && cur=$(( cur - 1 )) ; continue ;;
            $'\033[B'|$'\033OB'|j) (( cur < n - 1 )) && cur=$(( cur + 1 )) ; continue ;;
            "")                    break ;;
            q|Q|$'\033')           printf '\033[?25h' ; return 1 ;;
        esac
        # direct key
        found=-1
        for (( i = 0 ; i < n ; i++ )) ; do
            if [[ -n "${keys[i]}" && "${keys[i]^^}" == "${key^^}" ]] ; then found=${i} ; break ; fi
        done
        if (( found >= 0 )) ; then cur=${found} ; break ; fi
    done
    printf '\033[?25h'
    MENU_KEY="${keys[cur]}"
    MENU_VAL="${cells[cur]%%|*}"
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

# _ask_tbs <PROMPT> : tablespace name (upper-cased) or empty -> ASK_VAL
_ask_tbs() {
    while true ; do
        read -r -p "$1" ASK_VAL || return 1
        ASK_VAL=$(echo "${ASK_VAL}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
        [[ -z "${ASK_VAL}" || "${ASK_VAL}" =~ ^[A-Z][A-Z0-9_\$#]*$ ]] && return 0
        echo "    -> letters, digits, _ \$ # only, starting with a letter (Enter = none). Try again."
    done
}

# _confirm <PROMPT> : y/N
_confirm() {
    local a
    read -r -p "$1 (y/N) : " a
    [[ "${a}" =~ ^[yY]$ ]]
}

# _select_owner <SCREEN TITLE> : pick OWNER of DBADM.MIG_TAB_LIST_{OWNER} (from DBA_TABLES)
#   -> OWNER_LIST (one OWNER, or every OWNER with "ALL schemas") ; return 1 = cancelled
_select_owner() {
    local -a owners rows
    local o

    sqlplus -s ${DB_USER}/${DB_PASS} > ${OWN_OUT} 2>&1 <<_EOF
set pagesize 0
set feedback off
set heading off
set echo off
set verify off
SELECT SUBSTR(TABLE_NAME, 14)
  FROM DBA_TABLES
 WHERE OWNER = 'DBADM'
   AND TABLE_NAME LIKE 'MIG\_TAB\_LIST\_%' ESCAPE '\'
 ORDER BY 1;
exit
_EOF

    owners=()
    while IFS= read -r o ; do
        o=$(echo "${o}" | tr -d '[:space:]')
        [[ "${o}" =~ ^[A-Z0-9_\$#]+$ ]] && owners+=("${o}")
    done < ${OWN_OUT}

    _clear
    _header
    if (( ${#owners[@]} == 0 )) ; then
        _title "$1  :  schema"
        _section "No DBADM.MIG_TAB_LIST_{OWNER} found (or DB error)"
        sed 's/^/    /' ${OWN_OUT} | head -n 5
        echo
        _ask_name "  OWNER : " || return 1
        OWNER_LIST=("${ASK_VAL}")
        return 0
    fi

    rows=()
    for o in "${owners[@]}" ; do
        rows+=("||${o}|DBADM.MIG_TAB_LIST_${o}")
    done
    rows+=("A|A|ALL schemas|${#owners[@]} schema(s)" "T|T|Type OWNER|" "B|B|Back|")
    _menu "$1  :  select schema" "KEY|SCHEMA|LIST TABLE" "${rows[@]}" || return 1

    case "${MENU_KEY}" in
        A) OWNER_LIST=("${owners[@]}") ;;
        T) echo
           _ask_name "  OWNER : " || return 1
           OWNER_LIST=("${ASK_VAL}") ;;
        B) return 1 ;;
        *) OWNER_LIST=("${owners[MENU_IDX]}") ;;
    esac
    return 0
}

# ============================================================
# JSON files : one object per line -> read with grep / awk (no jq needed)
# ============================================================
_json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' ; }

# _json_join : object lines on stdin -> JSON array on stdout
_json_join() {
    echo "["
    awk 'NR > 1 { print prev "," } { prev = $0 } END { if (NR) print prev }'
    echo "]"
}

# awk helper : v("key") = value of a string / number field in one JSON line
AWK_V='
function v(k) {
    if (match($0, "\"" k "\":\"[^\"]*\"")) return substr($0, RSTART + length(k) + 4, RLENGTH - length(k) - 5)
    if (match($0, "\"" k "\":-?[0-9]+"))   return substr($0, RSTART + length(k) + 3, RLENGTH - length(k) - 3)
    return ""
}'

# ------------------------------------------------------------
# Built schemas (GET_DDL_SCHEMA.json) : written by [0] Build , read by [1] MIG_TAB_LIST
#   {"owner":"HR","table":"DBADM.MIG_TAB_LIST_HR","tables":2,"tbs_tab":"..","tbs_ind":"..",
#    "list_file":"..","created":"YYYY-MM-DD HH:MI:SS"}
#   building the same OWNER again replaces its object
# ------------------------------------------------------------
# _schema_add <LIST_FILE> <TBS_TAB> <TBS_IND> : record every OWNER of LIST_FILE
_schema_add() {
    local lst="$1" tt="$2" ti="$3" tmp="${SCHEMA_FILE}.tmp.$$" now o c
    now=$(date '+%Y-%m-%d %H:%M:%S')
    awk 'NF >= 2 { if (!($1 in c)) o[++n] = $1 ; c[$1]++ } END { for (i = 1 ; i <= n ; i++) print o[i], c[o[i]] }' \
        "${lst}" > ${OWN_OUT}
    {
        [[ -f "${SCHEMA_FILE}" ]] && grep '^  {' "${SCHEMA_FILE}" | sed 's/,$//' \
            | grep -v -F -f <(awk '{ printf "\"owner\":\"%s\"\n", $1 }' ${OWN_OUT})
        while read -r o c ; do
            printf '  {"owner":"%s","table":"DBADM.MIG_TAB_LIST_%s","tables":%d,"tbs_tab":"%s","tbs_ind":"%s","list_file":"%s","created":"%s"}\n' \
                "${o}" "${o}" "${c}" "${tt}" "${ti}" "$(_json_str "${lst}")" "${now}"
        done < ${OWN_OUT}
    } | _json_join > "${tmp}" && mv "${tmp}" "${SCHEMA_FILE}"
}

# _select_schema <SCREEN TITLE> : pick one OWNER recorded in GET_DDL_SCHEMA.json -> OWNER_LIST ; return 1 = cancelled
_select_schema() {
    local -a owners rows
    local o tb cr
    owners=() ; rows=()
    if [[ -s "${SCHEMA_FILE}" ]] ; then
        while IFS='|' read -r o tb cr ; do
            [[ -z "${o}" ]] && continue
            owners+=("${o}")
            rows+=("|${o}|${tb}|${cr}")
        done <<< "$(grep '^  {' "${SCHEMA_FILE}" | awk "${AWK_V}"'{ print v("owner") "|" v("tables") "|" v("created") }' | sort)"
    fi

    _clear
    _header
    if (( ${#owners[@]} == 0 )) ; then
        _title "$1  :  schema"
        _section "No schema built yet  ([0] Build MIG_TAB_LIST)"
        printf "    %s\n" "$(_fit $(( W - 6 )) "${SCHEMA_FILE}")"
        _pause
        return 1
    fi

    rows+=("B|Back||")
    _menu "$1  :  select schema  (GET_DDL_SCHEMA.json)" "SCHEMA|TABLES>|CREATED" "${rows[@]}" || return 1
    [[ "${MENU_KEY}" == "B" ]] && return 1
    OWNER_LIST=("${owners[MENU_IDX]}")
    return 0
}

# ------------------------------------------------------------
# Run history (GET_DDL_HISTORY.json)
#   {"run_id":"..","mode":"ALL","time":"..","owner":"..","type":"TABLE","status":"OK",
#    "rc":0,"obj_cnt":10,"ddl_cnt":10,"elapsed_sec":3,"ddl_file":"..","log_file":".."}
#   status : OK / NONE (no object of that type) / FAIL
#   obj_cnt : objects requested (GET_DDL statements) , ddl_cnt : statements in the DDL file
# ------------------------------------------------------------
# _hist_add <RUN_ID> <MODE> <OWNER> <TYPE> <STATUS> <RC> <OBJ_CNT> <DDL_CNT> <SEC> <DDL_FILE> <LOG_FILE>
_hist_add() {
    local obj tmp="${HIST_FILE}.tmp.$$"
    obj=$(printf '{"run_id":"%s","mode":"%s","time":"%s","owner":"%s","type":"%s","status":"%s","rc":%d,"obj_cnt":%d,"ddl_cnt":%d,"elapsed_sec":%d,"ddl_file":"%s","log_file":"%s"}' \
        "$1" "$2" "$(date '+%Y-%m-%d %H:%M:%S')" "$3" "$4" "$5" "$6" "$7" "$8" "$9" \
        "$(_json_str "${10}")" "$(_json_str "${11}")")
    { [[ -f "${HIST_FILE}" ]] && grep '^  {' "${HIST_FILE}" | sed 's/,$//' ; echo "  ${obj}" ; } \
        | _json_join > "${tmp}" && mv "${tmp}" "${HIST_FILE}"
}

_hist_cnt() { [[ -f "${HIST_FILE}" ]] && grep -c '^  {' "${HIST_FILE}" || echo 0 ; }

# _last_run : "<time>  <mode>  <owners>  ok N / none N / fail N" of the last run_id
_last_run() {
    [[ -s "${HIST_FILE}" ]] || { printf -- "-" ; return 0 ; }
    grep '^  {' "${HIST_FILE}" | awk "${AWK_V}"'
        { id[NR] = v("run_id") ; line[NR] = $0 }
        END {
            if (NR == 0) { printf "-" ; exit }
            last = id[NR]
            for (i = 1 ; i <= NR ; i++) {
                if (id[i] != last) continue
                $0 = line[i]
                if (t == "") { t = substr(v("time"), 6, 11) ; m = v("mode") }
                o = v("owner")
                if (!(o in seen)) { seen[o] = 1 ; no++ ; if (no <= 3) ow = ow (ow == "" ? "" : ",") o }
                cnt[v("status")]++
            }
            if (no > 3) ow = ow ",+" (no - 3)
            printf "%s  %-6s %s  (ok %d / none %d / fail %d)", t, m, ow, cnt["OK"], cnt["NONE"], cnt["FAIL"]
        }'
}

# ============================================================
# Setup
# ============================================================
# [0] Build DBADM.MIG_TAB_LIST_{OWNER} : pick a *.lst in the current directory ,
#     ask TABLE / INDEX tablespace , run 01.CREATE_MIG_TAB_LIST_BY_OWNER.sh ,
#     on success record its OWNERs in GET_DDL_SCHEMA.json
_menu_build() {
    local -a files rows
    local f lst tt ti rc
    _clear
    _header
    files=()
    while IFS= read -r f ; do
        [[ -f "${f}" ]] && files+=("${f}")
    done <<< "$(ls -t "${LIST_DIR}"/*.lst 2>/dev/null)"
    if (( ${#files[@]} == 0 )) ; then
        _title "0. BUILD MIG_TAB_LIST"
        _section "No *.lst file"
        printf "    %s\n" "$(_fit $(( W - 6 )) "${LIST_DIR}")"
        printf "    each line = OWNER TABLE_NAME (space separated)\n"
        _pause
        return 0
    fi

    rows=()
    for f in "${files[@]}" ; do
        rows+=("|$(basename "${f}")|$(date -r "${f}" '+%m-%d %H:%M' 2>/dev/null)|$(awk 'NF >= 2' "${f}" | wc -l | tr -d ' ')|$(awk 'NF >= 2 { print $1 }' "${f}" | sort -u | wc -l | tr -d ' ')")
    done
    rows+=("B|Back|||")
    _menu "0. BUILD MIG_TAB_LIST  :  select list file" "LIST FILE*|MODIFIED|TABLES>|OWNERS>" "${rows[@]}" || return 0
    [[ "${MENU_KEY}" == "B" ]] && return 0
    lst="${files[MENU_IDX]}"

    _clear
    _header
    _title "0. BUILD MIG_TAB_LIST  :  $(basename "${lst}")"
    mapfile -t rows < <(awk 'NF >= 2 { if (!($1 in c)) o[++n] = $1 ; c[$1]++ }
                             END { for (i = 1 ; i <= n ; i++) printf "%s|%d|DBADM.MIG_TAB_LIST_%s\n", o[i], c[o[i]], o[i] }' "${lst}")
    _grid "OWNER|TABLES>|LIST TABLE" "${rows[@]}"
    echo
    _section "TABLESPACE  (Enter = none : no tablespace clause in DDL)"
    _ask_tbs "    TABLE TABLESPACE : " || return 0 ; tt="${ASK_VAL}"
    _ask_tbs "    INDEX TABLESPACE : " || return 0 ; ti="${ASK_VAL}"
    echo
    _grid "PLAN|VALUE" \
        "List file|$(_fit 50 "${lst}")" \
        "TABLE TABLESPACE|${tt:-(none)}" \
        "INDEX TABLESPACE|${ti:-(none)}" \
        "Script|01.CREATE_MIG_TAB_LIST_BY_OWNER.sh" \
        "Steps|CREATE -> INSERT preview -> y/N"
    echo
    _confirm "  Create DBADM.MIG_TAB_LIST_{OWNER}" || return 0

    echo
    _log "BUILD : ${lst} (TBS_TAB=${tt:-none} , TBS_IND=${ti:-none})"
    : > ${RUN_OUT}
    bash "${SCRIPT_DIR}/01.CREATE_MIG_TAB_LIST_BY_OWNER.sh" "${lst}" "${tt}" "${ti}" 2>&1 | tee "${RUN_OUT}"
    rc=${PIPESTATUS[0]}
    if (( rc == 0 )) && grep -q 'Per-owner MIG_TAB_LIST tables created and' ${RUN_OUT} ; then
        _schema_add "${lst}" "${tt}" "${ti}"
        _ok "Schema(s) recorded : ${SCHEMA_FILE}"
    else
        _log "Schema(s) not recorded (build not completed , rc=${rc})"
    fi
    _log "BUILD end (rc=${rc})"
    _pause
}

# [1] MIG_TAB_LIST : DBADM.MIG_TAB_LIST_{OWNER} as a grid (that table only)
#   - schema : one recorded in GET_DDL_SCHEMA.json by [0] Build
#   - columns : SEQ / OWNER / TABLE_NAME / USE_YN / TBS_TAB / TBS_IND
#     (an old list table without TBS_TAB / TBS_IND shows them empty)
#   - first screen fills the terminal , then Enter : next screen (a : all , q : stop)
_screen_list() {
    local owner tab tbs lines page cnt key i last total stopped=0
    local -a grid
    _select_schema "1. MIG_TAB_LIST" || return 0
    owner="${OWNER_LIST[0]}"
    tab="DBADM.MIG_TAB_LIST_${owner}"

    # old list tables have no TBS_TAB / TBS_IND
    tbs=$(sqlplus -s ${DB_USER}/${DB_PASS} <<_EOF | tr -d '[:space:]'
set pagesize 0 feedback off heading off verify off
SELECT COUNT(*) FROM DBA_TAB_COLUMNS
 WHERE OWNER = 'DBADM' AND TABLE_NAME = 'MIG_TAB_LIST_${owner}' AND COLUMN_NAME IN ('TBS_TAB', 'TBS_IND');
exit
_EOF
)
    if [[ "${tbs}" == "2" ]] ; then tbs="TBS_TAB || '|' || TBS_IND" ; else tbs="'|'" ; fi

    sqlplus -s ${DB_USER}/${DB_PASS} > ${LIST_OUT} 2>&1 <<_EOF
set pagesize 0
set linesize 4000
set trimout on
set trimspool on
set feedback off
set heading off
set echo off
set verify off
SELECT 'R|' || SEQ || '|' || OWNER || '|' || TABLE_NAME || '|' || USE_YN || '|' || ${tbs}
  FROM ${tab}
 ORDER BY SEQ;
exit
_EOF

    _clear
    _header
    _title "1. MIG_TAB_LIST  :  ${tab}"
    total=$(grep -c '^R|' ${LIST_OUT})
    if (( total == 0 )) ; then
        _section "No row (or DB error)"
        sed -e '/^[[:space:]]*$/d' -e 's/^/    /' ${LIST_OUT} | head -n 8
        _pause
        return 0
    fi

    # grid[0..2] = head , then rows , last = bottom line
    mapfile -t grid < <(grep '^R|' ${LIST_OUT} | sed 's/^R|//' \
        | _grid_lines $(( $(_tcols) - 3 )) "SEQ>|OWNER|TABLE_NAME*|USE_YN|TBS_TAB|TBS_IND")
    printf "    rows : %s\n" "${total}"
    printf "  %s\n" "${grid[0]}" "${grid[1]}" "${grid[2]}"

    # first screen : what is left under header / title / rows line / grid head ; then one full screen per Enter
    lines=$(_tlines)
    page=$(( lines - HEADER_ROWS - 2 - 1 - 3 - 1 ))   # title 2 , rows 1 , grid head 3 , prompt 1
    (( page < 3 )) && page=3
    last=$(( ${#grid[@]} - 1 ))
    cnt=0
    for (( i = 3 ; i < last ; i++ )) ; do
        if (( cnt >= page )) ; then
            printf "  %s-- %d / %d rows   Enter : more   a : all   q : stop --%s" "${C_RV}" $(( i - 3 )) "${total}" "${C_0}"
            IFS= read -rsn1 key
            printf '\r\033[K'
            case "${key}" in
                q|Q) stopped=1 ; break ;;
                a|A) page=999999999 ;;
                *)   page=$(( lines - 1 )) ;;
            esac
            cnt=0
        fi
        printf "  %s\n" "${grid[i]}"
        cnt=$(( cnt + 1 ))
    done
    printf "  %s\n" "${grid[last]}"
    (( stopped )) && printf "  %s(stopped : %d / %d rows shown)%s\n" "${C_DIM}" $(( i - 3 )) "${total}" "${C_0}"
    _pause
}

# ============================================================
# Run
# ============================================================
# _run_step <RUN_ID> <MODE> <OWNER> <STEP_IDX> <NO> <TOTAL> : run one 03.EXTRACT_*.sh , record history
#   -> SUMMARY += "owner|label|status|obj|ddl|sec"
_run_step() {
    local run_id="$1" mode="$2" owner="$3"
    local label=${STEP_LABELS[$4]} script=${STEP_SCRIPTS[$4]}
    local rc status obj ddl_cnt=0 ddl_file log_file t0 sec

    echo
    _out "  %s[ %d/%d ]  %s : %s%s   %s(%s)%s\n" "${C_B}${C_CY}" "$5" "$6" "${owner}" "${label}" "${C_0}" "${C_DIM}" "${script}" "${C_0}"
    _out "  %s\n" "$(_rep '-' $(( W - 4 )))"
    : > ${RUN_OUT}
    t0=${SECONDS}
    bash "${SCRIPT_DIR}/${script}" "${owner}" 2>&1 | sed 's/^/    /' | tee -a "${LOGFILE}" "${RUN_OUT}"
    rc=${PIPESTATUS[0]}
    sec=$(( SECONDS - t0 ))

    # "[OK]   <LABEL> DDL extracted (<N> object(s)) : <DDL_FILE>"
    obj=$(sed -n 's/.*DDL extracted (\([0-9]*\) object(s)).*/\1/p' ${RUN_OUT} | tail -n 1)
    ddl_file=$(sed -n 's/.*DDL extracted ([0-9]* object(s)) : //p' ${RUN_OUT} | tail -n 1)
    log_file=$(ls -t "${BASE_PATH}"/log/EXTRACT_${label}_*.log 2>/dev/null | head -n 1)

    if (( rc == 0 )) && [[ -f "${ddl_file}" ]] ; then
        status=OK
        ddl_cnt=$(grep -c ';$' "${ddl_file}")
    elif grep -q "No ${label} found" ${RUN_OUT} && ! grep -qE 'ORA-[0-9]|SP2-[0-9]|command not found' ${RUN_OUT} ; then
        status=NONE
    else
        status=FAIL
    fi
    obj=${obj:-0}

    _hist_add "${run_id}" "${mode}" "${owner}" "${label}" "${status}" "${rc}" \
              "${obj}" "${ddl_cnt}" "${sec}" "${ddl_file}" "${log_file}"
    _out "  -> %s   object %s , ddl %s , %ss\n" "$(_st "${status}" 4)" "${obj}" "${ddl_cnt}" "${sec}"
    SUMMARY+=("${owner}|${label}|${status}|${obj}|${ddl_cnt}|${sec}")
}

# _print_summary <TITLE> : result table of SUMMARY
_print_summary() {
    local s o t st ob dd sc ok=0 none=0 fail=0 bar
    bar="  +$(_rep '-' 20)+$(_rep '-' 14)+$(_rep '-' 8)+$(_rep '-' 8)+$(_rep '-' 8)+$(_rep '-' 7)+"
    _title "$1  :  result"
    _out "%s\n" "${bar}"
    _out "  | %-18s | %-12s | %-6s | %6s | %6s | %5s |\n" "OWNER" "TYPE" "STATUS" "OBJECT" "DDL" "TIME"
    _out "%s\n" "${bar//-/=}"
    for s in "${SUMMARY[@]}" ; do
        IFS='|' read -r o t st ob dd sc <<< "${s}"
        case "${st}" in OK) ok=$(( ok + 1 )) ;; NONE) none=$(( none + 1 )) ;; *) fail=$(( fail + 1 )) ;; esac
        [[ "${st}" == "OK" && "${ob}" != "${dd}" ]] && dd="${C_YL}$(printf '%5s!' "${dd}")${C_0}" || dd=$(printf '%6s' "${dd}")
        _out "  | %-18s | %-12s | %s | %6s | %s | %4ss |\n" "${o:0:18}" "${t}" "$(_st "${st}" 6)" "${ob}" "${dd}" "${sc}"
    done
    _out "%s\n" "${bar}"
    _out "  %sOK %d%s   %sNONE %d%s   %sFAIL %d%s\n" "${C_GR}" ${ok} "${C_0}" "${C_DIM}" ${none} "${C_0}" "${C_RD}" ${fail} "${C_0}"
    _out "  DDL     : %s/ddl\n" "${BASE_PATH}"
    _out "  history : %s\n" "${HIST_FILE}"
}

# [2] Run one GET_DDL
_menu_run_one() {
    local i idx owner run_id no=0
    local -a rows=()
    _clear
    _header
    for (( i = 0 ; i < ${#STEP_LABELS[@]} ; i++ )) ; do
        rows+=("$(( i + 1 ))|$(( i + 1 ))|${STEP_LABELS[i]}|${STEP_SCRIPTS[i]}")
    done
    rows+=("B|B|Back|")
    _menu "2. RUN ONE  :  select type" "KEY|TYPE|SCRIPT" "${rows[@]}" || return 0
    [[ "${MENU_KEY}" == "B" ]] && return 0
    idx=${MENU_IDX}

    _select_owner "2. RUN ONE  ${STEP_LABELS[idx]}" || return 0

    _clear
    _header
    _title "2. RUN ONE  :  ${STEP_LABELS[idx]}  x  ${#OWNER_LIST[@]} schema(s)"
    run_id="$(date '+%Y%m%d_%H%M%S')_$$"
    SUMMARY=()
    _log "START ${STEP_LABELS[idx]} : ${OWNER_LIST[*]} (run_id=${run_id})"
    for owner in "${OWNER_LIST[@]}" ; do
        no=$(( no + 1 ))
        _run_step "${run_id}" SINGLE "${owner}" ${idx} ${no} ${#OWNER_LIST[@]}
    done
    _print_summary "2. RUN ONE"
    _pause
}

# [3] Run all : TABLE -> CONSTRAINT_C -> INDEX -> CONSTRAINT_P
_menu_run_all() {
    local i owner run_id order no=0 total
    _select_owner "3. RUN ALL" || return 0

    total=$(( ${#OWNER_LIST[@]} * ${#STEP_LABELS[@]} ))
    order=$(printf ' > %s' "${STEP_LABELS[@]}")
    _clear
    _header
    _title "3. RUN ALL  :  plan"
    _grid "PLAN|VALUE" \
        "Schema|${OWNER_LIST[*]}" \
        "Schemas|${#OWNER_LIST[@]}" \
        "Order|${order# > }" \
        "Steps|${total}" \
        "Output|$(_fit 50 "${BASE_PATH}/ddl")"
    echo
    _confirm "  Run all GET_DDL" || return 0

    _clear
    _header
    _title "3. RUN ALL  :  ${#OWNER_LIST[@]} schema(s) x ${#STEP_LABELS[@]} = ${total} step(s)"
    run_id="$(date '+%Y%m%d_%H%M%S')_$$"
    SUMMARY=()
    _log "START ALL : ${OWNER_LIST[*]} (run_id=${run_id})"
    for owner in "${OWNER_LIST[@]}" ; do
        for (( i = 0 ; i < ${#STEP_LABELS[@]} ; i++ )) ; do
            no=$(( no + 1 ))
            _run_step "${run_id}" ALL "${owner}" ${i} ${no} ${total}
        done
    done
    _print_summary "3. RUN ALL"
    _pause
}

# ============================================================
# View
# ============================================================
# _view_files <TITLE> <FILE>... : newest 30 files , pick one to view
_view_files() {
    local title="$1" ; shift
    local -a files rows
    local f sz st
    while true ; do
        _clear
        _header
        files=()
        while IFS= read -r f ; do
            [[ -f "${f}" ]] && files+=("${f}")
        done <<< "$(ls -t "$@" 2>/dev/null | head -n 30)"
        if (( ${#files[@]} == 0 )) ; then
            _title "${title}"
            _section "(none)"
            _pause
            return 0
        fi
        # STMT (statements in the file) only for DDL output (*.sql)
        rows=()
        for f in "${files[@]}" ; do
            sz=$(wc -c < "${f}" | tr -d ' ')
            (( sz > 99999 )) && sz="$(( sz / 1024 ))K"
            st=""
            [[ "${f}" == *.sql ]] && st="|$(grep -c ';$' "${f}")"
            rows+=("|$(basename "${f}")|$(date -r "${f}" '+%m-%d %H:%M' 2>/dev/null)|${sz}${st}")
        done
        if [[ "${files[0]}" == *.sql ]] ; then
            rows+=("B|Back|||")
            _menu "${title}  (newest ${#files[@]})" "FILE*|MODIFIED|SIZE>|STMT>" "${rows[@]}" || return 0
        else
            rows+=("B|Back||")
            _menu "${title}  (newest ${#files[@]})" "FILE*|MODIFIED|SIZE>" "${rows[@]}" || return 0
        fi
        [[ "${MENU_KEY}" == "B" ]] && return 0
        _clear
        if command -v less > /dev/null 2>&1 ; then
            less "${files[MENU_IDX]}"
        else
            tail -n 60 "${files[MENU_IDX]}"
            _pause
        fi
    done
}

# [6] Count by schema : latest result per OWNER / type + recent runs
_screen_count() {
    local bar
    _clear
    _header
    _title "6. COUNT BY SCHEMA"
    if [[ ! -s "${HIST_FILE}" ]] ; then
        _section "No run history"
        printf "    %s\n" "${HIST_FILE}"
        _pause
        return 0
    fi

    _section "LATEST OBJECT COUNT"
    bar="  +$(_rep '-' 20)+$(_rep '-' 9)+$(_rep '-' 9)+$(_rep '-' 9)+$(_rep '-' 9)+$(_rep '-' 13)+"
    printf "%s\n" "${bar}"
    printf "  | %-18s | %7s | %7s | %7s | %7s | %-11s |\n" "OWNER" "TABLE" "CON_C" "INDEX" "CON_P" "LAST RUN"
    printf "%s\n" "${bar//-/=}"
    grep '^  {' "${HIST_FILE}" | awk -v R="${C_RD}" -v Y="${C_YL}" -v D="${C_DIM}" -v Z="${C_0}" "${AWK_V}"'
        {
            o = v("owner") ; t = v("type") ; s = v("status")
            if      (s == "OK" && v("ddl_cnt") != v("obj_cnt")) c = Y sprintf("%7s", v("obj_cnt") "/" v("ddl_cnt") "!") Z
            else if (s == "OK")   c = sprintf("%7s", v("obj_cnt"))
            else if (s == "NONE") c = D sprintf("%7s", "0") Z
            else                  c = R sprintf("%7s", "FAIL") Z
            cell[o, t] = c ; last[o] = substr(v("time"), 6, 11) ; seen[o] = 1
        }
        END {
            n = split("TABLE CONSTRAINT_C INDEX CONSTRAINT_P", ty, " ")
            for (o in seen) {
                printf "  | %-18s |", substr(o, 1, 18)
                for (i = 1 ; i <= n ; i++) printf " %s |", ((o, ty[i]) in cell) ? cell[o, ty[i]] : D sprintf("%7s", "-") Z
                printf " %-11s |\n", last[o]
            }
        }' | sort
    printf "%s\n" "${bar}"
    printf "  %sN = object count   0 = none   - = not run   N/M! = object N , M stmt in DDL file%s\n" "${C_DIM}" "${C_0}"
    echo

    _section "RECENT RUNS (last 10)"
    bar="  +$(_rep '-' 13)+$(_rep '-' 8)+$(_rep '-' 14)+$(_rep '-' 14)+$(_rep '-' 6)+$(_rep '-' 7)+$(_rep '-' 6)+"
    printf "%s\n" "${bar}"
    printf "  | %-11s | %-6s | %-12s | %-12s | %-4s | %5s | %4s |\n" "TIME" "MODE" "OWNER" "TYPE" "STAT" "OBJ" "SEC"
    printf "%s\n" "${bar//-/=}"
    grep '^  {' "${HIST_FILE}" | tail -n 10 | awk -v R="${C_RD}" -v G="${C_GR}" -v D="${C_DIM}" -v Z="${C_0}" "${AWK_V}"'
        {
            s = v("status") ; c = (s == "OK") ? G : ((s == "NONE") ? D : R)
            printf "  | %-11s | %-6s | %-12s | %-12s | %s%-4s%s | %5s | %4s |\n",
                   substr(v("time"), 6, 11), v("mode"), substr(v("owner"), 1, 12), substr(v("type"), 1, 12),
                   c, s, Z, v("obj_cnt"), v("elapsed_sec")
        }'
    printf "%s\n" "${bar}"
    _pause
}

# ============================================================
# Main
# ============================================================
if [[ -n "$1" ]] ; then
    echo "Usage: $0   (no argument = menu)"
    exit 1
fi

_log "Menu start"
while true ; do
    _clear
    _header
    MAIN=(
        "0|SETUP|0|Build MIG_TAB_LIST|*.lst + tablespace -> MIG_TAB_LIST"
        "1||1|MIG_TAB_LIST|grid of built schemas (json)"
        "2|RUN|2|Run one|TABLE / CON_C / INDEX / CON_P"
        "3||3|Run all|TABLE > CON_C > INDEX > CON_P"
        "4|VIEW|4|Logs|log/*.log"
        "5||5|DDL output|ddl/*.sql"
        "6||6|Count by schema|latest count per schema (history)"
        "7|EXIT|7|Quit|"
    )
    _menu "MAIN MENU" "GROUP|KEY|MENU|DESCRIPTION" "${MAIN[@]}" || break
    case "${MENU_KEY}" in
        0) _menu_build ;;
        1) _screen_list ;;
        2) _menu_run_one ;;
        3) _menu_run_all ;;
        4) _view_files "4. LOGS  (BASE_PATH/log)" "${BASE_PATH}"/log/*.log ;;
        5) _view_files "5. DDL OUTPUT  (BASE_PATH/ddl)" "${BASE_PATH}"/ddl/*.sql ;;
        6) _screen_count ;;
        *) break ;;
    esac
done
_log "Menu end"
exit 0
