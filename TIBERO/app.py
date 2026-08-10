"""
SQL Grid Web - PostgreSQL 9.6 조회 전용 그리드
SQL_EXECUTE.html 디자인 목업을 SQL_GRID_WEB_PLAN.md 요구사항에 맞춰 Streamlit 으로 변환.

- SELECT / WITH 조회 쿼리만 허용, 다중 문장 차단, DML/DDL 차단
- 행 수 제한(LIMIT), 수행 시간/건수 표시, CSV 다운로드
- 읽기 전용 세션, 실행 SQL/시각 로깅
- 접속 정보는 PG.env 에서 로딩 (하드코딩 금지)
- 조회 SQL 저장/불러오기 (queries/saved_queries.json)
"""
import os
import re
import copy
import json
import time
import uuid
import logging
import datetime as dt
from datetime import datetime
from decimal import Decimal

import pandas as pd
import streamlit as st
from dotenv import load_dotenv
import psycopg2

# streamlit-aggrid 가 있으면 사용, 없으면 st.dataframe 로 폴백
try:
    from st_aggrid import AgGrid, GridOptionsBuilder, JsCode
    HAS_AGGRID = True
except Exception:
    HAS_AGGRID = False


# ============================================================
# 0. 상수 / 설정
# ============================================================
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
# 접속 정보 파일. run.py --env 로 다른 파일을 지정하면 SQLGRID_ENV_FILE 로 전달된다.
# (여러 DB 를 번갈아 볼 때 PG.env 를 덮어쓰지 않고 파일만 바꿔 끼우기 위함)
ENV_PATH = os.environ.get("SQLGRID_ENV_FILE") or os.path.join(BASE_DIR, "PG.env")
LOG_DIR = os.path.join(BASE_DIR, "log")

# 저장 쿼리 파일. run.py --queries 로 다른 경로를 주면 SQLGRID_QUERY_FILE 로 전달된다.
# (재배포로 앱 디렉터리를 갈아엎어도 저장분이 남도록 앱 바깥 경로를 지정할 수 있게 한다)
QUERY_PATH = os.environ.get("SQLGRID_QUERY_FILE") or os.path.join(BASE_DIR, "queries", "saved_queries.json")
QUERY_SCHEMA_VERSION = 1

# 그리드 스크롤 조회 시 브라우저 부담 안내 임계치 (행 수)
LARGE_ROWS_HINT = 100000

# 저장 쿼리 방어적 상한
MAX_SAVED_QUERIES = 200
MAX_NAME_LEN = 60
MAX_NOTE_LEN = 200
MAX_SQL_LEN = 200000

# 조회 쿼리에서 차단할 DML/DDL 키워드 (HTML 목업의 가드 규칙과 동일)
BLOCK_PATTERN = re.compile(
    r"\b(insert|update|delete|drop|truncate|alter|create|grant|revoke|merge|call|copy|vacuum)\b",
    re.IGNORECASE,
)
START_PATTERN = re.compile(r"^\s*(select|with)\b", re.IGNORECASE)


# ============================================================
# 1. 환경 변수 로딩
# ============================================================
def load_conn_params():
    """PG.env 에서 접속 정보 로딩. 코드에 하드코딩하지 않는다."""
    # override=True: 지정한 env 파일 값이 항상 이긴다. 기본값(False)이면 이미
    # os.environ 에 있는 PG_* 가 남아 있어 --env 로 파일을 바꿔도 반영되지 않는다.
    load_dotenv(ENV_PATH, override=True)
    return {
        "host": os.getenv("PG_HOST", "localhost"),
        "port": os.getenv("PG_PORT", "5432"),
        "dbname": os.getenv("PG_DBNAME", ""),
        "user": os.getenv("PG_USER", ""),
        "password": os.getenv("PG_PASSWORD", ""),
    }


def conn_label(p):
    """헤더에 표시할 접속 라벨 (비밀번호 제외)."""
    return f"{p['user']}@{p['host']}:{p['port']}/{p['dbname']}"


# ============================================================
# 2. 로깅
# ============================================================
def get_logger():
    os.makedirs(LOG_DIR, exist_ok=True)
    logger = logging.getLogger("sql_grid")
    if not logger.handlers:
        logger.setLevel(logging.INFO)
        fname = os.path.join(LOG_DIR, f"sql_grid_{datetime.now():%Y%m%d}.log")
        fh = logging.FileHandler(fname, encoding="utf-8")
        fh.setFormatter(logging.Formatter("%(asctime)s\t%(message)s"))
        logger.addHandler(fh)
    return logger


