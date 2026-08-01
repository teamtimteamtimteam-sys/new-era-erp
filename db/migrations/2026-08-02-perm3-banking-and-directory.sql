-- db/migrations/2026-08-02-perm3-banking-and-directory.sql
-- Permissions cut 3:银行明细遮蔽 + 权限管理界面所需的读写入口。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 本切让"角色"真正变成 Tim 可以【不改代码、不做迁移】就重塑的东西 —— 那正是
-- cut 1 开篇立下的目标。数据库这边要给三样东西:
--   B1  company_profile 的银行明细收进 data.view_banking(补上 2b 报告里的暴露面)
--   B2  user_directory —— 权限管理界面唯一需要读 auth 架构的地方
--   B3  set_user_roles      —— 授予/撤销角色,撤销【是记录不是删除】
--   B4  set_role_permissions —— 整体替换角色授权,并【在数据库里】强制 edit 蕴含 view
--
-- 【B4 的强制不是洁癖】。2b 的 fixture 量过:只授 edit 不授 view 时,
--   * 纯 INSERT 通过;
--   * INSERT ... RETURNING 【直接 42501】—— 而 PostgREST 默认就带 representation。
-- 于是这个组合不是"少看见几个数",是整条写入路径在应用里当场断掉。界面会挡,
-- 但界面挡不住 RPC 直调,所以真正的守卫必须在这里。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ============================================================================
-- B1. data.view_banking:公司银行明细
-- ============================================================================
-- 【2b 报告里点名的暴露面】:cut 2a 为了让发票抬头渲染,把 company_profile 定为
-- 任何登录用户可读。代价是公司银行账号、SWIFT、户名对【每一个登录员工】可见 ——
-- 包括只持有 module.tasks 的人。抬头要公开,账号不必。
INSERT INTO permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('data.view_banking', 'data', 'View company bank details', '查看公司银行明细',
     'Company bank account name, number, SWIFT and bank address as printed on invoices',
     '开在发票上的公司银行户名、账号、SWIFT 与开户行地址', 230);

-- 只给管理员与财务。【审计角色不给】—— 它是只读岗位,看得见发票本身即可;
-- 收款账号属于"能把钱引到哪里去"的信息,知悉面越小越好。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, 'data.view_banking' FROM roles r WHERE r.code IN ('admin', 'finance');

-- 遮蔽视图,机制与 cut 2b 完全一致:属主权限 + 把模块谓词原样加回视图体。
-- company_profile 在 2a 里的 SELECT 策略是 true(任何登录用户),所以这里没有
-- 额外的行谓词要加回 —— 行访问不变,只是银行列按权限置空。
CREATE VIEW public.company_profile_masked WITH (security_invoker = off) AS
SELECT
    id,
    legal_name,
    registration_no,
    address_lines,
    city,
    postal_code,
    country,
    phone,
    email,
    website,
    CASE WHEN has_permission('data.view_banking') THEN bank_name ELSE NULL END AS bank_name,
    CASE WHEN has_permission('data.view_banking') THEN bank_account_name ELSE NULL END AS bank_account_name,
    CASE WHEN has_permission('data.view_banking') THEN bank_account_no ELSE NULL END AS bank_account_no,
    CASE WHEN has_permission('data.view_banking') THEN bank_swift ELSE NULL END AS bank_swift,
    CASE WHEN has_permission('data.view_banking') THEN bank_address ELSE NULL END AS bank_address,
    invoice_footer_text,
    logo_path,
    updated_at,
    updated_by
FROM public.company_profile;

GRANT SELECT ON public.company_profile_masked TO authenticated;

-- 收回基表的原始银行列。表级 SELECT 蕴含所有列 —— 先整表收回,再逐列授回。
REVOKE SELECT ON public.company_profile FROM authenticated, anon;
GRANT SELECT (id, legal_name, registration_no, address_lines, city, postal_code, country,
              phone, email, website, invoice_footer_text, logo_path, updated_at, updated_by)
    ON public.company_profile TO authenticated;

