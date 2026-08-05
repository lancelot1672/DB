#!/usr/bin/env python3.8
# -*- coding: utf-8 -*-
"""
SQL Grid Web 실행 런처 (RHEL 8.10 / Python 3.8, Docker 없이 실행)

    python3.8 run.py                  # 0.0.0.0:8501 로 기동
    python3.8 run.py --port 8600
    python3.8 run.py --host 127.0.0.1 # 로컬 전용
    python3.8 run.py --browser        # 데스크톱 환경에서 브라우저 자동 오픈
    ./run.sh                          # venv 생성/활성화까지 포함한 래퍼

동작:
  1) Python / 의존성 확인 → 누락 시 y/N 확인 후 설치
     (./wheels 디렉터리가 있으면 --no-index 오프라인 설치, 없으면 PyPI)
  2) PG.env 확인 → 없으면 템플릿 생성 후 안내 종료 (접속 정보 하드코딩 금지)
  3) streamlit run app.py 실행

Python 3.8 기준으로 작성한다 (f-string 문법은 쓰되 3.9+ 전용 문법은 사용하지 않음).
"""
import argparse
import importlib.util
import os
import socket
import subprocess
import sys
import threading
import time
import webbrowser

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
APP_PATH = os.path.join(BASE_DIR, "app.py")
ENV_PATH = os.path.join(BASE_DIR, "PG.env")
REQ_PATH = os.path.join(BASE_DIR, "requirements.txt")
LOG_DIR = os.path.join(BASE_DIR, "log")
WHEEL_DIR = os.path.join(BASE_DIR, "wheels")

DEFAULT_PORT = 8501
DEFAULT_HOST = "0.0.0.0"
MIN_PYTHON = (3, 8)

# (import 이름, pip 패키지명) — app.py 가 실제로 import 하는 모듈 기준
REQUIRED_MODULES = [
    ("streamlit", "streamlit"),
    ("pandas", "pandas"),
    ("psycopg2", "psycopg2-binary"),
    ("dotenv", "python-dotenv"),
]
# 없어도 st.dataframe 으로 폴백되므로 경고만 한다
OPTIONAL_MODULES = [("st_aggrid", "streamlit-aggrid")]

ENV_KEYS = ["PG_HOST", "PG_PORT", "PG_DBNAME", "PG_USER", "PG_PASSWORD"]
ENV_TEMPLATE = """# PostgreSQL 접속 정보 (git 제외 대상)
PG_HOST=localhost
PG_PORT=5432
PG_DBNAME=
PG_USER=
PG_PASSWORD=
"""


# ============================================================
# 출력 헬퍼
# ============================================================
def _log(msg):
    print(msg)


def _ok(msg):
    print("  [OK] {}".format(msg))


def _fail(msg):
    print("  [FAIL] {}".format(msg))


def _warn(msg):
    print("  [WARN] {}".format(msg))


def _confirm(question):
    """설치 등 부수효과 있는 작업 전 y/N 확인 (레포 공통 규약)."""
    if not sys.stdin.isatty():
        return False
    try:
        return input("{} (y/N): ".format(question)).strip().lower() == "y"
    except EOFError:
        return False


# ============================================================
# 1. 실행 환경 / 의존성 확인
# ============================================================
def check_python():
    if sys.version_info < MIN_PYTHON:
        _fail("Python {}.{} 이상이 필요합니다. (현재 {})".format(
            MIN_PYTHON[0], MIN_PYTHON[1], sys.version.split()[0]))
        _log("  RHEL 8: sudo dnf install -y python38 python38-devel")
        return False
    _ok("Python {} ({})".format(sys.version.split()[0], sys.executable))
    return True


def missing_modules(modules):
    return [pkg for mod, pkg in modules if importlib.util.find_spec(mod) is None]


def has_offline_wheels():
    return os.path.isdir(WHEEL_DIR) and any(
        f.endswith((".whl", ".tar.gz")) for f in os.listdir(WHEEL_DIR)
    )


def install_requirements():
    """./wheels 가 있으면 오프라인(--no-index) 설치, 없으면 PyPI 설치."""
    if not os.path.exists(REQ_PATH):
        _fail("requirements.txt 가 없습니다: {}".format(REQ_PATH))
        return False

    cmd = [sys.executable, "-m", "pip", "install", "-r", REQ_PATH]
    if has_offline_wheels():
        cmd += ["--no-index", "--find-links", WHEEL_DIR]
        _log("  (오프라인 설치: {})".format(WHEEL_DIR))
    # venv 가 아니면 시스템 site-packages 오염을 피해 사용자 영역에 설치
    is_venv = sys.prefix != getattr(sys, "base_prefix", sys.prefix)
    is_root = hasattr(os, "geteuid") and os.geteuid() == 0
    if not is_venv and not is_root:
        cmd.append("--user")

    _log("  $ " + " ".join(cmd))
    return subprocess.call(cmd) == 0


