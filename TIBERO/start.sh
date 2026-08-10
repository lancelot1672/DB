#!/bin/bash
#############################################################
# SQL Grid Web 백그라운드 기동 / 종료 (nohup)
#
#   ./start.sh                      # PG.env / 8600 포트로 기동
#   ./start.sh --port 8700          # 인자를 주면 그대로 run.sh 로 전달(기본값 대체)
#   ./start.sh --env PG_DEV.env --port 8700
#   ./start.sh stop                 # 종료
#   ./start.sh status               # 상태 확인
#
# 로그는 ./run.log (앱 상세 로그는 log/run_<timestamp>.log).
#
# 주의 두 가지:
#  1) nohup 은 stdin 이 터미널이 아니라서 run.py 의 의존성 설치 확인 프롬프트에
#     답할 수 없다 → -y 로 무인 설치.
#  2) run.sh → run.py → streamlit 은 별도 PID 라, 부모만 kill 하면 streamlit 이
#     살아남아 포트를 계속 물고 있다 → setsid 로 프로세스 그룹을 새로 만들고
#     종료할 때 그룹 전체(kill -- -PGID)를 내린다.
#############################################################

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}" || exit 1

LOG_FILE="${SCRIPT_DIR}/run.log"
PID_FILE="${SCRIPT_DIR}/sqlgrid.pid"

# PID 파일이 살아있는 프로세스를 가리키면 0 을 반환한다.
_running() {
    [ -f "${PID_FILE}" ] || return 1
    local pid
    pid=$(cat "${PID_FILE}" 2>/dev/null)
    [ -n "${pid}" ] || return 1
    kill -0 "${pid}" 2>/dev/null
}

_stop() {
    if ! _running; then
        echo "[INFO] 실행 중이 아닙니다."
        rm -f "${PID_FILE}"
        return 0
    fi
    local pid
    pid=$(cat "${PID_FILE}")
    # 그룹 전체(run.sh/run.py/streamlit)를 내린다. setsid 로 띄웠으므로 PGID == PID.
    kill -- -"${pid}" 2>/dev/null || kill "${pid}" 2>/dev/null

    local i
    for i in $(seq 1 10); do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "${pid}" 2>/dev/null; then
        echo "[WARN] 정상 종료되지 않아 강제 종료합니다 (PID ${pid})."
        kill -9 -- -"${pid}" 2>/dev/null || kill -9 "${pid}" 2>/dev/null
    fi
    rm -f "${PID_FILE}"
    echo "[ OK ] 종료 (PID ${pid})"
}

_status() {
    if _running; then
        echo "[ OK ] 실행 중 (PID $(cat "${PID_FILE}"))"
        pgrep -a -g "$(cat "${PID_FILE}")" -f "streamlit run" 2>/dev/null
        return 0
    fi
    echo "[INFO] 실행 중이 아닙니다."
    return 1
}

case "$1" in
    stop)   _stop;   exit $? ;;
    status) _status; exit $? ;;
esac

#-----------------------------------------------------------
# 기동
#-----------------------------------------------------------
# 인자가 없으면 기본값, 있으면 준 인자를 그대로 쓴다.
if [ $# -gt 0 ]; then
    ARGS=("$@")
else
    ARGS=(--env PG.env --port 8600)
fi

# 이미 떠 있으면 중복 기동하지 않는다 (포트 충돌로 조용히 죽는 것을 막는다).
if _running; then
    echo "[FAIL] 이미 실행 중입니다 (PID $(cat "${PID_FILE}"))."
    echo "       종료: ./start.sh stop"
    exit 1
fi

[ -x "${SCRIPT_DIR}/run.sh" ] || chmod +x "${SCRIPT_DIR}/run.sh" 2>/dev/null

# setsid 가 없는 환경(드물다)에서는 그냥 nohup 으로 띄운다.
if command -v setsid >/dev/null 2>&1; then
    setsid "${SCRIPT_DIR}/run.sh" -y "${ARGS[@]}" > "${LOG_FILE}" 2>&1 < /dev/null &
else
    echo "[WARN] setsid 가 없어 프로세스 그룹 종료를 보장할 수 없습니다."
    nohup "${SCRIPT_DIR}/run.sh" -y "${ARGS[@]}" > "${LOG_FILE}" 2>&1 < /dev/null &
fi
PID=$!
echo "${PID}" > "${PID_FILE}"

echo "[ OK ] 기동 (PID ${PID}) : run.sh -y ${ARGS[*]}"
echo "       로그   : ${LOG_FILE}"
echo "       상태   : ./start.sh status"
echo "       종료   : ./start.sh stop"
