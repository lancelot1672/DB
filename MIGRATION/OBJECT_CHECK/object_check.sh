#!/bin/bash
# ============================================================
# object_check.sh  —  ASIS <-> TOBE OBJECT verification (v1, unified)
#
# Flow:
#   STEP 0 : DBADM.MIG_TAB_LIST 의 OWNER별 TABLE_COUNT 확인 (진행 여부 Y/N)
#   STEP 1 : ASIS dictionary  -> DBADM.DBA_ASIS_*        (via DB LINK)
#   STEP 2 : TOBE dictionary  -> DBADM.DBA_TOBE_*        (local)
#   STEP 3 : ASIS object count -> DBADM.MIG_OBJ_CNT_ASIS (local)
#   STEP 4 : TOBE object count -> DBADM.MIG_OBJ_CNT_TOBE (local)
#   STEP 5 : ASIS <-> TOBE GAP report                   (read-only)
#
# Rules:
#   - Each step PRINTS its SQL, then requires an explicit Y or N
#     (bare Enter / other input re-prompts; no accidental advance).
#   - After a run, a COMPLETION CHECKLIST of the step's sub-tasks is shown.
#   - If ANY sub-task is FAIL, the pipeline HALTS (no next step).
#   - The ASIS DB LINK is chosen from DBA_DB_LINKS via arrow-key menu.
#     The source sql/*.sql keep the ASIS dictionary views link-free; the
#     shell appends the chosen link (DBA_TABLES -> DBA_TABLES@<DBLINK>) at
#     runtime into a tmp copy (originals untouched).
#
# Usage: ./object_check.sh
# ============================================================

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SEP="============================================================"
SUB="------------------------------------------------------------"

DBLINK=""
TMP_FILES=""

# ASIS remote source dictionary views. In link steps the chosen DB LINK is
# appended to each ( DBA_TABLES -> DBA_TABLES@<DBLINK> ) at runtime.
# The source sql/*.sql keep these views link-free; the shell injects the link.
OC_REMOTE_VIEWS=(DBA_CONSTRAINTS DBA_TABLES DBA_TAB_COLUMNS DBA_INDEXES \
                 DBA_TAB_PARTITIONS DBA_IND_PARTITIONS DBA_OBJECTS)

declare -A STATUS   # STATUS[n]=OK|SKIP|FAIL for the final summary

# ------------------------------------------------------------
# Load environment (.env)
# ------------------------------------------------------------
if [[ -f "${SCRIPT_DIR}/.env" ]] ; then
    . "${SCRIPT_DIR}/.env"
else
    echo "[FAIL] .env not found: ${SCRIPT_DIR}/.env  (copy .env.example)"
    exit 1
fi
: "${DB_USER:?DB_USER not set in .env}"
: "${DB_PASS:?DB_PASS not set in .env}"
: "${BASE_PATH:?BASE_PATH not set in .env}"
mkdir -p "${BASE_PATH}/log" "${BASE_PATH}/tmp"

LOGFILE="${BASE_PATH}/log/OBJECT_CHECK_$(date '+%Y%m%d_%H%M%S').log"

# ------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------
_out()   { printf "$@"; printf "$@" >> "${LOGFILE}"; }
_log()   { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()    { _out "[OK]   %s\n" "$*"; }
_fail()  { _out "[FAIL] %s\n" "$*"; }
# _emit: print a (possibly multi-line) block to terminal AND log, safely.
_emit()  { printf '%s\n' "$1"; printf '%s\n' "$1" >> "${LOGFILE}"; }

_cleanup() { [[ -n "${TMP_FILES}" ]] && rm -f ${TMP_FILES} ; }
trap _cleanup EXIT

# ------------------------------------------------------------
# finish <exit_code> : print step summary and exit.
# ------------------------------------------------------------
finish() {
    local code="$1" s
    _out "\n%s\n" "$SEP"
    _out "  OBJECT_CHECK 단계별 완료 현황\n"
    _out "%s\n" "$SEP"
    for s in 0 1 2 3 4 5 ; do
        _out "  STEP %s : %s\n" "${s}" "${STATUS[$s]:-N/A}"
    done
    _out "%s\n" "$SEP"
    if [[ "${code}" -eq 0 ]] ; then
        _ok "OBJECT_CHECK finished  (log: ${LOGFILE})"
    else
        _fail "OBJECT_CHECK aborted  (log: ${LOGFILE})"
    fi
    exit "${code}"
}

# ------------------------------------------------------------
# confirm "question" : require an explicit Y or N.
#   bare Enter / other input re-prompts. Y->0, N->1.
# ------------------------------------------------------------
confirm() {
    local prompt="${1:-Proceed?}" ans
    while true ; do
        printf "%s [Y/N]: " "${prompt}" > /dev/tty
        read -r ans < /dev/tty
        case "${ans}" in
            y|Y) return 0 ;;
            n|N) return 1 ;;
            *)   printf "  Y 또는 N 을 입력하세요.\n" > /dev/tty ;;
        esac
    done
}

