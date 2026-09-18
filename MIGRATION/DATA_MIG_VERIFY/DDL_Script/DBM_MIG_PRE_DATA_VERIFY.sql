-- ============================================================
-- DBADM.DBM_MIG_PRE_DATA_VERIFY
--   pre-migration data verify result : 1 row = 1 column compared (ASIS SUM vs TOBE SUM)
--   created on the TARGET (TOBE) DB, next to DBM_MIG_MSTR
--
--   OWNER / TABLE_NAME / COLUMN_NAME : TARGET (TOBE) side names (plan)
--   SRC_*                            : SOURCE (ASIS) side names (differ when TRANS_YN = 'Y')
--   ASIS_COL / TOBE_COL              : SUM value kept as text, so that a huge / decimal
--                                      NUMBER is stored exactly as the DB printed it
--                                      (TO_NUMBER(ASIS_COL) when a numeric compare is wanted)
--   STATUS                           : 일치 / 불일치 / SKIP / ERROR
-- ============================================================

CREATE TABLE DBADM.DBM_MIG_PRE_DATA_VERIFY
(
    RUN_ID          NUMBER          NOT NULL,
    MSTR_ID         VARCHAR2(100)   NOT NULL,
    OWNER           VARCHAR2(30)    NOT NULL,
    TABLE_NAME      VARCHAR2(128)   NOT NULL,
    COLUMN_NAME     VARCHAR2(128)   NOT NULL,
    SRC_OWNER       VARCHAR2(30)    NULL,
    SRC_TABLE_NAME  VARCHAR2(128)   NULL,
    SRC_COLUMN_NAME VARCHAR2(128)   NULL,
    MIG_TYPE        VARCHAR2(10)    NULL,
    VERIFY_COND     VARCHAR2(4000)  NULL,
    ASIS_COL        VARCHAR2(200)   NULL,
    TOBE_COL        VARCHAR2(200)   NULL,
    DIFF            VARCHAR2(200)   NULL,
    STATUS          VARCHAR2(20)    NOT NULL,
    ERROR_MSG       VARCHAR2(1000)  NULL,
    VERIFY_DT       DATE            DEFAULT SYSDATE NOT NULL
)
;

CREATE INDEX DBADM.IX_DBM_MIG_PRE_DATA_VERIFY_01
    ON DBADM.DBM_MIG_PRE_DATA_VERIFY (MSTR_ID, RUN_ID, STATUS)
;

-- latest run only
-- SELECT * FROM DBADM.DBM_MIG_PRE_DATA_VERIFY
--  WHERE MSTR_ID = '20260914'
--    AND RUN_ID  = (SELECT MAX(RUN_ID) FROM DBADM.DBM_MIG_PRE_DATA_VERIFY WHERE MSTR_ID = '20260914')
--    AND STATUS <> '일치'
--  ORDER BY OWNER, TABLE_NAME, COLUMN_NAME
-- ;
