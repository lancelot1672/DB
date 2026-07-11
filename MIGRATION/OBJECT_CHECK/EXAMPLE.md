# OBJECT_CHECK 실행 예시

ASIS ↔ TOBE 오브젝트 검증(`object_check.sh`) 실행 흐름 예시.
실제 값(DB LINK 명, OWNER, 건수)은 환경에 따라 달라진다.

## 0. 준비

```bash
cd MIGRATION/OBJECT_CHECK
cp .env.example .env
vi .env          # DB_USER / DB_PASS / BASE_PATH 입력
```

`.env` 예:

```
DB_USER=dbadm
DB_PASS=********
BASE_PATH=/home/oracle/object_check
```

> `.env` 는 gitignore 대상(`*.env`). `log/`·`tmp/` 는 `BASE_PATH` 아래 자동 생성.

## 1. 실행

```bash
./object_check.sh
```

```
============================================================
[16:20:01] OBJECT_CHECK — ASIS <-> TOBE object verification
  Log : /home/oracle/object_check/log/OBJECT_CHECK_20260710_162001.log
============================================================
```

> **입력 규칙**
> - 각 단계의 `[Y/N]` 는 **명시적으로 `Y` 또는 `N`** 을 눌러야 한다. 빈 Enter·기타 키는
>   `Y 또는 N 을 입력하세요.` 로 재질문 — 실수로 다음 단계로 넘어가지 않는다.
> - 어느 단계든 **세부 과정에 `FAIL` 이 하나라도 있으면 파이프라인이 즉시 중단**되고
>   요약을 출력한다(그 다음 단계는 실행되지 않음).

## 1-0. STEP 0 — MIG_TAB_LIST OWNER별 TABLE_COUNT 확인

검증 대상 목록(`DBADM.MIG_TAB_LIST`)의 OWNER별 건수를 먼저 보여주고 진행 여부를 묻는다.

```
============================================================
[16:20:01] STEP 0 : DBADM.MIG_TAB_LIST OWNER별 TABLE_COUNT 확인
============================================================
--- OWNER별 TABLE_COUNT (ASIS_OWNER / TOBE_OWNER) ---
ASIS_OWNER           TOBE_OWNER            TABLE_COUNT
-------------------- -------------------- -----------
DBOWN                DBOWN                       132
PFMOWN               PFMOWN                      26

--- TOTAL ---
TOTAL_TABLES
------------
         158

STEP 0 : 위 MIG_TAB_LIST 대상으로 검증을 진행하시겠습니까? [Y/N]: y
```

- `N` 을 입력하면 검증을 시작하지 않고 종료(요약에 `STEP 0 : SKIP`).
- 조회 실패(테이블 미존재 등)면 `STEP 0 : FAIL` 로 중단.

## 2. STEP 1 — ASIS 딕셔너리 복제 (DB LINK 선택)

`DBA_DB_LINKS` 를 조회해 화살표(↑/↓)로 DB LINK 를 고르고 Enter.

```
============================================================
[16:20:01] STEP 1 : ASIS dictionary copy  -> DBADM.DBA_ASIS_*
============================================================
[16:20:01] Query DB links from DBA_DB_LINKS

Select ASIS DB LINK (from DBA_DB_LINKS):
  (Up/Down = move, Enter = select, q = cancel)
  > ASIS_OGBEKRDB          ← 반전 표시(현재 선택)
    DBLINK_HR
    DBLINK_SALES
```

Enter 후:

```
[OK]   Selected DB LINK : ASIS_DB
  Source : /home/oracle/object_check/sql/1.ASIS_COPY_DICTIONARY.sql
  DB LINK: ASIS_DB
  ---- SQL ----------------------------------------------------
  | --1. ASIS_COPY_DICTIONARY
  | DROP TABLE DBADM.DBA_ASIS_CONSTRAINTS PURGE;
  | CREATE TABLE DBADM.DBA_ASIS_CONSTRAINTS AS SELECT OWNER
  | ,CONSTRAINT_NAME
  | ,CONSTRAINT_TYPE
  | ,TABLE_NAME FROM DBA_CONSTRAINTS@ASIS_DB      ← 선택한 DB LINK 로 치환됨
  | WHERE CONSTRAINT_TYPE IN ('P','C','U','R')
  | AND TABLE_NAME NOT LIKE ('BIN%');
  | ...
  -------------------------------------------------------------
STEP 1 : 위 SQL을 실행하시겠습니까? [Y/N]: y
```

