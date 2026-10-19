-- Sample extract SQL (PostgreSQL). One file = one SELECT = one CSV (csv/SAMPLE_EMP.csv).
--   column alias = target column name (it becomes the CSV header)
--   target DATE      -> to_char(col, 'YYYYMMDDHH24MISS')
--   target TIMESTAMP -> to_char(col, 'YYYYMMDDHH24MISSUS')
SELECT e.emp_no                                    AS EMP_NO
     , e.emp_name                                  AS EMP_NM
     , to_char(e.hire_date, 'YYYYMMDDHH24MISS')    AS HIRE_DT
     , to_char(e.updated_at, 'YYYYMMDDHH24MISSUS') AS UPD_DTM
     , CASE WHEN e.is_active THEN 'Y' ELSE 'N' END AS USE_YN
     , e.salary                                    AS SAL
  FROM tstown.emp e
 WHERE e.hire_date >= DATE '2020-01-01'
