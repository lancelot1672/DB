# Claude Code 요청 / 응답 기록

## 2026-09-18

### 요청
> DATA_MIG_VERIFY 디렉토리 아래에 DATA_MIG_VERIFY_PLAN을 읽고 검증 쉘 작성할거야

### 확인한 것
- `DATA_MIG_VERIFY_PLAN.md`, `CLAUDE.md`
- 형제 디렉토리 `../DATA_MIG` 의 쉘 규약 (`MIG.env` 로딩, `_out`/`_log`/`_ok`/`_fail`,
  `${BASE_PATH}/tmp/..._$$`, `y/N` 확인, 일반 SQL 만 사용)
- 제어 테이블 DDL : `../DATA_MIG/DDL_Script/DBM_MIG_MSTR.sql`, `DBM_MIG_COL_MAP.sql`

### 질문 → 결정 (규칙 1)
| 질문 | 결정 |
|---|---|
| 검증 대상 목록 출처  | **`DBM_MIG_MSTR` 조회** (`MSTR_ID` + `MIG_YN='Y'` + `MIG_TYPE IN (PRE, DDAY)`). 이관 SQL 과 조건이 어긋나지 않음 |
| ASIS / TOBE SUM 취득 방식 | **양쪽 각각 접속** (DB LINK 미사용). Oracle ↔ Tibero 이기종 대응, DB LINK 부하 없음. `VERIFY.env` 에 계정 2벌 |
| 결과 테이블 컬럼 | **컬럼 추가**. 기존 5개로는 *어느 컬럼의 SUM 인지 알 수 없음* → `COLUMN_NAME` 필수 추가 + `RUN_ID` `MSTR_ID` `MIG_TYPE` `VERIFY_COND` `SRC_*` `DIFF` `ERROR_MSG` `VERIFY_DT` |
| NUMBER 컬럼 선정 기준 | **타겟 `ALL_TAB_COLUMNS` 기준 `COLUMN_ID` 순 상위 10개** (`MAX_NUM_COLS`). `TRANS_YN='Y'` 는 `DBM_MIG_COL_MAP` 으로 ASIS 컬럼명 매핑, `ADD` / ASIS 미존재는 `SKIP` |

### 응답 (산출물)
| 파일 | 내용 |
|---|---|
| `01.RUN_DATA_VERIFY.sh` | 검증 쉘. 옵션 `-t` 특정 테이블 / `-n` dry run / `-r` 리포트 / `-y` 무확인 / `-h` 도움말 |
| `DDL_Script/DBM_MIG_PRE_DATA_VERIFY.sql` | 결과 테이블 DDL (+ 조회 인덱스) |
| `VERIFY.env.example` | 접속 정보 / 옵션 (`VERIFY.env` 로 복사해 사용, gitignore 대상) |
| `README.md` | 사용법 / 검증 규칙 / 결과 테이블 설명 / 주의사항 |
| `EXAMPLE.md` | 실행 예시 (예시 데이터 &rarr; 생성 SQL &rarr; 화면 출력 &rarr; 결과 테이블) |

### 설계 메모
- `COL_CONDITION` 은 이관 SQL 과 동일하게 **ASIS 기준 컬럼명**으로 해석했다.
  `TRANS_YN='Y'` 인 테이블의 TOBE 조건 컬럼명은 `DBM_MIG_COL_MAP` 의 `RENAME` 을 역매핑해서 구한다.
- SUM 값은 `TO_CHAR` 문자 그대로 저장하고, 비교는 정규화(앞 0 / 끝 0 / `+` / `.5` → `0.5`) 후
  문자 비교로 한다. 숫자 변환을 거치지 않아 큰 수 / 소수 정밀도가 깨지지 않는다.
  Oracle ↔ Tibero 표기가 다를 경우를 대비해 `SUM_FMT` / `SUM_ROUND` 옵션을 두었다.
- `COUNT_CHECK=Y` 면 `COUNT(*)` 도 `*ROW_COUNT*` 행으로 남긴다 (같은 쿼리라 추가 비용 없음).
- `WORKER_DEGREE` 개 테이블을 동시에 처리한다 (테이블당 ASIS/TOBE 세션 각 1개).
- 결과는 매 수행 새 `RUN_ID` 로 쌓아 이력을 남긴다. 종료 코드 `2` = 불일치/ERROR 존재.
- `DDAY` 는 D-day 이전에 검증하면 당연히 불일치이므로 `MIG_TYPE_LIST` 기본값을 `PRE` 로 두었다.

### 검증 (실 DB 없이)
가짜 `sqlplus` / `tbsql` 스텁으로 전 구간 실행 확인 — 대상 조회, 컬럼 매핑(`RENAME`/`ADD`),
ASIS 미존재 컬럼 `SKIP`, SUM 비교(일치/불일치), `COUNT(*)` 비교, 결과 INSERT 생성,
DB 오류 시 `ERROR` 행 기록, `-t` / `-n` / `-r` 옵션, 종료 코드까지 정상 동작.
**실 DB 연결 테스트는 하지 않았다.**
