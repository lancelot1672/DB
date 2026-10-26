# P2O_MIG — PostgreSQL → Oracle/Tibero 데이터 마이그레이션 쉘 플랜

## 1. 목적
`./sql` 의 추출 SQL 을 골라 PostgreSQL 데이터를 서버에 `,` 구분 CSV 로 내려쓰고(UNLOAD),
대상 테이블을 대화형으로 입력받아 Oracle / Tibero 에 적재(LOAD)한다.

## 2. 방식

```
./sql/*.sql --(선택)--> [PostgreSQL] --psql COPY TO STDOUT--> ${BASE_PATH}/csv/<SQL파일명>.csv
                                                      --(대상 테이블 입력)--> sqlldr / tbloader --> [Oracle | Tibero]
```

| 단계 | 도구 | 비고 |
|------|------|------|
| UNLOAD | `psql` + `COPY (<SQL>) TO STDOUT WITH (FORMAT csv, HEADER)` | 출력을 파일로 리다이렉트 → PG 서버 파일 권한 불필요, 여러 줄 SQL 가능 |
| LOAD (Oracle) | `sqlldr` | control 파일 자동 생성 |
| LOAD (Tibero) | `tbloader` | control 문법이 sqlldr 과 거의 동일 → 생성 로직 공유 |

소스(PG)와 대상의 스키마·테이블명이 다르므로 **소스는 SQL 파일이, 대상은 대화형 입력이** 결정한다.

## 3. 선행 작업 (클라이언트 설치)
현재 실행 서버에 `psql`, `sqlldr`/`tbloader` 가 모두 없다. 스크립트 작성과 별개로 설치가 필요하다.

- PostgreSQL 클라이언트(`psql`) — 소스 PG 버전 이상
- Oracle 대상: Oracle Client(`sqlplus`, `sqlldr` 포함 — Instant Client 는 Tools 패키지 필요)
- Tibero 대상: Tibero Client(`tbsql`, `tbloader`)
- 실행 서버 → PG / 대상 DB 포트 방화벽 오픈

클라이언트 환경변수는 DBMS별 env 파일(`env/PG.env`, `env/ORACLE.env`, `env/TIBERO.env`)로 분리하고,
`P2O.env` 의 `*_ENV_FILE` 이 경로를 지정한다(상대경로 = 스크립트 디렉토리, 비우면 현재 셸 PATH 사용).
각 스크립트는 해당 env 파일을 source 한 뒤(`01` = PG, `02` = `TARGET_DBMS` 에 맞는 1개)
`command -v` 로 필요한 명령을 점검하고, 파일이나 명령이 없으면 안내 후 즉시 실패한다.

## 4. 파일 구성

| 파일 | 용도 |
|------|------|
| `P2O.env` (gitignore) / `P2O.env.example` | 접속 정보·경로·옵션, 클라이언트 env 파일 경로 |
| `env/PG.env` / `env/ORACLE.env` / `env/TIBERO.env` (gitignore, `*.env.example` 템플릿) | 클라이언트 환경변수(`*_HOME`, `PATH`, `LD_LIBRARY_PATH`, `NLS_LANG`/`TB_NLS_LANG`) |
| `sql/*.sql` | 추출 SQL (파일 1개 = SELECT 1개 = CSV 1개) |
| `01.UNLOAD_PG.sh` | SQL 파일 선택 → PG → CSV |
| `02.LOAD_TARGET.sh` | CSV 선택 → 대상 테이블 입력 → 적재 |
| `README.md` | 사용법·SQL 작성 규칙·예시 |

`P2O.env` 주요 항목: `PG_ENV_FILE/ORACLE_ENV_FILE/TIBERO_ENV_FILE`, `PG_HOST/PG_PORT/PG_DB`, `DB_TNS`,
`TARGET_DBMS`(`ORACLE`|`TIBERO`), `BASE_PATH`, `LOAD_MODE`(`APPEND`|`TRUNCATE`), `DIRECT`(`Y`|`N`), `LOAD_ERRORS`, `CHARSET`

계정·비밀번호는 env 에 두지 않고 스크립트 시작 시 대화형으로 입력받는다(`_ask_login`, 비밀번호는 `read -s`).

디렉토리: `${BASE_PATH}/csv`, `/ctl`, `/log`, `/bad`, `/tmp`

## 5. 추출 SQL 작성 규칙 (`sql/*.sql`)
- SELECT(또는 WITH) 문 1개만 작성. WHERE 로 부분 이관 조건을 직접 기술
- **컬럼 alias = 대상 테이블 컬럼명** (CSV 헤더로 내려가 적재 시 이름 기준 매핑에 사용)
- 날짜는 SQL 에서 고정 포맷 문자열로 변환
  - 대상 `DATE` → `to_char(col,'YYYYMMDDHH24MISS')`
  - 대상 `TIMESTAMP` → `to_char(col,'YYYYMMDDHH24MISSUS')`
- `boolean` 등 대상에 없는 타입도 SQL 에서 변환 (`CASE WHEN col THEN 'Y' ELSE 'N' END`)

## 6. 스크립트 동작

### 공통: 방향키 선택 메뉴 `_select_menu`
- 목록을 출력하고 `↑`/`↓`(및 `k`/`j`)로 커서 이동, `Enter` 선택, `q` 취소
- `read -rsn1` + ESC 시퀀스 처리, 선택 행 반전 표시(순수 bash, 외부 도구 불필요)
- 목록이 비어 있으면 안내 후 종료