-- 【发票 PDF 的决定】:PDF 路由【要求 data.view_banking】,没有这个码的人连按钮
-- 都看不到,直接访问路由返回 403。
-- 理由:发票是【要寄出去】的对外单据。银行区块一旦空着,客户就无从付款,而经手人
-- 多半不会察觉自己发出去的是一张残缺的单子 —— "看起来正常但付不了款"比"这份 PDF
-- 你没有权限生成"糟糕得多。所以宁可整份拒绝,并把原因说清楚。
-- 代价:auditor 持有 module.finance.view 但没有 data.view_banking,因此不能下载
-- 发票 PDF —— 它仍然可以在页面上读到发票的全部内容。这是有意的取舍。

-- ============================================================================
-- B2. user_directory:权限管理界面唯一要读 auth 架构的地方
-- ============================================================================
-- 【选视图,不选 SECURITY DEFINER 函数】,理由有三:
--   1. 与 2b 已经确立的机制一致 —— 属主权限视图 + 视图体里的谓词,这套东西项目里
--      已经有 18 个,读的人不必再学第二种模式;
--   2. PostgREST 对视图支持过滤、排序、分页,界面要按邮箱搜、按创建时间排,
--      RPC 返回的 setof 用起来别扭得多;
--   3. 权限检查写在 WHERE 里,天然满足"没有权限的人拿到【零行而不是报错】"——
--      函数要做到这一点得刻意吞掉异常,反而绕。
-- auth.users 不在 PostgREST 暴露的架构里,而视图建在 public 且以属主(postgres)
-- 身份读取,所以这是把 auth 数据【按一条明确的谓词】引出来的唯一出口。
CREATE VIEW public.user_directory WITH (security_invoker = off) AS
SELECT
    u.id                AS user_id,
    u.email::text       AS email,
    u.created_at        AS created_at,
    u.last_sign_in_at   AS last_sign_in_at,
    e.id                AS employee_id,
    e.code              AS employee_code,
    e.legal_name        AS employee_name,
    COALESCE(
        (SELECT jsonb_agg(jsonb_build_object('role_id', r.id, 'code', r.code,
                                             'name_en', r.name_en, 'name_zh', r.name_zh)
                          ORDER BY r.sort_order, r.code)
         FROM user_roles ur
         JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL
           AND r.deleted_at IS NULL),
        '[]'::jsonb
    ) AS roles
FROM auth.users u
LEFT JOIN public.employees e ON e.user_id = u.id AND e.deleted_at IS NULL
-- 【没有 action.manage_permissions 的人在这里拿到零行】,不是报错。
WHERE has_permission('action.manage_permissions');

GRANT SELECT ON public.user_directory TO authenticated;

-- ============================================================================
-- B3. set_user_roles:授予与撤销
-- ============================================================================
-- 【撤销是记录,不是删除】(cut 1 B4 的约定):revoked_at/by/reason 留着,
-- 于是"谁在什么时候因为什么收回了权限"这段历史仍然查得到。
-- cut 1 的最后一个管理员守卫(trg_user_roles_last_admin)照常触发 —— 本函数
-- 不做任何绕过,撤到最后一个管理员时它会抛 LAST_ADMIN_PROTECTED。
CREATE OR REPLACE FUNCTION public.set_user_roles(
    p_user_id uuid,
    p_role_ids uuid[],
    p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_target  uuid[] := COALESCE(p_role_ids, ARRAY[]::uuid[]);
    v_granted uuid[];
    v_revoked uuid[];
BEGIN
    PERFORM require_permission('action.manage_permissions');

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'USER_REQUIRED';
    END IF;

    -- 目标角色必须都存在且在册
    IF EXISTS (
        SELECT 1 FROM unnest(v_target) t(role_id)
        WHERE NOT EXISTS (SELECT 1 FROM roles r WHERE r.id = t.role_id AND r.deleted_at IS NULL)
    ) THEN
        RAISE EXCEPTION 'ROLE_NOT_FOUND';
    END IF;

    -- 新增:目标里有、当前未持有的
    WITH added AS (
        INSERT INTO user_roles (user_id, role_id, granted_by)
        SELECT p_user_id, t.role_id, auth.uid()
        FROM unnest(v_target) t(role_id)
        WHERE NOT EXISTS (
            SELECT 1 FROM user_roles ur
            WHERE ur.user_id = p_user_id AND ur.role_id = t.role_id AND ur.revoked_at IS NULL
        )
        RETURNING role_id
    )
    SELECT array_agg(role_id) INTO v_granted FROM added;

    -- 撤销:当前持有、目标里没有的。【UPDATE 而非 DELETE】。
    -- 最后一个管理员守卫就挂在这条 UPDATE 上,该拦的时候会在这里抛出来。
    WITH revoked AS (
        UPDATE user_roles ur
        SET revoked_at = now(), revoked_by = auth.uid(), revoke_reason = p_reason
        WHERE ur.user_id = p_user_id
          AND ur.revoked_at IS NULL
          AND NOT (ur.role_id = ANY (v_target))
        RETURNING ur.role_id
    )
    SELECT array_agg(role_id) INTO v_revoked FROM revoked;

    RETURN jsonb_build_object(
        'user_id', p_user_id,
        'granted', COALESCE(to_jsonb(v_granted), '[]'::jsonb),
        'revoked', COALESCE(to_jsonb(v_revoked), '[]'::jsonb),
        'roles_now', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('role_id', r.id, 'code', r.code)
                             ORDER BY r.sort_order, r.code)
            FROM user_roles ur JOIN roles r ON r.id = ur.role_id
            WHERE ur.user_id = p_user_id AND ur.revoked_at IS NULL AND r.deleted_at IS NULL
        ), '[]'::jsonb)
    );