# ============================================================
# 3. SQL 검증 (조회 전용 가드)
# ============================================================
def validate_sql(raw):
    """
    조회 전용 규칙 검사.
    반환: (ok, query_or_none, error_message)
    """
    trimmed = (raw or "").strip()
    if not trimmed:
        return False, None, "SQL을 입력하세요."

    # 다중 문장 차단 (끝 세미콜론 제거 후 ; 로 분리)
    stmts = [s.strip() for s in re.sub(r";\s*$", "", trimmed).split(";") if s.strip()]
    if len(stmts) > 1:
        return False, None, "여러 문장은 실행할 수 없습니다. 단일 SELECT 문만 입력하세요."

    query = stmts[0] if stmts else trimmed

    if not START_PATTERN.match(query):
        return False, None, "조회(SELECT) 쿼리만 허용됩니다."

    if BLOCK_PATTERN.search(query):
        return False, None, "조회(SELECT) 쿼리만 허용됩니다.  (DML/DDL 구문이 차단되었습니다)"

    return True, query, ""


# ============================================================
# 4. 쿼리 실행
# ============================================================
def _connect(params):
    """읽기 전용 세션으로 접속한 커넥션 반환."""
    conn = psycopg2.connect(
        host=params["host"],
        port=params["port"],
        dbname=params["dbname"],
        user=params["user"],
        password=params["password"],
        connect_timeout=10,
    )
    # 방어적으로 읽기 전용 세션 강제
    conn.set_session(readonly=True, autocommit=True)
    return conn


def run_query(query, params):
    """
    전체 결과를 한 번에 조회 (단일 사용자 · 그리드 스크롤 조회용).
    - LIMIT 없이 전량 fetch -> 그리드에서 클라이언트 가상 스크롤로 탐색
    반환: (df, elapsed_sec)
    """
    conn = _connect(params)
    try:
        start = time.perf_counter()
        with conn.cursor() as cur:
            cur.execute(query)
            cols = [d[0] for d in cur.description]
            rows = cur.fetchall()
        elapsed = time.perf_counter() - start
    finally:
        conn.close()
    return pd.DataFrame(rows, columns=cols), elapsed


# ============================================================
# 5. 결과 렌더링
# ============================================================
def _to_cell(v):
    """AgGrid/JSON 직렬화가 안 되는 값(Decimal, date/datetime 등)을 안전 타입으로 변환.
    미변환 시 그리드에 '[object Object]' 로 표시됨."""
    if v is None or isinstance(v, (str, int, float, bool)):
        return v
    if isinstance(v, Decimal):
        return float(v)
    if isinstance(v, datetime):
        return v.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(v, (dt.date, dt.time)):
        return v.isoformat()
    return str(v)


def grid_safe(df):
    """object dtype 컬럼의 각 셀을 JSON 안전 타입으로 매핑한 표시용 복사본."""
    safe = df.copy()
    for col in safe.columns:
        if safe[col].dtype == object:
            safe[col] = safe[col].map(_to_cell)
    return safe


def render_grid(df):
    df = grid_safe(df)
    if HAS_AGGRID:
        gb = GridOptionsBuilder.from_dataframe(df)
        gb.configure_default_column(sortable=True, filter=True, resizable=True)
        # 맨 앞 고정 행번호 컬럼 (현재 표시 순서 기준, 정렬/필터 시 갱신)
        gb.configure_column(
            "row_no", headerName="No", pinned="left", width=90,
            sortable=False, filter=False, suppressMovable=True,
            valueGetter=JsCode("function(p){ return p.node.rowIndex + 1; }"),
            cellStyle={"color": "#94a3b8", "textAlign": "right"},
        )
        gb.configure_grid_options(
            domLayout="normal", rowBuffer=30,
            pagination=False, suppressColumnVirtualisation=False,
            # 엑셀식: 단일 셀 클릭 선택 표시 + 드래그 범위 선택 (엔터프라이즈 모듈)
            enableRangeSelection=True,
            # Ctrl+C 로 선택 범위 복사 (헤더 포함 여부)
            copyHeadersToClipboard=False,
            # 우측 세로 스크롤바 항상 표시
            alwaysShowVerticalScroll=True,
            suppressHorizontalScroll=False,
        )
        AgGrid(df, gridOptions=gb.build(), height=640, theme="alpine",
               fit_columns_on_grid_load=False, allow_unsafe_jscode=True,
               enable_enterprise_modules=True)
    else:
        # 폴백: 1부터 시작하는 행번호를 인덱스로 표시
        disp = df.copy()
        disp.index = range(1, len(disp) + 1)
        disp.index.name = "No"
        st.dataframe(disp, use_container_width=True, height=640)


# ============================================================
# 6. 스타일 (디자인 목업 근사 - 다크 + 퍼플 액센트)
# ============================================================
CUSTOM_CSS = """
<style>
  .stApp { background: #020617; }
  .sg-title { font-size:20px; font-weight:700; letter-spacing:-0.01em; color:#e2e8f0; }
  .sg-sub   { font-size:12px; color:#64748b; font-family:monospace; }
  .sg-badge { display:inline-block; font-size:11px; font-weight:600; color:#a78bfa;
              border:1px solid #7c3aed; border-radius:6px; padding:2px 8px; }
  .sg-tag   { display:inline-block; font-size:11px; color:#94a3b8;
              border:1px solid #334155; border-radius:6px; padding:2px 8px; margin-right:6px; }
  .sg-metric { font-family:monospace; font-size:16px; font-weight:600; color:#e2e8f0; }
  .sg-side   { font-size:15px; font-weight:700; color:#e2e8f0; }
  .stTextArea textarea { font-family:monospace !important; font-size:13px !important; }
  [data-testid="stSidebar"] { background:#0b1220; border-right:1px solid #1e293b; }
</style>
"""


