-- db/migrations/2026-09-23-aproute1b-one-person-several-accounts-and-gm-reads.sql
-- ════════════════════════════════════════════════════════════════════════════
-- APR-ROUTE-1 · Batch B:一个人,几个账号(R3)· gm 只读(Tim,2026-09-23)
-- ════════════════════════════════════════════════════════════════════════════
--
-- ★★★ 审批是【开着】的,而且本刀一刻也不碰那个开关。★★★
-- 自证 ① 钉住它;② 钉住"一行留痕都没写、每一条链的在途张数都没变"。
-- 本刀的 DML 只有一处:从 gm 上删掉 14 行 role_permissions(全部 *.edit)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【Tim 的裁定,本刀照做】(全文:docs/handbacks/APR-ROUTE-1.md 的 Batch B 一节)
-- ════════════════════════════════════════════════════════════════════════════
--   R3  额外账号住在新表 employee_accounts,主账号仍是 employees.user_id;两道守卫
--       让一个账号不可能两处都登记;account_person() 先查主账号再回落到新表 ——
--       current_user_employee() 从此就是 account_person(auth.uid())。
--       采购单的两句裸自批检查、assert_segregated 改为按【人】认;
--       导出、user_directory、batch_audit_trail 认得额外账号。
--       链接/解除只经两支函数(action.manage_permissions),每一次落一行史(Q2);
--       一个在 approval_log 里做过决定的账号不许被链(Q1);面板并排报账号数与人数(Q3)。
--   gm  变成只读:拿掉每一个 *.edit 与 action.*(线上 action.* 为 0),保留全部
--       view 与 data.view_*。不为补偿给 gm 加任何东西。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本刀会让线上立刻发生的事】
-- ════════════════════════════════════════════════════════════════════════════
--   · Vince(gm)从此在 14 个模块里【什么都写不了】:采购单、供应商、客户、报价与
--     销售订单、付款/费用/凭证、财务设置、进料与产出、库存、加工与工单、定价、
--     人事与人事的每一个决定、盘点、任务(★ 连个人任务都建不了)。读一样不少。
--   · 人事三条链(请假 · 医疗 · 绩效)的决定人从 {admin, sandra, vince} 收成
--     {admin, sandra};工单放行 {admin, phua, sandra};盘点过账 5 人。
--     没有一条链落到"除了主角没有人";线上 8 张在途单据没有一张是 Vince 提的
--     或说的是他(grilling 实测)。
--   · R3 在线上【今天不改变任何人的答案】:employee_accounts 建出来是空的,
--     account_person() 对每一个现有账号给出与之前一字不差的答案(自证 ⑤)。
--
-- NOTE: 镜像在同一个提交里更新(AGENTS.md)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- ⓪ 之前的读数
-- ════════════════════════════════════════════════════════════════════════════
CREATE TEMP TABLE aproute1b_before ON COMMIT DROP AS
SELECT (SELECT approvals_enabled FROM finance_settings LIMIT 1)                        AS enabled,
       (SELECT count(*) FROM approval_log)                                             AS approval_log_rows,
       (SELECT count(*) FROM leave_requests      WHERE status='pending'   AND deleted_at IS NULL) AS leave_pending,
       (SELECT count(*) FROM medical_claims      WHERE status='submitted' AND deleted_at IS NULL) AS claims_pending,
       (SELECT count(*) FROM performance_reviews WHERE status='submitted')             AS reviews_pending,
       (SELECT count(*) FROM purchase_orders     WHERE approval_status='pending' AND deleted_at IS NULL) AS po_pending,
       (SELECT count(*) FROM work_orders         WHERE status='draft')                 AS wo_draft,
       (SELECT count(*) FROM expense_claims      WHERE status='submitted')             AS claim_pending,
       (SELECT count(*) FROM stocktakes          WHERE status='open' AND deleted_at IS NULL) AS stocktake_open,
       (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'gm') AS gm_codes,
       (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'gm' AND (rp.permission_code LIKE '%.edit' OR rp.permission_code LIKE 'action.%')) AS gm_write_codes;

-- 每一个现有账号今天是谁 —— 自证 ⑤ 要拿它比
CREATE TEMP TABLE aproute1b_people_before ON COMMIT DROP AS
SELECT u.id AS user_id, account_person(u.id) AS person
  FROM auth.users u;

DO $prologue$
DECLARE b record;
BEGIN
    SELECT * INTO b FROM aproute1b_before;
    RAISE NOTICE 'APRROUTE1B_BEFORE enabled=% approval_log=% leave=% medclaims=% reviews=% po_pending=% wo_draft=% expense_claims_submitted=% stocktakes_open=% gm_codes=% gm_write_codes=%',
        b.enabled, b.approval_log_rows, b.leave_pending, b.claims_pending, b.reviews_pending,
        b.po_pending, b.wo_draft, b.claim_pending, b.stocktake_open, b.gm_codes, b.gm_write_codes;
    IF b.enabled IS NOT TRUE THEN
        RAISE EXCEPTION 'APRROUTE1B_PRECONDITION|approvals_enabled is % —— 本刀假设审批是开着的', b.enabled;
    END IF;
    -- gm 的前提:grilling 读到 34 个码,其中 14 个写码、0 个 action.*
    IF b.gm_codes <> 34 OR b.gm_write_codes <> 14 THEN
        RAISE EXCEPTION 'APRROUTE1B_PRECONDITION|gm 持 % 个码(写码 %),grilling 读到的是 34 / 14 —— 有人改过 gm,停下', b.gm_codes, b.gm_write_codes;
    END IF;
    -- 没有一张在途单据是 Vince 提的或说的是他(grilling 实测);变了就停下
    IF EXISTS (SELECT 1 FROM leave_requests lr JOIN employees e ON e.id = lr.employee_id
                WHERE lr.status='pending' AND lr.deleted_at IS NULL
                  AND (e.user_id IN (SELECT user_id FROM real_role_holders('gm'))
                       OR lr.created_by IN (SELECT user_id FROM real_role_holders('gm'))))
       OR EXISTS (SELECT 1 FROM medical_claims mc JOIN employees e ON e.id = mc.employee_id
                WHERE mc.status='submitted' AND mc.deleted_at IS NULL
                  AND (e.user_id IN (SELECT user_id FROM real_role_holders('gm'))
                       OR mc.created_by IN (SELECT user_id FROM real_role_holders('gm')))) THEN
        RAISE EXCEPTION 'APRROUTE1B_PRECONDITION|有一张在途的人事单据与 gm 的持有人有关 —— 本刀会改它的决定人,停下报告';
    END IF;
END
$prologue$;

