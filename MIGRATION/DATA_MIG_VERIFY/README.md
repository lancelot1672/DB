# DATA_MIG_VERIFY

사전이관(PRE) 데이터가 이관 이후 변경되지 않았는지 검증하는 Bash + SQL 도구.
테이블별로 **NUMBER 타입 컬럼의 `SUM()` 값을 ASIS / TOBE 양쪽에서 구해 비교**하고,
결과를 `DBADM.DBM_MIG_PRE_DATA_VERIFY` 에 적재한다.

- 대상 목록은 `DATA_MIG` 와 같은 제어 테이블 `DBADM.DBM_MIG_MSTR` 에서 읽는다
- **DB LINK 를 쓰지 않고 ASIS / TOBE 에 각각 접속**한다 (Oracle `sqlplus` ↔ Tibero `tbsql` 혼용 가능)
- **일반 SQL 만** 사용 (프로시저 / PL/SQL 금지), 결과 INSERT 외에는 양쪽 DB 모두 읽기 전용
- 상세 사양 : [`DATA_MIG_VERIFY_PLAN.md`](DATA_MIG_VERIFY_PLAN.md) / 실행 예시 : [`EXAMPLE.md`](EXAMPLE.md)

---

## 1. 구성

| 구분 | 파일 | 설명 |
|---|---|---|
| 결과 테이블 DDL | `DDL_Script/DBM_MIG_PRE_DATA_VERIFY.sql` | 검증 결과 (TOBE DB 에 생성) |
| 검증 쉘 | `01.RUN_DATA_VERIFY.sh` | 검증 수행 / 결과 적재 / 리포트 |
| 예시 | `EXAMPLE.md` | 데이터 &rarr; SQL &rarr; 화면 &rarr; 결과 테이블 전 과정 |
| 설정 | `VERIFY.env` (`VERIFY.env.example` 복사) | ASIS / TOBE 접속 정보, MSTR_ID, 옵션 (gitignore) |
| 산출물 | `${BASE_PATH}/cmd/ASIS`, `cmd/TOBE` | 테이블별 SUM 조회 SQL |
| | `${BASE_PATH}/cmd/RESULT` | 결과 INSERT SQL |
| | `${BASE_PATH}/log/DATA_VERIFY_{MSTR_ID}_{시각}.log` | 수행 로그 |

## 2. 준비

### 요구사항
- bash, `sqlplus`(ORACLE) / `tbsql`(TIBERO) 가 PATH 에 있을 것 (ASIS / TOBE 각각의 타입에 맞게)
- 실행 계정 권한
  - ASIS : 대상 테이블 SELECT, `ALL_TAB_COLUMNS` 조회
  - TOBE : 대상 테이블 SELECT, `ALL_TAB_COLUMNS` 조회,
    `DBM_MIG_MSTR` / `DBM_MIG_COL_MAP` SELECT, `DBM_MIG_PRE_DATA_VERIFY` INSERT
- 실행권한(+x) 불필요 : `bash 01.RUN_DATA_VERIFY.sh` 로 실행

### 결과 테이블 생성 (TOBE)
```bash
sqlplus dbadm/****** @DDL_Script/DBM_MIG_PRE_DATA_VERIFY.sql
```

### VERIFY.env
```bash
cp VERIFY.env.example VERIFY.env   # 값 채우기, 자격증명은 이 파일에만
```

