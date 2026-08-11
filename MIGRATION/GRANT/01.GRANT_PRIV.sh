#!/bin/bash
# ============================================================
# 01.GRANT_PRIV.sh
# Grant table privileges. On start, choose one of two operations:
#
#   [Mode 1] INSERT INTO DBADM.DBM_PRIV_INF
#     - read DBADM.DBM_USR_INF -> (BSN OWNUSR CONUSR) targets
#     - generate 4 INSERT SQL files (SELECT/INSERT/UPDATE/DELETE)
#       into DBM_PRIV_INF ; an internal trigger performs the GRANT
#
#   [Mode 2] Direct GRANT + CREATE SYNONYM
#     - input OWNUSR (table owner) and CONUSR (connection user)
#     - list RL% roles granted to CONUSR (DBA_ROLE_PRIVS) and pick one
#     - GRANT SELECT,INSERT,UPDATE,DELETE on OWNUSR tables to the role
#       and CREATE SYNONYM in CONUSR for each OWNUSR table
#
#   [Mode 3] ROLE based GRANT
#     - list every RL_ role in DBA_ROLE_PRIVS (GRANTEE, GRANTED_ROLE), pick one
#     - list DISTINCT OWNER from DBA_TABLES, pick one
#     - pick privileges, then pick how to apply them
#       (INSERT INTO DBM_PRIV_INF / direct GRANT). No synonym is created.
#
# Every mode asks which privileges to grant (SELECT/INSERT/UPDATE/DELETE,
# multi-select, all checked by default) right before the SQL is generated.
#
# Generated SQL files are always saved under ./sql/ (executed or not).
# Usage: 01.GRANT_PRIV.sh
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
YMD=$(date '+%Y%m%d')
HMS=$(date '+%H%M%S')

# Privileges actually used are chosen interactively by _choose_privs();
# this is only the fallback default (all four).
PRIVS_DEFAULT="SELECT INSERT UPDATE DELETE"

# Every generated SQL file is prefixed with the mode that produced it
# (1_/2_/3_) so files from different modes group together in ./sql/.
# Each mode sets this before generating anything.
FILE_PREFIX=""

SQL_OUT_DIR="./sql"
TMP_DIR="${BASE_PATH}/tmp"
LOG_DIR="${BASE_PATH}/log"
mkdir -p "${SQL_OUT_DIR}" "${TMP_DIR}" "${LOG_DIR}"

TGT_SQL="${TMP_DIR}/GRANT_PRIV_TGT_$$.sql"
TGT_LST="${TMP_DIR}/GRANT_PRIV_TGT_$$.lst"

# --- Log File ---
LOGFILE="${LOG_DIR}/GRANT_PRIV_$(date '+%Y%m%d_%H%M%S').log"

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

_cleanup() {
    rm -f ${TGT_SQL} ${TGT_LST} \
          ${TMP_DIR}/GRANT_PRIV_ALL_$$.lst \
          ${TMP_DIR}/GRANT_ROLE_$$.lst ${TMP_DIR}/GRANT_GEN2_$$.sql \
          ${TMP_DIR}/GRANT_ROLE3_$$.lst ${TMP_DIR}/GRANT_OWNER3_$$.lst \
          ${TMP_DIR}/GRANT_GEN3I_$$.sql ${TMP_DIR}/GRANT_GEN3G_$$.sql
}

# ------------------------------------------------------------
# _select_menu : Up/Down arrow + Enter selection menu.
#   args   : menu options
#   result : selected option in global MENU_RESULT, index in MENU_INDEX
#   return : 0 on interactive select, 1 if no TTY (caller falls back)
#   Reads keys from /dev/tty so sqlplus stdin never interferes.
#   Lists longer than the terminal scroll inside a window (PgUp/PgDn
#   jump a page); a "-- cur/total --" status line is shown in that case.
#   NOTE: keep this in sync with the copy in 02.VERIFY_GRANT.sh.
# ------------------------------------------------------------
_select_menu() {
    local options=("$@")
    local n=${#options[@]}
    local cur=0 key k2 k3 first=1 top=0 rows win drawn i

    if [[ ! -t 1 || ! -e /dev/tty ]] ; then
        MENU_RESULT=""
        return 1
    fi

    # visible rows: keep 4 lines for the surrounding prompts
    rows=$(tput lines 2>/dev/null)
    [[ -z "${rows}" || "${rows}" -lt 8 ]] && rows=24
    win=$((rows - 4))
    [[ ${win} -lt 3 ]] && win=3
    [[ ${win} -gt ${n} ]] && win=${n}
    drawn=${win}
    [[ ${n} -gt ${win} ]] && drawn=$((win + 1))     # + status line

    exec 3< /dev/tty
    printf '\033[?25l'                              # hide cursor
    while true ; do
        # keep the cursor inside the window
        [[ ${cur} -lt ${top} ]] && top=${cur}
        [[ ${cur} -ge $((top + win)) ]] && top=$((cur - win + 1))

        [[ $first -eq 0 ]] && printf '\033[%dA' "${drawn}"   # move up to redraw
        first=0
        for ((i=top; i<top+win; i++)) ; do
            printf '\033[2K'                        # clear line
            if [[ $i -eq $cur ]] ; then
                printf ' \033[7m> %s \033[0m\n' "${options[$i]}"
            else
                printf '   %s \n' "${options[$i]}"
            fi
        done
        if [[ ${n} -gt ${win} ]] ; then
            printf '\033[2K'
            printf '   -- %d/%d (PgUp/PgDn) --\n' "$((cur + 1))" "${n}"
        fi

        IFS= read -rsn1 key <&3 || break
        case "$key" in
            $'\033')
                read -rsn2 -t 0.1 k2 <&3
                case "$k2" in
                    '[A') ((cur=(cur-1+n)%n)) ;;    # Up
                    '[B') ((cur=(cur+1)%n)) ;;      # Down
                    '[5') read -rsn1 -t 0.1 k3 <&3  # PgUp (ESC [ 5 ~)
                          cur=$((cur - win))
                          [[ ${cur} -lt 0 ]] && cur=0 ;;
                    '[6') read -rsn1 -t 0.1 k3 <&3  # PgDn (ESC [ 6 ~)
                          cur=$((cur + win))
                          [[ ${cur} -ge ${n} ]] && cur=$((n - 1)) ;;
                    '[H') cur=0 ;;                  # Home
                    '[F') cur=$((n - 1)) ;;         # End
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

