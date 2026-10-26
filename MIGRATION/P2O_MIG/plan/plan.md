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
각 모듈은 해당 env 파일을 source 한 뒤(Unload = PG, Load = `TARGET_DBMS` 에 맞는 1개)
`command -v` 로 필요한 명령을 점검하고, 파일이나 명령이 없으면 안내 후 즉시 실패한다.

## 4. 파일 구성

| 파일 | 용도 |
|------|------|
| `P2O.env` (gitignore) / `P2O.env.example` | 접속 정보·경로·옵션, 클라이언트 env 파일 경로 |
| `env/PG.env` / `env/ORACLE.env` / `env/TIBERO.env` (gitignore, `*.env.example` 템플릿) | 클라이언트 환경변수(`*_HOME`, `PATH`, `LD_LIBRARY_PATH`, `NLS_LANG`/`TB_NLS_LANG`) |
| `sql/*.sql` | 추출 SQL (파일 1개 = SELECT 1개 = CSV 1개) |
| `P2O.sh` | 유일한 쉘. 메뉴(Source / Target / 적재 옵션 설정 관리, 접속 테스트, 산출물·로그 조회) + Unload / Load 모듈 |
| `README.md` | 사용법·SQL 작성 규칙·예시 |

`P2O.sh` 내부 구성:

| 구역 | 함수 |
|------|------|
| 공통 입력 | `_select_menu`, `_ask_name`, `_ask_login` |
| 공통 설정 파일 | `_env_get`, `_env_set`, `_abs_path`, `_client_env` |
| 공통 CSV | `_rec_count`, `_rows_per_file`, `_split_csv` |
| 공통 클라이언트·로그인 | `_load_pg_client`, `_pg_login`, `_load_tgt_client`, `_run_sql`, `_has_db_error`, `_tgt_login` |
| Unload 모듈 | `_unload_run`, `_unload_cleanup` |
| Load 모듈 | `_load_run`, `_load_cleanup`, `_count_target`, `_ldr_count`, `_write_ctl`, `_run_loader` |
| 메뉴 | `_edit_field`, `_edit_client_var`, `_client_status`, `_test_source`, `_test_target`, `_screen_*`, `_menu_module` |

모듈은 `_run_module` 이 서브셸 `( _<module>_run )` 로 실행한다: 모듈 안의 `exit` 는 모듈만 끝내고,
모듈이 source 하는 클라이언트 env(PATH / LD_LIBRARY_PATH / NLS) 와 trap·로그 파일 전환이 메뉴에 남지 않는다.
모듈은 시작할 때 `P2O.env` 를 다시 읽는다(메뉴에서 바꾼 값 반영). `P2O.sh unload|load` 로 메뉴 없이 실행 가능.

`P2O.env` 주요 항목: `PG_ENV_FILE/ORACLE_ENV_FILE/TIBERO_ENV_FILE`, `PG_HOST/PG_PORT/PG_DB`, `DB_TNS`,
`TARGET_DBMS`(`ORACLE`|`TIBERO`), `BASE_PATH`, `LOAD_MODE`(`APPEND`|`TRUNCATE`), `DIRECT`(`Y`|`N`), `LOAD_ERRORS`, `CHARSET`,
`UNLOAD_CHUNK_ROWS`, `LOAD_CHUNK_ROWS`, `LOAD_COMMIT_ROWS` (청크 — 6장)

계정·비밀번호는 env 에 두지 않고 모듈·접속 테스트 시작 시 대화형으로 입력받는다(`_ask_login`, 비밀번호는 `read -s`).

디렉토리: `${BASE_PATH}/csv`, `/ctl`, `/log`, `/bad`, `/tmp`

## 5. 추출 SQL 작성 규칙 (`sql/*.sql`)
- SELECT(또는 WITH) 문 1개만 작성. WHERE 로 부분 이관 조건을 직접 기술
- **컬럼 alias = 대상 테이블 컬럼명** (CSV 헤더로 내려가 적재 시 이름 기준 매핑에 사용)
- 날짜는 SQL 에서 고정 포맷 문자열로 변환
  - 대상 `DATE` → `to_char(col,'YYYYMMDDHH24MISS')`
  - 대상 `TIMESTAMP` → `to_char(col,'YYYYMMDDHH24MISSUS')`
