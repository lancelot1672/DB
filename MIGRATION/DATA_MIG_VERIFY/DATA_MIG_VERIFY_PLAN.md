목적 : 데이터 마이그레이션 시, 사전이관 데이터에 대한 변경 사항이 없는지 검증하는 쉘이다.

테이블 마다 NUMBER 타입을 가진 컬럼이 N개 있을 수 있다. 여기서는 최대 10개라고 가정하고 진행한다.

1. DBADM.DMG_TAB테이블 리스트 파일을 읽는다.
2. ORACLE은 sqlplus / TIBERO는 tbsql 통해 진행한다.
3. 결과 테이블에 INSERT한다.
    
    DBADM.DBM_MIG_PRE_DATA_VERIFY 테이블
    컬럼 
    1. OWNER 
    2. TABLE_NAME
    3. ASIS_COL (NUMBER타입 컬럼 SUM값)
    4. TOBE_COL (NUMBER타입 컬럼 SUM값)
    5. STATUS [일치/불일치]
    
    ROWS 하나당 컬럼 1개 비교 값이며, 테이블별로 수행 필요
    

이관 조건이 있는 테이블 (MIG_TYPE = “PRE”)

```jsx
SELECT /*+ PARALLEL(2) */ 'TABLE_NAME',
SUM(COL1),
SUM(COL2),
SUM(COL3)
FROM OWNER.TABLE_NAME
WHERE CONDITION_COL >= 'VALUE' AND CONDITION_COL < 'VALUE'
;
```

이관 조건이 없는 테이블 (MIG_TYPE = “DDAY”)

```jsx
SELECT /*+ PARALLEL(2) */ 'TABLE_NAME',
SUM(COL1),
SUM(COL2),
SUM(COL3)
FROM OWNER.TABLE_NAME
;
```