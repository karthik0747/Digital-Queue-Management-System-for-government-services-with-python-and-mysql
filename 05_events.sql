-- =====================================================================
-- 05  EVENTS  (scheduled jobs inside MySQL - like a cron job)
-- They only run when the event scheduler is ON. Turn it on once with an
-- admin account:   SET GLOBAL event_scheduler = ON;
-- Check with:      SHOW VARIABLES LIKE 'event_scheduler';
-- =====================================================================

-- Every night at 00:05: mark yesterday's unused WAITING tokens as EXPIRED.
DROP EVENT IF EXISTS ev_expire_old_tokens;
CREATE EVENT ev_expire_old_tokens
    ON SCHEDULE EVERY 1 DAY
    STARTS (TIMESTAMP(CURDATE()) + INTERVAL 1 DAY + INTERVAL 5 MINUTE)
    COMMENT 'Mark unused past tokens as EXPIRED'
DO CALL sp_expire_old_tokens(CURDATE(), @expired_by_event);

-- Every Sunday: delete audit-log rows older than 90 days.
DROP EVENT IF EXISTS ev_purge_old_log;
CREATE EVENT ev_purge_old_log
    ON SCHEDULE EVERY 1 WEEK
    STARTS (TIMESTAMP(CURDATE()) + INTERVAL 1 DAY)
    COMMENT 'Keep the activity log small'
DO DELETE FROM activity_log WHERE logged_at < NOW() - INTERVAL 90 DAY;
