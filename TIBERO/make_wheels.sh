#!/bin/bash
#############################################################
# 폐쇄망 설치용 wheel 수집 (RHEL 8.10 / Python 3.8 = cp38)
#
#   ./make_wheels.sh              # cp38 / manylinux x86_64 용으로 내려받기
#   ./make_wheels.sh -c           # 기존 wheels/ 를 비우고 새로 받기 (부분 수집 잔재 제거)
#   ./make_wheels.sh -n           # 현재 실행 중인 파이썬 환경 기준(native)으로 내려받기
#   ./make_wheels.sh -d /path/dir # 저장 위치 지정 (기본 ./wheels)
#
# !! 반드시 Python 3.8 로 실행할 것 (pip 22.0 이상).
#    pip 의 --python-version 은 wheel 태그 선택에만 적용되고 환경 마커
#    (python_version < '3.9') 평가에는 적용되지 않는다. 3.9+ 로 수집하면
#    importlib-resources / pkgutil-resolve-name / zipp 이 조용히 누락된다.
#    스크립트가 python3.8 을 자동 탐색하며, 아니면 실행을 거부한다.
#      PYTHON_BIN=/usr/bin/python3.8 ./make_wheels.sh
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
CLEAN=0

# 대상 환경: RHEL 8.10 x86_64 + python38 (RPM python38 = cp38, glibc 2.28)
PY_VERSION="3.8"
ABI="cp38"
# pip 은 --platform 문자열과 wheel 태그를 "정확히" 일치시킨다.
# pandas 처럼 manylinux_2_17_x86_64.manylinux2014_x86_64 로 압축 태그를 쓰는 휠도 있지만,
# pyarrow 처럼 manylinux_2_17_x86_64 단독 태그로만 배포되는 휠도 있어
# glibc 2.28(RHEL 8) 에서 설치 가능한 태그를 모두 나열해야 누락되지 않는다.
#
# 순서 주의: 구버전 pip 도 읽을 수 있는 manylinux2014/2_17 계열을 앞에 두고,
# 그 태그로는 배포되지 않는 패키지를 위해 manylinux_2_28 을 마지막에 둔다.
# (manylinux_2_28 = PEP 600 태그 → 대상 서버 pip 20.3+ 필요. run.py 가 pip 을 먼저 올린다.)
PLATFORMS=(
    "manylinux2014_x86_64"
    "manylinux_2_17_x86_64"
    "manylinux_2_12_x86_64"
    "manylinux2010_x86_64"
    "manylinux_2_5_x86_64"
    "manylinux1_x86_64"
    "manylinux_2_28_x86_64"
)
# 대상 서버 pip 이 19.x 면 PEP 600 태그를 못 읽으므로 pip 자체도 함께 반입한다.
BOOTSTRAP_PKGS=(pip setuptools wheel)
# 수집 후 존재를 확인할 핵심 패키지 (streamlit 런타임 필수 — 하나라도 없으면 대상 서버에서 설치 실패)
# 값은 wheel 파일명 앞부분과 비교하므로 배포명 기준으로 적는다 (예: python_dotenv-1.0.1-...whl)
VERIFY_PKGS=(streamlit pandas numpy pyarrow psycopg2 python_dotenv altair pillow tornado click rich requests protobuf pip)

TS=$(date '+%Y%m%d_%H%M%S')
LOG_DIR="${SCRIPT_DIR}/log"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/make_wheels_${TS}.log"

_out()  { echo -e "$1" | tee -a "${LOG_FILE}"; }
_log()  { _out "[INFO] $1"; }
_ok()   { _out "[ OK ] $1"; }
_fail() { _out "[FAIL] $1"; }

usage() {
    echo "Usage: $0 [-n] [-c] [-d DEST_DIR]"
    echo "  -n          현재 파이썬 환경 기준으로 다운로드 (대상 서버에서 직접 실행할 때)"
    echo "  -c          기존 저장 디렉터리를 비우고 새로 받기"
    echo "  -d DEST_DIR 저장 디렉터리 (기본: ./wheels)"
    exit 1
}

while getopts "ncd:h" opt; do
    case "${opt}" in
        n) NATIVE=1 ;;
        c) CLEAN=1 ;;
        d) DEST="${OPTARG}" ;;
        *) usage ;;
    esac
done

[ -f "${REQ_FILE}" ] || { _fail "requirements.txt 가 없습니다: ${REQ_FILE}"; exit 1; }