| 항목 | 설명 |
|---|---|
| `ASIS_DB_TYPE` / `TOBE_DB_TYPE` | `ORACLE` / `TIBERO` (서로 달라도 됨) |
| `ASIS_DB_USER` `_PASS` `_TNS` | 소스 접속 정보 (`_TNS` 비우면 로컬 기본) |
| `TOBE_DB_USER` `_PASS` `_TNS` | 타겟 접속 정보. 제어 테이블 / 결과 테이블이 있는 DB |
| `MSTR_ID` | 검증할 `DBM_MIG_MSTR.MSTR_ID` |
| `MIG_TYPE_LIST` | 검증할 `MIG_TYPE` (기본 `PRE`, `PRE,DDAY` 가능) |
| `MAX_NUM_COLS` | 테이블당 비교할 NUMBER 컬럼 최대 개수 (기본 10) |
| `NUM_DATA_TYPES` | 숫자로 볼 `DATA_TYPE` (기본 `NUMBER`, `FLOAT` 등 추가 가능) |
| `COUNT_CHECK` | `Y` 면 `COUNT(*)` 도 한 행(`*ROW_COUNT*`)으로 비교 (기본 `Y`) |
| `PRE1_OP` / `PRE2_OP` | 조건 비교 연산자 (기본 `>=` / `<`). `PRE1_OP='>='` 처럼 따옴표 필수 |
| `PRE_COND_COL` | 조건 컬럼명을 담은 `DBM_MIG_MSTR` 컬럼 (기본 `COL_CONDITION`) |
| `WORKER_DEGREE` | 동시에 검증할 테이블 수 (기본 4). 테이블 1개당 DB 세션 2개(ASIS+TOBE) |
| `PARALLEL_DEGREE` | `SELECT /*+ PARALLEL(n) */` 차수 (0 또는 1 이면 힌트 없음) |
| `BASE_PATH` | `log/` `tmp/` `cmd/` 가 생성되는 작업 경로 |
| `SUM_FMT` / `SUM_ROUND` | 숫자 표기 보정 (아래 6. 참고) |
| `VERIFY_COLOR` | 화면 색상 : 비움 = 자동, `Y` 강제, `N` 끔 |

## 3. 실행

```bash
bash 01.RUN_DATA_VERIFY.sh                       # 전체 검증 + 결과 적재
bash 01.RUN_DATA_VERIFY.sh -t NEW.ORDERS,CUST    # 특정 테이블만 (TOBE 기준 OWNER.TABLE 또는 TABLE)
bash 01.RUN_DATA_VERIFY.sh -n                    # dry run : SQL 만 생성, 조회 / 적재 안 함
bash 01.RUN_DATA_VERIFY.sh -r [RUN_ID]           # 과거 수행 결과 리포트 (기본 : 최신 RUN_ID)
bash 01.RUN_DATA_VERIFY.sh -y                    # 확인 프롬프트 없이 (배치 / crontab)
```

종료 코드 : `0` 전부 일치 / `2` 불일치 또는 ERROR 존재 / `1` 실행 실패

```
============================================================
 SUMMARY   MSTR_ID=20260914   RUN_ID=7   tables=2
   일치   : 4
   불일치 : 2
   SKIP   : 2
   ERROR  : 0
============================================================
 tables to check :
    NEW.CUST_NOTI  불일치=2 ERROR=0
```

## 4. 검증 규칙

대상 : `MSTR_ID` = `VERIFY.env` 값 AND `MIG_YN = 'Y'` AND `MIG_TYPE IN (MIG_TYPE_LIST)`

| MIG_TYPE | 조회 조건 |
|---|---|
| `PRE` | `WHERE {COL_CONDITION} >= 'PRE1' AND {COL_CONDITION} < 'PRE2'` (연산자는 `PRE1_OP`/`PRE2_OP`) |
| `DDAY` | 조건 없음 (테이블 전체) |

- `COL_CONDITION` 은 이관 SQL 과 같이 **ASIS 기준 컬럼명**이다.
  `TRANS_YN = 'Y'` 인 테이블은 TOBE 쪽 조건 컬럼명을 `DBM_MIG_COL_MAP` 의 `RENAME` 으로 역매핑한다.
- `DDAY` 테이블은 D-day 에 이관되므로 그 전에 검증하면 당연히 불일치다.
  D-day 이전에는 `MIG_TYPE_LIST=PRE` 로 두고, D-day 적재 후에 `DDAY` 를 추가한다.

### 비교 컬럼 선정
1. TOBE `ALL_TAB_COLUMNS` 에서 `DATA_TYPE IN (NUM_DATA_TYPES)` 인 컬럼을 `COLUMN_ID` 순으로 최대 `MAX_NUM_COLS` 개
2. ASIS 컬럼명은 기본적으로 같은 이름. `TRANS_YN = 'Y'` 이면 `DBM_MIG_COL_MAP` 적용
   - `RENAME` → `SRC_COL` 사용
   - `ADD` → ASIS 원본이 없으므로 `SKIP`
3. ASIS 에 해당 컬럼이 없거나 숫자 타입이 아니면 `SKIP`