# ------------------------------------------------------------
# select_menu "Title" item1 item2 ...  -> chosen item to stdout
# ------------------------------------------------------------
select_menu() {
    local title="$1" ; shift
    local options=("$@")
    local n=${#options[@]}
    local cur=0 key i
    [[ $n -eq 0 ]] && return 1

    printf "\n%s\n" "${title}"                                > /dev/tty
    printf "  (Up/Down = move, Enter = select, q = cancel)\n" > /dev/tty

    while true ; do
        for ((i=0; i<n; i++)) ; do
            if [[ $i -eq $cur ]] ; then
                printf "\033[K  \033[7m> %s\033[0m\n" "${options[$i]}" > /dev/tty
            else
                printf "\033[K    %s\n" "${options[$i]}"               > /dev/tty
            fi
        done
        IFS= read -rsn1 key < /dev/tty
        case "$key" in
            $'\x1b')
                read -rsn2 -t 1 key < /dev/tty
                case "$key" in
                    '[A') if ((cur>0)) ; then ((cur--)) ; else cur=$((n-1)) ; fi ;;
                    '[B') if ((cur<n-1)) ; then ((cur++)) ; else cur=0 ; fi ;;
                esac
                ;;
            '')  break ;;
            q|Q) printf "\n" > /dev/tty ; return 1 ;;
        esac
        printf "\033[%dA" "$n" > /dev/tty
    done
    printf "\n" > /dev/tty
    printf "%s\n" "${options[$cur]}"
}

