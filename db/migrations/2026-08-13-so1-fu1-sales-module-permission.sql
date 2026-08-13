-- db/migrations/2026-08-13-so1-fu1-sales-module-permission.sql
-- SO-1 续:销售订单从 module.finance.* 切到【module.sales.*】—— 一个真模块的码
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么原来那条判断是错的,三条理由,记在这里而不是留在对话里】
--
-- (a) 【订单是先于财务的商业单据】。销售订单是"答应卖给某人",它发生在任何
--     账目之前;财务拥有的是【事后那一条链】—— sales_records(已经卖了)、
--     invoices(开票)、AR(收款)。把订单挂在 finance.* 上,等于说"要能记账
--     才能接单",而那不是这门生意的顺序。
--
-- (b) 【"跟着数据自己的策略走"对全新的表不成立】。那条经验是用来避免给既有
--     数据换一套没人想过的权限;而这四张表【就是新策略本身】—— 它们没有历史
--     可跟随。上一刀把它当成一条普适规则套了上去,那是把一条避免臆断的经验
--     用成了一次臆断。
--
-- (c) 【上一刀自己查出来的那个分叉,正是证据】:录一笔销售要的是
--     module.output.edit,不是 finance.*。也就是说【销售的操作面从来就不归财务】,
--     而订单是销售操作面的一部分。那个"分叉"不是需要 Tim 拍板的两难,
--     它是"finance 这个答案本来就不对"的证明。
--
-- 【为什么开一个新模块码是目录在正常工作,而不是权限膨胀】
-- module.* 这一层描述的是【业务模块】。销售是一个真模块:它有自己的单据、
-- 自己的角色(线上 sales 角色早就在)、自己的操作面。给它一个码,与 /margin
-- 当初被否掉的"合成一个新码"不是一回事 —— 那一次是为【一张跨模块的报表】
-- 造一个不对应任何模块的码,于是它必然成为"谁能看毛利"的第二份定义
-- (AGENTS.md 常设决定 2)。这一次的码对应一个真实存在的模块边界。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【授权集合 —— 按现有模块的房规】
--   sales    view + edit   —— 这个模块的主人
--   admin    view + edit   —— 与其余每个模块一致
--   gm       view + edit   —— 同上
--   auditor  view          —— 只读,与它在其余模块上的形状一致
-- 【finance 一个都不给,而这是一次明写的决定】:理由 (a) —— 财务拥有的是事后
-- 那条链。这意味着【今天持 finance.* 的人打不开订单页】,这是切换的直接后果,
-- 不是遗漏。真要让财务看订单,那是往 finance 角色上加 module.sales.view 的一行
-- 授权(角色授权是 RUNTIME CONFIG,界面上就能改),而不是把表挂回 finance.*。
--
-- 【NTF-1 的 subject_type 一个字没动】notifications 的 CASE 里今天只有
-- material / storage_location,而【没有任何东西为 sales_orders 发事件】——
-- 加一个没有写入者的主体类型,与 stock_status 拒绝 committed 是同一条理由。
-- 那张表的 ELSE false 会让它在有人声明之前不可见,这一点也不需要改。
--
-- 镜像:db/tables/{permissions,role_permissions,sales_orders,sales_order_lines,
--       sales_order_history,so_issues}.sql、
--       db/functions/{set_sales_order_status,record_so_issue}.sql。
-- 行为断言:fixture 63 新增 I 臂(三种读者,SET LOCAL ROLE 各走一次)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 目录:两行权限码 ═══════════════════════════════════════════════════
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order)
VALUES
    ('module.sales.view', 'module', 'Sales orders (view)', '销售订单(查看)',
     'Sales orders — read only', '销售订单 —— 只读', 132),
    ('module.sales.edit', 'module', 'Sales orders (edit)', '销售订单(编辑)',
     'Sales orders — create, confirm, cancel, issue', '销售订单 —— 新建、确认、作废、签发', 133);

-- ═══ 2 · 角色授权 ═══════════════════════════════════════════════════════════
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code IN ('module.sales.view', 'module.sales.edit')
 WHERE r.code IN ('admin', 'gm', 'sales');

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r JOIN permissions p ON p.code = 'module.sales.view'
 WHERE r.code = 'auditor';

-- ═══ 3 · RLS:四张表整体换码 ════════════════════════════════════════════════
DROP POLICY "sales_orders select by permission"        ON public.sales_orders;
DROP POLICY "sales_orders insert by permission"        ON public.sales_orders;
DROP POLICY "sales_orders update by permission"        ON public.sales_orders;
DROP POLICY "sales_order_lines select by permission"   ON public.sales_order_lines;
DROP POLICY "sales_order_lines insert by permission"   ON public.sales_order_lines;
DROP POLICY "sales_order_lines update by permission"   ON public.sales_order_lines;
DROP POLICY "sales_order_lines delete by permission"   ON public.sales_order_lines;
DROP POLICY "sales_order_history select by permission" ON public.sales_order_history;
DROP POLICY "so_issues select by permission"           ON public.so_issues;

