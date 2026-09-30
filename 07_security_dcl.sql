-- =====================================================================
-- 07  SECURITY  -  DCL: CREATE USER, ROLES, GRANT, REVOKE
-- NOT run automatically. Run it yourself as an admin (root) if you want
-- separate database accounts for citizens and staff:
--       mysql -u root -p queue_management < sql/07_security_dcl.sql
-- Change the passwords first! Replace queue_management if you renamed the DB.
-- =====================================================================

-- roles = named bundles of permissions
CREATE ROLE IF NOT EXISTS 'queue_citizen';
CREATE ROLE IF NOT EXISTS 'queue_staff';

-- Citizens: only book / cancel through procedures and read their own data through views.
GRANT EXECUTE ON PROCEDURE queue_management.sp_book_token   TO 'queue_citizen';
GRANT EXECUTE ON PROCEDURE queue_management.sp_cancel_token TO 'queue_citizen';
GRANT SELECT  ON queue_management.v_token_details            TO 'queue_citizen';
GRANT SELECT  ON queue_management.sub_services               TO 'queue_citizen';
GRANT SELECT  ON queue_management.services                   TO 'queue_citizen';
GRANT SELECT  ON queue_management.holidays                   TO 'queue_citizen';

-- Staff: everything citizens can do, plus serving, reports and holidays.
GRANT 'queue_citizen' TO 'queue_staff';
GRANT EXECUTE ON PROCEDURE queue_management.sp_serve_next          TO 'queue_staff';
GRANT EXECUTE ON PROCEDURE queue_management.sp_expire_old_tokens   TO 'queue_staff';
GRANT EXECUTE ON PROCEDURE queue_management.sp_add_holiday         TO 'queue_staff';
GRANT EXECUTE ON PROCEDURE queue_management.sp_remove_holiday      TO 'queue_staff';
GRANT EXECUTE ON PROCEDURE queue_management.sp_daily_summary       TO 'queue_staff';
GRANT EXECUTE ON PROCEDURE queue_management.sp_hourly_report       TO 'queue_staff';
GRANT SELECT  ON queue_management.v_service_performance            TO 'queue_staff';
GRANT SELECT  ON queue_management.activity_log                     TO 'queue_staff';

-- real accounts that get a role
CREATE USER IF NOT EXISTS 'counter_clerk'@'localhost' IDENTIFIED BY 'ChangeMe#123';
CREATE USER IF NOT EXISTS 'kiosk_user'@'localhost'    IDENTIFIED BY 'ChangeMe#456';
GRANT 'queue_staff'   TO 'counter_clerk'@'localhost';
GRANT 'queue_citizen' TO 'kiosk_user'@'localhost';
-- MySQL 8:  SET DEFAULT ROLE 'queue_staff' TO 'counter_clerk'@'localhost';
--           SET DEFAULT ROLE 'queue_citizen' TO 'kiosk_user'@'localhost';

-- take a permission away again
REVOKE SELECT ON queue_management.holidays FROM 'queue_citizen';

-- inspect
SHOW GRANTS FOR 'queue_citizen';
SHOW GRANTS FOR 'queue_staff';

-- clean up (remove the two dashes to run):
-- DROP USER IF EXISTS 'counter_clerk'@'localhost';
-- DROP USER IF EXISTS 'kiosk_user'@'localhost';
-- DROP ROLE IF EXISTS 'queue_staff';
-- DROP ROLE IF EXISTS 'queue_citizen';
