# Claude Code 요청 / 응답 기록

## 2026-09-15

### 1. MIGRATION 단계별 시작 / 진행 / 완료 통합 LOG 확인
- 요청 : 단계별 시작, 진행, 완료가 통합 LOG 에 찍히는지 확인
- 확인 : 통합 LOG 없음. 단계마다 파일이 따로이고(GEN_ / RUN_ / RETRY_), `[l] Total Log` 는 최근 실행 파일 하나만 표시, 시작 직후 오류는 완료 블록이 없었음
- 응답 : `./log/MIG_TOTAL.log` 통합 LOG 추가 (`02.RUN_MIG.sh`)
  - GEN / RUN / RETRY 의 시작 헤더, 테이블 블록, Running / Progress, `[END]` (DONE / STOPPED / ERROR / ABORT) 를 한 파일에 append
  - 메뉴 조작(미리보기, 취소, Stop 요청, Hint 변경)은 기록하지 않음
  - 시작 직후 오류도 `[END] ... RESULT=ERROR` 기록
  - `[l] Total Log` 는 `MIG_TOTAL.log` 를 `tail -F`
  - `MIG_RUN_PLAN.md` 5장 / 10장 반영

### 2. 메뉴 선택 Enter 없이 이동, 메뉴 표시 시 화면 Clear
- 요청 : 메뉴 Select 할 때 Enter 없이 이동, 메뉴를 보여줄 때 화면 Clear
- 결정 : 작업 결과는 아무 키 입력 시 메뉴 복귀 / y/N 확인은 Enter 유지 / `[l]` 은 q + Enter 유지 / 메뉴 자동 갱신 안 함
- 응답 : `02.RUN_MIG.sh` 메인 메뉴, `[R]` Run 하위 메뉴 수정
  - 메뉴 키는 Enter 없이 한 글자로 선택 (Enter 만 누르면 무시, 방향키 / ESC 는 잘못된 선택)
  - 메뉴를 그릴 때마다 화면 Clear (터미널일 때만), 잘못된 선택 메시지는 다시 그린 메뉴 아래 표시
  - 작업 후 `Press any key to return to the menu ...` 에서 아무 키 → Clear → 메뉴
  - Enter 필요 유지 : y/N 확인, `[h]` 차수 입력, `[l]` 의 q + Enter
  - `MIG_RUN_PLAN.md` 4장 반영

### 3. Running Session 이 있는데 메뉴에 IDLE 표시
- 요청 : 이관 세션이 돌고 있는데 메뉴가 IDLE 로 나옴 (확인 : DB 세션 / ps 의 worker / [s] Status RUNNING 행 모두 있음, 같은 서버 / 같은 계정)
- 원인 : 실행 여부를 락 파일의 PID(`kill -0`) 하나로만 판단하고, 확인에 실패하면 **락 파일을 삭제**했음. 락이 없어지거나 PID 가 달라지면 worker 가 살아 있어도 IDLE 이 되고 두 번째 실행까지 가능했음 (현장 케이스의 정확한 계기는 진단 명령 결과 미확인)
- 응답 : `02.RUN_MIG.sh` 수정 (방식 : 락 자동 삭제 금지 + DB 교차 확인)
  - 실행 판단을 실제 worker 프로세스(`ps -eo pid=,ppid=,args=`) 기준으로 변경, 상태 확인은 락을 지우지 않음
  - worker 가 시작 시 자기 PID 를 락에 기록, 락 없음 / PID 불일치는 프로세스 기준으로 복구 후 `warning` 표시
  - 상태 3가지 : RUNNING / STALE(락만 있고 worker 없음) / IDLE
  - 이관 / 재수행은 STALE 이거나 `DBM_XDN_LOG` 에 RUNNING 행이 남아 있어도 막음
  - `[U] Unlock` 추가 : worker 없을 때만, 이전 worker 의 DB 클라이언트가 살아 있으면 거부, 확인 후 락 삭제 + RUNNING 행 → FAIL, 통합 로그에 `[UNLOCK]` 기록
  - `MIG_RUN_PLAN.md` 4 / 6 / 9 / 10 / 11장 반영

