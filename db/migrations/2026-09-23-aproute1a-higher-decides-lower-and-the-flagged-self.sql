-- db/migrations/2026-09-23-aproute1a-higher-decides-lower-and-the-flagged-self.sql
-- ════════════════════════════════════════════════════════════════════════════
-- APR-ROUTE-1 · Batch A:高一级批低一级(R1)· 二级持有人的标记自批(R2)·
--                        "除了主角还有没有人批得动"(R4)· 报销单读漏(F1 / R5)
-- ════════════════════════════════════════════════════════════════════════════
--
-- ★★★ 审批是【开着】的,而且本刀一刻也不碰那个开关。★★★
-- 迁移末尾的自证 ① 钉住这件事;② 钉住"一行留痕都没写、每一条链的在途张数都没变"。
-- 本刀的 DML 只有两处:permissions 一行、role_permissions 三行(新码 data.view_self_approvals)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【Tim 的裁定,本刀照做,不再问】(docs/handbacks/APR-ROUTE-1.md 有全文)
-- ════════════════════════════════════════════════════════════════════════════
--   R1  持有更高审批级别的人可以决定分到更低一级的单据 —— 只在分档的金额链上。
--       → approval_level_eligible;require_approver_for 与 approval_deciders 读它。
--   R2  最高一级(今天是 cfo)的持有人可以决定【他自己的】报销单与医疗申报,
--       每一次都在 approval_log 标成自批,并有一张报表(admin · gm · auditor 看得见)。
--       永远不覆盖薪资、绩效、调薪、请假或任何别的类型。
--       → self_approval_exception(规则)· approval_log.self_decided(事实)
--         · approval_log_self_decided_scope(第二道保险)· self_approved_decisions(报表)
--   R3  一个人可以有好几个账号 —— 本刀(Batch A)只铺好"按人认"的那一个入口
--       account_person,它今天只读 employees.user_id。多账号本身是 Batch B。
--   R4  "有没有人批得动"要问的是【除了主角还有没有人】。
--       → approval_deciders;开关的闸、面板、APPROVALS_POLICY_WOULD_STRAND 都读它。
--   R5  expense_claim_status 加行谓词(F1)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本刀会让线上立刻发生的事 —— 审批开着,所以每一条都在提交那一刻生效】
-- ════════════════════════════════════════════════════════════════════════════
--   · admin@swm-os.test(cfo 的唯一真持有人)从此批得了【一级】的采购单与报销单(R1)。
--     ☞ chooer 自己 1000 以下的报销单从此有人批了 —— 那正是 R1 存在的理由。
--   · admin 可以决定【自己的】报销单(任一级)与医疗申报(他也持 module.hr.edit),
--     每一次都被标成 self_decided(R2)。一个只持 cfo 的账号批不了医疗申报:
--     module.hr.edit 那一行在前,例外不放宽任何模块门(Q5)。
--   · 任何一个登录的人,从 expense_claim_status 只读得到自己的报销单,
--     除非他持 module.finance.view(R5)。
--   · 没有任何一条既有的"批得动"被收窄。R1 只放宽,R2 只放宽,
--     forbid_self_approval 对不在例外里的类型一字未变。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【对象清单】
-- ════════════════════════════════════════════════════════════════════════════
--   新建 6 支:account_person · self_leg · self_approval_exception
--             approval_level_eligible · approval_deciders · self_approved_decisions
--   换签名 2 支(DROP + CREATE):forbid_self_approval(多了 p_subject_type)
--                               approval_pending_documents(多了两列)
--   替换 11 支:require_approver_for · approval_gate_intersections · approvals_readiness
--              guard_approvals_switch · record_approval_decision
--              decide_expense_claim · decide_medical_claim · decide_leave_request
--              approve_review · post_stocktake · release_work_order
--              (后六支只改了调 forbid_self_approval 那一行)
--   改 1 张表:approval_log(加列 self_decided + CHECK + 列授权 + 列注释)
--   改 1 张视图:expense_claim_status(行谓词 + 视图注释)
--   种子:permissions +1 · role_permissions +3(RUNTIME CONFIG —— 引导默认值同步写回,
--         见 db/tables/role_permissions.sql;它的值仍然【正确】:新码只多授给
--         admin / gm / auditor 三个角色,别的授权一行没动)
--
-- NOTE: 镜像在同一个提交里更新(AGENTS.md)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- ⓪ 先把【本刀之前】的读数钉在事务里 —— 末尾的自证要拿它比
-- ════════════════════════════════════════════════════════════════════════════
CREATE TEMP TABLE aproute1a_before ON COMMIT DROP AS
SELECT (SELECT approvals_enabled FROM finance_settings LIMIT 1)                        AS enabled,
       (SELECT count(*) FROM approval_log)                                             AS approval_log_rows,
       (SELECT count(*) FROM leave_requests      WHERE status='pending'   AND deleted_at IS NULL) AS leave_pending,
       (SELECT count(*) FROM medical_claims      WHERE status='submitted' AND deleted_at IS NULL) AS claims_pending,
       (SELECT count(*) FROM performance_reviews WHERE status='submitted')             AS reviews_pending,
       (SELECT count(*) FROM purchase_orders     WHERE approval_status='pending' AND deleted_at IS NULL) AS po_pending,
       (SELECT count(*) FROM work_orders         WHERE status='draft')                 AS wo_draft,
       (SELECT count(*) FROM expense_claims      WHERE status='submitted')             AS claim_pending,
       (SELECT count(*) FROM expense_claims)                                           AS claims_total,
       (SELECT count(*) FROM stocktakes          WHERE status='open' AND deleted_at IS NULL) AS stocktake_open;

DO $prologue$
DECLARE b record;
BEGIN
    SELECT * INTO b FROM aproute1a_before;
    RAISE NOTICE 'APRROUTE1A_BEFORE enabled=% approval_log=% leave=% medclaims=% reviews=% po_pending=% wo_draft=% expense_claims_submitted=% expense_claims_total=% stocktakes_open=%',
        b.enabled, b.approval_log_rows, b.leave_pending, b.claims_pending,
        b.reviews_pending, b.po_pending, b.wo_draft, b.claim_pending, b.claims_total, b.stocktake_open;
    IF b.enabled IS NOT TRUE THEN
        RAISE EXCEPTION 'APRROUTE1A_PRECONDITION|approvals_enabled is % —— 本刀假设审批是开着的', b.enabled;
    END IF;
    -- R4 的 Q4 前提:Tim 的 MD 是 Vince,他持 gm。不成立就停,不要 COMMIT。
    IF NOT EXISTS (SELECT 1 FROM real_role_holders('gm') h
                     JOIN employees e ON e.user_id = h.user_id
                    WHERE e.legal_name ILIKE 'Vince%') THEN
        RAISE EXCEPTION 'APRROUTE1A_PRECONDITION|gm 的真持有人里没有 Vince —— Tim 的 Q4 以此为前提';
    END IF;
END
$prologue$;

-- ════════════════════════════════════════════════════════════════════════════
-- ① 新码 data.view_self_approvals,授给 admin · gm · auditor(Tim 的 Q4)
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order)
VALUES ('data.view_self_approvals', 'data', 'View self-approved decisions', '查看自批记录',
        'Every expense claim or medical claim decided by the person it is about — the one exception to "nobody decides their own", open to the top approval level only and flagged every time',
        '每一张由单据主角本人决定的报销单或医疗申报 —— "没有人批自己的单"的唯一例外,只对最高审批级别开放,每一次都被标记',
        270);

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'data.view_self_approvals'
  FROM public.roles r
 WHERE r.code IN ('admin', 'gm', 'auditor') AND r.deleted_at IS NULL;

-- 【断言,不是注释】恰好 3 行。角色表将来若少了一个 code,上面那句 INSERT 会
-- 静默地少插一行,而"少一行"与"本来就这样"长得一模一样(NAV-CLEANUP-1 同一句)。
DO $$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM public.role_permissions WHERE permission_code = 'data.view_self_approvals';
    IF n <> 3 THEN
        RAISE EXCEPTION 'APRROUTE1A_GRANT_COUNT|expected 3 (admin, gm, auditor), got %', n;
    END IF;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- ② approval_log:self_decided(事实)+ 范围 CHECK(第二道保险)+ 列授权
-- ════════════════════════════════════════════════════════════════════════════
-- ★ 加列带 DEFAULT 不经过 UPDATE,所以 trg_approval_log_append_only 不开火 ——
--   本表只增不改的设计不受影响。历史行读 false 是真话:grilling 实测线上 14 行里
--   没有一行"决定人 = 主角";自证 ③ 在事务里把这件事再算一遍。
-- ★ 这是一张【只用列清单遮蔽】的表(check-masked-columns 的那三张之一):
--   列授权不会自动延伸到新列,所以 GRANT 必须在同一支迁移里(AGENTS.md)。
ALTER TABLE public.approval_log ADD COLUMN self_decided boolean NOT NULL DEFAULT false;
ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_self_decided_scope CHECK (
    NOT self_decided OR subject_type IN ('expense_claim', 'medical_claim'));
GRANT SELECT (self_decided) ON public.approval_log TO authenticated;
COMMENT ON COLUMN public.approval_log.self_decided IS
    'APR-ROUTE-1(Tim 的 R2):按下去的这个人,是不是这张单据的提单人或主角(按人认,经 self_leg)。★ 记的是【事实】不是【规则】:由 record_approval_decision 对 approved / rejected 两种决定计算;auto_approved 与 approval_voided 不是一次决定,恒为 false。唯一允许它为 true 的是 Tim 的例外(二级审批角色的持有人决定自己的报销单或医疗申报),approval_log_self_decided_scope 把它钉在这两类上。自批报表 self_approved_decisions() 读它。★ 加列时线上 14 行里没有一行是"决定人 = 主角"的决定(APR-ROUTE-1 grilling 实测),所以 DEFAULT false 对历史行是真话,不是回填。';