-- ════════════════════════════════════════════════════════════════════════════
-- ① 守卫函数(表之前 —— 表上的触发器引用它们)
-- ════════════════════════════════════════════════════════════════════════════
-- ── db/functions/guard_employee_account_not_primary.sql ──
CREATE OR REPLACE FUNCTION public.guard_employee_account_not_primary()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    SELECT e.code INTO v_code FROM employees e WHERE e.user_id = NEW.user_id LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_IS_PRIMARY|%', v_code;
    END IF;
    RETURN NEW;
END;
$function$;

-- ── db/functions/guard_employee_user_not_additional.sql ──
CREATE OR REPLACE FUNCTION public.guard_employee_user_not_additional()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    IF NEW.user_id IS NULL THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.user_id IS NOT DISTINCT FROM OLD.user_id THEN
        RETURN NEW;
    END IF;
    SELECT e.code INTO v_code
      FROM employee_accounts ea JOIN employees e ON e.id = ea.employee_id
     WHERE ea.user_id = NEW.user_id;
    IF FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_IS_ADDITIONAL|%', v_code;
    END IF;
    RETURN NEW;
END;
$function$;

-- ── db/functions/guard_employee_account_history_append_only.sql ──
CREATE OR REPLACE FUNCTION public.guard_employee_account_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'HISTORY_APPEND_ONLY';
END;
$function$;


-- ════════════════════════════════════════════════════════════════════════════
-- ② 两张新表 + employees 上那一侧的守卫
-- ════════════════════════════════════════════════════════════════════════════
-- ── db/tables/employee_accounts.sql ──
CREATE TABLE public.employee_accounts (
    user_id      uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
    employee_id  uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    linked_at    timestamptz NOT NULL DEFAULT now(),
    linked_by    uuid
);

CREATE INDEX idx_employee_accounts_employee ON public.employee_accounts (employee_id);

COMMENT ON TABLE public.employee_accounts IS
    'APR-ROUTE-1 Batch B(R3):一个人的【额外】登录账号。employees.user_id 仍是主账号;一个账号最多属于一个人(主键),且不许既是主账号又在本表里(guard_employee_account_not_primary · guard_employee_user_not_additional)。"这个账号是谁"的唯一定义是 account_person()。只经 link_additional_account / unlink_additional_account 写(action.manage_permissions),每一次都落 employee_account_history。';

-- ★ 一个账号不许同时是某人的主账号 —— 本表这一侧的守卫
CREATE TRIGGER trg_employee_accounts_not_primary
    BEFORE INSERT OR UPDATE ON public.employee_accounts
    FOR EACH ROW EXECUTE FUNCTION public.guard_employee_account_not_primary();

-- 迁移以 postgres 建表,本来就没有 anon;重建的 prelude 会多给一份 —— 显式收掉
-- (scripts/check-anon-grant-decision.mjs 要求每一张新表对 anon 表态)。
REVOKE ALL ON public.employee_accounts FROM anon;

ALTER TABLE public.employee_accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "employee_accounts select"
    ON public.employee_accounts
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text)
           OR has_permission('action.manage_permissions'::text)
           OR user_id = auth.uid());

-- ── db/tables/employee_account_history.sql ──
CREATE TABLE public.employee_account_history (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seq            bigint NOT NULL GENERATED BY DEFAULT AS IDENTITY UNIQUE,
    action         text NOT NULL CHECK (action IN ('linked', 'unlinked')),
    user_id        uuid NOT NULL,
    employee_id    uuid NOT NULL,
    actor_user_id  uuid,
    changed_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_employee_account_history_user
    ON public.employee_account_history (user_id, seq);

COMMENT ON TABLE public.employee_account_history IS
    'APR-ROUTE-1 Batch B(Q2):额外账号的链接与解除,只增不改。谁、什么时候、把哪个账号链到(或解除出)哪个人。唯一写入者是 link_additional_account / unlink_additional_account。approval_log.self_decided 记的是做决定那一刻的事实,解除链接不回头改它 —— 本表就是"那一刻它属于谁"的证词。读的门 action.manage_permissions,与谁改得了它同一个码。';

CREATE TRIGGER trg_employee_account_history_append_only
    BEFORE UPDATE OR DELETE ON public.employee_account_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_employee_account_history_append_only();

REVOKE ALL ON public.employee_account_history FROM anon;

ALTER TABLE public.employee_account_history ENABLE ROW LEVEL SECURITY;

CREATE POLICY "employee_account_history select by permission"
    ON public.employee_account_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('action.manage_permissions'::text));


CREATE TRIGGER trg_employees_user_not_additional
    BEFORE INSERT OR UPDATE OF user_id ON public.employees
    FOR EACH ROW EXECUTE FUNCTION public.guard_employee_user_not_additional();

