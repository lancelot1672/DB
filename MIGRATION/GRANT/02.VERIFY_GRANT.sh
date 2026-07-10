#!/bin/bash
# ============================================================
# 02.VERIFY_GRANT.sh
# Verify table privilege grants driven by 01.GRANT_PRIV.sh.
#   For each (BSN OWNUSR CONUSR) target in DBADM.DBM_USR_INF:
#     Check 1 : synonyms created  (DBA_SYNONYMS count == table count)
#     Check 2 : privileges granted (each of SELECT/INSERT/UPDATE/DELETE
#               count for RL_{BSN}_ALL == table count)
# Usage: 02.VERIFY_GRANT.sh
#   The available BSN list is read from DBM_USR_INF first, then the
#   target BSN is entered interactively (blank/ALL = all BSN).
# ============================================================

# --- Load environment variables ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [[ -f "./MIG.env" ]] ; then
    . ./MIG.env
else
    echo "[FAIL] MIG.env file not found: ./MIG.env"
    exit 1
fi

SEP="============================================================"
TSEP=$(printf '=%.0s' $(seq 1 105))
YMD=$(date '+%Y%m%d')
HMS=$(date '+%H%M%S')

PRIVS="SELECT INSERT UPDATE DELETE"

SQL_OUT_DIR="./sql"
TMP_DIR="${BASE_PATH}/tmp"
LOG_DIR="${BASE_PATH}/log"
mkdir -p "${SQL_OUT_DIR}" "${TMP_DIR}" "${LOG_DIR}"

TGT_LST="${TMP_DIR}/VERIFY_GRANT_TGT_$$.lst"
CNT_LST="${TMP_DIR}/VERIFY_GRANT_CNT_$$.lst"
GEN_SQL="${TMP_DIR}/VERIFY_GRANT_GEN_$$.sql"
MISS_SYN="${TMP_DIR}/VERIFY_GRANT_MSYN_$$.lst"
MISS_GRT="${TMP_DIR}/VERIFY_GRANT_MGRT_$$.lst"

# --- Log File ---
LOGFILE="${LOG_DIR}/VERIFY_GRANT_$(date '+%Y%m%d_%H%M%S').log"

# _out: Print to terminal and append to log file
_out() {
    printf "$@"
    printf "$@" >> ${LOGFILE}
}

# --- Colors: terminal only ([OK] green, [FAIL] bold red); log stays plain ---
if [[ -t 1 ]] ; then
    C_GRN=$'\033[32m' ; C_RED=$'\033[31m' ; C_BLD=$'\033[1m' ; C_RST=$'\033[0m'
else
    C_GRN='' ; C_RED='' ; C_BLD='' ; C_RST=''
fi

_log()  { _out "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
_ok()   {
    printf "${C_GRN}[OK]${C_RST}   %s\n" "$*"
    printf "[OK]   %s\n" "$*" >> ${LOGFILE}
}
_fail() {
    printf "${C_BLD}${C_RED}[FAIL] %s${C_RST}\n" "$*"
    printf "[FAIL] %s\n" "$*" >> ${LOGFILE}
}

_cleanup() { rm -f ${TGT_LST} ${CNT_LST} ${TMP_DIR}/VERIFY_GRANT_ALL_$$.lst ${GEN_SQL} ${MISS_SYN} ${MISS_GRT}; }

# ------------------------------------------------------------
# _select_menu : Up/Down arrow + Enter selection menu.
#   args   : menu options
#   result : selected option in global MENU_RESULT
#   return : 0 on interactive select, 1 if no TTY (caller falls back)
#   Reads keys from /dev/tty so sqlplus stdin never interferes.
# ------------------------------------------------------------
_select_menu() {
    local options=("$@")
    local n=${#options[@]}
    local cur=0 key k2 first=1

    if [[ ! -t 1 || ! -e /dev/tty ]] ; then
        MENU_RESULT=""
        return 1
    fi

    exec 3< /dev/tty
    printf '\033[?25l'                              # hide cursor
    while true ; do
        [[ $first -eq 0 ]] && printf '\033[%dA' "$n"   # move up to redraw
        first=0
        local i
        for ((i=0; i<n; i++)) ; do
            printf '\033[2K'                        # clear line
            if [[ $i -eq $cur ]] ; then
                printf ' \033[7m> %s \033[0m\n' "${options[$i]}"
            else
                printf '   %s \n' "${options[$i]}"
            fi
        done
        IFS= read -rsn1 key <&3 || break
        case "$key" in
            $'\033')
                read -rsn2 -t 0.1 k2 <&3
                case "$k2" in
                    '[A') ((cur=(cur-1+n)%n)) ;;    # Up
                    '[B') ((cur=(cur+1)%n)) ;;      # Down
                esac ;;
            '') break ;;                            # Enter
        esac
    done
    exec 3<&-
    printf '\033[?25h'                              # show cursor
    MENU_RESULT="${options[$cur]}"
    MENU_INDEX="${cur}"
    return 0
}

