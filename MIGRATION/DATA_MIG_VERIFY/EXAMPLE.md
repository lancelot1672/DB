# DATA_MIG_VERIFY 실행 예시

`01.RUN_DATA_VERIFY.sh` 의 동작을 처음부터 끝까지 따라가는 예시.
실제 값(OWNER, 건수, 소요시간)은 환경에 따라 달라진다.

---

## 0. 예시 데이터

### `DBADM.DBM_MIG_MSTR` (TOBE DB) — `MSTR_ID = 20260914`

| SRC_OWNER | SRC_TABLE_NAME | TGT_OWNER | TGT_TABLE_NAME | TRANS_YN | MIG_TYPE | MIG_FULL | COL_CONDITION | PRE1 | PRE2 | TAB_SIZE |
|---|---|---|---|---|---|---|---|---|---|---|
| OLD | ORD | NEW | ORDERS | N | PRE | COND | ORD_DT | 20250101 | 20250701 | 20480 |
| OLD | TB_CUST_NOTI | NEW | CUST_NOTI | Y | PRE | COND | SEND_DT | 20250101 | 20250701 | 5120 |

### `DBADM.DBM_MIG_COL_MAP` — 컬럼명이 바뀐 테이블만 등록

| SRC_OWNER | SRC_TABLE_NAME | TGT_OWNER | TGT_TABLE_NAME | TGT_COL | SRC_COL | MAP_FLAG |
|---|---|---|---|---|---|---|
| OLD | TB_CUST_NOTI | NEW | CUST_NOTI | SMS_CNT | SMS_SEND_CNT | RENAME |
| OLD | TB_CUST_NOTI | NEW | CUST_NOTI | KAKAO_CNT | | ADD |

### 테이블 컬럼 구성

| | TOBE (NEW) | ASIS (OLD) |
|---|---|---|
| **ORDERS / ORD** | `ORD_NO` VARCHAR2 (1)<br>`QTY` **NUMBER** (2)<br>`AMT` **NUMBER** (3)<br>`ORD_DT` VARCHAR2 (4) | `ORD_NO`, `QTY`, `AMT`, `ORD_DT` (동일) |
| **CUST_NOTI / TB_CUST_NOTI** | `SEND_SEQ` **NUMBER** (1)<br>`SMS_CNT` **NUMBER** (2)<br>`KAKAO_CNT` **NUMBER** (3)<br>`ONLY_TGT` **NUMBER** (4)<br>`SEND_DT` VARCHAR2 (5) | `SEND_SEQ` **NUMBER**<br>`SMS_SEND_CNT` **NUMBER**<br>`SEND_DT` VARCHAR2 |

괄호 안은 `COLUMN_ID`. 비교 대상은 **TOBE 기준 NUMBER 컬럼을 `COLUMN_ID` 순으로 최대 10개**.

---

## 1. 준비

```bash
cd DB/MIGRATION/DATA_MIG_VERIFY

# ① 결과 테이블 생성 (TOBE DB)
tbsql dbadm/****** @DDL_Script/DBM_MIG_PRE_DATA_VERIFY.sql

# ② 설정
cp VERIFY.env.example VERIFY.env
vi VERIFY.env
```

`VERIFY.env` (ASIS = Oracle, TOBE = Tibero 인 경우)

```bash
TOBE_DB_TYPE=TIBERO
TOBE_DB_USER=dbadm
TOBE_DB_PASS=********
TOBE_DB_TNS=TOBETNS

ASIS_DB_TYPE=ORACLE
ASIS_DB_USER=dbadm
ASIS_DB_PASS=********
ASIS_DB_TNS=ASISTNS

MSTR_ID=20260914
MIG_TYPE_LIST=PRE
MAX_NUM_COLS=10
COUNT_CHECK=Y
PRE1_OP='>='
PRE2_OP='<'
WORKER_DEGREE=4
PARALLEL_DEGREE=2
BASE_PATH=/home/oracle/data_mig_verify
```

> `VERIFY.env` 는 gitignore 대상(`*.env`). `log/` `tmp/` `cmd/` 는 `BASE_PATH` 아래 자동 생성.

---

## 2. Dry run — SQL 만 먼저 확인 `-n`