# ------------------------------------------------------------
# _multi_select_menu : Up/Down move, SPACE toggle, Enter confirm.
#   args   : menu options (all pre-checked by default)
#   result : space-joined checked options in MULTI_RESULT
#   return : 0 on interactive select, 1 if no TTY (caller falls back)
# ------------------------------------------------------------
_multi_select_menu() {
    local options=("$@")
    local n=${#options[@]}
    local cur=0 key k2 first=1 i mark
    local sel=()

    if [[ ! -t 1 || ! -e /dev/tty ]] ; then
        MULTI_RESULT=""
        return 1
    fi

    for ((i=0; i<n; i++)) ; do sel[$i]=1 ; done     # default: all checked

    exec 3< /dev/tty
    printf '\033[?25l'                              # hide cursor
    while true ; do
        [[ $first -eq 0 ]] && printf '\033[%dA' "$n"
        first=0
        for ((i=0; i<n; i++)) ; do
            printf '\033[2K'
            [[ ${sel[$i]} -eq 1 ]] && mark='■' || mark=' '
            if [[ $i -eq $cur ]] ; then
                printf ' \033[7m> [%s] %s \033[0m\n' "$mark" "${options[$i]}"
            else
                printf '   [%s] %s \n' "$mark" "${options[$i]}"
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
            ' ') sel[$cur]=$((1 - sel[$cur])) ;;    # SPACE toggle
            '') break ;;                            # Enter confirm
        esac
    done
    exec 3<&-
    printf '\033[?25h'                              # show cursor
    MULTI_RESULT=""
    for ((i=0; i<n; i++)) ; do
        [[ ${sel[$i]} -eq 1 ]] && MULTI_RESULT="${MULTI_RESULT}${MULTI_RESULT:+ }${options[$i]}"
    done
    return 0
}

# ------------------------------------------------------------
# _priv_code : privilege list -> file name tag.
#   SELECT=S INSERT=I UPDATE=U DELETE=D, always emitted in S,I,U,D order
#   so the same set always yields the same tag.
#     "SELECT UPDATE"                  -> SU
#     "DELETE SELECT INSERT UPDATE"    -> SIUD
#   args   : privileges (space separated, one arg or many)
#   stdout : the code
# ------------------------------------------------------------
_priv_code() {
    local p code="" list
    list=" $(echo "$*" | tr ',' ' ' | tr '[:lower:]' '[:upper:]' | xargs) "
    for p in SELECT INSERT UPDATE DELETE ; do
        case "${list}" in
            *" ${p} "*) code="${code}${p:0:1}" ;;
        esac
    done
    printf '%s' "${code}"
}

# ------------------------------------------------------------
# _choose_privs : SELECT/INSERT/UPDATE/DELETE multi-select.
#   All four are checked by default (plain Enter = all).
#   result : SEL_PRIVS      space separated  -> loops
#            GRANT_PRIV_CSV comma separated  -> GRANT statements
#            PRIV_CODE      S/I/U/D tag      -> file names
#   return : 0 on success, 1 if nothing selected
# ------------------------------------------------------------
_choose_privs() {
    local PMENU=("SELECT" "INSERT" "UPDATE" "DELETE")
    _out "  Select privileges (Up/Down move, SPACE toggle, Enter confirm):\n"
    if _multi_select_menu "${PMENU[@]}" ; then
        SEL_PRIVS="${MULTI_RESULT}"
    else
        printf "  Enter privileges (space/comma separated, blank=ALL): "
        read -r SEL_PRIVS
        SEL_PRIVS=$(echo "${SEL_PRIVS}" | tr ',' ' ' | tr '[:lower:]' '[:upper:]')
        [[ -z "$(echo ${SEL_PRIVS} | tr -d '[:space:]')" ]] && SEL_PRIVS="${PRIVS_DEFAULT}"
    fi
    if [[ -z "$(echo ${SEL_PRIVS} | tr -d '[:space:]')" ]] ; then
        _fail "At least one privilege must be selected"
        return 1
    fi
    GRANT_PRIV_CSV=$(echo ${SEL_PRIVS} | xargs | sed 's/ /, /g')
    PRIV_CODE=$(_priv_code "${SEL_PRIVS}")
    _log "Selected privileges: ${GRANT_PRIV_CSV}  (code=${PRIV_CODE})"
    return 0
}

