-- ============================================================
-- dummy_data_300k.sql
-- 그리드 대량 조회 테스트용 더미 데이터 30만 행 생성 (PostgreSQL 9.6 호환)
-- generate_series 로 한 번에 생성 (INSERT 30만 줄 X)
-- 실행:  psql -h <host> -U <user> -d <dbname> -f dummy_data_300k.sql
-- 행 수 조정: 아래 generate_series(1, 300000) 의 숫자만 변경
-- ============================================================

DROP TABLE IF EXISTS tstown.big_orders;

CREATE TABLE tstown.big_orders (
    id            INTEGER PRIMARY KEY,
    customer_id   INTEGER,
    customer_name VARCHAR(50),
    city          VARCHAR(30),
    country       VARCHAR(5),
    order_date    DATE,
    amount        NUMERIC(12, 2),
    status        VARCHAR(20),
    channel       VARCHAR(20),
    currency      VARCHAR(5),
    processed_at  TIMESTAMP,
    memo          VARCHAR(40)
);

-- 30만 행 일괄 생성 (배열 인덱싱 + random 으로 값 다양화)
INSERT INTO tstown.big_orders
SELECT
    g                                                              AS id,
    1 + (g % 10000)                                                AS customer_id,
    'CUST_' || lpad((1 + (g % 10000))::text, 5, '0')               AS customer_name,
    (ARRAY['Seoul','Busan','Incheon','Tokyo','Osaka','New York',
           'Chicago','Toronto','Vancouver','London'])[1 + (g % 10)] AS city,
    (ARRAY['KR','JP','US','CA','UK'])[1 + (g % 5)]                 AS country,
    DATE '2025-01-01' + (g % 365)                                  AS order_date,
    round((random() * 1000000)::numeric, 2)                        AS amount,
    (ARRAY['paid','cancelled','refunded','pending'])[1 + (g % 4)]  AS status,
    (ARRAY['web','mobile','store'])[1 + (g % 3)]                   AS channel,
    (ARRAY['KRW','JPY','USD','CAD','GBP'])[1 + (g % 5)]            AS currency,
    TIMESTAMP '2025-01-01 00:00:00' + (g % 500000) * INTERVAL '1 minute' AS processed_at,
    md5(g::text)                                                   AS memo
FROM generate_series(1, 300000) AS g;

-- 통계 갱신 (플래너 최적화)
ANALYZE tstown.big_orders;

COMMIT;

-- 확인용:
--   SELECT count(*) FROM tstown.big_orders;                 -- 300000
--   SELECT * FROM tstown.big_orders ORDER BY id;            -- 그리드 전체 스크롤 테스트
