# P2O_MIG — PostgreSQL → Oracle/Tibero 데이터 마이그레이션

`./sql` 의 추출 SQL 을 골라 PostgreSQL 데이터를 `,` 구분 CSV 로 내려쓰고,
대상 테이블을 입력받아 Oracle(`sqlldr`) / Tibero(`tbloader`) 에 적재한다.
설계는 [`plan/plan.md`](plan/plan.md) 참조.

쉘은 `00.P2O_MENU.sh` 하나다. 설정 관리 화면과 Unload / Load 모듈이 한 파일에 들어 있다.

```
sql/*.sql --선택--> [Unload 모듈] --> csv/<SQL파일명>.csv (또는 청크 디렉토리)
          --선택 + 대상 테이블 입력--> [Load 모듈] --> Oracle | Tibero
```

## 1. 선행 작업

실행 서버에 아래 클라이언트가 PATH 에 있어야 한다. 없으면 모듈이 시작하자마자 실패한다
(메뉴 상단에 `[psql OK]` / `[sqlplus/sqlldr OK]` 로 점검 결과가 보인다).

| 모듈 | 필요한 명령 |
|------|-------------|
| Unload | `psql` |
| Load (ORACLE) | `sqlplus`, `sqlldr` |
| Load (TIBERO) | `tbsql`, `tbloader` |

```bash
cp P2O.env.example P2O.env                # 접속 정보(호스트/DB/TNS)·옵션 (gitignore 대상, 메뉴가 없으면 생성 제안)
cp env/PG.env.example     env/PG.env      # Unload : PG_HOME / PATH / LD_LIBRARY_PATH
cp env/ORACLE.env.example env/ORACLE.env  # Load (ORACLE) : ORACLE_HOME / PATH / LD_LIBRARY_PATH / NLS_LANG
cp env/TIBERO.env.example env/TIBERO.env  # Load (TIBERO) : TB_HOME / PATH / LD_LIBRARY_PATH / TB_NLS_LANG
```

값은 파일을 직접 고쳐도 되고 메뉴 1~3 에서 고쳐도 된다(env 파일이 없으면 메뉴가 example 로 생성할지 묻는다).

클라이언트 환경변수는 DBMS별 env 파일로 분리한다. `P2O.env` 의 `PG_ENV_FILE` / `ORACLE_ENV_FILE` /
`TIBERO_ENV_FILE` 이 각 파일을 가리키며(상대경로 = 스크립트 디렉토리 기준), 모듈이 클라이언트 점검 전에 source 한다.
Unload 는 `PG_ENV_FILE`, Load 는 `TARGET_DBMS` 에 맞는 파일 하나만 읽는다. 값을 비우면 현재 셸의 PATH 를 그대로 쓴다.
지정했는데 파일이 없으면 즉시 실패한다. 모듈은 서브셸에서 돌기 때문에 source 한 환경변수는 메뉴에 남지 않는다
(Unload 의 PG 환경과 Load 의 Oracle 환경이 섞이지 않는다).

계정·비밀번호는 `P2O.env` 에 두지 않는다. 모듈(또는 접속 테스트)이 시작할 때 입력받고(비밀번호는 화면에 표시 안 됨),
바로 접속을 확인해 실패하면 종료한다.

비밀번호는 `ps` 에 보이지 않도록 명령행 인자로 넘기지 않는다.

| 명령 | 전달 방식 |
|------|-----------|
| `psql` | 환경변수 `PGPASSWORD` |
| `sqlplus` / `tbsql` | 로그인 없이 시작(`/nolog`) 후 표준입력으로 `CONNECT` |
| `sqlldr` | 권한 600 임시 parfile(`userid=`), 적재 직후 삭제 |
| `tbloader` | **예외** — userid 를 명령행으로만 받으므로 적재 중에는 `ps` 에 보인다 |

## 2. 추출 SQL 작성 규칙 (`sql/*.sql`)

파일 1개 = SELECT 1개 = CSV 1개. 예시는 [`sql/SAMPLE_EMP.sql`](sql/SAMPLE_EMP.sql).