CREATE POLICY "sales_orders select by permission" ON public.sales_orders
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));
CREATE POLICY "sales_orders insert by permission" ON public.sales_orders
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.sales.edit'::text));
CREATE POLICY "sales_orders update by permission" ON public.sales_orders
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.sales.edit'::text)) WITH CHECK (has_permission('module.sales.edit'::text));

CREATE POLICY "sales_order_lines select by permission" ON public.sales_order_lines
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));
CREATE POLICY "sales_order_lines insert by permission" ON public.sales_order_lines
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.sales.edit'::text));
CREATE POLICY "sales_order_lines update by permission" ON public.sales_order_lines
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.sales.edit'::text)) WITH CHECK (has_permission('module.sales.edit'::text));
CREATE POLICY "sales_order_lines delete by permission" ON public.sales_order_lines
    AS PERMISSIVE FOR DELETE TO authenticated USING (has_permission('module.sales.edit'::text));

CREATE POLICY "sales_order_history select by permission" ON public.sales_order_history
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));
CREATE POLICY "so_issues select by permission" ON public.so_issues
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));

-- ═══ 4 · 两个带调用者检查的函数改码 ══════════════════════════════════════
-- 【七个函数里只有这两个有调用者检查】另外五个是触发器守卫(返回 trigger,
-- 调不动 —— 闸门是触发它们的那次写入)与取号助手 next_sales_order_code。
-- 取线上 pg_get_functiondef,只替换 require_permission 那一行。

CREATE OR REPLACE FUNCTION public.set_sales_order_status(p_order_id uuid, p_to text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order sales_orders%ROWTYPE;
    v_cust  record;
    v_ok    boolean;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_order FROM sales_orders WHERE id = p_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_order_id::text, '?');
    END IF;

    -- 【允许的去处,逐个状态写出来】
    v_ok := CASE v_order.status
        WHEN 'draft'     THEN p_to IN ('confirmed','cancelled')
        WHEN 'confirmed' THEN p_to IN ('closed','cancelled')
        WHEN 'closed'    THEN false      -- 终态
        WHEN 'cancelled' THEN false      -- 终态
        ELSE false
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'SO_TRANSITION_NOT_ALLOWED|%|%', v_order.status, p_to;
    END IF;

    IF p_to = 'cancelled' AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
        RAISE EXCEPTION 'SO_CANCEL_REASON_REQUIRED|%', v_order.code;
    END IF;

    -- 【确认要看客户的信用冻结】一张确认了的订单是一个承诺;对一个被冻结的
    -- 客户做承诺,与 record_output_sale 拒绝给他发货是同一条判断,只是早一步。
    -- 【只看 credit_hold,不看额度】额度是随敞口变的,而订单还没产生敞口 ——
    -- 拿一个将来的数去拒绝一张今天的单,会把"可能超限"演成"已经超限"。
    IF p_to = 'confirmed' THEN
        SELECT credit_hold, code INTO v_cust FROM customers WHERE id = v_order.customer_id;
        IF v_cust.credit_hold THEN
            RAISE EXCEPTION 'SO_CUSTOMER_ON_HOLD|%', v_cust.code;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM sales_order_lines WHERE sales_order_id = p_order_id) THEN
            RAISE EXCEPTION 'SO_NO_LINES|%', v_order.code;
        END IF;
    END IF;

    -- 上下文标记:让冻结守卫知道是【转换函数】在动状态列(同 po_status_ctx)
    PERFORM set_config('evoltrya.so_status_ctx', '1', true);
    UPDATE sales_orders
       SET status       = p_to,
           confirmed_at = CASE WHEN p_to = 'confirmed' THEN now() ELSE confirmed_at END,
           closed_at    = CASE WHEN p_to = 'closed'    THEN now() ELSE closed_at END,
           cancelled_at = CASE WHEN p_to = 'cancelled' THEN now() ELSE cancelled_at END,
           cancel_reason= CASE WHEN p_to = 'cancelled' THEN p_reason ELSE cancel_reason END,
           updated_at   = now(),
           updated_by   = auth.uid()
     WHERE id = p_order_id;
    PERFORM set_config('evoltrya.so_status_ctx', '', true);

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (p_order_id, p_to, p_reason);

    RETURN jsonb_build_object('id', p_order_id, 'status', p_to);
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_so_issue(p_order_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order sales_orders%ROWTYPE;
    v_next  integer;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_order FROM sales_orders WHERE id = p_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_order_id::text, '?');
    END IF;
    -- 草稿不签发:签发出去的是一份对外承诺,而草稿还不是承诺。
    IF v_order.status = 'draft' THEN
        RAISE EXCEPTION 'SO_NOT_ISSUABLE|%|%', v_order.code, v_order.status;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('so_issue_' || p_order_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next FROM so_issues WHERE sales_order_id = p_order_id;

    INSERT INTO so_issues (sales_order_id, version, file_path, sha256, issued_by)
    VALUES (p_order_id, v_next, p_file_path, p_sha256, auth.uid());

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (p_order_id, 'issued', 'v' || v_next::text);

    RETURN jsonb_build_object('version', v_next);
END;
$function$;

COMMIT;
