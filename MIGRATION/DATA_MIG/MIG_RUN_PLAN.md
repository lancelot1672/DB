# 마이그레이션 플랜

DBM_MIG_MSTR 테이블 기준으로 DB_LINK `INSERT INTO SELECT` 마이그레이션을 진행한다.
Oracle / Tibero 이기종 환경을 고려해 **일반 SQL 만** 사용한다 (프로시저 / PL/SQL 블록 사용 금지).

---

## 1. 구성

| 구분 | 파일 | 설명 |
|---|---|---|
| 제어 테이블 | `DDL_Script/DBM_MIG_MSTR.sql` | 이관 대상 테이블 목록 / 조건 |
| | `DDL_Script/DBM_MIG_COL_MAP.sql` | 컬럼 매핑 (TRANS_YN = 'Y' 테이블, 상세 `COL_MAP_PLAN.md`) |
| | `DDL_Script/DBM_XDN_LOG.sql` | 이관 실행 이력 (`DBADM.DBM_XDN_LOG` 로 사용) |
| 적재 쉘 | `01.LOAD_MIG_MSTR.sh <CSV>` | DBM_MIG_MSTR CSV 적재 |
| | `03.LOAD_COL_MAP.sh <CSV>` | DBM_MIG_COL_MAP CSV 적재 |
| 이관 쉘 | `02.RUN_MIG.sh` | 메뉴 방식 SQL 작성 / 이관 / 재수행 / 모니터링 |
| 설정 | `MIG.env` (`MIG.env.example` 복사) | 접속 정보, MSTR_ID, DB LINK 등 (gitignore 대상) |
| | `MIG_HINT.conf` | PARALLEL 차수 ([h] Hint 에서 저장) |
| 산출물 | `./cmd/PRE`, `./cmd/DDAY` | 이관 SQL (`.out`) |
| | `./log` | 02 진행 로그 / 상세 로그 |
| | `${BASE_PATH}/log`, `${BASE_PATH}/tmp` | 01 / 03 적재 로그, 임시 파일 |
| 샘플 | `DBM_MIG_MSTR_sample.csv`, `DBM_MIG_COL_MAP_sample.csv` | CSV 양식 |

### MIG.env

| 항목 | 설명 |
|---|---|
| DB_TYPE | `ORACLE` (sqlplus) / `TIBERO` (tbsql) |
| DB_USER / DB_PASS / DB_TNS | 접속 정보 (DB_TNS 비우면 로컬 기본) |
| MSTR_ID | 이관할 DBM_MIG_MSTR.MSTR_ID (여러 테이블이 공유하는 기준 ID) |
| SRC_DBLINK | 소스 DB LINK 명. `DBM_MIG_MSTR.SRC`(ASIS) 는 라벨일 뿐 SQL 에 쓰지 않음 |
| HEARTBEAT_SEC | 한 테이블 이관 중 진행 로그에 Running 줄을 남기는 간격 (기본 300초) |
| BASE_PATH | 01 / 03 로그, 임시 파일 경로 |

접속 구조 : 쉘은 **타겟 DB 에만 접속**한다. 제어 테이블(DBM_MIG_MSTR / DBM_MIG_COL_MAP / DBM_XDN_LOG)은 타겟 DB 에 있고, 소스는 `@SRC_DBLINK` 로 읽는다.

---

## 2. 사전 적재 (CSV)

공통 규칙 (01 / 03)
1. 쉼표(,) 구분, 첫 줄은 컬럼명(헤더). 헤더 순서대로 INSERT 컬럼 목록을 만든다 (컬럼 순서 자유).
2. 값에 쉼표가 있으면 `"..."` 로 감싼다. `""` 는 따옴표 문자. 엑셀 CSV 의 BOM / CRLF 는 자동 제거.
3. **쉘에서는 검증하지 않는다** (중복 / NOT NULL / 형식 / 조건 체크 없음). 모든 검증은 DB 제약조건에 맡긴다.
4. 빈 값은 NULL 로 넣는다.
5. 적재 전 미리보기 + `y/N` 확인, 오류 발생 시 **전체 ROLLBACK** 하고 실패한 CSV 줄을 표시한다.

