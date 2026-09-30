-- =====================================================================
-- 03  STORED PROCEDURES
-- Topics: IN / OUT parameters, local variables, transactions
--         (START TRANSACTION / COMMIT / ROLLBACK), row locking (FOR UPDATE),
--         error handling (EXIT / CONTINUE HANDLER, SIGNAL, RESIGNAL),
--         cursor + LOOP, temporary table, function calls
-- Errors are raised as  'CODE: message'  and the Python app turns the CODE
-- into the matching exception (SLOT_FULL -> SlotUnavailableError ...).
-- =====================================================================
DELIMITER $$

-- ---------------------------------------------------------------------
-- Book a token. Everything happens in ONE transaction: either the citizen,
-- token number and token are all saved, or nothing is.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_book_token$$
CREATE PROCEDURE sp_book_token(
    IN  p_name           VARCHAR(100),
    IN  p_age            INT,
    IN  p_contact        CHAR(10),
    IN  p_sub_service_id INT,
    IN  p_visit_date     DATE,
    IN  p_slot_start     TIME,
    IN  p_slot_end       TIME,
    IN  p_now            DATETIME,
    OUT p_token_no       VARCHAR(20))
BEGIN
    DECLARE v_service_id INT DEFAULT NULL;
    DECLARE v_counters   INT DEFAULT 1;
    DECLARE v_prefix     VARCHAR(4);
    DECLARE v_abbrev     VARCHAR(6);
    DECLARE v_citizen_id INT DEFAULT NULL;
    DECLARE v_number     INT;

    -- any error: undo everything, then pass the same error to the caller
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT ss.service_id, s.num_counters, s.token_prefix, ss.abbrev
      INTO v_service_id, v_counters, v_prefix, v_abbrev
      FROM sub_services ss
      JOIN services s ON s.service_id = ss.service_id
     WHERE ss.sub_service_id = p_sub_service_id;

    IF v_service_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'INVALID_SUB_SERVICE: unknown request type';
    END IF;
    IF p_slot_end <= p_slot_start THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'INVALID_SLOT: slot end must be after slot start';
    END IF;
    IF p_visit_date < DATE(p_now) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'PAST_DATE: the visit date is in the past';
    END IF;
    IF fn_is_working_day(p_visit_date) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_WORKING_DAY: the office is closed on that date';
    END IF;

    START TRANSACTION;

    -- lock this department so two people cannot take the last free counter together
    SELECT service_id INTO v_service_id FROM services WHERE service_id = v_service_id FOR UPDATE;

    IF fn_max_concurrent(v_service_id, p_visit_date, p_slot_start, p_slot_end) >= v_counters THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'SLOT_FULL: that time slot has no free counter';
    END IF;

    -- find or create the citizen (same phone can be shared by a family)
    SELECT citizen_id INTO v_citizen_id
      FROM citizens WHERE contact = p_contact AND name = p_name LIMIT 1;
    IF v_citizen_id IS NULL THEN
        INSERT INTO citizens (name, age, contact, created_at) VALUES (p_name, p_age, p_contact, p_now);
        SET v_citizen_id = LAST_INSERT_ID();
    ELSE
        UPDATE citizens SET age = p_age WHERE citizen_id = v_citizen_id;
    END IF;

    -- next running number for this request type (atomic)
    INSERT IGNORE INTO token_sequences (sub_service_id, last_number) VALUES (p_sub_service_id, 0);
    UPDATE token_sequences SET last_number = LAST_INSERT_ID(last_number + 1)
     WHERE sub_service_id = p_sub_service_id;
    SET v_number   = LAST_INSERT_ID();
    SET p_token_no = fn_make_token_no(v_prefix, v_abbrev, v_number);

    INSERT INTO tokens (token_no, citizen_id, sub_service_id, visit_date,
                        slot_start, slot_end, status, booked_at)
    VALUES (p_token_no, v_citizen_id, p_sub_service_id, p_visit_date,
            p_slot_start, p_slot_end, 'WAITING', p_now);

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- Cancel a token (needs the phone number used for booking).
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_cancel_token$$
CREATE PROCEDURE sp_cancel_token(
    IN  p_token_no VARCHAR(20),
    IN  p_contact  CHAR(10),
    OUT p_status   VARCHAR(10))
BEGIN
    DECLARE v_id      INT DEFAULT NULL;
    DECLARE v_status  VARCHAR(10);
    DECLARE v_contact CHAR(10);
    DECLARE v_msg     VARCHAR(128);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT t.token_id, t.status, c.contact
      INTO v_id, v_status, v_contact
      FROM tokens t
      JOIN citizens c ON c.citizen_id = t.citizen_id
     WHERE t.token_no = UPPER(p_token_no)
       FOR UPDATE;

    IF v_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'TOKEN_NOT_FOUND: no such token';
    END IF;
    IF v_contact <> p_contact THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'CONTACT_MISMATCH: the phone number does not match this token';
    END IF;
    IF v_status <> 'WAITING' THEN
        SET v_msg = CONCAT('NOT_CANCELLABLE: only WAITING tokens can be cancelled (this one is ', v_status, ')');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    UPDATE tokens SET status = 'CANCELLED' WHERE token_id = v_id;
    SET p_status = 'CANCELLED';
    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- Staff: serve the next waiting person (earliest slot first).