END;
$function$;

-- ============================================================================
-- B4. set_role_permissions:整体替换角色授权
-- ============================================================================
-- 【edit 蕴含 view 的强制写在这里,而不是只写在界面里】。
-- 界面当然也要挡(勾 Edit 自动勾 View),但界面挡不住有人直接调 RPC,
-- 而这个组合的后果 2b 已经量过:PostgREST 的 INSERT ... RETURNING 会 42501,
-- 整条写入路径断掉。那不是"配置得不好看",是坏配置,所以数据库必须拒绝。
CREATE OR REPLACE FUNCTION public.set_role_permissions(
    p_role_id uuid,
    p_permission_codes text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_codes   text[] := COALESCE(p_permission_codes, ARRAY[]::text[]);
    v_role    record;
    v_missing text;
    v_bad     text;
BEGIN
    PERFORM require_permission('action.manage_permissions');

    SELECT id, code, is_system INTO v_role
    FROM roles WHERE id = p_role_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ROLE_NOT_FOUND';
    END IF;

    -- 未知权限码直接拒绝(目录是迁移级的,界面不该能凭空造码)
    SELECT c INTO v_bad
    FROM unnest(v_codes) c
    WHERE NOT EXISTS (SELECT 1 FROM permissions p WHERE p.code = c)
    LIMIT 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'PERMISSION_NOT_FOUND|%', v_bad;
    END IF;

    -- 【核心守卫】每一个 module.<m>.edit 都必须有对应的 module.<m>.view 同行
    SELECT split_part(c, '.', 2) INTO v_missing
    FROM unnest(v_codes) c
    WHERE c LIKE 'module.%.edit'
      AND NOT ('module.' || split_part(c, '.', 2) || '.view') = ANY (v_codes)
    LIMIT 1;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'EDIT_REQUIRES_VIEW|%', v_missing;
    END IF;

    -- 系统角色不可被摘掉管理权限 —— 否则一次保存就能把权限系统本身锁死
    IF v_role.is_system AND NOT ('action.manage_permissions' = ANY (v_codes)) THEN
        RAISE EXCEPTION 'SYSTEM_ROLE_PROTECTED';
    END IF;

    DELETE FROM role_permissions WHERE role_id = p_role_id;
    INSERT INTO role_permissions (role_id, permission_code, created_by)
    SELECT p_role_id, c, auth.uid() FROM unnest(v_codes) c;

    RETURN jsonb_build_object(
        'role_id', v_role.id,
        'code', v_role.code,
        'permission_count', array_length(v_codes, 1)
    );
END;
$function$;

NOTIFY pgrst, 'reload schema';

COMMIT;
