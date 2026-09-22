# DATA_MIG

`DBADM.DBM_MIG_MSTR` 제어 테이블 기준으로 DB LINK `INSERT INTO ... SELECT` 데이터 마이그레이션을 수행하는 Bash + SQL 도구.

- Oracle(sqlplus) / Tibero(tbsql) 이기종 가능, **일반 SQL 만** 사용 (프로시저 / PL/SQL 금지)
- 쉘은 **타겟 DB 에만 접속**, 소스는 `@SRC_DBLINK` 로 읽음 (제어 테이블은 타겟 DB)
- 메뉴 방식, 백그라운드(nohup) 실행, 테이블 병렬 실행, 실패 재수행, 통합 로그 / 대시보드
- 상세 사양 : [`MIG_RUN_PLAN.md`](MIG_RUN_PLAN.md) (이관), [`COL_MAP_PLAN.md`](COL_MAP_PLAN.md) (컬럼 매핑)

---

## 1. 구성

| 구분 | 파일 | 설명 |
|---|---|---|
| 제어 테이블 DDL | `DDL_Script/DBM_MIG_MSTR.sql` | 이관 대상 테이블 목록 / 조건 |
| | `DDL_Script/DBM_MIG_COL_MAP.sql` | 컬럼 매핑 (컬럼명 변경 / 추가 테이블) |
| | `DDL_Script/DBM_XDN_LOG.sql` | 이관 실행 이력 |
| 적재 쉘 | `01.LOAD_MIG_MSTR.sh <CSV>` | DBM_MIG_MSTR CSV 적재 |
| | `03.LOAD_COL_MAP.sh <CSV>` | DBM_MIG_COL_MAP CSV 적재 |
| 이관 쉘 | `02.RUN_MIG.sh` | SQL 작성 / 이관 / 재수행 / 모니터링 메뉴 |
| 설정 | `MIG.env` (`MIG.env.example` 복사) | 접속 정보 / MSTR_ID / DB LINK / 옵션 (gitignore) |
| | `MIG_HINT.conf` | WORKER / PARALLEL 차수 (메뉴 [h] 에서 저장, 자동 생성) |
| 샘플 | `DBM_MIG_MSTR_sample.csv`, `DBM_MIG_COL_MAP_sample.csv` | CSV 양식 |
| 산출물 | `${MIG_HOME}/cmd/PRE1`, `cmd/PRE2`, `cmd/DDAY` | 이관 SQL (`.out`) |
| | `${MIG_HOME}/log` | 통합 로그 `MIG_TOTAL.log`, 실행별 로그, 적재 로그 |
| | `${MIG_HOME}/tmp` | 임시 SQL / DB 출력 |
| | `${MIG_HOME}/run` | 백그라운드 worker 임시 실행 sh (종료 시 삭제) |

## 2. 준비

### 요구사항
- bash, `sqlplus`(ORACLE) 또는 `tbsql`(TIBERO) 가 PATH 에 있을 것
- `nohup`, `ps -eo pid=,ppid=,args=`, GNU `tail -F`
- 실행 계정 : 제어 테이블 DML, 타겟 테이블 INSERT, `ALL_TAB_COLUMNS` 조회, 소스 DB LINK 조회 권한
- 실행권한(+x) 불필요 : `bash 02.RUN_MIG.sh` 로 실행

### 제어 테이블 생성
`DDL_Script/*.sql` 3개를 타겟 DB 에 `DBADM` 스키마로 생성한다.

### MIG.env
```bash
cp MIG.env.example MIG.env   # 값 채우기, 자격증명은 이 파일에만
```

