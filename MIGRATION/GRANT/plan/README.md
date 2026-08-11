# GRANT 권한 부여 툴 — 기능별 플랜 인덱스

`GRANT/` 디렉토리의 권한 부여 / 검증 스크립트를 기능 단위로 쪼갠 플랜 문서 모음이다.
각 문서는 **요구사항 → 현재 구현 상태 → 남은 작업** 순으로 기술한다.

대상 스크립트는 두 개뿐이다.

| 스크립트 | 역할 |
|---|---|
| `01.GRANT_PRIV.sh` | 권한 부여 (모드 선택 → 대상 발췌 → SQL 생성 → 실행) |
| `02.VERIFY_GRANT.sh` | 부여 결과 검증 (건수 비교 + 누락 객체 추출 + 보정 SQL 생성) |

## 구현 현황

**공통 규약** — 모드에 상관없이 적용. 신규 기능 추가 전에 읽을 것.

| # | 문서 | 내용 | 상태 |
|---|---|---|---|
| 00 | [00.COMMON_UI.md](00.COMMON_UI.md) | 화면 조작 헬퍼 (스크롤 메뉴, 다중 선택, 로깅) | 🟡 부분 구현 |
| 07 | [07.FILE_CONVENTION.md](07.FILE_CONVENTION.md) | **파일 출력 규약** (저장 위치, 파일명, 권한 코드, 보존/정리) | ✅ 구현 완료 |
| 04 | [04.COMMON_PRIV_SELECT.md](04.COMMON_PRIV_SELECT.md) | 공통 1 — PRIVILEGE 다중 선택 (기본 전체) | ✅ 구현 완료 |
| 05 | [05.COMMON_APPLY_METHOD.md](05.COMMON_APPLY_METHOD.md) | 공통 2 — 적용 방식 선택 (INSERT / 직접 GRANT) | ✅ 구현 완료 |

**기능별**

| # | 문서 | 기능 | 상태 |
|---|---|---|---|
| 01 | [01.MODE1_INSERT_DBM_PRIV_INF.md](01.MODE1_INSERT_DBM_PRIV_INF.md) | Mode 1 — `DBM_USR_INF` 기준 `DBM_PRIV_INF` INSERT | ✅ 구현 완료 |
| 02 | [02.MODE2_DIRECT_GRANT_SYNONYM.md](02.MODE2_DIRECT_GRANT_SYNONYM.md) | Mode 2 — 직접 GRANT + CREATE SYNONYM | ✅ 구현 완료 |
| 03 | [03.MODE3_ROLE_BASED_GRANT.md](03.MODE3_ROLE_BASED_GRANT.md) | Mode 3 — ROLE 기준 권한 부여 | ✅ 구현 완료 |
| 06 | [06.VERIFY.md](06.VERIFY.md) | 부여 결과 검증 | 🟡 부분 구현 |

범례 — ✅ 구현 완료 / 🟡 부분 구현 (요구사항 대비 미달) / ⬜ 미구현
번호는 작성 순서에 따른 식별자일 뿐 읽는 순서가 아니다.

## 남은 작업

`04` → `05` → `03` 은 구현 완료(2026-08-11). 남은 것은 아래 둘이다.

1. **06 (검증)** — 우선 `02.VERIFY_GRANT.sh:219-221` 의 `OWNER` 조건 누락(오탐)을 고치고,
   Mode 3 로 부여한 롤/권한을 검증할 수 있도록 확장한다.
2. **00 (공통 UI)** — 스크롤 메뉴는 `01.GRANT_PRIV.sh` 에만 적용됐다.
   `02.VERIFY_GRANT.sh` 의 복사본은 아직 구버전이다.

## 배경 테이블

| 테이블 | 설명 |
|---|---|
| `DBADM.DBM_USR_INF` | 업무(BSN) ↔ 소유 계정(OWNUSR) ↔ 접속 계정(CONUSR) 매핑 |
| `DBADM.DBM_PRIV_INF` | 테이블 ↔ ROLE 권한 매핑. **INSERT 시 내부 TRIGGER 가 실제 GRANT 수행** |
| `DBA_TABLES` / `DBA_ROLE_PRIVS` / `DBA_TAB_PRIVS` / `DBA_SYNONYMS` | Oracle 딕셔너리 |
