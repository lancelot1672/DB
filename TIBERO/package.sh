#!/bin/bash
#############################################################
# 폐쇄망 반입용 배포 패키지(tar.gz) 생성
#
#   ./package.sh              # tibero_sqlgrid_<timestamp>.tar.gz 생성
#   ./package.sh -o /data     # 출력 디렉터리 지정 (기본 ./dist)
#   ./package.sh -E           # PG.env 를 함께 포함 (자격증명 포함! 기본은 제외)
#   ./package.sh -s           # wheels 의존성 폐쇄 검증 생략
#
# 포함: app.py run.py run.sh start.sh make_wheels.sh requirements.txt wheels/ 문서 더미SQL
# 제외: PG.env(자격증명) queries/(저장 쿼리) .venv/(445M) tbcheck(596M) dist/ log/ __pycache__ *.swp .git
#
# 반입 후 대상 서버(RHEL 8.10 / Python 3.8):
#   tar xzf tibero_sqlgrid_<ts>.tar.gz && cd tibero_sqlgrid
#   cp PG.env.example PG.env && vi PG.env && chmod 600 PG.env
#   ./run.sh                      # 포그라운드
#   ./start.sh                    # 백그라운드(nohup)
#############################################################

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}" || exit 1

PKG_NAME="tibero_sqlgrid"
OUT_DIR="${SCRIPT_DIR}/dist"
WHEEL_DIR="${SCRIPT_DIR}/wheels"
REQ_FILE="${SCRIPT_DIR}/requirements.txt"
WITH_ENV=0
SKIP_VERIFY=0

TS=$(date '+%Y%m%d_%H%M%S')
LOG_DIR="${SCRIPT_DIR}/log"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/package_${TS}.log"

_out()  { echo -e "$1" | tee -a "${LOG_FILE}"; }
_log()  { _out "[INFO] $1"; }
_ok()   { _out "[ OK ] $1"; }
_warn() { _out "[WARN] $1"; }
_fail() { _out "[FAIL] $1"; }

# 반입 대상 — 여기 없는 파일은 패키지에 들어가지 않는다.
CORE_FILES=(app.py run.py run.sh start.sh make_wheels.sh requirements.txt)
DOC_FILES=(README.md SQL_GRID_WEB_PLAN.md SQL_EXECUTE.html CLAUDE_DESIGN_PROMPT.md)
DATA_FILES=(dummy_data.sql dummy_data_300k.sql)

usage() {
    echo "Usage: $0 [-o OUT_DIR] [-E] [-s]"
    echo "  -o OUT_DIR  tar.gz 저장 위치 (기본: ./dist)"
    echo "  -E          PG.env 포함 (실제 접속 자격증명이 반출됩니다)"
    echo "  -s          wheels 의존성 폐쇄 검증 생략"
    exit 1
}

while getopts "o:Esh" opt; do
    case "${opt}" in
        o) OUT_DIR="${OPTARG}" ;;
        E) WITH_ENV=1 ;;
        s) SKIP_VERIFY=1 ;;
        *) usage ;;
    esac
done

STAGE=""
_cleanup() { [ -n "${STAGE}" ] && [ -d "${STAGE}" ] && rm -rf "${STAGE}"; }
trap _cleanup EXIT INT TERM

#-----------------------------------------------------------
# 1. 필수 파일 확인
#-----------------------------------------------------------
MISSING=()
for f in "${CORE_FILES[@]}"; do
    [ -f "${SCRIPT_DIR}/${f}" ] || MISSING+=("${f}")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    _fail "필수 파일이 없습니다: ${MISSING[*]}"
    exit 1
fi

if [ ! -d "${WHEEL_DIR}" ] || [ -z "$(ls -A "${WHEEL_DIR}"/*.whl 2>/dev/null)" ]; then
    _fail "wheels/ 가 비어 있습니다. 먼저 수집하세요: ./make_wheels.sh"
    _fail "  (폐쇄망에는 인터넷이 없으므로 wheel 없이 반입하면 설치가 불가능합니다)"
    exit 1
