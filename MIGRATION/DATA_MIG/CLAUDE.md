# Subject : MIGRATION Shell

## 규칙
1. 방식은 claude가 고민하여 물어보고 할 것

### 설계 
#### DBM_MIG_MSTR의 테이블 컬럼 의미는 다음과 같다
- MSTR_ID : 기준이 되는 ID 값
- SRC : SOURCE DB
- TGT : TARGET DB
- TBS_TAB : TABLE TABLESPACE NAME
- IND_TAB : INDEX TABLESPACE NAME
- TAB_SIZE : TABLE SIZE
- LOB_SIZE : LOB이 있을 때 LOB SIZE
- PARTITION_YN : 테이블 파티션 여부
- MANAGER : 테이블 담당자 이름
- MIG_YN : 마이그레이션 여부
- MIG_TYPE : 초기적재  / 조건이관 / 전체이관 [INIT / PRE / DDAY]
- MIG_FULL : 전체 이관 여부 [FULL : 전체 / COND : 조건]
- COL_CONDITION : 이관 조건 컬럼 명
- PRE1 : 조건이 있을 경우 조건에 대해 이상 값 (COL_CONDITION >= PRE1)
- PRE2 : 조건 미만 값 (COL_CONDITION >= PRE1 AND COL_CONDITION < PRE2)
- PRE3 : 조건 이상 값 (COL_CONDITION >= PRE3)
- MIG_METHOD : DB_LINK 고정
- SRC : ASIS 고정
- TGT : TOBE 고정

#### DBM_MIG_COL_MAP (컬럼 매핑) — 상세는 COL_MAP_PLAN.md
- MSTR_ID : DBM_MIG_MSTR.MSTR_ID
- COL_SEQ : 타겟 컬럼 순서
- TGT_COL : 타겟 컬럼명
- SRC_COL : 소스 컬럼명 (추가 컬럼이면 NULL)
- DEFAULT_VAL : SRC_COL 이 NULL 일 때 넣을 값
- REMARK : 비고
- 구조 변경 테이블만 타겟 컬럼 전부 등록, 삭제 컬럼은 미등록
- 제약 : Oracle / Tibero 이기종 가능, 프로시저 사용 금지 (일반 SQL 만)