# ============================================================
# 7. 프리셋(샘플) 쿼리 - 목업의 예시 (대상 DB 스키마에 맞게 수정)
# ============================================================
PRESETS = {
    "customers ⋈ orders": (
        "SELECT\n"
        "    c.customer_id,\n"
        "    c.name,\n"
        "    c.city,\n"
        "    c.country,\n"
        "    COUNT(o.order_id)  AS order_count,\n"
        "    SUM(o.amount)      AS total_spent,\n"
        "    MAX(o.order_date)  AS last_order\n"
        "FROM customers c\n"
        "JOIN orders o ON o.customer_id = c.customer_id\n"
        "WHERE c.status = 'active'\n"
        "GROUP BY c.customer_id, c.name, c.city, c.country\n"
        "ORDER BY total_spent DESC;"
    ),
    "customers": (
        "SELECT customer_id, name, email, city, country, signup_date, status\n"
        "FROM customers\n"
        "WHERE status = 'active'\n"
        "ORDER BY signup_date DESC;"
    ),
    "orders": (
        "SELECT order_id, customer_id, order_date, amount, status, channel\n"
        "FROM orders\n"
        "WHERE order_date >= '2026-01-01'\n"
        "ORDER BY amount DESC;"
    ),
    "transactions": (
        "SELECT txn_id, order_id, method, amount, currency, processed_at, state\n"
        "FROM transactions\n"
        "ORDER BY processed_at DESC;"
    ),
}


# ============================================================
# 7.5 저장 쿼리 저장소 (JSON 파일)
#
# DB 에는 저장하지 않는다 — 앱은 읽기 전용 세션/계정을 전제로 하므로 쓰기가 불가능하다.
# 아래 함수들은 Streamlit 에 의존하지 않는 순수 함수로 둔다(테스트/재사용 용이).
# ============================================================
def _now():
    return datetime.now().isoformat(timespec="seconds")


def _new_id():
    return "q_{:%Y%m%d_%H%M%S}_{}".format(datetime.now(), uuid.uuid4().hex[:4])


def _empty_store():
    return {"version": QUERY_SCHEMA_VERSION, "updated_at": _now(), "items": []}


def validate_store(obj):
    """가져오기/로딩 공통 스키마 검사. 반환: (ok, error_message)"""
    if not isinstance(obj, dict):
        return False, "최상위가 JSON 객체가 아닙니다."
    items = obj.get("items")
    if not isinstance(items, list):
        return False, "'items' 배열이 없습니다."
    for i, it in enumerate(items):
        if not isinstance(it, dict):
            return False, "items[{}] 가 객체가 아닙니다.".format(i)
        if not isinstance(it.get("name"), str) or not it["name"].strip():
            return False, "items[{}] 의 name 이 비어 있습니다.".format(i)
        if not isinstance(it.get("sql"), str):
            return False, "items[{}] 의 sql 이 문자열이 아닙니다.".format(i)
    return True, ""


def _normalize(store):
    """손으로 편집한 파일에도 견디도록 누락 필드를 채운다."""
    now = _now()
    for it in store.get("items", []):
        it.setdefault("id", _new_id())
        it.setdefault("note", "")
        it.setdefault("created_at", now)
        it.setdefault("updated_at", it["created_at"])
        it["name"] = it["name"].strip()
    return store


def load_store():
    """
    저장 파일 로딩. 반환: (store, warning, readonly)
    - 파일 없음    -> 빈 저장소
    - JSON 손상    -> .bak 로 옮기고 빈 저장소 + 경고 (앱은 죽지 않는다)
    - 상위 버전    -> 그대로 읽되 쓰기 금지(readonly=True)
    """
    if not os.path.exists(QUERY_PATH):
        return _empty_store(), "", False
    try:
        with open(QUERY_PATH, encoding="utf-8") as f:
            obj = json.load(f)
        ok, err = validate_store(obj)
        if not ok:
            raise ValueError(err)
    except Exception as e:
        hint = ""
        try:
            os.replace(QUERY_PATH, QUERY_PATH + ".bak")
            hint = " 손상된 파일은 {}.bak 로 옮겼습니다.".format(os.path.basename(QUERY_PATH))
        except OSError:
            pass
        return _empty_store(), "저장된 쿼리 파일을 읽지 못했습니다: {}.{}".format(e, hint), False

    try:
        version = int(obj.get("version", 1) or 1)
    except (TypeError, ValueError):
        version = 1  # 버전이 이상하면 현재 스키마로 간주 (items 는 이미 검증됨)
    readonly = version > QUERY_SCHEMA_VERSION
    warn = ""
    if readonly:
        warn = ("저장 파일 버전(v{})이 앱(v{})보다 높습니다. 덮어써서 손상시키지 않도록 "
                "읽기 전용으로 엽니다.".format(obj.get("version"), QUERY_SCHEMA_VERSION))
    return _normalize(obj), warn, readonly