-- ════════════════════════════════════════════════════════════════════════════
-- ③ "这个账号是谁"—— 一份定义,回落到新表;current_user_employee 就是它
-- ════════════════════════════════════════════════════════════════════════════
-- ── db/functions/account_person.sql ──
CREATE OR REPLACE FUNCTION public.account_person(p_user uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(
        (SELECT e.id FROM employees e
          WHERE p_user IS NOT NULL AND e.user_id = p_user AND e.deleted_at IS NULL
          LIMIT 1),
        -- ★ Batch B:额外账号。一个已删的员工不是一个"人"(与主账号那一支同一条)。
        (SELECT e.id FROM employee_accounts ea
           JOIN employees e ON e.id = ea.employee_id AND e.deleted_at IS NULL
          WHERE p_user IS NOT NULL AND ea.user_id = p_user));
$function$;

COMMENT ON FUNCTION public.account_person(uuid) IS
'APR-ROUTE-1(R3):"这个账号是哪一个人"的唯一定义 —— 返回它所属的在册员工 id(先查主账号 employees.user_id,再回落到额外账号 employee_accounts),不属于任何员工时返回 NULL。current_user_employee()、自批拒绝(self_leg)、R2 的自批标记与 R4 的"别人批得动吗"(approval_deciders)全部经由它认人。EXECUTE 已从 authenticated 收回 —— 它回答任意一个账号是谁。';

-- ── db/functions/current_user_employee.sql ──
CREATE OR REPLACE FUNCTION public.current_user_employee()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT account_person(auth.uid());
$function$;


-- ════════════════════════════════════════════════════════════════════════════
-- ④ 按【人】认的四处:两句采购单自批 · 职责分离 · 导出 · 主账号关联
-- ════════════════════════════════════════════════════════════════════════════
-- ── db/functions/approve_purchase_order.sql ──
CREATE OR REPLACE FUNCTION public.approve_purchase_order(p_po_id uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po    record;
    v_base  numeric;
    v_level smallint;
BEGIN
    PERFORM require_permission('module.purchasing.view');
    -- ★★【R4:批的人必须看得见他批的那个数】★★(CHAIN-BUILD-1,2026-08-30)
    --   本函数按【金额】选级别(approval_level_for),而金额在 purchase_orders_masked /
    --   purchase_order_lines_masked 上是遮蔽列,门是 data.view_prices。
    --   于是一个只持 module.purchasing.view 的人可以【打开单据、按下批准】,
    --   而屏幕上那一格写着「受限」—— 他批的是一个自己看不见的数字。
    --
    --   【为什么是"要这个权限",不是"在审批路径上解遮蔽"】(4a 的两条路,选了前者)
    --   解遮蔽会开出【第二条看价格的路】,绕过 _masked 那一套 —— 而那一套自己带着
    --   gate 的 colgrant / colreader 两条判词。多一条路 = 多一份定义,正是本仓库
    --   反复付账的那个形状。这里不发明新权限码,只是要求一个【已经存在】的。
    --
    --   【它与开关那道闸不重复,两者问的不是同一件事】
    --     · 开关时问:这个【角色】看得见金额吗(策略层面,可全知,后果是全体)
    --     · 批准时问:这个【人】看得见金额吗(个体层面,权限是多角色的并集)
    --   与 AGENTS.md「决定期间的值:控件禁用 + 服务端独立拒绝」是同一个两道闸的形状。
    PERFORM require_permission('data.view_prices');
    -- APR-2c:审批未生效时,"批准"是一个没有意义的动作 —— 单据本来就已经是 approved。
    -- 点名拒绝,而不是默默成功:后者会让人以为审批流在跑。
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    SELECT id, code, created_by, approval_status, status, currency, fx_rate, estimated_total_ccy
    INTO v_po FROM purchase_orders WHERE id = p_po_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_po_id::text, '?');
    END IF;
    IF v_po.approval_status <> 'pending' THEN
        RAISE EXCEPTION 'PO_NOT_PENDING|%|%', v_po.code, v_po.approval_status;
    END IF;

    -- 【四眼】提单的人不能自己批。与 approve_review 的 SELF_APPROVAL_FORBIDDEN 同名同理。
    -- ★ APR-ROUTE-1 Batch B(R3):按【人】认,不按账号认 —— self_leg 是那一份定义。
    --   同一个人的另一个账号提的单,这里照拒。裸码保留(APR-2 §3)。
    IF self_leg(v_po.created_by, NULL::uuid, auth.uid()) <> 'none' THEN
        RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN';
    END IF;

    -- 【本位币比,用单据自己存的汇率】(决定 3)。FIN-35 删掉了 fx_rate 的默认值,
    -- 所以一张外币单要么带着真汇率,要么根本不存在 —— 这里不必再防平价。
    v_base  := round(v_po.estimated_total_ccy * v_po.fx_rate, 2);
    v_level := approval_level_for(v_base);
    PERFORM require_approver_for(v_level);

    -- PUR-2:告诉 guard_po_amendable 这是一次【状态转换】,不是一次修改。
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法:显式声明,
    -- 而不是让守卫去猜调用方是谁。
    -- 【用完立刻清掉 —— 这一句是 fu2 的全部内容】set_config(..., true) 是
    -- 【事务】局部,不是语句局部。只在函数开头设一次,守卫就会在这次调用之后、
    -- 整个事务余下的时间里【一直是关着的】:跑过一次 close_purchase_order 之后,
    -- 同一事务里一条直连的 UPDATE ... SET status 就畅通无阻(实测过)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders
    SET approval_status = 'approved',
        approved_at = now(),
        approved_by = auth.uid(),
        -- 批准把单据从 draft 推到 confirmed;advance_po_on_receipt 仍按 confirmed 走
        status = CASE WHEN status = 'draft' THEN 'confirmed' ELSE status END,
        updated_by = auth.uid()
    WHERE id = p_po_id;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);


    PERFORM record_approval_decision('purchase_order', p_po_id, 'approved', v_level, p_note);

    RETURN jsonb_build_object('purchase_order_id', p_po_id, 'code', v_po.code,
                              'level', v_level, 'amount_base', v_base);
END;
$function$;

-- ── db/functions/reject_purchase_order.sql ──
CREATE OR REPLACE FUNCTION public.reject_purchase_order(p_po_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po    record;
    v_level smallint;
BEGIN
    PERFORM require_permission('module.purchasing.view');
    -- APR-2c:审批未生效时,"批准"是一个没有意义的动作 —— 单据本来就已经是 approved。
    -- 点名拒绝,而不是默默成功:后者会让人以为审批流在跑。
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    SELECT id, code, created_by, approval_status, currency, fx_rate, estimated_total_ccy
    INTO v_po FROM purchase_orders WHERE id = p_po_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_po_id::text, '?');
    END IF;
    IF v_po.approval_status <> 'pending' THEN
        RAISE EXCEPTION 'PO_NOT_PENDING|%|%', v_po.code, v_po.approval_status;
    END IF;
    -- ★ APR-ROUTE-1 Batch B(R3):按【人】认 —— 与 approve_purchase_order 同一句。
    IF self_leg(v_po.created_by, NULL::uuid, auth.uid()) <> 'none' THEN
        RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REJECT_REASON_REQUIRED';
    END IF;

    -- 驳回也要走同一道授权:能批的人才能驳
    v_level := approval_level_for(round(v_po.estimated_total_ccy * v_po.fx_rate, 2));
    PERFORM require_approver_for(v_level);

    -- PUR-2:告诉 guard_po_amendable 这是一次【状态转换】,不是一次修改。
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法:显式声明,
    -- 而不是让守卫去猜调用方是谁。
    -- 【用完立刻清掉 —— 这一句是 fu2 的全部内容】set_config(..., true) 是
    -- 【事务】局部,不是语句局部。只在函数开头设一次,守卫就会在这次调用之后、
    -- 整个事务余下的时间里【一直是关着的】:跑过一次 close_purchase_order 之后,
    -- 同一事务里一条直连的 UPDATE ... SET status 就畅通无阻(实测过)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders
    SET approval_status = 'rejected', updated_by = auth.uid()
    WHERE id = p_po_id;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);


    PERFORM record_approval_decision('purchase_order', p_po_id, 'rejected', v_level, p_reason);

    RETURN jsonb_build_object('purchase_order_id', p_po_id, 'code', v_po.code, 'level', v_level);
END;
$function$;