### 01.LOAD_MIG_MSTR.sh (DBM_MIG_MSTR)
- INSERT 만 한다 (기존 데이터 삭제 / 중복 체크 없음).
- NUMBER 컬럼(`TAB_SIZE`, `LOB_SIZE`)은 따옴표 없이 숫자로, 나머지는 문자로 넣는다.
- 비어 있거나 헤더에 없으면 기본값 : `TRANS_YN=N`, `PARTITION_YN=N`, `MIG_YN=Y`, `MIG_METHOD=DB_LINK`, `SRC=ASIS`, `TGT=TOBE`

### 03.LOAD_COL_MAP.sh (DBM_MIG_COL_MAP)
- CSV 에 나온 **테이블 쌍(TGT_OWNER, TGT_TABLE_NAME, SRC_OWNER, SRC_TABLE_NAME)의 기존 매핑을 DELETE 후 INSERT** 한다 (한 트랜잭션). CSV 에 없는 테이블 쌍은 유지.
- 이름 컬럼(TGT_OWNER / TGT_TABLE_NAME / SRC_OWNER / SRC_TABLE_NAME / TGT_COL / SRC_COL / MAP_FLAG)은 대문자로 변환, `DEFAULT_VAL` / `REMARK` 는 그대로.

---

## 3. 이관 대상과 조건

1. `DBM_MIG_MSTR` 에서 `MSTR_ID = MIG.env 의 MSTR_ID` 이고 `MIG_YN = 'Y'` 인 행을 대상으로 한다.
2. 테이블명 / OWNER 변경은 `SRC_OWNER.SRC_TABLE_NAME` → `TGT_OWNER.TGT_TABLE_NAME` 으로 표현한다.
3. COND + DDAY 는 없으므로 마이그레이션은 **PRE / DDAY 2단계**로 한다.

| MIG_TYPE | MIG_FULL | PRE 단계 | DDAY 단계 |
|---|---|---|---|
| PRE | COND | `COL_CONDITION >= 'PRE1' AND COL_CONDITION < 'PRE2'` | `COL_CONDITION >= 'PRE3'` (나머지 데이터) |
| DDAY | FULL | 대상 아님 | 조건 없이 전체 이관 |
| 그 외 (INIT, PRE+FULL 등) | | 대상 아님 (제외 건수만 표시) | 대상 아님 |

- MIG_TYPE / MIG_FULL 은 값이 **정확히** `PRE` / `DDAY` / `COND` / `FULL` 일 때만 규칙이 적용된다 (대소문자 구분).
- PRE1 / PRE2 / PRE3 은 항상 따옴표로 감싸 비교한다.

### TRANS_YN
| TRANS_YN | 이관 SQL |
|---|---|
| N | `INSERT INTO TGT SELECT * FROM SRC@SRC_DBLINK` (소스 / 타겟 컬럼 구성과 순서가 같아야 함) |
| Y | 타겟 `ALL_TAB_COLUMNS` 컬럼을 `COLUMN_ID` 순서로 명시. 컬럼마다 매핑 없음 → 같은 이름, `RENAME` → `SRC_COL`, `ADD` → `DEFAULT_VAL` (NULL 이면 컬럼 제외) |

- 매핑은 `DBM_MIG_COL_MAP` 에 **바뀐 컬럼만** 등록한다 (상세 `COL_MAP_PLAN.md`).
- 매핑 키에 소스 테이블이 포함되어 **N:1 병합**(여러 소스 → 타겟 하나)은 소스별로 다른 매핑을 줄 수 있다.
- **1:N 분할**은 컬럼 분할만 지원하고, 행 분할(조건으로 나눠 담기)은 지원하지 않는다.
- 타겟 딕셔너리에서 컬럼을 못 찾으면 `SELECT *` 로 작성하고 `[WARN]` 표시.

---

