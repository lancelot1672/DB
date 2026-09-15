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
| | `./log` | 02 통합 로그(`MIG_TOTAL.log`) / 실행별 진행 로그 / 상세 로그 |
| | `${BASE_PATH}/log`, `${BASE_PATH}/tmp` | 01 / 03 적재 로그, 임시 파일 |
| | `${MIG_HOME}/run` | 백그라운드 worker 실행용 임시 sh (worker 종료 시 삭제) |
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
| MIG_HOME | worker 실행용 임시 sh 를 만들 기준 경로 (`${MIG_HOME}/run`). 비우면 스크립트 디렉토리 |

사전 점검 : 02 메뉴를 띄울 때 `DBADM.DBM_MIG_MSTR` / `DBADM.DBM_MIG_COL_MAP` / `DBADM.DBM_XDN_LOG` / `ALL_TAB_COLUMNS` 를 하나씩 조회해, 없거나 권한이 없는 객체를 메뉴 상단에 `! CHECK` 로 표시한다 (알림만, 차단 없음, 테이블 생성 후 메뉴를 다시 띄우면 갱신).

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
- CSV 에 나온 **테이블 쌍(SRC_OWNER, SRC_TABLE_NAME, TGT_OWNER, TGT_TABLE_NAME)의 기존 매핑을 DELETE 후 INSERT** 한다 (한 트랜잭션). CSV 에 없는 테이블 쌍은 유지.
- 이름 컬럼(SRC_OWNER / SRC_TABLE_NAME / TGT_OWNER / TGT_TABLE_NAME / TGT_COL / SRC_COL / MAP_FLAG)은 대문자로 변환, `DEFAULT_VAL` / `REMARK` 는 그대로.

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