실제 조회 없이 어떤 SQL 이 나가는지 먼저 본다.

```bash
bash 01.RUN_DATA_VERIFY.sh -n -y
```

```
============================================================
 DATA MIGRATION PRE-VERIFY
  MSTR_ID        : 20260914
  MIG_TYPE       : PRE
  ASIS           : ORACLE (sqlplus)  dbadm@ASISTNS
  TOBE           : TIBERO (tbsql)  dbadm@TOBETNS
  MAX_NUM_COLS   : 10   COUNT_CHECK : Y   NUM TYPE : NUMBER
  WORKER/PARALLEL: 4 / 2
  LOG            : /home/oracle/data_mig_verify/log/DATA_VERIFY_20260914_20260918_144713.log
============================================================
[14:47:13] read DBADM.DBM_MIG_MSTR ...
[OK]   target tables : 2
[14:47:14] read TOBE ALL_TAB_COLUMNS ...
[OK]   TOBE number columns : 6
[14:47:14] read ASIS ALL_TAB_COLUMNS ...
[OK]   ASIS number columns : 4
[14:47:14] read DBADM.DBM_MIG_COL_MAP ...
[OK]   column mappings : 2
[OK]   RUN_ID : 7
============================================================
  NEW.ORDERS : SQL only (2 columns)
  NEW.CUST_NOTI : SQL only (2 columns)
============================================================
[OK]   dry run : SQL written under .../cmd/ASIS and .../cmd/TOBE (nothing was run, nothing inserted)
```

### 생성된 SQL

`cmd/ASIS/NEW_ORDERS.sql` — **파일명은 TOBE 기준**(`{TGT_OWNER}_{TGT_TABLE_NAME}.sql`)이라 양쪽이 짝을 이룬다

```sql
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET LINESIZE 32767
SET TRIMSPOOL ON
SET VERIFY OFF
SET ECHO OFF
WHENEVER SQLERROR EXIT FAILURE
-- ASIS OLD.ORD   MSTR_ID=20260914 RUN_ID=7 MIG_TYPE=PRE
SELECT /*+ PARALLEL(2) */ '#S#'||TO_CHAR(SUM("QTY"))||'|'||TO_CHAR(SUM("AMT"))||'|'||TO_CHAR(COUNT(*))
  FROM "OLD"."ORD"
 WHERE "ORD_DT" >= '20250101' AND "ORD_DT" < '20250701';
EXIT
```

`cmd/TOBE/NEW_ORDERS.sql`

```sql
-- TOBE NEW.ORDERS   MSTR_ID=20260914 RUN_ID=7 MIG_TYPE=PRE
SELECT /*+ PARALLEL(2) */ '#S#'||TO_CHAR(SUM("QTY"))||'|'||TO_CHAR(SUM("AMT"))||'|'||TO_CHAR(COUNT(*))
  FROM "NEW"."ORDERS"
 WHERE "ORD_DT" >= '20250101' AND "ORD_DT" < '20250701';
```

`cmd/ASIS/NEW_CUST_NOTI.sql` — **`TRANS_YN='Y'` 라 컬럼명이 ASIS 기준으로 치환**됐다

```sql
-- ASIS OLD.TB_CUST_NOTI   MSTR_ID=20260914 RUN_ID=7 MIG_TYPE=PRE
SELECT /*+ PARALLEL(2) */ '#S#'||TO_CHAR(SUM("SEND_SEQ"))||'|'||TO_CHAR(SUM("SMS_SEND_CNT"))||'|'||TO_CHAR(COUNT(*))
  FROM "OLD"."TB_CUST_NOTI"
 WHERE "SEND_DT" >= '20250101' AND "SEND_DT" < '20250701';
```

`cmd/TOBE/NEW_CUST_NOTI.sql`

```sql
-- TOBE NEW.CUST_NOTI   MSTR_ID=20260914 RUN_ID=7 MIG_TYPE=PRE
SELECT /*+ PARALLEL(2) */ '#S#'||TO_CHAR(SUM("SEND_SEQ"))||'|'||TO_CHAR(SUM("SMS_CNT"))||'|'||TO_CHAR(COUNT(*))
  FROM "NEW"."CUST_NOTI"
 WHERE "SEND_DT" >= '20250101' AND "SEND_DT" < '20250701';
```

