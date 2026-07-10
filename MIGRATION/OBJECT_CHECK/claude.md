# OBJECT_CHECK — ASIS ↔ TOBE 오브젝트 검증 프로세스

DB → DB 마이그레이션 시 **원본(ASIS)** 과 **대상(TOBE)** 사이의 오브젝트가
누락·불일치 없이 이관되었는지 검증하는 도구 모음이다. 마이그레이션 대상 목록
(`DBADM.dbm_mig_mstr`, `MIG_YN IN ('META','Y')`)에 속한 테이블을 기준으로 각 DB의
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

## SQL 파이프라인 (`sql/`)

번호순으로 실행되는 5단계. 셸 스크립트는 이 SQL 들을 감싸 실행한다.

| # | 파일 | 대상 DB | 역할 |
|---|------|---------|------|
| 1 | `1.ASIS_COPY_DICTIONARY.sql` | ASIS (DB LINK 경유) | ASIS 딕셔너리를 `DBADM.DBA_ASIS_*` 로 복제 (CTAS) |
| 2 | `2.TOBE_COPY_DICTIONARY.sql` | TOBE (로컬) | TOBE 딕셔너리를 `DBADM.DBA_TOBE_*` 로 복제 (CTAS) |
| 3 | `3.ASIS_OBJECT_COUNT_CREATE.sql` | 로컬 | `DBADM.MIG_OBJ_CNT_ASIS` 생성 후 오브젝트 종류별 개수 집계 |
| 4 | `4.TOBE_OBJECT_COUNT_CREATE.sql` | 로컬 | `DBADM.MIG_OBJ_CNT_TOBE` 생성 후 오브젝트 종류별 개수 집계 |
| 5 | `5.ASIS_TOBE_OBJECT_GAP_CHECK.sql` | 로컬 | ASIS vs TOBE 개수를 조인·비교하여 GAP 리포트 출력 |

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

집계는 복제된 `DBA_{ASIS|TOBE}_*` 를 제어 테이블 `DBADM.dbm_mig_mstr` 과 조인하여
(`MIG_YN IN ('META','Y')`, `OWNER=ASIS_OWNER`/`TABLE_NAME` 매칭) 대상 테이블에 한정해 센다.

### GAP 리포트 (5단계)

`MIG_OBJ_CNT_ASIS` ⨝ `MIG_OBJ_CNT_TOBE` 를 `(OBJECT_NAME, OBJECT_TYPE, OWNER)` 기준
FULL OUTER JOIN 하여 `ASIS_CNT`, `TOBE_CNT`, `GAP(=ASIS-TOBE)` 를 출력한다. 한쪽에만
존재하는 행(누락)도 드러나도록 OUTER JOIN 을 쓰고, `GAP <> 0` 또는 한쪽 NULL 인 행을 강조한다.

## 제어 테이블

- `DBADM.dbm_mig_mstr` — 마이그레이션 대상 마스터. 최소 컬럼: `ASIS_OWNER`, `TABLE_NAME`, `MIG_YN`.
  검증 범위는 `MIG_YN IN ('META','Y')` 행으로 한정한다.

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

- 대상: DB LINK 선택 등 모든 선택 입력.
- 구현: 방향키를 읽는 셀렉트 메뉴(`read -rsn` 로 이스케이프 시퀀스 파싱하는 `select_menu()`
  함수)를 `object_check.sh` 안에 자체 구현한다. 현재 선택 항목을 반전 표시하고, Enter 로 확정,
  `q` 로 취소. `bash` 내장 `select` 는 화살표를 지원하지 않으므로 방향키 파싱을 직접 둔다.
- 외부 의존(`fzf` 등)에 의존하지 않는 것을 기본으로 하되, 존재하면 활용 가능.

### STEP 0 — MIG_TAB_LIST OWNER별 TABLE_COUNT 확인 (필수, 맨 처음)

파이프라인 시작 전, 검증 대상 목록 `DBADM.MIG_TAB_LIST` 의 **OWNER별 TABLE_COUNT
(ASIS_OWNER / TOBE_OWNER 그룹)와 총건수**를 먼저 조회해 보여주고 `Y/N` 으로 진행 여부를
확인한다(`precheck_mig_tab_list`). `N` 이면 종료, 조회 실패면 `FAIL` 로 중단.

### 단계별 SQL 미리보기 + Y/N (필수)

`object_check.sh` 는 STEP 0 확인 후 1~5단계를 순서대로 돌며, **각 단계에서 실행할 SQL 전문을
화면에 출력한 뒤 `Y/N` 을 입력받는다**. DB LINK 치환이 필요한 단계는 치환된 최종 SQL 을 출력한다.

- **명시적 입력 강제** — `Y`/`N` 만 유효. 빈 Enter·기타 입력은 재질문(`confirm` 루프)하여
  실수로 다음 단계로 넘어가지 않게 한다.