- `boolean` 등 대상에 없는 타입도 SQL 에서 변환 (`CASE WHEN col THEN 'Y' ELSE 'N' END`)

## 6. 동작

### 공통: 방향키 선택 메뉴 `_select_menu`
- 목록을 출력하고 `↑`/`↓`(및 `k`/`j`)로 커서 이동, `Enter` 선택, `q` 취소
- `read -rsn1` + ESC 시퀀스 처리, 선택 행 반전 표시(순수 bash, 외부 도구 불필요)
- 목록이 비어 있으면 안내 후 종료

### 공통: 계정 입력 `_ask_login`
- 계정·비밀번호를 빈 값이 아닐 때까지 입력받는다. 비밀번호는 화면·로그에 남기지 않는다
- 입력 직후 접속 확인(`_pg_login` = PG `SELECT version()`, `_tgt_login` = 대상 `SELECT ... FROM DUAL`), 실패하면 모듈 종료
  (모듈과 메뉴 접속 테스트가 같은 함수를 쓴다)
- 비밀번호는 명령행 인자(`ps` 노출)로 넘기지 않는다: `psql` 은 `PGPASSWORD`, `sqlplus`/`tbsql` 은
  로그인 없이 시작 후 표준입력 `CONNECT`, `sqlldr` 은 권한 600 tmp parfile.
  `tbloader` 는 userid 를 명령행으로만 받으므로 예외(적재 중 `ps` 노출)