`y` 입력 시 실행:

```
[16:20:14] STEP 1 executing...
Table dropped.
Table created.
...
[OK]   STEP 1 done
  ------------------------------------------------------------
   완료 현황 (ASIS dict)
  ------------------------------------------------------------
  [1/7] DBA_ASIS_CONSTRAINTS       ... OK    rows=763
  [2/7] DBA_ASIS_TABLES            ... OK    rows=158
  [3/7] DBA_ASIS_TAB_COLUMNS       ... OK    rows=3120
  [4/7] DBA_ASIS_INDEXES           ... OK    rows=274
  [5/7] DBA_ASIS_TAB_PARTITIONS    ... OK    rows=0
  [6/7] DBA_ASIS_IND_PARTITIONS    ... OK    rows=0
  [7/7] DBA_ASIS_OTHER_OBJECTS     ... OK    rows=52
  => 7/7 complete
  ------------------------------------------------------------
```

- **완료 현황** = STEP 실행 직후 sql/1 의 세부 과정(7개 테이블 생성)을 각 테이블 건수로 검증.
- 생성 실패/미존재 테이블은 `... FAIL <ORA-..>` 로 표기되어 어느 세부 과정이 빠졌는지 드러난다.

> 원본 `sql/1.ASIS_COPY_DICTIONARY.sql` 의 원격 뷰는 링크 없이(`FROM DBA_CONSTRAINTS`) 두고,
> 실행 시 `tmp/` 사본에서 각 원격 뷰에 선택한 DB LINK 를 붙여(`DBA_CONSTRAINTS@ASIS_DB`) 실행한다.
> 로컬 복제본 `DBADM.DBA_ASIS_*` 에는 링크가 붙지 않는다.

## 3. STEP 2 — TOBE 딕셔너리 복제 (로컬)

DB LINK 없이 로컬 딕셔너리 조회. SQL 출력 후 Y/N.

```
============================================================
[16:20:20] STEP 2 : TOBE dictionary copy  -> DBADM.DBA_TOBE_*
============================================================
  Source : /home/oracle/object_check/sql/2.TOBE_COPY_DICTIONARY.sql
  ---- SQL ----------------------------------------------------
  | --2. TOBE_COPY_DICTIONARY
  | DROP TABLE DBADM.DBA_TOBE_CONSTRAINTS PURGE;
  | CREATE TABLE DBADM.DBA_TOBE_CONSTRAINTS AS SELECT OWNER
  | ...
  -------------------------------------------------------------
STEP 2 : 위 SQL을 실행하시겠습니까? [Y/N]: y
[16:20:25] STEP 2 executing...
[OK]   STEP 2 done
  ------------------------------------------------------------
   완료 현황 (TOBE dict)
  ------------------------------------------------------------
  [1/7] DBA_TOBE_CONSTRAINTS       ... OK    rows=762
  [2/7] DBA_TOBE_TABLES            ... OK    rows=158
  [3/7] DBA_TOBE_TAB_COLUMNS       ... OK    rows=3120
  [4/7] DBA_TOBE_INDEXES           ... OK    rows=274
  [5/7] DBA_TOBE_TAB_PARTITIONS    ... OK    rows=0
  [6/7] DBA_TOBE_IND_PARTITIONS    ... OK    rows=0
  [7/7] DBA_TOBE_OTHER_OBJECTS     ... OK    rows=52
  => 7/7 complete
  ------------------------------------------------------------
```

## 4. STEP 3 — ASIS 개수 집계

STEP 1 에서 복제한 로컬 `DBADM.DBA_ASIS_*` 만 조회하므로 **DB LINK 를 붙이지 않는다**(nolink).

