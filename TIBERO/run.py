#!/usr/bin/env python3.8
# -*- coding: utf-8 -*-
"""
SQL Grid Web 실행 런처 (RHEL 8.10 / Python 3.8, Docker 없이 실행)

    python3.8 run.py                     # 0.0.0.0:8501 로 기동 (PG.env 사용)
    python3.8 run.py --port 8600         # 웹 서비스 포트 변경
    python3.8 run.py --env PG_DEV.env    # 다른 DB 접속 정보 파일로 기동
    python3.8 run.py --env PG_DEV.env --port 8600
    python3.8 run.py --host 127.0.0.1    # 로컬 전용
    python3.8 run.py --browser           # 데스크톱 환경에서 브라우저 자동 오픈
    python3.8 run.py -y                  # 확인 프롬프트 자동 승인 (폐쇄망 무인 설치)
    python3.8 run.py --queries /var/lib/sqlgrid/saved_queries.json   # 저장 쿼리 파일 위치 지정
    ./run.sh                             # venv 생성/활성화까지 포함한 래퍼

--port 는 웹 서비스 포트이고, DB 포트는 접속 정보 파일의 PG_PORT 다 (서로 다름).
--env 로 준 경로는 SQLGRID_ENV_FILE, --queries 는 SQLGRID_QUERY_FILE 환경 변수로 app.py 에 전달된다.
--queries 를 앱 디렉터리 바깥으로 지정하면 재배포(tar 해제)로 앱을 갈아엎어도 저장 쿼리가 남는다.

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
DEFAULT_ENV_PATH = os.path.join(BASE_DIR, "PG.env")
DEFAULT_QUERY_PATH = os.path.join(BASE_DIR, "queries", "saved_queries.json")
REQ_PATH = os.path.join(BASE_DIR, "requirements.txt")
LOG_DIR = os.path.join(BASE_DIR, "log")
WHEEL_DIR = os.path.join(BASE_DIR, "wheels")

DEFAULT_PORT = 8501
DEFAULT_HOST = "0.0.0.0"
MIN_PYTHON = (3, 8)
# PEP 600(manylinux_x_y) 태그를 인식하는 최소 pip 버전.
# RHEL 8 python38 기본 pip(19.x)은 pillow/pyarrow 의 manylinux_2_28 휠을 못 읽는다.
PIP_PEP600_MIN = (20, 3)

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
    # flush: 로그 파일로 리다이렉트하면 stdout 이 블록 버퍼링되어,
    # Ctrl+C / kill 로 끝낼 때 점검 메시지가 통째로 사라진다.
    print(msg, flush=True)


def _ok(msg):
    print("  [OK] {}".format(msg), flush=True)


def _fail(msg):
    print("  [FAIL] {}".format(msg), flush=True)


def _warn(msg):
    print("  [WARN] {}".format(msg), flush=True)


# --yes 로 켜진다. 폐쇄망 서버에 스크립트로 배포할 때 대화식 프롬프트를 없앤다.
ASSUME_YES = False


def _confirm(question):
    """설치 등 부수효과 있는 작업 전 y/N 확인 (레포 공통 규약)."""
    if ASSUME_YES:
        _log("{} (y/N): y  [--yes]".format(question))
        return True
    if not sys.stdin.isatty():
        # 파이프/nohup 으로 돌리면 물어볼 수 없다. 임의로 설치하지 않고 --yes 를 안내한다.
        _warn("대화형 입력이 불가능합니다 (stdin 이 터미널이 아님). 자동 승인하려면 --yes")
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


def pip_install_cmd(offline):
    """pip install 공통 인자 구성."""
    cmd = [sys.executable, "-m", "pip", "install"]
    if offline:
        cmd += ["--no-index", "--find-links", WHEEL_DIR]
    # venv 가 아니면 시스템 site-packages 오염을 피해 사용자 영역에 설치
    is_venv = sys.prefix != getattr(sys, "base_prefix", sys.prefix)
    is_root = hasattr(os, "geteuid") and os.geteuid() == 0
    if not is_venv and not is_root:
        cmd.append("--user")
    return cmd


def current_pip_version():
    """(major, minor) 튜플. 확인 불가 시 None."""
    try:
        import pip
        parts = pip.__version__.split(".")
        return (int(parts[0]), int(parts[1]))
    except Exception:
        return None


def ensure_pip():
    """
    manylinux_2_28 같은 PEP 600 태그는 pip 20.3+ 부터 인식한다.
    RHEL 8 의 python38 기본 pip 은 19.x 라 pillow / pyarrow 의 manylinux_2_28 휠을
    '지원하지 않는 플랫폼' 으로 건너뛰어 오프라인 설치가 실패한다. 먼저 pip 을 올린다.
    """
    ver = current_pip_version()
    if ver is None:
        _warn("pip 버전을 확인하지 못했습니다. 그대로 진행합니다.")
        return True
    if ver >= PIP_PEP600_MIN:
        _ok("pip {}.{}".format(ver[0], ver[1]))
        return True

    _warn("pip {}.{} — manylinux_2_28(PEP 600) 휠을 인식하지 못합니다. 업그레이드합니다."
          .format(ver[0], ver[1]))
    offline = has_offline_wheels()
    cmd = pip_install_cmd(offline) + ["--upgrade", "pip"]
    _log("  $ " + " ".join(cmd))
    if subprocess.call(cmd) != 0:
        _fail("pip 업그레이드 실패.")
        if offline:
            _log("  wheels/ 에 pip 휠이 없는 경우입니다. 인터넷 서버에서 아래로 받아 함께 반입하세요:")
            _log("    pip download pip -d wheels --only-binary=:all: --python-version 3.8")
        return False
    _ok("pip 업그레이드 완료")
    return True


def install_requirements():
    """./wheels 가 있으면 오프라인(--no-index) 설치, 없으면 PyPI 설치."""
    if not os.path.exists(REQ_PATH):
        _fail("requirements.txt 가 없습니다: {}".format(REQ_PATH))
        return False

    offline = has_offline_wheels()
    if offline:
        _log("  (오프라인 설치: {})".format(WHEEL_DIR))
    if not ensure_pip():
        return False

    cmd = pip_install_cmd(offline) + ["-r", REQ_PATH]
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


def check_env(env_path):
    name = os.path.basename(env_path)
    if not os.path.exists(env_path):
        _fail("접속 정보 파일이 없습니다: {}".format(env_path))
        # --env 로 지정한 경로가 오타인 경우가 많으므로 템플릿 생성은 기본 경로에서만.
        if env_path != DEFAULT_ENV_PATH:
            _log("  경로를 확인하세요. 기본 파일로 실행하려면 --env 를 빼고 실행합니다.")
            return False
        if _confirm("  템플릿을 생성할까요? ({})".format(env_path)):
            with open(env_path, "w", encoding="utf-8") as f:
                f.write(ENV_TEMPLATE)
            os.chmod(env_path, 0o600)
            _log("\n생성했습니다. {} 에 접속 정보를 채운 뒤 다시 실행하세요:".format(name))
            _log("  {}".format(env_path))
        return False

    values = read_env_file(env_path)
    empty = [k for k in ENV_KEYS if not values.get(k)]
    if empty:
        _fail("{} 의 값이 비어 있습니다: {}".format(name, ", ".join(empty)))
        _log("  {} 를 편집한 뒤 다시 실행하세요.".format(env_path))
        return False

    _ok("{} — {}@{}:{}/{}".format(name, values["PG_USER"], values["PG_HOST"],
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


def run_streamlit(host, port, open_browser, env_path, query_path):
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

    # app.py 는 CLI 인자를 받을 수 없으므로(streamlit run 이 가로챈다)
    # 접속 정보 / 저장 쿼리 파일 경로는 환경 변수로 넘긴다.
    child_env = os.environ.copy()
    child_env["SQLGRID_ENV_FILE"] = env_path
    child_env["SQLGRID_QUERY_FILE"] = query_path

    try:
        return subprocess.call(cmd, cwd=BASE_DIR, env=child_env)
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
    parser.add_argument("-e", "--env", default=os.environ.get("SQLGRID_ENV_FILE") or DEFAULT_ENV_PATH,
                        help="DB 접속 정보 파일 (기본 {})".format(os.path.basename(DEFAULT_ENV_PATH)))
    parser.add_argument("-q", "--queries",
                        default=os.environ.get("SQLGRID_QUERY_FILE") or DEFAULT_QUERY_PATH,
                        help="저장 쿼리 파일 (기본 queries/saved_queries.json)")
    parser.add_argument("-y", "--yes", action="store_true",
                        help="확인 프롬프트를 자동 승인 (폐쇄망 무인 설치)")
    args = parser.parse_args()

    global ASSUME_YES
    ASSUME_YES = args.yes

    # 상대 경로로 줘도 되도록 정규화 (app.py 는 BASE_DIR 에서 실행되므로 절대경로가 필요)
    env_path = os.path.abspath(os.path.expanduser(args.env))
    query_path = os.path.abspath(os.path.expanduser(args.queries))

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
    if not check_env(env_path):
        return 1

    _log("[3/3] 앱 실행...")
    port = find_free_port(args.host, args.port)
    if port is None:
        _fail("{}~{} 포트가 모두 사용 중입니다. --port 로 지정하세요."
              .format(args.port, args.port + 9))
        return 1
    if port != args.port:
        _warn("{} 포트가 사용 중이라 {} 로 실행합니다.".format(args.port, port))

    _log("       저장 쿼리: {}{}".format(
        query_path, "" if os.path.exists(query_path) else "  (아직 없음 - 첫 저장 시 생성)"))

    return run_streamlit(args.host, port, args.browser, env_path, query_path)


if __name__ == "__main__":
    sys.exit(main())
