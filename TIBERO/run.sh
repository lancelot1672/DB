#!/bin/bash
#############################################################
# SQL Grid Web 실행 (RHEL 8.10 / Python 3.8)
#
#   ./run.sh                 # venv 확인 → 의존성 확인 → 기동 (0.0.0.0:8501)
#   ./run.sh --port 8600
#   ./run.sh --host 127.0.0.1
#   PYTHON_BIN=/usr/bin/python3.8 ./run.sh
#
# venv(.venv) 가 있으면 그것으로 실행하고, 없으면 y/N 확인 후 생성한다.
# 폐쇄망이면 wheels/ 디렉터리를 함께 복사해 두면 오프라인으로 설치된다.
#############################################################

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}" || exit 1

VENV_DIR="${SCRIPT_DIR}/.venv"
WHEEL_DIR="${SCRIPT_DIR}/wheels"
LOG_DIR="${SCRIPT_DIR}/log"
TS=$(date '+%Y%m%d_%H%M%S')

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/run_${TS}.log"

_out()  { echo -e "$1" | tee -a "${LOG_FILE}"; }
_log()  { _out "[INFO] $1"; }
_ok()   { _out "[ OK ] $1"; }
_fail() { _out "[FAIL] $1"; }

#-----------------------------------------------------------
# 1. Python 3.8 탐색
#-----------------------------------------------------------
find_python() {
    if [ -n "${PYTHON_BIN}" ]; then
        command -v "${PYTHON_BIN}" >/dev/null 2>&1 && { echo "${PYTHON_BIN}"; return 0; }
        return 1
    fi
    for cand in python3.8 /usr/bin/python3.8 python3; do
        command -v "${cand}" >/dev/null 2>&1 || continue
        # 3.8 이상만 허용
        if "${cand}" -c 'import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)' 2>/dev/null; then
            echo "${cand}"
            return 0
        fi
    done
    return 1
}

#-----------------------------------------------------------
# 2. venv 준비
#-----------------------------------------------------------
setup_venv() {
    local py="$1"
    _log "venv 가 없습니다: ${VENV_DIR}"
    read -r -p "       지금 생성할까요? (y/N): " ans
    if [ "${ans}" != "y" ] && [ "${ans}" != "Y" ]; then
        _log "venv 없이 ${py} 로 진행합니다. (패키지는 --user 영역에 설치됨)"
        return 1
    fi

    "${py}" -m venv "${VENV_DIR}" 2>&1 | tee -a "${LOG_FILE}"
    if [ "${PIPESTATUS[0]}" -ne 0 ] || [ ! -x "${VENV_DIR}/bin/python" ]; then
        _fail "venv 생성 실패. (RHEL 8: sudo dnf install -y python38 python38-devel)"
        return 1
    fi
    _ok "venv 생성: ${VENV_DIR}"

    # 오프라인이면 pip 업그레이드를 건너뛴다
    if [ -d "${WHEEL_DIR}" ]; then
        _log "오프라인 wheels 감지 — pip 업그레이드 생략"
    else
        "${VENV_DIR}/bin/python" -m pip install --upgrade pip >>"${LOG_FILE}" 2>&1
    fi
    return 0
}

#-----------------------------------------------------------
# 3. 실행
#-----------------------------------------------------------
PY=$(find_python)
if [ -z "${PY}" ]; then
    _fail "Python 3.8 이상을 찾을 수 없습니다."
    _fail "  RHEL 8: sudo dnf install -y python38 python38-devel"
    _fail "  또는 PYTHON_BIN=/path/to/python3.8 ./run.sh"
    exit 1
fi
_ok "Python: $(${PY} -V 2>&1) (${PY})"

if [ -x "${VENV_DIR}/bin/python" ]; then
    PY="${VENV_DIR}/bin/python"
    _ok "venv 사용: ${VENV_DIR}"
else
    setup_venv "${PY}" && PY="${VENV_DIR}/bin/python"
fi

_log "run.py 실행 (로그: ${LOG_FILE})"
exec "${PY}" "${SCRIPT_DIR}/run.py" "$@"