### 4. [FAIL] Background worker did not start
- 요청 : 이관 시작 시 `[FAIL] Background worker did not start` 발생
- 원인 (코드 기준, 현장 출력 미확인)
  - 3번 수정의 시작 확인이 `ps` 인자에서 `--worker` + 로그 경로를 찾아야만 성공 → `ps` 가 긴 인자를 자르는 OS 에서는 살아 있는 worker 도 못 찾음
  - worker 출력이 `/dev/null` 이라 실제 시작 실패(환경 / PATH 오류 등) 원인이 보이지 않음
  - 실패 처리에서 살아 있는 worker 의 락도 지울 수 있었음
- 응답 : `02.RUN_MIG.sh` 수정
  - `_is_worker_pid` 추가 : PID 생존(좀비 제외) + 인자에 스크립트명 / `--worker` (인자가 없거나 잘렸으면 생존만으로 인정)
  - `ps` 목록에서 못 찾아도 락 PID 가 살아 있으면 RUNNING (`warning : ... not matched by ps args`)
  - worker 시작 출력을 `..._worker.err` 에 저장 (끝날 때 비어 있으면 삭제), 시작 실패 시 진단(프로세스 생존, ps 인자, 시작 출력, 로그 끝) 표시
  - 락은 PID 가 죽어 있을 때만 삭제
  - 테스트 : 정상 / ps 인자 80자 절단 / worker 시작 실패 3가지 확인
  - `MIG_RUN_PLAN.md` 6장 / 10장 반영

### 5. DBADM.DBM_MIG_MSTR 을 왜 못 찾아 (TBR-8033)
- 요청 : 테이블에 데이터 / 권한 있는데 `[FAIL] Failed to read DBADM.DBM_MIG_MSTR` / `TBR-8033: Specified schema object was not found`
- 원인 : SQL 작성([R]→[1]/[4])이 한 SQL 파일에서 `DBM_MIG_MSTR` 조회 + `ALL_TAB_COLUMNS` / `DBM_MIG_COL_MAP` 컬럼 조회를 같이 실행하고, 어느 쪽이 실패해도 MSTR 이라고 표시함. 두 번째 조회의 객체(유력 : `DBADM.DBM_MIG_COL_MAP` 미생성)가 없어서 난 오류 (현장 확인 명령 결과는 미수신)
- 결정 : 조회 분리 + COL_MAP 은 필요할 때만 / 메뉴 시작 시 제어 테이블 한 번 점검
- 응답 : `02.RUN_MIG.sh` 수정
  - SQL 작성 조회 분리 : ① `DBM_MIG_MSTR` ② `TRANS_YN = 'Y'` 대상이 있을 때만 `ALL_TAB_COLUMNS` + `DBM_MIG_COL_MAP`, 실패 메시지에 실제 객체명 표시
  - 메뉴 시작 시 4개 객체를 문장별로 조회(오류가 나도 계속)해 없는 객체를 `! CHECK` 로 표시 (차단 없음)
  - `MIG_RUN_PLAN.md` 1장 / 5장 반영
  - 참고 : `DDL_Script/DBM_XDN_LOG.sql` 은 스키마(`DBADM.`) 없이 작성되어 있어 다른 스키마에 생성됐을 수 있음

