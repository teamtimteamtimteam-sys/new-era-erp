-- db/views/user_directory.sql
-- 系统账号目录:权限管理界面唯一需要读 auth 架构的地方。
--
-- 【选视图而不是 SECURITY DEFINER 函数】:与 2b 已确立的属主权限视图机制一致;
-- PostgREST 对视图支持过滤/排序/分页(界面要按邮箱搜、按时间排);而且权限检查
-- 写在 WHERE 里,天然满足"没有权限的人拿到【零行而不是报错】"。
--
-- auth.users 不在 PostgREST 暴露的架构里;本视图建在 public 且以属主身份读取,
-- 是把 auth 数据按一条明确谓词引出来的唯一出口。
--
-- NOTE: introduced by db/migrations/2026-08-02-perm3-banking-and-directory.sql.

CREATE VIEW public.user_directory WITH (security_invoker = off) AS
 SELECT u.id AS user_id,
    u.email::text AS email,
    u.created_at,
    u.last_sign_in_at,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('role_id', r.id, 'code', r.code, 'name_en', r.name_en, 'name_zh', r.name_zh) ORDER BY r.sort_order, r.code) AS jsonb_agg
           FROM user_roles ur
             JOIN roles r ON r.id = ur.role_id
          WHERE ur.user_id = u.id AND ur.revoked_at IS NULL AND r.deleted_at IS NULL), '[]'::jsonb) AS roles
   FROM auth.users u
     LEFT JOIN employees e ON e.user_id = u.id AND e.deleted_at IS NULL
  WHERE has_permission('action.manage_permissions'::text);