def save_store(store):
    """같은 디렉터리의 tmp 에 쓴 뒤 os.replace 로 원자 교체 (중단되어도 원본이 남는다)."""
    store["version"] = QUERY_SCHEMA_VERSION
    store["updated_at"] = _now()
    store["items"].sort(key=lambda it: it["name"].lower())

    d = os.path.dirname(QUERY_PATH) or "."
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".{}.tmp.{}".format(os.path.basename(QUERY_PATH), os.getpid()))
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(store, f, ensure_ascii=False, indent=2)
        os.replace(tmp, QUERY_PATH)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def commit_store(mutate, fallback=None):
    """
    디스크 최신본을 다시 읽어 mutate 를 적용하고 저장한다.
    (브라우저 탭 2개 / 외부 편집으로 다른 쪽 저장분이 사라지는 것을 막는다)

    fallback: 디스크 파일이 손상된 경우 기준으로 삼을 저장소(보통 세션 사본).
              손상 파일은 load_store 가 이미 .bak 로 보존했으므로,
              이때 빈 저장소로 덮어써서 세션의 저장분까지 잃지 않도록 한다.
    반환: (store, error_message)
    """
    disk, warn, readonly = load_store()
    if readonly:
        return disk, "저장 파일 버전이 앱보다 높아 쓰기를 막았습니다."
    if warn and fallback is not None:
        disk = copy.deepcopy(fallback)
    try:
        mutate(disk)
        save_store(disk)
    except Exception as e:
        return disk, str(e)
    return disk, ""


def find_by_name(store, name):
    key = (name or "").strip().lower()
    for it in store["items"]:
        if it["name"].lower() == key:
            return it
    return None


def find_by_id(store, qid):
    for it in store["items"]:
        if it["id"] == qid:
            return it
    return None


def clean_name(raw):
    """반환: (name, error_message)"""
    name = re.sub(r"[\x00-\x1f\x7f]", "", raw or "").strip()
    if not name:
        return "", "이름을 입력하세요."
    if len(name) > MAX_NAME_LEN:
        return "", "이름은 {}자 이내로 입력하세요.".format(MAX_NAME_LEN)
    return name, ""


def upsert_query(store, name, sql, note="", overwrite=False):
    """반환: (item, 'created'|'updated'). 중복인데 overwrite=False 면 ValueError."""
    if len(sql) > MAX_SQL_LEN:
        raise ValueError("SQL 이 너무 깁니다 ({:,}자 / 최대 {:,}자).".format(len(sql), MAX_SQL_LEN))
    dup = find_by_name(store, name)
    if dup and not overwrite:
        raise ValueError("같은 이름의 쿼리가 이미 있습니다.")
    if dup:
        dup.update({"sql": sql, "note": note, "updated_at": _now()})
        return dup, "updated"
    if len(store["items"]) >= MAX_SAVED_QUERIES:
        raise ValueError("저장 가능한 쿼리는 최대 {}건입니다.".format(MAX_SAVED_QUERIES))
    now = _now()
    item = {"id": _new_id(), "name": name, "sql": sql, "note": note,
            "created_at": now, "updated_at": now}
    store["items"].append(item)
    return item, "created"


def rename_query(store, qid, new_name):
    it = find_by_id(store, qid)
    if it is None:
        raise ValueError("대상 쿼리를 찾을 수 없습니다. (다른 곳에서 삭제되었을 수 있습니다)")
    dup = find_by_name(store, new_name)
    if dup is not None and dup["id"] != qid:
        raise ValueError("같은 이름의 쿼리가 이미 있습니다.")
    old = it["name"]
    it["name"] = new_name
    it["updated_at"] = _now()
    return old


def delete_query(store, qid):
    """삭제한 항목을 반환한다(되돌리기용)."""
    it = find_by_id(store, qid)
    if it is None:
        raise ValueError("대상 쿼리를 찾을 수 없습니다.")
    store["items"].remove(it)
    return it