- `SELECT` 또는 `WITH` 로 시작하는 문장 1개 (앞쪽 `--` 주석 가능, 끝의 `;` 는 있어도 된다)
- 부분 이관 조건은 `WHERE` 에 직접 쓴다
- **컬럼 alias = 대상 테이블 컬럼명** — CSV 헤더가 되어 적재 시 이름으로 매핑된다(순서 무관, 대소문자 무관)
- 날짜는 고정 포맷 문자열로 변환한다

| 대상 컬럼 타입 | SQL |
|----------------|-----|
| `DATE` | `to_char(col, 'YYYYMMDDHH24MISS')` |
| `TIMESTAMP` | `to_char(col, 'YYYYMMDDHH24MISSUS')` |
| (boolean 등) | `CASE WHEN col THEN 'Y' ELSE 'N' END` |

## 3. 실행

```bash
./00.P2O_MENU.sh           # 메뉴 (P2O.env 가 없으면 P2O.env.example 로 생성할지 묻는다)
./00.P2O_MENU.sh unload    # 메뉴 없이 Unload 모듈만 실행
./00.P2O_MENU.sh load      # 메뉴 없이 Load 모듈만 실행
```

| 메뉴 | 내용 |
|------|------|
| 1. Source | `PG_HOST` / `PG_PORT` / `PG_DB` / `PG_ENV_FILE`, `env/PG.env` 의 `PG_HOME` 수정, psql 접속 테스트 |
| 2. Target | `TARGET_DBMS`(선택) / `DB_TNS` / `ORACLE_ENV_FILE`·`TIBERO_ENV_FILE`, 그 파일의 `ORACLE_HOME`·`TB_HOME`, `NLS_LANG`·`TB_NLS_LANG` 수정, 접속 테스트 |
| 3. Load options | `BASE_PATH`, `LOAD_MODE`, `DIRECT`, `LOAD_ERRORS`, `CHARSET`, 청크 설정 3종 |
| 4. Unload | PG 계정/비밀번호 → SQL 선택 → 미리보기 → y/N → `csv/<SQL파일명>.csv` (또는 청크 디렉토리) |
| 5. Load | 대상 계정/비밀번호 → CSV/청크 디렉토리 선택 → OWNER / TABLE_NAME 입력 → (청크가 여럿이면) 시작 청크 → 미리보기 → y/N → 청크별 적재 |
| 6. Outputs | CSV·청크 디렉토리 목록(크기), 최근 로그 15개 선택 → `less`(없으면 `tail`) |

- 목록 선택: `↑`/`↓`(또는 `k`/`j`) 이동, `Enter` 선택, `q` 뒤로/취소.
- 화면 상단에 현재 Source / Target / 적재 옵션과 클라이언트 점검 결과(`[psql OK]`, `[sqlplus/sqlldr OK]`, `env file missing` 등)를 표시한다.
- 설정 값은 파일의 `KEY=` 줄만 바꿔 쓴다(주석·다른 줄 유지, 없으면 끝에 추가). 입력 형식을 검사하고(포트·숫자·선택지,
  공백·따옴표 등 source 를 깨는 문자 거부) 변경 내역은 `log/P2O_MENU_*.log` 에 남는다.
- 모듈은 서브셸에서 실행된다. 모듈이 실패·취소되거나 `Ctrl+C` 로 중단해도 메뉴로 돌아오고, 결과(rc)가 메뉴 로그에 남는다.
  모듈을 실행할 때마다 `P2O.env` 를 다시 읽으므로 메뉴에서 바꾼 설정이 바로 적용된다.

Load 모듈은 적재 전 CSV 건수·청크 수·현재 건수·컬럼 매핑을 보여준다. 적재 후에는 로더 log 의 적재/거부 건수와
`count(*)` 를 함께 보여주고, `기대 건수(APPEND = 기존 + 적재 대상, TRUNCATE = 적재 대상)` 와 다르면 `[FAIL]` 로 끝난다.
(tbloader log 문구를 못 읽으면 `?` 로 표시)

### 청크 단위 처리 (대용량)