### 메뉴
- `P2O.env` 가 없으면 `P2O.env.example` 로 생성할지 확인
- 상단에 현재 설정 요약 + 클라이언트 점검 결과(서브셸에서 env 파일 source 후 `command -v`)
- 1 Source / 2 Target / 3 적재 옵션 화면: 항목 선택 → 새 값 입력(Enter = 유지, `-` = 비움) 또는 선택지 메뉴
  - `P2O.env` / `env/*.env` 의 `KEY=`(`export KEY=`) 줄만 교체, 주석·줄바꿈(CRLF 포함) 유지, 없으면 추가
  - 값 검사: 포트·숫자·선택지, source 를 깨는 문자(공백·따옴표·`` ` ``·`;&|<>\`) 거부. 변경은 메뉴 로그에 기록
  - 클라이언트 env 파일이 없으면 `env/*.env.example` 로 생성할지 확인
  - 접속 테스트: 서브셸에서 모듈과 같은 `_load_*_client` + `_*_login` 실행(계정·비밀번호 저장 안 함)
- 4·5: Unload / Load 모듈 실행(서브셸), 실행·종료(rc)를 메뉴 로그에 기록. `Ctrl+C` 는 모듈만 중단(메뉴는 `trap ':' INT`)
- 6: CSV·청크 디렉토리·최근 로그 조회

### Unload 모듈 (`_unload_run`)
1. `P2O.env` 재로딩, `_load_pg_client`(PG env source, `psql` 점검), `_pg_login`
2. `${SCRIPT_DIR}/sql/*.sql` 목록을 메뉴로 표시 → 파일 선택
3. 선택한 SQL 내용 미리보기, 끝의 `;` 제거, SELECT/WITH 로 시작하는지 확인
4. `COPY (<SQL>) TO STDOUT WITH (FORMAT csv, HEADER, DELIMITER ',', QUOTE '"', NULL '')` 를
   tmp `.sql` 로 만들어 `psql -f` 실행, 결과를 `csv/<SQL파일명>.csv` 로 저장 (`PGCLIENTENCODING=UTF8`)
   - 같은 이름의 CSV 가 있으면 덮어쓰기 `y/N` 확인
5. 종료코드 확인, 추출 건수·파일 크기·경로를 로그에 기록
   (`COPY ... TO STDOUT` 은 `COPY n` 태그를 출력하지 않으므로 CSV 를 따옴표 짝 기준으로 세어 건수를 구한다)
6. 청크(`UNLOAD_CHUNK_ROWS > 0`): COPY 출력(1회, 단일 스냅샷)을 awk 로 받아 N 행마다 새 파일로 나눈다
   - `csv/<SQL파일명>/<SQL파일명>_00001.csv …`, 모든 청크 1행 = 헤더, 레코드 경계(따옴표 짝)에서만 자른다
   - 숨김 `.partdir` 에 쓰고 성공 시 rename, 청크마다 진행 줄 출력
   - 같은 SQL 의 이전 결과(단일 CSV·청크 디렉토리)는 덮어쓰기 확인 후 모두 교체

### Load 모듈 (`_load_run`)
1. `P2O.env` 재로딩, `_load_tgt_client`(`TARGET_DBMS` 에 따라 env source, `sqlplus`+`sqlldr` / `tbsql`+`tbloader` 점검),
   `_tgt_login`
2. `${BASE_PATH}/csv/*.csv` 와 청크 디렉토리(`csv/*/`) 목록을 메뉴로 표시 → 선택
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
9. 청크 적재
   - 적재 단위 = 청크 파일 1개 = 로더 1회. 청크 디렉토리는 그대로, 단일 CSV 는 `LOAD_CHUNK_ROWS > 0` 이고
     그보다 많으면 tmp 로 분할(종료 시 삭제). control 파일은 `INFILE` 없이 만들고 청크는 `data=` 로 넘긴다
   - 디렉토리의 모든 청크 헤더가 같은지 확인(control 파일 1개 공유)
   - 청크가 여럿이면 시작 청크 입력(재개). `TRUNCATE` 는 시작 청크가 1일 때 첫 청크에만, 이후는 `_APPEND.ctl`
   - 청크마다 rc / bad 행 / 로그상 적재 건수 = 청크 건수 확인, 하나라도 어긋나면 중단하고 재개 번호 안내
     (conventional path 는 중간 커밋이 있어 실패 청크의 일부 행이 남을 수 있음 → 안내 문구로 표시)
   - `LOAD_COMMIT_ROWS` → 로더 `rows=`

## 7. 공통 규약 (저장소 규약 준수)
- `SCRIPT_DIR` 기준 env source, 없으면 즉시 실패. 자격증명 하드코딩 금지
- `_out` / `_log` / `_ok` / `_fail` 로깅 → `${BASE_PATH}/log/<이름>_<timestamp>.log`
  (메뉴 = `P2O_MENU_*`, 모듈은 서브셸 안에서 `LOGFILE` 을 `UNLOAD_PG_*` / `LOAD_TARGET_*` 로 바꿔 쓴다)
- 임시 파일은 `${BASE_PATH}/tmp/..._$$.*`, 메뉴 `_cleanup` / 모듈 `_unload_cleanup`·`_load_cleanup`(서브셸 EXIT trap) 으로 정리
- 각 DB/로더 호출 후 `$?` / `${PIPESTATUS[0]}` 확인
- 적재만 수행하고 데이터 검증은 DB 제약조건·로더 bad 파일에 맡긴다

## 8. 유의사항
- **빈 문자열 / NULL**: Oracle·Tibero 는 `''` 를 NULL 로 취급 → PG 의 빈 문자열과 NULL 구분이 사라진다(NOT NULL 컬럼 거부 가능)
- **데이터 내 개행**: CSV 따옴표로 감싸지지만 로더는 레코드 내 개행을 기본 처리하지 못함
  → 해당 컬럼은 SQL 에서 `replace()` 로 치환하거나, 레코드 구분자 변경을 구현 시 실데이터로 확인
- **문자셋**: CSV 는 UTF8 고정, 로더 측 `CHARACTERSET` 은 `P2O.env`, `NLS_LANG`(`TB_NLS_LANG`) 은 `env/ORACLE.env`(`env/TIBERO.env`) 에 지정
- **LOB / bytea / json / 배열**: 1차 범위 제외
- **대용량**: 행 수 기준 청크 분할(6장)로 대응. 병렬 적재와 기간·키 범위 분할(SQL 파일 여러 개로 수동)은 범위 외

## 9. 구현 순서
1. 클라이언트 설치 확인(3장)
2. `P2O.env.example`, 공통 골격(env·로깅·cleanup·`_select_menu`)
3. Unload 모듈 + 샘플 `sql/*.sql`
4. Load 모듈 — Oracle(`sqlldr`) 먼저, 이후 Tibero(`tbloader`) 분기
5. 메뉴(설정 관리·접속 테스트·산출물) — 처음엔 `01.UNLOAD_PG.sh` / `02.LOAD_TARGET.sh` 별도 쉘이었고 메뉴 도입 후 모듈로 통합
6. `README.md`