### 공통: 계정 입력 `_ask_login`
- 계정·비밀번호를 빈 값이 아닐 때까지 입력받는다. 비밀번호는 화면·로그에 남기지 않는다
- 입력 직후 접속 확인(PG `SELECT 1`, 대상 `SELECT ... FROM DUAL`), 실패하면 즉시 종료
- 비밀번호는 명령행 인자(`ps` 노출)로 넘기지 않는다: `psql` 은 `PGPASSWORD`, `sqlplus`/`tbsql` 은
  로그인 없이 시작 후 표준입력 `CONNECT`, `sqlldr` 은 권한 600 tmp parfile.
  `tbloader` 는 userid 를 명령행으로만 받으므로 예외(적재 중 `ps` 노출)

### 01.UNLOAD_PG.sh
1. env 로딩, `psql` 존재 점검, PG 계정·비밀번호 입력 및 접속 확인
2. `${SCRIPT_DIR}/sql/*.sql` 목록을 메뉴로 표시 → 파일 선택
3. 선택한 SQL 내용 미리보기, 끝의 `;` 제거, SELECT/WITH 로 시작하는지 확인
4. `COPY (<SQL>) TO STDOUT WITH (FORMAT csv, HEADER, DELIMITER ',', QUOTE '"', NULL '')` 를
   tmp `.sql` 로 만들어 `psql -f` 실행, 결과를 `csv/<SQL파일명>.csv` 로 저장 (`PGCLIENTENCODING=UTF8`)
   - 같은 이름의 CSV 가 있으면 덮어쓰기 `y/N` 확인
5. 종료코드 확인, 추출 건수·파일 크기·경로를 로그에 기록
   (`COPY ... TO STDOUT` 은 `COPY n` 태그를 출력하지 않으므로 CSV 를 따옴표 짝 기준으로 세어 건수를 구한다)

### 02.LOAD_TARGET.sh
1. env 로딩, `TARGET_DBMS` 에 따라 `sqlplus`+`sqlldr` / `tbsql`+`tbloader` 존재 점검,
   대상 계정·비밀번호 입력 및 접속 확인
2. `${BASE_PATH}/csv/*.csv` 목록을 메뉴로 표시 → 파일 선택
3. 대상 테이블 대화형 입력: `OWNER`, `TABLE_NAME` (대문자 변환, 빈 값이면 재입력)
4. 딕셔너리(`ALL_TAB_COLUMNS`)로 테이블 존재·컬럼 타입 조회
5. CSV 헤더를 읽어 control 파일 생성
   - 헤더 컬럼 순서대로 필드 나열, 헤더 행은 skip
   - `FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'`, `TRAILING NULLCOLS`
   - 대상 타입이 `DATE`/`TIMESTAMP` 인 컬럼은 5장의 포맷 마스크 지정
   - 헤더에 있는데 대상 테이블에 없는 컬럼이 있으면 목록 출력 후 중단
6. 미리보기(CSV 파일, 대상 테이블, 적재 모드, 현재 건수, 컬럼 매핑) → `y/N` 확인
   (`TRUNCATE` 모드는 파괴적 작업이므로 경고 문구 포함)
7. `sqlldr` / `tbloader` 실행, 종료코드 확인
8. 결과 요약: 적재/거부 건수(로더 log 파싱), bad 파일 경로, 적재 후 `count(*)`

## 7. 공통 규약 (저장소 규약 준수)
- `SCRIPT_DIR` 기준 env source, 없으면 즉시 실패. 자격증명 하드코딩 금지
- `_out` / `_log` / `_ok` / `_fail` 로깅 → `${BASE_PATH}/log/<SCRIPT>_<timestamp>.log`
- 임시 파일은 `${BASE_PATH}/tmp/..._$$.*`, `_cleanup` 으로 정리
- 각 DB/로더 호출 후 `$?` / `${PIPESTATUS[0]}` 확인
- 적재만 수행하고 데이터 검증은 DB 제약조건·로더 bad 파일에 맡긴다

## 8. 유의사항
- **빈 문자열 / NULL**: Oracle·Tibero 는 `''` 를 NULL 로 취급 → PG 의 빈 문자열과 NULL 구분이 사라진다(NOT NULL 컬럼 거부 가능)
- **데이터 내 개행**: CSV 따옴표로 감싸지지만 로더는 레코드 내 개행을 기본 처리하지 못함
  → 해당 컬럼은 SQL 에서 `replace()` 로 치환하거나, 레코드 구분자 변경을 구현 시 실데이터로 확인
- **문자셋**: CSV 는 UTF8 고정, 로더 측 `CHARACTERSET` 은 `P2O.env`, `NLS_LANG`(`TB_NLS_LANG`) 은 `env/ORACLE.env`(`env/TIBERO.env`) 에 지정
- **LOB / bytea / json / 배열**: 1차 범위 제외
- **대용량**: 1차는 SQL 1개 = 단일 파일. 분할·병렬은 범위 외

## 9. 구현 순서
1. 클라이언트 설치 확인(3장)
2. `P2O.env.example`, 공통 골격(env·로깅·cleanup·`_select_menu`)
3. `01.UNLOAD_PG.sh` + 샘플 `sql/*.sql`
4. `02.LOAD_TARGET.sh` — Oracle(`sqlldr`) 먼저, 이후 Tibero(`tbloader`) 분기
5. `README.md`