# ------------------------------------------------------------
# select_dblink : query DBA_DB_LINKS, pick one via arrow menu.
# ------------------------------------------------------------
select_dblink() {
    _log "Query DB links from DBA_DB_LINKS"
    local raw
    raw=$(sqlplus -s "${DB_USER}/${DB_PASS}" <<'EOF'
SET HEAD OFF FEED OFF PAGES 0 LINES 200 TRIM ON TRIMSPOOL ON VERIFY OFF
SELECT db_link FROM dba_db_links ORDER BY db_link;
EXIT;
EOF
)
    if echo "${raw}" | grep -qiE 'ORA-|SP2-|ERROR' ; then
        _fail "sqlplus error while querying DBA_DB_LINKS:"
        _emit "${raw}"
        return 1
    fi
    local links=() line
    while IFS= read -r line ; do
        line="$(printf '%s' "${line}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "${line}" ]] && links+=("${line}")
    done <<< "${raw}"
    if [[ ${#links[@]} -eq 0 ]] ; then
        _fail "No DB links found in DBA_DB_LINKS"
        return 1
    fi
    local chosen
    chosen="$(select_menu "Select ASIS DB LINK (from DBA_DB_LINKS):" "${links[@]}")" \
        || { _fail "DB LINK selection cancelled"; return 1; }
    DBLINK="${chosen}"
    _ok "Selected DB LINK : ${DBLINK}"
}

# ------------------------------------------------------------
# STEP 0 : MIG_TAB_LIST OWNER별 TABLE_COUNT 확인
#   Read-only precheck. Returns 1 on SQL error or user 'N'.
# ------------------------------------------------------------
precheck_mig_tab_list() {
    _out "\n%s\n" "$SEP"
    _log "STEP 0 : DBADM.MIG_TAB_LIST OWNER별 TABLE_COUNT 확인"
    _out "%s\n" "$SEP"

    local out
    out=$(sqlplus -s "${DB_USER}/${DB_PASS}" <<'EOF' 2>&1
SET PAGES 200 LINES 200 FEED OFF VERIFY OFF
COL OWNER  FOR A20
COL TABLE_COUNT FOR 999,999,999
PROMPT --- OWNER별 TABLE_COUNT  ---
SELECT OWNER, COUNT(*) AS TABLE_COUNT
  FROM DBADM.MIG_TAB_LIST
 GROUP BY OWNER
 ORDER BY OWNER;
PROMPT
PROMPT --- TOTAL ---
SELECT COUNT(*) AS TOTAL_TABLES FROM DBADM.MIG_TAB_LIST;
EXIT;
EOF
)
    _emit "${out}"

    if printf '%s' "${out}" | grep -qiE 'ORA-|SP2-' ; then
        _fail "STEP 0 : DBADM.MIG_TAB_LIST 조회 실패"
        STATUS[0]="FAIL"
        return 1
    fi

    if confirm "STEP 0 : 위 MIG_TAB_LIST 대상으로 검증을 진행하시겠습니까?" ; then
        STATUS[0]="OK"
        return 0
    else
        _log "STEP 0 : 사용자 중단(N)"
        STATUS[0]="SKIP"
        return 1
    fi
}

# Delay (seconds) between each sub-task line in the completion checklist.
STEP_SLEEP="0.5"

# _count_sql <select> : run a one-value SELECT, echo the trimmed scalar
#   (or the ORA-/SP2- error text) to stdout.
_count_sql() {
    local q="$1" out
    out=$(sqlplus -s "${DB_USER}/${DB_PASS}" <<EOF 2>&1
SET HEAD OFF FEED OFF PAGES 0 LINES 200 TRIM ON TRIMSPOOL ON VERIFY OFF
${q}
EXIT;
EOF
)
    printf '%s' "${out}" | tr -d '\r' | tr -s ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -vE '^$' | tail -1
}

# _query_rows <select> : run a multi-row SELECT, echo cleaned non-empty
#   lines (ORA-/SP2- error lines are kept so callers can detect failure).
_query_rows() {
    local q="$1" out
    out=$(sqlplus -s "${DB_USER}/${DB_PASS}" <<EOF 2>&1
SET HEAD OFF FEED OFF PAGES 0 LINES 300 TRIM ON TRIMSPOOL ON VERIFY OFF
${q}
EXIT;
EOF
)
    printf '%s' "${out}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -vE '^$'
}

# ------------------------------------------------------------
# verify_dict <ASIS|TOBE> : STEP 1/2 checklist. Prints each of the 7
#   tables one-by-one (0.5s apart). Returns 1 if any FAIL.
# ------------------------------------------------------------
verify_dict() {
    local side="$1"
    local objs=(CONSTRAINTS TABLES TAB_COLUMNS INDEXES TAB_PARTITIONS IND_PARTITIONS OTHER_OBJECTS)
    local n=${#objs[@]} i tab res okc=0 failed=0
    for ((i=0; i<n; i++)) ; do
        tab="DBA_${side}_${objs[$i]}"
        res="$(_count_sql "SELECT COUNT(*) FROM DBADM.${tab};")"
        if [[ "${res}" =~ ^[0-9]+$ ]] ; then
            _emit "$(printf '  [%d/%d] %-30s ... OK    rows=%s' $((i+1)) "${n}" "${tab}" "${res}")"
            okc=$((okc+1))
        elif printf '%s' "${res}" | grep -qi 'ORA-00942' ; then
            # CTAS 로 테이블이 생성되지 않은 경우(원본 뷰가 없어 미생성) -> rows=0 으로 예외 처리(비중단)
            _emit "$(printf '  [%d/%d] %-30s ... OK    rows=0 (table not found)' $((i+1)) "${n}" "${tab}")"
            okc=$((okc+1))
        else
            _emit "$(printf '  [%d/%d] %-30s ... FAIL  %s' $((i+1)) "${n}" "${tab}" "${res:0:40}")"
            failed=1
        fi
        sleep "${STEP_SLEEP}"
    done
    _emit "$(printf '  => %d/%d complete' "${okc}" "${n}")"
    [[ ${failed} -eq 0 ]]
}

# ------------------------------------------------------------
# verify_count <ASIS|TOBE> : STEP 3/4 checklist, broken down by OWNER.
#   For each OWNER present in DBADM.MIG_OBJ_CNT_<side>, prints each of the
#   6 OBJECT_NAME counts (0.5s apart) + an owner total. Only real SQL
#   exceptions are FAIL. Returns 1 on FAIL.
# ------------------------------------------------------------
verify_count() {
    local side="$1"
    local labels=("CONSTRAINT" "TABLE" "TABLE PARITTION" "INDEX" "INDEX PARITTION" "OTHERS OBJECT")
    local -A CNT
    local rows o obj c lbl owners=() nown idx total

    rows="$(_query_rows "SELECT OWNER||'|'||OBJECT_NAME||'|'||NVL(SUM(CNT),0) FROM DBADM.MIG_OBJ_CNT_${side} GROUP BY OWNER, OBJECT_NAME;")"

    if printf '%s' "${rows}" | grep -qiE 'ORA-|SP2-' ; then
        _emit "$(printf '  ... FAIL  %s' "$(printf '%s' "${rows}" | tail -1)")"
        return 1
    fi
    if [[ -z "${rows}" ]] ; then
        _emit "  (no rows in DBADM.MIG_OBJ_CNT_${side})"
        return 0
    fi

    # index counts by "owner|object_name" and collect distinct owners
    while IFS='|' read -r o obj c ; do
        [[ -z "${o}" ]] && continue
        CNT["${o}|${obj}"]="${c}"
        if [[ " ${owners[*]} " != *" ${o} "* ]] ; then owners+=("${o}") ; fi
    done <<< "${rows}"

    IFS=$'\n' owners=($(printf '%s\n' "${owners[@]}" | sort)) ; unset IFS
    nown=${#owners[@]} ; idx=0

    for o in "${owners[@]}" ; do
        idx=$((idx+1))
        _emit "$(printf '  [%d/%d] OWNER = %s' "${idx}" "${nown}" "${o}")"
        total=0
        for lbl in "${labels[@]}" ; do
            c="${CNT["${o}|${lbl}"]:-0}"
            _emit "$(printf '         %-16s ... cnt=%s' "${lbl}" "${c}")"
            total=$((total + c))
            sleep "${STEP_SLEEP}"
        done
        _emit "$(printf '         => %s objects total = %d' "${o}" "${total}")"
    done
    _emit "$(printf '  => %d owner(s) checked' "${nown}")"
    return 0
}

# ------------------------------------------------------------
# verify_step <spec>  spec = dict:ASIS|dict:TOBE|count:ASIS|count:TOBE
#   Prints the checklist live; returns 1 if any sub-task is FAIL.
# ------------------------------------------------------------
verify_step() {
    local spec="$1" kind side rc
    kind="${spec%%:*}" ; side="${spec##*:}"

    _out "%s\n" "  ${SUB}"
    _out "   완료 현황 (%s %s)\n" "${side}" "${kind}"
    _out "%s\n" "  ${SUB}"
    case "${kind}" in
        dict)  verify_dict  "${side}" ; rc=$? ;;
        count) verify_count "${side}" ; rc=$? ;;
        *)     rc=0 ;;
    esac
    _out "%s\n" "  ${SUB}"
    return ${rc}
}

# ------------------------------------------------------------
# run_step <num> <title> <src.sql> <link|nolink> <verifyspec|"">
#   Returns non-zero ONLY on FAIL (missing file / sqlplus error /
#   verify FAIL). User 'N' = SKIP and returns 0 (pipeline continues).
# ------------------------------------------------------------
run_step() {
    local num="$1" title="$2" src="$3" mode="$4" vspec="$5"
    local rendered rc _l _v

    _out "\n%s\n" "$SEP"
    _log "STEP ${num} : ${title}"
    _out "%s\n" "$SEP"

    if [[ ! -f "${src}" ]] ; then
        _fail "SQL file not found: ${src}"
        STATUS[$num]="FAIL"
        return 1
    fi

    if [[ "${mode}" == "link" && -z "${DBLINK}" ]] ; then
        select_dblink || { STATUS[$num]="FAIL"; return 1; }
    fi

    if [[ "${mode}" == "link" ]] ; then
        rendered="${BASE_PATH}/tmp/$(basename "${src}" .sql)_$$.sql"
        cp "${src}" "${rendered}"
        # Append the chosen DB LINK to each ASIS remote source view.
        for _v in "${OC_REMOTE_VIEWS[@]}" ; do
            sed -i -E "s/\\b(${_v})\\b/\\1@${DBLINK}/g" "${rendered}"
        done
        TMP_FILES="${TMP_FILES} ${rendered}"
    else
        rendered="${src}"
    fi

    _out "  Source : %s\n" "${src}"
    [[ "${mode}" == "link" ]] && _out "  DB LINK: %s\n" "${DBLINK}"
    _out "  ---- SQL ----------------------------------------------------\n"
    while IFS= read -r _l ; do _out "  | %s\n" "${_l}"; done < "${rendered}"
    _out "  -------------------------------------------------------------\n"

    if ! confirm "STEP ${num} : 위 SQL을 실행하시겠습니까?" ; then
        _log "STEP ${num} skipped by user"
        STATUS[$num]="SKIP"
        return 0
    fi

    _log "STEP ${num} executing..."
    sqlplus -s "${DB_USER}/${DB_PASS}" <<EOF 2>&1 | tee -a "${LOGFILE}"
SET DEFINE OFF VERIFY OFF ECHO ON FEED ON LINES 200 PAGES 200
WHENEVER SQLERROR CONTINUE
@${rendered}
EXIT;
EOF
    rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 ]] ; then
        _fail "STEP ${num} sqlplus failed (rc=${rc})"
        STATUS[$num]="FAIL"
        return 1
    fi
    _ok "STEP ${num} done"

    if [[ -n "${vspec}" ]] ; then
        if verify_step "${vspec}" ; then
            STATUS[$num]="OK"
        else
            _fail "STEP ${num} : 세부 과정에 FAIL 이 있어 다음 단계로 진행하지 않습니다"
            STATUS[$num]="FAIL"
            return 1
        fi
    else
        STATUS[$num]="OK"
    fi
    return 0
}