# ------------------------------------------------------------
# _choose_apply_method : pick how the privileges are applied.
#   result : APPLY_MODE = "INSERT" (DBM_PRIV_INF + trigger) | "GRANT"
#   return : 0 on success, 1 on invalid input
# ------------------------------------------------------------
_choose_apply_method() {
    local AMENU=("1. INSERT INTO DBADM.DBM_PRIV_INF  (trigger performs GRANT)"
                 "2. Direct GRANT                    (execute GRANT statements)")
    local _i
    _out "  Select apply method (Up/Down + Enter):\n"
    if _select_menu "${AMENU[@]}" ; then
        if [[ ${MENU_INDEX} -eq 0 ]] ; then APPLY_MODE="INSERT" ; else APPLY_MODE="GRANT" ; fi
    else
        for _i in "${!AMENU[@]}" ; do _out "    %s\n" "${AMENU[$_i]}"; done
        printf "  Enter apply method [1/2]: "
        read -r _i
        case "$(echo ${_i} | tr -d '[:space:]')" in
            1|"") APPLY_MODE="INSERT" ;;
            2)    APPLY_MODE="GRANT"  ;;
            *)    _fail "Invalid apply method: ${_i}" ; return 1 ;;
        esac
    fi
    _log "Apply method: ${APPLY_MODE}"
    return 0
}