> **`CUST_NOTI` 의 컬럼이 4개인데 왜 2개만 조회하나**
> - `KAKAO_CNT` → `DBM_MIG_COL_MAP` 의 `ADD`. 이관 시 생성된 컬럼이라 ASIS 원본이 없음 → `SKIP`
> - `ONLY_TGT` → ASIS `TB_CUST_NOTI` 에 없는 컬럼 → `SKIP`
> - `SMS_CNT` → `RENAME` 이라 ASIS 에서는 `SMS_SEND_CNT` 로 조회
> - 조건 컬럼 `SEND_DT` 는 `RENAME` 등록이 없어 양쪽 같은 이름 사용

---

## 3. 실제 실행

```bash
bash 01.RUN_DATA_VERIFY.sh
```

```
============================================================
 DATA MIGRATION PRE-VERIFY
  MSTR_ID        : 20260914
  MIG_TYPE       : PRE
  ASIS           : ORACLE (sqlplus)  dbadm@ASISTNS
  TOBE           : TIBERO (tbsql)  dbadm@TOBETNS
  MAX_NUM_COLS   : 10   COUNT_CHECK : Y   NUM TYPE : NUMBER
  WORKER/PARALLEL: 4 / 2
  LOG            : /home/oracle/data_mig_verify/log/DATA_VERIFY_20260914_20260918_144713.log
============================================================
[14:47:13] read DBADM.DBM_MIG_MSTR ...
[OK]   target tables : 2
[14:47:14] read TOBE ALL_TAB_COLUMNS ...
[OK]   TOBE number columns : 6
[14:47:14] read ASIS ALL_TAB_COLUMNS ...
[OK]   ASIS number columns : 4
[14:47:14] read DBADM.DBM_MIG_COL_MAP ...
[OK]   column mappings : 2
[OK]   RUN_ID : 7

  tables : 2    RUN_ID : 7    dry run : N
  run the verify ? (y/N) : y

[14:47:15] verify start : 2 tables, 4 at a time
============================================================
  NEW.ORDERS : 일치 3 / SKIP 0   (8s)
  NEW.CUST_NOTI : 불일치 2 / 일치 1 / SKIP 2   (12s)
============================================================
[14:47:27] verify done
[14:47:27] insert 8 rows into DBADM.DBM_MIG_PRE_DATA_VERIFY (RUN_ID=7) ...
[OK]   result loaded : 8 rows, RUN_ID=7

============================================================
 SUMMARY   MSTR_ID=20260914   RUN_ID=7   tables=2
   일치   : 4
   불일치 : 2
   SKIP   : 2
   ERROR  : 0
============================================================
 tables to check :
    NEW.CUST_NOTI  불일치=2 ERROR=0
============================================================
[14:47:28] log : /home/oracle/data_mig_verify/log/DATA_VERIFY_20260914_20260918_144713.log
 detail : bash 01.RUN_DATA_VERIFY.sh -r 7
```

- 화면에서 `일치` 는 초록, `불일치` / `ERROR` 는 빨강, `SKIP` 은 노랑 (로그 파일은 색 없음)
- 테이블은 `TAB_SIZE` 작은 것부터 `WORKER_DEGREE` 개씩 동시에 진행

### 이 때 DB 에서 실제로 읽은 값

| | ASIS | TOBE | 판정 |
|---|---|---|---|
| `ORDERS` 조회 결과 | `#S#00150\|  1234.5600\|9821` | `#S#00150\|  1234.5600\|9821` | 3건 일치 |
| `CUST_NOTI` 조회 결과 | `#S#5000\|777\|120` | `#S#5000\|775\|119` | `SMS_CNT`, `*ROW_COUNT*` 불일치 |

> `00150` / `  1234.5600` 처럼 앞뒤 0 과 공백이 붙어 나와도
> 정규화 후 비교하므로 `150` / `1234.56` 로 판정된다.

---

## 4. 결과 테이블

```sql
SELECT OWNER, TABLE_NAME, COLUMN_NAME, SRC_COLUMN_NAME,
       ASIS_COL, TOBE_COL, DIFF, STATUS, ERROR_MSG
  FROM DBADM.DBM_MIG_PRE_DATA_VERIFY
 WHERE MSTR_ID = '20260914' AND RUN_ID = 7
 ORDER BY TABLE_NAME, COLUMN_NAME;
```

