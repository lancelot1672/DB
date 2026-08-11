# GRANT 쉘 동작 예시

업무(BSN)별 롤 `RL_{BSN}_ALL`에 대상 스키마(OWNUSR)의 테이블 권한을 일괄 부여하고 검증하는
두 쉘의 동작 예시입니다.

- `01.GRANT_PRIV.sh` : 권한 부여 — 실행 시 세 모드 중 선택
    - **Mode 1**: `DBM_PRIV_INF` INSERT → 내부 트리거가 GRANT 수행
    - **Mode 2**: 직접 `GRANT` + `CREATE SYNONYM`
    - **Mode 3**: `RL_` 롤 + OWNER 를 골라서 부여 (적용 방식도 선택)
- `02.VERIFY_GRANT.sh` : 시노님 생성 + 권한 부여 검증

세 모드 모두 SQL 생성 직전에 **부여할 권한(`SELECT`/`INSERT`/`UPDATE`/`DELETE`)을
다중 선택**합니다. 기본값은 4개 전부 체크이므로 그냥 `Enter` 를 치면 전체가 선택됩니다.

### 생성 파일명 규칙

파일명은 **`{모드}_{대상}_{권한코드}_{일자}_{시각}.sql`** 형태입니다.

**① 모드 접두사** — 어느 모드가 만든 파일인지. `./sql/` 에 섞여도 `ls` 하면 묶여 보입니다.

| `1_` | `2_` | `3_` | `V_` |
|---|---|---|---|
| Mode 1 | Mode 2 | Mode 3 | 검증 재조치 |

**② 권한 코드** — 그 파일에 담긴 권한. 같은 롤/OWNER 를 권한만 바꿔 여러 번 돌려도 구분됩니다.

| 권한 | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| 코드 | `S` | `I` | `U` | `D` |

- 선택 순서와 무관하게 **항상 `S` → `I` → `U` → `D` 순**으로 붙습니다.
  (`UPDATE` + `SELECT` 를 골라도 `SU`)
- 4종 전부 선택 → `SIUD`

```
1_CORE_S_20260811_090000.sql                      <-- Mode 1: 권한별 파일이라 한 글자
2_DBOWN_TO_RL_CORE_ALL_SIUD_20260811_090000.sql   <-- Mode 2: 한 파일에 4종
3_DBOWN_TO_RL_CORE_RO_SI_20260811_090000.sql      <-- Mode 3 GRANT 방식
V_FAIL_CORE_20260811_102600.sql                   <-- 검증 실패 재조치
```

> 시노님 파일(`2_APCON_SYNONYM_...`)과 검증 재조치 파일(`V_FAIL_...`)은
> 권한 선택과 무관하므로 **권한 코드는 붙지 않습니다** (모드 접두사는 붙습니다).
> 로그 파일(`GRANT_PRIV_...log`)은 실행 전체를 담아 특정 모드에 속하지 않으므로 접두사가 없습니다.

## 예시 데이터

`DBADM.DBM_USR_INF` 테이블에 아래 2개 업무가 등록되어 있다고 가정합니다.

| BSN  | OWNUSR | CONUSR |
|------|--------|--------|
| CORE | DBOWN  | APCON  |
| SALE | SLOWN  | SLCON  |

- `DBOWN` 스키마에 테이블 3개(`ORD`, `CUST`, `PROD`)가 존재한다고 가정합니다.

---

## 1. 권한 부여 : `01.GRANT_PRIV.sh`

실행하면 먼저 동작 모드를 방향키(↑/↓)로 선택합니다.

```
$ ./01.GRANT_PRIV.sh
============================================================
[09:20:00] Select operation
============================================================
  Select operation (Up/Down + Enter):
  > 1. Trigger Grants (INSERT INTO DBADM.DBM_PRIV_INF)
    2. Direct GRANT + CREATE SYNONYM
    3. ROLE based GRANT (pick RL_ role + OWNER)
```

### Mode 1 — DBM_PRIV_INF INSERT (트리거가 GRANT 수행)