| 항목 | 설명 |
|---|---|
| `DB_TYPE` | `ORACLE` / `TIBERO` |
| `DB_USER` / `DB_PASS` / `DB_TNS` | 접속 정보 (`DB_TNS` 비우면 로컬 기본) |
| `MSTR_ID` | 이관할 `DBM_MIG_MSTR.MSTR_ID` |
| `SRC_DBLINK` | 소스 DB LINK 명 (`FROM OWNER.TABLE@SRC_DBLINK`) |
| `HEARTBEAT_SEC` | 테이블 실행 중 `RUNNING` 로그 간격 (기본 300) |
| `MIG_HOME` | 01 / 02 / 03 공통 작업 경로 (비우면 스크립트 디렉토리). 아래에 `cmd` / `log` / `tmp` / `run` 자동 생성 |
| `MIG_COLOR` | 화면 색상 : 비움 = 자동, `Y` 강제, `N` 끔 |
| `SQL_REFRESH` | `Y` : 이관 / 재수행 시 테이블 실행 직전 SQL 재생성, `N` 또는 비움(기본) : `.out` 그대로 실행 |
| `SPLIT_UNIT` / `SPLIT_SIZE` | 날짜 조건 분할 `DAY` / `MONTH` / `YEAR` + 간격, `NONE` 또는 비움(기본) : 테이블당 SQL 1개 |
| `PRE_COND_COL` / `DDAY_COND_COL` | 단계별 조건 컬럼명을 담은 `DBM_MIG_MSTR` 컬럼 (기본 둘 다 `COL_CONDITION`) |

## 3. 작업 흐름

```
① DBM_MIG_MSTR CSV 적재        bash 01.LOAD_MIG_MSTR.sh DBM_MIG_MSTR.csv
② (컬럼 변경 테이블) 매핑 적재   bash 03.LOAD_COL_MAP.sh DBM_MIG_COL_MAP.csv
③ 메뉴 실행                    bash 02.RUN_MIG.sh
   [R] → [1] PRE SQL 작성  → 차수 [1] 1차 (PRE1~PRE2) / [2] 2차 (PRE2~PRE3)
   [R] → [2] PRE 이관 (차수 선택) → (실패 시) [3] PRE 재수행 (차수 선택)
   [R] → [4] DDAY SQL 작성 → [5] DDAY 이관 → (실패 시) [6] DDAY 재수행
   조건 컬럼이 있는 테이블은 1차 → 2차 → DDAY 세 번, 없으면 DDAY 한 번
```

### ① / ② CSV 적재
- 쉼표 구분, 첫 줄 = 컬럼명 (순서 자유), 쉼표가 있는 값은 `"..."`
- 미리보기 → `y/N` 확인 → 적재, 오류 시 **전체 ROLLBACK**
- **쉘에서 검증하지 않는다** (중복 / NOT NULL / 형식은 DB 제약조건에 맡김), 빈 값은 NULL
- `01` : INSERT 만, `TAB_SIZE` / `LOB_SIZE` 는 숫자로. 기본값 `TRANS_YN=N PARTITION_YN=N MIG_YN=Y MIG_METHOD=DB_LINK SRC=ASIS TGT=TOBE`
- `03` : CSV 에 나온 테이블 쌍(SRC → TGT)의 기존 매핑을 DELETE 후 INSERT, 이름 컬럼은 대문자 변환

## 4. 이관 규칙

대상 : `MSTR_ID = MIG.env 의 MSTR_ID` AND `MIG_YN = 'Y'`

| MIG_TYPE | MIG_FULL | PRE 단계 | DDAY 단계 |
|---|---|---|---|
| 조건 컬럼 있음 | PRE 1차 : `>= 'PRE1' AND < 'PRE2'` , PRE 2차 : `>= 'PRE2' AND < 'PRE3'` | DDAY : `>= 'PRE3'` |
| 조건 컬럼 없음 | 대상 아님 | DDAY : 조건 없이 전체 |

| TRANS_YN | 이관 SQL |
|---|---|
| N | `INSERT INTO TGT SELECT * FROM SRC@SRC_DBLINK` |
| Y | 타겟 `ALL_TAB_COLUMNS` 순서로 컬럼 명시. `DBM_MIG_COL_MAP` 의 `RENAME` → `SRC_COL`, `ADD` → `DEFAULT_VAL` (NULL 이면 제외) |

