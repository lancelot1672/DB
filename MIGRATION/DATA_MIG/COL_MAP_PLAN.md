# 컬럼 매핑 테이블 (DBM_MIG_COL_MAP)

컬럼명 변경 / 순서 변경 / 컬럼 추가가 있는 테이블만 등록한다. 등록이 없는 테이블은 기존 방식(동일 구조)으로 이관한다.

## 테이블

| 컬럼 | 설명 |
|---|---|
| MSTR_ID | DBM_MIG_MSTR.MSTR_ID |
| COL_SEQ | 타겟 컬럼 순서 |
| TGT_COL | 타겟 컬럼명 |
| SRC_COL | 소스 컬럼명 (추가 컬럼이면 NULL) |
| DEFAULT_VAL | SRC_COL 이 NULL 일 때 넣을 값 (`'B'`, `SYSDATE` 등, 비우면 NULL) |
| REMARK | 비고 |

## 등록 규칙
1. 구조가 바뀐 테이블은 **타겟 컬럼 전부**를 등록한다 (바뀌지 않은 컬럼 포함).
2. 컬럼명 변경 → `SRC_COL` 에 옛 이름
3. 컬럼 추가 → `SRC_COL` 비움, 필요하면 `DEFAULT_VAL`
4. 컬럼 삭제 → 등록하지 않음
5. 순서 변경 → `COL_SEQ` 만 타겟 순서대로 (INSERT 에 컬럼명을 명시하므로 순서는 자동 해결)

## 예시

소스 `OLD.CUST(CUST_NO, CUST_NM, TEL, OLD_FLAG)` → 타겟 `NEW.CUSTOMER(CUST_NO, CUST_NAME, CUST_GRADE, TEL_NO, REG_DT)`

| MSTR_ID | COL_SEQ | TGT_COL | SRC_COL | DEFAULT_VAL | REMARK |
|---|---|---|---|---|---|
| CUST_01 | 1 | CUST_NO | CUST_NO | | |
| CUST_01 | 2 | CUST_NAME | CUST_NM | | 명칭변경 |
| CUST_01 | 3 | CUST_GRADE | | 'B' | 추가 |
| CUST_01 | 4 | TEL_NO | TEL | | 명칭변경 |
| CUST_01 | 5 | REG_DT | | SYSDATE | 추가 |

`OLD_FLAG` 는 삭제 컬럼이라 등록하지 않음.

`SQL/COL_MAP_GEN_INSERT.sql` 결과:
```sql
INSERT INTO NEW.CUSTOMER (CUST_NO, CUST_NAME, CUST_GRADE, TEL_NO, REG_DT) SELECT CUST_NO, CUST_NM, 'B', TEL, SYSDATE FROM OLD.CUST@ASIS_LINK;
```

## 주의
- 일반 SQL(LISTAGG)만 사용하며 프로시저는 쓰지 않는다. Oracle / Tibero 양쪽에서 동일하게 동작한다.
- 이기종(Oracle → Tibero) 이관을 고려해 `DEFAULT_VAL` 에는 양쪽 공통 함수만 쓴다 (`SYSDATE`, `NVL`, `TO_DATE` 등).
- 문자 값은 따옴표까지 저장한다: `INSERT ... VALUES (..., '''B''', ...)` → 컬럼 값 `'B'`
- 생성 SQL 한 줄이 4000byte 를 넘으면 LISTAGG 오류가 난다 (대략 컬럼 60~100개 이상인 테이블).
- DB LINK 명은 `DBM_MIG_MSTR.SRC`(ASIS 라벨)가 아니라 MIG.env 의 `SRC_DBLINK` 를 쓴다 (`DEFINE SRC_DBLINK = ...` 후 실행).
- WHERE 조건은 `MIG_FULL = 'COND'` 일 때만 붙는다: PRE → `COL_CONDITION >= 'PRE1' AND COL_CONDITION < 'PRE2'`, DDAY → `COL_CONDITION >= 'PRE3'`, INIT → 없음.