## 4. 마이그레이션 단계 (02.RUN_MIG.sh 메뉴)

메뉴 형식은 `[키] 이름` 으로 통일한다. `r` / `R` 은 둘 다 Run 하위 메뉴이고, `s`(Status) 와 `S`(Stop) 는 대소문자를 구분한다.

메인 메뉴
```
============================================================
 DATA MIGRATION   MSTR_ID=20260914  DB_TYPE=ORACLE  SRC_DBLINK=ASIS_LINK
------------------------------------------------------------
 * RUNNING : RUN PRE  RUN_ID=3  45/120  PID=48213  since 2026-09-14 16:46:44   <- 실행 중 표시
============================================================
  [R] Run         (SQL generate / migration / retry)
  [l] Total Log   (tail -F, q + Enter to return)
  [s] Status      (DBADM.DBM_XDN_LOG)
  [S] Stop        (after the current table)
  [h] Hint        (PARALLEL n)
  [q] Quit        (background migration keeps running)
============================================================
```

[R] Run 하위 메뉴 (작업 하나를 끝내면 메인 메뉴로 돌아간다, `[b]` 는 작업 없이 돌아가기)
```
============================================================
 RUN MENU   MSTR_ID=20260914
============================================================
 [PRE]
  [1] Generate PRE  SQL      (cmd/PRE  : n file(s))
  [2] Run      PRE  migration   (background)
  [3] Retry    PRE  FAILED      (background)
 [DDAY]
  [4] Generate DDAY SQL      (cmd/DDAY : n file(s))
  [5] Run      DDAY migration   (background)
  [6] Retry    DDAY FAILED      (background)

  [b] Back
============================================================
```

[1단계 : PRE 이관 SQL 작성] — [R] → [1]
- MIG_TYPE : PRE + MIG_FULL : COND 테이블에 대해 `./cmd/PRE` 아래 SQL 작성

[2단계 : PRE 이관] — [R] → [2] / 재수행 [R] → [3]
- `./cmd/PRE` 아래 `.out` 전부를 기반으로 이관 수행

[3단계 : DDAY 이관 SQL 작성] — [R] → [4]
- PRE + COND 테이블 : `COL_CONDITION >= PRE3` 조건으로 나머지 데이터 SQL 작성
- DDAY + FULL 테이블 : 조건 없는 전체 이관 SQL 작성

[4단계 : DDAY 이관] — [R] → [5] / 재수행 [R] → [6]
- `./cmd/DDAY` 아래 `.out` 전부를 기반으로 이관 수행

---

## 5. SQL 작성 ([R] → [1] / [4])

1. `./cmd/{PRE|DDAY}/{TGT_OWNER}_{TGT_TABLE_NAME}__{SRC_OWNER}_{SRC_TABLE_NAME}.out` 에 `INSERT INTO SELECT`, `COMMIT` 을 기록한다.
2. 작성 전에 해당 단계 디렉토리의 **기존 `.out` 을 모두 삭제**한다 (삭제 / 작성 건수 미리보기 후 `y/N` 확인).
3. `.out` 상단에 헤더 주석을 남긴다. 이관 실행 시 로그 키와 건수 조회 조건으로 사용한다.
   ```
   -- MSTR_ID        : 20260914
   -- MIG_PHASE      : PRE
   -- MSTR_MIG_TYPE  : PRE / COND
   -- SRC_OWNER      : OLD
   -- SRC_TABLE_NAME : ORD
   -- TGT_OWNER      : NEW
   -- TGT_TABLE_NAME : ORDERS
   -- SRC_DBLINK     : ASIS_LINK
   -- CONDITION      : WHERE ORD_DT >= '20250101' AND ORD_DT < '20250701'
   -- TRANS_YN       : N
   -- GENERATED      : 2026-09-14 16:46:44
   INSERT INTO NEW.ORDERS
   SELECT * FROM OLD.ORD@ASIS_LINK WHERE ORD_DT >= '20250101' AND ORD_DT < '20250701';
   COMMIT;
   ```
