# Subject : MIGRATION Shell

## 규칙
1. 방식은 claude가 고민하여 물어보고 할 것
2. ./etc/Claude_Request.md에 Claude Code에 대한 요청 / 응답 간략하게 기록

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
- 모든 테이블 공통 테이블 하나 (테이블별 _MAPPING 테이블 만들지 않음), PK : SRC_OWNER + SRC_TABLE_NAME + TGT_OWNER + TGT_TABLE_NAME + TGT_COL
- SRC_OWNER / SRC_TABLE_NAME / TGT_OWNER / TGT_TABLE_NAME : 소스 → 타겟 테이블 쌍 (컬럼 순서도 SRC 가 먼저, N:1 병합 시 소스별 매핑)
- TGT_COL : 타겟 컬럼명
- SRC_COL : 소스 컬럼명 (RENAME 일 때 옛 이름, ADD 는 NULL)
- MAP_FLAG : RENAME (컬럼명 변경) / ADD (추가 컬럼)
- DEFAULT_VAL : ADD 컬럼에 넣을 값 (NULL 이면 INSERT 에서 제외 → 타겟 DEFAULT)
- REMARK : 자유 메모
- TRANS_YN = 'Y' 테이블의 바뀐 컬럼만 등록, 나머지는 타겟 ALL_TAB_COLUMNS 에서 같은 이름으로 자동 매핑
- 적재 : 03.LOAD_COL_MAP.sh <CSV> (CSV 에 나온 테이블 쌍만 DELETE 후 INSERT, 이름 컬럼 대문자 변환)
- 제약 : Oracle / Tibero 이기종 가능, 프로시저 사용 금지 (일반 SQL 만)