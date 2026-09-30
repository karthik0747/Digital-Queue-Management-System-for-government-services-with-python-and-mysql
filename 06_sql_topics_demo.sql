-- =====================================================================
-- 06  SQL TOPICS DEMO  -  every major SQL topic on the queue database
-- Safe to run: it only reads real tables. All changes are made on a
-- scratch table (demo_scratch) or rolled back, and cleaned up at the end.
-- Run it in MySQL Workbench / mysql client, or:  python src/run_sql_demo.py
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. SELECT basics: WHERE, ORDER BY, LIMIT, DISTINCT, alias, LIKE, IN, BETWEEN, IS NULL
-- ---------------------------------------------------------------------
SELECT name AS request_type, avg_minutes FROM sub_services WHERE avg_minutes >= 30 ORDER BY avg_minutes DESC, name LIMIT 5;
SELECT DISTINCT num_counters FROM services ORDER BY num_counters;
SELECT name FROM sub_services WHERE name LIKE '%Update%';
SELECT name FROM services WHERE name IN ('Passport', 'Aadhar Card');
SELECT name, avg_minutes FROM sub_services WHERE avg_minutes BETWEEN 15 AND 20;
SELECT token_no FROM tokens WHERE served_at IS NULL LIMIT 5;

-- ---------------------------------------------------------------------
-- 2. Aggregates: COUNT, SUM, AVG, MIN, MAX, GROUP BY, HAVING, GROUP_CONCAT, ROLLUP
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS request_types, SUM(avg_minutes) AS total_minutes, ROUND(AVG(avg_minutes), 1) AS avg_min,
       MIN(avg_minutes) AS shortest, MAX(avg_minutes) AS longest
  FROM sub_services;
SELECT s.name AS service, COUNT(*) AS request_types, ROUND(AVG(ss.avg_minutes), 1) AS avg_minutes
  FROM services s JOIN sub_services ss ON ss.service_id = s.service_id
 GROUP BY s.service_id, s.name
HAVING COUNT(*) >= 4;
SELECT s.name AS service, GROUP_CONCAT(ss.abbrev ORDER BY ss.abbrev SEPARATOR ', ') AS codes
  FROM services s JOIN sub_services ss ON ss.service_id = s.service_id
 GROUP BY s.service_id, s.name;
SELECT s.name AS service, SUM(ss.avg_minutes) AS minutes
  FROM services s JOIN sub_services ss ON ss.service_id = s.service_id
 GROUP BY s.name WITH ROLLUP;

-- ---------------------------------------------------------------------
-- 3. JOINs: INNER, LEFT (with anti-join), RIGHT, CROSS, SELF
-- ---------------------------------------------------------------------
SELECT t.token_no, c.name, s.name AS service, ss.name AS request_type
  FROM tokens t
  JOIN citizens c      ON c.citizen_id = t.citizen_id
  JOIN sub_services ss ON ss.sub_service_id = t.sub_service_id
  JOIN services s      ON s.service_id = ss.service_id
 LIMIT 5;
SELECT ss.name AS request_type, COUNT(t.token_id) AS tokens
  FROM sub_services ss LEFT JOIN tokens t ON t.sub_service_id = ss.sub_service_id
 GROUP BY ss.sub_service_id, ss.name;
SELECT ss.name AS never_booked
  FROM sub_services ss LEFT JOIN tokens t ON t.sub_service_id = ss.sub_service_id
 WHERE t.token_id IS NULL;
SELECT s.name, ss.name AS request_type
  FROM tokens t RIGHT JOIN sub_services ss ON ss.sub_service_id = t.sub_service_id
  JOIN services s ON s.service_id = ss.service_id
 WHERE t.token_id IS NULL LIMIT 3;
SELECT s.name AS service, d.day_name
  FROM services s CROSS JOIN (SELECT 'Mon' AS day_name UNION ALL SELECT 'Tue' UNION ALL SELECT 'Wed') d
 LIMIT 6;
SELECT a.name AS shorter_job, b.name AS longer_job, a.avg_minutes, b.avg_minutes AS longer_minutes
  FROM sub_services a JOIN sub_services b
    ON a.service_id = b.service_id AND a.avg_minutes < b.avg_minutes
 WHERE a.service_id = (SELECT service_id FROM services WHERE name = 'Aadhar Card')
 LIMIT 5;