-- p_token_no is NULL when nobody is waiting.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_serve_next$$
CREATE PROCEDURE sp_serve_next(
    IN  p_sub_service_id INT,
    IN  p_date           DATE,
    IN  p_now            DATETIME,
    OUT p_token_no       VARCHAR(20))
BEGIN
    DECLARE v_id INT DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT token_id, token_no INTO v_id, p_token_no
      FROM tokens
     WHERE sub_service_id = p_sub_service_id
       AND visit_date     = p_date
       AND status         = 'WAITING'
     ORDER BY slot_start, token_id
     LIMIT 1
       FOR UPDATE;

    IF v_id IS NULL THEN
        SET p_token_no = NULL;
    ELSE
        UPDATE tokens SET status = 'SERVED', served_at = p_now WHERE token_id = v_id;
    END IF;

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- Tokens still WAITING from a past day were never used -> EXPIRED.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_expire_old_tokens$$
CREATE PROCEDURE sp_expire_old_tokens(IN p_today DATE, OUT p_count INT)
BEGIN
    UPDATE tokens SET status = 'EXPIRED'
     WHERE status = 'WAITING' AND visit_date < p_today;
    SET p_count = ROW_COUNT();
END$$

-- ---------------------------------------------------------------------
-- Holidays
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_add_holiday$$
CREATE PROCEDURE sp_add_holiday(IN p_date DATE, IN p_name VARCHAR(100))
BEGIN
    INSERT INTO holidays (holiday_date, name) VALUES (p_date, p_name)
    ON DUPLICATE KEY UPDATE name = p_name;
END$$

DROP PROCEDURE IF EXISTS sp_remove_holiday$$
CREATE PROCEDURE sp_remove_holiday(IN p_date DATE, OUT p_removed INT)
BEGIN
    DELETE FROM holidays WHERE holiday_date = p_date;
    SET p_removed = ROW_COUNT();
END$$

-- ---------------------------------------------------------------------
-- Report procedures that RETURN A RESULT SET.
-- ---------------------------------------------------------------------

-- One row per request type for a day (zeros included): LEFT JOIN + aggregates.
DROP PROCEDURE IF EXISTS sp_daily_summary$$
CREATE PROCEDURE sp_daily_summary(IN p_date DATE)
BEGIN
    SELECT s.name AS service_type, ss.name AS sub_service,
           COALESCE(SUM(t.status = 'WAITING'), 0)   AS waiting,
           COALESCE(SUM(t.status = 'SERVED'), 0)    AS served,
           COALESCE(SUM(t.status = 'CANCELLED'), 0) AS cancelled
      FROM sub_services ss
      JOIN services s ON s.service_id = ss.service_id
      LEFT JOIN tokens t ON t.sub_service_id = ss.sub_service_id AND t.visit_date = p_date
     GROUP BY s.service_id, ss.sub_service_id, s.name, ss.name
     ORDER BY s.service_id, ss.sub_service_id;
END$$

-- Bookings per hour with a running total, built with a CURSOR and a temporary table.
DROP PROCEDURE IF EXISTS sp_hourly_report$$
CREATE PROCEDURE sp_hourly_report(IN p_date DATE)
BEGIN
    DECLARE v_done    INT DEFAULT 0;
    DECLARE v_hour    INT;
    DECLARE v_count   INT;
    DECLARE v_max     INT DEFAULT 0;
    DECLARE v_total   INT DEFAULT 0;
    DECLARE v_running INT DEFAULT 0;

    DECLARE cur_hours CURSOR FOR
        SELECT HOUR(slot_start), COUNT(*)
          FROM tokens
         WHERE visit_date = p_date AND status IN ('WAITING', 'SERVED')
         GROUP BY HOUR(slot_start)
         ORDER BY HOUR(slot_start);
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    DROP TEMPORARY TABLE IF EXISTS tmp_hourly;
    CREATE TEMPORARY TABLE tmp_hourly (
        hour_of_day   INT,
        bookings      INT,
        running_total INT,
        share_pct     DECIMAL(5,1),
        crowd         VARCHAR(6)
    );

    SELECT COALESCE(MAX(c), 0), COALESCE(SUM(c), 0) INTO v_max, v_total
      FROM (SELECT COUNT(*) AS c FROM tokens
             WHERE visit_date = p_date AND status IN ('WAITING', 'SERVED')
             GROUP BY HOUR(slot_start)) h;

    OPEN cur_hours;
    read_loop: LOOP
        FETCH cur_hours INTO v_hour, v_count;
        IF v_done = 1 THEN
            LEAVE read_loop;
        END IF;
        SET v_running = v_running + v_count;
        INSERT INTO tmp_hourly
        VALUES (v_hour, v_count, v_running,
                ROUND(100 * v_count / v_total, 1),
                fn_crowd_label(v_count / v_max));
    END LOOP;
    CLOSE cur_hours;

    SELECT * FROM tmp_hourly ORDER BY hour_of_day;
    DROP TEMPORARY TABLE tmp_hourly;
END$$

DELIMITER ;