- `Y` = 실행, `N` = 그 단계 SKIP 후 다음 단계로 진행.
- **FAIL 시 중단** — 실행 오류(sqlplus rc≠0) 또는 **세부 과정 완료 현황에 `FAIL` 이 하나라도
  있으면** 그 단계에서 파이프라인을 즉시 중단(`finish 1`)하고 요약을 출력한다. 이후 단계는
  실행되지 않고 `N/A` 로 표기.

### 세부 과정 완료 현황 (필수)

각 STEP 은 여러 세부 과정(sub-task)으로 구성되며, 실행 직후 **세부 과정별 완료 현황
체크리스트**(대상별 `OK`/`FAIL`/`EMPTY` + 건수)를 출력한다. 세부 과정은 `sql/*.sql` 에서 도출:

- **STEP 1/2** — 딕셔너리 테이블 7개 생성 (`DBADM.DBA_{ASIS|TOBE}_` × CONSTRAINTS / TABLES /
  TAB_COLUMNS / INDEXES / TAB_PARTITIONS / IND_PARTITIONS / OTHER_OBJECTS). 검증: 각 테이블 건수.
- **STEP 3/4** — 개수 집계 6종 INSERT (OBJECT_NAME = CONSTRAINT / TABLE / TABLE PARITTION /
  INDEX / INDEX PARITTION / OTHERS OBJECT). 검증: `MIG_OBJ_CNT_{ASIS|TOBE}` 를 OBJECT_NAME 별
  그룹핑하여 `groups`(OWNER×유형 조합 수)·`cnt`(합계) 표기. **0건도 `OK (empty, 0 rows)` 로
  정상 완료 처리**(파티션 없는 스키마는 0건이 정상)하며 `n/n complete` 에 포함한다. 실제 예외
  (테이블 미존재 등)만 `FAIL` 로 카운트에서 제외.

구현: `verify_dict()`/`verify_count()` 가 **대상마다 개별 `SELECT COUNT(*)` 를 셸 루프로
실행**하여 `[1/7] [2/7] …` 처럼 한 줄씩 순차 출력하고, 항목 사이에 `sleep ${STEP_SLEEP}`
(기본 `0.5` 초) 를 둔다(진행 상황이 눈에 보이도록). 누락 테이블 등 스칼라가 숫자로 안 나오면
`FAIL` 로 표기하고 그 STEP 을 중단한다. `OBJECT_NAME` 라벨은 `sql/*.sql` 의 리터럴
(오타 `PARITTION` 포함)과 **정확히 일치**해야 하므로 SQL 라벨 변경 시 함께 수정한다.
마지막에 STEP 별 `OK`/`SKIP`/`FAIL` 요약을 출력한다.

### DB LINK 선택 (dba_db_links)

ASIS 접속용 DB LINK 는 **하드코딩하지 않고** `DBA_DB_LINKS` 를 조회해 화살표 메뉴로 고른다.

```sql
SELECT owner, db_link, username, host FROM DBA_DB_LINKS ORDER BY db_link;
```

**SQL 파일은 수정하지 않는다.** 캐노니컬 `sql/*.sql` 에는 DB LINK 가 리터럴 토큰
`ASIS_OGBEKRDB` 로 박혀 있고(`object_check.sh` 의 `OC_DBLINK_TOKEN`), 셸이 실행 시점에
`${BASE_PATH}/tmp/` 에 SQL 사본을 만들어 이 토큰을 선택한 DB LINK 로 `sed` 치환한 뒤
그 tmp 파일을 `sqlplus` 로 실행한다. 원본 SQL 은 그대로 둔다. 1·3단계가 원격 DB LINK 를
참조하므로 치환 대상이며, DB LINK 는 최초로 필요한 단계에서 한 번 고른 뒤 재사용한다.

## 구성 파일 (v1)

**셸은 단일 파일 `object_check.sh` 로 통합**되어 있다(env 로딩·로깅·`confirm`·화살표
`select_menu`·DB LINK 선택·SQL 치환/실행을 모두 포함, self-contained).

| 파일 | 역할 |
|------|------|
| `object_check.sh` | 5단계 파이프라인 통합 실행 스크립트. |
| `.env` / `.env.example` | `DB_USER`/`DB_PASS`/`BASE_PATH`. `.env` 는 gitignore 대상. |
| `sql/1`~`sql/5.*.sql` | 캐노니컬 SQL(스펙). 셸이 감싸 실행. |

## 실행 방법 (v1)

```bash
cp .env.example .env      # DB_USER / DB_PASS / BASE_PATH 채우기
./object_check.sh
#  → 1단계에서 dba_db_links 조회 후 화살표로 DB LINK 선택
#  → 각 단계마다 실행할 SQL 을 출력하고 Y/N 확인 (N = 해당 단계 건너뜀)
#  → 1·2 딕셔너리 복제 → 3·4 개수 집계 → 5 GAP 리포트(조회 전용)
```

이 저장소에는 테스트/린터/CI 가 없다.