- 조건 컬럼은 단계별로 `MIG.env` `PRE_COND_COL` / `DDAY_COND_COL` 이 가리키는 MSTR 컬럼 값 (기본 둘 다 `COL_CONDITION`). 비교 연산자는 고정(`>=` 하한 / `<` 상한)이라 단계가 경계에서 겹치거나 빠지지 않는다
- 테이블명 / OWNER 변경 : `SRC_OWNER.SRC_TABLE_NAME → TGT_OWNER.TGT_TABLE_NAME`
- 매핑은 **바뀐 컬럼만** 등록 (N:1 병합은 소스별 매핑 가능, 1:N 은 컬럼 분할만)
- SQL 파일 : `cmd/{PRE|DDAY}/{TGT_OWNER}_{TGT_TABLE_NAME}__{SRC_OWNER}_{SRC_TABLE_NAME}.out` (헤더 주석 + INSERT + COMMIT, 힌트 없음)

## 5. 02.RUN_MIG.sh 메뉴

키 하나로 이동 (Enter 불필요, `y/N` 확인 / [h] 입력 / [l] 의 `q` 는 Enter 필요)

| 키 | 기능 |
|---|---|
| `[R]` | Run 하위 메뉴 : `[1]`~`[3]` PRE 작성 / 이관 / 재수행, `[4]`~`[6]` DDAY 작성 / 이관 / 재수행, `[b]` 돌아가기 |
| `[l]` | Total Log : 통합 로그 `tail -F` (`q` + Enter 로 복귀) |
| `[s]` | Status : `DBM_XDN_LOG` 건수 / 진행률 / 실행 중 테이블 / FAIL 목록 |
| `[S]` | Stop : 새 테이블 시작 중지, 돌고 있는 테이블은 끝까지 진행 |
| `[h]` | Hint : `WORKER_DEGREE`(동시 테이블 수, 기본 1) / `PARALLEL_DEGREE`(기본 4), 실행 중에도 반영 |
| `[U]` | Unlock : worker 가 없을 때 남은 락 제거 + RUNNING 행을 FAIL 로 |
| `[q]` | 메뉴 종료 (백그라운드 이관은 계속) |

메뉴 상단 상태 : `* RUNNING`(대시보드 : WORKER x PARALLEL, SUCCESS / FAIL / SKIP / WAIT, 슬롯별 테이블 / 경과), `* STALE`, `* IDLE`

### 실행 방식
- 이관 / 재수행은 미리보기 + `y/N` 후 **백그라운드(nohup + 새 세션)** 로 실행, 메뉴를 나가도 계속 진행
  - 새 세션(setsid / perl / python)으로 띄우므로 터미널 Ctrl+C 가 worker 와 `sqlplus` / `tbsql` 에 전달되지 않는다 (같은 그룹이면 실행 중 INSERT 가 ORA-01013 으로 취소됨). 시작 메시지와 로그 헤더의 `SESSION=` 에서 확인
- 한 번에 **하나의 실행**만 (실행 여부 = worker 프로세스 + `log/.run.lock`)
- 실행 안에서 **WORKER 개 테이블 동시 실행**, `TAB_SIZE` 작은 테이블부터. DB 부하 최대 `WORKER x PARALLEL`
- 실행 시 힌트 적용 : `INSERT /*+ APPEND PARALLEL(n) */`, `SELECT /*+ PARALLEL(n) */`, `ALTER SESSION ENABLE PARALLEL DML`
- **INSERT 만** 수행 (TRUNCATE / DELETE 없음) → 같은 단계를 다시 이관하면 중복 적재, 실패 건은 재수행 메뉴 사용
- 재수행 : 해당 단계 최근 RUN_ID 의 FAIL 행만 같은 행을 갱신