def check_dependencies():
    missing = missing_modules(REQUIRED_MODULES)
    if missing:
        _fail("누락된 패키지: {}".format(", ".join(missing)))
        if not _confirm("  지금 설치할까요?"):
            _log("\n설치를 건너뛰었습니다. 아래 명령으로 직접 설치하세요:")
            if has_offline_wheels():
                _log("  {} -m pip install --no-index --find-links wheels -r requirements.txt"
                     .format(sys.executable))
            else:
                _log("  {} -m pip install -r requirements.txt".format(sys.executable))
                _log("  (폐쇄망이면 먼저 인터넷 가능 서버에서 ./make_wheels.sh 실행 후 wheels/ 복사)")
            return False
        if not install_requirements():
            _fail("pip 설치에 실패했습니다.")
            return False
        missing = missing_modules(REQUIRED_MODULES)
        if missing:
            _fail("설치 후에도 누락 상태입니다: {}".format(", ".join(missing)))
            _log("  --user 로 설치된 경우 PATH/PYTHONPATH 를 확인하세요.")
            return False
    _ok("필수 패키지 확인 완료")

    for pkg in missing_modules(OPTIONAL_MODULES):
        _warn("{} 미설치 — 그리드가 st.dataframe 으로 폴백됩니다.".format(pkg))
    return True


# ============================================================
# 2. PG.env 확인
# ============================================================
def read_env_file(path):
    """PG.env 를 key=value 로 단순 파싱 (streamlit 실행 전 사전 점검용)."""
    values = {}
    with open(path, "r", encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            values[key.strip()] = val.strip().strip('"').strip("'")
    return values


def check_env():
    if not os.path.exists(ENV_PATH):
        _fail("PG.env 가 없습니다.")
        if _confirm("  템플릿을 생성할까요? ({})".format(ENV_PATH)):
            with open(ENV_PATH, "w", encoding="utf-8") as f:
                f.write(ENV_TEMPLATE)
            os.chmod(ENV_PATH, 0o600)
            _log("\n생성했습니다. PG.env 에 접속 정보를 채운 뒤 다시 실행하세요:")
            _log("  {}".format(ENV_PATH))
        return False

    values = read_env_file(ENV_PATH)
    empty = [k for k in ENV_KEYS if not values.get(k)]
    if empty:
        _fail("PG.env 의 값이 비어 있습니다: {}".format(", ".join(empty)))
        _log("  {} 를 편집한 뒤 다시 실행하세요.".format(ENV_PATH))
        return False

    _ok("PG.env — {}@{}:{}/{}".format(values["PG_USER"], values["PG_HOST"],
                                      values["PG_PORT"], values["PG_DBNAME"]))
    return True


# ============================================================
# 3. 실행
# ============================================================
def find_free_port(host, port, tries=10):
    """포트가 사용 중이면 다음 포트로 넘긴다. 모두 막혔으면 None."""
    bind_host = "" if host == "0.0.0.0" else host
    for candidate in range(port, port + tries):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind((bind_host, candidate))
                return candidate
            except OSError:
                continue
    return None


def local_ip():
    """외부에서 접속할 때 쓸 서버 IP 추정 (실제 연결은 하지 않음)."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except OSError:
        return None


def open_browser_later(url, delay=3.0):
    threading.Thread(
        target=lambda: (time.sleep(delay), webbrowser.open(url)),
        daemon=True,
    ).start()


def run_streamlit(host, port, open_browser):
    os.makedirs(LOG_DIR, exist_ok=True)
    local_url = "http://localhost:{}".format(port)
    cmd = [
        sys.executable, "-m", "streamlit", "run", APP_PATH,
        "--server.port", str(port),
        "--server.address", host,
        # headless=true: 최초 실행 시 이메일 입력 프롬프트와 자동 오픈을 막는다
        # (서버에는 브라우저가 없으므로 기본값). 필요하면 --browser 로 직접 연다.
        "--server.headless", "true",
        "--browser.gatherUsageStats", "false",
    ]

    _ok(local_url)
    if host == "0.0.0.0":
        ip = local_ip()
        if ip:
            _ok("http://{}:{}  (외부 접속 시 방화벽 개방 필요)".format(ip, port))
            _log("       firewall-cmd --add-port={}/tcp --permanent && firewall-cmd --reload".format(port))
    _log("  종료: Ctrl+C")
    _log("")

    if open_browser:
        open_browser_later(local_url)

    try:
        return subprocess.call(cmd, cwd=BASE_DIR)
    except KeyboardInterrupt:
        _log("\n종료했습니다.")
        return 0


def main():
    parser = argparse.ArgumentParser(description="SQL Grid Web 실행 런처 (RHEL 8 / Python 3.8)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help="실행 포트 (기본 {}, 사용 중이면 다음 포트로 자동 변경)".format(DEFAULT_PORT))
    parser.add_argument("--host", default=DEFAULT_HOST,
                        help="바인드 주소 (기본 {}, 로컬 전용은 127.0.0.1)".format(DEFAULT_HOST))
    parser.add_argument("--browser", action="store_true",
                        help="브라우저 자동 오픈 (데스크톱 환경에서만)")
    args = parser.parse_args()

    _log("=" * 56)
    _log(" SQL Grid Web (PostgreSQL 9.6) - 조회 전용")
    _log("=" * 56)

    if not os.path.exists(APP_PATH):
        _fail("app.py 를 찾을 수 없습니다: {}".format(APP_PATH))
        return 1

    _log("[1/3] 실행 환경 확인...")
    if not check_python() or not check_dependencies():
        return 1

    _log("[2/3] 접속 정보 확인...")
    if not check_env():
        return 1

    _log("[3/3] 앱 실행...")
    port = find_free_port(args.host, args.port)
    if port is None:
        _fail("{}~{} 포트가 모두 사용 중입니다. --port 로 지정하세요."
              .format(args.port, args.port + 9))
        return 1
    if port != args.port:
        _warn("{} 포트가 사용 중이라 {} 로 실행합니다.".format(args.port, port))

    return run_streamlit(args.host, port, args.browser)


if __name__ == "__main__":
    sys.exit(main())