### 6. nohup: failed to run command '02.RUN_MIG.sh': Permission denied
- 요청 : 백그라운드 이관 시작 시 위 오류 해결
- 원인 : git 에 `.sh` 파일이 모두 `100644`(실행권한 없음, Windows `core.filemode=false`)로 저장됨. 메뉴는 `bash 02.RUN_MIG.sh` 로 실행돼 동작하지만, worker 시작이 `nohup 02.RUN_MIG.sh --worker ...` 로 파일을 직접 실행해 거부됨
- 결정 : 자식 프로세스 생성 시 임시 sh 를 만들어 실행 (`$MIG_HOME/run/*.sh`)
- 응답 : `02.RUN_MIG.sh` 수정
  - `MIG_HOME`(MIG.env, 기본 = 스크립트 디렉토리) 추가, `${MIG_HOME}/run` 생성
  - 시작 시 `run/{RUN|RETRY}_{PHASE}_{MSTR_ID}_R{RUN_ID}_{시각}.sh` 작성 → `nohup bash <임시 sh>` 실행 → 임시 sh 가 `exec bash 02.RUN_MIG.sh --worker ...`
  - 인터프리터 명시 실행이라 실행권한 불필요, exec 로 PID / worker 인자 유지(프로세스 확인 로직 그대로)
  - worker 종료 시 임시 sh 삭제, 시작 실패 시에도 삭제
  - `MIG.env.example`, `MIG_RUN_PLAN.md` 1 / 6 / 11장 반영

### 7. RUNNING 초록 / FAIL 빨강 색상 표시 (메뉴, 로그 tail)
- 요청 : 메뉴와 로그 tail 에서 RUNNING 은 초록, FAIL 은 빨강으로 가시성 좋게
- 결정 : 로그 파일은 색상 코드 없이 두고 **보여줄 때만** 색칠 / 경고 노랑, SUCCESS·OK 파랑, 단계 헤더 굵게 추가
- 응답 : `02.RUN_MIG.sh` 수정
  - 키워드 기준 색상 필터(`_colorize`, awk) 하나로 메뉴 화면, `[s] Status`, `[l] Total Log`, 메뉴 메시지, SQL 작성 화면 출력에 적용
  - 메뉴 밖 보기 : `bash 02.RUN_MIG.sh --tail [로그]`, `tail -f <로그> | bash 02.RUN_MIG.sh --color`
  - 터미널일 때 자동, `MIG_COLOR=Y/N`, `NO_COLOR` 지원, 백그라운드 worker 는 색 사용 안 함
  - `MIG.env.example`, `MIG_RUN_PLAN.md` 10장 반영

### 8. 메뉴 명령 키 주황색 / 메뉴도 ctl 처럼 백그라운드
- 요청 : 메뉴의 `[s]` 같은 명령 키를 주황색으로, 메뉴도 ctl 처럼 백그라운드로 실행
- 결정 : 주황색은 메뉴 화면의 `[키]` 만 / ctl 방식은 의미 확인 중 (답변 대기, 미반영)
- 응답 : `_colorize keys` + `_paint_menu` 로 메인 / Run 메뉴의 `[x]` 키를 주황(256색 208)으로 표시, 줄 색은 키 뒤로 유지. `MIG_RUN_PLAN.md` 10장 색상표 반영

### 9. DBM_XDN_LOG 에 ELAPSED_TIME 추가
- 요청 : XDN_LOG 맨 뒤에 ELAPSED_TIME 컬럼 추가, 데이터 이관 후 소요 시간 UPDATE
- 결정 : VARCHAR2 `'HH24:MI:SS'` / 구간은 START_TIME ~ END_TIME
- 응답
  - `DDL_Script/DBM_XDN_LOG.sql` 에 `ELAPSED_TIME VARCHAR2(20)` 추가 (기존 테이블용 ALTER 주석 포함)
  - `02.RUN_MIG.sh` : 완료 UPDATE 에서 `SYSDATE - START_TIME` 을 `'HH24:MI:SS'` 로 계산 (시간 24 초과 허용), RUNNING 시작 시 NULL, SQL 파일 없음 FAIL 은 `'00:00:00'`, Unlock FAIL 처리 행도 계산
  - `MIG_RUN_PLAN.md` 9장 반영

