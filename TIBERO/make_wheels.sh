#!/bin/bash
#############################################################
# 폐쇄망 설치용 wheel 수집 (RHEL 8.10 / Python 3.8 = cp38)
#
#   ./make_wheels.sh              # cp38 / manylinux x86_64 용으로 내려받기
#   ./make_wheels.sh -n           # 현재 실행 중인 파이썬 환경 기준(native)으로 내려받기
#   ./make_wheels.sh -d /path/dir # 저장 위치 지정 (기본 ./wheels)
#
# 인터넷이 되는 서버에서 실행한 뒤, wheels/ 디렉터리를 대상 서버의
# TIBERO/wheels 로 복사하면 run.sh / run.py 가 --no-index 로 설치한다.
#
#   대상 서버:  ./run.sh          (wheels/ 감지 시 자동 오프라인 설치)
#   수동 설치:  python3.8 -m pip install --no-index --find-links wheels -r requirements.txt
#############################################################

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}" || exit 1

REQ_FILE="${SCRIPT_DIR}/requirements.txt"
DEST="${SCRIPT_DIR}/wheels"
NATIVE=0

# 대상 환경: RHEL 8.10 x86_64 + python38 (RPM python38 = cp38, glibc 2.28 → manylinux_2_28/2014)
PY_VERSION="3.8"
ABI="cp38"
PLATFORMS=("manylinux_2_28_x86_64" "manylinux2014_x86_64" "manylinux1_x86_64")

TS=$(date '+%Y%m%d_%H%M%S')
LOG_DIR="${SCRIPT_DIR}/log"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/make_wheels_${TS}.log"

_out()  { echo -e "$1" | tee -a "${LOG_FILE}"; }
_log()  { _out "[INFO] $1"; }
_ok()   { _out "[ OK ] $1"; }
_fail() { _out "[FAIL] $1"; }

usage() {
    echo "Usage: $0 [-n] [-d DEST_DIR]"
    echo "  -n          현재 파이썬 환경 기준으로 다운로드 (대상 서버에서 직접 실행할 때)"
    echo "  -d DEST_DIR 저장 디렉터리 (기본: ./wheels)"
    exit 1
}

while getopts "nd:h" opt; do
    case "${opt}" in
        n) NATIVE=1 ;;
        d) DEST="${OPTARG}" ;;
        *) usage ;;
    esac
done

[ -f "${REQ_FILE}" ] || { _fail "requirements.txt 가 없습니다: ${REQ_FILE}"; exit 1; }

PY="${PYTHON_BIN:-python3}"
command -v "${PY}" >/dev/null 2>&1 || { _fail "python 을 찾을 수 없습니다 (PYTHON_BIN 지정)"; exit 1; }

_log "python : $(${PY} -V 2>&1) (${PY})"
_log "pip    : $(${PY} -m pip -V 2>&1)"
_log "대상   : $([ ${NATIVE} -eq 1 ] && echo 'native (현재 환경)' || echo "cp38 / ${PLATFORMS[0]} 외")"
_log "저장   : ${DEST}"

if [ -d "${DEST}" ] && [ -n "$(ls -A "${DEST}" 2>/dev/null)" ]; then
    _log "기존 파일 $(ls -1 "${DEST}" | wc -l) 개가 있습니다 (덮어쓰기/추가됨)."
    read -r -p "       계속할까요? (y/N): " ans
    [ "${ans}" = "y" ] || [ "${ans}" = "Y" ] || { _log "취소했습니다."; exit 0; }
fi
mkdir -p "${DEST}"

CMD=("${PY}" -m pip download -r "${REQ_FILE}" -d "${DEST}")
if [ ${NATIVE} -eq 0 ]; then
    # 크로스 다운로드는 소스 빌드를 할 수 없으므로 바이너리 휠만 받는다
    CMD+=(--only-binary=:all: --python-version "${PY_VERSION}" --implementation cp --abi "${ABI}")
    for p in "${PLATFORMS[@]}"; do
        CMD+=(--platform "${p}")
    done
fi

_log "$ ${CMD[*]}"
"${CMD[@]}" 2>&1 | tee -a "${LOG_FILE}"
RC=${PIPESTATUS[0]}

if [ ${RC} -ne 0 ]; then
    _fail "다운로드 실패 (rc=${RC}). 로그: ${LOG_FILE}"
    _fail "  - pip 가 오래되어 --platform 다중 지정을 못 하면: ${PY} -m pip install -U pip"
    _fail "  - 그래도 실패하면 대상 서버에서 './make_wheels.sh -n' 으로 받으세요."
    exit ${RC}
fi

COUNT=$(ls -1 "${DEST}" | wc -l)
SIZE=$(du -sh "${DEST}" | cut -f1)
_ok "wheel ${COUNT} 개 / ${SIZE} → ${DEST}"
_log ""
_log "다음 단계:"
_log "  1) tar czf tibero_web.tar.gz app.py run.py run.sh requirements.txt wheels/"
_log "  2) 대상 서버(RHEL 8.10)로 복사 후 압축 해제"
_log "  3) PG.env 작성 → ./run.sh"