-- ── db/functions/assert_segregated.sql ──
CREATE OR REPLACE FUNCTION public.assert_segregated(p_code text, p_first_actors uuid[], p_subject text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_actor uuid := auth.uid();
BEGIN
    -- 【没有主语时不判】auth.uid() 为 NULL 的调用方是迁移、后台作业、service_role ——
    -- 它们本来就绕过 RLS,这里不是一个新洞。但它意味着**以 postgres 跑的 fixture
    -- 不设 claims 就是空转的**(AGENTS.md 反复记过的那种"空洞的臂"),
    -- 所以 db/fixtures/127 每一臂都设 request.jwt.claims。
    IF v_actor IS NULL THEN
        RETURN;
    END IF;

    -- 【空集就是空集,不是"通过"】第一步没有留下主语(例如 created_by 为 NULL)时,
    -- 这条规矩**没有可比的对象**,于是它不适用 —— 而"不适用"与"查过了,没问题"
    -- 不是一回事。这个区别写在 docs/known-issues.md 的 SOD-1-BLIND 条,
    -- 因为它今天对 8 家既有供应商成立。
    IF p_first_actors IS NULL OR cardinality(p_first_actors) = 0 THEN
        RETURN;
    END IF;

    -- ★ APR-ROUTE-1 Batch B(Tim 的 Q8):按【人】认,不按账号认。
    --   同一个人的另一个账号做了第一步,第二步照拒 —— 否则独立 CFO 账号
    --   能给 admin 账号建的供应商付款。"同一个人"只有 self_leg 一份定义。
    IF EXISTS (SELECT 1 FROM unnest(p_first_actors) AS a(u)
                WHERE self_leg(a.u, NULL::uuid, v_actor) <> 'none') THEN
        RAISE EXCEPTION '%|%', p_code, COALESCE(p_subject, '?');
    END IF;
END;
$function$;

-- ── db/functions/export_my_personal_data.sql ──
CREATE OR REPLACE FUNCTION public.export_my_personal_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_emp employees%ROWTYPE;
BEGIN
    -- 【它只导出【调用者自己】的数据】—— 没有参数,拿不到别人的。
    -- ★ APR-ROUTE-1 Batch B(R3):经 current_user_employee() 认人 —— 一个人的
    --   第二个账号导出的也是【他自己】的数据,而不是一句"没有员工档案"。
    SELECT * INTO v_emp FROM employees WHERE id = current_user_employee() AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PDPA_NO_EMPLOYEE_RECORD';
    END IF;

    RETURN jsonb_build_object(
        'generated_at', now(),
        'about', jsonb_build_object(
            'employee_code', v_emp.code, 'legal_name', v_emp.legal_name,
            'preferred_name', v_emp.preferred_name, 'identity_no', v_emp.identity_no,
            'work_email', v_emp.work_email, 'work_phone', v_emp.work_phone,
            'residency_status', v_emp.residency_status,
            'work_pass', jsonb_build_object('type', v_emp.work_pass_type, 'number', v_emp.work_pass_no,
                'issued', v_emp.work_pass_issue_date, 'expires', v_emp.work_pass_expiry_date),
            'employment', jsonb_build_object('type', v_emp.employment_type,
                'category', v_emp.work_category, 'status', v_emp.employment_status,
                'job_title', (SELECT p.title FROM positions p WHERE p.id = v_emp.position_id), 'hire_date', v_emp.hire_date,
                'confirmation_date', v_emp.confirmation_date,
                'separation_date', v_emp.separation_date, 'separation_type', v_emp.separation_type),
            'monthly_salary', v_emp.monthly_salary),
        'employment_history', COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.effective_date)
            FROM employment_history h WHERE h.employee_id = v_emp.id), '[]'::jsonb),
        'leave_requests', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.created_at)
            FROM leave_requests l WHERE l.employee_id = v_emp.id), '[]'::jsonb),
        'medical_claims', COALESCE((SELECT jsonb_agg(to_jsonb(m) ORDER BY m.created_at)
            FROM medical_claims m WHERE m.employee_id = v_emp.id), '[]'::jsonb),
        'payroll_lines', COALESCE((SELECT jsonb_agg(to_jsonb(pl) ORDER BY pl.created_at)
            FROM payroll_lines pl WHERE pl.employee_id = v_emp.id), '[]'::jsonb),
        -- 【绩效评估的【正文】刻意不在这里,而这是一个【法律】问题不是设计问题】
        -- PDPA 对"评价性用途"(evaluative purpose)有豁免,而这一份导出要不要
        -- 包含评估的书面结论,取决于那条豁免怎么适用 —— 那不是我能裁的。
        -- 所以这里只给【存在性与时间】,正文留白,并在 docs/pdpa.md 里点名为待决。
        'performance_reviews_metadata_only', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'review_type', r.review_type, 'period_start', r.period_start,
                'period_end', r.period_end, 'status', r.status) ORDER BY r.period_start)
            FROM performance_reviews r WHERE r.employee_id = v_emp.id), '[]'::jsonb),
        'note', 'Performance review content is deliberately excluded pending a legal view on the PDPA evaluative-purpose exemption. See docs/pdpa.md.');
END;
$function$;

