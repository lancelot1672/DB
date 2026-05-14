-- ============================================================
-- CANADA_EXPDP TEST DATA
-- ============================================================

-- ============================================================
-- 1. 테스트 테이블 생성
-- ============================================================

-- 1-1. DBADM.TEST_ORDER (날짜 조건 테스트용)
CREATE TABLE DBADM.TEST_ORDER (
    ORDER_ID    NUMBER,
    ORDER_DATE  VARCHAR2(8),
    CUST_NAME   VARCHAR2(50),
    AMOUNT      NUMBER(12,2)
);

INSERT INTO DBADM.TEST_ORDER VALUES (1, '20250101', 'KIM',   10000);
INSERT INTO DBADM.TEST_ORDER VALUES (2, '20250215', 'LEE',   25000);
INSERT INTO DBADM.TEST_ORDER VALUES (3, '20250320', 'PARK',  30000);
INSERT INTO DBADM.TEST_ORDER VALUES (4, '20250410', 'CHOI',  15000);
INSERT INTO DBADM.TEST_ORDER VALUES (5, '20250505', 'JUNG',  42000);
INSERT INTO DBADM.TEST_ORDER VALUES (6, '20250612', 'KANG',   8000);
INSERT INTO DBADM.TEST_ORDER VALUES (7, '20250718', 'YOON',  55000);
INSERT INTO DBADM.TEST_ORDER VALUES (8, '20250830', 'HAN',   12000);

-- 1-2. DBADM.TEST_LOG (날짜 범위 조건 테스트용)
CREATE TABLE DBADM.TEST_LOG (
    LOG_SEQ     NUMBER,
    LOG_DATE    VARCHAR2(8),
    LOG_TYPE    VARCHAR2(10),
    LOG_MSG     VARCHAR2(200)
);

INSERT INTO DBADM.TEST_LOG VALUES (1, '20250101', 'INFO',  'System started');
INSERT INTO DBADM.TEST_LOG VALUES (2, '20250115', 'ERROR', 'Connection timeout');
INSERT INTO DBADM.TEST_LOG VALUES (3, '20250201', 'INFO',  'Batch job started');
INSERT INTO DBADM.TEST_LOG VALUES (4, '20250301', 'WARN',  'Disk usage 80%');
INSERT INTO DBADM.TEST_LOG VALUES (5, '20250401', 'INFO',  'Monthly report');
INSERT INTO DBADM.TEST_LOG VALUES (6, '20250501', 'ERROR', 'ORA-01555');
INSERT INTO DBADM.TEST_LOG VALUES (7, '20250601', 'INFO',  'Backup completed');
INSERT INTO DBADM.TEST_LOG VALUES (8, '20250701', 'INFO',  'Archive done');

-- 1-3. DBADM.TEST_CODE (조건 없이 전체 export 테스트용)
CREATE TABLE DBADM.TEST_CODE (
    CODE_TYPE   VARCHAR2(10),
    CODE_VALUE  VARCHAR2(10),
    CODE_NAME   VARCHAR2(50)
);

INSERT INTO DBADM.TEST_CODE VALUES ('STATUS', '01', 'Active');
INSERT INTO DBADM.TEST_CODE VALUES ('STATUS', '02', 'Inactive');
INSERT INTO DBADM.TEST_CODE VALUES ('STATUS', '03', 'Pending');
INSERT INTO DBADM.TEST_CODE VALUES ('GRADE',  'A',  'Premium');
INSERT INTO DBADM.TEST_CODE VALUES ('GRADE',  'B',  'Standard');
INSERT INTO DBADM.TEST_CODE VALUES ('GRADE',  'C',  'Basic');

COMMIT;

-- ============================================================
-- 2. MIG_TAB_LIST 테이블 생성
-- ============================================================

CREATE TABLE DBADM.MIG_TAB_LIST (
    OWNER       VARCHAR2(30),
    TABLE_NAME  VARCHAR2(30),
    WHERE_COL1  VARCHAR2(30),
    PRE1        VARCHAR2(100),
    WHERE_COL2  VARCHAR2(30),
    PRE2        VARCHAR2(100)
);

-- ============================================================
-- 3. MIG_TAB_LIST 데이터
--    CASE 1 : WHERE_COL1만 있음  (>=)
--    CASE 2 : WHERE_COL1 + COL2  (>= AND <)
--    CASE 3 : 조건 없음          (전체 export)
-- ============================================================

-- CASE 1: ORDER_DATE >= '20250401'
INSERT INTO DBADM.MIG_TAB_LIST (OWNER, TABLE_NAME, WHERE_COL1, PRE1, WHERE_COL2, PRE2)
VALUES ('DBADM', 'TEST_ORDER', 'ORDER_DATE', '20250401', NULL, NULL);

-- CASE 2: LOG_DATE >= '20250201' AND LOG_DATE < '20250601'
INSERT INTO DBADM.MIG_TAB_LIST (OWNER, TABLE_NAME, WHERE_COL1, PRE1, WHERE_COL2, PRE2)
VALUES ('DBADM', 'TEST_LOG', 'LOG_DATE', '20250201', 'LOG_DATE', '20250601');

-- CASE 3: 전체 export (WHERE 조건 없음)
INSERT INTO DBADM.MIG_TAB_LIST (OWNER, TABLE_NAME, WHERE_COL1, PRE1, WHERE_COL2, PRE2)
VALUES ('DBADM', 'TEST_CODE', NULL, NULL, NULL, NULL);

COMMIT;

-- ============================================================
-- 확인 쿼리
-- ============================================================

SELECT OWNER, TABLE_NAME,
       NVL(WHERE_COL1, '-') AS WHERE_COL1,
       NVL(PRE1, '-')       AS PRE1,
       NVL(WHERE_COL2, '-') AS WHERE_COL2,
       NVL(PRE2, '-')       AS PRE2
  FROM DBADM.MIG_TAB_LIST
 ORDER BY OWNER, TABLE_NAME;

-- 예상 EXPDP 결과:
--   TEST_ORDER : 4건 (20250410, 20250505, 20250612, 20250718, 20250830)
--   TEST_LOG   : 4건 (20250201, 20250301, 20250401, 20250501)
--   TEST_CODE  : 6건 (전체)
