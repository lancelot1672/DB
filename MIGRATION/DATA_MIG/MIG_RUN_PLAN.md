# 마이그레이션 플랜
DBM_MIG_MSTR 테이블 기준으로 MIGRATION을 진행한다.
DBM_MIG_MSTR MIG_YN 컬럼 값이 'Y'인 테이블에 대해 진행한다.

마이그레이션 시작 전 DBM_XDN_LOG에 다음 데이터를 기록한다.
1. RUN_ID는 1번부터 채번한다. 테이블마다의 값이 아닌 테이블 전체의 값이다.
2. SRC_OWNER, SRC_TABLE_NAME, TGT_OWNER, TGT_TABLE_NAME을 기록한다.
3. STATUS에 [PENDING ] 기록한다.
4. 

각 테이블 마이그레이션 시작 시 DBM_XDN_LOG에 다음 데이터를 기록한다.
1. STATUS에 [ RUNNING / SUCCESS / FAIL] 기록
2. START_TIME 기록 (YYYY-MM-DD HH24:MI:SS)
3. ROW_CNT_SRC에 SRC 테이블 건수를 조회하여 기록

마이그레이션 종료 후 DBM_XDN_LOG에 다음 데이터를 기록한다.
1. STATUS에 [SUCCESS / FAIL] 기록
2. END_TIME 기록 (YYYY-MM-DD HH24:MI:SS)
3. ROW_CNT_TGT에 SRC 테이블 건수를 조회하여 기록


### DBM_MIG_MSTR 테이블 TRANS_YN 가 'Y' 일 경우
테이블 메타 정보가 변경되는 것이므로 일단 보류 (이후 기능 추가 예정)

### 마이그레이션 제약조건
1. ./cmd 디렉토리 아래에 {TGT_OWNER}_{TGT_TABLE_NAME}.out 테이블 이관 SQL인 INSERT INTO SELECT, COMMIT SQL 기록
2. ./log 디렉토리 아래에 진행상황 log 기록 (테이블 명, 조건에 대한 건 수, 시작 시간, 종료 시간, 소요 시간)
3. MIG_TYPE이 DDAY일 경우 COL_CONDITION 조건 없이 전체이관 진행
4. MIG_TYPE이 PRE일 경우 PRE1 >= AND PRE2 < 조건 이관 진행
5. ERROR 발생 시 ERROR는 DBM_XDN_LOG 테이블 ERROR_MSG에 기록
6. COND + DDAY는 없으니 마이그레이션은 2단계로 한다.

### 마이그레이션 단계
메뉴로 만들어서 실행할 수 있도록 한다.
[1단계 : PRE 이관 SQL 작성]
PRE 이관 MIG_TYPE : PRE + MIG_FULL이 COND인 테이블에 대해 진행
1. ./cmd/PRE 디렉토리 아래에 {TGT_OWNER}_{TGT_TABLE_NAME}.out 테이블 이관 SQL인 INSERT INTO SELECT, COMMIT SQL 기록

[2단계 : PRE 이관]
1. ./cmd/PRE 디렉토리 아래 SQL 기반으로 이관 수행

[3단계 : DDAY 이관 SQL 작성]
./cmd/DDAY 디렉토리 아래 SQL 작성
1. PRE 이관  MIG_TYPE : PRE + MIG_FULL : COND인 테이블에 대해 COL_CONDITION >= PRE3 조건으로 나머지 데이터에 대해 {TGT_OWNER}_{TGT_TABLE_NAME}.out 테이블 이관 SQL 작성
2. DDAY 이관 MIG_TYPE : DDAY + MIG_FULL : FULL인 테이블에 대해 {TGT_OWNER}_{TGT_TABLE_NAME}.out 테이블 이관 SQL 작성

[4단계 : DDAY 이관]
./cmd/DDAY 디렉토리 아래 SQL 기반으로 이관 수행
1. PRE 이관  MIG_TYPE : PRE + MIG_FULL : COND인 테이블에 대해 COL_CONDITION >= PRE3 조건으로 나머지 데이터에 대해 이관 진행
2. DDAY 이관 MIG_TYPE : DDAY + MIG_FULL : FULL인 테이블에 대해 진행