| OWNER | TABLE_NAME | COLUMN_NAME | SRC_COLUMN_NAME | ASIS_COL | TOBE_COL | DIFF | STATUS | ERROR_MSG |
|---|---|---|---|---|---|---|---|---|
| NEW | CUST_NOTI | `*ROW_COUNT*` | `*ROW_COUNT*` | 120 | 119 | 1 | **불일치** | |
| NEW | CUST_NOTI | KAKAO_CNT | *(NULL)* | | | | SKIP | DBM_MIG_COL_MAP : ADD column (no ASIS source) |
| NEW | CUST_NOTI | ONLY_TGT | ONLY_TGT | | | | SKIP | ASIS OLD.TB_CUST_NOTI.ONLY_TGT not found (or not NUMBER) |
| NEW | CUST_NOTI | SEND_SEQ | SEND_SEQ | 5000 | 5000 | | 일치 | |
| NEW | CUST_NOTI | SMS_CNT | SMS_SEND_CNT | 777 | 775 | 2 | **불일치** | |
| NEW | ORDERS | `*ROW_COUNT*` | `*ROW_COUNT*` | 9821 | 9821 | | 일치 | |
| NEW | ORDERS | AMT | AMT | 1234.56 | 1234.56 | | 일치 | |
| NEW | ORDERS | QTY | QTY | 150 | 150 | | 일치 | |

공통 컬럼 값 (모든 행 동일) : `RUN_ID=7`, `MSTR_ID=20260914`, `SRC_OWNER=OLD`, `MIG_TYPE=PRE`,
`VERIFY_COND = SEND_DT >= '20250101' AND SEND_DT < '20250701'` (테이블별 조건), `VERIFY_DT=2026-09-18 14:47`

실제 적재된 INSERT 문 (`cmd/RESULT/RESULT_20260914_R7_0000.sql`) 중 한 줄:

```sql
INSERT INTO DBADM.DBM_MIG_PRE_DATA_VERIFY (RUN_ID, MSTR_ID, OWNER, TABLE_NAME, COLUMN_NAME,
  SRC_OWNER, SRC_TABLE_NAME, SRC_COLUMN_NAME, MIG_TYPE, VERIFY_COND, ASIS_COL, TOBE_COL, DIFF,
  STATUS, ERROR_MSG, VERIFY_DT)
VALUES (7, '20260914', 'NEW', 'CUST_NOTI', 'SMS_CNT', 'OLD', 'TB_CUST_NOTI', 'SMS_SEND_CNT', 'PRE',
  'SEND_DT >= ''20250101'' AND SEND_DT < ''20250701''', '777', '775', '2', '불일치', NULL, SYSDATE);
```

---

## 5. 리포트 `-r`

```bash
bash 01.RUN_DATA_VERIFY.sh -r        # 최신 RUN_ID
bash 01.RUN_DATA_VERIFY.sh -r 7      # 특정 RUN_ID
```

```
============================================================
 DATA VERIFY REPORT   MSTR_ID=20260914   RUN_ID=7
============================================================
=== SUMMARY ===
    RUN_ID STATUS          CNT
---------- -------- ----------
         7 SKIP              2
         7 불일치            2
         7 일치              4

=== NOT 일치 ===
OWNER   TABLE_NAME   COLUMN_NAME    ASIS_COL   TOBE_COL   STATUS
------- ------------ -------------- ---------- ---------- --------
NEW     CUST_NOTI    KAKAO_CNT                             SKIP
NEW     CUST_NOTI    ONLY_TGT                              SKIP
NEW     CUST_NOTI    *ROW_COUNT*    120        119        불일치
NEW     CUST_NOTI    SMS_CNT        777        775        불일치
```

---

## 6. 특정 테이블만 `-t`

```bash
bash 01.RUN_DATA_VERIFY.sh -t NEW.ORDERS -y            # OWNER.TABLE
bash 01.RUN_DATA_VERIFY.sh -t ORDERS -y                # 테이블명만 써도 됨
bash 01.RUN_DATA_VERIFY.sh -t NEW.ORDERS,CUST_NOTI -y  # 여러 개는 쉼표
```