-- ---------------------------------------------------------------------
-- 4. SUBQUERIES: scalar, IN, EXISTS, NOT EXISTS, correlated, derived table, ANY / ALL
-- ---------------------------------------------------------------------
SELECT name, avg_minutes FROM sub_services WHERE avg_minutes > (SELECT AVG(avg_minutes) FROM sub_services);
SELECT name FROM services WHERE service_id IN (SELECT service_id FROM sub_services WHERE avg_minutes >= 45);
SELECT s.name FROM services s WHERE EXISTS (SELECT 1 FROM sub_services ss WHERE ss.service_id = s.service_id AND ss.avg_minutes <= 10);
SELECT s.name FROM services s WHERE NOT EXISTS (SELECT 1 FROM tokens t JOIN sub_services ss ON ss.sub_service_id = t.sub_service_id WHERE ss.service_id = s.service_id);
SELECT ss.name, ss.avg_minutes, (SELECT ROUND(AVG(x.avg_minutes), 1) FROM sub_services x WHERE x.service_id = ss.service_id) AS dept_avg
  FROM sub_services ss WHERE ss.avg_minutes > (SELECT AVG(x.avg_minutes) FROM sub_services x WHERE x.service_id = ss.service_id);
SELECT d.service_id, d.longest FROM (SELECT service_id, MAX(avg_minutes) AS longest FROM sub_services GROUP BY service_id) d WHERE d.longest > 30;
SELECT name FROM sub_services WHERE avg_minutes > ALL (SELECT avg_minutes FROM sub_services WHERE service_id = 4);
SELECT name FROM sub_services WHERE avg_minutes = ANY (SELECT MAX(avg_minutes) FROM sub_services GROUP BY service_id);

-- ---------------------------------------------------------------------
-- 5. SET OPERATIONS: UNION, UNION ALL   (INTERSECT / EXCEPT need MySQL 8.0.31+)
-- ---------------------------------------------------------------------
SELECT name AS label FROM services UNION SELECT name FROM sub_services ORDER BY label LIMIT 8;
SELECT 'service' AS kind, COUNT(*) AS n FROM services UNION ALL SELECT 'request type', COUNT(*) FROM sub_services;

-- ---------------------------------------------------------------------
-- 6. CONDITIONAL & NULL functions: CASE, IF, COALESCE, IFNULL, NULLIF
-- ---------------------------------------------------------------------
SELECT name, avg_minutes,
       CASE WHEN avg_minutes <= 15 THEN 'Quick' WHEN avg_minutes <= 30 THEN 'Normal' ELSE 'Long' END AS job_size,
       IF(avg_minutes > 20, 'book 2 slots', 'book 1 slot') AS advice
  FROM sub_services LIMIT 6;
SELECT COALESCE(documents_required, 'n/a') AS docs, IFNULL(NULLIF(avg_minutes, 0), 15) AS minutes FROM sub_services LIMIT 3;

-- ---------------------------------------------------------------------
-- 7. BUILT-IN FUNCTIONS: string, numeric, date/time
-- ---------------------------------------------------------------------
SELECT UPPER(name), LOWER(abbrev), LENGTH(name), CONCAT(abbrev, '-', avg_minutes), SUBSTRING(name, 1, 5), REPLACE(name, ' ', '_') FROM sub_services LIMIT 3;
SELECT ROUND(17 / 4, 2) AS rounded, CEIL(17 / 4) AS ceil_, FLOOR(17 / 4) AS floor_, MOD(17, 4) AS remainder, 17 DIV 4 AS int_div;
SELECT CURDATE() AS today, DAYNAME(CURDATE()) AS day_name, DATE_ADD(CURDATE(), INTERVAL 7 DAY) AS next_week,
       DATEDIFF('2026-12-25', '2026-10-02') AS days_between, DATE_FORMAT('2026-10-02', '%d %b %Y') AS pretty,
       TIME_FORMAT('14:05:00', '%h:%i %p') AS pretty_time, ADDTIME('08:00:00', '00:45:00') AS plus_45min, WEEKDAY('2026-10-03') AS weekday_no;