```
============================================================
[09:20:01] Pass 1: read available targets from DBADM.DBM_USR_INF
============================================================
  Available targets in DBADM.DBM_USR_INF (Up/Down + Enter):
    ALL          (all BSN)
  > BSN=CORE       OWNUSR=DBOWN      CONUSR=APCON       <-- ↑/↓ 로 목록에서 바로 선택
    BSN=SALE       OWNUSR=SLOWN      CONUSR=SLCON
[09:20:05] Selected BSN: CORE
[OK]   Selected 1 target(s)
  BSN=CORE         OWNUSR=DBOWN        CONUSR=APCON
  Select privileges (Up/Down move, SPACE toggle, Enter confirm):
   [■] SELECT               <-- 기본 전체 체크. 그냥 Enter 치면 4종 전부
   [■] INSERT
   [■] UPDATE
   [■] DELETE
[09:20:05] Selected privileges: SELECT, INSERT, UPDATE, DELETE
============================================================
[09:20:05] Pass 2: generate INSERT SQL files -> ./sql
============================================================
[OK]   1_CORE_S_20260710_092005.sql : 3 INSERT(s)
[OK]   1_CORE_I_20260710_092005.sql : 3 INSERT(s)
[OK]   1_CORE_U_20260710_092005.sql : 3 INSERT(s)
[OK]   1_CORE_D_20260710_092005.sql : 3 INSERT(s)
============================================================
[09:20:06] INSERT preview
============================================================
  Total INSERT rows : 12

  --- 1_CORE_S_20260710_092005.sql (TOP 3) ---
  INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) VALUES ('SELECT','DBOWN','CUST','RL_CORE_ALL',SYSDATE);
  INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) VALUES ('SELECT','DBOWN','ORD','RL_CORE_ALL',SYSDATE);
  INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) VALUES ('SELECT','DBOWN','PROD','RL_CORE_ALL',SYSDATE);
  --- 1_CORE_I_20260710_092005.sql (TOP 3) ---
  INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) VALUES ('INSERT','DBOWN','CUST','RL_CORE_ALL',SYSDATE);
  ...

Proceed with INSERT of 12 row(s) into DBADM.DBM_PRIV_INF? [y/N]: y     <-- 사용자 입력
============================================================
[09:20:10] Execute INSERT via sqlplus (trigger will GRANT)
============================================================
[09:20:10]   -> 1_CORE_S_20260710_092005.sql
[09:20:11]   -> 1_CORE_I_20260710_092005.sql
[09:20:12]   -> 1_CORE_U_20260710_092005.sql
[09:20:13]   -> 1_CORE_D_20260710_092005.sql
[OK]   Granted privileges via 12 INSERT(s) into DBADM.DBM_PRIV_INF
[09:20:13] Generated SQL files kept under: ./sql
```
> INSERT 4개 파일(`SELECT/INSERT/UPDATE/DELETE`)은 **실행 여부와 무관하게** `./sql/`에 항상 생성·보존됩니다.
> (미리보기에서 `N`을 눌러 실행을 취소해도 파일은 남습니다.)

#### 동작 순서
1. `DBM_USR_INF` 전체 조회 → 사용 가능한 BSN 목록 표시
2. 대상 BSN 입력 (공백/`ALL` → 전체)
3. **부여할 권한 선택** — `SPACE` 토글, `Enter` 확정 (기본 전체 선택)
4. 대상 OWNUSR의 `DBA_TABLES` 기준으로 **선택한 권한별** SQL 파일 생성
5. 총 건수 + 미리보기(파일별 TOP 3) → `[y/N]` 확인
6. `y` 입력 시 `DBM_PRIV_INF`에 INSERT → **내부 트리거가 실제 GRANT 수행**