-- ── db/functions/set_user_employee_link.sql ──
CREATE OR REPLACE FUNCTION public.set_user_employee_link(p_user_id uuid, p_employee_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_prev  uuid;
    v_owner uuid;
    v_code  text;
BEGIN
    PERFORM require_permission('action.manage_permissions');

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'USER_REQUIRED';
    END IF;

    -- 目标员工若已经绑在【别的】账号上,拒绝 —— employees.user_id 上的
    -- partial unique index 也会拦,但那样抛出来的是索引名,不是人话。
    IF p_employee_id IS NOT NULL THEN
        SELECT user_id, code INTO v_owner, v_code
        FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND';
        END IF;
        IF v_owner IS NOT NULL AND v_owner <> p_user_id THEN
            RAISE EXCEPTION 'EMPLOYEE_ALREADY_LINKED|%', v_code;
        END IF;
    END IF;

    -- ★ APR-ROUTE-1 Batch B(R3):一个额外账号不许再被设成主账号 ——
    --   先解除那条额外链接(/settings/accounts 的同一块控件)。
    --   employees 上的守卫也会拦,这里先说人话。
    IF p_employee_id IS NOT NULL THEN
        SELECT e.code INTO v_code
          FROM employee_accounts ea JOIN employees e ON e.id = ea.employee_id
         WHERE ea.user_id = p_user_id;
        IF FOUND THEN
            RAISE EXCEPTION 'ACCOUNT_IS_ADDITIONAL|%', v_code;
        END IF;
    END IF;

    SELECT id INTO v_prev FROM employees WHERE user_id = p_user_id;

    -- 解绑旧的 + 绑上新的。两条 UPDATE 在同一个函数体里,
    -- 任何一条失败整个调用回滚 —— 不会再出现"清掉了但没设上"的中间态。
    UPDATE employees SET user_id = NULL
    WHERE user_id = p_user_id
      AND (p_employee_id IS NULL OR id <> p_employee_id);

    IF p_employee_id IS NOT NULL THEN
        UPDATE employees SET user_id = p_user_id WHERE id = p_employee_id;
    END IF;

    RETURN jsonb_build_object(
        'user_id', p_user_id,
        'previous_employee_id', v_prev,
        'employee_id', p_employee_id
    );
END;
$function$;


-- ════════════════════════════════════════════════════════════════════════════
-- ⑤ 链接 / 解除,与面板的人数
-- ════════════════════════════════════════════════════════════════════════════
-- ── db/functions/link_additional_account.sql ──
CREATE OR REPLACE FUNCTION public.link_additional_account(p_user_id uuid, p_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp   employees%ROWTYPE;
    v_code  text;
    v_n     integer;
BEGIN
    PERFORM require_permission('action.manage_permissions');

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'USER_REQUIRED';
    END IF;
    IF p_employee_id IS NULL THEN
        RAISE EXCEPTION 'EMPLOYEE_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_FOUND';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND';
    END IF;
    IF v_emp.user_id IS NULL THEN
        RAISE EXCEPTION 'ADDITIONAL_NEEDS_PRIMARY|%', v_emp.code;
    END IF;

    SELECT e.code INTO v_code FROM employees e WHERE e.user_id = p_user_id LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_IS_PRIMARY|%', v_code;
    END IF;

    SELECT e.code INTO v_code
      FROM employee_accounts ea JOIN employees e ON e.id = ea.employee_id
     WHERE ea.user_id = p_user_id;
    IF FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_ALREADY_ADDITIONAL|%', v_code;
    END IF;

    -- ★ Tim 的 Q1:一个做过决定的账号不许被链到任何人身上
    SELECT count(*) INTO v_n FROM approval_log WHERE actor_user_id = p_user_id;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ACCOUNT_HAS_DECISIONS|%', v_n;
    END IF;

    INSERT INTO employee_accounts (user_id, employee_id, linked_by)
    VALUES (p_user_id, p_employee_id, auth.uid());

    INSERT INTO employee_account_history (action, user_id, employee_id, actor_user_id)
    VALUES ('linked', p_user_id, p_employee_id, auth.uid());

    RETURN jsonb_build_object('user_id', p_user_id, 'employee_id', p_employee_id,
                              'employee_code', v_emp.code, 'linked', true);
END;
$function$;

-- ── db/functions/unlink_additional_account.sql ──
CREATE OR REPLACE FUNCTION public.unlink_additional_account(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp uuid;
BEGIN
    PERFORM require_permission('action.manage_permissions');

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'USER_REQUIRED';
    END IF;

    DELETE FROM employee_accounts WHERE user_id = p_user_id
    RETURNING employee_id INTO v_emp;
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_ADDITIONAL';
    END IF;

    INSERT INTO employee_account_history (action, user_id, employee_id, actor_user_id)
    VALUES ('unlinked', p_user_id, v_emp, auth.uid());

    RETURN jsonb_build_object('user_id', p_user_id, 'employee_id', v_emp, 'linked', false);
END;
$function$;

-- ── db/functions/approvals_readiness.sql ──
CREATE OR REPLACE FUNCTION public.approvals_readiness()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s          record;
    v_blocking   text[] := '{}';
    v_l1_total   integer := 0;  v_l1_real integer := 0;
    v_l2_total   integer := 0;  v_l2_real integer := 0;
    -- APR-ROUTE-1 Batch B(Tim 的 Q3):每一级的【人】数,与账号数并排
    v_l1_people  integer := 0;  v_l2_people integer := 0;
    v_l1_norais  integer := 0;
    v_l1_sees    boolean := false;
    v_l2_sees    boolean := false;
    v_pending    integer := 0;
    v_blocking_p integer := 0;
    v_pendchains jsonb   := '[]'::jsonb;
    v_chains     jsonb   := '[]'::jsonb;
    v_deadchains integer := 0;
    v_owngaps    jsonb   := '[]'::jsonb;
BEGIN
    -- ★ APR-1(N6):此前这里要求 module.finance.view,而 /settings/approvals
    --   那一页的闸是 action.manage_permissions —— **两个码守同一块屏幕**。
    --   今天 admin 与 cco 两个码都持有,所以看不出问题;哪一天有人持前者而不持
    --   后者,那一页会渲染成 readError,而那读起来像"读不到",不像"你没权限"。
    --   这支函数的抬头自己就写着"屏幕与闸读同一份判据"。
    PERFORM require_permission('action.manage_permissions');

    SELECT approvals_enabled, approval_level1_role_code, approval_threshold_base,
           approval_level2_role_code
      INTO v_s FROM finance_settings LIMIT 1;

    -- ── 一级 ──
    IF v_s.approval_level1_role_code IS NULL THEN
        v_blocking := v_blocking || 'approval_level1_role_code'::text;
    ELSE
        SELECT count(*) INTO v_l1_real FROM real_role_holders(v_s.approval_level1_role_code);
        -- ★ Batch B(Q3):同一个人的两个账号只算一个人 —— 经 account_person 认人。
        SELECT count(DISTINCT COALESCE(account_person(h.user_id)::text, 'account:' || h.user_id::text))
          INTO v_l1_people FROM real_role_holders(v_s.approval_level1_role_code) h;
        SELECT count(*) INTO v_l1_total
          FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE r.code = v_s.approval_level1_role_code AND r.is_active AND ur.revoked_at IS NULL;
        v_l1_sees := role_can_see_amounts(v_s.approval_level1_role_code);

        IF v_l1_real = 0 AND v_l1_total > 0 THEN
            v_blocking := v_blocking || 'approval_level1_holder_cannot_sign_in'::text;
        ELSIF v_l1_real = 0 THEN
            v_blocking := v_blocking || 'approval_level1_role_has_no_real_holder'::text;
        END IF;
        IF NOT v_l1_sees THEN
            v_blocking := v_blocking || 'approval_level1_role_cannot_see_amounts'::text;
        END IF;

        -- 【报告,不拦】这个角色的持有人里,有几个是【提不了采购单】的(SOD-1 fu2)。
        SELECT count(*) INTO v_l1_norais
          FROM real_role_holders(v_s.approval_level1_role_code) h
         WHERE NOT EXISTS (
            SELECT 1 FROM user_roles ur2
              JOIN roles r2 ON r2.id = ur2.role_id
              JOIN role_permissions rp ON rp.role_id = r2.id
             WHERE ur2.user_id = h.user_id AND r2.is_active AND ur2.revoked_at IS NULL
               AND rp.permission_code = 'module.purchasing.edit');
    END IF;

    IF v_s.approval_threshold_base IS NULL THEN
        v_blocking := v_blocking || 'approval_threshold_base'::text;
    END IF;

    -- ── 二级:与一级【同等对待】,这正是本刀要的 ──
    IF v_s.approval_level2_role_code IS NULL THEN
        v_blocking := v_blocking || 'approval_level2_role_code'::text;
    ELSE
        SELECT count(*) INTO v_l2_real FROM real_role_holders(v_s.approval_level2_role_code);
        SELECT count(DISTINCT COALESCE(account_person(h.user_id)::text, 'account:' || h.user_id::text))
          INTO v_l2_people FROM real_role_holders(v_s.approval_level2_role_code) h;
        SELECT count(*) INTO v_l2_total
          FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE r.code = v_s.approval_level2_role_code AND r.is_active AND ur.revoked_at IS NULL;
        v_l2_sees := role_can_see_amounts(v_s.approval_level2_role_code);

        IF v_l2_real = 0 AND v_l2_total > 0 THEN
            v_blocking := v_blocking || 'approval_level2_holder_cannot_sign_in'::text;
        ELSIF v_l2_real = 0 THEN
            v_blocking := v_blocking || 'approval_level2_role_has_no_real_holder'::text;
        END IF;
        IF NOT v_l2_sees THEN
            v_blocking := v_blocking || 'approval_level2_role_cannot_see_amounts'::text;
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★ APR-3(Tim 的 Q6):在途张数放宽到【每一条接上引擎的链】,
    --    而 can_disable 仍然只看【关掉之后会批不动的那些】 ★★
    -- ════════════════════════════════════════════════════════════════════════
    -- 两个数长得一样,问的不是同一件事,所以它们是两个字段 ——
    -- 而【两个都出自同一支函数】(approval_pending_documents),于是屏幕与闸
    -- 不可能各读一份判据。那一句判别写在那个函数的抬头,下一刀照它回答一次:
    --   **这条链的决定函数,在审批关着的时候还跑不跑得动?**
    --
    -- ★【为什么不把 can_disable 一起放宽】线上今天有一张 submitted 的报销单,
    --   而报销在审批关着时照常批得了 —— 把它算进去会让审批从此【关不掉】,
    --   一个没有人要求过的新约束,而且它看起来会像一个 bug。
    --
    -- ⚠【pending_purchase_orders 这个字段名保留】它喂的是屏幕上那一句
    --   「关掉会怎样」,而那句话说的正是采购单。改名要连着文案一起改,
    --   而本刀没有理由动它 —— 它今天仍然逐字等于 blocks_disable 的那个数,
    --   因为今天只有采购单 blocks_disable。
    SELECT count(*) FILTER (WHERE d.subject_type = 'purchase_order'),
           count(*) FILTER (WHERE d.blocks_disable)
      INTO v_pending, v_blocking_p
      FROM approval_pending_documents() d;

    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'subject_type'), '[]'::jsonb)
      INTO v_pendchains
      FROM (
        SELECT jsonb_build_object(
                   'subject_type',    d.subject_type,
                   'pending',         count(*),
                   'blocks_disable',  bool_or(d.blocks_disable),
                   -- 分不出档的那些单独报出来,不混进计数里读成零
                   'amount_unknown',  count(*) FILTER (WHERE d.amount_base IS NULL)) AS x
          FROM approval_pending_documents() d
         GROUP BY d.subject_type
      ) g;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★ APR-2:屏幕上也要看得见「这条链真的有人批得动吗」 ★★
    -- ════════════════════════════════════════════════════════════════════════
    -- 本函数的抬头写着"屏幕与闸读同一份判据"。APR-2 给 guard_approvals_switch
    -- 加了一道新闸(链的模块门 ∩ 那一级的角色持有人 = 空 → 按名拒),
    -- ★ 所以那道闸【必须】同时出现在这里 —— 否则就又是一块说"可以开"、
    --   而闸会拒绝的屏幕,也就是本函数存在的全部理由的反面。
    --
    -- ⚠ 这里【不】传参,读的是已经落库的那两个角色码 —— 面板说的是
    --   "以现在这条策略,能不能开"。闸那一侧传的是 NEW(它判的是正要写下去的
    --   那条策略),两者的差别写在 approval_gate_intersections 的抬头。
    -- ★★ 只在【两级角色都已经设好】时才问这个问题 —— 而这不是为了少说一句话,
    --    是为了与闸【同序】:guard_approvals_switch 先抛 APPROVALS_POLICY_INCOMPLETE,
    --    根本走不到这道新闸。策略整个没设时,role_code 是 NULL,求交必然全 0,
    --    于是 blocking 会多出第四条 —— 一句【真的、但重复的】话,
    --    它说的还是上面那三条已经说过的事,而它会把"策略没设"与
    --    "策略设好了却没有人批得动"这两种完全不同的状态搅在一起。
    IF v_s.approval_level1_role_code IS NOT NULL
       AND v_s.approval_level2_role_code IS NOT NULL THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'subject_type',     i.subject_type,
                   'action_function',  i.action_function,
                   'level',            i.level,
                   'role_code',        i.role_code,
                   'gate_permissions', to_jsonb(i.gate_permissions),
                   'approvers',        i.approvers)
                   ORDER BY i.subject_type, i.action_function, i.level), '[]'::jsonb),
               count(*) FILTER (WHERE i.approvers = 0)
          INTO v_chains, v_deadchains
          FROM approval_gate_intersections() i;

        IF v_deadchains > 0 THEN
            v_blocking := v_blocking || 'approval_chain_has_no_approver'::text;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- ★★ APR-ROUTE-1(Tim 的 R4 · Q10):【他自己的单,谁来批】—— 忠告,不拦 ★★
        -- ════════════════════════════════════════════════════════════════════
        -- 上面那一段问"这一级有没有任何人"。它答"有"的时候,那个人自己提的、
        -- 或者说的就是他自己的单据,仍然可以没有人批:提单人那条腿拦他,
        -- 而这一级只有他一个人(EMP-SELF-0 的 F2;线上 admin 的大额采购单正是这样)。
        -- 所以这里把每一个【批得动这一级的人】逐个代入成"提单人兼主角",
        -- 再问一次 approval_deciders:除了他自己,还有没有人?
        --   · 没有,而 R2 的例外也不覆盖他  → self_exception = false(他的单会搁死)
        --   · 没有,但 R2 的例外让他自己批  → self_exception = true(只能自批,并被标记)
        -- ★【为什么是忠告】(Tim 的 Q10)线上今天就有这样的格子,而把它做成拦
        --   会让一条 Tim 自己裁定的策略开不起来。★ 等独立 CFO 账号落地、二级有了
        --   第二个人,Tim 会再看一次要不要把它改成拦 —— docs/approvals.md 记着这句。
        -- 【判据只有一份】approval_deciders;这里只是换了一组参数去问它。
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'subject_type',    x.subject_type,
                   'action_function', x.action_function,
                   'level',           x.level,
                   'role_code',       x.role_code,
                   'user_id',         x.user_id,
                   'who',             x.who,
                   'self_exception',  x.self_only)
                   ORDER BY x.subject_type, x.action_function, x.level, x.who), '[]'::jsonb)
          INTO v_owngaps
          FROM (
            SELECT i.subject_type, i.action_function, i.level, i.role_code, p.user_id,
                   COALESCE(e.legal_name, u.email, p.user_id::text) AS who,
                   EXISTS (SELECT 1 FROM approval_deciders(i.subject_type, i.action_function, i.level,
                                             p.user_id, account_person(p.user_id),
                                             v_s.approval_level1_role_code, v_s.approval_level2_role_code) d
                            WHERE d.via_self_exception) AS self_only
              FROM approval_gate_intersections() i
              -- 每一个批得动这一级的【人】,取他的一个账号代入
              CROSS JOIN LATERAL (
                  SELECT DISTINCT ON (d0.person_key) d0.user_id
                    FROM approval_deciders(i.subject_type, i.action_function, i.level,
                                           NULL::uuid, NULL::uuid,
                                           v_s.approval_level1_role_code, v_s.approval_level2_role_code) d0
                   ORDER BY d0.person_key, d0.user_id) p
              LEFT JOIN auth.users u ON u.id = p.user_id
              LEFT JOIN employees e ON e.id = account_person(p.user_id)
             WHERE NOT EXISTS (
                     SELECT 1 FROM approval_deciders(i.subject_type, i.action_function, i.level,
                                        p.user_id, account_person(p.user_id),
                                        v_s.approval_level1_role_code, v_s.approval_level2_role_code) d
                      WHERE NOT d.via_self_exception)
          ) x;
    END IF;

    RETURN jsonb_build_object(
        'enabled',                 v_s.approvals_enabled,
        'level1_role_code',        v_s.approval_level1_role_code,
        'level1_holders_total',    v_l1_total,
        'level1_real_holders',     v_l1_real,
        -- ★ APR-ROUTE-1 Batch B(Q3):账号数与人数并排。独立 CFO 账号落地之后,
        --   二级会是【2 个账号、1 个人】—— 前者说"那个账号是真的",后者说"二级仍然只有一个人"。
        'level1_people',           v_l1_people,
        'level1_can_see_amounts',  v_l1_sees,
        'level1_holders_who_cannot_raise', v_l1_norais,
        'threshold_base',          v_s.approval_threshold_base,
        'level2_role_code',        v_s.approval_level2_role_code,
        'level2_holders_total',    v_l2_total,
        'level2_real_holders',     v_l2_real,
        'level2_people',           v_l2_people,
        'level2_can_see_amounts',  v_l2_sees,
        'pending_purchase_orders', v_pending,
        -- ★ APR-3:逐链的在途张数(屏幕用),与【会挡住关闭的】那个数(闸用)。
        --   两个都从 approval_pending_documents() 来 —— 一份判据,两个问题。
        'pending_by_chain',        v_pendchains,
        'pending_blocking_disable', v_blocking_p,
        -- ★ APR-2:逐条给出"这条链有几个人批得动",而不是一个布尔 ——
        --   与两级持有人给两个数、不给一个布尔是同一条理由:
        --   要分开的是"哪一条链死了、死在哪一级、缺的是哪个码"。
        'chain_gates',             v_chains,
        'chains_without_approver', v_deadchains,
        -- ★ APR-ROUTE-1(R4):一个人自己的单,除了他自己没有人批得动 —— 逐格点名。
        --   忠告,不进 blocking(Tim 的 Q10);own_document_gaps_block = false 跟着返回值走,
        --   与 no_deputy_by_decision 同形:一句只躺在文档里的"这是裁定"会被当成遗漏。
        'own_document_gaps',       v_owngaps,
        'own_document_gaps_block', false,
        'blocking',                to_jsonb(v_blocking),
        'can_enable',              (NOT v_s.approvals_enabled AND cardinality(v_blocking) = 0),
        -- ★ APR-3:判据换成【会被搁死的那些】,与 guard_approvals_switch 的
        --   关闭那一支逐字同源(它读的是同一支函数的同一个过滤条件)。
        'can_disable',             (v_s.approvals_enabled AND v_blocking_p = 0),
        -- 跟着数字走的那句话,不只躺在文档里(与 PARTY-1 的处置同形)
        'no_deputy_by_decision',   true);
