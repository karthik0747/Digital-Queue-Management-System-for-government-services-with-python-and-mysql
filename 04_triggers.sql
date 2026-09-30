-- =====================================================================
-- 04  TRIGGERS  (run automatically on INSERT / UPDATE / DELETE)
-- Topics: BEFORE vs AFTER, NEW / OLD row values, SIGNAL for validation,
--         automatic audit trail
-- =====================================================================
DELIMITER $$

-- ---- validation before a citizen is saved -----------------------------
DROP TRIGGER IF EXISTS trg_citizens_bi$$
CREATE TRIGGER trg_citizens_bi BEFORE INSERT ON citizens
FOR EACH ROW
BEGIN
    IF NEW.contact NOT REGEXP '^[0-9]{10}$' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'INVALID_CONTACT: contact number must be exactly 10 digits';
    END IF;
    IF NEW.age < 1 OR NEW.age > 120 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'INVALID_AGE: age must be between 1 and 120';
    END IF;
    SET NEW.name = TRIM(NEW.name);
END$$

DROP TRIGGER IF EXISTS trg_citizens_bu$$
CREATE TRIGGER trg_citizens_bu BEFORE UPDATE ON citizens
FOR EACH ROW
BEGIN
    IF NEW.age < 1 OR NEW.age > 120 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'INVALID_AGE: age must be between 1 and 120';
    END IF;
END$$

-- ---- rules for tokens ---------------------------------------------------
DROP TRIGGER IF EXISTS trg_tokens_bi$$
CREATE TRIGGER trg_tokens_bi BEFORE INSERT ON tokens
FOR EACH ROW
BEGIN
    IF NEW.slot_end <= NEW.slot_start THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'INVALID_SLOT: slot end must be after slot start';
    END IF;
    SET NEW.token_no = UPPER(NEW.token_no);
END$$

-- A SERVED / CANCELLED / EXPIRED token can never go back to another status.
DROP TRIGGER IF EXISTS trg_tokens_bu$$
CREATE TRIGGER trg_tokens_bu BEFORE UPDATE ON tokens
FOR EACH ROW
BEGIN
    DECLARE v_msg VARCHAR(128);
    IF OLD.status <> 'WAITING' AND NEW.status <> OLD.status THEN
        SET v_msg = CONCAT('INVALID_STATUS_CHANGE: ', OLD.status, ' token cannot become ', NEW.status);
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
END$$

-- ---- automatic audit trail (activity_log) -----------------------------
DROP TRIGGER IF EXISTS trg_tokens_ai$$
CREATE TRIGGER trg_tokens_ai AFTER INSERT ON tokens
FOR EACH ROW
BEGIN
    INSERT INTO activity_log (logged_at, message)
    VALUES (NOW(), CONCAT('Booked ', NEW.token_no, ' for ', NEW.visit_date, ' ',
                          TIME_FORMAT(NEW.slot_start, '%H:%i')));
END$$

DROP TRIGGER IF EXISTS trg_tokens_au$$
CREATE TRIGGER trg_tokens_au AFTER UPDATE ON tokens
FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO activity_log (logged_at, message)
        VALUES (NOW(), CONCAT(NEW.token_no, ': ', OLD.status, ' -> ', NEW.status));
    END IF;
END$$

DROP TRIGGER IF EXISTS trg_holidays_ai$$
CREATE TRIGGER trg_holidays_ai AFTER INSERT ON holidays
FOR EACH ROW
BEGIN
    INSERT INTO activity_log (logged_at, message)
    VALUES (NOW(), CONCAT('Holiday added: ', NEW.holiday_date, ' ', NEW.name));
END$$

DROP TRIGGER IF EXISTS trg_holidays_ad$$
CREATE TRIGGER trg_holidays_ad AFTER DELETE ON holidays
FOR EACH ROW
BEGIN
    INSERT INTO activity_log (logged_at, message)
    VALUES (NOW(), CONCAT('Holiday removed: ', OLD.holiday_date, ' ', OLD.name));
END$$

DELIMITER ;