4. `.out` 에는 **힌트를 넣지 않는다** (힌트는 실행 시 적용, 7장).
5. `.out` 을 직접 고치면 실행에 그대로 반영된다. WHERE 를 고칠 때는 건수 조회용 `-- CONDITION` 주석도 같이 고친다.
6. 같은 소스 → 타겟 쌍이 중복 등록되어 파일명이 겹치면 `[WARN]` 표시 후 덮어쓴다.
7. 이관이 실행 중인 단계의 디렉토리는 다시 작성할 수 없다.
8. 작성 로그 : `./log/GEN_{PHASE}_{MSTR_ID}_{시각}.log`

---

## 6. 이관 실행 ([R] → [2] / [5])

1. 메뉴에서 대상 `.out` 목록 / RUN_ID / 힌트를 미리보기하고 `y/N` 확인 후 **백그라운드(nohup)로 실행**한다. 메뉴를 종료하거나 세션이 끊겨도 계속 진행된다.
2. 백그라운드 이관은 **한 번에 하나만** 실행한다 (`./log/.run.lock`). 실행 중에는 [R] 의 이관 / 재수행([2] / [3] / [5] / [6])이 막히고, 실행 중인 단계의 SQL 작성도 막힌다.
3. 테이블은 **순차 실행**하고, 실패한 테이블은 FAIL 기록 후 다음 테이블을 계속 진행한다.
4. **INSERT 만** 한다. 타겟 데이터를 TRUNCATE / DELETE 하지 않는다 (같은 단계를 다시 실행하면 중복 적재됨).
5. 실패한 INSERT 는 ROLLBACK 되므로 재수행해도 중복되지 않는다.

### 테이블별 처리 순서
1. RUNNING / START_TIME 기록
2. 소스 건수 조회 (`SELECT COUNT(*) FROM SRC@SRC_DBLINK {조건}`) → ROW_CNT_SRC
3. `.out` 실행 (힌트 적용, 7장)
4. SUCCESS / FAIL, END_TIME, ERROR_MSG 기록
5. 타겟 건수 조회 (`SELECT COUNT(*) FROM TGT {조건}`) → ROW_CNT_TGT
6. 건수 일치 판단은 **적재 건수(Inserted) 와 SRC 건수**로 한다 (N:1 병합 테이블은 타겟 테이블 건수에 다른 소스 적재분이 포함됨)

---

## 7. 힌트

1. 이관 실행([R] → [2] / [3] / [5] / [6]) 시 `.out` 을 읽어 힌트를 넣어 실행한다.
   ```sql
   ALTER SESSION ENABLE PARALLEL DML;                -- n > 1 일 때
   INSERT /*+ APPEND PARALLEL(n) */ INTO ...
   SELECT /*+ PARALLEL(n) */ ...
   ```
2. 줄 첫머리가 `INSERT INTO` / `SELECT` 인 줄에만 넣는다. 이미 `/*+ ... */` 힌트가 있는 SELECT 줄(직접 수정한 `.out`)은 그대로 둔다.
3. PARALLEL 차수 n 은 **[h] Hint** 에서 변경한다. `MIG_HINT.conf` 에 저장되며 기본 4. `1` 이면 `APPEND` 만 넣고 병렬 / PARALLEL DML 은 쓰지 않는다.
4. 실제 실행 SQL(힌트 포함)은 `_detail.log` 에 남긴다. 실행 중인 이관은 시작할 때의 힌트를 유지하고, 변경은 다음 실행부터 적용된다.

---

## 8. FAIL 재수행 ([R] → [3] / [6])

1. 해당 단계(PRE / DDAY)의 **가장 최근 RUN_ID** 에서 `STATUS = 'FAIL'` 인 테이블만 재수행한다.
2. `.out` 파일은 로그의 소스 / 타겟 명으로 `{TGT_OWNER}_{TGT_TABLE_NAME}__{SRC_OWNER}_{SRC_TABLE_NAME}.out` 을 찾는다. 파일이 없으면 실행하지 않고 FAIL(`SQL file not found`)로 둔다.
3. 새 RUN_ID / PENDING 을 만들지 않고 **기존 FAIL 행을 RUNNING → SUCCESS / FAIL 로 갱신**한다 (이전 ERROR_MSG / 시간은 덮어씀).
4. 실행 방식(백그라운드, 순차, 힌트, 로그)은 이관 실행과 같다.