#-----------------------------------------------------------
# 실행 인터프리터 결정 — 반드시 Python 3.8 이어야 한다
#
# pip 의 --python-version 은 "wheel 태그 선택" 에만 적용되고
# 환경 마커(python_version < '3.9' 등) 평가에는 적용되지 않는다.
# 마커는 항상 '실행 중인 인터프리터' 기준으로 평가되므로, 3.9+ 로 수집하면
#   jsonschema → importlib-resources / pkgutil-resolve-name   (python_version < '3.9')
#   importlib-resources → zipp                                (python_version < '3.10')
# 같은 3.8 전용 의존성이 조용히 빠진다. 다운로드는 성공으로 끝나지만
# 대상 서버에서 "No matching distribution found for importlib-resources" 로 실패한다.
#-----------------------------------------------------------
find_python() {
    local cand
    if [ -n "${PYTHON_BIN}" ]; then
        command -v "${PYTHON_BIN}" >/dev/null 2>&1 && { echo "${PYTHON_BIN}"; return 0; }
        return 1
    fi
    # .venv 를 먼저 본다 — RHEL 8 의 /usr/bin/python3.8 은 pip 19.x 라 크로스 수집을 못 한다.
    for cand in "${SCRIPT_DIR}/.venv/bin/python" python3.8 /usr/bin/python3.8; do
        command -v "${cand}" >/dev/null 2>&1 || continue
        "${cand}" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3,8) else 1)' 2>/dev/null \
            && { echo "${cand}"; return 0; }
    done
    [ ${NATIVE} -eq 1 ] && command -v python3 >/dev/null 2>&1 && { echo "python3"; return 0; }
    return 1
}

PY=$(find_python)
if [ -z "${PY}" ]; then
    _fail "Python 3.8 인터프리터를 찾을 수 없습니다."
    _fail "  수집은 반드시 3.8 로 실행해야 합니다 (환경 마커가 실행 인터프리터 기준으로 평가됨)."
    _fail "  RHEL 8: sudo dnf install -y python38"
    _fail "  또는  : PYTHON_BIN=/path/to/python3.8 $0"
    exit 1
fi
command -v "${PY}" >/dev/null 2>&1 || { _fail "python 을 찾을 수 없습니다: ${PY}"; exit 1; }