### SQL_REFRESH (이관 직전 SQL 재생성)
| 값 | 동작 |
|---|---|
| `N` / 미설정 (기본) | `cmd/{PHASE}/*.out` 그대로 실행 (직접 수정 반영), 재수행 시 파일 없으면 FAIL |
| `Y` | 테이블마다 실행 직전 MSTR(+COL_MAP) 재조회 → `.out` 덮어쓰기 (변경 시 `.bak`), 파일이 없어도 생성, 더 이상 대상이 아니면 **SKIP** (DBM_XDN_LOG 행 유지) |

### SPLIT_UNIT (날짜 조건 분할)
| 값 | 동작 |
|---|---|
| `NONE` / 미설정 (기본) | 테이블당 `.out` 1개 (기존) |
| `DAY` / `MONTH` / `YEAR` + `SPLIT_SIZE` | SQL 작성 시 날짜 조건을 청크 파일(`..__C0001.out`)로 분할. PRE `[PRE1, PRE2)`, DDAY `[PRE3, 오늘]` + 마지막 열린 구간 |

- 날짜 형식은 PRE 값 모양으로 자동 판별 (`20250101`, `2025-01-01`, `202501` …), VARCHAR / DATE 컬럼 모두 기존과 같은 문자 비교
- 날짜로 볼 수 없는 조건은 분할하지 않고 `[WARN] not split` 표시
- `DBM_XDN_LOG` 에 청크마다 1행 (`CHUNK_NO`, `CHUNK_COND` 컬럼 필요), 실패한 청크만 재수행
- 청크는 `INSERT /*+ NOAPPEND */` (PARALLEL DML 없음) 로 실행해 같은 테이블의 청크도 동시에 실행

## 6. 로그 / 이력

| 위치 | 내용 |
|---|---|
| `log/MIG_TOTAL.log` | 통합 로그 : GEN / RUN / RETRY 시작, 이벤트(`HH:MI:SS [Wn] START / RUNNING / SUCCESS / FAIL / SKIP`), 테이블 블록, 완료 |
| `log/{RUN\|RETRY}_{PHASE}_{MSTR_ID}_R{RUN_ID}_{시각}.log` | 실행 1회 진행 로그 |
| `log/..._detail.log` | 실행 SQL(힌트 포함) + DB 클라이언트 출력 |
| `log/..._worker.err` | worker 시작 / 쉘 오류 |
| `log/GEN_{PHASE}_{MSTR_ID}_{시각}.log` | SQL 작성 로그 |
| `DBADM.DBM_XDN_LOG` | 테이블별 `PENDING → RUNNING → SUCCESS / FAIL`, 건수(SRC / TGT), START / END / ELAPSED_TIME, ERROR_MSG |

- 색상은 화면에만 (로그 파일은 plain) : 메뉴 밖에서 `bash 02.RUN_MIG.sh --tail [로그파일]` 또는 `tail -f <로그> | bash 02.RUN_MIG.sh --color`

## 7. 주의사항

1. 이관 중인 프로세스를 `kill` 하지 말고 **[S] Stop** 사용. 이미 죽었다면 DB 세션 종료 확인 후 **[U] Unlock** → 재수행
2. `SQL_REFRESH=Y` 면 `.out` 직접 수정 / 직접 넣은 힌트는 유지되지 않음 (조건 / 매핑은 제어 테이블에서 수정)
3. N:1 병합 시 소스 간 PK 중복은 `ORA-00001` FAIL
4. `APPEND` 적재 중 타겟 테이블 잠김, DB LINK 원격 SELECT 의 PARALLEL 은 제한될 수 있음
5. Tibero : `tbsql` 힌트 / `ENABLE PARALLEL DML` 문법, 건수 메시지 형식은 버전별 확인
6. 한글 CSV 는 `NLS_LANG` / `TB_NLS_LANG` 을 CSV 인코딩과 맞춤