END;
$function$;

COMMENT ON FUNCTION public.approvals_readiness() IS
'SOD-1,CHAIN-BUILD-1 改写(2026-08-30):审批开关能不能开,以及开不了缺哪几样 —— 屏幕与闸读同一份判据。★两级【同等对待】★:各返回 holders_total(未撤销的授权数)与 real_holders(真的登录得了的),**两个数而不是一个数加一个布尔**,因为要分开的是三种状态:没人持有 / 有人持有但登录不了 / 有能干活的人 —— 中间那一种若报成"没有持有人",操作的人会去再授一次权,而那个角色已经授过了。持有人判据只有一处定义(real_role_holders)。另报每一级的 can_see_amounts(R4)。**没有代理人、没有升级**:某一级没人就停在那一级,这是裁定,不是遗漏(no_deputy_by_decision 跟着返回值走)。';


-- ════════════════════════════════════════════════════════════════════════════
-- ⑥ 两张属主视图认得额外账号(直接连表 —— 属主替得了表,替不了函数 EXECUTE)
-- ════════════════════════════════════════════════════════════════════════════
-- ── db/views/user_directory.sql ──
CREATE OR REPLACE VIEW public.user_directory WITH (security_invoker = off) AS
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

-- ── db/views/batch_audit_trail.sql ──
CREATE OR REPLACE VIEW public.batch_audit_trail WITH (security_invoker = off) AS
 SELECT batch_kind,
    batch_id,
    occurred_at,
    business_date,
    event_kind,
    module_code,
    has_permission(module_code) AS may_view,
        CASE
            WHEN has_permission(module_code) THEN actor_id
            ELSE NULL::uuid
        END AS actor_id,
    actor_space,
    source_table,
        CASE
            WHEN has_permission(module_code) THEN source_id
            ELSE NULL::uuid
        END AS source_id,
        CASE
            WHEN has_permission(module_code) THEN source_code
            ELSE NULL::text
        END AS source_code,
        CASE
            WHEN has_permission(module_code) THEN href
            ELSE NULL::text
        END AS href,
        CASE
            WHEN has_permission(module_code) THEN detail
            ELSE NULL::jsonb
        END AS detail,
    (seams ||
        CASE
            WHEN ('has_masked_amount'::text = ANY (seams)) AND NOT has_permission('data.view_prices'::text) THEN ARRAY['amount_restricted'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN actor_id IS NOT NULL AND NOT (EXISTS ( SELECT 1
               FROM employees e
              WHERE e.user_id = t.actor_id)) AND NOT (EXISTS ( SELECT 1
               FROM employee_accounts ea
              WHERE ea.user_id = t.actor_id)) THEN ARRAY['actor_unresolvable'::text]
            ELSE ARRAY[]::text[]
        END AS seams
   FROM batch_audit_trail_all t
  WHERE has_any_permission(ARRAY['module.inbound.view'::text, 'module.output.view'::text, 'module.inventory.view'::text, 'module.processing.view'::text, 'module.finance.view'::text, 'module.sales.view'::text, 'module.purchasing.view'::text, 'module.stocktakes.view'::text]);


-- ════════════════════════════════════════════════════════════════════════════
-- ⑦ gm 只读(Tim,2026-09-23)
-- ════════════════════════════════════════════════════════════════════════════
DELETE FROM public.role_permissions rp
 USING public.roles r
 WHERE r.id = rp.role_id AND r.code = 'gm'
   AND (rp.permission_code LIKE '%.edit' OR rp.permission_code LIKE 'action.%');

-- ════════════════════════════════════════════════════════════════════════════
-- ⑧ 自证
-- ════════════════════════════════════════════════════════════════════════════
DO $proof$
DECLARE
    b      record;
    v_n    integer;
    v_src  text;
    v_list text;
BEGIN
    SELECT * INTO b FROM aproute1b_before;

    -- ① 审批仍然开着
    IF (SELECT approvals_enabled FROM finance_settings) IS NOT TRUE THEN
        RAISE EXCEPTION 'APRROUTE1B_PROOF_1|审批不再是开着的';
    END IF;

    -- ② 一行留痕都没写,每一条链的在途张数都没变
    IF (SELECT count(*) FROM approval_log) <> b.approval_log_rows
       OR (SELECT count(*) FROM leave_requests WHERE status='pending' AND deleted_at IS NULL) <> b.leave_pending
       OR (SELECT count(*) FROM medical_claims WHERE status='submitted' AND deleted_at IS NULL) <> b.claims_pending
       OR (SELECT count(*) FROM performance_reviews WHERE status='submitted') <> b.reviews_pending
       OR (SELECT count(*) FROM purchase_orders WHERE approval_status='pending' AND deleted_at IS NULL) <> b.po_pending
       OR (SELECT count(*) FROM work_orders WHERE status='draft') <> b.wo_draft
       OR (SELECT count(*) FROM expense_claims WHERE status='submitted') <> b.claim_pending
       OR (SELECT count(*) FROM stocktakes WHERE status='open' AND deleted_at IS NULL) <> b.stocktake_open THEN
        RAISE EXCEPTION 'APRROUTE1B_PROOF_2|有一个在途计数或留痕行数变了';
    END IF;

    -- ③ gm:恰好剩 20 个码,0 个写码,而且没有少掉任何一个读码
    SELECT count(*) INTO v_n FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'gm';
    IF v_n <> 20 THEN
        RAISE EXCEPTION 'APRROUTE1B_PROOF_3|gm 剩 % 个码,应当是 20', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE r.code = 'gm' AND (rp.permission_code LIKE '%.edit' OR rp.permission_code LIKE 'action.%');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'APRROUTE1B_PROOF_3|gm 还有 % 个写码', v_n;
    END IF;
    SELECT string_agg(c, ',') INTO v_list
      FROM unnest(ARRAY['data.view_banking','data.view_prices','data.view_reviews','data.view_sales',
                        'data.view_self_approvals','module.finance.view','module.hr.view',
                        'module.purchasing.view','module.tasks.view']) c
     WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                        WHERE r.code = 'gm' AND rp.permission_code = c);
    IF v_list IS NOT NULL THEN
        RAISE EXCEPTION 'APRROUTE1B_PROOF_3|gm 丢了读码:%', v_list;
    END IF;
    -- 每一个被拿掉的写码,仍然至少有一个真的持有人(否则那个模块从此谁都写不了)
    SELECT string_agg(c.code, ',') INTO v_list
      FROM (SELECT DISTINCT permission_code AS code FROM role_permissions WHERE permission_code LIKE '%.edit') c
     WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                        CROSS JOIN LATERAL real_role_holders(r.code) h
                        WHERE rp.permission_code = c.code);
    IF v_list IS NOT NULL THEN
        RAISE EXCEPTION 'APRROUTE1B_PROOF_3|这些写码已经没有任何真持有人:%', v_list;
    END IF;

    -- ④ 人事三条链(hr.edit)仍然至少有两个人 —— 于是每一个人自己的单都有别人批
    SELECT count(DISTINCT COALESCE(account_person(h.user_id)::text, h.user_id::text)) INTO v_n
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
      CROSS JOIN LATERAL real_role_holders(r.code) h
     WHERE rp.permission_code = 'module.hr.edit';
    IF v_n < 2 THEN
        RAISE EXCEPTION 'APRROUTE1B_PROOF_4|module.hr.edit 只剩 % 个人 —— 那个人自己的请假/医疗/绩效没人批', v_n;
    END IF;

    -- ⑤ R3 在线上今天不改变任何人的答案:employee_accounts 是空的,
    --    account_person 对每一个现有账号给出与之前一字不差的答案
    SELECT count(*) INTO v_n FROM employee_accounts;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'APRROUTE1B_PROOF_5|employee_accounts 一建出来就有 % 行', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM aproute1b_people_before p
     WHERE account_person(p.user_id) IS DISTINCT FROM p.person;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'APRROUTE1B_PROOF_5|% 个账号的"是谁"变了', v_n;
    END IF;
    SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname='current_user_employee';
    IF v_src NOT LIKE '%account_person(auth.uid())%' THEN
        RAISE EXCEPTION 'APRROUTE1B_PROOF_5|current_user_employee 没有改成 account_person(auth.uid())';
    END IF;

    -- ⑥ 采购单两句自批与职责分离都按人认(读目录,不读这个文件)
    FOR v_list IN SELECT p.proname::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                   WHERE n.nspname='public' AND p.proname IN ('approve_purchase_order','reject_purchase_order','assert_segregated')
                     AND p.prosrc NOT LIKE '%self_leg(%'
    LOOP
        RAISE EXCEPTION 'APRROUTE1B_PROOF_6|% 仍然按账号认人', v_list;
    END LOOP;

    -- ⑦ 两道守卫都挂上了
    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE tgname IN ('trg_employee_accounts_not_primary', 'trg_employees_user_not_additional',
                      'trg_employee_account_history_append_only') AND NOT tgisinternal;
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'APRROUTE1B_PROOF_7|三个触发器只挂上了 % 个', v_n;
    END IF;

    RAISE NOTICE 'APRROUTE1B_AFTER enabled=% approval_log=% expense_claims_submitted=% gm_codes=% gm_write_codes=0 employee_accounts=0',
        (SELECT approvals_enabled FROM finance_settings), (SELECT count(*) FROM approval_log),
        (SELECT count(*) FROM expense_claims WHERE status='submitted'),
        (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'gm');
    RAISE NOTICE 'APRROUTE1B 自证七条全过。';
END
$proof$;

COMMIT;