생성되는 SQL (예)
```sql
SELECT /*+ PARALLEL(2) */ '#S#'||TO_CHAR(SUM("QTY"))||'|'||TO_CHAR(SUM("AMT"))||'|'||TO_CHAR(COUNT(*))
  FROM "OLD"."ORD"
 WHERE "ORD_DT" >= '20250101' AND "ORD_DT" < '20250701';
```

## 5. 결과 테이블

`DBADM.DBM_MIG_PRE_DATA_VERIFY` — **1 행 = 컬럼 1개 비교 결과**

| 컬럼 | 설명 |
|---|---|
| `RUN_ID` | 수행 회차. 매 수행마다 `MAX(RUN_ID)+1`, 과거 이력은 보존 |
| `MSTR_ID` | `DBM_MIG_MSTR.MSTR_ID` |
| `OWNER` / `TABLE_NAME` / `COLUMN_NAME` | **TOBE(타겟) 기준** 이름 |
| `SRC_OWNER` / `SRC_TABLE_NAME` / `SRC_COLUMN_NAME` | ASIS(소스) 기준 이름 |
| `MIG_TYPE` | `PRE` / `DDAY` |
| `VERIFY_COND` | 실제 적용한 WHERE 조건 |
| `ASIS_COL` / `TOBE_COL` | SUM 값 (원문 그대로 **문자로 저장** — 큰 수 / 소수 정밀도 보존) |
| `DIFF` | 불일치일 때 참고용 차이값 (double 연산이라 아주 큰 값은 근사) |
| `STATUS` | `일치` / `불일치` / `SKIP` / `ERROR` |
| `ERROR_MSG` | SKIP / ERROR 사유, DB 오류 메시지 |
| `VERIFY_DT` | 수행 시각 |

- `COLUMN_NAME = '*ROW_COUNT*'` : `COUNT(*)` 비교 행 (`COUNT_CHECK=Y`)
- `COLUMN_NAME = '*NONE*'` : 테이블 단위 ERROR / 비교할 컬럼이 없는 경우
- 숫자 비교는 **정규화 후 문자 비교** (`00150` = `150`, `1234.5600` = `1234.56`, `-.5` = `-0.5`)

```sql
-- 최신 수행의 불일치만
SELECT * FROM DBADM.DBM_MIG_PRE_DATA_VERIFY
 WHERE MSTR_ID = '20260914'
   AND RUN_ID  = (SELECT MAX(RUN_ID) FROM DBADM.DBM_MIG_PRE_DATA_VERIFY WHERE MSTR_ID = '20260914')
   AND STATUS <> '일치'
 ORDER BY OWNER, TABLE_NAME, COLUMN_NAME;
```

## 6. 주의사항

1. **`SUM_FMT`** : ASIS 와 TOBE 가 같은 값을 다르게 출력하면(Oracle ↔ Tibero, `NLS` 차이,
   아주 큰 수의 지수 표기 등) 정규화로도 맞출 수 없다. 이 때 `SUM_FMT` 에 양쪽 공통 포맷을 준다
   (예 `SUM_FMT=TM9`). 지수 표기(`1.23E+37`) 값은 정규화하지 않고 그대로 비교한다.
2. **`SUM_ROUND`** : 부동소수 계열 컬럼이 끝자리에서만 달라질 때 `SUM_ROUND=2` 처럼 지정하면
   `ROUND(SUM(col), 2)` 로 비교한다.
3. SUM 은 전수 스캔이다. 큰 테이블은 `PARALLEL_DEGREE` / `WORKER_DEGREE` 로 조절하되
   `WORKER_DEGREE x 2` 개의 DB 세션이 동시에 뜨는 점을 감안한다 (ASIS + TOBE 각 1개).
4. 검증 중 소스에 DML 이 계속 발생하면 조회 시점 차이로 불일치가 날 수 있다.
   사전이관 구간(`[PRE1, PRE2)`)이 더 이상 변하지 않는 시점에 수행하는 것이 전제다.
5. 1:N 로 행이 분할된 테이블, `ADD` 로 값이 생성된 컬럼은 SUM 비교 대상이 아니다 (`SKIP`).
6. 결과 INSERT 는 400건 단위로 나누어 `COMMIT` 한다. 중간 실패 시 이미 커밋된 건은 남으므로,
   `RUN_ID` 로 구분해 확인한다.
7. 한글 값 : 클라이언트 캐릭터셋을 DB 에 맞춘다 (`NLS_LANG` / `TB_NLS_LANG`).
