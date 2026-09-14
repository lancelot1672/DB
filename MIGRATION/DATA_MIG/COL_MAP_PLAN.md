# 컬럼 매핑 테이블 (DBM_MIG_COL_MAP)

컬럼명 변경 / 컬럼 추가가 있는 테이블(`DBM_MIG_MSTR.TRANS_YN = 'Y'`)의 **바뀐 컬럼만** 등록하는 공통 테이블 하나.
테이블별 `_MAPPING` 테이블은 만들지 않는다. 테이블명 / OWNER 변경은 `DBM_MIG_MSTR` 의 SRC / TGT 컬럼으로 표현한다.

## 테이블

| 컬럼 | 설명 |
|---|---|
| TGT_OWNER | 타겟 OWNER (PK) |
| TGT_TABLE_NAME | 타겟 테이블명 (PK) |
| SRC_OWNER | 소스 OWNER (PK) |
| SRC_TABLE_NAME | 소스 테이블명 (PK) |
| TGT_COL | 타겟 컬럼명 (PK) |
| SRC_COL | 소스 컬럼명 (`RENAME` 일 때 옛 이름, `ADD` 는 NULL) |
| MAP_FLAG | `RENAME` : 컬럼명 변경 / `ADD` : 추가 컬럼 |
| DEFAULT_VAL | `ADD` 컬럼에 넣을 값 (`'N'`, `SYSDATE` 등). 비우면 INSERT 에서 빠지고 타겟 DEFAULT 적용 |
| REMARK | 자유 메모 (변경 사유 등) |

DDL : `DDL_Script/DBM_MIG_COL_MAP.sql`

## 적재 : `03.LOAD_COL_MAP.sh <CSV_FILE>`
- CSV 형식 / 동작은 `01.LOAD_MIG_MSTR.sh` 와 같다 (헤더 = 컬럼, `"..."` 따옴표, 쉘 검증 없음, 미리보기 + y/N, 오류 시 전체 ROLLBACK)
- CSV 에 나온 **테이블 쌍(TGT_OWNER, TGT_TABLE_NAME, SRC_OWNER, SRC_TABLE_NAME) 의 기존 매핑을 DELETE 후 CSV 로 INSERT** (한 트랜잭션). 다른 테이블 쌍의 매핑은 유지
- 이름 컬럼(TGT_OWNER / TGT_TABLE_NAME / SRC_OWNER / SRC_TABLE_NAME / TGT_COL / SRC_COL / MAP_FLAG)은 대문자로 변환, `DEFAULT_VAL` / `REMARK` 는 그대로
- 샘플 : `DBM_MIG_COL_MAP_sample.csv` (콤마가 들어가는 식은 `"NVL(REG_DT, SYSDATE)"` 처럼 따옴표로 감싼다)
- 테이블 쌍의 매핑을 전부 지우려면 CSV 에서 빼는 게 아니라 DB 에서 직접 DELETE 한다 (CSV 에 없는 쌍은 건드리지 않음)

키에 소스 테이블이 들어가므로 N:1 병합(여러 소스 → 타겟 하나)에서 소스마다 다른 매핑을 줄 수 있다.

## 등록 규칙
1. `TRANS_YN = 'Y'` 인 테이블의 **바뀐 컬럼만** 등록한다. (소스 → 타겟 쌍 기준)
2. 컬럼명 변경 → `MAP_FLAG = RENAME`, `SRC_COL` 에 옛 이름
3. 컬럼 추가 → `MAP_FLAG = ADD`, 필요하면 `DEFAULT_VAL`
4. 바뀌지 않은 컬럼 → 등록하지 않음 (타겟 `ALL_TAB_COLUMNS` 에서 같은 이름으로 자동 매핑)
5. 소스에서 삭제된 컬럼 → 등록하지 않음 (타겟에 없으므로 SELECT 에 안 들어감)
6. 컬럼 순서 / 추가 위치 → 신경 쓰지 않음 (INSERT 에 컬럼명을 명시)

## 예시 1 : 테이블명 + 컬럼 변경

`OLD.TB_CUST_NOTI` → `NEW.CUST_NOTI` : `SEND_SMS_YN` → `SMS_SEND_YN`, 맨 뒤 `KAKAO_SEND_YN` 추가

