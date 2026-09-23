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
-- ★ APR-ROUTE-1 Batch B(2026-09-23,R3):一个账号可以是某人的【额外账号】。
--   员工那一列先查主账号、再回落到 employee_accounts —— 与 account_person() 同一个先后。
--   ☞ 这里【直接连表】而不调 account_person():本视图是属主权限,而属主替得了【表】,
--     替不了【函数的 EXECUTE】(AGENTS.md「属主权限视图替得了表」那一节)——
--     account_person 已从 authenticated 收回,读这张视图的人会撞 42501。
--   新增的末列 account_kind:'primary' | 'additional' | NULL(没关联任何人)。
--   /settings/accounts 靠它决定这一行给哪一块控件。
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
          WHERE ur.user_id = u.id AND ur.revoked_at IS NULL AND r.deleted_at IS NULL), '[]'::jsonb) AS roles,
        CASE
            WHEN ep.id IS NOT NULL THEN 'primary'::text
            WHEN ea.employee_id IS NOT NULL THEN 'additional'::text
            ELSE NULL::text
        END AS account_kind
   FROM auth.users u
     LEFT JOIN employees ep ON ep.user_id = u.id AND ep.deleted_at IS NULL
     LEFT JOIN employee_accounts ea ON ea.user_id = u.id
     LEFT JOIN employees e ON e.id = COALESCE(ep.id, ea.employee_id) AND e.deleted_at IS NULL
  WHERE has_permission('action.manage_permissions'::text);