```
[OK]   target tables : 1
  NEW.ORDERS : 일치 3 / SKIP 0   (9s)
 SUMMARY   MSTR_ID=20260914   RUN_ID=8   tables=1
   일치   : 3
   불일치 : 0
```

> `-t` 로 돌려도 **새 `RUN_ID` 가 부여**된다 (위 예시는 8). 이전 회차는 그대로 남는다.

---

## 7. 오류가 났을 때

ASIS 조회가 실패하면 그 테이블은 `ERROR` 한 행으로 기록되고, 나머지 테이블은 계속 진행한다.

```
  NEW.ORDERS : ERROR  ASIS: ORA-00942: table or view does not exist
============================================================
 SUMMARY   MSTR_ID=20260914   RUN_ID=9   tables=1
   일치   : 0
   불일치 : 0
   SKIP   : 0
   ERROR  : 1
```

| COLUMN_NAME | STATUS | ERROR_MSG |
|---|---|---|
| `*NONE*` | ERROR | `ASIS: ORA-00942: table or view does not exist` |

---

## 8. STATUS 판정 요약

| 상황 | STATUS | 비고 |
|---|---|---|
| ASIS SUM = TOBE SUM | `일치` | 정규화 후 문자 비교 |
| ASIS SUM ≠ TOBE SUM | `불일치` | `DIFF` 에 참고용 차이값 |
| `DBM_MIG_COL_MAP` 의 `ADD` 컬럼 | `SKIP` | ASIS 원본이 없음 |
| ASIS 에 없거나 숫자 타입이 아닌 컬럼 | `SKIP` | 컬럼명 변경 시 `COL_MAP` 등록 누락 여부 확인 |
| TOBE 에 NUMBER 컬럼이 아예 없음 | `SKIP` | `COLUMN_NAME = *NONE*` (`COUNT_CHECK=N` 일 때만) |
| `MIG_TYPE=PRE` 인데 조건값이 비어 있음 | `ERROR` | `DBM_MIG_MSTR` 의 `COL_CONDITION`/`PRE1`/`PRE2` 확인 |
| 조회 SQL 실패 | `ERROR` | `ERROR_MSG` 에 DB 오류 원문 |
| 양쪽 모두 대상 행 0건 | `일치` | SUM 이 양쪽 다 NULL → `ASIS_COL`/`TOBE_COL` 이 NULL |

---

## 9. 배치 / 자동화

종료 코드로 판단한다.

| 코드 | 의미 |
|---|---|
| `0` | 전부 일치 (SKIP 만 있는 경우 포함) |
| `2` | 불일치 또는 ERROR 존재 |
| `1` | 실행 실패 (env 오류, 제어 테이블 조회 실패, 대상 0건 등) |

```bash
# 매일 새벽 2시 검증, 불일치면 메일
0 2 * * * cd /home/oracle/DATA_MIG_VERIFY && bash 01.RUN_DATA_VERIFY.sh -y \
  || mailx -s "[MIG] PRE DATA VERIFY 불일치" dba@example.com < /dev/null
```

---

## 10. 생성되는 파일

```
/home/oracle/data_mig_verify/           <- BASE_PATH
├── log/
│   └── DATA_VERIFY_20260914_20260918_144713.log   화면과 같은 내용 (색 없음)
├── cmd/
│   ├── ASIS/
│   │   ├── NEW_ORDERS.sql              ASIS SUM 조회 SQL
│   │   └── NEW_CUST_NOTI.sql
│   ├── TOBE/
│   │   ├── NEW_ORDERS.sql              TOBE SUM 조회 SQL
│   │   └── NEW_CUST_NOTI.sql
│   └── RESULT/
│       └── RESULT_20260914_R7_0000.sql 결과 INSERT (400건 단위로 분할)
└── tmp/                                 수행 중 임시 파일 (종료 시 자동 삭제)
```

`cmd/` 아래 SQL 은 **매 수행마다 덮어쓰기**된다. 불일치 원인을 직접 확인할 때는
`cmd/ASIS`, `cmd/TOBE` 의 SQL 을 그대로 복사해 `SUM()` 대신 상세 조회로 바꿔 쓰면 된다.
