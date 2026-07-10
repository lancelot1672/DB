# OBJECT_CHECK — ASIS ↔ TOBE 오브젝트 검증 프로세스

DB → DB 마이그레이션 시 **원본(ASIS)** 과 **대상(TOBE)** 사이의 오브젝트가
누락·불일치 없이 이관되었는지 검증하는 도구 모음이다. 마이그레이션 대상 목록
(`DBADM.MIG_TAB_LIST`)에 속한 테이블을 기준으로 각 DB의
딕셔너리를 복사해와 오브젝트 종류별 개수를 집계하고, ASIS/TOBE 개수 차이(GAP)를 비교한다.

이 디렉토리는 상위 `MIGRATION/` 파이프라인과 **독립적**이며, 자체 완결적으로 동작한다.
상위 `../../CLAUDE.md` 의 저장소 공통 규약을 따른다.

## 버전 정책 (디렉토리 분리)

여러 구현 버전을 만들되 **버전마다 디렉토리를 분리**한다. 각 버전은 자체 완결적이며
서로 import/공유하지 않는다.

| 버전 | 디렉토리 | 유형 | 상태 |
|------|----------|------|------|
| v1 | `./` (현재) | Bash + SQL*Plus 셸 스크립트 | 개발 중 |
| v2+ | 예: `./v2_xxx/` | (추후) | — |

> 새 버전을 추가할 때는 새 하위 디렉토리를 만들고, 이 문서의 표에 한 줄 추가한다.
> 기존 버전 디렉토리의 파일은 건드리지 않는다.



### 복제 대상 딕셔너리 (1·2단계)

두 단계가 동일한 오브젝트 집합을 각각 ASIS/TOBE 에서 복제한다 (`DBA_ASIS_*` / `DBA_TOBE_*`):

- `CONSTRAINTS` — `DBA_CONSTRAINTS` 중 `CONSTRAINT_TYPE IN ('P','C','U','R')`, `TABLE_NAME NOT LIKE 'BIN%'`
- `TABLES` — `DBA_TABLES`
- `TAB_COLUMNS` — `DBA_TAB_COLUMNS` (컬럼 구성·타입·길이·NULL 여부)
- `INDEXES` — `DBA_INDEXES`
- `TAB_PARTITIONS` — `DBA_TAB_PARTITIONS`
- `IND_PARTITIONS` — `DBA_IND_PARTITIONS`
- `OTHER_OBJECTS` — `DBA_OBJECTS` 중 `FUNCTION / PROCEDURE / PACKAGE / SEQUENCE / TRIGGER`

> **주의 — ASIS/TOBE 컬럼 구성 불일치:** 소스 dictionary 뷰의 컬럼명이 DB 벤더/버전에 따라
> 다르다. 예) 파티션의 위치 컬럼이 ASIS=`PARTITION_POSITION`, TOBE=`PARTITION_NO`,
> 소유자 컬럼이 `TABLE_OWNER` vs `OWNER`. 집계(3·4단계)에서 이 차이를 흡수하도록 컬럼을
> 표준화(alias)해서 맞출 것. 양쪽을 수정할 때 반드시 함께 검토한다.

### 개수 집계 스키마 (3·4단계)

`MIG_OBJ_CNT_ASIS` / `MIG_OBJ_CNT_TOBE` 는 동일 구조:

```
DB          VARCHAR(10)   -- 'ASIS' | 'TOBE'
OBJECT_NAME VARCHAR(100)  -- 집계 그룹 라벨 (CONSTRAINT, TABLE, TABLE PARTITION, INDEX, INDEX PARTITION, OTHERS OBJECT)
OWNER       VARCHAR(20)   -- 스키마 소유자
OBJECT_TYPE VARCHAR(100)  -- 세부 유형 (CONSTRAINT_P/C/U/R, TABLE, INDEX, FUNCTION ...)
CNT         NUMBER        -- 개수
```

집계는 복제된 `DBA_{ASIS|TOBE}_*` 를 제어 테이블 `DBADM.MIG_TAB_LIST` 과 조인하여
(`OWNER`/`TABLE_NAME` 매칭) 대상 테이블에 한정해 센다.

### GAP 리포트 (5단계)

`MIG_OBJ_CNT_ASIS` ⨝ `MIG_OBJ_CNT_TOBE` 를 `(OBJECT_NAME, OBJECT_TYPE, OWNER)` 기준
FULL OUTER JOIN 하여 `ASIS_CNT`, `TOBE_CNT`, `GAP(=ASIS-TOBE)` 를 출력한다. 한쪽에만
존재하는 행(누락)도 드러나도록 OUTER JOIN 을 쓰고, `GAP <> 0` 또는 한쪽 NULL 인 행을 강조한다.

## 제어 테이블

- `DBADM.MIG_TAB_LIST` — 마이그레이션 대상

## 셸 스크립트 규약 (v1)

상위 저장소 공통 골격을 그대로 따른다:

1. **Env 로딩** — `SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)` 후 로컬 `.env` (또는 `MIG.env`)
   를 source, 없으면 즉시 실패. `.env` 는 gitignore 대상이며 `DB_USER`/`DB_PASS`/`BASE_PATH`
   를 제공. 자격증명 하드코딩 금지.