def merge_store(base, incoming, overwrite):
    """
    incoming 의 항목을 base 에 병합(제자리 수정)하고 통계를 반환한다.
    조회 전용 가드: 항목마다 validate_sql 을 돌려 통과한 것만 받아들인다.
    """
    stats = {"added": 0, "updated": 0, "skipped": 0, "rejected": []}
    for raw in incoming.get("items", []):
        name, err = clean_name(raw.get("name", ""))
        if err:
            stats["rejected"].append((str(raw.get("name", ""))[:MAX_NAME_LEN], err))
            continue
        ok, query, verr = validate_sql(raw.get("sql", ""))
        if not ok:
            stats["rejected"].append((name, verr))
            continue
        if find_by_name(base, name) is not None and not overwrite:
            stats["skipped"] += 1
            continue
        try:
            _item, action = upsert_query(
                base, name, query, str(raw.get("note", ""))[:MAX_NOTE_LEN], overwrite=True)
        except ValueError as e:
            stats["rejected"].append((name, str(e)))
            continue
        stats["added" if action == "created" else "updated"] += 1
    return stats


# ============================================================
# 8. 콜백
#
# ※ 위젯 인스턴스화 이후에는 세션 상태를 바꿀 수 없으므로,
#    sql_input 대입은 반드시 on_click 콜백 안에서 한다.
# ============================================================
def set_preset(key):
    st.session_state.sql_input = PRESETS[key]
    st.session_state.sq_loaded_id = None


def clear_sql():
    st.session_state.sql_input = ""
    st.session_state.sq_loaded_id = None


def _flash(level, text):
    st.session_state.sq_msg = (level, text)


def _apply_store(store):
    """쓰기 성공 후 세션 반영. 이전 로딩 경고(손상 파일 등)는 해소됐으므로 지운다."""
    st.session_state.saved_store = store
    st.session_state.saved_warn = ""


def cb_show_save():
    """저장 폼 열기. 불러온 쿼리가 있으면 그 이름/메모를 기본값으로 채운다."""
    st.session_state.sq_show_save = True
    st.session_state.sq_overwrite = False
    it = find_by_id(st.session_state.saved_store, st.session_state.get("sq_loaded_id"))
    st.session_state.sq_save_name = it["name"] if it else ""
    st.session_state.sq_save_note = it.get("note", "") if it else ""


def cb_cancel_save():
    st.session_state.sq_show_save = False


def cb_save_current():
    logger = get_logger()
    name, err = clean_name(st.session_state.get("sq_save_name", ""))
    if err:
        _flash("error", err)
        return

    # 저장 시점에도 조회 전용 가드를 적용한다 — 저장소가 DML 보관함이 되지 않도록.
    ok, query, verr = validate_sql(st.session_state.get("sql_input", ""))
    if not ok:
        _flash("error", "저장할 수 없습니다 — {}".format(verr))
        return

    note = (st.session_state.get("sq_save_note") or "").strip()[:MAX_NOTE_LEN]
    overwrite = bool(st.session_state.get("sq_overwrite"))
    box = {}

    def _mutate(s):
        box["item"], box["action"] = upsert_query(s, name, query, note, overwrite)

    store, err2 = commit_store(_mutate, fallback=st.session_state.saved_store)
    if err2:
        logger.error("SAVE_ERR\t%s\t%s", name, err2)
        _flash("error", "저장 실패: {}".format(err2))
        return

    _apply_store(store)
    st.session_state.sq_selected = box["item"]["id"]
    st.session_state.sq_loaded_id = box["item"]["id"]
    st.session_state.sq_loaded_sql = query
    st.session_state.sq_show_save = False
    st.session_state.sq_save_name = ""
    st.session_state.sq_save_note = ""
    st.session_state.sq_overwrite = False
    logger.info("SAVE\t%s\t%s\t%d chars", box["action"], name, len(query))
    _flash("success", "저장했습니다: {}".format(name))


def cb_load_saved():
    qid = st.session_state.get("sq_selected")
    it = find_by_id(st.session_state.saved_store, qid)
    if it is None:
        _flash("error", "불러올 쿼리를 찾을 수 없습니다.")
        return
    st.session_state.sql_input = it["sql"]
    st.session_state.sq_loaded_id = qid
    st.session_state.sq_loaded_sql = it["sql"]
    get_logger().info("LOAD\t%s", it["name"])
    _flash("success", "불러왔습니다: {}".format(it["name"]))


def cb_rename_saved(qid):
    new_name, err = clean_name(st.session_state.get("sq_rename_" + qid, ""))
    if err:
        _flash("error", err)
        return
    box = {}
    store, err2 = commit_store(lambda s: box.update(old=rename_query(s, qid, new_name)),
                               fallback=st.session_state.saved_store)
    if err2:
        _flash("error", "이름 변경 실패: {}".format(err2))
        return
    _apply_store(store)
    st.session_state.sq_selected = qid
    get_logger().info("RENAME\t%s -> %s", box["old"], new_name)
    _flash("success", "이름을 변경했습니다: {} → {}".format(box["old"], new_name))


def cb_delete_saved(qid):
    box = {}
    store, err = commit_store(lambda s: box.update(item=delete_query(s, qid)),
                              fallback=st.session_state.saved_store)
    if err:
        _flash("error", "삭제 실패: {}".format(err))
        return
    _apply_store(store)
    st.session_state.sq_undo = box["item"]
    st.session_state.sq_del_ok = False
    if st.session_state.get("sq_loaded_id") == qid:
        st.session_state.sq_loaded_id = None
    get_logger().info("DELETE\t%s", box["item"]["name"])
    _flash("warning", "삭제했습니다: {}  (되돌리기 가능)".format(box["item"]["name"]))