fi
WHEEL_COUNT=$(ls -1 "${WHEEL_DIR}"/*.whl 2>/dev/null | wc -l)
_log "wheels : ${WHEEL_COUNT} 개 / $(du -sh "${WHEEL_DIR}" | cut -f1)"

#-----------------------------------------------------------
# 2. 의존성 폐쇄 검증 — 반입 후에야 실패하는 사고를 막는다
#    (make_wheels.sh 와 동일한 검사. 수집과 반입 사이에 파일이 유실됐을 수 있다.)
#-----------------------------------------------------------
find_py38() {
    local cand
    for cand in "${SCRIPT_DIR}/.venv/bin/python" python3.8 /usr/bin/python3.8; do
        command -v "${cand}" >/dev/null 2>&1 || continue
        "${cand}" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3,8) else 1)' 2>/dev/null \
            || continue
        # --dry-run 은 pip 22.2+ 에서만 지원
        "${cand}" -c 'import pip,sys; v=tuple(int(x) for x in pip.__version__.split(".")[:2]); sys.exit(0 if v >= (22,2) else 1)' 2>/dev/null \
            && { echo "${cand}"; return 0; }
    done
    return 1
}

if [ ${SKIP_VERIFY} -eq 1 ]; then
    _warn "폐쇄 검증을 생략합니다 (-s)."
else
    VPY=$(find_py38)
    if [ -z "${VPY}" ]; then
        _warn "검증용 Python 3.8 (pip 22.2+) 이 없어 폐쇄 검증을 건너뜁니다."
        _warn "  반입 전 대상과 동일한 환경에서 아래를 확인하세요:"
        _warn "    python3.8 -m pip install --no-index --find-links wheels -r requirements.txt"
        read -r -p "       그래도 계속할까요? (y/N): " ans
        [ "${ans}" = "y" ] || [ "${ans}" = "Y" ] || { _log "취소했습니다."; exit 0; }
    else
        _log "의존성 폐쇄 검증 (${VPY})"
        if ! "${VPY}" -m pip install --no-index --find-links "${WHEEL_DIR}" \
                -r "${REQ_FILE}" --dry-run --ignore-installed >>"${LOG_FILE}" 2>&1; then
            _fail "wheels/ 만으로는 설치가 불가능합니다 — 의존성이 빠져 있습니다."
            _fail "  로그: ${LOG_FILE}"
            _fail "  ./make_wheels.sh -c 로 다시 수집하세요."
            exit 1
        fi
        _ok "의존성 폐쇄 검증 완료 — wheels/ 만으로 설치 가능"
    fi
fi

#-----------------------------------------------------------
# 3. 스테이징 — 넣을 것만 복사한다(제외 목록 방식은 새 파일이 생기면 샌다)
#-----------------------------------------------------------
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/${PKG_NAME}_$$_XXXXXX") || { _fail "임시 디렉터리 생성 실패"; exit 1; }
ROOT="${STAGE}/${PKG_NAME}"
mkdir -p "${ROOT}" || exit 1

for f in "${CORE_FILES[@]}"; do
    cp -p "${SCRIPT_DIR}/${f}" "${ROOT}/" || { _fail "복사 실패: ${f}"; exit 1; }
done
for f in "${DOC_FILES[@]}" "${DATA_FILES[@]}"; do
    [ -f "${SCRIPT_DIR}/${f}" ] && cp -p "${SCRIPT_DIR}/${f}" "${ROOT}/"
done

# 대상 서버에서 바로 실행할 수 있어야 한다 (git 에 실행 권한이 없는 경우 대비)
chmod +x "${ROOT}/run.sh" "${ROOT}/start.sh" "${ROOT}/make_wheels.sh" 2>/dev/null

mkdir -p "${ROOT}/wheels"
cp -p "${WHEEL_DIR}"/*.whl "${ROOT}/wheels/" || { _fail "wheel 복사 실패"; exit 1; }
[ -n "$(ls -A "${WHEEL_DIR}"/*.tar.gz 2>/dev/null)" ] && cp -p "${WHEEL_DIR}"/*.tar.gz "${ROOT}/wheels/"

# 접속 정보 — 기본은 템플릿만. 실제 PG.env 는 -E 를 줘야 들어간다.
cat > "${ROOT}/PG.env.example" <<'EOF'
# PostgreSQL 접속 정보 — PG.env 로 복사해서 채운 뒤 chmod 600
PG_HOST=localhost
PG_PORT=5432
PG_DBNAME=
PG_USER=
PG_PASSWORD=
EOF

if [ ${WITH_ENV} -eq 1 ]; then
    if [ -f "${SCRIPT_DIR}/PG.env" ]; then
        _warn "PG.env 를 포함합니다 — 접속 자격증명이 tar.gz 안에 그대로 들어갑니다."
        read -r -p "       계속할까요? (y/N): " ans
        if [ "${ans}" = "y" ] || [ "${ans}" = "Y" ]; then
            cp -p "${SCRIPT_DIR}/PG.env" "${ROOT}/PG.env"
            chmod 600 "${ROOT}/PG.env"
            _ok "PG.env 포함"
        else
            _log "PG.env 는 제외합니다."
        fi
    else
        _warn "-E 를 줬지만 PG.env 가 없습니다. 템플릿만 넣습니다."
    fi
else
    _log "PG.env 제외 (자격증명 반출 방지). 포함하려면 -E"
fi

mkdir -p "${ROOT}/log"
: > "${ROOT}/log/.gitkeep"

#-----------------------------------------------------------
# 4. tar.gz 생성
#-----------------------------------------------------------
mkdir -p "${OUT_DIR}" || { _fail "출력 디렉터리 생성 실패: ${OUT_DIR}"; exit 1; }
OUT_DIR=$(cd "${OUT_DIR}" && pwd)
TARBALL="${OUT_DIR}/${PKG_NAME}_${TS}.tar.gz"

if [ -e "${TARBALL}" ]; then
    read -r -p "       ${TARBALL} 이 이미 있습니다. 덮어쓸까요? (y/N): " ans
    [ "${ans}" = "y" ] || [ "${ans}" = "Y" ] || { _log "취소했습니다."; exit 0; }
fi

# -C STAGE: tar 안에 최상위 디렉터리 하나만 두어 압축 해제 시 흩어지지 않게 한다
tar czf "${TARBALL}" -C "${STAGE}" "${PKG_NAME}" 2>&1 | tee -a "${LOG_FILE}"
if [ "${PIPESTATUS[0]}" -ne 0 ] || [ ! -f "${TARBALL}" ]; then
    _fail "tar 생성 실패: ${TARBALL}"
    exit 1
fi

#-----------------------------------------------------------
# 5. 검증 + 체크섬 (매체를 건너가며 깨지는 일이 잦다)
#-----------------------------------------------------------
if ! tar tzf "${TARBALL}" >/dev/null 2>&1; then
    _fail "생성된 tar.gz 를 읽을 수 없습니다: ${TARBALL}"
    exit 1
fi

SUMFILE="${TARBALL}.sha256"
( cd "${OUT_DIR}" && sha256sum "$(basename "${TARBALL}")" > "$(basename "${SUMFILE}")" ) 2>/dev/null

ENTRIES=$(tar tzf "${TARBALL}" | wc -l)
SIZE=$(du -h "${TARBALL}" | cut -f1)

_ok "패키지 생성 완료"
_log "  파일   : ${TARBALL}"
_log "  크기   : ${SIZE} (항목 ${ENTRIES} 개, wheel ${WHEEL_COUNT} 개)"
[ -f "${SUMFILE}" ] && _log "  체크섬 : ${SUMFILE}"

# 반출되면 안 되는 것이 섞였는지 최종 확인 — 스테이징 실수에 대한 안전망
# queries/ = 사용자가 저장한 조회 SQL(사내 스키마/테이블명). 대상 서버에서 새로 만들어진다.
LEAK=$(tar tzf "${TARBALL}" | grep -E "(^|/)(\.venv/|tbcheck$|__pycache__/|\.git/|queries/)|\.pyc$|\.swp$" | head -5)
if [ -n "${LEAK}" ]; then
    _fail "제외 대상이 포함됐습니다:"
    echo "${LEAK}" | tee -a "${LOG_FILE}"
    exit 1
fi
if [ ${WITH_ENV} -eq 0 ] && tar tzf "${TARBALL}" | grep -qE "(^|/)PG\.env$"; then
    _fail "PG.env 가 포함됐습니다 (의도치 않은 자격증명 반출)."
    exit 1
fi
_ok "제외 항목 확인 완료 (.venv / tbcheck / log / queries / __pycache__ 미포함)"

_log ""
_log "폐쇄망 반입 후:"
_log "  sha256sum -c $(basename "${SUMFILE}")"
_log "  tar xzf $(basename "${TARBALL}")"
_log "  cd ${PKG_NAME}"
_log "  cp PG.env.example PG.env && vi PG.env && chmod 600 PG.env"
_log "  ./run.sh                      # 포그라운드 (또는 ./run.sh --port 8600)"
_log "  ./start.sh                    # 백그라운드 기동 (nohup, 로그: run.log)"