```
============================================================
[16:20:30] STEP 3 : ASIS object count     -> DBADM.MIG_OBJ_CNT_ASIS
============================================================
  Source : /home/oracle/object_check/sql/3.ASIS_OBJECT_COUNT_CREATE.sql
  ---- SQL ----------------------------------------------------
  | -- 3. ASIS_OBJECT COUNT CREATE
  | DROP TABLE DBADM.MIG_OBJ_CNT_ASIS PURGE;
  | ...
  | FROM DBA_ASIS_OTHER_OBJECTS A,DBA_OBJECTS B
  | ...
  -------------------------------------------------------------
STEP 3 : 위 SQL을 실행하시겠습니까? [Y/N]: y
[16:20:35] STEP 3 executing...
[OK]   STEP 3 done
  ------------------------------------------------------------
   완료 현황 (ASIS count)
  ------------------------------------------------------------
  [1/2] OWNER = EBDBA
         CONSTRAINT       ... cnt=663
         TABLE            ... cnt=158
         TABLE PARITTION  ... cnt=0
         INDEX            ... cnt=274
         INDEX PARITTION  ... cnt=0
         OTHERS OBJECT    ... cnt=52
         => EBDBA objects total = 1147
  [2/2] OWNER = PROWORKS
         CONSTRAINT       ... cnt=40
         TABLE            ... cnt=26
         TABLE PARITTION  ... cnt=0
         INDEX            ... cnt=0
         INDEX PARITTION  ... cnt=0
         OTHERS OBJECT    ... cnt=0
         => PROWORKS objects total = 66
  => 2 owner(s) checked
  ------------------------------------------------------------
```

- **OWNER별**로 6개 OBJECT 종류의 건수(`cnt`)와 소유자별 합계를 보여준다(항목마다 0.5초 간격).
- 해당 OWNER 에 특정 오브젝트가 없으면 `cnt=0` 으로 표기(정상). `MIG_OBJ_CNT` 테이블 자체
  조회 오류만 `FAIL` 로 중단된다.

## 5. STEP 4 — TOBE 개수 집계

```
============================================================
[16:20:40] STEP 4 : TOBE object count     -> DBADM.MIG_OBJ_CNT_TOBE
============================================================
  Source : /home/oracle/object_check/sql/4.TOBE_OBJECT_COUNT_CREATE.sql
  ---- SQL ----------------------------------------------------
  | -- 4. TOBE_OBJECT COUNT CREATE
  | DROP TABLE DBADM.MIG_OBJ_CNT_TOBE PURGE;
  | ...
  -------------------------------------------------------------
STEP 4 : 위 SQL을 실행하시겠습니까? [Y/N]: y
[16:20:45] STEP 4 executing...
[OK]   STEP 4 done
  ------------------------------------------------------------
   완료 현황 (TOBE count)
  ------------------------------------------------------------
  [1/2] OWNER = GEBOWN
         CONSTRAINT       ... cnt=662
         TABLE            ... cnt=158
         TABLE PARITTION  ... cnt=0
         INDEX            ... cnt=274
         INDEX PARITTION  ... cnt=0
         OTHERS OBJECT    ... cnt=52
         => GEBOWN objects total = 1146
  [2/2] OWNER = PROWORKS
         CONSTRAINT       ... cnt=40
         TABLE            ... cnt=26
         TABLE PARITTION  ... cnt=0
         INDEX            ... cnt=0
         INDEX PARITTION  ... cnt=0
         OTHERS OBJECT    ... cnt=0
         => PROWORKS objects total = 66
  => 2 owner(s) checked
  ------------------------------------------------------------
```

> ASIS 는 `EBDBA`, TOBE 는 `GEBOWN` 처럼 OWNER 명이 다를 수 있다. OWNER 매핑 비교는
> STEP 5(GAP) 에서 수행하고, STEP 3/4 완료 현황은 각 DB 의 실제 OWNER 기준으로 보여준다.

## 6. STEP 5 — GAP 리포트 (조회 전용)