2. **로깅 헬퍼** — `_out()`(터미널+`${BASE_PATH}/log/<SCRIPT>_<ts>.log` append), `_log`/`_ok`/`_fail`.
3. **임시 파일** — `${BASE_PATH}/tmp/..._$$.sql` (PID 접미사), `_cleanup` 로 정리.
4. **DB 접근** — `sqlplus -s ${DB_USER}/${DB_PASS}` 에 `.sql`/heredoc 전달, 호출마다
   `$?`/`${PIPESTATUS[0]}` 확인.
5. **파괴적 작업**(DROP/CTAS/TRUNCATE/INSERT) 전 미리보기 + 대화식 `y/N` 확인.
6. 인자 없이 호출하면 사용법(Usage) 출력.

## 입력 방식 — 화살표 선택 메뉴 (필수)

이 도구의 모든 사용자 입력은 **자유 타이핑이 아니라, 조회 결과를 목록으로 보여준 뒤
↑/↓ 화살표로 이동하고 Enter 로 선택**하는 방식이어야 한다.

- 대상: DB LINK 선택, OWNER/스키마 선택, 실행 단계 선택 등 모든 선택 입력.
- 구현: 방향키를 읽는 셀렉트 메뉴(예: `read -rsn` 로 이스케이프 시퀀스 파싱하는
  `select_menu()` 헬퍼)를 각 버전 디렉토리에 자체 구현한다. 현재 선택 항목을 반전 표시하고,
  Enter 로 확정, 필요 시 `q`/Ctrl-C 로 취소. `bash` 내장 `select` 는 화살표를 지원하지 않으므로
  방향키 파싱 헬퍼를 직접 둔다.
- 외부 의존(`fzf` 등)에 의존하지 않는 것을 기본으로 하되, 존재하면 활용 가능.

### DB LINK 선택 (dba_db_links)

ASIS 접속용 DB LINK 는 **하드코딩하지 않고** `DBA_DB_LINKS` 를 조회해 화살표 메뉴로 고른다.

```sql
SELECT owner, db_link, username, host FROM DBA_DB_LINKS ORDER BY db_link;
```

선택된 `db_link` 명을 1단계 SQL 의 `@ASIS_OGBEKRDB` 자리에 치환해 실행한다
(SQL 파일은 플레이스홀더를 두고 셸이 `sed`/변수 치환으로 주입). 즉 `1.ASIS_COPY_DICTIONARY.sql`
의 `@<DB_LINK>` 는 셸에서 선택한 값으로 채워진다.


## SQL 파이프라인 (`sql/`)

번호순으로 실행되는 5단계. 셸 스크립트는 이 SQL 들을 감싸 실행한다.

| # | 파일 | 대상 DB | 역할 |
|---|------|---------|------|
| 1 | `1.ASIS_COPY_DICTIONARY.sql` | ASIS (DB LINK 경유) | ASIS 딕셔너리를 `DBADM.DBA_ASIS_*` 로 복제 (CTAS) |
| 2 | `2.TOBE_COPY_DICTIONARY.sql` | TOBE (로컬) | TOBE 딕셔너리를 `DBADM.DBA_TOBE_*` 로 복제 (CTAS) |
| 3 | `3.ASIS_OBJECT_COUNT_CREATE.sql` | 로컬 | `DBADM.MIG_OBJ_CNT_ASIS` 생성 후 오브젝트 종류별 개수 집계 |
| 4 | `4.TOBE_OBJECT_COUNT_CREATE.sql` | 로컬 | `DBADM.MIG_OBJ_CNT_TOBE` 생성 후 오브젝트 종류별 개수 집계 |
| 5 | `5.ASIS_TOBE_OBJECT_GAP_CHECK.sql` | 로컬 | ASIS vs TOBE 개수를 조인·비교하여 GAP 리포트 출력 |

### SQL 설명
#### 1. ASIS_COPY_DICTIONARY.sql
ASIS DB의 DICTIONARY (DB 형상)을 DB LINK를 통해 조회하여 TOBE DB에 테이블로 생성한다.

#### 2. TOBE_COPY_DICTIONARY.sql
TOBE DB의 DICTIONARY (DB 형상)을 조회하여 TOBE DB에 테이블로 생성한다.

#### 3. ASIS_OBJECT_COUNT_CREATE.sql
1번에서 생성된 ASIS DICTIONARY 테이블 (DB 형상)을 조회하여 OBJECT COUNT 조회하여 TOBE DB에 테이블로 생성한다.<br>
결과 테이블 : DBADM.MIG_OBJ_CNT_ASIS

#### 4. TOBE_OBJECT_COUNT_CREATE.sql
2번에서 생성된 TOBE DICTIONARY 테이블 (DB 형상)을 조회하여 OBJECT COUNT 조회하여 TOBE DB에 테이블로 생성한다.<br>
결과 테이블 : DBADM.MIG_OBJ_CNT_TOBE

#### 5. TOBE_OBJECT_COUNT_CREATE.sql
DBADM.MIG_OBJ_CNT_ASIS <-> DBADM.MIG_OBJ_CNT_TOBE GAP 비교