def cb_undo_delete():
    it = st.session_state.get("sq_undo")
    if not it:
        return
    store, err = commit_store(
        lambda s: upsert_query(s, it["name"], it["sql"], it.get("note", ""), overwrite=True),
        fallback=st.session_state.saved_store)
    if err:
        _flash("error", "되돌리기 실패: {}".format(err))
        return
    _apply_store(store)
    st.session_state.sq_undo = None
    get_logger().info("UNDO_DELETE\t%s", it["name"])
    _flash("success", "복구했습니다: {}".format(it["name"]))


# ============================================================
# 8.5 저장 쿼리 UI
# ============================================================
def render_save_form():
    """편집기 아래 저장 폼. (st.popover/st.dialog 는 1.31+ 이라 expander 로 구현)"""
    if not st.session_state.get("sq_show_save"):
        return
    with st.expander("쿼리 저장", expanded=True):
        c1, c2 = st.columns([2, 3])
        name = c1.text_input("이름", key="sq_save_name", max_chars=MAX_NAME_LEN,
                             placeholder="예: 테이블별 건수 점검")
        c2.text_input("메모 (선택)", key="sq_save_note", max_chars=MAX_NOTE_LEN,
                      placeholder="예: 월간 점검 1번 항목")

        dup = find_by_name(st.session_state.saved_store, name) if (name or "").strip() else None
        overwrite = False
        if dup:
            st.warning("같은 이름의 쿼리가 이미 있습니다. (최종 저장 {})"
                       .format(dup.get("updated_at", "").replace("T", " ")))
            overwrite = st.checkbox("덮어쓰기", key="sq_overwrite")

        b1, b2, _b3 = st.columns([1, 1, 4])
        b1.button("저장", key="sq_do_save", type="primary", use_container_width=True,
                  on_click=cb_save_current, disabled=bool(dup) and not overwrite)
        b2.button("취소", key="sq_cancel_save", use_container_width=True, on_click=cb_cancel_save)


def _render_import_export(store):
    with st.expander("내보내기 / 가져오기"):
        items = store["items"]
        st.download_button(
            "⬇ JSON 내보내기",
            data=json.dumps(store, ensure_ascii=False, indent=2).encode("utf-8"),
            file_name="saved_queries_{:%Y%m%d_%H%M%S}.json".format(datetime.now()),
            mime="application/json", use_container_width=True, disabled=not items)

        up = st.file_uploader("JSON 가져오기", type=["json"], key="sq_upload")
        if up is None:
            return
        try:
            incoming = json.loads(up.getvalue().decode("utf-8"))
            ok, err = validate_store(incoming)
        except Exception as e:
            ok, err = False, str(e)
        if not ok:
            st.error("가져올 수 없는 파일입니다: {}".format(err))
            return

        mode = st.radio("이름 충돌 시", ["건너뛰기", "덮어쓰기"], key="sq_imp_mode", horizontal=True)
        overwrite = (mode == "덮어쓰기")
        # 미리보기 — 사본에 병합해 보고 결과 건수만 보여준다(실제 파일은 건드리지 않음)
        preview = merge_store(copy.deepcopy(store), incoming, overwrite)
        st.caption("추가 {} · 갱신 {} · 건너뜀 {} · 거부 {}".format(
            preview["added"], preview["updated"], preview["skipped"], len(preview["rejected"])))
        for nm, why in preview["rejected"][:5]:
            st.caption("↳ 거부: {} — {}".format(nm, why))

        if st.button("적용", key="sq_imp_apply", type="primary", use_container_width=True):
            stats = {}
            new_store, err2 = commit_store(
                lambda s: stats.update(merge_store(s, incoming, overwrite)),
                fallback=store)
            if err2:
                st.error("가져오기 실패: {}".format(err2))
                return
            _apply_store(new_store)
            get_logger().info("IMPORT\t+%s ~%s skip:%s reject:%s",
                              stats["added"], stats["updated"], stats["skipped"],
                              len(stats["rejected"]))
            _flash("success", "가져오기 완료 — 추가 {} · 갱신 {} · 건너뜀 {} · 거부 {}".format(
                stats["added"], stats["updated"], stats["skipped"], len(stats["rejected"])))
            st.rerun()