-- ════════════════════════════════════════════════════════════════════════════
-- ③ 按人认的入口,与两个"自己"的判据
-- ════════════════════════════════════════════════════════════════════════════
-- ── db/functions/account_person.sql ──
CREATE OR REPLACE FUNCTION public.account_person(p_user uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT e.id FROM employees e
     WHERE p_user IS NOT NULL AND e.user_id = p_user AND e.deleted_at IS NULL
     LIMIT 1;
$function$;

COMMENT ON FUNCTION public.account_person(uuid) IS
'APR-ROUTE-1(R3):"这个账号是哪一个人"的唯一定义 —— 返回它所属的在册员工 id,不属于任何员工时返回 NULL。自批拒绝(self_leg)、R2 的自批标记与 R4 的"别人批得动吗"(approval_deciders)全部经由它认人。★ Batch A 只读 employees.user_id;Batch B 加 employee_accounts 之后只改本函数的函数体。EXECUTE 已从 authenticated 收回 —— 它回答任意一个账号是谁。';

-- ── db/functions/self_leg.sql ──
CREATE OR REPLACE FUNCTION public.self_leg(p_raiser uuid, p_subject_employee uuid, p_user uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_person uuid;
BEGIN
    IF p_user IS NULL THEN
        RETURN 'none';
    END IF;
    v_person := account_person(p_user);

    -- ① 提单的人:同一个账号,或者同一个人的另一个账号
    IF p_raiser IS NOT NULL
       AND (p_raiser = p_user
            OR (v_person IS NOT NULL AND account_person(p_raiser) = v_person)) THEN
        RETURN 'raiser';
    END IF;

    -- ② 单据说的是谁
    IF p_subject_employee IS NOT NULL AND v_person IS NOT NULL
       AND p_subject_employee = v_person THEN
        RETURN 'subject';
    END IF;

    RETURN 'none';
END;
$function$;

COMMENT ON FUNCTION public.self_leg(uuid, uuid, uuid) IS
'APR-ROUTE-1:账号 p_user 相对于一份单据(提单人 p_raiser、主角 p_subject_employee)是不是"自己",是的话是哪条腿 —— raiser | subject | none,永不返回 NULL。raiser 先判(与 APR-2 同序);"同一个人"经 account_person 按人认(R3)。三个读者:forbid_self_approval(拒不拒)· record_approval_decision(self_decided)· approval_deciders(R4 的"别人")。EXECUTE 已从 authenticated 收回。';

-- ── db/functions/self_approval_exception.sql ──
CREATE OR REPLACE FUNCTION public.self_approval_exception(p_subject_type text, p_subject_employee uuid, p_user uuid, p_level2_role text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(
               p_subject_type IN ('expense_claim', 'medical_claim')
           AND p_subject_employee IS NOT NULL
           AND p_user IS NOT NULL
           AND p_level2_role IS NOT NULL
           AND account_person(p_user) = p_subject_employee
           AND EXISTS (SELECT 1 FROM real_role_holders(p_level2_role) h WHERE h.user_id = p_user),
           false);
$function$;

COMMENT ON FUNCTION public.self_approval_exception(text, uuid, uuid, text) IS
'APR-ROUTE-1(R2):"不许自己批自己"的唯一例外 —— 单据是 expense_claim 或 medical_claim、这个账号属于单据说的那个人、并且它此刻是二级审批角色的真持有人。永不返回 NULL。它不放宽任何模块门:能不能走到这一步仍由决定函数自己的 require_permission 决定。approval_log 上的 approval_log_self_decided_scope 是同一句话的第二道保险。EXECUTE 已从 authenticated 收回。';


-- forbid_self_approval 多了第三个参数,而且【没有默认值】—— 预检认得"同一支迁移里
-- 先 DROP 旧签名"(preflight_migration.py 的 _dropped_before)。
DROP FUNCTION public.forbid_self_approval(uuid, uuid);
-- ── db/functions/forbid_self_approval.sql ──
CREATE OR REPLACE FUNCTION public.forbid_self_approval(p_raiser_user uuid, p_subject_employee uuid, p_subject_type text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_leg text;
    v_l2  text;
BEGIN
    -- 两条腿:raiser 先判,"同一个人"按人认(self_leg)。
    v_leg := self_leg(p_raiser_user, p_subject_employee, auth.uid());
    IF v_leg = 'none' THEN
        RETURN;
    END IF;

    -- ★ APR-ROUTE-1(R2):唯一的例外。它要求"主角就是我",所以一张我替别人提的单
    --   不会从这里漏过去 —— 那一张的 raiser 腿照拒。
    SELECT approval_level2_role_code INTO v_l2 FROM finance_settings LIMIT 1;
    IF self_approval_exception(p_subject_type, p_subject_employee, auth.uid(), v_l2) THEN
        RETURN;
    END IF;

    RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN|%', v_leg;
END;
$function$;


-- ════════════════════════════════════════════════════════════════════════════
-- ④ R1 与 R4:谁有资格 · 谁批得动
-- ════════════════════════════════════════════════════════════════════════════
-- ── db/functions/approval_level_eligible.sql ──
CREATE OR REPLACE FUNCTION public.approval_level_eligible(p_level smallint, p_level1_role text, p_level2_role text)
 RETURNS TABLE(user_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 这一级自己的角色
    SELECT h.user_id
      FROM real_role_holders(CASE p_level WHEN 1 THEN p_level1_role
                                          WHEN 2 THEN p_level2_role END) h
    UNION
    -- ★ R1:一级另加二级的持有人。二级之上没有更高的一级。
    SELECT h.user_id
      FROM real_role_holders(p_level2_role) h
     WHERE p_level = 1 AND p_level2_role IS NOT NULL
$function$;

COMMENT ON FUNCTION public.approval_level_eligible(smallint, text, text) IS
'APR-ROUTE-1(R1):谁有资格批这一级 —— 这一级角色的真持有人,一级另加二级的真持有人(高一级可以批低一级)。require_approver_for 与 approval_deciders(→ approval_gate_intersections)都读它,于是后来接进来的分档链调 require_approver_for、在 approval_chain_gates() 里加一行,就继承 R1。两个角色码当参数传:guard_approvals_switch 是 BEFORE UPDATE,读表读到的是 OLD。EXECUTE 已从 authenticated 收回。';

-- ── db/functions/approval_deciders.sql ──
CREATE OR REPLACE FUNCTION public.approval_deciders(p_subject_type text, p_action_function text, p_level smallint, p_raiser uuid, p_subject_employee uuid, p_level1_role text, p_level2_role text)
 RETURNS TABLE(user_id uuid, person_key text, via_self_exception boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH gate AS (
        SELECT cg.gate_permissions
          FROM approval_chain_gates() cg
         WHERE cg.subject_type = p_subject_type
           AND cg.action_function = p_action_function
           AND cg.level = p_level
    ),
    -- 「谁【真的】持有权限 P」—— 四条判据借自 real_role_grants,不另写一份。
    real_perm AS (
        SELECT DISTINCT rp.permission_code, rg.user_id
          FROM role_permissions rp
          JOIN roles r ON r.id = rp.role_id
          CROSS JOIN LATERAL real_role_grants(r.code) rg
    ),
    cand AS (
        SELECT e.user_id,
               self_leg(p_raiser, p_subject_employee, e.user_id) AS leg,
               self_approval_exception(p_subject_type, p_subject_employee, e.user_id, p_level2_role) AS exc
          FROM approval_level_eligible(p_level, p_level1_role, p_level2_role) e
         CROSS JOIN gate g
         -- 门是【合取】:少一个码就不算
         WHERE NOT EXISTS (
                 SELECT 1 FROM unnest(g.gate_permissions) AS need(code)
                  WHERE NOT EXISTS (
                        SELECT 1 FROM real_perm pp
                         WHERE pp.permission_code = need.code
                           AND pp.user_id = e.user_id))
    )
    SELECT c.user_id,
           COALESCE(account_person(c.user_id)::text, 'account:' || c.user_id::text),
           (c.leg <> 'none')
      FROM cand c
     WHERE c.leg = 'none' OR c.exc
$function$;

COMMENT ON FUNCTION public.approval_deciders(text, text, smallint, uuid, uuid, text, text) IS
'APR-ROUTE-1(R4):一条链的一级,对一份提单人为 p_raiser、主角为 p_subject_employee 的单据,谁批得动 —— 有资格(approval_level_eligible,含 R1)∩ 持这条链的模块门 ∩(不是"自己" 或 R2 例外成立)。person_key 按人认(R3):同一个人的两个账号只算一个。via_self_exception = 这一行只因 R2 才算数。三个读者:approval_gate_intersections(不传提单人与主角)· approvals_readiness(逐个持有人代入,忠告)· guard_approvals_switch 的 WOULD_STRAND(在途单据的真实双方)。EXECUTE 已从 authenticated 收回。';

-- ── db/functions/require_approver_for.sql ──
CREATE OR REPLACE FUNCTION public.require_approver_for(p_level smallint)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_role text;
    v_l1   text;
    v_l2   text;
BEGIN
    SELECT approval_level1_role_code, approval_level2_role_code
      INTO v_l1, v_l2 FROM finance_settings LIMIT 1;

    IF p_level = 1 THEN
        v_role := v_l1;
        IF v_role IS NULL THEN
            RAISE EXCEPTION 'APPROVAL_LEVEL1_ROLE_NOT_SET';
        END IF;
    ELSIF p_level = 2 THEN
        v_role := v_l2;
        IF v_role IS NULL THEN
            RAISE EXCEPTION 'APPROVAL_LEVEL2_ROLE_NOT_SET';
        END IF;
    ELSE
        RAISE EXCEPTION 'APPROVAL_LEVEL_INVALID|%', p_level;
    END IF;

    -- ★ APR-ROUTE-1(R1):「这一级谁有资格」只有一份定义 —— approval_level_eligible。
    --   一级另加二级的持有人(高一级可以批低一级);二级只有二级。
    --   拒绝的文案不变:它说的仍然是【这一级】的角色,那是人该去找的那个。
    IF NOT EXISTS (SELECT 1 FROM approval_level_eligible(p_level, v_l1, v_l2) h
                    WHERE h.user_id = auth.uid()) THEN
        RAISE EXCEPTION 'APPROVAL_NOT_AUTHORISED|%|%', p_level, v_role;
    END IF;
END;
$function$;

-- ── db/functions/approval_gate_intersections.sql ──
CREATE OR REPLACE FUNCTION public.approval_gate_intersections(p_level1_role text DEFAULT NULL::text, p_level2_role text DEFAULT NULL::text)
 RETURNS TABLE(subject_type text, action_function text, level smallint, role_code text, gate_permissions text[], approvers integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH s AS (
        SELECT COALESCE(p_level1_role, fs.approval_level1_role_code) AS l1,
               COALESCE(p_level2_role, fs.approval_level2_role_code) AS l2
          FROM finance_settings fs
         LIMIT 1
    ),
    g AS (
        SELECT cg.subject_type, cg.action_function, cg.level, cg.gate_permissions,
               CASE cg.level WHEN 1 THEN s.l1 ELSE s.l2 END AS role_code,
               s.l1, s.l2
          FROM approval_chain_gates() cg
         CROSS JOIN s
    )
    -- ★ APR-ROUTE-1(R4 · Q10):「谁批得动」只有一份定义 —— approval_deciders。
    --   这里不传提单人与主角:问的是"这一级有没有【任何人】",开关的闸与面板读它。
    --   数的是【人】,不是账号(R3):同一个人的两个账号只算一个。
    --   含 R1:一级把二级的持有人也算进来。
    SELECT g.subject_type, g.action_function, g.level, g.role_code, g.gate_permissions,
           (SELECT count(DISTINCT d.person_key)::integer
              FROM approval_deciders(g.subject_type, g.action_function, g.level,
                                     NULL::uuid, NULL::uuid, g.l1, g.l2) d)
      FROM g
     ORDER BY g.subject_type, g.action_function, g.level
$function$;

COMMENT ON FUNCTION public.approval_gate_intersections(text, text) IS
'APR-2:逐条给出「这条链的模块门 ∩ 这一级的角色持有人」有几个人 —— 0 就是一条谁都批不动的链。★ 两个参数存在的理由:guard_approvals_switch 是 BEFORE UPDATE,从 finance_settings 读到的是 OLD 那一行,而策略四列是一起写的;不传 NEW 的角色码,那道闸判的就是上一版策略并且全绿。不传参时读已落库的值(approvals_readiness 的用法)。「真的持有人」与「真的持有权限」两侧都从 real_role_grants 长出来,所以全库仍然只有一份"真人"的判据。EXECUTE 已从 authenticated 收回 —— 它读 auth.users 与整张权限矩阵。★ APR-ROUTE-1:approvers 改由 approval_deciders 计算(不传提单人与主角),数的是【人】而不是账号,并含 R1(一级把二级的持有人也算进来)。';


-- 返回类型变了(多两列),CREATE OR REPLACE 改不了返回类型。
DROP FUNCTION public.approval_pending_documents();
-- ── db/functions/approval_pending_documents.sql ──
CREATE OR REPLACE FUNCTION public.approval_pending_documents()
 RETURNS TABLE(subject_type text, doc_id uuid, code text, amount_base numeric, blocks_disable boolean, raiser_user_id uuid, subject_employee_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 采购单:审批开着时才生成 pending,而 approve_purchase_order 在审批关着时
    -- 按名拒(APPROVALS_NOT_ENABLED)—— 关掉审批,这些单据就没有人推得动。
    SELECT 'purchase_order'::text, po.id, po.code,
           round(po.estimated_total_ccy * po.fx_rate, 2),
           true,
           po.created_by, NULL::uuid
      FROM purchase_orders po
     WHERE po.approval_status = 'pending' AND po.deleted_at IS NULL
    UNION ALL
    -- 报销单:submitted 是员工交了一张单,与审批开关无关;decide_expense_claim
    -- 开着关着都做得了决定(只有分档那一步是条件性的)。所以它【不】挡关闭。
    SELECT 'expense_claim'::text, c.id, c.code, b.amount_base, false,
           c.created_by, c.employee_id
      FROM expense_claims c
      LEFT JOIN LATERAL expense_claim_amount_base(c.id) b ON true
     WHERE c.status = 'submitted'
$function$;

COMMENT ON FUNCTION public.approval_pending_documents() IS
'APR-3(Tim 的 Q6):哪些单据正在等人批 —— 逐行,一份判据三个读它的人(屏幕的逐链计数 · 关闭那道闸要的编号 · APPROVALS_POLICY_WOULD_STRAND 要的金额)。★ blocks_disable 把两个长得一样的数分开:「有多少在等人批」每条链都算,「关掉审批会搁死谁」只有一部分链算。判别的那一句话:这条链的决定函数在审批关着时还跑不跑得动 —— 跑不动才 true。今天只有采购单 true(approve_purchase_order 开头就 RAISE APPROVALS_NOT_ENABLED);报销单 false。★ 盘点不在本表里(Tim 的 Q4:open 是"正在点",不是"在等人批"),工单也不在(它没有等人批的队列)。amount_base 为 NULL = 这一张分不了档,不读成零。';

-- ── db/functions/guard_approvals_switch.sql ──
CREATE OR REPLACE FUNCTION public.guard_approvals_switch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_missing text[] := '{}';
    v_pending integer;
    v_codes   text;
    v_lvl     integer;
    v_role    text;
    v_total   integer;
    v_real    integer;
    v_gap     record;
    v_doc     record;
    v_thr     numeric;
BEGIN
    -- ── 开:策略必须齐,两级都必须【有人批】而且【看得见金额】 ──
    IF NEW.approvals_enabled AND NOT OLD.approvals_enabled THEN
        IF NEW.approval_level1_role_code IS NULL THEN
            v_missing := v_missing || 'approval_level1_role_code'::text;
        END IF;
        IF NEW.approval_threshold_base IS NULL THEN
            v_missing := v_missing || 'approval_threshold_base'::text;
        END IF;
        IF NEW.approval_level2_role_code IS NULL THEN
            v_missing := v_missing || 'approval_level2_role_code'::text;
        END IF;
        IF cardinality(v_missing) > 0 THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_INCOMPLETE|%', array_to_string(v_missing, ', ');
        END IF;

        -- 两级走【同一段】判断 —— 两级不同形正是上一版留下的问题。
        FOR v_lvl IN 1..2 LOOP
            v_role := CASE v_lvl WHEN 1 THEN NEW.approval_level1_role_code
                                 ELSE NEW.approval_level2_role_code END;

            SELECT count(*) INTO v_real FROM real_role_holders(v_role);

            IF v_real = 0 THEN
                -- 【分辨两种零】总数是从 user_roles 上数的(未撤销的授权),
                -- 与 real 的差,正好就是"有人持有,但他登录不了"。
                SELECT count(*) INTO v_total
                  FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                 WHERE r.code = v_role AND r.is_active AND ur.revoked_at IS NULL;

                IF v_total > 0 THEN
                    -- ★ 3c 的中间态:角色【有人】,但那个人【登录不了】。
                    --   报成"没有持有人"会把人送去再授一次权,而那不会改变任何事。
                    RAISE EXCEPTION 'APPROVALS_LEVEL%_HOLDER_CANNOT_SIGN_IN|%|%', v_lvl, v_role, v_total;
                ELSE
                    RAISE EXCEPTION 'APPROVALS_LEVEL%_ROLE_UNHELD|%', v_lvl, v_role;
                END IF;
            END IF;

            -- R4/4b:看不见金额的角色批不了它该批的东西 —— 同一时刻、同一理由。
            IF NOT role_can_see_amounts(v_role) THEN
                RAISE EXCEPTION 'APPROVALS_LEVEL%_ROLE_CANNOT_SEE_AMOUNTS|%', v_lvl, v_role;
            END IF;
        END LOOP;

        -- ════════════════════════════════════════════════════════════════════
        -- ★★★ APR-2:每一条接上引擎的链,都必须【真的有人批得动】 ★★★
        -- ════════════════════════════════════════════════════════════════════
        -- 上面那一段问的是"这一级的角色有没有真人、看不看得见金额" ——
        -- 两个都是【关于角色的】问题。而它们全部为真时,这条链仍然可以是死的:
        -- 一个持有那个角色的人,可能根本进不了那张单据所在的模块。
        -- ★ 这不是假设:WO-1b 就是这么在线上造出一把锁的,而当时三道闸全绿
        --   (逐项实测写在 db/functions/approval_chain_gates.sql 的抬头)。
        --
        -- ★★ 传的是 NEW 的两个角色码,【不能】让它自己去读表:本触发器是
        --    BEFORE UPDATE,而策略四列是一起写的 —— 读表读到的是 OLD,
        --    于是这道闸会去判上一版策略,并且全绿。
        --
        -- 【为什么是拒绝,不是忠告】与本函数抬头那句话同一条:把"开着但没人批"
        -- 做成一个【到不了】的状态,而不是【到了才发现】。后者的代价是一批
        -- 永远停在 pending 的单据,而开关此时已经关不掉了(下面那道闸)。
        FOR v_gap IN
            SELECT i.action_function, i.level, i.role_code,
                   array_to_string(i.gate_permissions, '+') AS perms
              FROM approval_gate_intersections(NEW.approval_level1_role_code,
                                               NEW.approval_level2_role_code) i
             WHERE i.approvers = 0
             ORDER BY i.action_function, i.level
             LIMIT 1
        LOOP
            RAISE EXCEPTION 'APPROVALS_CHAIN_HAS_NO_APPROVER|%|%|%|%',
                v_gap.action_function, v_gap.level, v_gap.role_code, v_gap.perms;
        END LOOP;
    END IF;

    -- ── 关:会被永远搁死的在途单据,先点名 ──
    -- ★★ APR-3(Tim 的 Q6):判据从"数采购单"换成 approval_pending_documents()
    --    里 blocks_disable 为真的那些 —— 而今天这两件事【算出同一个数】。
    --    换它不是为了换出一个新数字,是为了让这道闸与屏幕读【同一支函数】:
    --    APR-3 把屏幕上的在途张数放宽到了每一条链,而这道闸【没有】跟着放宽,
    --    两个数从此不同。它们必须出自同一个定义,否则下一个读代码的人无从
    --    知道哪一个才是拦人的那个。
    -- ★【为什么不是"每一条链都算"】那会当场把审批锁死在开着的状态:线上今天
    --    有一张 submitted 的报销单,而一张 submitted 的报销单在审批关着时
    --    【照样批得了】(decide_expense_claim 只有分档那一步是条件性的)。
    --    判别的那一句话写在 approval_pending_documents 的抬头,
    --    下一刀接一条链时照它回答一次:**这条链的决定函数,在审批关着的时候
    --    还跑不跑得动?**
    IF OLD.approvals_enabled AND NOT NEW.approvals_enabled THEN
        SELECT count(*)::integer, string_agg(d.code, ', ' ORDER BY d.code)
          INTO v_pending, v_codes
          FROM approval_pending_documents() d
         WHERE d.blocks_disable;
        IF COALESCE(v_pending, 0) > 0 THEN
            RAISE EXCEPTION 'APPROVALS_CANNOT_DISABLE_WITH_PENDING|%|%', v_pending, v_codes;
        END IF;
    END IF;

    -- ── 开着的时候不许把策略值抽走 ──
    -- ★★ APR-3 把这一段【提到 WOULD_STRAND 之前】,而这不是排版:
    --   抽走门槛(NEW 为 NULL)时,下面那一段会拿一个 NULL 门槛去重新分档,
    --   于是每一张在途单据都被当成二级判 —— 二级碰巧没有人批得动时,
    --   它会抛出 WOULD_STRAND,而**这次编辑真正的毛病是"你不能在开着的时候
    --   把这个值抽走"**。☞ 一条更含糊的拒绝盖住一条更准的拒绝,
    --   在屏幕上就是一句指错路的话。**结构上就不合法的那一种,先拒。**
    IF NEW.approvals_enabled THEN
        IF NEW.approval_level1_role_code IS NULL AND OLD.approval_level1_role_code IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_level1_role_code';
        END IF;
        IF NEW.approval_threshold_base IS NULL AND OLD.approval_threshold_base IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_threshold_base';
        END IF;
        IF NEW.approval_level2_role_code IS NULL AND OLD.approval_level2_role_code IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_level2_role_code';
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★★ APR-3:APPROVALS_POLICY_WOULD_STRAND —— 一条【定向】拒绝 ★★★
    -- ════════════════════════════════════════════════════════════════════════
    -- Tim 的 N8 裁定:**不做一刀切的锁。** 最需要改策略的时刻,正是某条链配错了、
    -- 单据卡住的时刻;锁住它会把一个救得回来的状态变成一个救不回来的状态,
    -- 而那正是本函数抬头那句「拒绝要给出路,不是给一堵墙」。
    --
    -- ★【它判的是什么】审批【开着】,而这次编辑动了角色或门槛:拿【新策略】
    --   把每一张在途单据重新分一次档,再问那一档那条链有没有人批得动。
    --   有一张落在没人批得动的档上 → 按名拒,并【点出那张单、那一级、那个角色】。
    --   其余一律放行 —— 包括"把某一级换成一个更窄的角色"这种一般性的改动,
    --   只要今天在途的这些单据都还有人批。
    --
    -- ★★【为什么必须拿 NEW 的门槛,而不是让 approval_level_for 自己去读表】
    --   本触发器是 BEFORE UPDATE:读 finance_settings 读到的是 OLD 那一行。
    --   于是"重新分档"会拿【旧门槛】去分,并且全绿 —— 与上面那道
    --   APPROVALS_CHAIN_HAS_NO_APPROVER 传 NEW 角色码是逐字同一个陷阱。
    --   分档那个比较号只有一份定义(approval_level_at),这里传参用它。
    --
    -- ★【金额分不出来的那一张,按二级判】Tim 的 N4 原话:「不明金额的安全方向
    --   是往上」。一张查不到牌价的报销单分不了档,这里不放它过去,也不发明
    --   一个新规矩 —— 复用那一条。今天线上没有这样的单据。
    --
    -- ★【它不重复定义"谁批得动"】那一句仍然只有 approval_gate_intersections()
    --   一份实现,这里只是按 (subject_type, level) 去查它的答案。
    IF NEW.approvals_enabled AND OLD.approvals_enabled
       AND (NEW.approval_level1_role_code IS DISTINCT FROM OLD.approval_level1_role_code
         OR NEW.approval_level2_role_code IS DISTINCT FROM OLD.approval_level2_role_code
         OR NEW.approval_threshold_base   IS DISTINCT FROM OLD.approval_threshold_base) THEN
        v_thr := NEW.approval_threshold_base;
        FOR v_doc IN
            SELECT d.subject_type, d.code, d.raiser_user_id, d.subject_employee_id,
                   CASE WHEN d.amount_base IS NULL OR v_thr IS NULL
                        THEN 2::smallint
                        ELSE approval_level_at(d.amount_base, v_thr) END AS lvl
              FROM approval_pending_documents() d
             ORDER BY d.subject_type, d.code
        LOOP
            -- ★★ APR-ROUTE-1(R4 · Q10):问的是【这一张】—— 除了它自己的提单人与
            --    主角,新策略下还有没有人批得动(R1 与 R2 算数)。此前问的是
            --    "这一级有没有任何持有人",于是一张只有它自己的提单人批得动的单
            --    会被当成"有人批"放过去。判据只有 approval_deciders 一份。
            -- 【角色与缺的码照旧从名册取】拒绝要点出那一级的角色与那条链的门,
            --   而这两样是 approval_gate_intersections 已经给出的东西。
            FOR v_gap IN
                SELECT i.action_function, i.role_code,
                       array_to_string(i.gate_permissions, '+') AS perms
                  FROM approval_gate_intersections(NEW.approval_level1_role_code,
                                                   NEW.approval_level2_role_code) i
                 WHERE i.subject_type = v_doc.subject_type
                   AND i.level = v_doc.lvl
                   AND NOT EXISTS (
                         SELECT 1 FROM approval_deciders(
                                    i.subject_type, i.action_function, i.level,
                                    v_doc.raiser_user_id, v_doc.subject_employee_id,
                                    NEW.approval_level1_role_code,
                                    NEW.approval_level2_role_code))
                 ORDER BY i.action_function
                 LIMIT 1
            LOOP
                RAISE EXCEPTION 'APPROVALS_POLICY_WOULD_STRAND|%|%|%|%|%',
                    v_doc.code, v_doc.lvl, v_gap.role_code, v_gap.action_function, v_gap.perms;
            END LOOP;
        END LOOP;
    END IF;

    RETURN NEW;
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
        'level1_can_see_amounts',  v_l1_sees,
        'level1_holders_who_cannot_raise', v_l1_norais,
        'threshold_base',          v_s.approval_threshold_base,
        'level2_role_code',        v_s.approval_level2_role_code,
        'level2_holders_total',    v_l2_total,
        'level2_real_holders',     v_l2_real,
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
-- ⑤ R2:留痕记下事实,六个调用点说出自己的类型,报表读得出来
-- ════════════════════════════════════════════════════════════════════════════
-- ── db/functions/record_approval_decision.sql ──
CREATE OR REPLACE FUNCTION public.record_approval_decision(p_subject_type text, p_subject_id uuid, p_decision text, p_level smallint DEFAULT NULL::smallint, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_ccy  text;
    v_amt  numeric;
    v_rate numeric;
    v_base numeric;
    v_ok   boolean := false;
    v_id   uuid;
    v_base_ccy text;
    -- APR-ROUTE-1(R2):这一张单据的提单人与主角,为了 self_decided
    v_raiser   uuid;
    v_subject  uuid;
    v_self     boolean := false;
BEGIN
    SELECT code INTO v_base_ccy FROM currencies WHERE is_base;

    -- 【外键没了,这一段就是它的替代】主体必须真的存在,并且顺手把编号与金额
    -- 冻结下来。不存在 → 点名拒绝,而不是插一行指向空气的留痕。
    CASE p_subject_type
        WHEN 'leave_request' THEN
            -- 请假没有金额:天数不是钱,不塞进币种列
            SELECT true, r.code, r.created_by, r.employee_id INTO v_ok, v_code, v_raiser, v_subject
              FROM leave_requests r WHERE r.id = p_subject_id;
        WHEN 'medical_claim' THEN
            -- amount_sgd 已经是本位币口径(列名是 FIN-0 之前留下的字面量,不是新的判断)
            SELECT true, c.code, c.amount_sgd, v_base_ccy, 1, c.amount_sgd, c.created_by, c.employee_id
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser, v_subject
              FROM medical_claims c WHERE c.id = p_subject_id;
        WHEN 'performance_review' THEN
            SELECT true, e.code, r.submitted_by, r.employee_id INTO v_ok, v_code, v_raiser, v_subject
              FROM performance_reviews r JOIN employees e ON e.id = r.employee_id
             WHERE r.id = p_subject_id;
        WHEN 'purchase_order' THEN
            -- 【用单据自己存的汇率】(决定 3)—— 审批档次因此不会随行情事后漂移
            SELECT true, po.code, po.estimated_total_ccy, po.currency, po.fx_rate,
                   round(po.estimated_total_ccy * po.fx_rate, 2), po.created_by
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser
              FROM purchase_orders po WHERE po.id = p_subject_id;
        WHEN 'payment' THEN
            SELECT true, p.code, p.amount_ccy, p.currency, p.fx_rate, p.amount_base
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM payments p WHERE p.id = p_subject_id;
        WHEN 'expense' THEN
            SELECT true, e.code, e.amount_ccy, e.currency, e.fx_rate, e.amount_base
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM expenses e WHERE e.id = p_subject_id;
        WHEN 'expense_claim' THEN
            -- ★ APR-3:报销单。expense_claims 上【没有 fx_rate,也没有 amount_base】,
            -- 所以这四列要算 —— 而算它的判据只有一份(expense_claim_amount_base),
            -- 与 decide_expense_claim 分档、approval_pending_documents 列在途读的是
            -- 同一支。三处各算一遍就是三份会漂开的数,而"屏幕上说的档次"与"真正
            -- 拦人的那一档"漂开,是一句关于内控的假话。
            -- 【牌价查不到时四列一起留空,而不是塞一个数进去】approval_log 的
            -- amount_shape 约束要的就是"全有或全无";留空的意思是【这一张当时
            -- 分不了档】,而那是真的。要按名拒的那一支是 decide_expense_claim。
            SELECT true, c.code, b.amount_ccy, b.currency, b.fx_rate, b.amount_base,
                   c.created_by, c.employee_id
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser, v_subject
              FROM expense_claims c
              LEFT JOIN LATERAL expense_claim_amount_base(c.id) b ON true
             WHERE c.id = p_subject_id;
            IF v_rate IS NULL THEN
                v_amt := NULL; v_ccy := NULL; v_base := NULL;
            END IF;
        WHEN 'pricing_formula' THEN
            SELECT true, f.code INTO v_ok, v_code
              FROM pricing_formulas f WHERE f.id = p_subject_id;
        WHEN 'stocktake' THEN
            SELECT true, s.code, s.created_by INTO v_ok, v_code, v_raiser
              FROM stocktakes s WHERE s.id = p_subject_id;
        WHEN 'work_order' THEN
            -- WO-1b:工单【没有金额】—— 它是一份要做什么的计划,不是一笔钱。
            -- 与 leave_request / performance_review / stocktake 同一类:
            -- 只冻结编号,金额那四列留空,而不是塞一个 0 进去
            -- (0 会让它在按金额筛的报表里排到最前面,那是一句假话)。
            SELECT true, w.code, w.created_by INTO v_ok, v_code, v_raiser
              FROM work_orders w WHERE w.id = p_subject_id;
        ELSE
            RAISE EXCEPTION 'APPROVAL_SUBJECT_TYPE_UNKNOWN|%', p_subject_type;
    END CASE;

    IF NOT COALESCE(v_ok, false) THEN
        RAISE EXCEPTION 'APPROVAL_SUBJECT_NOT_FOUND|%|%', p_subject_type, p_subject_id;
    END IF;

    -- ════════════════════════════════════════════════════════════════════
    -- ★★ APR-ROUTE-1(Tim 的 R2 · Q2):self_decided 记的是【事实】,不是【规则】 ★★
    -- ════════════════════════════════════════════════════════════════════
    -- 它问的是"按下去的这个人,是不是这张单的提单人或主角(按人认)",
    -- 而【不】问"例外成不成立"。两者今天算出同一个答案 —— 因为 forbid_self_approval
    -- 只在例外成立时才让"自己"走到这里。
    -- ★ 分开写的理由:哪一天另一条路径让一次自批漏了过来,这一格照样是 true,
    --   而 approval_log_self_decided_scope 那条 CHECK 会在【这一行 INSERT】上
    --   当场拒绝 —— 漏洞变成一次响亮的失败,而不是一行看起来正常的留痕。
    -- 【只看 approved / rejected】auto_approved 是"没有人按过任何东西"
    --   (create_purchase_order 在审批关着时由提单人自己的会话写),
    --   approval_voided 是系统作废 —— 两者都不是一次决定,不该被问"是不是自批"。
    IF p_decision IN ('approved', 'rejected') THEN
        v_self := self_leg(v_raiser, v_subject, auth.uid()) <> 'none';
    END IF;

    INSERT INTO approval_log (subject_type, subject_id, subject_code, decision, level,
                              actor_user_id, note, amount_ccy, currency, fx_rate, amount_base,
                              self_decided)
    VALUES (p_subject_type, p_subject_id, v_code, p_decision, p_level,
            auth.uid(), p_note, v_amt, v_ccy, v_rate, v_base,
            v_self)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$function$

;

-- ── db/functions/decide_expense_claim.sql ──
CREATE OR REPLACE FUNCTION public.decide_expense_claim(p_claim_id uuid, p_approve boolean, p_account_code text DEFAULT NULL::text, p_tax_code text DEFAULT NULL::text, p_posting_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c        expense_claims%ROWTYPE;
    v_emp      employees%ROWTYPE;
    v_has_att  boolean;
    v_exp      jsonb;
    v_date     date;
    v_base     numeric;
    v_level    smallint;
    v_appr_on  boolean := approvals_enabled();
BEGIN
    -- ① APR-3(Q1):门是【看得见财务 + 看得见金额】,不是【改得了财务】。
    --    两个码分两句,与 approve_purchase_order 同形 —— 拒绝要说清缺的是哪一个。
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_c FROM expense_claims WHERE id = p_claim_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_FOUND|%', COALESCE(p_claim_id::text, '?');
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;
    SELECT * INTO v_emp FROM employees WHERE id = v_c.employee_id;

    -- ══ ★② 四眼:全库【唯一】一份判据,两条腿 ★ ════════════════════════════
    -- 【为什么这道闸必须在这里】SOD-1 的 guard_payment_sod 明确豁免了付给员工的
    -- 款,理由是"由 HR 建档、财务付款,已经跨了两个模块的门"。那句话在写下的
    -- 那天是对的 —— 而 CLAIM-1 开出了一条新路:**员工自己发起**。发起人现在
    -- 就是受益人,那个论证对新路不成立。「换了推导来源,闸就要跟着搬」。
    -- 【两条腿各是谁】raiser = 提这张单的人(代人录入时不是员工本人);
    -- subject = 这张单【说的是谁】,也就是拿到这笔钱的那位员工。
    -- 顺序是定的:raiser 先判(APR-2 §3.5)。
    PERFORM forbid_self_approval(v_c.created_by, v_c.employee_id, 'expense_claim');

    -- ══ ★③ 分档 ★ ════════════════════════════════════════════════════════
    -- 【只在审批开着时问这一句】关着的时候,分档是一个没有意义的动作:
    -- 没有哪一级在生效,而 require_approver_for 会拿一条没有人在执行的策略
    -- 去拒绝一个本来做得了决定的人。这与 HR 三条链的形状一致 ——
    -- ☞ 也正因为如此,一张 submitted 的报销单【不挡】审批关闭
    --   (approval_pending_documents 的 blocks_disable = false,理由写在那里)。
    IF v_appr_on THEN
        SELECT b.amount_base INTO v_base FROM expense_claim_amount_base(p_claim_id) b;
        IF v_base IS NULL THEN
            -- 【那句话归 fx_rate_for 所有,这里只是把它请出来】——
            -- 自己拼一句 FX_RATE_MISSING 就是这条 FX 规矩的第二份定义。
            PERFORM fx_rate_for(v_c.currency, v_c.spend_date, 'tt_sell');
            -- 上面必定抛;真走到这里说明牌价其实查得到而上一步算出了 NULL,
            -- 那是一个【不该发生】的状态,按名拒而不是继续往下走。
            RAISE EXCEPTION 'EXPENSE_CLAIM_AMOUNT_BASE_UNRESOLVED|%', v_c.code;
        END IF;
        v_level := approval_level_for(v_base);
        PERFORM require_approver_for(v_level);
    END IF;

    -- ══ 驳回 ══════════════════════════════════════════════════════════════
    IF NOT p_approve THEN
        -- 【按名拒,而不是让 CHECK 抛约束原文】fixture 90 立的那条
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_REJECT_REASON_REQUIRED|%', v_c.code;
        END IF;
        UPDATE expense_claims
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_claim_id;
        -- ★ 驳回【也】留痕 —— APR-1 建这张表的第一条理由就是"驳回 → 重提 →
        --   批准之后,驳回那一次不留痕迹"。报销单此前正是那个形状:
        --   decision_notes 会被下一次决定覆盖掉。
        PERFORM record_approval_decision('expense_claim', p_claim_id, 'rejected',
                                         v_level, btrim(p_notes));
        RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'rejected',
                                  'level', v_level);
    END IF;

    -- ══ 批准 ══════════════════════════════════════════════════════════════
    IF p_account_code IS NULL OR btrim(p_account_code) = '' THEN
        -- 会计口径由审批人给 —— 没有科目就没法记账,而猜一个科目比拒绝坏
        RAISE EXCEPTION 'EXPENSE_CLAIM_ACCOUNT_REQUIRED|%', v_c.code;
    END IF;

    -- ★【GST 开着时,税码是【必给】的 —— 而且只能由审批人给】★
    -- 实测:resolve_tax_code 接受 override 或【往来对象的默认税码】,两者皆空就
    -- 按名拒(TAX_CODE_REQUIRED)。而 employees **没有 default_tax_code 这一列** ——
    -- 员工这一侧【永远】解析不出默认值。所以报销这条路上,税码只能显式给。
    -- 【为什么在这里先拒一次,而不是让 resolve_tax_code 去拒】它的提示语是
    -- 「给这个往来对象设一个默认税码,或在这张单据上指定一个」—— 对员工来说
    -- 前半句是【做不到的事】,于是那句话有一半是错的指路。这里按名拒并说清楚
    -- 要做的判断:进项税可抵是 TX,不可抵是 BL,而那是一个财务判断。
    -- 【这不是把税的规矩重写一遍】有效性、侧别、是否停用仍然全归 resolve_tax_code;
    -- 这里只声明一个【这条路特有的前提】:员工没有默认值,所以 override 必填。
    IF (SELECT gst_registered FROM finance_settings) AND
       COALESCE(btrim(COALESCE(p_tax_code, '')), '') = '' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_TAX_CODE_REQUIRED|%', v_c.code;
    END IF;

    -- ★【凭据:要么有附件,要么有一句说得出为什么没有】★
    -- 【为什么查在这一步而不是提交那一步】提交那一刻申请还不存在,附件挂不上去;
    -- 而凭据真正起作用的时刻,正是有人要据它做决定的时刻。
    -- 【为什么留了一条例外的路】一条没有例外出口的规矩会被绕过 ——
    -- 这里绕过的走法是"让财务当成一笔普通费用直接录进去",而那会把整条
    -- 报销记录一起丢掉。所以:允许没有收据,但要求把【为什么】说出来,
    -- 并且让审批人看见自己批的是哪一种。
    SELECT EXISTS (SELECT 1 FROM finance_attachments
                    WHERE claim_id = p_claim_id AND deleted_at IS NULL) INTO v_has_att;
    IF NOT v_has_att AND COALESCE(btrim(v_c.no_receipt_reason), '') = '' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NO_EVIDENCE|%', v_c.code;
    END IF;

    -- 入账日:默认花钱那天;期间关了账时由审批人显式给
    v_date := COALESCE(p_posting_date, v_c.spend_date);

    -- 【成本与欠款在这里同时落地】unpaid = 一笔挂在这名员工头上的应付,
    -- 它会立刻出现在 ap_open_items 里带着他自己的名字(PAYEE-1a)。
    -- 汇率传 NULL:由 record_expense 按【那一天】自己查牌价 —— 一条 FX 规矩,
    -- 查不到就按名拒(FX_RATE_MISSING),报销不是它的例外。
    -- ⚠ APR-3 照直说:这里过账取的是 v_date 那天的牌价,而上面分档取的是
    --   spend_date 那天的 —— 两个日期不同时,两个数可以不一样。那是两个不同的
    --   问题(这笔承诺有多大 / 账上记多少),理由写在 expense_claim_amount_base。
    -- ★★【这张开支单【不】另外走一次审批】它是引擎在一个人已经批准之后代他
    --   记的账,不是一份新提交的单据 —— 与 N5 对系统生成凭证的裁定逐字同源。
    --   expense 这个 subject_type 在 APR-3 里【没有】接上引擎(Tim 的 Q2 裁定:
    --   payments / expenses 没有在途态,要先做一次建模改动),所以今天这一格
    --   不需要任何豁免机制;那条路开工时,豁免要写成一个【显式入参】,不是 GUC
    --   (Tim 的 Q9),理由记在 docs/forward-queue.md。
    v_exp := record_expense(
        p_expense_date   := v_date,
        p_account_code   := btrim(p_account_code),
        p_amount         := v_c.amount_ccy,
        p_currency       := v_c.currency,
        p_fx_rate        := NULL,
        p_payment_status := 'unpaid',
        p_bank_account   := NULL,
        p_supplier_id    := NULL,
        p_employee_id    := v_c.employee_id,
        p_payee_name     := v_emp.legal_name,
        p_notes          := format('Expense claim %s (%s) — %s', v_c.code, v_emp.code, v_c.description),
        p_tax_code       := NULLIF(btrim(COALESCE(p_tax_code, '')), ''));

    UPDATE expense_claims
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           account_code = btrim(p_account_code),
           tax_code = NULLIF(btrim(COALESCE(p_tax_code, '')), ''),
           posting_date = v_date,
           expense_id = (v_exp->>'expense_id')::uuid
     WHERE id = p_claim_id;

    PERFORM record_approval_decision('expense_claim', p_claim_id, 'approved',
                                     v_level, NULLIF(btrim(COALESCE(p_notes, '')), ''));

    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'approved',
                              'expense_id', v_exp->>'expense_id', 'posting_date', v_date,
                              'level', v_level);
END;
$function$;

-- ── db/functions/decide_medical_claim.sql ──
CREATE OR REPLACE FUNCTION public.decide_medical_claim(p_claim_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_claim record; v_bal jsonb; v_remaining numeric;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_claim FROM medical_claims WHERE id = p_claim_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CLAIM_NOT_FOUND'; END IF;
    IF v_claim.status <> 'submitted' THEN RAISE EXCEPTION 'CLAIM_NOT_SUBMITTED|%', v_claim.status; END IF;

    -- ★ APR-2:四眼,与 decide_leave_request 逐字同一支判据、同样两条腿。
    -- 这条链此前也一条都没有 —— 而它【是真的在批钱】(amount_sgd)。
    PERFORM forbid_self_approval(v_claim.created_by, v_claim.employee_id, 'medical_claim');

    IF NOT p_approve THEN
        UPDATE medical_claims SET status='rejected', decided_at=now(), decided_by=auth.uid(),
               decision_notes=p_notes, updated_by=auth.uid() WHERE id = p_claim_id;

        -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
        -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
        PERFORM record_approval_decision('medical_claim', p_claim_id, 'rejected', NULL, p_notes);
        RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_claim.code, 'status','rejected');
    END IF;

    v_bal := medical_claim_balance(v_claim.employee_id, v_claim.claim_year);
    v_remaining := (v_bal->>'remaining_sgd')::numeric;
    IF v_claim.amount_sgd > v_remaining THEN
        RAISE EXCEPTION 'CLAIM_EXCEEDS_LIMIT|%|%', v_remaining, v_claim.amount_sgd;
    END IF;

    UPDATE medical_claims SET status='approved', decided_at=now(), decided_by=auth.uid(),
           decision_notes=p_notes, updated_by=auth.uid() WHERE id = p_claim_id;

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('medical_claim', p_claim_id, 'approved', NULL, p_notes);

    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_claim.code, 'status','approved',
                              'amount_sgd', v_claim.amount_sgd,
                              'remaining_after', v_remaining - v_claim.amount_sgd,
                              -- 与补偿一样,把"没有入账"写进返回值,免得调用方以为记过账了
                              'expense_posted', false,
                              'note', 'No expense is posted. Reimbursement route (payroll vs separate payment) is an operational decision; link it via medical_claims.expense_id once chosen.');
END;
$function$;

-- ── db/functions/decide_leave_request.sql ──
CREATE OR REPLACE FUNCTION public.decide_leave_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_req    record;
    v_type   record;
    v_need   numeric;
    v_take   numeric;
    v_bal    jsonb;
    v_avail  numeric;
    v_accrual numeric;
    g        record;
    v_used   jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_req FROM leave_requests WHERE id = p_request_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'REQUEST_NOT_FOUND'; END IF;
    IF v_req.status <> 'pending' THEN RAISE EXCEPTION 'REQUEST_NOT_PENDING|%', v_req.status; END IF;

    -- ★ APR-2:四眼。此前这条链【一条自批判据都没有】——
    -- 一个持 module.hr.edit 的人批得了自己的假(APR-0 §1.5 实测)。
    -- 两条腿,判据只有一份定义(见 forbid_self_approval 的抬头):
    --   ① 提这张单的人;② 这张单【说的是谁】。
    -- ★ 第二条在这里是承重的:HR 可以【代人】提单,那时 created_by 是 HR、
    --   employee_id 是员工本人 —— 只判第一条的话,那位员工(若他持
    --   module.hr.edit)照样批得了自己的假。
    PERFORM forbid_self_approval(v_req.created_by, v_req.employee_id, 'leave_request');

    SELECT * INTO v_type FROM leave_types WHERE code = v_req.leave_type_code;

    IF NOT p_approve THEN
        UPDATE leave_requests SET status='rejected', decided_at=now(), decided_by=auth.uid(),
               decision_notes=p_notes, updated_by=auth.uid()
        WHERE id = p_request_id;

        -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
        -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
        PERFORM record_approval_decision('leave_request', p_request_id, 'rejected', NULL, p_notes);
        RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','rejected');
    END IF;

    IF v_type.is_accrued THEN
        v_bal := leave_balance(v_req.employee_id, v_req.leave_type_code, v_req.start_date);
        v_avail := (v_bal->>'available')::numeric;
        IF v_avail < v_req.days THEN
            RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE|%|%',
                trim_scale(v_avail), trim_scale(v_req.days);
        END IF;

        v_need := v_req.days;
        -- ══════════════════════════════════════════════════════════════════
        -- 【先用旧的】:按 expires_on 从早到晚扣。
        -- 结转来的行有失效日,当年累积没有 —— 所以结转天数天然排在前面被先吃掉,
        -- 反过来的话它们会先烂掉,对员工是净损失。
        -- ══════════════════════════════════════════════════════════════════
        FOR g IN
            SELECT gr.id, gr.days, gr.expires_on, gr.leave_year, gr.grant_type,
                   gr.days
                   - COALESCE((SELECT SUM(CASE WHEN c.entry_type='draw' THEN c.days ELSE -c.days END)
                               FROM leave_consumption c WHERE c.leave_grant_id = gr.id), 0)
                   - COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                               WHERE cf.source_grant_id = gr.id AND cf.grant_type = 'carry_forward'
                                 AND cf.deleted_at IS NULL), 0) AS remaining
            FROM leave_grants gr
            WHERE gr.employee_id = v_req.employee_id AND gr.leave_type_code = v_req.leave_type_code
              AND gr.deleted_at IS NULL AND gr.granted_on <= v_req.start_date
              AND (gr.expires_on IS NULL OR gr.expires_on >= v_req.start_date)
            ORDER BY gr.expires_on NULLS LAST, gr.granted_on
        LOOP
            EXIT WHEN v_need <= 0;
            IF g.remaining <= 0 THEN CONTINUE; END IF;
            v_take := LEAST(g.remaining, v_need);
            INSERT INTO leave_consumption (leave_request_id, leave_grant_id, entry_type, days)
            VALUES (p_request_id, g.id, 'draw', v_take);
            v_need := v_need - v_take;
            v_used := v_used || jsonb_build_object('source', 'grant', 'grant_id', g.id,
                                                   'leave_year', g.leave_year,
                                                   'grant_type', g.grant_type,
                                                   'expires_on', g.expires_on, 'days', v_take);
        END LOOP;

        -- 结转吃完了还不够 → 从当年度的派生累积里扣(记 accrual_year,不挂授予行)
        IF v_need > 0 AND v_type.is_accrued THEN
            v_accrual := available_annual_accrual(v_req.employee_id, v_req.start_date);
            v_take := LEAST(v_accrual, v_need);
            IF v_take > 0 THEN
                INSERT INTO leave_consumption (leave_request_id, leave_grant_id, entry_type, days, accrual_year)
                VALUES (p_request_id, NULL, 'draw', v_take,
                        EXTRACT(YEAR FROM v_req.start_date)::integer);
                v_need := v_need - v_take;
                v_used := v_used || jsonb_build_object('source', 'accrual',
                                                       'leave_year', EXTRACT(YEAR FROM v_req.start_date)::integer,
                                                       'grant_type', 'monthly_accrual',
                                                       'expires_on', NULL, 'days', v_take);
            END IF;
        END IF;

        IF v_need > 0 THEN
            RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE|%|%',
                trim_scale(v_req.days - v_need), trim_scale(v_req.days);
        END IF;
    END IF;

    UPDATE leave_requests SET status='approved', decided_at=now(), decided_by=auth.uid(),
           decision_notes=p_notes, updated_by=auth.uid()
    WHERE id = p_request_id;

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('leave_request', p_request_id, 'approved', NULL, p_notes);

    RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','approved',
                              'days', v_req.days, 'consumed_from', v_used);
END;
$function$;

-- ── db/functions/approve_review.sql ──
CREATE OR REPLACE FUNCTION public.approve_review(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r        performance_reviews%ROWTYPE;
    v_emp      employees%ROWTYPE;
    v_period   text;
    v_old_sal  numeric;
    v_conf     date;
    v_confirmed boolean := false;
    v_salaried  boolean := false;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    -- 【四眼原则】与"评估人不能是本人"是两条不同的规则:一条防自我评价
    -- (表上的 CHECK:reviewer_employee_id IS DISTINCT FROM employee_id),
    -- 这一条防自我批准。
    --
    -- ★★ APR-2 把它换成了全库唯一的那支判据,而这【不是】重构 ——
    -- 它补上了本函数缺的那条腿。此前只拒 submitted_by,于是这条路一直是通的:
    --   【别人提交、被评的那位自己批准】。
    -- 而本函数会写 employees.monthly_salary 与一行 employment_history 调薪记录,
    -- 也就是说 **一个人批得了自己的加薪**。线上三个持 module.hr.edit 的人
    -- 全部是在册员工(实测 2026-09-22),所以它不是理论上的。
    PERFORM forbid_self_approval(v_r.submitted_by, v_r.employee_id, 'performance_review');

    SELECT * INTO v_emp FROM employees WHERE id = v_r.employee_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    UPDATE performance_reviews
    SET status = 'approved', approved_at = now(), approved_by = auth.uid()
    WHERE id = p_review_id;

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('performance_review', p_review_id, 'approved', NULL, NULL);

    -- ── 试用期转正 ────────────────────────────────────────────────────────
    IF v_r.review_type = 'probation' AND v_r.probation_outcome = 'confirm' THEN
        IF v_emp.employment_status = 'separated' THEN
            RAISE EXCEPTION 'EMPLOYEE_SEPARATED|%', v_emp.code;
        END IF;
        v_conf := COALESCE(v_emp.probation_end_date, CURRENT_DATE);

        UPDATE employees
        SET employment_status = 'active',      -- 【没有 'confirmed' 这个状态,见文件头 (2)】
            confirmation_date = v_conf
        WHERE id = v_emp.id;

        -- 【恰好一行】履历。
        INSERT INTO employment_history
            (employee_id, effective_date, change_type, job_title, department_id,
             employment_type, employment_status, notes)
        VALUES (v_emp.id, v_conf, 'confirmed',
                -- KPI-1:履历存的是【当时那个职位的名称文本】,不是指针
                (SELECT p.title FROM positions p WHERE p.id = v_emp.position_id),
                v_emp.department_id,
                v_emp.employment_type, 'active',
                format('Probation confirmed by performance review %s', p_review_id));

        -- 【假期台账一个字都不写】年假的解锁是读时按 employment_status 派生的
        -- (submit_leave_request 的 PROBATION_NO_ANNUAL_LEAVE)。在这里补一笔授予
        -- 就是 HR-2a 结转重复计数的翻版。见文件头 (1)。
        v_confirmed := true;
    END IF;

    -- ── 不予转正:【什么都不改】 ──────────────────────────────────────────
    -- 决定记在评估单据上,提醒由 hr_alerts 的 probation_not_confirmed 一支发出。
    -- 【绝不把在职状态改成 separated,也绝不触发任何离职逻辑】——
    -- 离职是手工流程:人一旦 separated 就掉出工资表,而最后一个月的工资还没录。
    -- 先掉出去,那笔钱就再也发不出来了。

    -- ── 调薪 ──────────────────────────────────────────────────────────────
    IF v_r.new_monthly_salary IS NOT NULL THEN
        -- payroll_periods 没有起止两列:周期就是 period_month 那个整月(见文件头 (4))
        SELECT p.code INTO v_period
        FROM payroll_periods p
        WHERE p.deleted_at IS NULL AND p.status = 'posted'
          AND v_r.salary_effective_date >= p.period_month
          AND v_r.salary_effective_date < (p.period_month + interval '1 month')::date
        ORDER BY p.period_month
        LIMIT 1;

        IF v_period IS NOT NULL THEN
            -- 【连同上面的转正一起回滚】总账已经认了那个月的工资,
            -- 追改一个已过账周期里的薪酬会让账实不符。
            RAISE EXCEPTION 'SALARY_EFFECTIVE_IN_POSTED_PERIOD|%', v_period;
        END IF;

        v_old_sal := v_emp.monthly_salary;

        UPDATE employees SET monthly_salary = v_r.new_monthly_salary WHERE id = v_emp.id;

        INSERT INTO employment_history
            (employee_id, effective_date, change_type, job_title, department_id,
             employment_type, employment_status, old_monthly_salary, new_monthly_salary, notes)
        SELECT e.id, v_r.salary_effective_date, 'salary_change',
               (SELECT p.title FROM positions p WHERE p.id = e.position_id), e.department_id,
               e.employment_type, e.employment_status, v_old_sal, v_r.new_monthly_salary,
               format('Salary change approved with performance review %s', p_review_id)
        FROM employees e WHERE e.id = v_emp.id;

        v_salaried := true;
    END IF;

    RETURN jsonb_build_object(
        'review_id', p_review_id, 'status', 'approved',
        'employee_code', v_emp.code,
        'review_type', v_r.review_type,
        'probation_outcome', v_r.probation_outcome,
        'confirmed', v_confirmed,
        'confirmation_date', v_conf,
        'salary_changed', v_salaried,
        'old_monthly_salary', v_old_sal,
        'new_monthly_salary', v_r.new_monthly_salary,
        'salary_effective_date', v_r.salary_effective_date);
END;
$function$;

-- ── db/functions/post_stocktake.sql ──
CREATE OR REPLACE FUNCTION public.post_stocktake(p_stocktake_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user           uuid := auth.uid();
    v_st             record;
    v_line           record;
    v_code           text;
    v_current        numeric;
    v_deleted        timestamptz;
    v_delta          numeric;
    v_lines_total    integer := 0;
    v_lines_adjusted integer := 0;
    v_total_delta    numeric := 0;
    v_value          numeric;
    v_inv_acct       text;
    v_amt            numeric;
    v_je_lines       jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('module.stocktakes.edit');
    SELECT id, code, status, deleted_at, created_by INTO v_st
    FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_st.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', p_stocktake_id;
    END IF;
    IF v_st.status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_st.status;
    END IF;

    -- ★ APR-3:四眼。判据只有一份定义,两条腿的顺序也只在那里定。
    -- 第二个入参是 NULL —— 一次盘点是关于一批货的,不是关于某个人的,
    -- 所以它没有"这张单说的是谁"那条腿;而 NULL 一律不匹配。
    PERFORM forbid_self_approval(v_st.created_by, NULL::uuid, 'stocktake');

    FOR v_line IN SELECT * FROM stocktake_lines WHERE stocktake_id = p_stocktake_id
    LOOP
        v_lines_total := v_lines_total + 1;

        IF v_line.inbound_batch_id IS NOT NULL THEN
            SELECT code, remaining_qty, deleted_at INTO v_code, v_current, v_deleted
            FROM inbound_batches WHERE id = v_line.inbound_batch_id FOR UPDATE;
            -- ════════════════════════════════════════════════════════════════
            -- PROC-COST-2 · R1:【盘点计值 = 落地成本,与注销同一支函数】
            -- 改之前这里取的是 unit_price(上一行的 SELECT 列表里),于是一批
            -- 落地 900 的货盘成 0 只解除 500,**400 留在 1200 上**(线上实测)。
            --
            -- ★【两个方向都改,而这是让修复安全的那一半】★
            -- 下面 v_value 同时喂给盘盈(借库存)与盘亏(贷库存)两支。只改盘亏
            -- 的实现会让一次"点少了、再点回来"**永久销毁**运费与加工成本 ——
            -- 那批料一克都没离开过厂房。**一次修复造出来的新缺陷,比被修的更坏。**
            -- fixture 的 D 臂钉的就是这一条:100 → 50 → 100,1200 必须回到起点。
            --
            -- 【读的是 landed_unit_cost,不是带判据的读取器】计值不许取决于
            -- 谁按的按钮 —— 见本刀迁移抬头第四节。
            -- 【FOR UPDATE 之后单独取】把函数调用留在 FOR UPDATE 的目标列表里
            -- 会让人以为它也被锁保护;它不是,它是一次独立的读。分两行写。
            -- ════════════════════════════════════════════════════════════════
            v_value := inbound_batch_landed_unit_cost_all(v_line.inbound_batch_id);
            v_inv_acct := '1200';
        ELSE
            SELECT ob.code, ob.remaining_qty, ob.deleted_at, po.unit_cost_base
            INTO v_code, v_current, v_deleted, v_value
            FROM output_batches ob
            LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
            WHERE ob.id = v_line.output_batch_id
            FOR UPDATE OF ob;
            v_inv_acct := '1220';
        END IF;

        IF v_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'BATCH_DELETED|%', v_code;
        END IF;

        v_delta := v_line.counted_qty - v_current;
        IF v_delta <> 0 THEN
            IF v_line.inbound_batch_id IS NOT NULL THEN
                -- ════════════════════════════════════════════════════════════
                -- FIN-32-fu1:业务日 = 过账日(CURRENT_DATE),而这是【查过之后】
                -- 的结论,不是"没有更好的来源"那种含糊话。
                -- stocktakes 上确实有个 started_at,名字听起来像盘点日 —— 它不是:
                -- 它是 timestamptz NOT NULL DEFAULT now(),【全代码库没有任何一处
                -- 写过它】,而线上每一行的 started_at 与 created_at 【逐微秒相等】
                -- (实测 3/3,最大差 0.000000 秒)。它是建单时间戳,不是盘点日期。
                -- 所以周一盘、周二过账,这里记的仍是周二 —— 而这是【诚实的】:
                -- 系统里根本没有人告诉过它周一。
                -- 真要记录盘点当天,得先有一个【盘点日字段让人填】(Phase 2 的
                -- 盘点单),那时这里改成读它 —— 与注销读 deleted_at 同一条规矩:
                -- 日期要来自记录,而记录得先存在。
                -- ════════════════════════════════════════════════════════════
                INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.inbound_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE inbound_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.inbound_batch_id;
            ELSE
                INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.output_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE output_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.output_batch_id;
            END IF;
            v_lines_adjusted := v_lines_adjusted + 1;
            v_total_delta := v_total_delta + v_delta;

            -- cut 2a:有单值的差异行,成对累积分录行(盘盈:借库存 贷 5200;盘亏反向)。
            -- 无值(未计价进料 / 无成本产出)只调量不入账。
            -- PROC-COST-2:v_value 现在是【单位落地成本】,两支共用它 —— 见上。
            IF v_value IS NOT NULL THEN
                v_amt := round(abs(v_delta) * v_value, 2);
                IF v_amt <> 0 THEN
                    IF v_delta > 0 THEN
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', '5200',     'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt);
                    ELSE
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', '5200',     'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt);
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;

    UPDATE stocktakes
    SET status = 'posted', posted_at = now(), updated_by = v_user, updated_at = now()
    WHERE id = p_stocktake_id;

    -- cut 2a:一张分录覆盖全部有值差异行(每行自成一对,天然自平)
    IF jsonb_array_length(v_je_lines) >= 2 THEN
        PERFORM post_journal_entry(
            CURRENT_DATE,
            'Stocktake ' || v_st.code,
            'stocktake', p_stocktake_id,
            v_je_lines);
    END IF;

    -- ★ APR-3:留痕。恒 approved、level 恒 NULL(理由在文件抬头)。
    PERFORM record_approval_decision('stocktake', p_stocktake_id, 'approved', NULL::smallint,
        format('盘点过账:%s 行有差异,合计 %s', v_lines_adjusted, v_total_delta));

    RETURN jsonb_build_object(
        'stocktake_id', p_stocktake_id,
        'code', v_st.code,
        'lines_total', v_lines_total,
        'lines_adjusted', v_lines_adjusted,
        'total_delta', v_total_delta
    );
END;
$function$;

-- ── db/functions/release_work_order.sql ──
CREATE OR REPLACE FUNCTION public.release_work_order(p_work_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_wo      work_orders%ROWTYPE;
    v_appr_on boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status <> 'draft' THEN
        RAISE EXCEPTION 'WO_NOT_DRAFT|%|%', v_wo.code, v_wo.status;
    END IF;

    -- ★ APR-2:四眼。判据只有一份定义(forbid_self_approval)。
    -- 【只有一条腿】—— 工单没有"这张单说的是谁"(它说的是一批料,不是一个人),
    -- 所以第二个参数是 NULL,而 NULL 一律不匹配。不硬塞一个主语进去。
    PERFORM forbid_self_approval(v_wo.created_by, NULL::uuid, 'work_order');

    -- 【放行是那个要有人负责的动作】(WO-1b)Doc 2 点名要"who approved the work
    -- order"。可审批的是放行 —— 不是新建(草稿谁都可以写),也不是收工(事后记录)。
    --
    -- ★ APR-2:谁能放行,由 module.processing.edit 说了算 —— 本函数【不】按角色
    --   分级。工单没有金额,而按角色分级只管带钱的单据(Tim 的 Q1 裁定)。
    --   ☞ 这里原先有一句按级别授权的检查,而它在线上是一把【谁都过不去】的锁。
    --     整段来龙去脉写在本文件的抬头 —— **刻意写在函数体外面**,
    --     见抬头最后一段说明为什么。

    UPDATE work_orders
       SET status = 'released', updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, changed_by)
    VALUES (p_work_order_id, 'released', v_user);

    -- 【留痕要说实话】—— 而 APR-3(Tim 的 Q7)把"实话"这一句本身改了。
    -- ★ 两条分支现在写的是【同一个决定值】:放行是一个人按下去的动作,
    --   审批开着还是关着都是;开关只改变"有没有一道按级别的授权",
    --   不改变"有没有人做过这个决定"。
    -- ★ 层级恒 NULL,不写 1。此前写的是 1,而那是一句【假记录】——
    --   这条路上【没有跑过任何一级授权检查】(上面那一段说明了为什么),
    --   于是 level = 1 会让留痕声称发生过一件没有发生的事。
    --   与 HR 三条链同形:它们也一律 NULL(approval_log 的 level 列注释)。
    PERFORM record_approval_decision('work_order', p_work_order_id, 'approved', NULL::smallint,
        CASE WHEN v_appr_on THEN NULL
             ELSE '审批流未启用(finance_settings.approvals_enabled = false)—— 没有按级别的授权步骤,而放行是这个人按下去的' END);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'status', 'released', 'approvals_enabled', v_appr_on);
END;
$function$

;

-- ── db/functions/self_approved_decisions.sql ──
CREATE OR REPLACE FUNCTION public.self_approved_decisions()
 RETURNS TABLE(seq bigint, decided_at timestamp with time zone, subject_type text, subject_id uuid, subject_code text, decision text, level smallint, actor_user_id uuid, actor_name text, subject_employee_id uuid, subject_name text, amount_ccy numeric, currency text, amount_base numeric, note text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('data.view_self_approvals');

    RETURN QUERY
    SELECT a.seq, a.decided_at, a.subject_type, a.subject_id, a.subject_code, a.decision,
           a.level, a.actor_user_id,
           COALESCE(ae.legal_name, au.email::text, a.actor_user_id::text) AS actor_name,
           s.employee_id,
           se.legal_name,
           a.amount_ccy, a.currency, a.amount_base, a.note
      FROM approval_log a
      LEFT JOIN auth.users au ON au.id = a.actor_user_id
      LEFT JOIN employees ae ON ae.id = account_person(a.actor_user_id)
      LEFT JOIN LATERAL (
            SELECT c.employee_id FROM expense_claims c
             WHERE a.subject_type = 'expense_claim' AND c.id = a.subject_id
            UNION ALL
            SELECT m.employee_id FROM medical_claims m
             WHERE a.subject_type = 'medical_claim' AND m.id = a.subject_id
      ) s ON true
      LEFT JOIN employees se ON se.id = s.employee_id
     WHERE a.self_decided
     ORDER BY a.seq DESC;
END;
$function$;

COMMENT ON FUNCTION public.self_approved_decisions() IS
'APR-ROUTE-1(R2 · Q4):自批报表 —— approval_log 里 self_decided 的每一行,带决定人与主角的显示名。门只有一个:data.view_self_approvals(admin · gm · auditor);没有它就 RAISE,不返回零行(零行在这里的意思是"没有人自批过")。以属主身份读,因为 approval_log 的读策略按单据类型分门,一个只持本码的审计者经由那张表会静默读到零行。';


-- ════════════════════════════════════════════════════════════════════════════
-- ⑥ F1 / R5:expense_claim_status 的行谓词
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE VIEW public.expense_claim_status WITH (security_invoker = off) AS
SELECT c.id AS claim_id,
    c.code,
    c.employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    c.spend_date,
    c.submitted_at,
    c.amount_ccy,
    c.currency,
    c.description,
    c.no_receipt_reason,
    c.status,
    c.decided_at,
    c.decision_notes,
    c.account_code,
    c.tax_code,
    c.posting_date,
    c.expense_id,
    x.payment_status,
    x.status = 'reversed'::text AS expense_reversed,
    COALESCE(a.settled_ccy, 0::numeric) AS settled_ccy,
    c.status = 'approved'::text AND x.status = 'posted'::text AND COALESCE(a.settled_ccy, 0::numeric) >= x.amount_ccy AS is_paid,
    c.status = 'approved'::text AND x.status = 'posted'::text AND COALESCE(a.settled_ccy, 0::numeric) < x.amount_ccy AS is_owing,
    (EXISTS ( SELECT 1
           FROM finance_attachments fa
          WHERE fa.claim_id = c.id AND fa.deleted_at IS NULL)) AS has_receipt
   FROM expense_claims c
     JOIN employees e ON e.id = c.employee_id
     LEFT JOIN expenses x ON x.id = c.expense_id
     LEFT JOIN LATERAL ( SELECT round(sum(pa.allocated_ccy), 2) AS settled_ccy
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id
          WHERE pa.expense_id = c.expense_id AND p.status = 'posted'::text) a ON true
  WHERE has_permission('module.finance.view'::text) OR c.employee_id = current_user_employee();

COMMENT ON VIEW public.expense_claim_status IS
    'CLAIM-1:每一笔报销一行,而【付了没有是推导出来的】—— 与 medical_claim_status 同一条:付款状态归 expenses 所有,存一份副本第一次冲销付款时两边就分家。expense_reversed 单独露出来,因为"批准被撤销"在本刀里【没有】自己的机制:改法是冲销那笔费用(expenses 本来就有冲销路径与 reversed_by_expense),claim 的状态跟着它走 —— 两个撤销机制会对"这笔钱还欠不欠"各说各话。属主权限(security_invoker = off):它横跨 finance 与 hr(employees 有 RLS),invoker 会让读者无权的那一侧静默丢掉行,而行消失在这里意味着"少了一笔欠员工的钱"(OPS-14 修法 (a))。★ APR-ROUTE-1(F1,Tim 的 R5):行谓词写在视图里 —— has_permission(''module.finance.view'') OR employee_id = current_user_employee(),与 medical_claim_status 同形;此前它把每一笔报销交给任何一个登录的人,只靠页面自己的过滤挡着。';

-- ════════════════════════════════════════════════════════════════════════════
-- ⑦ 自证(全部读目录与真数据;任何一条不过,整支回滚)
-- ════════════════════════════════════════════════════════════════════════════
DO $proof$
DECLARE
    b        record;
    v_n      integer;
    v_m      integer;
    v_src    text;
    v_row    record;
    v_l1     text;
    v_l2     text;
BEGIN
    SELECT * INTO b FROM aproute1a_before;
    SELECT approval_level1_role_code, approval_level2_role_code INTO v_l1, v_l2 FROM finance_settings;

    -- ① 审批仍然开着 -------------------------------------------------------
    IF (SELECT approvals_enabled FROM finance_settings) IS NOT TRUE THEN
        RAISE EXCEPTION 'APRROUTE1A_PROOF_1|审批不再是开着的';
    END IF;

    -- ② 一行留痕都没写,每一条链的在途张数都没变 ---------------------------
    IF (SELECT count(*) FROM approval_log) <> b.approval_log_rows
       OR (SELECT count(*) FROM leave_requests WHERE status='pending' AND deleted_at IS NULL) <> b.leave_pending
       OR (SELECT count(*) FROM medical_claims WHERE status='submitted' AND deleted_at IS NULL) <> b.claims_pending
       OR (SELECT count(*) FROM performance_reviews WHERE status='submitted') <> b.reviews_pending
       OR (SELECT count(*) FROM purchase_orders WHERE approval_status='pending' AND deleted_at IS NULL) <> b.po_pending
       OR (SELECT count(*) FROM work_orders WHERE status='draft') <> b.wo_draft
       OR (SELECT count(*) FROM expense_claims WHERE status='submitted') <> b.claim_pending
       OR (SELECT count(*) FROM stocktakes WHERE status='open' AND deleted_at IS NULL) <> b.stocktake_open THEN
        RAISE EXCEPTION 'APRROUTE1A_PROOF_2|有一个在途计数或留痕行数变了 —— 本刀不该写任何业务数据';
    END IF;

    -- ③ ★ 历史行的 self_decided = false 是真话:按新判据把每一行 approved/rejected
    --     的"决定人是不是提单人或主角"重算一遍,必须一行都没有。
    SELECT count(*) INTO v_n
      FROM approval_log a
      LEFT JOIN leave_requests      lr ON a.subject_type='leave_request'      AND lr.id = a.subject_id
      LEFT JOIN medical_claims      mc ON a.subject_type='medical_claim'      AND mc.id = a.subject_id
      LEFT JOIN performance_reviews pr ON a.subject_type='performance_review' AND pr.id = a.subject_id
      LEFT JOIN purchase_orders     po ON a.subject_type='purchase_order'     AND po.id = a.subject_id
      LEFT JOIN expense_claims      ec ON a.subject_type='expense_claim'      AND ec.id = a.subject_id
      LEFT JOIN stocktakes          st ON a.subject_type='stocktake'          AND st.id = a.subject_id
      LEFT JOIN work_orders         wo ON a.subject_type='work_order'         AND wo.id = a.subject_id
     WHERE a.decision IN ('approved', 'rejected')
       AND self_leg(COALESCE(lr.created_by, mc.created_by, pr.submitted_by, po.created_by,
                             ec.created_by, st.created_by, wo.created_by),
                    COALESCE(lr.employee_id, mc.employee_id, pr.employee_id, ec.employee_id),
                    a.actor_user_id) <> 'none';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'APRROUTE1A_PROOF_3|历史留痕里有 % 行按新判据是自批 —— DEFAULT false 对它们是一句假话', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM approval_log WHERE self_decided;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'APRROUTE1A_PROOF_3|加列之后已经有 % 行 self_decided = true', v_n;
    END IF;

    -- ④ R1:二级的每一个真持有人,都在一级的有资格名单里 --------------------
    SELECT count(*) INTO v_n FROM real_role_holders(v_l2) h
     WHERE NOT EXISTS (SELECT 1 FROM approval_level_eligible(1::smallint, v_l1, v_l2) e WHERE e.user_id = h.user_id);
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'APRROUTE1A_PROOF_4|R1 没生效:% 个二级持有人不在一级的有资格名单里', v_n;
    END IF;
    -- 反方向:一级的持有人【不】因此进入二级(R1 只向下,不向上)
    SELECT count(*) INTO v_n FROM real_role_holders(v_l1) h
     WHERE NOT EXISTS (SELECT 1 FROM real_role_holders(v_l2) h2 WHERE h2.user_id = h.user_id)
       AND EXISTS (SELECT 1 FROM approval_level_eligible(2::smallint, v_l1, v_l2) e WHERE e.user_id = h.user_id);
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'APRROUTE1A_PROOF_4|R1 越界:% 个只持一级角色的人进了二级的有资格名单', v_n;
    END IF;
    -- require_approver_for 的函数体读的是那一份定义,不是自己的
    SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname='require_approver_for';
    IF v_src NOT LIKE '%approval_level_eligible%' OR v_src LIKE '%real_role_holders%' THEN
        RAISE EXCEPTION 'APRROUTE1A_PROOF_4|require_approver_for 没有改读 approval_level_eligible(或者还留着第二份判据)';
    END IF;

    -- ⑤ R4:每一条链仍然有人批得动,而一级的人数 ≥ 二级(R1)---------------
    SELECT count(*), count(*) FILTER (WHERE approvers = 0) INTO v_n, v_m FROM approval_gate_intersections();
    IF v_n = 0 THEN
        RAISE EXCEPTION 'APRROUTE1A_PROOF_5|求交一行都没有 —— 一个瞎掉的判据与一棵干净的树都打印 0';
    END IF;
    IF v_m > 0 THEN
        RAISE EXCEPTION 'APRROUTE1A_PROOF_5|有 % 条链没有人批得动 —— 审批从此关掉就开不回来', v_m;
    END IF;
    FOR v_row IN
        SELECT a.action_function, a.approvers AS l1, b2.approvers AS l2
          FROM approval_gate_intersections() a
          JOIN approval_gate_intersections() b2 ON b2.action_function = a.action_function AND b2.level = 2
         WHERE a.level = 1 AND a.approvers < b2.approvers
    LOOP
        RAISE EXCEPTION 'APRROUTE1A_PROOF_5|% 一级 % 人 < 二级 % 人 —— R1 之后一级至少包含二级', v_row.action_function, v_row.l1, v_row.l2;
    END LOOP;
    -- ★ 在途的那一张报销单(若有)仍然有人批得动 —— WOULD_STRAND 的判据对它为假
    FOR v_row IN
        SELECT d.code, d.subject_type, d.raiser_user_id, d.subject_employee_id,
               approval_level_at(d.amount_base, (SELECT approval_threshold_base FROM finance_settings)) AS lvl
          FROM approval_pending_documents() d
         WHERE d.amount_base IS NOT NULL
    LOOP
        SELECT count(*) INTO v_n
          FROM approval_chain_gates() cg
         WHERE cg.subject_type = v_row.subject_type AND cg.level = v_row.lvl
           AND NOT EXISTS (SELECT 1 FROM approval_deciders(cg.subject_type, cg.action_function, cg.level,
                                          v_row.raiser_user_id, v_row.subject_employee_id, v_l1, v_l2));
        IF v_n > 0 THEN
            RAISE EXCEPTION 'APRROUTE1A_PROOF_5|在途的 % 在本刀之后没有人批得动', v_row.code;
        END IF;
    END LOOP;

    -- ⑥ forbid_self_approval:只剩一个签名,六个调用点各自说出了自己的类型 --
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname='forbid_self_approval';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'APRROUTE1A_PROOF_6|forbid_self_approval 有 % 个签名 —— 旧的没 DROP 掉', v_n;
    END IF;
    FOR v_row IN
        SELECT * FROM (VALUES ('decide_expense_claim','expense_claim'), ('decide_medical_claim','medical_claim'),
                              ('decide_leave_request','leave_request'), ('approve_review','performance_review'),
                              ('post_stocktake','stocktake'), ('release_work_order','work_order')) v(fn, st)
    LOOP
        SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname='public' AND p.proname = v_row.fn;
        IF v_src NOT LIKE '%forbid_self_approval(%''' || v_row.st || ''')%' THEN
            RAISE EXCEPTION 'APRROUTE1A_PROOF_6|% 没有以类型 % 调 forbid_self_approval', v_row.fn, v_row.st;
        END IF;
    END LOOP;

    -- ⑦ R2 的例外只有两类 —— 用每一个类型问一遍那支唯一的判据 ----------------
    --    代入的人:二级角色的一个真持有人,他自己就是主角。只有 expense / medical 为真。
    FOR v_row IN
        SELECT h.user_id, account_person(h.user_id) AS emp
          FROM real_role_holders(v_l2) h WHERE account_person(h.user_id) IS NOT NULL LIMIT 1
    LOOP
        SELECT count(*) INTO v_n
          FROM unnest(ARRAY['leave_request','medical_claim','performance_review','purchase_order',
                            'payment','expense','expense_claim','pricing_formula','stocktake','work_order']) t(st)
         WHERE self_approval_exception(t.st, v_row.emp, v_row.user_id, v_l2);
        IF v_n <> 2 THEN
            RAISE EXCEPTION 'APRROUTE1A_PROOF_7|例外对 % 个类型成立 —— 应当恰好是 expense_claim 与 medical_claim 两个', v_n;
        END IF;
        IF NOT self_approval_exception('expense_claim', v_row.emp, v_row.user_id, v_l2)
           OR NOT self_approval_exception('medical_claim', v_row.emp, v_row.user_id, v_l2) THEN
            RAISE EXCEPTION 'APRROUTE1A_PROOF_7|例外对报销或医疗不成立';
        END IF;
        -- 不是二级持有人的人,例外不成立(用一级角色去问)
        IF self_approval_exception('expense_claim', v_row.emp, v_row.user_id, v_l1)
           AND NOT EXISTS (SELECT 1 FROM real_role_holders(v_l1) h WHERE h.user_id = v_row.user_id) THEN
            RAISE EXCEPTION 'APRROUTE1A_PROOF_7|例外对一个不持那个角色的人成立了';
        END IF;
    END LOOP;

    -- ⑧ F1 / R5:谓词在视图里,并且【真的在拦】 --------------------------------
    --    本迁移以 postgres 跑、没有 JWT:has_permission 恒假、current_user_employee() 为 NULL,
    --    所以它经这张视图应当读到 0 行,而基表有 b.claims_total 行。
    --    ☞ 这是一次【身份写明】的读数:postgres,rolbypassrls = true,读的是【视图】。
    SELECT pg_get_viewdef('public.expense_claim_status'::regclass) INTO v_src;
    IF v_src NOT LIKE '%has_permission(''module.finance.view''::text)%'
       OR v_src NOT LIKE '%current_user_employee()%' THEN
        RAISE EXCEPTION 'APRROUTE1A_PROOF_8|expense_claim_status 里没有那句行谓词';
    END IF;
    IF NULLIF(current_setting('request.jwt.claims', true), '') IS NOT NULL THEN
        RAISE EXCEPTION 'APRROUTE1A_PROOF_8|本会话带着 claims —— 下面那个 0 就不是谓词的读数了';
    END IF;
    SELECT count(*) INTO v_n FROM expense_claim_status;
    IF b.claims_total > 0 AND v_n <> 0 THEN
        RAISE EXCEPTION 'APRROUTE1A_PROOF_8|无身份的读者经视图读到 % 行(基表 % 行)—— 谓词没在拦', v_n, b.claims_total;
    END IF;
    SELECT reloptions::text INTO v_src FROM pg_class WHERE oid = 'public.expense_claim_status'::regclass;
    IF v_src IS NULL OR v_src NOT LIKE '%security_invoker=off%' THEN
        RAISE EXCEPTION 'APRROUTE1A_PROOF_8|expense_claim_status 不再是属主权限(reloptions=%)', v_src;
    END IF;

    RAISE NOTICE 'APRROUTE1A_AFTER enabled=% approval_log=% expense_claims_submitted=% | view_rows_as_postgres_no_jwt=% base_rows=%',
        (SELECT approvals_enabled FROM finance_settings), (SELECT count(*) FROM approval_log),
        (SELECT count(*) FROM expense_claims WHERE status='submitted'),
        v_n, b.claims_total;
    FOR v_row IN SELECT subject_type, action_function, level, role_code, approvers FROM approval_gate_intersections() LOOP
        RAISE NOTICE 'APRROUTE1A_CHAIN % % L% role=% persons=%', v_row.subject_type, v_row.action_function, v_row.level, v_row.role_code, v_row.approvers;
    END LOOP;
    RAISE NOTICE 'APRROUTE1A 自证八条全过。';
END
$proof$;

COMMIT;