- 메뉴 선택은 **Enter 없이 키 하나**로 이동한다. (Enter 만 누르면 무시, 방향키 / ESC 는 잘못된 선택으로 표시)
- 메뉴를 보여줄 때마다 **화면을 Clear** 한다. 잘못된 선택 메시지는 다시 그린 메뉴 아래에 표시한다.
- 작업(SQL 작성, 이관 시작, 재수행 시작, Status, Stop, Hint)이 끝나면 결과를 남겨두고 `Press any key to return to the menu ...` 에서 **아무 키**를 누르면 Clear 후 메뉴로 돌아간다.
- 실수 방지를 위해 다음 입력은 **Enter 가 필요**하다 : `y/N` 확인, `[h]` PARALLEL 차수 입력, `[l] Total Log` 의 `q` + Enter.

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
  [S] Stop        (no new table ; running tables finish)
  [h] Hint        (WORKER m x PARALLEL n)
  [U] Unlock      (stale lock / interrupted RUNNING rows, only when no worker)
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
   -- TAB_SIZE       : 20992
   -- GENERATED      : 2026-09-14 16:46:44
   INSERT INTO NEW.ORDERS
   SELECT * FROM OLD.ORD@ASIS_LINK WHERE ORD_DT >= '20250101' AND ORD_DT < '20250701';
   COMMIT;
   ```
4. `.out` 에는 **힌트를 넣지 않는다** (힌트는 실행 시 적용, 7장).
5. `.out` 은 이관 / 재수행 직전에 **다시 생성되어 덮어써진다** (6장). 조건 / 매핑 수정은 `DBM_MIG_MSTR` / `DBM_MIG_COL_MAP` 에서 하고, `.out` 을 직접 고친 내용은 유지되지 않는다(내용이 바뀌면 이전 파일은 `.bak`).
6. 같은 소스 → 타겟 쌍이 중복 등록되어 파일명이 겹치면 `[WARN]` 표시 후 덮어쓴다.
7. 이관이 실행 중인 단계의 디렉토리는 다시 작성할 수 없다.
   - 조회는 두 번으로 나눈다 : ① `DBM_MIG_MSTR` 대상 목록 ② `TRANS_YN = 'Y'` 대상이 있을 때만 `ALL_TAB_COLUMNS` + `DBM_MIG_COL_MAP` 컬럼 목록.
     `TRANS_YN = 'N'` 만 있으면 `DBM_MIG_COL_MAP` 이 없어도 작성된다. 실패 메시지에는 실제로 실패한 조회의 객체명을 표시한다.
8. 작성 로그 : `./log/GEN_{PHASE}_{MSTR_ID}_{시각}.log`. 확인(y) 후 작성한 결과는 통합 로그(`MIG_TOTAL.log`)에 `[GEN]` 블록(시작 / 파일별 한 줄 / `[END]`)으로도 남긴다. 미리보기 후 취소는 통합 로그에 남기지 않는다.

---

## 6. 이관 실행 ([R] → [2] / [5])

1. 메뉴에서 대상 `.out` 목록 / RUN_ID / 힌트를 미리보기하고 `y/N` 확인 후 **백그라운드(nohup)로 실행**한다. 메뉴를 종료하거나 세션이 끊겨도 계속 진행된다.
   - 시작 후 최대 10초 동안 worker 프로세스를 확인한다. `ps` 인자가 잘려 보이는 OS 에서도 락 PID 가 살아 있으면 실행 중으로 본다.
   - 확인되지 않으면 `[FAIL] Background worker not confirmed` 와 함께 프로세스 생존 여부, `ps` 인자, 시작 출력(`..._worker.err`), 로그 끝부분을 보여준다.
   - 락은 해당 PID 가 **죽어 있을 때만** 지운다 (살아 있으면 유지).
   - worker 는 **임시 sh 를 만들어 실행**한다 : 메뉴가 `${MIG_HOME}/run/{RUN|RETRY}_{PHASE}_{MSTR_ID}_R{RUN_ID}_{시각}.sh` 를 만들고
     `nohup bash <임시 sh>` 로 실행하며, 임시 sh 는 `exec bash 02.RUN_MIG.sh --worker ...` 로 worker 를 띄운다.
     인터프리터(bash)를 명시해 실행하므로 `02.RUN_MIG.sh` / 임시 sh 에 실행권한(+x)이 없어도 된다.
   - 임시 sh 는 worker 가 끝나면(정상 / 오류 / 중지) 삭제한다. 다시 실행하면 같은 데이터가 중복 적재되므로 수동으로 실행하지 않는다.
2. 백그라운드 이관은 **한 번에 하나만** 실행한다. 실행 중에는 [R] 의 이관 / 재수행([2] / [3] / [5] / [6])이 막히고, 실행 중인 단계의 SQL 작성도 막힌다.
   - 실행 여부는 **실제 worker 프로세스(`ps`)** 로 판단하고 `./log/.run.lock` 은 보조로 쓴다. worker 는 시작 시 자기 PID 를 락에 기록한다.
   - 상태 확인은 락을 **지우지 않는다**. worker 가 살아 있는데 락이 없거나 PID 가 다르면 프로세스 기준으로 락을 다시 쓰고 메뉴에 `warning` 을 표시한다.
   - 락은 있는데 worker 프로세스가 없으면 `STALE` 로 표시하고 실행을 막는다.
   - worker 가 없어도 `DBM_XDN_LOG` 에 해당 MSTR_ID 의 `RUNNING` 행이 있으면(중단된 실행) 이관 / 재수행을 막는다.
3. 테이블은 **worker 병렬도(WORKER) 만큼 동시에** 실행한다. 실패한 테이블은 FAIL 기록 후 나머지를 계속 진행한다.
   - worker(coordinator) 1개가 테이블마다 하위 쉘(슬롯 W1 ~ Wn)을 띄워 동시에 최대 WORKER 개까지 실행한다. RUN_ID / 락은 실행당 하나.
   - 실행 순서 : `.out` 헤더의 `TAB_SIZE`(= DBM_MIG_MSTR.TAB_SIZE + LOB_SIZE) **작은 테이블부터**. (SQL 작성 시 헤더에 기록, 헤더가 없는 예전 `.out` 은 0)
   - 1초마다 `MIG_HINT.conf` 를 다시 읽어 **실행 중에도** 슬롯 수를 늘리거나 줄인다. 줄이면 돌고 있는 테이블이 끝나는 대로 줄어든다.
   - DB 부하는 최대 `WORKER x PARALLEL` (테이블마다 `PARALLEL(n)` 세션) 이다.
4. **INSERT 만** 한다. 타겟 데이터를 TRUNCATE / DELETE 하지 않는다 (같은 단계를 다시 실행하면 중복 적재됨).
5. 실패한 INSERT 는 ROLLBACK 되므로 재수행해도 중복되지 않는다.

### 이관 직전 SQL 재생성 (이관 / 재수행 공통)
- 대상 목록은 `cmd/{PHASE}` 의 `.out` 파일 목록이다 ([1] / [4] 이후 MSTR 에 추가된 테이블은 SQL 을 다시 작성해야 포함).
- 테이블마다 실행 직전에 `DBM_MIG_MSTR`(TRANS_YN = 'Y' 면 `DBM_MIG_COL_MAP` 포함)를 다시 조회해 SQL 을 만들고 `cmd/{PHASE}/*.out` 을 **덮어쓴 뒤 그 파일을 실행**한다.
  - 내용이 바뀌었으면 이전 파일은 `*.out.bak` 로 남긴다 (`-- GENERATED` 시각만 다른 경우는 변경 아님).
  - 파일이 없어도(재수행) 대상이면 새로 만든다.
- 더 이상 대상이 아니면(행 삭제 / `MIG_YN = 'N'` / MIG_TYPE · MIG_FULL 변경) **SKIP** : 실행하지 않고 `DBM_XDN_LOG` 행은 그대로 둔다(이관은 PENDING, 재수행은 FAIL 유지). 로그에 `[Wn] SKIP` 이벤트 / `Result : SKIP` / 끝 요약 `SKIP=n` 과 목록을 남긴다.
- 재생성 조회가 실패하면(DB 오류) 실행하지 않고 FAIL(`SQL regenerate failed : ...`).
- 블록의 `SQL file :` 줄에 재생성 결과(no change / changed -> .bak / file was missing)를 표시한다.

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
2. 줄 첫머리가 `INSERT INTO` / `SELECT` 인 줄에만 넣는다. 이미 `/*+ ... */` 힌트가 있는 SELECT 줄은 그대로 둔다. (단, `.out` 은 이관 직전에 다시 생성되므로 파일에 직접 넣은 힌트는 유지되지 않는다)
3. **[h] Hint** 에서 두 값을 변경한다. `MIG_HINT.conf` 에 저장된다.
   - `WORKER_DEGREE` : 동시에 이관할 테이블 수 (1 ~ 99, 기본 1)
   - `PARALLEL_DEGREE` : 테이블마다의 PARALLEL 차수 (기본 4, `1` 이면 `APPEND` 만 넣고 병렬 / PARALLEL DML 은 쓰지 않음)
4. 실제 실행 SQL(힌트 포함)은 `_detail.log` 에 남긴다.
5. **실행 중 변경도 바로 적용**한다 : WORKER 는 1초 안에 슬롯 수에 반영되고, PARALLEL 은 **다음에 시작하는 테이블부터** 적용된다(이미 돌고 있는 테이블은 시작할 때의 값 유지). 설정 파일은 임시 파일로 쓴 뒤 교체한다.

---

## 8. FAIL 재수행 ([R] → [3] / [6])

1. 해당 단계(PRE / DDAY)의 **가장 최근 RUN_ID** 에서 `STATUS = 'FAIL'` 인 테이블만 재수행한다.
2. `.out` 파일은 로그의 소스 / 타겟 명으로 `{TGT_OWNER}_{TGT_TABLE_NAME}__{SRC_OWNER}_{SRC_TABLE_NAME}.out` 을 찾는다. 실행 직전에 SQL 을 다시 생성하므로 파일이 없어도 아직 대상이면 새로 만들어 실행하고, 대상이 아니면 SKIP 한다 (6장 "이관 직전 SQL 재생성").
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
5. ELAPSED_TIME 에 `START_TIME ~ END_TIME` 소요 시간을 `'HH24:MI:SS'` (VARCHAR2(20), 24시간 초과 시 `'27:15:02'`) 로 기록
   - END_TIME 과 같은 UPDATE 에서 `SYSDATE - START_TIME` 으로 계산 (Oracle / Tibero 공통 함수)
   - 재수행 시작(RUNNING) 때 NULL 로 초기화 후 다시 계산, SQL 파일이 없어 실행하지 않은 FAIL 은 `'00:00:00'`, `[U] Unlock` 으로 FAIL 처리한 행도 계산
   - 기존 테이블 : `ALTER TABLE DBADM.DBM_XDN_LOG ADD (ELAPSED_TIME VARCHAR2(20) NULL);`

기타
- 중지([S] Stop)로 실행하지 못한 테이블은 `PENDING` 으로 남는다.
- 쉘이 강제 종료되면 진행 중이던 테이블은 `RUNNING` 으로 남는다. DB 세션이 끝난 것을 확인한 뒤 **[U] Unlock** 으로 `FAIL`(`ERROR_MSG = INTERRUPTED ...`)로 바꾸면 재수행 대상이 된다.
- 재수행은 같은 RUN_ID 의 FAIL 행을 갱신한다 (8장).

---

## 10. 로그 / 모니터링

### 로그 파일 (`./log`)
| 파일 | 내용 |
|---|---|
| `MIG_TOTAL.log` | **통합 로그**. 모든 단계(GEN / RUN / RETRY)의 시작, 테이블 블록, 진행률 / Running, 완료를 한 파일에 계속 append (`[l] Total Log`) |
| `{RUN\|RETRY}_{PHASE}_{MSTR_ID}_R{RUN_ID}_{시각}.log` | 실행 한 번의 진행 로그 (통합 로그와 같은 내용을 실행 단위로 분리) |
| `..._detail.log` | 실행한 SQL(힌트 포함) + DB 클라이언트 원본 출력 (오류 추적용) |
| `..._worker.err` | worker 시작 출력 / 쉘 오류 (시작 실패 원인 확인용, 끝날 때 비어 있으면 삭제) |
| `current.log` | 최신 실행의 진행 로그 링크 (`tail -F log/current.log`) |
| `GEN_{PHASE}_{MSTR_ID}_{시각}.log` | SQL 작성 로그 |

### 통합 로그에 남는 것
| 단계 | 시작 | 진행 | 완료 |
|---|---|---|---|
| GEN (SQL 작성) | `[GEN]` 헤더 (대상 / 제외 / 삭제 건수) | 파일별 한 줄, `[WARN]` | `[END] GEN ... RESULT=DONE` |
| RUN (이관) | `[RUN]` 헤더 (RUN_ID / 힌트 / 로그 경로) | 테이블 블록, `Running`, `Progress` | `[END] RUN ... RESULT=DONE / STOPPED / ERROR`, `[STOP]`, `[ABORT]` |
| RETRY (재수행) | `[RETRY]` 헤더 | 테이블 블록, `Running`, `Progress` | `[END] RETRY ... RESULT=DONE / ERROR` |

- 메뉴 조작(미리보기, 취소, `[S]` Stop 요청, `[h]` 힌트 변경)은 통합 로그에 남기지 않는다. Stop 이 실제로 적용되면 `[STOP]` 줄이 남는다.
- 시작 직후 오류(대상 파일 없음, PENDING 등록 실패, FAIL 조회 실패)도 `[END] ... RESULT=ERROR` 로 완료 블록을 남긴다.
- GEN 블록은 한 번에 append 하므로 실행 중인 이관의 테이블 블록 사이에 끼어들 수는 있어도 GEN 블록 자체가 쪼개지지는 않는다.
- 통합 로그는 자동으로 지우거나 나누지 않는다 (필요 시 수동 정리).

### 진행 로그 형식 (블록형)
- 테이블명, 조건, 조건에 대한 건수, 시작 시간, 종료 시간, 소요 시간을 테이블마다 한 블록으로 남긴다.
- 여러 테이블이 동시에 돌기 때문에 **이벤트 한 줄은 즉시, 테이블 블록은 끝날 때 한 번에** 기록한다 (블록끼리 섞이지 않음).
  ```
  14:10:02 [W1] START    [  1/120] OLD.ORD -> NEW.ORDERS  (PARALLEL 8)
  14:10:02 [W2] START    [  2/120] OLD.CUST -> NEW.CUSTOMER  (PARALLEL 8)
  14:15:02 [W1] RUNNING  [  1/120] OLD.ORD -> NEW.ORDERS  00:05:00 elapsed      <- HEARTBEAT_SEC 마다
  14:13:04 [W2] SUCCESS  [  2/120] OLD.CUST -> NEW.CUSTOMER  00:03:02
  (테이블 블록 : 조건 / Parallel / 건수 / 시작 / 종료 / 결과 / Progress)
  14:20:10 [W-] STOP     stop requested : 70 table(s) not started, 3 running table(s) finish
  ```
- 끝에 요약 블록(전체 / 성공 / 실패 / 미실행, 실패 목록, 재수행 메뉴 안내)을 남긴다.
- 로그 **파일**에는 색상 코드를 넣지 않는다 (`less` / `vi` / `grep` 에서 깨지지 않게). 색은 **화면에 보여줄 때만** 입힌다.

### 색상 (화면 표시)
| 색 | 대상 |
|---|---|
| 초록 | `* RUNNING`, `Running :`, Status 의 RUNNING 건수 / 목록, `worker : RUNNING` |
| 빨강 | `[FAIL]`, `Result : FAIL`, `RESULT=ERROR`, `[ABORT]`, `FAILED :`, `ORA- / TBR- / SP2-` 오류, Status 의 FAIL 건수 / 목록, 줄 안의 `FAIL=n`(n > 0) |
| 노랑 | `* STALE`, `warning :`, `[WARN]`, `[STOP]`, `! CHECK`, `RESULT=STOPPED`, Stop 요청, `<> SRC` 건수 불일치, `[UNLOCK]` |
| 파랑 | `[OK]`, `Result : SUCCESS`, `RESULT=DONE`, Status 의 SUCCESS 건수 |
| 굵게 | `[GEN]` / `[RUN]` / `[RETRY]` / `[END]` / `[STATUS]` 헤더 |
| 주황 | 메뉴 화면의 명령 키 `[R]` `[l]` `[s]` `[S]` `[h]` `[U]` `[q]` `[1]`~`[6]` `[b]` (메뉴 화면에만, 줄 색은 키 뒤로 유지). 256색 터미널 기준 |

- 적용 : 메뉴 화면, `[s] Status`, `[l] Total Log`, 메뉴 메시지, SQL 작성 화면 출력
- 메뉴 밖에서 색으로 보기 : `bash 02.RUN_MIG.sh --tail [로그파일]` (기본 `log/MIG_TOTAL.log`, Ctrl+C 종료) 또는 `tail -f <로그파일> | bash 02.RUN_MIG.sh --color`
- `MIG.env` 의 `MIG_COLOR` : 비우면 터미널일 때 자동, `Y` 강제(`| less -R` 등), `N` 끔. `NO_COLOR` 환경변수가 있으면 끔

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
- **[l] Total Log** : 통합 로그(`MIG_TOTAL.log`)를 `tail -F` 로 보여준다. 실행 중이면 해당 실행의 개별 로그 경로도 함께 표시한다. **`q` + Enter 로만** 메뉴로 돌아오며(Ctrl+C 무시) tail 프로세스를 종료한다.
- **[s] Status** : 실행 중(없으면 최근) RUN_ID 의 PENDING / RUNNING / SUCCESS / FAIL 건수, 진행률, 실행 중 테이블과 경과 시간, FAIL 상위 10건을 DBM_XDN_LOG 에서 조회한다.
- **[S] Stop** : 새 테이블을 더 시작하지 않고, 돌고 있는 테이블은 끝까지 진행한다 (stop 파일 방식). 시작하지 않은 테이블은 PENDING 으로 남는다.
- 메뉴 상단에 실행 상태를 항상 표시한다.
  - `* RUNNING` : 대시보드 (메뉴를 다시 그릴 때 갱신)
    ```
     * RUNNING : RUN PRE  RUN_ID=3  done 45/120 (37%)  PID=48213  since 2026-09-15 13:10:02
       WORKER 4 (busy 3) x PARALLEL 8 = DB load max 32    SUCCESS=43  FAIL=2  WAIT=72
       [W1] [ 46/120] OLD.ORD -> NEW.ORDERS                        P8   00:25:10
       [W2] [ 47/120] OLD.CUST -> NEW.CUSTOMER                     P8   00:03:02
       [W3] [ 48/120] OLD.NOTI -> NEW.NOTI                         P4   00:00:41
       [W4] (idle)
    ```
    (락 복구 / worker 여러 개면 `warning` 줄, 슬롯 줄의 `P` 는 그 테이블이 시작할 때의 PARALLEL)
  - `* STALE`   : 락은 있으나 worker 프로세스 없음 → `[s] Status` / DB 세션 확인 후 `[U] Unlock`
  - `* IDLE`    : 실행 중인 이관 없음 (현재 WORKER x PARALLEL 설정 표시)
- **[U] Unlock** : worker 프로세스가 없을 때만 동작한다.
  - 이전 worker 의 DB 클라이언트(sqlplus / tbsql)가 아직 살아 있으면 거부한다 (INSERT 가 COMMIT 될 수 있음).
  - 락 정보와 `RUNNING` 행 목록을 보여주고 `y` + Enter 확인 후 락을 지우고 `RUNNING` 행을 `FAIL` 로 바꾼다.
  - 처리 결과는 통합 로그에 `[UNLOCK]` 블록으로 남긴다.
  - 중단된 테이블이 이미 COMMIT 되었을 수 있으므로 재수행 전 타겟 건수를 확인한다.

---

## 11. 제약 / 주의사항

1. 프로시저 / PL/SQL 블록을 사용하지 않는다. Oracle(sqlplus) / Tibero(tbsql) 공통 SQL 만 사용한다.
2. 쉘에서는 데이터를 검증하지 않는다. 잘못된 값은 DB 오류로 FAIL / ROLLBACK 된다.
3. 이관 중인 백그라운드 프로세스를 `kill` 하지 않는다. 진행 중인 sqlplus / tbsql INSERT 는 계속 돌고 로그는 RUNNING 으로 남는다. 중지는 **[S] Stop** 으로 한다. (이미 kill 했다면 DB 세션 종료 확인 후 **[U] Unlock**)
   - 실행 상태 판단에 `ps -eo pid=,ppid=,args=` 를 사용한다. 지원하지 않는 OS 에서는 락 PID(`kill -0`) 기준으로만 판단한다.
4. INSERT 만 하므로 같은 단계를 다시 실행하면 중복 적재된다. 실패 건은 재수행 메뉴를 쓴다.
5. N:1 병합 시 소스끼리 PK 값이 겹치면 `ORA-00001` 로 FAIL 된다 (데이터 사전 확인 필요).
6. `APPEND` (direct-path) 적재 중에는 타겟 테이블이 잠긴다. 타겟에 트리거 / 활성 FK 가 있으면 일반 INSERT 로 동작한다.
7. SELECT 의 `PARALLEL` 힌트는 DB LINK 원격 테이블에서 제한될 수 있으므로 실제 병렬 여부를 확인한다.
8. 서버에 `nohup` 이 필요하며, `tail -F` 는 GNU tail 기준이다. 스크립트는 `bash 02.RUN_MIG.sh` 로 실행해도 되고, worker 도 bash 로 명시 실행하므로 실행권한(+x)은 필요 없다. (git 에는 `.sh` 가 `100644` 로 저장되어 있음)
9. Tibero 사용 시 `tbsql -s`, `WHENEVER SQLERROR EXIT FAILURE ROLLBACK`, 힌트 / `ENABLE PARALLEL DML` 문법, 건수 메시지(`N rows inserted.`) 형식을 버전별로 확인한다.
10. 한글 값이 있는 CSV 는 클라이언트 문자셋(`NLS_LANG` / `TB_NLS_LANG`)을 CSV 인코딩과 맞춘다.