PY_MM=$("${PY}" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
_log "python : $(${PY} -V 2>&1) (${PY})"
_log "pip    : $(${PY} -m pip -V 2>&1)"

if [ "${PY_MM}" != "${PY_VERSION}" ]; then
    if [ ${NATIVE} -eq 1 ]; then
        _fail "native 모드인데 현재 파이썬이 ${PY_MM} 입니다 (대상 환경은 ${PY_VERSION})."
        _fail "  대상 서버의 python3.8 로 실행하세요."
        exit 1
    fi
    _fail "수집 인터프리터가 Python ${PY_MM} 입니다 — 반드시 ${PY_VERSION} 이어야 합니다."
    _fail "  --python-version ${PY_VERSION} 은 wheel 태그에만 적용되고 환경 마커에는 적용되지 않습니다."
    _fail "  ${PY_MM} 로 수집하면 3.8 전용 의존성(importlib-resources, pkgutil-resolve-name, zipp)이"
    _fail "  조용히 누락되고, 대상 서버 설치 시점에야 실패합니다."
    _fail "  PYTHON_BIN=/usr/bin/python3.8 $0"
    exit 1
fi

# 크로스 수집은 --platform 다중 지정이 필요하다. pip 22.0 미만은 --platform 을
# 단일 값으로 처리해(마지막 값만 적용) pandas 등에서 'No matching distribution' 이 난다.
# manylinux_2_28(PEP 600) 태그 인식도 pip 20.3+ 부터다.
PIP_MM=$("${PY}" -c 'import pip,sys; sys.stdout.write(".".join(pip.__version__.split(".")[:2]))' 2>/dev/null)
if [ ${NATIVE} -eq 0 ]; then
    if [ -z "${PIP_MM}" ]; then
        _fail "pip 버전을 확인할 수 없습니다: ${PY} -m pip -V"
        exit 1
    fi
    if [ "$(printf '%s\n22.0\n' "${PIP_MM}" | sort -V | head -1)" != "22.0" ]; then
        _fail "pip ${PIP_MM} — 크로스 수집에는 pip 22.0 이상이 필요합니다."
        _fail "  (22.0 미만은 --platform 다중 지정을 무시하고 마지막 값만 사용합니다)"
        _fail "  ${PY} -m pip install --user -U pip"
        _fail "  또는 pip 이 최신인 venv 로: PYTHON_BIN=${SCRIPT_DIR}/.venv/bin/python $0"
        exit 1
    fi
fi
_log "대상   : $([ ${NATIVE} -eq 1 ] && echo 'native (현재 환경)' || echo "cp38 / ${PLATFORMS[0]} 외")"
_log "저장   : ${DEST}"

if [ -d "${DEST}" ] && [ -n "$(ls -A "${DEST}" 2>/dev/null)" ]; then
    _log "기존 파일 $(ls -1 "${DEST}" | wc -l) 개가 있습니다."
    if [ ${CLEAN} -eq 1 ]; then
        # 이전 실행이 중간에 실패해 남은 부분 수집본을 그대로 반입하면
        # 대상 서버에서 "No matching distribution" 으로 실패한다.
        read -r -p "       ${DEST} 의 파일을 모두 삭제하고 새로 받을까요? (y/N): " ans
        [ "${ans}" = "y" ] || [ "${ans}" = "Y" ] || { _log "취소했습니다."; exit 0; }
        rm -f "${DEST}"/*.whl "${DEST}"/*.tar.gz
        _ok "기존 파일 삭제 완료"
    else
        _log "(추가 수집됩니다. 새로 받으려면 -c 옵션)"
        read -r -p "       계속할까요? (y/N): " ans
        [ "${ans}" = "y" ] || [ "${ans}" = "Y" ] || { _log "취소했습니다."; exit 0; }
    fi
fi
mkdir -p "${DEST}"

CMD=("${PY}" -m pip download -r "${REQ_FILE}" "${BOOTSTRAP_PKGS[@]}" -d "${DEST}")
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
    _fail "  !! ${DEST} 는 '부분 수집' 상태입니다. 이대로 반입하면 대상 서버에서 설치가 실패합니다."
    _fail "  - 특정 패키지에서 'No matching distribution' 이면 그 패키지의 wheel 태그를 확인하고"
    _fail "    PLATFORMS 배열에 해당 태그를 추가하세요."
    _fail "  - pip 가 오래되어 --platform 다중 지정을 못 하면: ${PY} -m pip install -U pip"
    _fail "  - 그래도 실패하면 대상 서버에서 './make_wheels.sh -n' 으로 받으세요."
    exit ${RC}
fi

#-----------------------------------------------------------
# 수집 결과 검증 — 핵심 패키지 누락 여부 확인
#-----------------------------------------------------------
FILES=$(ls -1 "${DEST}" | tr 'A-Z' 'a-z' | tr '-' '_')
MISSING=()
for pkg in "${VERIFY_PKGS[@]}"; do
    echo "${FILES}" | grep -q "^$(echo "${pkg}" | tr 'A-Z' 'a-z' | tr '-' '_')" || MISSING+=("${pkg}")
done

COUNT=$(ls -1 "${DEST}" | wc -l)
SIZE=$(du -sh "${DEST}" | cut -f1)
_ok "wheel ${COUNT} 개 / ${SIZE} → ${DEST}"

if [ ${#MISSING[@]} -gt 0 ]; then
    _fail "핵심 패키지가 보이지 않습니다: ${MISSING[*]}"
    _fail "  다운로드는 성공했지만 반입 전에 확인하세요 (패키지명이 다를 수 있음)."
    _fail "  개별 수집 예: ${PY} -m pip download <pkg> -d ${DEST} --only-binary=:all: \\"
    _fail "                  --python-version ${PY_VERSION} --implementation cp --abi ${ABI} \\"
    _fail "                  --platform manylinux_2_17_x86_64"
    exit 1
fi
_ok "핵심 패키지 확인 완료 (${#VERIFY_PKGS[@]}종)"

#-----------------------------------------------------------
# 의존성 폐쇄(closure) 검증 — 대상 서버와 동일한 조건으로 실제 resolve 해 본다.
#
# 위의 VERIFY_PKGS 는 최상위 패키지 파일명만 보므로 전이 의존성 누락을 못 잡는다.
# (importlib-resources 누락 사례가 그렇게 통과했다.)
# 여기서는 --no-index --find-links 로 진짜 의존성 해석을 돌려 확인한다.
# --dry-run 은 실제 설치 없이 해석만 하며 pip 22.2+ 에서 지원한다.
#-----------------------------------------------------------
if [ -n "${PIP_MM}" ] && [ "$(printf '%s\n22.2\n' "${PIP_MM}" | sort -V | head -1)" = "22.2" ]; then
    _log "의존성 폐쇄 검증 (--no-index 로 실제 resolve)"
    RESOLVE_OUT=$("${PY}" -m pip install --no-index --find-links "${DEST}" \
        -r "${REQ_FILE}" --dry-run --ignore-installed 2>&1)
    if [ $? -ne 0 ]; then
        echo "${RESOLVE_OUT}" | tee -a "${LOG_FILE}" >/dev/null
        echo "${RESOLVE_OUT}" | tail -20
        _fail "수집본만으로는 설치가 불가능합니다 — 의존성이 빠져 있습니다."
        _fail "  위 'No matching distribution found for ...' 에 나온 패키지를 확인하세요."
        _fail "  3.8 전용 조건부 의존성이면 수집 인터프리터가 3.8 이 맞는지 다시 확인하세요."
        exit 1
    fi
    _ok "의존성 폐쇄 검증 완료 — wheels/ 만으로 설치 가능"
else
    _log "pip ${PIP_MM} — --dry-run 미지원이라 폐쇄 검증을 건너뜁니다."
    _log "  대상 서버 반입 전 아래로 직접 확인하세요:"
    _log "    python3.8 -m pip install --no-index --find-links ${DEST} -r requirements.txt"
fi

_log ""
_log "다음 단계:"
_log "  1) tar czf tibero_web.tar.gz app.py run.py run.sh requirements.txt wheels/"
_log "  2) 대상 서버(RHEL 8.10)로 복사 후 압축 해제"
_log "  3) PG.env 작성 → ./run.sh"