---

## 9. DBM_XDN_LOG 기록

마이그레이션 시작 전 ([R] → [2] / [5], 백그라운드 시작 시)
1. RUN_ID 는 1번부터 채번한다 (`MAX(RUN_ID) + 1`). 테이블마다의 값이 아닌 **실행 한 번(테이블 전체)의 값**이다.
2. MSTR_ID, SRC_OWNER, SRC_TABLE_NAME, TGT_OWNER, TGT_TABLE_NAME 을 기록한다.
3. MIG_TYPE 에는 **단계 값(PRE / DDAY)** 을 기록한다 (PRE 테이블의 나머지 이관은 DDAY 로 기록되어 1차 / 2차 구분 가능).
4. STATUS 에 `PENDING` 을 기록한다.

각 테이블 마이그레이션 시작 시
1. STATUS 에 `RUNNING` 기록
2. START_TIME 기록 (DATE, YYYY-MM-DD HH24:MI:SS)
3. ROW_CNT_SRC 에 **조건을 적용한 SRC 테이블 건수**를 조회하여 기록

마이그레이션 종료 후
1. STATUS 에 `SUCCESS` / `FAIL` 기록
2. END_TIME 기록 (DATE, YYYY-MM-DD HH24:MI:SS)
3. ROW_CNT_TGT 에 **조건을 적용한 TGT 테이블 건수**를 조회하여 기록
4. ERROR 발생 시 ERROR 는 ERROR_MSG 에 기록

기타
- 중지([S] Stop)로 실행하지 못한 테이블은 `PENDING` 으로 남는다.
- 쉘이 강제 종료되면 진행 중이던 테이블은 `RUNNING` 으로 남는다 (재수행 대상 아님, 확인 후 조치).
- 재수행은 같은 RUN_ID 의 FAIL 행을 갱신한다 (8장).

---

## 10. 로그 / 모니터링

### 로그 파일 (`./log`)
| 파일 | 내용 |
|---|---|
| `{RUN\|RETRY}_{PHASE}_{MSTR_ID}_R{RUN_ID}_{시각}.log` | 진행 로그 (사람이 보는 로그, `tail -f` 용) |
| `..._detail.log` | 실행한 SQL(힌트 포함) + DB 클라이언트 원본 출력 (오류 추적용) |
| `current.log` | 최신 실행의 진행 로그 링크 (`tail -F log/current.log`) |
| `GEN_{PHASE}_{MSTR_ID}_{시각}.log` | SQL 작성 로그 |

### 진행 로그 형식 (블록형)
- 테이블명, 조건, 조건에 대한 건수, 시작 시간, 종료 시간, 소요 시간을 테이블마다 한 블록으로 남긴다.
- 한 테이블이 오래 걸리면 `HEARTBEAT_SEC` 마다 `Running` 줄을 남긴다.
- 끝에 요약 블록(전체 / 성공 / 실패 / 미실행, 실패 목록, 재수행 메뉴 안내)을 남긴다.
- 색상 코드는 넣지 않는다 (`less` / `vi` 로 볼 수 있게).