def render_sidebar_queries():
    store = st.session_state.saved_store
    items = store["items"]

    with st.sidebar:
        st.markdown('<span class="sg-side">📁 저장된 쿼리</span>&nbsp;'
                    '<span class="sg-sub">{}건</span>'.format(len(items)), unsafe_allow_html=True)

        if st.session_state.get("saved_warn"):
            st.warning(st.session_state.saved_warn)

        if not items:
            st.caption("저장된 쿼리가 없습니다. 편집기의 [💾 저장] 을 누르면 여기에 추가됩니다.")
        else:
            kw = (st.text_input("검색", key="sq_search", placeholder="🔍 이름 검색",
                                label_visibility="collapsed") or "").strip().lower()
            shown = [it for it in items if kw in it["name"].lower()] if kw else items

            if not shown:
                st.caption("'{}' 와 일치하는 쿼리가 없습니다.".format(kw))
            else:
                # 선택값이 목록에 없으면(삭제/검색으로 사라짐) 위젯 생성 전에 정리한다
                opts = [it["id"] for it in shown]
                names = {it["id"]: it["name"] for it in shown}
                if st.session_state.get("sq_selected") not in opts:
                    st.session_state.sq_selected = opts[0]
                st.selectbox("쿼리", options=opts, key="sq_selected",
                             format_func=lambda i: names.get(i, i), label_visibility="collapsed")

                qid = st.session_state.sq_selected
                sel = find_by_id(store, qid)
                if sel:
                    st.markdown('<span class="sg-sub">{} · {}줄</span>'.format(
                        sel.get("updated_at", "").replace("T", " "),
                        sel["sql"].count("\n") + 1), unsafe_allow_html=True)
                    if sel.get("note"):
                        st.caption(sel["note"])

                    st.button("📂 불러오기", key="sq_do_load", type="primary",
                              use_container_width=True, on_click=cb_load_saved)

                    with st.expander("이름 변경 / 삭제"):
                        st.text_input("새 이름", key="sq_rename_" + qid, value=sel["name"],
                                      max_chars=MAX_NAME_LEN)
                        st.button("이름 변경", key="sq_do_rename", use_container_width=True,
                                  on_click=cb_rename_saved, args=(qid,))
                        st.divider()
                        ok_del = st.checkbox("삭제 확인", key="sq_del_ok")
                        st.button("🗑 삭제", key="sq_do_delete", use_container_width=True,
                                  disabled=not ok_del, on_click=cb_delete_saved, args=(qid,))

        if st.session_state.get("sq_undo"):
            st.button("↩ 삭제 되돌리기 ({})".format(st.session_state.sq_undo["name"]),
                      key="sq_do_undo", use_container_width=True, on_click=cb_undo_delete)

        _render_import_export(store)
        st.caption("저장 위치: {}".format(QUERY_PATH))


