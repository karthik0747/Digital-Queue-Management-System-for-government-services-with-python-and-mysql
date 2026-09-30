-- =====================================================================
-- 01  VIEWS  (saved SELECT queries that behave like read-only tables)
-- Topics: JOIN, GROUP BY, aggregate functions, window function, derived table
-- =====================================================================

-- Every token with the person, service and request type already joined.
-- The Python app reads tokens through this view.
CREATE OR REPLACE VIEW v_token_details AS
SELECT t.token_id, t.token_no, t.citizen_id, t.sub_service_id,
       t.visit_date, t.slot_start, t.slot_end, t.status, t.booked_at, t.served_at,
       c.name, c.age, c.contact,
       s.service_id, s.name AS service_type, s.num_counters,
       ss.name AS sub_service, ss.avg_minutes
FROM tokens t
JOIN citizens c      ON c.citizen_id = t.citizen_id
JOIN sub_services ss ON ss.sub_service_id = t.sub_service_id
JOIN services s      ON s.service_id = ss.service_id;

-- Today's waiting list with each person's position (window function ROW_NUMBER).
CREATE OR REPLACE VIEW v_today_queue AS
SELECT service_type, sub_service, token_no, name, slot_start, slot_end,
       ROW_NUMBER() OVER (PARTITION BY sub_service_id ORDER BY slot_start, token_id) AS queue_position
FROM v_token_details
WHERE status = 'WAITING' AND visit_date = CURDATE();

-- One row per day and request type (GROUP BY + conditional aggregation).
CREATE OR REPLACE VIEW v_daily_summary AS
SELECT t.visit_date, s.name AS service_type, ss.name AS sub_service,
       COUNT(*)                   AS total_tokens,
       SUM(t.status = 'WAITING')   AS waiting,
       SUM(t.status = 'SERVED')    AS served,
       SUM(t.status = 'CANCELLED') AS cancelled,
       SUM(t.status = 'EXPIRED')   AS expired
FROM tokens t
JOIN sub_services ss ON ss.sub_service_id = t.sub_service_id
JOIN services s      ON s.service_id = ss.service_id
GROUP BY t.visit_date, s.service_id, ss.sub_service_id, s.name, ss.name;

-- Department ranking: derived table + RANK() window function.
CREATE OR REPLACE VIEW v_service_performance AS
SELECT x.service_type, x.total_tokens, x.served, x.cancelled, x.expired,
       ROUND(100 * x.cancelled / NULLIF(x.total_tokens, 0), 1) AS cancel_rate_pct,
       RANK() OVER (ORDER BY x.served DESC) AS served_rank
FROM (
    SELECT s.service_id, s.name AS service_type,
           COUNT(t.token_id)                        AS total_tokens,
           COALESCE(SUM(t.status = 'SERVED'), 0)    AS served,
           COALESCE(SUM(t.status = 'CANCELLED'), 0) AS cancelled,
           COALESCE(SUM(t.status = 'EXPIRED'), 0)   AS expired
    FROM services s
    LEFT JOIN sub_services ss ON ss.service_id = s.service_id
    LEFT JOIN tokens t        ON t.sub_service_id = ss.sub_service_id
    GROUP BY s.service_id, s.name
) x;