```
============================================================
[16:20:50] STEP 5 : ASIS <-> TOBE GAP check
============================================================
  Source : /home/oracle/object_check/sql/5.ASIS_TOBE_OBJECT_GAP_CHECK.sql
  ---- SQL ----------------------------------------------------
  | -- 5. ASIS <-> TOBE OBJECT GAP CHECK
  | ...
  -------------------------------------------------------------
STEP 5 : 위 SQL을 실행하시겠습니까? [Y/N]: y
[16:20:52] STEP 5 executing...

===================== OBJECT COUNT GAP (ASIS - TOBE) =====================
OBJECT_NAME          OBJECT_TYPE                  ASIS_CNT   TOBE_CNT        GAP
-------------------- ------------------------- ---------- ---------- ----------
CONSTRAINT           CONSTRAINT_C                     412        412          0
CONSTRAINT           CONSTRAINT_P                     158        158          0
CONSTRAINT           CONSTRAINT_R                      93         92          1
INDEX                INDEX                            274        274          0
OTHERS OBJECT        SEQUENCE                          41         41          0
TABLE                TABLE                            158        158          0

===================== MISMATCH ONLY (GAP <> 0) ==========================
OBJECT_NAME          OBJECT_TYPE                  ASIS_CNT   TOBE_CNT        GAP
-------------------- ------------------------- ---------- ---------- ----------
CONSTRAINT           CONSTRAINT_R                      93         92          1

===================== RESULT ============================================
GAP_RESULT
--------------------------------------------
CHECK: 1 object type(s) mismatched

[OK]   STEP 5 done

============================================================
  OBJECT_CHECK 단계별 완료 현황
============================================================
  STEP 0 : OK
  STEP 1 : OK
  STEP 2 : OK
  STEP 3 : OK
  STEP 4 : OK
  STEP 5 : OK
============================================================
[OK]   OBJECT_CHECK finished  (log: /home/oracle/object_check/log/OBJECT_CHECK_20260710_162001.log)
============================================================
```

마지막 요약은 각 STEP 의 결과를 `OK` / `SKIP`(사용자가 N) / `FAIL`(오류·세부과정 실패) /
`N/A`(중단으로 미실행) 로 표기한다.

## FAIL 로 중단되는 경우

예) STEP 1 에서 `DBA_ASIS_INDEXES` 생성이 실패하면 완료 현황에 `FAIL` 이 찍히고 즉시 중단:

```
[OK]   STEP 1 done
  ------------------------------------------------------------
   완료 현황 (ASIS dict)
  ------------------------------------------------------------
  [1/7] DBA_ASIS_CONSTRAINTS       ... OK    rows=763
  ...
  [4/7] DBA_ASIS_INDEXES           ... FAIL  ORA-00942: table or view does not exist
  ...
  => 6/7 complete
  ------------------------------------------------------------
[FAIL] STEP 1 : 세부 과정에 FAIL 이 있어 다음 단계로 진행하지 않습니다

============================================================
  OBJECT_CHECK 단계별 완료 현황
============================================================
  STEP 0 : OK
  STEP 1 : FAIL
  STEP 2 : N/A
  STEP 3 : N/A
  STEP 4 : N/A
  STEP 5 : N/A
============================================================
[FAIL] OBJECT_CHECK aborted  (log: /home/oracle/object_check/log/OBJECT_CHECK_20260710_162001.log)
============================================================
```

- GAP = 0 → 일치, `GAP <> 0` → 개수 차이(누락 의심), 한쪽만 존재 → 다른 쪽이 0 으로 표기.
- 전 단계 일치 시 RESULT 는 `PASS : ASIS = TOBE (no gap)`.

## 특정 단계만 건너뛰기

각 단계 프롬프트에서 `n` 을 입력하면 그 단계만 건너뛰고 다음으로 진행한다.
예) 딕셔너리 복제(1·2)는 이미 했고 집계·비교만 다시 하고 싶을 때:

```
STEP 1 : 위 SQL을 실행하시겠습니까? [Y/N]: n
[16:25:01] STEP 1 skipped by user
STEP 2 : 위 SQL을 실행하시겠습니까? [Y/N]: n
[16:25:02] STEP 2 skipped by user
STEP 3 : 위 SQL을 실행하시겠습니까? [Y/N]: y
...
```

> STEP 3 은 DB LINK 가 필요하므로, 1·2 를 건너뛰었더라도 STEP 3 진입 시 DB LINK 선택
> 메뉴가 처음으로 표시된다.

## 로그

전체 출력은 실행마다 아래 파일에 함께 기록된다:

```
${BASE_PATH}/log/OBJECT_CHECK_<YYYYMMDD_HHMMSS>.log
```
