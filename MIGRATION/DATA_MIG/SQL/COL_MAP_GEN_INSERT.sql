-- 컬럼 매핑이 등록된 테이블의 이관 INSERT 문 생성 (Oracle / Tibero 공통 SQL)
--   &SRC_DBLINK : 소스 DB LINK 명 (MIG.env 의 SRC_DBLINK, 실행 전 DEFINE SRC_DBLINK = ...)
--   WHERE 조건 (MIG_FULL = 'COND' 일 때만)
--     PRE  : COL_CONDITION >= 'PRE1' AND COL_CONDITION < 'PRE2'
--     DDAY : COL_CONDITION >= 'PRE3'
--     INIT : 조건 없음
SELECT 'INSERT INTO ' || M.TGT_OWNER || '.' || M.TGT_TABLE_NAME
       || ' (' || LISTAGG(C.TGT_COL, ', ') WITHIN GROUP (ORDER BY C.COL_SEQ) || ')'
       || ' SELECT ' || LISTAGG(NVL(C.SRC_COL, NVL(C.DEFAULT_VAL, 'NULL')), ', ') WITHIN GROUP (ORDER BY C.COL_SEQ)
       || ' FROM ' || M.SRC_OWNER || '.' || M.SRC_TABLE_NAME || '@&SRC_DBLINK'
       || CASE
            WHEN M.MIG_FULL = 'COND' AND M.MIG_TYPE = 'PRE'
                 THEN ' WHERE ' || M.COL_CONDITION || ' >= ''' || M.PRE1 || ''''
                   || ' AND '   || M.COL_CONDITION || ' < '''  || M.PRE2 || ''''
            WHEN M.MIG_FULL = 'COND' AND M.MIG_TYPE = 'DDAY'
                 THEN ' WHERE ' || M.COL_CONDITION || ' >= ''' || M.PRE3 || ''''
          END
       || ';' AS MIG_SQL
  FROM DBADM.DBM_MIG_MSTR M
  JOIN DBADM.DBM_MIG_COL_MAP C
    ON C.MSTR_ID = M.MSTR_ID
 WHERE M.MIG_YN = 'Y'
 GROUP BY M.MSTR_ID, M.TGT_OWNER, M.TGT_TABLE_NAME, M.SRC_OWNER, M.SRC_TABLE_NAME,
          M.MIG_FULL, M.MIG_TYPE, M.COL_CONDITION, M.PRE1, M.PRE2, M.PRE3
 ORDER BY M.MSTR_ID;
