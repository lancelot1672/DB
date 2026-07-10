# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 저장소 개요
DB 마이그레이션 관련된 ToolKit Repository 이다. 
제어 테이블 `DBADM.MIG_TAB_LIST`(및 소유자별 변형 `DBADM.MIG_TAB_LIST_{OWNER}`)를
중심으로 동작한다. **단일 애플리케이션이 아니라**, 디렉토리별로 독립적이고
자체 완결적인 도구들의 모음이다. 각 디렉토리는 독립적으로 동작하며 공유 라이브러리,
빌드 시스템, 디렉토리 간 import 가 없다.

두 종류의 도구가 있다:

- **Bash + SQL*Plus 스크립트** (`MIGRATION/`, `CANADA/`, `KZ_PROSYNC/`) — 제어 테이블을
  기반으로 Oracle Data Pump(`expdp`/`impdp`)와 DDL 추출을 수행.
- **Streamlit 웹 앱** (`TIBERO/`, `MIG_LIST/`) — 조회용 / 제어 테이블 INSERT SQL 생성용 Python UI.

## 디렉토리 구성

| 디렉토리 | 유형 | 용도 |
|-----|------|---------|
| `MIGRATION/` | shell | 번호순 파이프라인(`01.` → `03.`). 소유자별 제어 테이블 생성 후 메타데이터 / 제약조건 / 인덱스 DDL 추출. |
| `CANADA/` | shell + sql | "CANADA" 대상용 변형 마이그레이션 스크립트(제어 테이블 생성, 조건부 EXPDP, DB 디렉토리 설정). |
| `KZ_PROSYNC/` | shell | `impdp` 측: 리스트의 덤프 파일을 gunzip 후 import. |
| `MIG_LIST/` | Streamlit | 테이블 목록 Excel 업로드 → 검증 → `INSERT INTO DBADM.MIG_TAB_LIST` SQL 생성. `Dockerfile` 포함. |
| `TIBERO/` | Streamlit | DB 월간 점검을 위한 PostgreSQL 9.6 조회 전용 SQL 그리드(SELECT 전용 가드, 전체 조회, CSV 저장). `Dockerfile` / `docker-compose.yml` 포함. |

도구별 설계/요구사항 문서는 코드 옆에 `*_PLAN.md` / `README.md` 로 존재한다
(예: `TIBERO/SQL_GRID_WEB_PLAN.md`, `MIG_LIST/MIG_LIST_PLAN.md`). 동작을 바꾸기 전에
먼저 읽을 것 — 이 문서들이 사양(spec)이다.

## 실행 방법

**Streamlit 앱** (해당 앱 디렉토리 내에서):
```bash
cd TIBERO      # 또는 MIG_LIST
pip install -r requirements.txt
streamlit run app.py
```
`TIBERO/` 는 `PG.env` 가 필요하다(`PG.env.example` 복사). `MIG_LIST/` 는 Excel
템플릿을 최초 1회 생성해야 한다: `python create_template.py` (`template/` 에 생성).

컨테이너 실행:
```bash
# MIG_LIST
cd MIG_LIST && docker build -t mig_list . && docker run -p 8501:8501 mig_list

# TIBERO (compose, dong-network 외부 네트워크 필요)
cd TIBERO && docker network create dong-network && docker compose up -d --build
```

**Shell 스크립트** — `sqlplus`/`expdp` 가 PATH 에 있고 env 파일이 채워진 환경에서 실행한다
(아래 참조). 위치 인자를 받으며, 인자 없이 호출하면 사용법을 출력한다:
```bash
MIGRATION/01.CREATE_MIG_TAB_LIST_BY_OWNER.sh <LIST_FILE>   # LIST_FILE = 줄마다 "OWNER TABLE_NAME"
MIGRATION/02.EXPDP_META_PARFILE.sh <OWNER>                 # DB 디렉토리를 대화식으로 입력받음
MIGRATION/03.EXTRACT_INDEX.sh <OWNER>
```

이 저장소에는 테스트 스위트, 린터, CI 가 설정되어 있지 않다.

## 모든 Shell 스크립트의 공통 규약

모든 스크립트가 동일한 골격을 따른다 — 새 스크립트를 추가할 때 이를 맞출 것:

1. **Env 로딩**: `SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)` 로 경로를 구한 뒤, 로컬 env 파일
   (`MIGRATION/` 은 `MIG.env`, `CANADA/`·`KZ_PROSYNC/` 는 `.env`)을 source 하거나 없으면
   즉시 실패한다. 이 파일들은 **gitignore 대상**(`.gitignore` = `*.env`)이며 `DB_USER`,
   `DB_PASS`, `BASE_PATH` 를 제공한다. 자격증명을 하드코딩하지 말 것.
2. **로깅 헬퍼**: `_out()` 은 터미널에 출력하고 *동시에* `${BASE_PATH}/log/<SCRIPT>_<timestamp>.log`
   에 append 한다. `_log`/`_ok`/`_fail` 은 태그를 붙여 이를 감싼다.
3. **임시 파일**: `${BASE_PATH}/tmp/..._$$.sql` (PID 접미사)에 작성하고 `_cleanup` 함수로 정리한다.
4. **DB 접근**: `sqlplus -s ${DB_USER}/${DB_PASS}` 에 생성한 `.sql` 파일 또는 heredoc 을 넘긴다.
   각 호출 후 `$?` / `${PIPESTATUS[0]}` 를 확인한다.
5. **파괴적 작업**(INSERT, TRUNCATE)은 미리보기를 보여준 뒤 대화식 `y/N` 확인을 받는다.

## 제어 테이블

마이그레이션 흐름 전체가 `DBADM.MIG_TAB_LIST` 를 중심으로 돈다 — 이관 대상 테이블당 한 행이며,
선택적 `WHERE_COL*` / `PRE*` 컬럼은 부분/기간 export 를 위한 행 필터 조건
(`WHERE {col} >= '{pre1}' AND {col} < '{pre2}'`)이 된다. `MIG_LIST` 앱이 이 테이블의 INSERT 문을
생성하고, `01.` 스크립트가 소유자별 복제본을 만들며, `02.`/`03.` 스크립트가 이를 읽어 Data Pump
parfile 을 만들고 DDL 을 추출한다. Streamlit 생성기와 shell 스크립트는 컬럼 구성이 약간 다르므로
(`MIG_LIST`: `WHERE_COL1/PRE1/WHERE_COL2/PRE2`; `01.` 소유자별 테이블: `WHERE_COL/PRE1/PRE2`)
양쪽을 수정할 때 일관성을 유지할 것.

## TIBERO SQL 그리드 — 반드시 지켜야 할 사항

`TIBERO/app.py` 는 의도적으로 조회 전용이며, 다음 가드를 반드시 보존해야 한다:
정규식 기반 SELECT/WITH 전용 허용, 다중 문장 차단, DML/DDL 키워드 차단리스트,
`conn.set_session(readonly=True)`. 접속 정보는 `PG.env` 에서 로딩하며 코드에 하드코딩하지 않는다.

동작/구현 메모:
- **전체 조회 방식**: 단일 사용자 기준으로 결과 전체를 한 번에 fetch 하여 pandas DataFrame 으로
  보관하고, 그리드에서 가상 스크롤로 탐색한다(페이지네이션 없음).
- **그리드 값 변환**: `Decimal`/`date`/`datetime` 등 JSON 직렬화 불가 타입은 `grid_safe()`/`_to_cell()`
  로 변환한다. 미변환 시 그리드에 `[object Object]` 로 표시되므로 유지할 것.
- **그리드 기능**: 맨 앞 고정 행번호(`No`) 컬럼, 우측 스크롤바 상시 표시, 엑셀식 셀/범위 선택 +
  Ctrl+C 복사. 셀/범위 선택은 `enable_enterprise_modules=True`(AG Grid Enterprise 기능)에 의존하므로
  라이선스 정책에 유의(무라이선스 시 평가판 워터마크). `streamlit-aggrid` 미설치 시 `st.dataframe` 로 폴백.
- **메모리 표기**: 결과가 서버에서 차지하는 메모리를 `df.memory_usage(deep=True)` 로 계산해 메트릭에 표시한다.
- **더미 데이터**: `dummy_data.sql`(소량, `tstown` 스키마), `dummy_data_300k.sql`(`generate_series` 로
  30만 행 대량 생성) 로 대량 조회를 테스트할 수 있다.