### 10. worker 병렬 실행 / Hint 에서 병렬도·PARALLEL 수정 / 메뉴 대시보드
- 요청 : worker shell 병렬 가능하게, Hint 에서 worker 병렬도와 PARALLEL 수정, 메뉴에서 병렬도 / Parallel 정보 확인하는 대시보드
- 결정 : 배분 순서 TAB_SIZE 작은 순 / 실행 중 변경은 다음 테이블부터 즉시 / 대시보드는 메인 메뉴 상단 / 로그는 이벤트 한 줄 즉시 + 블록은 완료 시 한 번에
- 응답 : `02.RUN_MIG.sh` 수정
  - worker 를 coordinator 로 변경 : 테이블마다 하위 쉘(W1 ~ Wn)을 띄워 동시에 최대 WORKER_DEGREE 개, 1초마다 설정 / stop 파일 확인
  - SQL 작성 시 `.out` 헤더에 `TAB_SIZE`(TAB_SIZE + LOB_SIZE) 기록, 실행 / 재수행 큐는 작은 순
  - `[h] Hint` : WORKER_DEGREE(1 ~ 99, 기본 1) / PARALLEL_DEGREE 둘 다 입력, 설정 파일은 임시 파일 후 교체
  - 로그 : `HH:MI:SS [Wn] START / RUNNING / SUCCESS / FAIL` 한 줄 즉시, 테이블 블록(Parallel / worker 표시 추가) + Progress 는 끝날 때 한 번에
  - `[S] Stop` : 새 테이블을 시작하지 않고 돌고 있는 테이블은 끝까지
  - 메인 메뉴 상단 대시보드 : 진행률, WORKER (busy) x PARALLEL = DB load, SUCCESS / FAIL / WAIT, 슬롯별 테이블 / PARALLEL / 경과 시간
  - `MIG_RUN_PLAN.md` 4 / 5 / 6 / 7 / 10장 반영

### 11. MAPPING 테이블 SRC OWNER / TABLE_NAME 이 먼저 오게 변경
- 요청 : DBM_MIG_COL_MAP 에서 SRC_OWNER, SRC_TABLE_NAME 이 먼저 오도록
- 응답
  - `DDL_Script/DBM_MIG_COL_MAP.sql` : 컬럼 순서 SRC_OWNER, SRC_TABLE_NAME, TGT_OWNER, TGT_TABLE_NAME, TGT_COL ... , PK 순서도 동일하게 변경. 기존 테이블 재생성 절차 주석 추가 (ALTER 로 컬럼 순서 변경 불가)
  - `DBM_MIG_COL_MAP_sample.csv` : 헤더 / 데이터 순서 변경
  - `03.LOAD_COL_MAP.sh` : 대문자 변환 목록, 테이블 쌍 키 / DELETE 조건 순서, 미리보기 표시(`SRC -> TGT`, `SRC_COL -> TGT_COL`) 변경. CSV 는 헤더 이름 기준이라 예전 순서 CSV 도 그대로 적재됨
  - `02.RUN_MIG.sh` 는 컬럼 이름으로만 조회해 변경 없음, `.out` 파일명(`{TGT}__{SRC}`)은 매핑 테이블과 무관해 유지
  - `COL_MAP_PLAN.md`, `MIG_RUN_PLAN.md`, `CLAUDE.md` 반영

### 12. DBM_XDN_LOG 컬럼 추가 여부 / ELAPSED_TIME 을 END_TIME 뒤로
- 요청 : DBM_XDN_LOG 컬럼 추가했는지 확인, ELAPSED_TIME 은 END_TIME 뒤에 오게 구성
- 확인 : DDL 파일 / `02.RUN_MIG.sh` 에는 반영, 실제 DB 에는 미실행 (DB 접속 불가, 서버에서 실행 필요 : 컬럼이 없으면 RUNNING UPDATE 실패로 모든 테이블 FAIL)
- 응답 : `DDL_Script/DBM_XDN_LOG.sql` 에서 ELAPSED_TIME 을 END_TIME 바로 뒤로 이동. 기존 테이블은 ALTER ADD 가 항상 맨 뒤에 붙으므로 (A) 재생성(Oracle / Tibero) 또는 (B) ERROR_MSG INVISIBLE → VISIBLE(Oracle 12c+) 절차를 주석으로 추가. 스크립트는 컬럼 이름으로만 UPDATE 하므로 변경 없음

