# P2O_MIG — PostgreSQL → Oracle/Tibero 데이터 마이그레이션

`./sql` 의 추출 SQL 을 골라 PostgreSQL 데이터를 `,` 구분 CSV 로 내려쓰고,
대상 테이블을 입력받아 Oracle(`sqlldr`) / Tibero(`tbloader`) 에 적재한다.
설계는 [`plan/plan.md`](plan/plan.md) 참조.

```
sql/*.sql --선택--> 01.UNLOAD_PG.sh --> csv/<SQL파일명>.csv --선택 + 대상 테이블 입력--> 02.LOAD_TARGET.sh --> Oracle | Tibero
```

## 1. 선행 작업

실행 서버에 아래 클라이언트가 PATH 에 있어야 한다. 없으면 스크립트가 시작하자마자 실패한다.

| 스크립트 | 필요한 명령 |
|----------|-------------|
| `01.UNLOAD_PG.sh` | `psql` |
| `02.LOAD_TARGET.sh` (ORACLE) | `sqlplus`, `sqlldr` |
| `02.LOAD_TARGET.sh` (TIBERO) | `tbsql`, `tbloader` |

```bash
cp P2O.env.example P2O.env    # 접속 정보·옵션 입력 (gitignore 대상)
```

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
./01.UNLOAD_PG.sh      # SQL 선택 → 미리보기 → y/N → csv/<SQL파일명>.csv
./02.LOAD_TARGET.sh    # CSV 선택 → OWNER / TABLE_NAME 입력 → 미리보기 → y/N → 적재
```

목록 선택: `↑`/`↓`(또는 `k`/`j`) 이동, `Enter` 선택, `q` 취소.

`02` 는 적재 전 CSV 건수·현재 건수·컬럼 매핑을 보여주고, 적재 후 건수를 다시 세어
`기대 건수(APPEND = 기존 + CSV, TRUNCATE = CSV)` 와 다르거나 bad 행이 있으면 `[FAIL]` 로 끝난다.

## 4. 산출물 (`${BASE_PATH}`, 비우면 스크립트 디렉토리)

| 경로 | 내용 |
|------|------|
| `csv/<SQL파일명>.csv` | 내려쓴 데이터 (UTF8, 1행 = 헤더) |
| `ctl/<OWNER>.<TABLE>_<시각>.ctl` | 생성된 control 파일 |
| `bad/<OWNER>.<TABLE>_<시각>.bad` | 거부된 행 |
| `log/UNLOAD_PG_*.log`, `log/LOAD_TARGET_*.log` | 스크립트 로그 |
| `log/<OWNER>.<TABLE>_<시각>_sqlldr.log` (`_tbloader.log`) | 로더 로그 |

## 5. 유의사항

- **TRUNCATE 모드**(`LOAD_MODE=TRUNCATE`)는 기존 데이터를 복구할 수 없게 지운다. 기본값은 `APPEND`.
- **빈 문자열 = NULL**: Oracle·Tibero 는 `''` 를 NULL 로 취급한다. PG 의 빈 문자열이 NOT NULL 컬럼에 들어가면 거부된다.
- **데이터 내 개행**: 값에 개행이 있으면 로더가 레코드를 잘못 나눌 수 있다. SQL 에서
  `replace(replace(col, chr(13), ''), chr(10), ' ')` 등으로 치환해서 내린다.
- **지원하지 않는 타입**: 대상 컬럼이 `CLOB`/`BLOB`/`LONG`/`RAW`/`XMLTYPE` 이면 중단한다.
- **CSV 에 없는 대상 컬럼**은 적재하지 않는다(NULL 또는 DEFAULT).
- 데이터 검증은 하지 않는다. DB 제약조건과 로더 bad 파일에 맡긴다.
