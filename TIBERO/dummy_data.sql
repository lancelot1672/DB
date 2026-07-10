-- ============================================================
-- dummy_data.sql
-- SQL Grid (TIBERO/app.py) 프리셋 쿼리용 더미 데이터 (PostgreSQL 9.6 호환)
-- 실행:  psql -h <host> -U <user> -d <dbname> -f dummy_data.sql
-- 앱의 PRESETS(tstown.customers / tstown.orders / tstown.transactions) 컬럼 구조에 맞춤.
-- ============================================================

DROP TABLE IF EXISTS tstown.transactions;
DROP TABLE IF EXISTS tstown.orders;
DROP TABLE IF EXISTS tstown.customers;

-- ============================================================
-- 1. tstown.customers
-- ============================================================
CREATE TABLE tstown.customers (
    customer_id  INTEGER PRIMARY KEY,
    name         VARCHAR(100),
    email        VARCHAR(200),
    city         VARCHAR(100),
    country      VARCHAR(50),
    signup_date  DATE,
    status       VARCHAR(20)
);

INSERT INTO tstown.customers (customer_id, name, email, city, country, signup_date, status) VALUES
    (1,  'Alice Kim',      'alice@example.com',   'Seoul',      'KR', '2025-01-05', 'active'),
    (2,  'Bob Lee',        'bob@example.com',     'Busan',      'KR', '2025-02-11', 'active'),
    (3,  'Carol Park',     'carol@example.com',   'Incheon',    'KR', '2025-03-02', 'inactive'),
    (4,  'David Choi',     'david@example.com',   'Tokyo',      'JP', '2025-03-18', 'active'),
    (5,  'Eva Jung',       'eva@example.com',     'Osaka',      'JP', '2025-04-07', 'active'),
    (6,  'Frank Yoon',     'frank@example.com',   'New York',   'US', '2025-04-22', 'active'),
    (7,  'Grace Han',      'grace@example.com',   'Chicago',    'US', '2025-05-01', 'inactive'),
    (8,  'Henry Shin',     'henry@example.com',   'Toronto',    'CA', '2025-05-15', 'active'),
    (9,  'Ivy Kwon',       'ivy@example.com',     'Vancouver',  'CA', '2025-06-03', 'active'),
    (10, 'Jack Oh',        'jack@example.com',    'London',     'UK', '2025-06-20', 'active');

-- ============================================================
-- 2. tstown.orders
-- ============================================================
CREATE TABLE tstown.orders (
    order_id     INTEGER PRIMARY KEY,
    customer_id  INTEGER REFERENCES tstown.customers(customer_id),
    order_date   DATE,
    amount       NUMERIC(12,2),
    status       VARCHAR(20),
    channel      VARCHAR(20)
);

INSERT INTO tstown.orders (order_id, customer_id, order_date, amount, status, channel) VALUES
    (1001, 1, '2026-01-10',  120000.00, 'paid',      'web'),
    (1002, 1, '2026-02-14',   85000.00, 'paid',      'mobile'),
    (1003, 2, '2026-01-22',  240000.00, 'paid',      'web'),
    (1004, 2, '2026-03-01',   15000.00, 'cancelled', 'mobile'),
    (1005, 4, '2026-02-05',  530000.00, 'paid',      'web'),
    (1006, 5, '2026-02-19',   67000.00, 'paid',      'store'),
    (1007, 6, '2026-03-11',  310000.00, 'paid',      'web'),
    (1008, 6, '2026-04-02',   99000.00, 'refunded',  'mobile'),
    (1009, 8, '2026-01-30',  178000.00, 'paid',      'web'),
    (1010, 9, '2026-03-25',  445000.00, 'paid',      'store'),
    (1011, 9, '2026-04-15',   28000.00, 'paid',      'mobile'),
    (1012, 10,'2026-02-28',  760000.00, 'paid',      'web');

-- ============================================================
-- 3. tstown.transactions
-- ============================================================
CREATE TABLE tstown.transactions (
    txn_id        INTEGER PRIMARY KEY,
    order_id      INTEGER REFERENCES tstown.orders(order_id),
    method        VARCHAR(20),
    amount        NUMERIC(12,2),
    currency      VARCHAR(10),
    processed_at  TIMESTAMP,
    state         VARCHAR(20)
);

INSERT INTO tstown.transactions (txn_id, order_id, method, amount, currency, processed_at, state) VALUES
    (5001, 1001, 'card',     120000.00, 'KRW', '2026-01-10 10:12:03', 'settled'),
    (5002, 1002, 'card',      85000.00, 'KRW', '2026-02-14 14:31:55', 'settled'),
    (5003, 1003, 'transfer', 240000.00, 'KRW', '2026-01-22 09:05:20', 'settled'),
    (5004, 1004, 'card',      15000.00, 'KRW', '2026-03-01 11:47:10', 'voided'),
    (5005, 1005, 'card',     530000.00, 'JPY', '2026-02-05 16:20:41', 'settled'),
    (5006, 1006, 'cash',      67000.00, 'JPY', '2026-02-19 18:02:33', 'settled'),
    (5007, 1007, 'card',     310000.00, 'USD', '2026-03-11 12:15:09', 'settled'),
    (5008, 1008, 'card',      99000.00, 'USD', '2026-04-02 13:40:27', 'refunded'),
    (5009, 1009, 'transfer', 178000.00, 'CAD', '2026-01-30 08:55:14', 'settled'),
    (5010, 1010, 'card',     445000.00, 'CAD', '2026-03-25 19:33:48', 'settled'),
    (5011, 1011, 'card',      28000.00, 'CAD', '2026-04-15 20:11:02', 'settled'),
    (5012, 1012, 'transfer', 760000.00, 'GBP', '2026-02-28 07:29:56', 'settled');

COMMIT;