| TGT_OWNER | TGT_TABLE_NAME | SRC_OWNER | SRC_TABLE_NAME | TGT_COL | SRC_COL | MAP_FLAG | DEFAULT_VAL |
|---|---|---|---|---|---|---|---|
| NEW | CUST_NOTI | OLD | TB_CUST_NOTI | SMS_SEND_YN | SEND_SMS_YN | RENAME | |
| NEW | CUST_NOTI | OLD | TB_CUST_NOTI | KAKAO_SEND_YN | | ADD | 'N' |

`cmd/{PRE|DDAY}/NEW_CUST_NOTI__OLD_TB_CUST_NOTI.out` :
```sql
INSERT INTO NEW.CUST_NOTI
       (CUST_NO
      , SMS_SEND_YN
      , REG_DT
      , KAKAO_SEND_YN)
SELECT  CUST_NO
      , SEND_SMS_YN
      , REG_DT
      , 'N'
  FROM OLD.TB_CUST_NOTI@ASIS_LINK;
COMMIT;
```

## 예시 2 : N:1 병합

`OLD.SMS_HIST` + `OLD.KAKAO_HIST` → `NEW.NOTI_HIST` (소스마다 컬럼명이 다르고, 구분 컬럼 `NOTI_TYPE` 추가)

| TGT_TABLE_NAME | SRC_TABLE_NAME | TGT_COL | SRC_COL | MAP_FLAG | DEFAULT_VAL |
|---|---|---|---|---|---|
| NOTI_HIST | SMS_HIST | SEND_DT | SMS_SEND_DT | RENAME | |
| NOTI_HIST | SMS_HIST | NOTI_TYPE | | ADD | 'SMS' |
| NOTI_HIST | KAKAO_HIST | SEND_DT | KKO_SEND_DT | RENAME | |
| NOTI_HIST | KAKAO_HIST | NOTI_TYPE | | ADD | 'KAKAO' |

→ `NEW_NOTI_HIST__OLD_SMS_HIST.out`, `NEW_NOTI_HIST__OLD_KAKAO_HIST.out` 두 파일로 따로 적재.

## 동작
- `TRANS_YN = 'N'` : `INSERT INTO TGT SELECT * FROM SRC@SRC_DBLINK`
- `TRANS_YN = 'Y'` : 타겟 `ALL_TAB_COLUMNS` 의 컬럼을 `COLUMN_ID` 순서로 나열하고, 컬럼마다
  - 매핑 없음 → 같은 이름
  - `RENAME` → `SRC_COL`
  - `ADD` → `DEFAULT_VAL` (NULL 이면 컬럼 제외)
- 타겟 딕셔너리에서 컬럼을 못 찾으면(테이블 없음 / 권한 없음) `SELECT *` 로 작성하고 `[WARN]` 표시
- 컬럼 리스트는 한 줄에 컬럼 하나씩 쓰므로 LISTAGG 4000byte 제한이 없다
- 건수 일치 판단은 **적재 건수(Inserted) vs SRC 건수**. `ROW_CNT_TGT` 는 타겟 테이블 건수 (N:1 병합이면 다른 소스 적재분 포함)

## 주의
- 쉘은 매핑을 검증하지 않는다. `TGT_COL` / `SRC_COL` 오타는 이관 실행 시 `ORA-00904` 등으로 FAIL 기록된다.
- 이름은 딕셔너리 표기(대문자) 그대로 저장한다.
- `DEFAULT_VAL` 에는 Oracle / Tibero 공통 함수만 쓴다 (`SYSDATE`, `NVL`, `TO_DATE` 등). 문자 값은 따옴표까지 저장 (`'N'`).
- 타겟의 가상 컬럼 / IDENTITY(GENERATED ALWAYS) 컬럼은 값을 넣을 수 없으므로 `ADD` + `DEFAULT_VAL` 비움으로 등록해 제외한다.
- 실행 계정이 타겟 테이블의 `ALL_TAB_COLUMNS` 를 조회할 수 있어야 한다.
- 1:N 분할은 **컬럼 분할만** 지원한다 (타겟마다 자기 컬럼만 SELECT). 행 분할(조건으로 나눠 담기)은 지원하지 않는다.