# ============================================================
# Pass 1. Read ALL targets from DBM_USR_INF, then let the user
#         pick a BSN interactively (blank/ALL = all BSN)
# ============================================================
_out "%s\n" "$SEP"
_log "Read available targets from DBADM.DBM_USR_INF"
_out "%s\n" "$SEP"

ALL_LST="${TMP_DIR}/VERIFY_GRANT_ALL_$$.lst"

sqlplus -s ${DB_USER}/${DB_PASS} <<_EOF
set pagesize 0
set linesize 200
set feedback off
set heading off
set echo off
set verify off
set trimspool on

spool ${ALL_LST}
SELECT BSN || ' ' || OWNUSR || ' ' || CONUSR
  FROM DBADM.DBM_USR_INF
 ORDER BY BSN;
spool off
exit
_EOF

egrep -v "^[[:space:]]*$" ${ALL_LST} > ${ALL_LST}.tmp 2>/dev/null
mv ${ALL_LST}.tmp ${ALL_LST}

if [[ ! -s "${ALL_LST}" ]] ; then
    _fail "No rows found in DBADM.DBM_USR_INF"
    rm -f ${ALL_LST}
    _cleanup
    exit 1
fi

# Build the selectable list directly from DBM_USR_INF (row 0 = ALL).
# The target list itself is the scroll menu (Up/Down + Enter).
MENU_OPTS=() ; MENU_BSN=()
MENU_OPTS+=("ALL          (all BSN)") ; MENU_BSN+=("ALL")
while read -r _b _o _c ; do
    [[ -z "${_b}" ]] && continue
    MENU_OPTS+=("$(printf 'BSN=%-10s OWNUSR=%-10s CONUSR=%-10s' "${_b}" "${_o}" "${_c}")")
    MENU_BSN+=("${_b}")
done < ${ALL_LST}

_out "  Available targets in DBADM.DBM_USR_INF (Up/Down + Enter):\n"
if _select_menu "${MENU_OPTS[@]}" ; then
    BSN_IN="${MENU_BSN[$MENU_INDEX]}"
else
    # non-TTY fallback: print the list plainly, then read typed input
    for _i in "${!MENU_OPTS[@]}" ; do _out "    %s\n" "${MENU_OPTS[$_i]}"; done
    printf "Enter target BSN (blank or ALL = all): "
    read -r BSN_IN
    BSN_IN=$(echo "${BSN_IN}" | tr -d '[:space:]')
    [[ -z "${BSN_IN}" ]] && BSN_IN="ALL"
fi

if [[ -z "${BSN_IN}" || "${BSN_IN}" == "ALL" || "${BSN_IN}" == "all" ]] ; then
    _log "Selected: ALL BSN"
    cp ${ALL_LST} ${TGT_LST}
else
    _log "Selected BSN: ${BSN_IN}"
    awk -v bsn="${BSN_IN}" '$1==bsn' ${ALL_LST} > ${TGT_LST}
fi
rm -f ${ALL_LST}

if [[ ! -s "${TGT_LST}" ]] ; then
    _fail "No matching target in DBADM.DBM_USR_INF (BSN=${BSN_IN})"
    _cleanup
    exit 1
fi

# ============================================================
# Pass 2. Per-target verification
# ============================================================
FAIL_TOTAL=0

_out "%-12s %-12s %-12s %12s %8s %8s %8s %8s %8s   %s\n" \
     "BSN" "OWNUSR" "CONUSR" "COUNT(TABLE)" "SYN" "SELECT" "INSERT" "UPDATE" "DELETE" "RESULT"
_out "%s\n" "$TSEP"

while read -r BSN OWNUSR CONUSR ; do
    [[ -z "${BSN}" ]] && continue
    GRANTEE="RL_${BSN}_ALL"

    # --- Collect all counts in one sqlplus call ---
    sqlplus -s ${DB_USER}/${DB_PASS} <<_EOF > /dev/null
set pagesize 0
set linesize 200
set feedback off
set heading off
set echo off
set verify off
set trimspool on

spool ${CNT_LST}
SELECT 'TAB ' || COUNT(*) FROM DBA_TABLES  WHERE OWNER = '${OWNUSR}';
SELECT 'SYN ' || COUNT(*) FROM DBA_SYNONYMS
 WHERE TABLE_OWNER = '${OWNUSR}' AND OWNER = '${CONUSR}';
SELECT PRIVILEGE || ' ' || COUNT(*) FROM DBA_TAB_PRIVS
 WHERE GRANTEE = '${GRANTEE}'
 GROUP BY PRIVILEGE;
