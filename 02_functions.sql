-- =====================================================================
-- 02  STORED FUNCTIONS  (return ONE value, can be used inside SELECT)
-- Topics: DETERMINISTIC vs READS SQL DATA, IF, CASE, WHILE loop, EXISTS
-- =====================================================================
DELIMITER $$

DROP FUNCTION IF EXISTS fn_make_token_no$$
CREATE FUNCTION fn_make_token_no(p_prefix VARCHAR(4), p_abbrev VARCHAR(6), p_number INT)
RETURNS VARCHAR(20)
DETERMINISTIC
BEGIN
    -- ('AC','DOB',7)  ->  'AC-DOB-0007'
    RETURN CONCAT(p_prefix, '-', p_abbrev, '-', LPAD(p_number, 4, '0'));
END$$

DROP FUNCTION IF EXISTS fn_mask_contact$$
CREATE FUNCTION fn_mask_contact(p_contact CHAR(10))
RETURNS VARCHAR(10)
DETERMINISTIC
BEGIN
    RETURN CONCAT('XXXXXX', RIGHT(p_contact, 4));
END$$

DROP FUNCTION IF EXISTS fn_is_working_day$$
CREATE FUNCTION fn_is_working_day(p_date DATE)
RETURNS TINYINT(1)
READS SQL DATA
BEGIN
    IF WEEKDAY(p_date) IN (5, 6) THEN           -- Saturday, Sunday
        RETURN 0;
    END IF;
    IF EXISTS (SELECT 1 FROM holidays WHERE holiday_date = p_date) THEN
        RETURN 0;
    END IF;
    RETURN 1;
END$$

DROP FUNCTION IF EXISTS fn_next_working_day$$
CREATE FUNCTION fn_next_working_day(p_date DATE)
RETURNS DATE
READS SQL DATA
BEGIN
    DECLARE v_day DATE DEFAULT DATE_ADD(p_date, INTERVAL 1 DAY);
    WHILE fn_is_working_day(v_day) = 0 DO
        SET v_day = DATE_ADD(v_day, INTERVAL 1 DAY);
    END WHILE;
    RETURN v_day;
END$$

DROP FUNCTION IF EXISTS fn_crowd_label$$
CREATE FUNCTION fn_crowd_label(p_ratio DECIMAL(5,2))
RETURNS VARCHAR(6)
DETERMINISTIC
BEGIN
    RETURN CASE
        WHEN p_ratio < 0.34 THEN 'Low'
        WHEN p_ratio < 0.67 THEN 'Medium'
        ELSE 'High'
    END;
END$$

-- Highest number of people booked at the same moment inside [p_start, p_end)
-- for one department. Checked in 15-minute steps, exactly like the Python scheduler.
DROP FUNCTION IF EXISTS fn_max_concurrent$$
CREATE FUNCTION fn_max_concurrent(p_service_id INT, p_date DATE, p_start TIME, p_end TIME)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_unit  INT DEFAULT TIME_TO_SEC(p_start) DIV 60;
    DECLARE v_end_m INT DEFAULT TIME_TO_SEC(p_end) DIV 60;
    DECLARE v_max   INT DEFAULT 0;
    DECLARE v_count INT DEFAULT 0;

    WHILE v_unit < v_end_m DO
        SELECT COUNT(*) INTO v_count
          FROM tokens t
          JOIN sub_services ss ON ss.sub_service_id = t.sub_service_id
         WHERE ss.service_id = p_service_id
           AND t.visit_date  = p_date
           AND t.status IN ('WAITING', 'SERVED')
           AND t.slot_start <= SEC_TO_TIME(v_unit * 60)
           AND t.slot_end    > SEC_TO_TIME(v_unit * 60);
        IF v_count > v_max THEN
            SET v_max = v_count;
        END IF;
        SET v_unit = v_unit + 15;
    END WHILE;
    RETURN v_max;
END$$

-- How many WAITING people are ahead of this token in the same request-type queue.
DROP FUNCTION IF EXISTS fn_people_ahead$$
CREATE FUNCTION fn_people_ahead(p_token_id INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_result INT DEFAULT 0;
    SELECT COUNT(*) INTO v_result
      FROM tokens me
      JOIN tokens other
        ON other.sub_service_id = me.sub_service_id
       AND other.visit_date     = me.visit_date
       AND other.status         = 'WAITING'
       AND (other.slot_start < me.slot_start
            OR (other.slot_start = me.slot_start AND other.token_id < me.token_id))
     WHERE me.token_id = p_token_id AND me.status = 'WAITING';
    RETURN v_result;
END$$

DELIMITER ;