### 13. TBR-8026: Invalid identifier (cmd 의 SQL 은 정상) 원인 분석
- 요청 : 이관 시 TBR-8026 발생, cmd/ 의 .out SQL 을 직접 실행하면 정상 → 원인 분석
- 분석 : 이관 시 .out 외에 쉘이 실행하는 SQL(RUNNING / 종료 UPDATE, SRC / TGT 건수 조회) 중 하나로 판단. 후보 A : DB 에 ELAPSED_TIME 컬럼 미추가, 후보 B : TGT 건수 조회에 소스 기준 조건 컬럼(CONDITION)을 타겟에 그대로 사용. 확인 명령(컬럼 목록, detail log 의 오류 직전 SQL, 결과 / Warning) 안내
- 결과 : 조건 컬럼(COL_CONDITION) 값이 잘못된 것이었음. 수정 후 정상 (코드 변경 없음)

### 14. [2] RUN / [3] RETRY 시 테이블 이관 직전 SQL 재생성 후 파일로 내리기
- 요청 : [1] 에서 구문을 뽑은 뒤 [2] running / [3] retry 할 때 해당 테이블 이관 전에 구문을 다시 생성해서 파일로 내려줘
- 결정 : cmd/{PHASE}/*.out 덮어쓰기(바뀌면 .bak) / 더 이상 대상이 아니면 SKIP / 대상 목록은 .out 파일 목록 유지
- 응답 : `02.RUN_MIG.sh` 수정
  - SQL 작성 로직을 공통 함수로 분리 : `_phase_cond`, `_row_sql`, `_col_sql`, `_write_out` ([1] / [4] 와 테이블 슬롯이 같이 사용)
  - `_refresh_out` : 슬롯에서 실행 직전 해당 테이블 1건의 MSTR(+ COL_MAP) 조회 → `.out` 재작성, 내용이 바뀌면 `.bak`, 파일이 없으면 생성
  - 대상이 아니면 SKIP (실행 안 함, DBM_XDN_LOG 행 유지), 재생성 조회 실패는 실행 없이 FAIL
  - 진행 로그 `SQL file :` 줄, `[Wn] SKIP` 이벤트, Progress / 끝 요약 / 대시보드에 SKIP 건수, SKIP 노랑 표시
  - [2] / [3] 미리보기에 재생성 안내, 재수행의 SQL 파일 없음은 FAIL 대신 재생성
  - `MIG_RUN_PLAN.md` 5 / 6 / 7 / 8장 반영 (`.out` 직접 수정은 유지되지 않음)

### 15. 14번(SQL 재생성)을 MIG.env 옵션으로 켜기 / 끄기
- 요청 : 14번 요청을 MIG.env 에 옵션으로 켜기/끄기 가능하게 구성
- 결정 : 옵션 없으면 끔(N) / 끔은 예전 동작 그대로 / MIG.env 에서만 설정, 화면·로그에 표시
- 응답 : `MIG.env` `SQL_REFRESH=Y|N` (Y 외에는 N)
  - N : `.out` 그대로 실행, 재수행 시 파일 없으면 FAIL, SKIP 없음 / Y : 14번 동작
  - worker 시작 시 값으로 고정, 메뉴 상단 / [2][3] 미리보기 / 로그 헤더에 `SQL_REFRESH=` 표시
  - `MIG.env.example`, `MIG_RUN_PLAN.md` 반영
