## 권한 부여 쉘

> 상세 플랜은 기능별로 **[`./plan/`](plan/README.md)** 아래에 분리되어 있다.
> 구현 현황 표는 [plan/README.md](plan/README.md) 참고.

### 동작 과정
1. DBADM.DBM_USR_INF 기준으로 검색
2. DBADM.DBM_USR_INF, DBA_TABLES 검색해서 DBADM.DBM_PRIV_INF 테이블에 INSERT
3. 내부 TRIGGER 통해 권한 부여

3번은 DB 측에 이미 되어있으므로 1, 2번만 스크립트로 구현한다.

### 대상 발췌 1 : DBADM.DBM_USR_INF 기준으로 검색
```SQL
SELECT BSN, OWNUSR, CONUSR FROM DBADM.DBM_USR_INF;
```

### 대상 발췌 2 : DBADM.DBM_USR_INF 테이블 기준으로 DBADM.DBM_PRIV_INF 테이블에 INSERT
DBADM.DBM_USR_INF 테이블의 OWNUSR 기준으로 DBA_TABLES에서 검색

- GRANTEE : BSN을 기준으로 RL_{BSN}_ALL로 치환
- PRIVILEGE : SELECT / INSERT / UPDATE / DELETE 각각 SQL 파일로 생성 (맨 마지막 줄엔 COMMIT;)

수행 예시
- BSN -> CORE
- OWNUSR -> DBOWN
- CONUSR -> APCON

```SQL
--INSERT SQL
INSERT INTO DBADM.DBM_PRIV_INF (PRIVILEGE, OWNER, OBJECT_NAME, GRANTEE, CREATED)
VALUES ('SELECT', 'DBOWN', 'TABLE_NAME', 'RL_CORE_ALL', SYSDATE);
```

### 검증

#### 1. 시노님 생성 검증

- OWNER -> CONUSR
- TABLE_OWNER -> OWNUSR

```SQL
SELECT OWNER, SYNONYM_NAME, TABLE_OWNER, TABLE_NAME FROM DBA_SYNONYMS
WHERE TABLE_OWNER = '{OWNUSR}';
```

#### 2. 권한 부여 검증
GRANTEE : RL_{BSN}_ALL

아래 SQL로 조회시 SELECT, INSERT, DELETE, UPDATE가 TABLE 갯수만큼 존재하여야 한다.
```SQL
SELECT GRANTEE, OWNER, TABLE_NAME, PRIVILEGE FROM DBA_TAB_PRIVS
WHERE GRANTEE = '{GRANTEE}';
```

---

## 기능별 플랜 문서

**공통 규약**

| # | 문서 | 내용 | 상태 |
|---|---|---|---|
| 00 | [plan/00.COMMON_UI.md](plan/00.COMMON_UI.md) | 화면 조작 헬퍼 (스크롤 메뉴, 다중 선택, 로깅) | 🟡 부분 구현 |
| 07 | [plan/07.FILE_CONVENTION.md](plan/07.FILE_CONVENTION.md) | **파일 출력 규약** (저장 위치, 파일명, 권한 코드, 보존/정리) | ✅ 구현 완료 |
| 04 | [plan/04.COMMON_PRIV_SELECT.md](plan/04.COMMON_PRIV_SELECT.md) | 공통 1 — PRIVILEGE 다중 선택 (기본 전체) | ✅ 구현 완료 |
| 05 | [plan/05.COMMON_APPLY_METHOD.md](plan/05.COMMON_APPLY_METHOD.md) | 공통 2 — 적용 방식 선택 (INSERT / 직접 GRANT) | ✅ 구현 완료 |

**기능별**

| # | 문서 | 기능 | 상태 |
|---|---|---|---|
| 01 | [plan/01.MODE1_INSERT_DBM_PRIV_INF.md](plan/01.MODE1_INSERT_DBM_PRIV_INF.md) | Mode 1 — DBM_PRIV_INF INSERT | ✅ 구현 완료 |
| 02 | [plan/02.MODE2_DIRECT_GRANT_SYNONYM.md](plan/02.MODE2_DIRECT_GRANT_SYNONYM.md) | Mode 2 — 직접 GRANT + CREATE SYNONYM | ✅ 구현 완료 |
| 03 | [plan/03.MODE3_ROLE_BASED_GRANT.md](plan/03.MODE3_ROLE_BASED_GRANT.md) | Mode 3 — ROLE 기준 권한 부여 | ✅ 구현 완료 |
| 06 | [plan/06.VERIFY.md](plan/06.VERIFY.md) | 부여 결과 검증 | 🟡 부분 구현 |