-- ---------------------------------------------------------------------
-- 8. WINDOW FUNCTIONS: ROW_NUMBER, RANK, DENSE_RANK, NTILE, LAG, LEAD, running SUM
-- ---------------------------------------------------------------------
SELECT service_id, name, avg_minutes,
       ROW_NUMBER() OVER (PARTITION BY service_id ORDER BY avg_minutes DESC) AS row_no,
       RANK()       OVER (PARTITION BY service_id ORDER BY avg_minutes DESC) AS rnk,
       DENSE_RANK() OVER (ORDER BY avg_minutes DESC) AS dense_rnk,
       NTILE(3)     OVER (ORDER BY avg_minutes) AS bucket,
       SUM(avg_minutes) OVER (PARTITION BY service_id ORDER BY sub_service_id) AS running_minutes,
       LAG(avg_minutes)  OVER (PARTITION BY service_id ORDER BY sub_service_id) AS previous_job,
       LEAD(avg_minutes) OVER (PARTITION BY service_id ORDER BY sub_service_id) AS next_job
  FROM sub_services;

-- ---------------------------------------------------------------------
-- 9. CTEs: WITH, and WITH RECURSIVE (a calendar and a slot generator)
-- ---------------------------------------------------------------------
WITH long_jobs AS (SELECT * FROM sub_services WHERE avg_minutes >= 30)
SELECT s.name AS service, COUNT(*) AS long_jobs FROM long_jobs l JOIN services s ON s.service_id = l.service_id GROUP BY s.name;

WITH RECURSIVE calendar AS (
    SELECT CURDATE() AS d
    UNION ALL
    SELECT d + INTERVAL 1 DAY FROM calendar WHERE d < CURDATE() + INTERVAL 13 DAY
)
SELECT d, DAYNAME(d) AS day_name, fn_is_working_day(d) AS office_open FROM calendar;

WITH RECURSIVE slots AS (
    SELECT CAST('08:00:00' AS TIME) AS slot_start
    UNION ALL
    SELECT ADDTIME(slot_start, '00:15:00') FROM slots WHERE slot_start < '17:45:00'
)
SELECT slot_start, ADDTIME(slot_start, '00:30:00') AS slot_end_30min FROM slots
 WHERE NOT (slot_start >= '12:45:00' AND slot_start < '14:00:00') LIMIT 10;

-- ---------------------------------------------------------------------
-- 10. PIVOT with conditional aggregation, and JSON functions
-- ---------------------------------------------------------------------
SELECT s.name AS service,
       SUM(ss.avg_minutes <= 15)                        AS quick_jobs,
       SUM(ss.avg_minutes > 15 AND ss.avg_minutes <= 30) AS normal_jobs,
       SUM(ss.avg_minutes > 30)                         AS long_jobs
  FROM services s JOIN sub_services ss ON ss.service_id = s.service_id GROUP BY s.service_id, s.name;
SELECT JSON_OBJECT('service', s.name, 'counters', s.num_counters) AS service_json FROM services s LIMIT 3;

-- ---------------------------------------------------------------------
-- 11. DDL + DML on a scratch table: CREATE, ALTER, INSERT, UPDATE, DELETE, UPSERT, DROP
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS demo_scratch;
CREATE TABLE demo_scratch (
    id      INT AUTO_INCREMENT PRIMARY KEY,
    label   VARCHAR(40) NOT NULL UNIQUE,
    minutes INT NOT NULL DEFAULT 15 CHECK (minutes > 0)
);
INSERT INTO demo_scratch (label, minutes) VALUES ('alpha', 10), ('beta', 20), ('gamma', 30);
INSERT INTO demo_scratch (label, minutes) SELECT CONCAT('copy-', abbrev), avg_minutes FROM sub_services LIMIT 3;
INSERT INTO demo_scratch (label, minutes) VALUES ('alpha', 99) ON DUPLICATE KEY UPDATE minutes = VALUES(minutes);
ALTER TABLE demo_scratch ADD COLUMN note VARCHAR(20) NULL AFTER label;
ALTER TABLE demo_scratch MODIFY COLUMN note VARCHAR(50) DEFAULT 'none';
ALTER TABLE demo_scratch ADD INDEX idx_scratch_minutes (minutes);
UPDATE demo_scratch SET note = 'short' WHERE minutes < 20;
UPDATE demo_scratch d JOIN sub_services ss ON CONCAT('copy-', ss.abbrev) = d.label SET d.note = ss.name;
DELETE FROM demo_scratch WHERE minutes > (SELECT AVG(minutes) FROM (SELECT minutes FROM demo_scratch) x);
SELECT * FROM demo_scratch ORDER BY id;
ALTER TABLE demo_scratch DROP COLUMN note;
DROP TABLE demo_scratch;