| 설정 (`P2O.env`) | 대상 | 동작 |
|------------------|------|------|
| `UNLOAD_CHUNK_ROWS=N` | Unload | COPY 1회의 출력을 N 행씩 나눠 `csv/<SQL파일명>/<SQL파일명>_00001.csv …` 로 저장. 모든 청크에 헤더 포함, 레코드(따옴표 안 개행 포함)는 쪼개지 않는다. 진행 상황이 청크마다 출력된다 |
| `LOAD_CHUNK_ROWS=N` | Load | 단일 CSV 를 N 행씩 tmp 청크로 나눠 적재 (청크 디렉토리는 이 값과 무관하게 Unload 의 청크 그대로 적재) |
| `LOAD_COMMIT_ROWS=N` | Load | 로더 `rows=` (커밋/데이터 저장 단위). 비우면 로더 기본값 |

- `0`(기본)이면 나누지 않는다 — CSV 1개, 로더 1회.
- Load 는 청크마다 로더를 1회 실행하고 **rc ≠ 0, bad 행, 로그상 적재 건수 ≠ 청크 건수** 중 하나라도 있으면 그 청크에서 멈춘다.
  `LOAD_ERRORS` 는 청크(로더 실행)마다 적용된다.
- **재개**: 같은 CSV(·같은 `LOAD_CHUNK_ROWS`)로 다시 실행해 `Start from chunk` 에 실패한 청크 번호를 입력한다.
  실패한 청크에서 이미 커밋된 행(로그의 loaded 건수)은 재개 시 다시 들어가므로 먼저 지운다.
- `LOAD_MODE=TRUNCATE` 는 첫 청크에만 적용되고 나머지는 APPEND. 2 이상에서 재개하면 TRUNCATE 하지 않는다.
- 단일 CSV 를 `LOAD_CHUNK_ROWS` 로 나누면 `${BASE_PATH}/tmp` 에 CSV 크기만큼 공간이 더 필요하다(종료 시 삭제).

## 4. 산출물 (`${BASE_PATH}`, 비우면 스크립트 디렉토리)

| 경로 | 내용 |
|------|------|
| `csv/<SQL파일명>.csv` | 내려쓴 데이터 (UTF8, 1행 = 헤더) |
| `csv/<SQL파일명>/<SQL파일명>_NNNNN.csv` | `UNLOAD_CHUNK_ROWS > 0` 일 때의 청크 파일 (같은 SQL 을 다시 내리면 단일/청크 결과 모두 교체) |
| `ctl/<OWNER>.<TABLE>_<시각>.ctl` (`_APPEND.ctl`) | 생성된 control 파일 (TRUNCATE + 청크면 2번째 청크부터 `_APPEND`) |
| `bad/<OWNER>.<TABLE>_<시각>[_NNNNN].bad` | 거부된 행 (청크가 여럿이면 청크 번호 접미사) |
| `log/UNLOAD_PG_*.log`, `log/LOAD_TARGET_*.log` | Unload / Load 모듈 로그 (실행 1회당 1개) |
| `log/P2O_MENU_*.log` | 메뉴 로그: 설정 변경(`SET KEY : 이전 -> 새 값`), 접속 테스트, 모듈 실행/종료(rc) |
| `log/<OWNER>.<TABLE>_<시각>[_NNNNN]_sqlldr.log` (`_tbloader.log`) | 로더 로그 |

## 5. 유의사항

- **TRUNCATE 모드**(`LOAD_MODE=TRUNCATE`)는 기존 데이터를 복구할 수 없게 지운다. 기본값은 `APPEND`.
- **빈 문자열 = NULL**: Oracle·Tibero 는 `''` 를 NULL 로 취급한다. PG 의 빈 문자열이 NOT NULL 컬럼에 들어가면 거부된다.
- **데이터 내 개행**: 값에 개행이 있으면 로더가 레코드를 잘못 나눌 수 있다. SQL 에서
  `replace(replace(col, chr(13), ''), chr(10), ' ')` 등으로 치환해서 내린다.
- **지원하지 않는 타입**: 대상 컬럼이 `CLOB`/`BLOB`/`LONG`/`RAW`/`XMLTYPE` 이면 중단한다.
- **CSV 에 없는 대상 컬럼**은 적재하지 않는다(NULL 또는 DEFAULT).
- 데이터 검증은 하지 않는다. DB 제약조건과 로더 bad 파일에 맡긴다.