> `SELECT` 만 선택했다면 `1_CORE_S_...sql` 한 개만 생성됩니다.
> (전체 선택 시에만 위 예시처럼 4개가 생성)
> 파일명의 `1_` 은 Mode 1, 끝의 `S`/`I`/`U`/`D` 는 그 파일에 담긴 권한 코드입니다
> — [생성 파일명 규칙](#생성-파일명-규칙) 참고.

#### 생성되는 SQL 파일 예 (`1_CORE_S_20260710_092005.sql`)
```sql
INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) VALUES ('SELECT','DBOWN','CUST','RL_CORE_ALL',SYSDATE);
INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) VALUES ('SELECT','DBOWN','ORD','RL_CORE_ALL',SYSDATE);
INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) VALUES ('SELECT','DBOWN','PROD','RL_CORE_ALL',SYSDATE);
COMMIT;
```
> `INSERT` / `UPDATE` / `DELETE` 파일도 `PRIVILEGE` 값만 다르게 동일하게 생성되며, 각 파일 마지막 줄은 `COMMIT;`

### Mode 2 — 직접 GRANT + CREATE SYNONYM

시작 메뉴에서 `2`를 선택하면, `OWNUSR` / `CONUSR`를 입력받고 `CONUSR`에 부여된
`RL%` 롤을 조회해 선택한 뒤, 해당 롤에 `OWNUSR` 테이블 권한을 부여하고 시노님을 생성합니다.

```
  Select operation (Up/Down + Enter):
    1. INSERT INTO DBADM.DBM_PRIV_INF (trigger grants)
  > 2. Direct GRANT + CREATE SYNONYM
============================================================
[09:30:00] Mode 2: Direct GRANT + CREATE SYNONYM
============================================================
  Enter OWNUSR (table owner schema): DBOWN          <-- 사용자 입력
  Enter CONUSR (connection user): APCON             <-- 사용자 입력
  RL roles granted to APCON (Up/Down + Enter):
  > RL_CORE_ALL              <-- ↑/↓ 로 선택 (DBA_ROLE_PRIVS 조회 결과)
    RL_SALE_ALL
  Select privileges (Up/Down move, SPACE toggle, Enter confirm):
   [■] SELECT               <-- SPACE 로 선택/해제, Enter 로 확정
   [■] INSERT
   [ ] UPDATE
   [■] DELETE
[09:30:04] Target: OWNUSR=DBOWN  CONUSR=APCON  ROLE=RL_CORE_ALL  PRIVS=SELECT, INSERT, DELETE
[OK]   2_DBOWN_TO_RL_CORE_ALL_SID_20260710_093000.sql : 3 GRANT(s)
[OK]   2_APCON_SYNONYM_20260710_093000.sql : 3 SYNONYM(s)
============================================================
[09:30:05] Preview
============================================================
  --- GRANT (TOP 3) ---
  GRANT SELECT, INSERT, DELETE ON DBOWN.CUST TO RL_CORE_ALL;
  GRANT SELECT, INSERT, DELETE ON DBOWN.ORD TO RL_CORE_ALL;
  GRANT SELECT, INSERT, DELETE ON DBOWN.PROD TO RL_CORE_ALL;
  --- SYNONYM (TOP 3) ---
  CREATE SYNONYM APCON.CUST FOR DBOWN.CUST;
  CREATE SYNONYM APCON.ORD FOR DBOWN.ORD;
  CREATE SYNONYM APCON.PROD FOR DBOWN.PROD;

Proceed with 3 GRANT(s) and 3 SYNONYM(s)? [y/N]: y     <-- 사용자 입력
============================================================
[09:30:10] Execute GRANT + CREATE SYNONYM via sqlplus
============================================================
[09:30:10]   -> 2_DBOWN_TO_RL_CORE_ALL_SID_20260710_093000.sql
[09:30:11]   -> 2_APCON_SYNONYM_20260710_093000.sql
[OK]   GRANTed on 3 table(s) to RL_CORE_ALL; 3 SYNONYM(s) for APCON
[09:30:11] Generated SQL files kept under: ./sql
```

#### 동작 순서
1. `OWNUSR`(테이블 소유 스키마) 입력
2. `CONUSR`(접속 유저) 입력 → `DBA_ROLE_PRIVS`에서 `GRANTEE=CONUSR AND GRANTED_ROLE LIKE 'RL%'` 조회
3. 조회된 `RL%` 롤을 방향키로 선택
4. **부여할 권한 선택** — `SELECT/INSERT/UPDATE/DELETE`를 `SPACE`로 토글, `Enter`로 확정 (기본 전체 선택)
5. `OWNUSR` 소유 테이블 기준으로 SQL 2종 생성 → 미리보기 → `[y/N]` 확인 → 실행

#### 생성되는 SQL 파일
- `2_DBOWN_TO_RL_CORE_ALL_SID_20260710_093000.sql` (선택한 권한만 한 줄로 부여)
  ```sql
  GRANT SELECT, INSERT, DELETE ON DBOWN.CUST TO RL_CORE_ALL;
  GRANT SELECT, INSERT, DELETE ON DBOWN.ORD  TO RL_CORE_ALL;
  GRANT SELECT, INSERT, DELETE ON DBOWN.PROD TO RL_CORE_ALL;
  ```
- `2_APCON_SYNONYM_20260710_093000.sql` (`CONUSR` 스키마에 `OWNUSR` 테이블 시노님)
  ```sql
  CREATE SYNONYM APCON.CUST FOR DBOWN.CUST;
  CREATE SYNONYM APCON.ORD  FOR DBOWN.ORD;
  CREATE SYNONYM APCON.PROD FOR DBOWN.PROD;
  ```
> `GRANT`/`CREATE SYNONYM`은 DDL이라 별도 `COMMIT` 없이 자동 반영됩니다.
> 시노님을 다른 스키마(`CONUSR`)에 만들려면 실행 계정(`dbadm`)에 `CREATE ANY SYNONYM` 권한이 필요합니다.

### Mode 3 — ROLE 기준 권한 부여

Mode 2 가 `CONUSR` 를 먼저 입력받아 **그 계정에 붙은 롤만** 보여주는 것과 달리,
Mode 3 는 **`DBA_ROLE_PRIVS` 의 `RL_` 롤 전체**를 먼저 보여주고 롤을 고른 뒤,
그 롤에 어떤 OWNER 의 테이블 권한을 붙일지 고릅니다.
`CONUSR` 를 입력받지 않으므로 **시노님은 생성하지 않습니다.**

```
  Select operation (Up/Down + Enter):
    1. Trigger Grants (INSERT INTO DBADM.DBM_PRIV_INF)
    2. Direct GRANT + CREATE SYNONYM
  > 3. ROLE based GRANT (pick RL_ role + OWNER)
============================================================
[09:40:00] Mode 3: ROLE based GRANT
============================================================
  RL_ roles in DBA_ROLE_PRIVS (Up/Down + Enter):
    GRANTEE=APCON          GRANTED_ROLE=RL_CORE_ALL
  > GRANTEE=APCON          GRANTED_ROLE=RL_CORE_RO      <-- ↑/↓ 로 선택
    GRANTEE=SLCON          GRANTED_ROLE=RL_SALE_ALL
[09:40:04] Selected ROLE (GRANTEE): RL_CORE_RO
  Table OWNER in DBA_TABLES (42 found, Up/Down + Enter):
    APCON
  > DBOWN                                               <-- 목록이 길면 창 안에서 스크롤
    SLOWN
    SYS
   -- 2/42 (PgUp/PgDn) --
[09:40:08] Selected OWNER: DBOWN
  Select privileges (Up/Down move, SPACE toggle, Enter confirm):
   [■] SELECT               <-- SPACE 로 UPDATE/DELETE 해제
   [■] INSERT
   [ ] UPDATE
   [ ] DELETE
[09:40:12] Selected privileges: SELECT, INSERT
  Select apply method (Up/Down + Enter):
  > 1. INSERT INTO DBADM.DBM_PRIV_INF  (trigger performs GRANT)
    2. Direct GRANT                    (execute GRANT statements)
[09:40:15] Apply method: INSERT
[09:40:15] Target: OWNER=DBOWN  GRANTEE=RL_CORE_RO  PRIVS=SELECT, INSERT  APPLY=INSERT
============================================================
[09:40:15] Generate SQL -> ./sql
============================================================
[OK]   3_RL_CORE_RO_S_20260710_094000.sql : 3 INSERT(s)
[OK]   3_RL_CORE_RO_I_20260710_094000.sql : 3 INSERT(s)
============================================================
[09:40:16] Preview
============================================================
  --- 3_RL_CORE_RO_S_20260710_094000.sql (TOP 3) ---
  INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) VALUES ('SELECT','DBOWN','CUST','RL_CORE_RO',SYSDATE);
  ...

Proceed with INSERT of 6 row(s) into DBADM.DBM_PRIV_INF? [y/N]: y     <-- 사용자 입력
============================================================
[09:40:20] Execute INSERT via sqlplus (trigger will GRANT)
============================================================
[09:40:20]   -> 3_RL_CORE_RO_S_20260710_094000.sql
[09:40:21]   -> 3_RL_CORE_RO_I_20260710_094000.sql
[OK]   Granted privileges via 6 INSERT(s) into DBADM.DBM_PRIV_INF (GRANTEE=RL_CORE_RO)
[09:40:21] Generated SQL files kept under: ./sql
```

#### 동작 순서
1. `DBA_ROLE_PRIVS` 에서 `GRANTED_ROLE LIKE 'RL\_%' ESCAPE '\'` 조회 → `GRANTEE`, `GRANTED_ROLE` 표시
2. 롤 1개 선택 → 선택한 **`GRANTED_ROLE` 이 권한을 받을 주체(GRANTEE)** 가 됨
3. `SELECT DISTINCT OWNER FROM DBA_TABLES ORDER BY OWNER ASC` → OWNER 1개 선택
4. **부여할 권한 선택** (기본 전체)
5. **적용 방식 선택** — `DBM_PRIV_INF` INSERT / 직접 GRANT
6. SQL 생성 → 미리보기(TOP 3) → `[y/N]` 확인 → 실행

> 목록에 보이는 `GRANTEE` 컬럼은 **그 롤을 이미 갖고 있는 계정**을 참고로 보여주는 것입니다.
> 같은 롤이 여러 계정에 부여돼 있으면 행이 여러 번 표시됩니다.
> 권한을 받는 대상은 어느 행을 고르든 `GRANTED_ROLE` 입니다.

#### 적용 방식에 따른 생성 파일

- **INSERT 선택 시** — 권한별로 파일 분리, 마지막 줄 `COMMIT;`
  `3_RL_CORE_RO_S_20260710_094000.sql`
  ```sql
  INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) VALUES ('SELECT','DBOWN','CUST','RL_CORE_RO',SYSDATE);
  INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) VALUES ('SELECT','DBOWN','ORD','RL_CORE_RO',SYSDATE);
  INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) VALUES ('SELECT','DBOWN','PROD','RL_CORE_RO',SYSDATE);
  COMMIT;
  ```
- **GRANT 선택 시** — 한 문장에 권한이 다 들어가므로 파일 1개
  `3_DBOWN_TO_RL_CORE_RO_SI_20260710_094000.sql`
  ```sql
  GRANT SELECT, INSERT ON DBOWN.CUST TO RL_CORE_RO;
  GRANT SELECT, INSERT ON DBOWN.ORD  TO RL_CORE_RO;
  GRANT SELECT, INSERT ON DBOWN.PROD TO RL_CORE_RO;
  ```

> **GRANT 방식으로 부여하면 `DBM_PRIV_INF` 에는 행이 남지 않습니다.**
> 매핑 테이블 이력이 필요하면 INSERT 방식을 쓰십시오.

---

## 2. 검증 : `02.VERIFY_GRANT.sh`

```
$ ./02.VERIFY_GRANT.sh
============================================================
[09:25:01] Read available targets from DBADM.DBM_USR_INF
============================================================
  Available targets in DBADM.DBM_USR_INF (Up/Down + Enter):
    ALL          (all BSN)
  > BSN=CORE       OWNUSR=DBOWN      CONUSR=APCON       <-- ↑/↓ 로 목록에서 바로 선택
    BSN=SALE       OWNUSR=SLOWN      CONUSR=SLCON
[09:25:04] Selected BSN: CORE
BSN          OWNUSR       CONUSR       COUNT(TABLE)      SYN   SELECT   INSERT   UPDATE   DELETE   RESULT
=========================================================================================================
CORE         DBOWN        APCON                   3        3        3        3        3        3   [OK]
=========================================================================================================
[OK]   All 1 target(s) verified
```

### 검증 실패 예시 (권한 일부 누락)
`UPDATE` 권한이 `PROD` 테이블에만 누락된 경우, **어떤 객체가 안 맞는지** 상세 출력하고
재조치용 SQL 파일을 생성합니다.
```
BSN          OWNUSR       CONUSR       COUNT(TABLE)      SYN   SELECT   INSERT   UPDATE   DELETE   RESULT
=========================================================================================================
CORE         DBOWN        APCON                   3        3        3        3        2        3   [FAIL]
[FAIL]   CORE UPDATE  count mismatch: 2 / expected 3 (GRANTEE=RL_CORE_ALL)
[FAIL]   CORE missing GRANT (1) [GRANTEE=RL_CORE_ALL]:
         - UPDATE  PROD
[10:26:00] CORE remediation SQL written : ./sql/V_FAIL_CORE_20260710_102600.sql
=========================================================================================================
[FAIL]   1 of 1 target(s) FAILED verification
```

생성되는 재조치 SQL 파일 (`V_FAIL_CORE_20260710_102600.sql`):
```sql
-- ============================================================
-- VERIFY FAIL remediation : BSN=CORE
--   OWNUSR=DBOWN  CONUSR=APCON  GRANTEE=RL_CORE_ALL
--   expected table count = 3
--   generated 20260710_102600
-- ============================================================

-- [1] Missing SYNONYMS : 0
--   (none)

-- [2] Missing GRANTS : 1  (re-INSERT into DBADM.DBM_PRIV_INF; trigger re-grants)
INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED) VALUES ('UPDATE','DBOWN','PROD','RL_CORE_ALL',SYSDATE);

COMMIT;
```
> 이 파일을 `sqlplus`로 실행하면 누락분만 다시 부여됩니다. 시노님 누락 시에는
> `[1]` 섹션에 `CREATE SYNONYM {CONUSR}.{TABLE} FOR {OWNUSR}.{TABLE};` 문이 생성됩니다.

### 검증 항목 (PLAN.md 검증 1·2)
- **검증 1 (SYN)** : `DBA_SYNONYMS`에서 `TABLE_OWNER=OWNUSR`, `OWNER=CONUSR` 시노님 개수
  == 대상 테이블 개수(`COUNT(TABLE)`)
- **검증 2 (SELECT/INSERT/UPDATE/DELETE)** : `DBA_TAB_PRIVS`에서 `GRANTEE=RL_{BSN}_ALL`의
  권한별 개수가 각각 대상 테이블 개수(`COUNT(TABLE)`)와 일치
- 모든 항목이 `COUNT(TABLE)`과 일치하면 `[OK]`, 하나라도 불일치하면 `[FAIL]` + 상세 사유 출력
- 하나라도 FAIL이면 스크립트는 `exit 1` 로 종료

---

## 참고

- 두 쉘 모두 인자 없이 실행하며, 목록에서 **방향키(↑/↓) + Enter**로 바로 선택합니다.
  (`DBM_USR_INF` 목록의 첫 항목 `ALL`은 전체 대상. TTY가 없는 환경 — 파이프/크론 등 —
  에서는 자동으로 목록 출력 후 타이핑 입력으로 폴백)
- 목록이 터미널 높이를 넘으면 창 안에서 스크롤되며 `-- 3/42 (PgUp/PgDn) --` 형태로
  현재 위치를 표시합니다. `PgUp`/`PgDn` 은 한 페이지씩, `Home`/`End` 는 처음/끝으로 이동합니다.
  (두 쉘 모두 적용)
- 환경 변수(`DB_USER`, `DB_PASS`, `BASE_PATH`)는 `MIGRATION/MIG.env` 및 실행 환경에서 로드됩니다.
- 생성 SQL 파일(부여 / 검증 재조치)은 `./sql/`, 로그는 `${BASE_PATH}/log/` 에 보존되며,
  **실행을 취소(`N`)해도 파일은 남습니다.**
- `DBM_PRIV_INF` INSERT 방식의 실제 권한 부여(GRANT)는 내부 트리거가 수행합니다.
  Mode 2 / Mode 3(GRANT 방식)은 `GRANT` 문을 직접 실행합니다.