spool off
exit
_EOF

    # --- Parse counts ---
    TAB_CNT=0 ; SYN_CNT=0
    P_SELECT=0 ; P_INSERT=0 ; P_UPDATE=0 ; P_DELETE=0
    while read -r _key _val ; do
        [[ -z "${_key}" ]] && continue
        case "${_key}" in
            TAB)    TAB_CNT="${_val}" ;;
            SYN)    SYN_CNT="${_val}" ;;
            SELECT) P_SELECT="${_val}" ;;
            INSERT) P_INSERT="${_val}" ;;
            UPDATE) P_UPDATE="${_val}" ;;
            DELETE) P_DELETE="${_val}" ;;
        esac
    done < ${CNT_LST}

    # --- Evaluate ---
    ROW_FAIL=0
    [[ "${SYN_CNT}"  != "${TAB_CNT}" ]] && ROW_FAIL=1
    [[ "${P_SELECT}" != "${TAB_CNT}" ]] && ROW_FAIL=1
    [[ "${P_INSERT}" != "${TAB_CNT}" ]] && ROW_FAIL=1
    [[ "${P_UPDATE}" != "${TAB_CNT}" ]] && ROW_FAIL=1
    [[ "${P_DELETE}" != "${TAB_CNT}" ]] && ROW_FAIL=1

    if [[ ${ROW_FAIL} -eq 0 ]] ; then
        RESULT="OK"   ; RES_C="${C_GRN}[OK]${C_RST}"
    else
        RESULT="FAIL" ; RES_C="${C_BLD}${C_RED}[FAIL]${C_RST}"
        FAIL_TOTAL=$((FAIL_TOTAL + 1))
    fi

    # colored to terminal, plain to log (keep column alignment)
    printf "%-12s %-12s %-12s %12s %8s %8s %8s %8s %8s   %s\n" \
         "${BSN}" "${OWNUSR}" "${CONUSR}" "${TAB_CNT}" "${SYN_CNT}" \
         "${P_SELECT}" "${P_INSERT}" "${P_UPDATE}" "${P_DELETE}" "${RES_C}"
    printf "%-12s %-12s %-12s %12s %8s %8s %8s %8s %8s   %s\n" \
         "${BSN}" "${OWNUSR}" "${CONUSR}" "${TAB_CNT}" "${SYN_CNT}" \
         "${P_SELECT}" "${P_INSERT}" "${P_UPDATE}" "${P_DELETE}" "[${RESULT}]" >> ${LOGFILE}

    # --- Detail on failure : count mismatch + exact missing objects + fix SQL ---
    if [[ ${ROW_FAIL} -ne 0 ]] ; then
        # (a) count-level mismatch summary
        [[ "${SYN_CNT}"  != "${TAB_CNT}" ]] && _fail "  ${BSN} SYNONYM count mismatch: ${SYN_CNT} / expected ${TAB_CNT} (TABLE_OWNER=${OWNUSR}, OWNER=${CONUSR})"
        [[ "${P_SELECT}" != "${TAB_CNT}" ]] && _fail "  ${BSN} SELECT  count mismatch: ${P_SELECT} / expected ${TAB_CNT} (GRANTEE=${GRANTEE})"
        [[ "${P_INSERT}" != "${TAB_CNT}" ]] && _fail "  ${BSN} INSERT  count mismatch: ${P_INSERT} / expected ${TAB_CNT} (GRANTEE=${GRANTEE})"
        [[ "${P_UPDATE}" != "${TAB_CNT}" ]] && _fail "  ${BSN} UPDATE  count mismatch: ${P_UPDATE} / expected ${TAB_CNT} (GRANTEE=${GRANTEE})"
        [[ "${P_DELETE}" != "${TAB_CNT}" ]] && _fail "  ${BSN} DELETE  count mismatch: ${P_DELETE} / expected ${TAB_CNT} (GRANTEE=${GRANTEE})"

        # (b) build a script that spools the EXACT missing objects
        : > ${GEN_SQL}
        {
            echo "set pagesize 0"
            echo "set linesize 1000"
            echo "set feedback off"
            echo "set heading off"
            echo "set echo off"
            echo "set verify off"
            echo "set trimspool on"
            echo ""
            echo "spool ${MISS_SYN}"
            echo "SELECT TABLE_NAME FROM DBA_TABLES T WHERE T.OWNER = '${OWNUSR}'"
            echo "   AND NOT EXISTS (SELECT 1 FROM DBA_SYNONYMS S"
            echo "        WHERE S.TABLE_OWNER = '${OWNUSR}' AND S.OWNER = '${CONUSR}' AND S.TABLE_NAME = T.TABLE_NAME)"
            echo " ORDER BY TABLE_NAME;"
            echo "spool off"
            echo ""
            echo "spool ${MISS_GRT}"
            for PRIV in ${PRIVS} ; do
                echo "SELECT '${PRIV} ' || TABLE_NAME FROM DBA_TABLES T WHERE T.OWNER = '${OWNUSR}'"
                echo "   AND NOT EXISTS (SELECT 1 FROM DBA_TAB_PRIVS P"
                echo "        WHERE P.GRANTEE = '${GRANTEE}' AND P.OWNER = '${OWNUSR}'"
                echo "          AND P.TABLE_NAME = T.TABLE_NAME AND P.PRIVILEGE = '${PRIV}')"
                echo " ORDER BY TABLE_NAME;"
            done
            echo "spool off"
            echo "exit"
        } >> ${GEN_SQL}

        : > ${MISS_SYN} ; : > ${MISS_GRT}
        sqlplus -s ${DB_USER}/${DB_PASS} @${GEN_SQL} < /dev/null >> ${LOGFILE}
        egrep -v "^[[:space:]]*$" ${MISS_SYN} > ${MISS_SYN}.tmp 2>/dev/null ; mv ${MISS_SYN}.tmp ${MISS_SYN}
        egrep -v "^[[:space:]]*$" ${MISS_GRT} > ${MISS_GRT}.tmp 2>/dev/null ; mv ${MISS_GRT}.tmp ${MISS_GRT}

        _MSYN=$(wc -l < ${MISS_SYN})
        _MGRT=$(wc -l < ${MISS_GRT})

        # (c) print the exact missing objects to terminal/log
        if [[ "${_MSYN}" -gt 0 ]] ; then
            _fail "  ${BSN} missing SYNONYM (${_MSYN}) [OWNER=${CONUSR} -> ${OWNUSR}]:"
            while read -r _t ; do _out "         - %s\n" "${_t}"; done < ${MISS_SYN}
        fi
        if [[ "${_MGRT}" -gt 0 ]] ; then
            _fail "  ${BSN} missing GRANT (${_MGRT}) [GRANTEE=${GRANTEE}]:"
            while read -r _p _t ; do _out "         - %-7s %s\n" "${_p}" "${_t}"; done < ${MISS_GRT}
        fi
        if [[ "${_MSYN}" -eq 0 && "${_MGRT}" -eq 0 ]] ; then
            _fail "  ${BSN} count mismatch but no missing object found (possible extra/duplicate entries)"
        fi

        # (d) write remediation SQL file
        FAIL_SQL="${SQL_OUT_DIR}/VERIFY_FAIL_${BSN}_${YMD}_${HMS}.sql"
        {
            echo "-- ============================================================"
            echo "-- VERIFY FAIL remediation : BSN=${BSN}"
            echo "--   OWNUSR=${OWNUSR}  CONUSR=${CONUSR}  GRANTEE=${GRANTEE}"
            echo "--   expected table count = ${TAB_CNT}"
            echo "--   generated ${YMD}_${HMS}"
            echo "-- ============================================================"
            echo ""
            echo "-- [1] Missing SYNONYMS : ${_MSYN}"
        } > ${FAIL_SQL}
        if [[ "${_MSYN}" -gt 0 ]] ; then
            while read -r _t ; do
                echo "CREATE SYNONYM ${CONUSR}.${_t} FOR ${OWNUSR}.${_t};" >> ${FAIL_SQL}
            done < ${MISS_SYN}
        else
            echo "--   (none)" >> ${FAIL_SQL}
        fi
        {
            echo ""
            echo "-- [2] Missing GRANTS : ${_MGRT}  (re-INSERT into DBADM.DBM_PRIV_INF; trigger re-grants)"
        } >> ${FAIL_SQL}
        if [[ "${_MGRT}" -gt 0 ]] ; then
            while read -r _p _t ; do
                echo "INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) VALUES ('${_p}','${OWNUSR}','${_t}','${GRANTEE}',SYSDATE);" >> ${FAIL_SQL}
            done < ${MISS_GRT}
        else
            echo "--   (none)" >> ${FAIL_SQL}
        fi
        echo ""        >> ${FAIL_SQL}
        echo "COMMIT;"  >> ${FAIL_SQL}

        _log "  ${BSN} remediation SQL written : ${FAIL_SQL}"
    fi
done < ${TGT_LST}

# ============================================================
# Summary
# ============================================================
_out "%s\n" "$SEP"
TGT_CNT=$(wc -l < ${TGT_LST})
if [[ ${FAIL_TOTAL} -eq 0 ]] ; then
    _ok "All ${TGT_CNT} target(s) verified"
    _cleanup
    exit 0
else
    _fail "${FAIL_TOTAL} of ${TGT_CNT} target(s) FAILED verification"
    _cleanup
    exit 1
fi