# ============================================================
# 9. 메인
# ============================================================
def main():
    st.set_page_config(page_title="SQL Grid (PostgreSQL)", layout="wide")
    st.markdown(CUSTOM_CSS, unsafe_allow_html=True)

    params = load_conn_params()
    logger = get_logger()

    if "sql_input" not in st.session_state:
        st.session_state.sql_input = PRESETS["customers ⋈ orders"]

    # 저장 쿼리는 세션당 1회만 파일에서 읽는다(매 rerun 마다 읽지 않는다).
    # 쓰기 직전에는 commit_store 가 디스크 최신본을 다시 읽어 병합한다.
    if "saved_store" not in st.session_state:
        store, warn, readonly = load_store()
        st.session_state.saved_store = store
        st.session_state.saved_warn = warn
        st.session_state.saved_readonly = readonly
        st.session_state.sq_loaded_id = None
        st.session_state.sq_loaded_sql = ""
        st.session_state.sq_show_save = False
        st.session_state.sq_undo = None
        if warn:
            logger.error("STORE_WARN\t%s", warn)

    render_sidebar_queries()

    # --- Header ---
    h1, h2 = st.columns([3, 2])
    with h1:
        st.markdown(
            f'<span class="sg-title">🗄️ SQL Grid</span>&nbsp;&nbsp;'
            f'<span class="sg-sub">PostgreSQL 9.6</span>',
            unsafe_allow_html=True,
        )
    with h2:
        st.markdown(
            f'<div style="text-align:right;">'
            f'<span class="sg-sub">{conn_label(params)}</span>&nbsp;&nbsp;'
            f'<span class="sg-badge">READ ONLY</span></div>',
            unsafe_allow_html=True,
        )
    st.divider()

    # --- Editor ---
    st.caption("쿼리 편집기 · Ctrl+Enter 로 편집 확정")

    pcols = st.columns(len(PRESETS) + 1)
    pcols[0].markdown("**샘플**")
    for i, key in enumerate(PRESETS):
        pcols[i + 1].button(key, on_click=set_preset, args=(key,), use_container_width=True)

    st.text_area("SQL", key="sql_input", height=260,
                 placeholder="SELECT ... FROM ... WHERE ...", label_visibility="collapsed")

    tcol1, tcol2, tcol3, tcol4, tcol5 = st.columns([3.5, 1, 1, 1, 1])
    with tcol1:
        st.markdown(
            '<span class="sg-tag">SELECT 전용</span>'
            '<span class="sg-tag">다중문 차단</span>'
            '<span class="sg-tag">읽기 전용 계정</span>'
            '<span class="sg-tag">전체 조회 · 스크롤</span>',
            unsafe_allow_html=True,
        )
    with tcol2:
        st.download_button("⬇ .sql", data=(st.session_state.sql_input or "").encode("utf-8"),
                           file_name="query_{:%Y%m%d_%H%M%S}.sql".format(datetime.now()),
                           mime="text/plain", use_container_width=True,
                           disabled=not (st.session_state.sql_input or "").strip())
    with tcol3:
        # 저장 파일이 상위 버전이면 덮어써서 손상시키지 않도록 저장 자체를 막는다
        st.button("💾 저장", key="sq_open_save", on_click=cb_show_save, use_container_width=True,
                  disabled=bool(st.session_state.get("saved_readonly")))
    with tcol4:
        st.button("지우기", on_click=clear_sql, use_container_width=True)
    with tcol5:
        run = st.button("▶ 실행", type="primary", use_container_width=True)

    # 불러온 쿼리를 편집했는지 표시 (저장 누락 방지)
    loaded = find_by_id(st.session_state.saved_store, st.session_state.get("sq_loaded_id"))
    if loaded:
        changed = st.session_state.sql_input != st.session_state.get("sq_loaded_sql", "")
        st.caption("저장 쿼리: {}{}".format(loaded["name"], "  ●  수정됨(저장 안 됨)" if changed else ""))

    msg = st.session_state.pop("sq_msg", None)
    if msg:
        {"success": st.success, "error": st.error, "warning": st.warning}[msg[0]](msg[1])

    render_save_form()

    # --- Run ---
    if run:
        ok, query, err = validate_sql(st.session_state.sql_input)
        if not ok:
            st.session_state.sg_result = None
            st.session_state.sg_error = {"code": "", "message": err}
        else:
            logger.info("RUN\t%s", query.replace("\n", " "))
            try:
                with st.spinner("전체 결과 조회 중…"):
                    df, elapsed = run_query(query, params)
                mem_mb = df.memory_usage(deep=True).sum() / (1024 * 1024)
                logger.info("DONE\t%s rows\t%.3fs\t%.1fMB", len(df), elapsed, mem_mb)
                st.session_state.sg_result = {"df": df, "elapsed": elapsed}
                st.session_state.sg_error = None
            except psycopg2.Error as e:
                code = getattr(e, "pgcode", "") or ""
                msg = (e.pgerror or str(e)).strip()
                logger.error("ERR\t%s\t%s", code, msg.replace("\n", " "))
                st.session_state.sg_result = None
                st.session_state.sg_error = {"code": code, "message": msg}
            except Exception as e:  # 연결 실패 등
                st.session_state.sg_result = None
                st.session_state.sg_error = {"code": "", "message": str(e)}

    # --- Result / Error / Idle ---
    st.divider()
    error = st.session_state.get("sg_error")
    result = st.session_state.get("sg_result")

    if error:
        head = "쿼리 오류"
        if error.get("code"):
            head += f"  ·  SQLSTATE {error['code']}"
        st.error(f"**{head}**\n\n```\n{error['message']}\n```")
    elif result:
        df = result["df"]
        total = len(df)
        # 결과가 서버(pandas)에서 실제 차지하는 메모리 (문자열 실사용량 포함)
        mem_mb = df.memory_usage(deep=True).sum() / (1024 * 1024)

        m1, m2, m3, m4, m5 = st.columns([1, 1, 1, 1, 2])
        m1.markdown(f'조회 건수<br><span class="sg-metric">{total:,}</span>', unsafe_allow_html=True)
        m2.markdown(f'수행 시간<br><span class="sg-metric">{result["elapsed"]:.3f}s</span>', unsafe_allow_html=True)
        m3.markdown(f'메모리<br><span class="sg-metric">{mem_mb:,.1f} MB</span>', unsafe_allow_html=True)
        m4.markdown(f'컬럼<br><span class="sg-metric">{len(df.columns)}</span>', unsafe_allow_html=True)
        with m5:
            csv = ("﻿" + df.to_csv(index=False)).encode("utf-8")
            st.download_button(f"⬇ CSV 저장 ({total:,}행)", data=csv,
                               file_name=f"query_result_{datetime.now():%Y%m%d_%H%M%S}.csv",
                               mime="text/csv")

        if total == 0:
            st.info("조회 결과가 없습니다. (0건)")
        else:
            hint = "셀 클릭/드래그로 범위 선택(엑셀식) · Ctrl+C 로 복사 · 우측 스크롤바로 이동"
            if total >= LARGE_ROWS_HINT:
                hint += f" · 전체 {total:,}행 로드(초기 렌더가 다소 걸릴 수 있음)"
            st.caption(hint)
            render_grid(df)
    else:
        st.info("쿼리를 실행하면 결과가 여기에 표시됩니다.")


if __name__ == "__main__":
    main()