# ------------------------------------------------------------
# _gen_insert_sql : build INSERT INTO DBADM.DBM_PRIV_INF scripts,
#                   one file per privilege, each ending with COMMIT;.
#   args   : OWNER GRANTEE "PRIV [PRIV ...]"
#   result : GEN_FILES (space separated), TOTAL_ROWS
#   return : 0 on success, 1 on sqlplus / zero-row failure
# ------------------------------------------------------------
_gen_insert_sql() {
    local OWNER="$1" GRANTEE="$2" PRIV_LIST="$3"
    local GEN="${TMP_DIR}/GRANT_GEN3I_$$.sql"
    local PRIV OUT f _c _rc

    GEN_FILES="" ; TOTAL_ROWS=0
    : > ${GEN}
    {
        echo "set pagesize 0"
        echo "set linesize 1000"
        echo "set long 9999"
        echo "set feedback off"
        echo "set heading off"
        echo "set echo off"
        echo "set verify off"
        echo "set trimspool on"
        echo ""
    } >> ${GEN}

    for PRIV in ${PRIV_LIST} ; do
        OUT="${SQL_OUT_DIR}/${FILE_PREFIX}_${GRANTEE}_$(_priv_code ${PRIV})_${YMD}_${HMS}.sql"
        : > ${OUT}
        GEN_FILES="${GEN_FILES} ${OUT}"
        {
            echo "spool ${OUT} append"
            echo "SELECT 'INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) '"
            echo "    || 'VALUES (''${PRIV}'',''' || OWNER || ''',''' || TABLE_NAME || ''',''${GRANTEE}'',SYSDATE);'"
            echo "  FROM DBA_TABLES WHERE OWNER = '${OWNER}' ORDER BY TABLE_NAME;"
            echo "spool off"
            echo ""
        } >> ${GEN}
    done
    echo "exit" >> ${GEN}

    sqlplus -s ${DB_USER}/${DB_PASS} @${GEN} < /dev/null >> ${LOGFILE}
    _rc=$?
    rm -f ${GEN}
    if [[ ${_rc} -ne 0 ]] ; then
        _fail "sqlplus failed while generating INSERT SQL"
        return 1
    fi

    for f in ${GEN_FILES} ; do
        if [[ -s "${f}" ]] ; then
            egrep -v "^[[:space:]]*$" ${f} > ${f}.tmp
            mv ${f}.tmp ${f}
        else
            : > ${f}
        fi
        echo "COMMIT;" >> ${f}
        _c=$(grep -c '^INSERT INTO' ${f})
        TOTAL_ROWS=$((TOTAL_ROWS + _c))
        _ok "$(basename ${f}) : ${_c} INSERT(s)"
    done

    if [[ ${TOTAL_ROWS} -eq 0 ]] ; then
        _fail "No tables found for OWNER=${OWNER}; nothing to insert"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# _gen_grant_sql : build a single file of GRANT statements.
#   args   : OWNER GRANTEE "PRIV, PRIV, ..."
#   result : GRANT_FILE, TOTAL_ROWS
#   return : 0 on success, 1 on sqlplus / zero-row failure
# ------------------------------------------------------------
_gen_grant_sql() {
    local OWNER="$1" GRANTEE="$2" CSV="$3"
    local GEN="${TMP_DIR}/GRANT_GEN3G_$$.sql"
    local _rc

    GRANT_FILE="${SQL_OUT_DIR}/${FILE_PREFIX}_${OWNER}_TO_${GRANTEE}_$(_priv_code "${CSV}")_${YMD}_${HMS}.sql"
    TOTAL_ROWS=0
    : > ${GRANT_FILE} ; : > ${GEN}
    {
        echo "set pagesize 0"
        echo "set linesize 1000"
        echo "set feedback off"
        echo "set heading off"
        echo "set echo off"
        echo "set verify off"
        echo "set trimspool on"
        echo ""
        echo "spool ${GRANT_FILE}"
        echo "SELECT 'GRANT ${CSV} ON ${OWNER}.' || TABLE_NAME || ' TO ${GRANTEE};'"
        echo "  FROM DBA_TABLES WHERE OWNER = '${OWNER}' ORDER BY TABLE_NAME;"
        echo "spool off"
        echo "exit"
    } >> ${GEN}

    sqlplus -s ${DB_USER}/${DB_PASS} @${GEN} < /dev/null >> ${LOGFILE}
    _rc=$?
    rm -f ${GEN}
    if [[ ${_rc} -ne 0 ]] ; then
        _fail "sqlplus failed while generating GRANT SQL"
        return 1
    fi

    [[ -s "${GRANT_FILE}" ]] && { egrep -v "^[[:space:]]*$" ${GRANT_FILE} > ${GRANT_FILE}.tmp ; mv ${GRANT_FILE}.tmp ${GRANT_FILE}; }
    TOTAL_ROWS=$(grep -c '^GRANT' ${GRANT_FILE})
    if [[ "${TOTAL_ROWS}" -eq 0 ]] ; then
        _fail "No tables found for OWNER=${OWNER}; nothing to grant"
        return 1
    fi
    _ok "$(basename ${GRANT_FILE}) : ${TOTAL_ROWS} GRANT(s)"
    return 0
}

# ============================================================
# Mode 2. Direct GRANT + CREATE SYNONYM
#   1) input OWNUSR (table owner schema)
#   2) input CONUSR (connection user) ; list RL% roles granted to it
#   3) pick a ROLE, then GRANT on OWNUSR tables + CREATE SYNONYM
# ============================================================
run_grant_mode() {
    local OWNUSR CONUSR ROLE ROLE_LST GEN2 GRANT_SQL SYN_SQL
    local G_CNT S_CNT ANSWER _r _i _l

    FILE_PREFIX="2"

    _out "%s\n" "$SEP"
    _log "Mode 2: Direct GRANT + CREATE SYNONYM"
    _out "%s\n" "$SEP"

    # 1) OWNUSR
    printf "  Enter OWNUSR (table owner schema): "
    read -r OWNUSR
    OWNUSR=$(echo "${OWNUSR}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    [[ -z "${OWNUSR}" ]] && { _fail "OWNUSR is required"; return 1; }

    # 2) CONUSR
    printf "  Enter CONUSR (connection user): "
    read -r CONUSR
    CONUSR=$(echo "${CONUSR}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    [[ -z "${CONUSR}" ]] && { _fail "CONUSR is required"; return 1; }

    # query RL% roles granted to CONUSR
    ROLE_LST="${TMP_DIR}/GRANT_ROLE_$$.lst"
    sqlplus -s ${DB_USER}/${DB_PASS} <<_EOF
set pagesize 0
set linesize 200
set feedback off
set heading off
set echo off
set verify off
set trimspool on
spool ${ROLE_LST}
SELECT GRANTED_ROLE FROM DBA_ROLE_PRIVS
 WHERE GRANTEE = '${CONUSR}' AND GRANTED_ROLE LIKE 'RL%'
 ORDER BY GRANTED_ROLE;
spool off
exit
_EOF
    egrep -v "^[[:space:]]*$" ${ROLE_LST} > ${ROLE_LST}.tmp 2>/dev/null
    mv ${ROLE_LST}.tmp ${ROLE_LST}
    if [[ ! -s "${ROLE_LST}" ]] ; then
        _fail "No RL% role granted to ${CONUSR} in DBA_ROLE_PRIVS"
        rm -f ${ROLE_LST}
        return 1
    fi

    # 3) pick a role (arrow menu, or typed fallback)
    local RMENU=()
    while read -r _r ; do [[ -n "${_r}" ]] && RMENU+=("${_r}"); done < ${ROLE_LST}
    rm -f ${ROLE_LST}
    _out "  RL roles granted to ${CONUSR} (Up/Down + Enter):\n"
    if _select_menu "${RMENU[@]}" ; then
        ROLE="${RMENU[$MENU_INDEX]}"
    else
        for _i in "${!RMENU[@]}" ; do _out "    %s\n" "${RMENU[$_i]}"; done
        printf "  Enter ROLE: "
        read -r ROLE
        ROLE=$(echo "${ROLE}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    fi
    [[ -z "${ROLE}" ]] && { _fail "ROLE is required"; return 1; }

    # 3b) choose privileges (SPACE toggle, Enter confirm; default all)
    _choose_privs || return 1
    _log "Target: OWNUSR=${OWNUSR}  CONUSR=${CONUSR}  ROLE=${ROLE}  PRIVS=${GRANT_PRIV_CSV}"

    # 4) generate GRANT + SYNONYM SQL from OWNUSR tables
    GRANT_SQL="${SQL_OUT_DIR}/${FILE_PREFIX}_${OWNUSR}_TO_${ROLE}_${PRIV_CODE}_${YMD}_${HMS}.sql"
    SYN_SQL="${SQL_OUT_DIR}/${FILE_PREFIX}_${CONUSR}_SYNONYM_${YMD}_${HMS}.sql"
    GEN2="${TMP_DIR}/GRANT_GEN2_$$.sql"
    : > ${GRANT_SQL} ; : > ${SYN_SQL} ; : > ${GEN2}
    {
        echo "set pagesize 0"
        echo "set linesize 1000"
        echo "set feedback off"
        echo "set heading off"
        echo "set echo off"
        echo "set verify off"
        echo "set trimspool on"
        echo ""
        echo "spool ${GRANT_SQL}"
        echo "SELECT 'GRANT ${GRANT_PRIV_CSV} ON ${OWNUSR}.' || TABLE_NAME || ' TO ${ROLE};'"
        echo "  FROM DBA_TABLES WHERE OWNER = '${OWNUSR}' ORDER BY TABLE_NAME;"
        echo "spool off"
        echo ""
        echo "spool ${SYN_SQL}"
        echo "SELECT 'CREATE SYNONYM ${CONUSR}.' || TABLE_NAME || ' FOR ${OWNUSR}.' || TABLE_NAME || ';'"
        echo "  FROM DBA_TABLES WHERE OWNER = '${OWNUSR}' ORDER BY TABLE_NAME;"
        echo "spool off"
        echo "exit"
    } >> ${GEN2}
    sqlplus -s ${DB_USER}/${DB_PASS} @${GEN2} < /dev/null >> ${LOGFILE}
    rm -f ${GEN2}

    for _l in "${GRANT_SQL}" "${SYN_SQL}" ; do
        [[ -s "${_l}" ]] && { egrep -v "^[[:space:]]*$" ${_l} > ${_l}.tmp ; mv ${_l}.tmp ${_l}; }
    done
    G_CNT=$(grep -c '^GRANT' ${GRANT_SQL})
    S_CNT=$(grep -c '^CREATE SYNONYM' ${SYN_SQL})
    if [[ "${G_CNT}" -eq 0 ]] ; then
        _fail "No tables found for OWNER=${OWNUSR}; nothing to grant"
        return 1
    fi
    _ok "$(basename ${GRANT_SQL}) : ${G_CNT} GRANT(s)"
    _ok "$(basename ${SYN_SQL}) : ${S_CNT} SYNONYM(s)"

    # 5) preview + confirm
    _out "%s\n" "$SEP"
    _log "Preview"
    _out "%s\n" "$SEP"
    _out "  --- GRANT (TOP 3) ---\n"
    grep '^GRANT' ${GRANT_SQL} | head -3 | while read -r _l ; do _out "  %s\n" "${_l}"; done
    _out "  --- SYNONYM (TOP 3) ---\n"
    grep '^CREATE SYNONYM' ${SYN_SQL} | head -3 | while read -r _l ; do _out "  %s\n" "${_l}"; done
    _out "\n"

    printf "Proceed with %s GRANT(s) and %s SYNONYM(s)? [y/N]: " "${G_CNT}" "${S_CNT}"
    read -r ANSWER
    if [[ "${ANSWER}" != "y" && "${ANSWER}" != "Y" ]] ; then
        _log "Cancelled by user (SQL files generated under ${SQL_OUT_DIR}, nothing executed)"
        return 0
    fi

    # 6) execute
    _out "%s\n" "$SEP"
    _log "Execute GRANT + CREATE SYNONYM via sqlplus"
    _out "%s\n" "$SEP"

    _log "  -> $(basename ${GRANT_SQL})"
    sqlplus -s ${DB_USER}/${DB_PASS} @${GRANT_SQL} < /dev/null >> ${LOGFILE}
    if [[ $? -ne 0 ]] ; then _fail "GRANT execution failed"; return 1; fi

    _log "  -> $(basename ${SYN_SQL})"
    sqlplus -s ${DB_USER}/${DB_PASS} @${SYN_SQL} < /dev/null >> ${LOGFILE}
    if [[ $? -ne 0 ]] ; then _fail "SYNONYM execution had errors (some may already exist)"; fi

    _ok "GRANTed on ${G_CNT} table(s) to ${ROLE}; ${S_CNT} SYNONYM(s) for ${CONUSR}"
    _log "Generated SQL files kept under: ${SQL_OUT_DIR}"
    return 0
}

# ============================================================
# Mode 3. ROLE based GRANT
#   1) list every RL_ role in DBA_ROLE_PRIVS -> pick one  (= GRANTEE)
#   2) list DISTINCT OWNER from DBA_TABLES   -> pick one  (= OWNUSR)
#   3) pick privileges          (_choose_privs)
#   4) pick how to apply them   (_choose_apply_method)
#   No synonym is created here; use Mode 2 when synonyms are needed.
# ============================================================
run_role_mode() {
    local ROLE OWNUSR ROLE_LST OWN_LST ANSWER f
    local RMENU=() RROLE=() OMENU=()
    local _g _r _o _i _l

    FILE_PREFIX="3"

    _out "%s\n" "$SEP"
    _log "Mode 3: ROLE based GRANT"
    _out "%s\n" "$SEP"

    # ------------------------------------------------------------
    # 1) RL_ roles from DBA_ROLE_PRIVS (GRANTEE, GRANTED_ROLE)
    #    'RL\_%' ESCAPE '\' : the underscore is a literal, not a wildcard
    # ------------------------------------------------------------
    ROLE_LST="${TMP_DIR}/GRANT_ROLE3_$$.lst"
    sqlplus -s ${DB_USER}/${DB_PASS} <<_EOF
set pagesize 0
set linesize 200
set feedback off
set heading off
set echo off
set verify off
set trimspool on
spool ${ROLE_LST}
SELECT GRANTEE || ' ' || GRANTED_ROLE
  FROM DBA_ROLE_PRIVS
 WHERE GRANTED_ROLE LIKE 'RL\_%' ESCAPE '\'
 ORDER BY GRANTEE, GRANTED_ROLE;
spool off
exit
_EOF
    if [[ $? -ne 0 ]] ; then _fail "sqlplus failed while reading DBA_ROLE_PRIVS"; return 1; fi

    egrep -v "^[[:space:]]*$" ${ROLE_LST} > ${ROLE_LST}.tmp 2>/dev/null
    mv ${ROLE_LST}.tmp ${ROLE_LST}
    if [[ ! -s "${ROLE_LST}" ]] ; then
        _fail "No RL_ role found in DBA_ROLE_PRIVS"
        rm -f ${ROLE_LST}
        return 1
    fi

    # The GRANTEE column is shown for context only (who already holds the
    # role); the selected GRANTED_ROLE is what receives the privileges.
    while read -r _g _r ; do
        [[ -z "${_r}" ]] && continue
        RMENU+=("$(printf 'GRANTEE=%-14s GRANTED_ROLE=%s' "${_g}" "${_r}")")
        RROLE+=("${_r}")
    done < ${ROLE_LST}
    rm -f ${ROLE_LST}

    _out "  RL_ roles in DBA_ROLE_PRIVS (Up/Down + Enter):\n"
    if _select_menu "${RMENU[@]}" ; then
        ROLE="${RROLE[$MENU_INDEX]}"
    else
        for _i in "${!RMENU[@]}" ; do _out "    %s\n" "${RMENU[$_i]}"; done
        printf "  Enter ROLE (GRANTED_ROLE): "
        read -r ROLE
        ROLE=$(echo "${ROLE}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    fi
    [[ -z "${ROLE}" ]] && { _fail "ROLE is required"; return 1; }
    _log "Selected ROLE (GRANTEE): ${ROLE}"

    # ------------------------------------------------------------
    # 2) DISTINCT OWNER from DBA_TABLES (single select)
    # ------------------------------------------------------------
    OWN_LST="${TMP_DIR}/GRANT_OWNER3_$$.lst"
    sqlplus -s ${DB_USER}/${DB_PASS} <<_EOF
set pagesize 0
set linesize 200
set feedback off
set heading off
set echo off
set verify off
set trimspool on
spool ${OWN_LST}
SELECT DISTINCT OWNER FROM DBA_TABLES ORDER BY OWNER ASC;
spool off
exit
_EOF
    if [[ $? -ne 0 ]] ; then _fail "sqlplus failed while reading DBA_TABLES"; return 1; fi

    egrep -v "^[[:space:]]*$" ${OWN_LST} > ${OWN_LST}.tmp 2>/dev/null
    mv ${OWN_LST}.tmp ${OWN_LST}
    if [[ ! -s "${OWN_LST}" ]] ; then
        _fail "No OWNER found in DBA_TABLES"
        rm -f ${OWN_LST}
        return 1
    fi
    while read -r _o ; do [[ -n "${_o}" ]] && OMENU+=("${_o}"); done < ${OWN_LST}
    rm -f ${OWN_LST}

    _out "  Table OWNER in DBA_TABLES (%s found, Up/Down + Enter):\n" "${#OMENU[@]}"
    if _select_menu "${OMENU[@]}" ; then
        OWNUSR="${OMENU[$MENU_INDEX]}"
    else
        for _i in "${!OMENU[@]}" ; do _out "    %s\n" "${OMENU[$_i]}"; done
        printf "  Enter OWNER: "
        read -r OWNUSR
        OWNUSR=$(echo "${OWNUSR}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    fi
    [[ -z "${OWNUSR}" ]] && { _fail "OWNER is required"; return 1; }
    _log "Selected OWNER: ${OWNUSR}"

    # ------------------------------------------------------------
    # 3) privileges  4) apply method
    # ------------------------------------------------------------
    _choose_privs || return 1
    _choose_apply_method || return 1
    _log "Target: OWNER=${OWNUSR}  GRANTEE=${ROLE}  PRIVS=${GRANT_PRIV_CSV}  APPLY=${APPLY_MODE}"

    # ------------------------------------------------------------
    # 5) generate SQL -> ./sql/
    # ------------------------------------------------------------
    _out "%s\n" "$SEP"
    _log "Generate SQL -> ${SQL_OUT_DIR}"
    _out "%s\n" "$SEP"

    if [[ "${APPLY_MODE}" == "INSERT" ]] ; then
        _gen_insert_sql "${OWNUSR}" "${ROLE}" "${SEL_PRIVS}" || return 1
    else
        _gen_grant_sql "${OWNUSR}" "${ROLE}" "${GRANT_PRIV_CSV}" || return 1
    fi

    # ------------------------------------------------------------
    # 6) preview + confirm
    # ------------------------------------------------------------
    _out "%s\n" "$SEP"
    _log "Preview"
    _out "%s\n" "$SEP"
    if [[ "${APPLY_MODE}" == "INSERT" ]] ; then
        for f in ${GEN_FILES} ; do
            _out "  --- %s (TOP 3) ---\n" "$(basename ${f})"
            grep '^INSERT INTO' ${f} | head -3 | while read -r _l ; do _out "  %s\n" "${_l}"; done
        done
        _out "\n"
        printf "Proceed with INSERT of %s row(s) into DBADM.DBM_PRIV_INF? [y/N]: " "${TOTAL_ROWS}"
    else
        _out "  --- %s (TOP 3) ---\n" "$(basename ${GRANT_FILE})"
        grep '^GRANT' ${GRANT_FILE} | head -3 | while read -r _l ; do _out "  %s\n" "${_l}"; done
        _out "\n"
        printf "Proceed with %s GRANT(s) to %s? [y/N]: " "${TOTAL_ROWS}" "${ROLE}"
    fi
    read -r ANSWER
    if [[ "${ANSWER}" != "y" && "${ANSWER}" != "Y" ]] ; then
        _log "Cancelled by user (SQL files generated under ${SQL_OUT_DIR}, nothing executed)"
        return 0
    fi

    # ------------------------------------------------------------
    # 7) execute
    # ------------------------------------------------------------
    _out "%s\n" "$SEP"
    if [[ "${APPLY_MODE}" == "INSERT" ]] ; then
        _log "Execute INSERT via sqlplus (trigger will GRANT)"
        _out "%s\n" "$SEP"
        for f in ${GEN_FILES} ; do
            _log "  -> $(basename ${f})"
            # generated files end with COMMIT; (no EXIT) -> feed EOF
            sqlplus -s ${DB_USER}/${DB_PASS} @${f} < /dev/null >> ${LOGFILE}
            if [[ $? -ne 0 ]] ; then _fail "Failed to execute: ${f}"; return 1; fi
        done
        _ok "Granted privileges via ${TOTAL_ROWS} INSERT(s) into DBADM.DBM_PRIV_INF (GRANTEE=${ROLE})"
    else
        _log "Execute GRANT via sqlplus"
        _out "%s\n" "$SEP"
        _log "  -> $(basename ${GRANT_FILE})"
        sqlplus -s ${DB_USER}/${DB_PASS} @${GRANT_FILE} < /dev/null >> ${LOGFILE}
        if [[ $? -ne 0 ]] ; then _fail "GRANT execution failed"; return 1; fi
        _ok "GRANTed on ${TOTAL_ROWS} table(s) of ${OWNUSR} to ${ROLE}"
    fi

    _log "Generated SQL files kept under: ${SQL_OUT_DIR}"
    return 0
}

# ============================================================
# Operation menu : choose mode 1 or mode 2
# ============================================================
_out "%s\n" "$SEP"
_log "Select operation"
_out "%s\n" "$SEP"

OP_OPTS=("1. Trigger Grants (INSERT INTO DBADM.DBM_PRIV_INF)"
         "2. Direct GRANT + CREATE SYNONYM"
         "3. ROLE based GRANT (pick RL_ role + OWNER)")
_out "  Select operation (Up/Down + Enter):\n"
if _select_menu "${OP_OPTS[@]}" ; then
    OP_MODE=$((MENU_INDEX + 1))
else
    for _i in "${!OP_OPTS[@]}" ; do _out "    %s\n" "${OP_OPTS[$_i]}"; done
    printf "  Enter operation [1/2/3]: "
    read -r OP_MODE
    OP_MODE=$(echo "${OP_MODE}" | tr -d '[:space:]')
fi
_log "Operation mode = ${OP_MODE}"

if [[ "${OP_MODE}" == "2" ]] ; then
    run_grant_mode
    _RC=$?
    _cleanup
    exit ${_RC}
fi

if [[ "${OP_MODE}" == "3" ]] ; then
    run_role_mode
    _RC=$?
    _cleanup
    exit ${_RC}
fi

# ============================================================
# Mode 1 (default) : INSERT INTO DBADM.DBM_PRIV_INF
# ============================================================
FILE_PREFIX="1"

# ============================================================
# Pass 1. Read ALL targets from DBM_USR_INF, then let the user
#         pick a BSN interactively (blank/ALL = all BSN)
# ============================================================
_out "%s\n" "$SEP"
_log "Pass 1: read available targets from DBADM.DBM_USR_INF"
_out "%s\n" "$SEP"

ALL_LST="${TMP_DIR}/GRANT_PRIV_ALL_$$.lst"

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

# Remove blank lines
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

_TGT_CNT=$(wc -l < ${TGT_LST})
_ok "Selected ${_TGT_CNT} target(s)"
while read -r _b _o _c ; do
    _out "  BSN=%-12s OWNUSR=%-12s CONUSR=%-12s\n" "${_b}" "${_o}" "${_c}"
done < ${TGT_LST}

# --- Choose privileges (default: all four) ---
_choose_privs || { _cleanup; exit 1; }

# ============================================================
# Pass 2. Generate INSERT SQL files per (BSN, PRIVILEGE)
#   - one file per BSN per privilege : {BSN}_{PRIV}_{YMD}_{HMS}.sql
#   - INSERT rows for every table of OWNUSR in DBA_TABLES
#   - GRANTEE = RL_{BSN}_ALL ; last line = COMMIT;
# ============================================================
_out "%s\n" "$SEP"
_log "Pass 2: generate INSERT SQL files -> ${SQL_OUT_DIR}"
_out "%s\n" "$SEP"

# Distinct BSN list (keep order)
BSNS=$(awk '{print $1}' ${TGT_LST} | awk '!seen[$0]++')

# Reset target-generation script
: > ${TGT_SQL}
echo "set pagesize 0"     >> ${TGT_SQL}
echo "set linesize 1000"  >> ${TGT_SQL}
echo "set long 9999"      >> ${TGT_SQL}
echo "set feedback off"   >> ${TGT_SQL}
echo "set heading off"    >> ${TGT_SQL}
echo "set echo off"       >> ${TGT_SQL}
echo "set verify off"     >> ${TGT_SQL}
echo "set trimspool on"   >> ${TGT_SQL}
echo ""                   >> ${TGT_SQL}

# Track generated files (space separated) per privilege for later execution
GEN_FILES=""

for BSN in ${BSNS} ; do
    GRANTEE="RL_${BSN}_ALL"
    for PRIV in ${SEL_PRIVS} ; do
        OUT_SQL="${SQL_OUT_DIR}/${FILE_PREFIX}_${BSN}_$(_priv_code ${PRIV})_${YMD}_${HMS}.sql"
        : > ${OUT_SQL}
        GEN_FILES="${GEN_FILES} ${OUT_SQL}"

        # For every OWNUSR belonging to this BSN, spool INSERT statements
        awk -v bsn="${BSN}" '$1==bsn {print $2}' ${TGT_LST} | awk '!seen[$0]++' | while read -r OWNUSR ; do
            {
              echo "spool ${OUT_SQL} append"
              echo "SELECT 'INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) '"
              echo "    || 'VALUES (''${PRIV}'',''' || OWNER || ''',''' || TABLE_NAME || ''',''${GRANTEE}'',SYSDATE);'"
              echo "  FROM DBA_TABLES WHERE OWNER = '${OWNUSR}' ORDER BY TABLE_NAME;"
              echo "spool off"
              echo ""
            } >> ${TGT_SQL}
        done
    done
done

echo "exit" >> ${TGT_SQL}

# Run the generation script (spools INSERT statements into each OUT_SQL)
sqlplus -s ${DB_USER}/${DB_PASS} @${TGT_SQL} >> ${LOGFILE}

# Clean up each generated file (strip blank lines) and append COMMIT;
TOTAL=0
for f in ${GEN_FILES} ; do
    if [[ -s "${f}" ]] ; then
        egrep -v "^[[:space:]]*$" ${f} > ${f}.tmp
        mv ${f}.tmp ${f}
    else
        : > ${f}
    fi
    echo "COMMIT;" >> ${f}
    _c=$(grep -c '^INSERT INTO' ${f})
    TOTAL=$((TOTAL + _c))
    _ok "$(basename ${f}) : ${_c} INSERT(s)"
done

if [[ ${TOTAL} -eq 0 ]] ; then
    _fail "No tables found for the target owner(s); nothing to grant"
    _cleanup
    exit 1
fi

# ============================================================
# Pass 3. Preview + confirm
# ============================================================
_out "%s\n" "$SEP"
_log "INSERT preview"
_out "%s\n" "$SEP"
_out "  Total INSERT rows : %s\n\n" "${TOTAL}"

for f in ${GEN_FILES} ; do
    _out "  --- %s (TOP 3) ---\n" "$(basename ${f})"
    grep '^INSERT INTO' ${f} | head -3 | while read -r _line ; do _out "  %s\n" "${_line}"; done
done
_out "\n"

printf "Proceed with INSERT of %s row(s) into DBADM.DBM_PRIV_INF? [y/N]: " "${TOTAL}"
read -r ANSWER
if [[ "${ANSWER}" != "y" && "${ANSWER}" != "Y" ]] ; then
    _log "INSERT cancelled by user (SQL files generated, no rows inserted)"
    _cleanup
    exit 0
fi

# ============================================================
# Pass 4. Execute INSERT via sqlplus (trigger performs GRANT)
# ============================================================
_out "%s\n" "$SEP"
_log "Execute INSERT via sqlplus (trigger will GRANT)"
_out "%s\n" "$SEP"

for f in ${GEN_FILES} ; do
    _log "  -> $(basename ${f})"
    # stdin from /dev/null: the generated file ends with COMMIT; (no EXIT),
    # so feed EOF to make sqlplus quit instead of waiting at the SQL> prompt.
    sqlplus -s ${DB_USER}/${DB_PASS} @${f} < /dev/null >> ${LOGFILE}
    if [[ $? -ne 0 ]] ; then
        _fail "Failed to execute: ${f}"
        _cleanup
        exit 1
    fi
done

_cleanup
_ok "Granted privileges via ${TOTAL} INSERT(s) into DBADM.DBM_PRIV_INF"
_log "Generated SQL files kept under: ${SQL_OUT_DIR}"
exit 0