# ============================================================
# Main  (halt on any FAIL)
# ============================================================
_out "%s\n" "$SEP"
_log "OBJECT_CHECK — ASIS <-> TOBE object verification"
_out "  Log : %s\n" "${LOGFILE}"
_out "%s\n" "$SEP"

precheck_mig_tab_list || finish 1

run_step 1 "ASIS dictionary copy  -> DBADM.DBA_ASIS_*"        "${SCRIPT_DIR}/sql/1.ASIS_COPY_DICTIONARY.sql"      link   "dict:ASIS"  || finish 1
run_step 2 "TOBE dictionary copy  -> DBADM.DBA_TOBE_*"        "${SCRIPT_DIR}/sql/2.TOBE_COPY_DICTIONARY.sql"      nolink "dict:TOBE"  || finish 1
run_step 3 "ASIS object count     -> DBADM.MIG_OBJ_CNT_ASIS"  "${SCRIPT_DIR}/sql/3.ASIS_OBJECT_COUNT_CREATE.sql"  nolink "count:ASIS" || finish 1
run_step 4 "TOBE object count     -> DBADM.MIG_OBJ_CNT_TOBE"  "${SCRIPT_DIR}/sql/4.TOBE_OBJECT_COUNT_CREATE.sql"  nolink "count:TOBE" || finish 1
run_step 5 "ASIS <-> TOBE GAP check"                          "${SCRIPT_DIR}/sql/5.ASIS_TOBE_OBJECT_GAP_CHECK.sql" nolink ""          || finish 1

finish 0
