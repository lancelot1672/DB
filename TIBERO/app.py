"""
SQL Grid Web - PostgreSQL 9.6 조회 전용 그리드
SQL_EXECUTE.html 디자인 목업을 SQL_GRID_WEB_PLAN.md 요구사항에 맞춰 Streamlit 으로 변환.

- SELECT / WITH 조회 쿼리만 허용, 다중 문장 차단, DML/DDL 차단
- 행 수 제한(LIMIT), 수행 시간/건수 표시, CSV 다운로드
- 읽기 전용 세션, 실행 SQL/시각 로깅
- 접속 정보는 PG.env 에서 로딩 (하드코딩 금지)
"""
import os
import re
import time
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
ENV_PATH = os.path.join(BASE_DIR, "PG.env")
LOG_DIR = os.path.join(BASE_DIR, "log")

# 그리드 스크롤 조회 시 브라우저 부담 안내 임계치 (행 수)
LARGE_ROWS_HINT = 100000

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
    load_dotenv(ENV_PATH)
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
  .stTextArea textarea { font-family:monospace !important; font-size:13px !important; }
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
# 8. 콜백
# ============================================================
def set_preset(key):
    st.session_state.sql_input = PRESETS[key]


def clear_sql():
    st.session_state.sql_input = ""


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

    tcol1, tcol3, tcol4 = st.columns([4, 1, 1])
    with tcol1:
        st.markdown(
            '<span class="sg-tag">SELECT 전용</span>'
            '<span class="sg-tag">다중문 차단</span>'
            '<span class="sg-tag">읽기 전용 계정</span>'
            '<span class="sg-tag">전체 조회 · 스크롤</span>',
            unsafe_allow_html=True,
        )
    with tcol3:
        st.button("지우기", on_click=clear_sql, use_container_width=True)
    with tcol4:
        run = st.button("▶ 실행", type="primary", use_container_width=True)

    # --- Run ---
    if run:
        ok, query, err = validate_sql(st.session_state.sql_input)
        if not ok:
            st.session_state.sg_result = None
            st.session_state.sg_error = err
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
