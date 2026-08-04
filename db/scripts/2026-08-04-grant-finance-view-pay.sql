-- db/scripts/2026-08-04-grant-finance-view-pay.sql
-- FIN-4 D 部分(已拍板):财务做银行对账,对账单上本来就一人一行看得见净额,
-- 系统内再遮只会挡住对账。给 finance 角色加 data.view_pay。
-- 【纯数据】角色授权是运行期配置,不进迁移、不进镜像(同 role-set-reshape)。
-- 此后财务【多看见】的:payroll_lines_masked 的五个按人头金额、employees_masked 的
-- 月薪列、employment_history 的调薪前后值、绩效评估里的调薪、假期折算金额。
BEGIN;
INSERT INTO role_permissions (role_id, permission_code)
SELECT id, 'data.view_pay' FROM roles WHERE code = 'finance'
ON CONFLICT DO NOTHING;
COMMIT;