```
============================================================
 [RUN] PRE  MSTR_ID=20260914  RUN_ID=3  TABLES=120  PID=48213
       START=2026-09-14 17:56:19  DB=TIBERO  DBLINK=ASIS_LINK  HEARTBEAT=300s
       HINT=INSERT /*+ APPEND PARALLEL(4) */ , SELECT /*+ PARALLEL(4) */ , PARALLEL DML
       LOG=./log/RUN_PRE_20260914_R3_20260914_175619.log
       DETAIL=./log/RUN_PRE_20260914_R3_20260914_175619_detail.log
============================================================

------------------------------------------------------------
[  2/120]  OLD.ORD -> NEW.ORDERS
------------------------------------------------------------
  File      : NEW_ORDERS__OLD_ORD.out
  Condition : WHERE ORD_DT >= '20250101' AND ORD_DT < '20250701'
  Start     : 2026-09-14 17:56:27
  SRC count : 1,234,567
  Running   : 00:05:00 elapsed  (18:01:27)
  Inserted  : 1,234,567 (= SRC)
  TGT count : 1,234,567
  End       : 2026-09-14 18:03:10  (00:06:43)
  Result    : SUCCESS
  Progress  : 2/120 (1%)  SUCCESS 1  FAIL 1  total elapsed 00:06:51

============================================================
 [END] RUN PRE  MSTR_ID=20260914  RUN_ID=3  RESULT=DONE
       TOTAL=120  SUCCESS=119  FAIL=1  NOT_RUN=0
       START=2026-09-14 17:56:19  END=2026-09-14 21:09:04  ELAPSED=03:12:45
 FAILED :
   OLD.BAD -> NEW.BAD  ORA-00942: table or view does not exist
 RETRY  : 02.RUN_MIG.sh -> [R] Run -> [3] Retry PRE FAILED
============================================================
```

### 모니터링 메뉴
- **[l] Total Log** : 실행 중(없으면 최근) 진행 로그를 `tail -F` 로 보여준다. **`q` + Enter 로만** 메뉴로 돌아오며(Ctrl+C 무시) tail 프로세스를 종료한다.
- **[s] Status** : 실행 중(없으면 최근) RUN_ID 의 PENDING / RUNNING / SUCCESS / FAIL 건수, 진행률, 실행 중 테이블과 경과 시간, FAIL 상위 10건을 DBM_XDN_LOG 에서 조회한다.
- **[S] Stop** : 현재 테이블까지만 끝내고 중지한다 (stop 파일 방식). 남은 테이블은 PENDING 으로 남는다.
- 메뉴 상단에 실행 중인 이관(단계, RUN_ID, 진행 n/N, PID, 현재 테이블)을 항상 표시한다.

---

## 11. 제약 / 주의사항

1. 프로시저 / PL/SQL 블록을 사용하지 않는다. Oracle(sqlplus) / Tibero(tbsql) 공통 SQL 만 사용한다.
2. 쉘에서는 데이터를 검증하지 않는다. 잘못된 값은 DB 오류로 FAIL / ROLLBACK 된다.
3. 이관 중인 백그라운드 프로세스를 `kill` 하지 않는다. 진행 중인 sqlplus / tbsql INSERT 는 계속 돌고 로그는 RUNNING 으로 남는다. 중지는 **[S] Stop** 으로 한다.
4. INSERT 만 하므로 같은 단계를 다시 실행하면 중복 적재된다. 실패 건은 재수행 메뉴를 쓴다.
5. N:1 병합 시 소스끼리 PK 값이 겹치면 `ORA-00001` 로 FAIL 된다 (데이터 사전 확인 필요).
6. `APPEND` (direct-path) 적재 중에는 타겟 테이블이 잠긴다. 타겟에 트리거 / 활성 FK 가 있으면 일반 INSERT 로 동작한다.
7. SELECT 의 `PARALLEL` 힌트는 DB LINK 원격 테이블에서 제한될 수 있으므로 실제 병렬 여부를 확인한다.
8. 서버에 `nohup` 이 필요하며, `tail -F` 는 GNU tail 기준이다.
9. Tibero 사용 시 `tbsql -s`, `WHENEVER SQLERROR EXIT FAILURE ROLLBACK`, 힌트 / `ENABLE PARALLEL DML` 문법, 건수 메시지(`N rows inserted.`) 형식을 버전별로 확인한다.
10. 한글 값이 있는 CSV 는 클라이언트 문자셋(`NLS_LANG` / `TB_NLS_LANG`)을 CSV 인코딩과 맞춘다.