-- ---------------------------------------------------------------------
-- 12. TEMPORARY TABLE and USER VARIABLES
-- ---------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS tmp_long_jobs;
CREATE TEMPORARY TABLE tmp_long_jobs AS SELECT name, avg_minutes FROM sub_services WHERE avg_minutes >= 30;
SELECT COUNT(*) AS long_jobs FROM tmp_long_jobs;
DROP TEMPORARY TABLE tmp_long_jobs;
SET @limit_minutes = 30;
SELECT name FROM sub_services WHERE avg_minutes >= @limit_minutes LIMIT 3;
SELECT @row := @row + 1 AS running_no, name FROM sub_services, (SELECT @row := 0) init LIMIT 3;

-- ---------------------------------------------------------------------
-- 13. INDEXES and EXPLAIN (see how MySQL executes a query)
-- ---------------------------------------------------------------------
SHOW INDEX FROM tokens;
EXPLAIN SELECT * FROM tokens WHERE visit_date = CURDATE() AND status = 'WAITING';
EXPLAIN SELECT * FROM tokens WHERE token_no = 'AC-DOB-0001';

-- ---------------------------------------------------------------------
-- 14. TRANSACTIONS: START TRANSACTION, SAVEPOINT, ROLLBACK TO, COMMIT, ROLLBACK, locking read
-- ---------------------------------------------------------------------
START TRANSACTION;
    INSERT INTO holidays (holiday_date, name) VALUES ('2030-01-01', 'Demo Holiday');
    SAVEPOINT after_first_holiday;
    INSERT INTO holidays (holiday_date, name) VALUES ('2030-01-02', 'Second Demo Holiday');
    ROLLBACK TO SAVEPOINT after_first_holiday;
    SELECT holiday_date, name FROM holidays WHERE holiday_date >= '2030-01-01';
    SELECT service_id FROM services WHERE service_id = 1 FOR UPDATE;
ROLLBACK;
SELECT COUNT(*) AS demo_holidays_left FROM holidays WHERE holiday_date >= '2030-01-01';

-- ---------------------------------------------------------------------
-- 15. PREPARED STATEMENTS (safe, reusable, parameterised SQL)
-- ---------------------------------------------------------------------
SET @service_name = 'Aadhar Card';
PREPARE find_jobs FROM 'SELECT ss.name, ss.avg_minutes FROM sub_services ss JOIN services s ON s.service_id = ss.service_id WHERE s.name = ? ORDER BY ss.avg_minutes';
EXECUTE find_jobs USING @service_name;
DEALLOCATE PREPARE find_jobs;

-- ---------------------------------------------------------------------
-- 16. USING THE PROGRAM'S OWN VIEWS, FUNCTIONS AND PROCEDURES
-- ---------------------------------------------------------------------
SELECT * FROM v_service_performance;
SELECT * FROM v_today_queue;
SELECT fn_make_token_no('AC', 'DOB', 7) AS token, fn_mask_contact('9876543210') AS masked,
       fn_is_working_day('2026-10-02') AS holiday_open, fn_next_working_day('2026-10-01') AS next_open_day,
       fn_crowd_label(0.5) AS crowd;
CALL sp_daily_summary(CURDATE());
CALL sp_hourly_report(CURDATE());

-- ---------------------------------------------------------------------
-- 17. DATA DICTIONARY: ask MySQL about its own objects (INFORMATION_SCHEMA)
-- ---------------------------------------------------------------------
SELECT ROUTINE_TYPE, ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = DATABASE() ORDER BY ROUTINE_TYPE, ROUTINE_NAME;
SELECT TRIGGER_NAME, EVENT_MANIPULATION, ACTION_TIMING, EVENT_OBJECT_TABLE FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = DATABASE();
SELECT EVENT_NAME, INTERVAL_VALUE, INTERVAL_FIELD FROM information_schema.EVENTS WHERE EVENT_SCHEMA = DATABASE();
SELECT TABLE_NAME FROM information_schema.VIEWS WHERE TABLE_SCHEMA = DATABASE();
SELECT TABLE_NAME, CONSTRAINT_NAME, REFERENCED_TABLE_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = DATABASE() AND REFERENCED_TABLE_NAME IS NOT NULL;
