-- db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql
-- ROLE-1 · Batch 2a —— Tim 的角色与审批矩阵(docs/role-matrix.md)第 2 批的前一半。
-- 由 db/scripts/build_role1b2a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本批做什么】(Batch 2 grilling Q5–Q11 + Batch 2a grilling Q1–Q8,Tim 全部接受)
--   ① 三个新动作码,只给 cfo:action.finance_settings · action.customer_credit · action.supplier_approve。
--      ★ 不给 admin 角色(Tim)。⚠ admin@ 同时持 cfo 角色,所以 admin@ 经由 cfo 拿得到这三个码 ——
--        那是 Tim 自己在 /settings/accounts 上的决定,本刀不碰 user_roles。
--   ② 财务设置(Q10):accounts / currencies / company_profile 的写策略与 enforce_write_permission
--      从 module.finance.edit 换成 action.finance_settings;finance_settings 的写策略不换
--      (锁期仍归财务),加一支列守卫 guard_finance_settings_cfo_columns + 写入口 set_finance_settings;
--      company-assets 桶的上传 / 改 / 删改为要 action.finance_settings(读不变:PDF 要读标志)。
--   ③ 客户信用(Q11):列守卫 guard_customer_credit_write + 写入口 set_customer_credit;
--      批量导入不许带 credit_limit_base / credit_hold。
--   ④ 供应商审批(Q8–Q9 · Q2–Q4):supplier_status_moves()(唯一定义)· set_supplier_status
--      (唯一改法)· guard_supplier_direct_write(created_by 永不可改;直连不许改状态、
--      不许生出非 draft、不许伪造建档人)· approved_by / approved_at(批准时盖、回草稿时清)·
--      supplier_status_history(每一步)· approval_log 加 'supplier'(送审 / 批准 / 驳回)·
--      operations_now 加 supplier_pending_approval。不是审批引擎的链。
--   ⑤ 未批准的供应商不付款(Q5):payment_request_payee_check 只放行 approved / active 且没被删;
--      新采购单同样(Q7 / Q1):trg_purchase_orders_supplier_approved,只挂 INSERT、每一条路径都拦。
--   ⑥ 仓库建供应商(Q5):warehouse 拿到 module.suppliers.view + module.suppliers.edit。
--
-- 【不做什么】不批准任何供应商(Q6)。审批开关与策略一个字都不碰。Batch 2b(合同条款、
--   金属价格、直接销售、化验)是下一刀。
--
-- ★★【本迁移一提交,线上就有 377,673.50 的应付付不出去】★★(以 tim@ 身份读 ap_open_items 视图,
--   2026-09-24 18:31 CST)—— Acme(SUP-2026-0002)97,064.50 · Bosch(SUP-2026-0095)280,000.00 ·
--   Ever Higher(SUP-2026-0445)109.00 三家是 draft;ZZ1B-GDS 500.00 是一家已删的供应商。
--   前三家由 Choo Er 送审、Tim(tim@)批准之后恢复可付;第四家是测试残骸,记在
--   docs/known-wrong-until-cutover.md。此刻线上 0 张付款申请,所以没有一张在途申请被卡住。
--
-- 【RUNTIME CONFIG 的引导默认值,照 AGENTS.md 那条规矩说清楚】
--   · role_permissions 的引导【改了】:warehouse 加 module.suppliers.view / .edit(Q5)。
--     它说的仍是它原来的意思(全新安装的起点);cfo 仍不在引导里(ROLE1-BOOTSTRAP-MISSING-ROLES),
--     所以三个新码在全新安装里没有持有者 —— 与 Batch 1 的 action.finance_reopen 同一个处境。
--   · permissions 是逐行比对的种子,新增三行,镜像同步。
--   · finance_settings 不是种子表;本刀没有改变任何 RUNTIME CONFIG 表里某一列的【含义】。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;在途单据一张不少;
-- approval_log 一行没写;供应商状态一家没变;每一个角色的码 = 之前 + 本刀那五条授权,不多不少;
-- 每一张在途单据都还有一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B2A_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ('action.finance_settings', 'action.customer_credit',
                                                        'action.supplier_approve')) THEN
        RAISE EXCEPTION 'ROLE1B2A_PRE|new codes already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                WHERE r.code = 'warehouse' AND rp.permission_code LIKE 'module.suppliers.%') THEN
        RAISE EXCEPTION 'ROLE1B2A_PRE|warehouse already holds a suppliers code';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'suppliers' AND column_name = 'approved_by') THEN
        RAISE EXCEPTION 'ROLE1B2A_PRE|suppliers.approved_by already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM payment_requests WHERE status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'ROLE1B2A_PRE|a payment request is in flight — Step 0 read none';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE b2a_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved');
CREATE TEMP TABLE b2a_log_before ON COMMIT DROP AS SELECT count(*) AS n FROM approval_log;
CREATE TEMP TABLE b2a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE b2a_suppliers_before ON COMMIT DROP AS
SELECT id, status::text AS status, created_by, deleted_at FROM suppliers;
CREATE TEMP TABLE b2a_credit_before ON COMMIT DROP AS
SELECT id, credit_limit_base, credit_hold FROM customers;
CREATE TEMP TABLE b2a_je_before ON COMMIT DROP AS SELECT count(*) AS n FROM journal_entries;

-- ── 1 · 目录:三个新码 ────────────────────────────────────────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.finance_settings', 'action', 'Finance settings, chart of accounts, currencies and company details', '财务设置、科目表、币种与公司资料', 'Change the chart of accounts, currencies, the company profile (including bank details and logo), GST registration and the other finance settings. The period lock stays with Finance (edit); the approvals switch and policy stay with system administration.', '修改科目表、币种、公司资料(含银行资料与标志)、GST 登记与其余财务设置。锁期仍归「财务(编辑)」;审批开关与策略仍归系统管理。', 980),
    ('action.customer_credit', 'action', 'Set customer credit limits and holds', '设定客户信用额度与冻结', 'Set or clear a customer''s credit limit and put a customer on or off credit hold. Every other customer field stays with Customers (edit).', '设定或清除客户的信用额度,冻结或解冻客户。客户的其余各项仍归「客户(编辑)」。', 990),
    ('action.supplier_approve', 'action', 'Approve, reject, blacklist and restore suppliers', '批准、驳回、拉黑与恢复供应商', 'Approve or reject a supplier submitted for review, blacklist a supplier, and restore a blacklisted one (move it to archived). Nobody approves a supplier they created. Every other status move stays with Suppliers (edit).', '批准或驳回一家送审的供应商,拉黑一家供应商,把一家被拉黑的恢复(移到归档)。没有人批准自己建的供应商。其余状态变动仍归「供应商(编辑)」。', 1000);

-- ── 2 · suppliers:批准戳两列(Q4)────────────────────────────────────────────
ALTER TABLE public.suppliers ADD COLUMN approved_by uuid;
ALTER TABLE public.suppliers ADD COLUMN approved_at timestamptz;
COMMENT ON COLUMN public.suppliers.approved_by IS
    'ROLE-1 Batch 2a(Q4):批准这一家的人(CFO,action.supplier_approve)。只在状态进入 approved 时由 validate_supplier_status_transition 盖;回到 draft 时清空,所以它说的永远是此刻生效的那一次批准。驳回、拉黑、恢复不盖它 —— 它们记在 approval_log 与 supplier_status_history。';
COMMENT ON COLUMN public.suppliers.approved_at IS
    'ROLE-1 Batch 2a(Q4):批准的时刻。与 approved_by 同盖同清。';

-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/supplier_status_moves.sql
-- ROLE-1 · Batch 2a(Tim 的矩阵 §6,Batch 2 grilling Q8):供应商状态机 —— 【哪一步合法、要哪一个码】的唯一定义。
--
-- 【三个读者,一份定义】
--   · validate_supplier_status_transition(触发器):一步不在这张表里 → INVALID_STATUS_TRANSITION;
--   · set_supplier_status:这一步要哪个码 → require_permission;
--   · /suppliers/[id]/edit 的状态面板:画哪些钮、哪一个钮要什么码(禁用时说出那个码)。
-- 此前合法跳转写在触发器体里、页面上另抄一份(statusMachine.ts)—— 两份迟早各说各话。
--
-- 【Tim 的 Q8,原样】
--   CFO(action.supplier_approve):→ approved、→ rejected(都只能从 pending_review 来)、
--       任何 → blacklisted、blacklisted → archived(「恢复」:拉黑之后回头的唯一一步)。
--   module.suppliers.edit:其余每一步 —— 送审、撤回送审、启用、暂停、重新启用、归档、归档后回草稿。
-- 跳转图本身【一步没改】(与 ROLE-1 之前触发器体里那一份逐条相同);改的只是每一步归谁。
--
-- 【返回 text,不返回 supplier_status】镜像函数的签名只许内置类型(AGENTS.md):重建时
-- db/functions 先于 db/tables 重放,那时枚举还不存在。比较的一方各自 ::text。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.supplier_status_moves()
 RETURNS TABLE(from_status text, to_status text, required_code text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT f, t, c
      FROM (VALUES
        ('draft',          'pending_review', 'module.suppliers.edit'),
        ('draft',          'archived',       'module.suppliers.edit'),
        ('pending_review', 'approved',       'action.supplier_approve'),
        ('pending_review', 'rejected',       'action.supplier_approve'),
        ('pending_review', 'draft',          'module.suppliers.edit'),
        ('rejected',       'draft',          'module.suppliers.edit'),
        ('rejected',       'archived',       'module.suppliers.edit'),
        ('approved',       'active',         'module.suppliers.edit'),
        ('approved',       'suspended',      'module.suppliers.edit'),
        ('approved',       'archived',       'module.suppliers.edit'),
        ('active',         'suspended',      'module.suppliers.edit'),
        ('active',         'blacklisted',    'action.supplier_approve'),
        ('active',         'archived',       'module.suppliers.edit'),
        ('suspended',      'active',         'module.suppliers.edit'),
        ('suspended',      'blacklisted',    'action.supplier_approve'),
        ('suspended',      'archived',       'module.suppliers.edit'),
        ('blacklisted',    'archived',       'action.supplier_approve'),
        ('archived',       'draft',          'module.suppliers.edit')
      ) m(f, t, c)
$function$;

COMMENT ON FUNCTION public.supplier_status_moves() IS
'ROLE-1 Batch 2a:供应商状态机的唯一定义 —— 每一步合法跳转与它要的码。触发器、set_supplier_status 与状态面板三处都读它。CFO(action.supplier_approve)管 → approved / → rejected / → blacklisted / blacklisted → archived;其余归 module.suppliers.edit(Tim,Q8)。';

-- db/functions/guard_supplier_direct_write.sql
-- ROLE-1 · Batch 2a(Batch 2 grilling Q8,Batch 2a grilling Q2):把"建档人不能批自己建的"
-- 那条规矩的【主语】钉死,并把状态的改法收成一扇门。
--
-- Batch 2 的 grilling 量出这条规矩今天有三个洞,本守卫补的是其中两个半:
--   ① 直连 INSERT 可以把 created_by 写成任何人(trg_supplier_creator 只在 NULL 时落笔);
--   ② 直连 UPDATE 可以改写 created_by,或把它清成 NULL(清成 NULL = 规矩不再适用);
--   ③ 直连 INSERT 可以直接生出一家 approved / active 的供应商(跳转触发器跳过 INSERT)。
--
-- 【规则】
--   · created_by【任何路径都不许改】(属主路径也一样:一个会被改写的主语不是主语)
--     → SUPPLIER_CREATED_BY_IMMUTABLE。
--   · 直连写(row_security_active = true):
--       INSERT 的状态必须是 draft → SUPPLIER_INSERT_MUST_BE_DRAFT|<状态>;
--       INSERT 的 created_by 只能是空(由 trg_supplier_creator 落成自己)或自己
--         → SUPPLIER_CREATED_BY_FORGED;
--       INSERT 不许带批准戳;
--       UPDATE 改状态 → SUPPLIER_STATUS_THROUGH_FUNCTION_ONLY(只走 set_supplier_status);
--       UPDATE 改批准戳 → SUPPLIER_APPROVAL_STAMP_THROUGH_FUNCTION_ONLY。
--   · 属主路径(fixture、批量导入、set_supplier_status)只受第一条约束 —— 批量导入本来就
--     不许带 status / created_by / 批准戳(master_import_forbidden_columns)。
--
-- 【触发器顺序】trg_supplier_creator(字典序在前)先把 NULL 落成 auth.uid(),
-- 本守卫(trg_suppliers_direct_write)后跑,看到的就是落笔之后的值 —— 所以
-- "空或自己"在这里读作"等于 auth.uid(),或仍为 NULL(auth.uid() 不是一个真账号)"。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_supplier_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION 'SUPPLIER_CREATED_BY_IMMUTABLE';
    END IF;
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'draft' THEN
            RAISE EXCEPTION 'SUPPLIER_INSERT_MUST_BE_DRAFT|%', NEW.status;
        END IF;
        IF NEW.created_by IS NOT NULL AND NEW.created_by IS DISTINCT FROM auth.uid() THEN
            RAISE EXCEPTION 'SUPPLIER_CREATED_BY_FORGED';
        END IF;
        IF NEW.approved_by IS NOT NULL OR NEW.approved_at IS NOT NULL THEN
            RAISE EXCEPTION 'SUPPLIER_APPROVAL_STAMP_THROUGH_FUNCTION_ONLY';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
        RAISE EXCEPTION 'SUPPLIER_STATUS_THROUGH_FUNCTION_ONLY';
    END IF;
    IF NEW.approved_by IS DISTINCT FROM OLD.approved_by
       OR NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
        RAISE EXCEPTION 'SUPPLIER_APPROVAL_STAMP_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_supplier_direct_write() IS
'ROLE-1 Batch 2a:suppliers.created_by 任何路径都不许改(SUPPLIER_CREATED_BY_IMMUTABLE)。直连写(row_security_active)另受四条:INSERT 必须是 draft、created_by 只能是空或自己、不许带批准戳;UPDATE 不许改状态(只走 set_supplier_status)、不许改批准戳。INVOKER,以分出直连写与属主路径。';

-- db/functions/log_supplier_status_change.sql
-- ROLE-1 · Batch 2a(Batch 2a grilling Q3):供应商状态的【每一步】都进 supplier_status_history ——
-- 拉黑与恢复也在内。approval_log 只记送审 / 批准 / 驳回(那三步是一次审批);拉黑是 CFO 的
-- 决定却不是一次审批,此前它唯一的痕迹是 updated_by,而下一次随便一个编辑就把它盖掉了。
--
-- 【为什么挂在触发器上,而不是写在 set_supplier_status 里】状态还有属主路径能改
-- (fixture、将来的迁移)。一条"每一步都记"的规矩,只挂在一扇门上就不是每一步。
-- 附注由 set_supplier_status 经事务内设置项 evoltrya.supplier_status_note 交过来;
-- 别的路径没有附注,留 NULL。
--
-- SECURITY DEFINER:变动史没有 INSERT 策略(留痕不该有第二个写法),触发器以属主身份写;
-- changed_by = auth.uid() 仍是按下去的那个人。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.log_supplier_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    INSERT INTO supplier_status_history (supplier_id, from_status, to_status, changed_by, note)
    VALUES (NEW.id, OLD.status::text, NEW.status::text, auth.uid(),
            NULLIF(current_setting('evoltrya.supplier_status_note', true), ''));
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.log_supplier_status_change() IS
'ROLE-1 Batch 2a:供应商状态每变一次,往 supplier_status_history 写一行(从、到、谁、何时、附注)。挂在 AFTER UPDATE OF status 上,所以每一条路径都记。';

-- db/functions/guard_supplier_status_history_append_only.sql
-- ROLE-1 · Batch 2a:供应商状态变动史只增不改。自己报名(FIN-31)—— 与
-- guard_customer_credit_history_append_only 同一个形状。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_supplier_status_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'SUPPLIER_STATUS_HISTORY_APPEND_ONLY|update|%', OLD.id;
    ELSE
        RAISE EXCEPTION 'SUPPLIER_STATUS_HISTORY_APPEND_ONLY|delete|%', OLD.id;
    END IF;
END;
$function$;

-- db/functions/set_supplier_status.sql
-- ROLE-1 · Batch 2a(Tim 的矩阵 §6,Batch 2 grilling Q8–Q9,Batch 2a grilling Q2–Q4):
-- 供应商状态的【唯一】改法。此前没有这支函数 —— 状态面板直连 UPDATE suppliers.status,
-- 跳转触发器只管"合不合法",不管"谁可以"。
--
-- 【做什么,按顺序】
--   ① 供应商在、没被删(FOR UPDATE 锁住)→ 否则 SUPPLIER_NOT_FOUND;
--   ② 这一步在 supplier_status_moves() 里 → 否则 INVALID_STATUS_TRANSITION|从|到
--      (与触发器同一句话,因为读的是同一张表);
--   ③ require_permission(那一步要的码)—— CFO 那四类走 action.supplier_approve,其余 module.suppliers.edit;
--   ④ → approved / → rejected:**建档人永远不能批自己建的**(Q8)—— forbid_self_approval
--      按【人】认(account_person:一个人的两个账号算一个人),'supplier' 不在
--      self_approval_exception 的任何一条例外里,所以永远拒 SELF_APPROVAL_FORBIDDEN|raiser。
--      created_by 为 NULL 的供应商(线上 7 家,SOD-1 之前建的)这条不适用 —— 那是 Tim 裁过的(Q8)。
--   ⑤ UPDATE 状态;approved_by / approved_at 的盖章与清空由触发器做(Q4),
--      变动史由 trg_suppliers_status_history 记(Q3)—— 本函数把 p_note 经一个事务内的
--      设置项交给那支触发器,写完即清。
--   ⑥ approval_log:送审记 submitted、批准记 approved、驳回记 rejected(Q3);subject_type = 'supplier'。
--
-- 【它【不是】审批引擎的一条链】(Q9)不调用 require_approver_for,没有金额档位,
-- 审批开关关着也照样要 CFO 批 —— fixture 203 断言 approval_chain_gates() 等于每一支
-- 调用 require_approver_for 的函数,所以这里不许调用它。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.set_supplier_status(p_supplier_id uuid, p_to text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s    suppliers%ROWTYPE;
    v_to   supplier_status;
    v_code text;
BEGIN
    IF p_to IS NULL OR NOT (p_to = ANY (enum_range(NULL::supplier_status)::text[])) THEN
        RAISE EXCEPTION 'SUPPLIER_STATUS_UNKNOWN|%', COALESCE(p_to, '?');
    END IF;
    v_to := p_to::supplier_status;

    SELECT * INTO v_s FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', COALESCE(p_supplier_id::text, '?');
    END IF;

    SELECT m.required_code INTO v_code
      FROM supplier_status_moves() m
     WHERE m.from_status = v_s.status::text AND m.to_status = v_to::text;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'INVALID_STATUS_TRANSITION|%|%', v_s.status, v_to;
    END IF;
    PERFORM require_permission(v_code);

    IF v_to IN ('approved', 'rejected') THEN
        PERFORM forbid_self_approval(v_s.created_by, NULL, 'supplier');
    END IF;

    PERFORM set_config('evoltrya.supplier_status_note', COALESCE(NULLIF(btrim(p_note), ''), ''), true);
    UPDATE suppliers SET status = v_to, updated_by = auth.uid() WHERE id = p_supplier_id;
    PERFORM set_config('evoltrya.supplier_status_note', '', true);

    IF v_to = 'pending_review' THEN
        PERFORM record_approval_decision('supplier', p_supplier_id, 'submitted', NULL, NULLIF(btrim(p_note), ''));
    ELSIF v_to IN ('approved', 'rejected') THEN
        PERFORM record_approval_decision('supplier', p_supplier_id, v_to::text, NULL, NULLIF(btrim(p_note), ''));
    END IF;

    RETURN jsonb_build_object('code', v_s.code, 'from', v_s.status, 'to', v_to);
END;
$function$;

COMMENT ON FUNCTION public.set_supplier_status(uuid, text, text) IS
'ROLE-1 Batch 2a:供应商状态的唯一改法。每一步要的码读 supplier_status_moves()(CFO 的 action.supplier_approve 管批准 / 驳回 / 拉黑 / 拉黑后归档;其余 module.suppliers.edit)。批准与驳回按人拒自批(建档人)。送审、批准、驳回写 approval_log(subject_type = supplier);每一步都进 supplier_status_history。不是审批引擎的链:审批开关不关它。';

-- ─── record_approval_decision
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
        -- ★ PAY-REQ-1:付款申请。提单人 = created_by;主角 = 收款员工(付给供应商时 NULL)。
        --   金额冻结的是【申请上】那一组(审批人批的就是它);本位币额是提交时的试算值。
        WHEN 'payment_request' THEN
            SELECT true, r.code, r.amount_ccy, r.currency,
                   CASE WHEN r.amount_ccy > 0 THEN r.amount_base / r.amount_ccy END,
                   r.amount_base, r.created_by, r.employee_id
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser, v_subject
              FROM payment_requests r WHERE r.id = p_subject_id;
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
        WHEN 'supplier' THEN
            -- ROLE-1 Batch 2a(Q3 / Q9):供应商的送审、批准、驳回。没有金额 —— 批的是
            -- "可以跟这一家做生意",不是一笔钱;提单人 = 建档人(created_by)。
            SELECT true, s.code, s.created_by INTO v_ok, v_code, v_raiser
              FROM suppliers s WHERE s.id = p_subject_id;
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

-- db/functions/payment_request_payee_check.sql
-- PAY-REQ-1(2026-09-23,Tim 的 Q4):一张出款申请的收款人若是【被拉黑 / 暂停】的
-- 供应商,批准与付款都按名拒。提交也拒 —— 一张注定批不了的申请不该进 CFO 的队列。
--
-- ★ ROLE-1 · Batch 2a(Tim 2026-09-23,Batch B grilling Q5):**一家【未批准】的供应商,
--   付款申请提不了、批不了、付不了。** "可付"的定义收成一句话:
--       状态是 approved 或 active,并且没被删。
--   其余每一种状态(draft / pending_review / rejected / suspended / blacklisted / archived)
--   都按名拒,状态原样写进拒绝里:PAYMENT_REQUEST_SUPPLIER_BLOCKED|<编号>|<状态>;
--   已删的供应商读作 PAYMENT_REQUEST_SUPPLIER_BLOCKED|<编号>|deleted。
--   此前这里只拦 blacklisted 与 suspended,并且写着"draft / pending / archived 不拦,
--   线上的供应商付款就付给过 draft 的供应商" —— 那一段说的是 PAY-REQ-1 当时的规矩,
--   本刀把它换掉了。线上此刻 377,673.50 的应付因此付不出去,直到 CFO 批准那三家
--   (docs/handbacks/ROLE-1.md § Batch 2a)。
--
-- 三个调用点不变:submit_payment_request(提交)、decide_payment_request(批准那一支;
-- 驳回不查 —— 驳回一张付不出去的申请正是该做的事)、pay_payment_request(付款)。
--
-- 冲销申请不查(Q5 豁免):冲销是把钱【收回来】,拦住它只会把一笔记错的付款锁死在账上。
-- 本函数只对 payment_out 起作用,冲销(payment_reversal)从第一行就返回。
--
-- 内层算子,无调用者检查;只从 SECURITY DEFINER 的申请函数体内调用。
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.
-- ROLE-1 Batch 2a: db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.payment_request_payee_check(p_kind text, p_supplier_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code    text;
    v_status  text;
    v_deleted boolean;
BEGIN
    IF p_kind <> 'payment_out' OR p_supplier_id IS NULL THEN
        RETURN;
    END IF;
    SELECT s.code, s.status::text, s.deleted_at IS NOT NULL INTO v_code, v_status, v_deleted
      FROM suppliers s WHERE s.id = p_supplier_id;
    IF NOT FOUND THEN
        RETURN;  -- record_payment_internal 按它自己的名字拒(COUNTERPARTY_NOT_FOUND)
    END IF;
    IF v_deleted THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_SUPPLIER_BLOCKED|%|deleted', v_code;
    END IF;
    IF v_status NOT IN ('approved', 'active') THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_SUPPLIER_BLOCKED|%|%', v_code, v_status;
    END IF;
END;
$function$
;

-- db/functions/guard_po_supplier_approved.sql
-- ROLE-1 · Batch 2a(Batch 2 grilling Q7,Batch 2a grilling Q1):**新开的采购单,供应商必须已批准**。
--
-- 【规则】一张采购单【生下来】那一刻,供应商必须是 approved 或 active、且没被删;
-- 其余每一种状态按名拒:PO_SUPPLIER_NOT_APPROVED|<供应商编号>|<状态>(已删读作 deleted)。
--
-- 【只在 INSERT 上】Q7 的原话:既有采购单照常收货。supplier_id 在 UPDATE 上本来就不许改
-- (guard_po_amendable),所以一张已经开出去的单不会因为这条规矩改不动、收不了货、结不了。
--
-- 【为什么是触发器、而且【每一条路径】都拦(属主也拦)】create_purchase_order 是唯一
-- 开单的函数,但 purchase_orders 上还开着一条 module.purchasing.edit 的直连 INSERT 策略 ——
-- 只查函数,那扇门就绕过去了(Q1)。先例是同一张表上的 trg_purchase_orders_vendor_not_forwarder。
-- 属主路径也拦:一张开给未批准供应商的新单,从哪条路来都是同一件不该发生的事;
-- 要这种单的 fixture 自己去建一家 active 的供应商。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_po_supplier_approved()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code    text;
    v_status  text;
    v_deleted boolean;
BEGIN
    SELECT s.code, s.status::text, s.deleted_at IS NOT NULL INTO v_code, v_status, v_deleted
      FROM suppliers s WHERE s.id = NEW.supplier_id;
    IF NOT FOUND THEN
        RETURN NEW;  -- 外键会按它自己的名字拒
    END IF;
    IF v_deleted THEN
        RAISE EXCEPTION 'PO_SUPPLIER_NOT_APPROVED|%|deleted', v_code;
    END IF;
    IF v_status NOT IN ('approved', 'active') THEN
        RAISE EXCEPTION 'PO_SUPPLIER_NOT_APPROVED|%|%', v_code, v_status;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_po_supplier_approved() IS
'ROLE-1 Batch 2a:新采购单的供应商必须是 approved 或 active 且没被删,否则 PO_SUPPLIER_NOT_APPROVED|<编号>|<状态或 deleted>。只挂在 INSERT 上(既有采购单照常收货),每一条路径都拦(直连 INSERT 策略那扇门也在内)。';

-- db/functions/guard_finance_settings_cfo_columns.sql
-- ROLE-1 · Batch 2a(Tim 的矩阵 §12,Batch 2 grilling Q10):**财务设置只归 CFO** ——
-- 除了两处:锁期(locked_before)仍归财务,审批四列仍只走 set_approvals_policy。
--
-- 【为什么是一支列守卫,而不是换掉这张表的写策略】finance_settings 是【一行、两个主人】:
-- 财务要直连写 locked_before(/finance/settings 的手动锁),CFO 要写其余各列。CFO 不持
-- module.finance.edit,所以写策略不能换成 action.finance_settings(那会把财务的锁拿走);
-- 也不能保持原样放任(那会让财务照旧改 GST 登记)。于是:写策略不动,
-- 【直连写】改到锁期与审批四列以外的任何一列 → 按名拒,那些列只走 set_finance_settings
-- (SECURITY DEFINER,要 action.finance_settings)。
--
-- 【判据写成"除了这几列,其余全归 CFO"】而不是列一份 CFO 的列清单:哪一天这张表多一列,
-- 它默认落在 CFO 那一边 —— 多一列设置而没有人想过它归谁,错在安全的那一边。
-- 审批四列在这里放行,是因为它们有自己的守卫(guard_approvals_policy_write),不是因为
-- 它们归财务;updated_at / updated_by 是盖章,不是设置。
--
-- 【INSERT 一律拒】这张表是单行表(id boolean CHECK (id)),那一行在建库时就在;
-- 客户端再插一行只可能是绕路。
--
-- 【为什么是 INVOKER】与 guard_lock_reopen_path、enforce_write_permission 同一个理由:
-- 要分出"直连写"(row_security_active = true)与属主路径(set_finance_settings、
-- set_approvals_policy、close_period 都是 SECURITY DEFINER,各自已经要过自己的码)。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_finance_settings_cfo_columns()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_col text;
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        RAISE EXCEPTION 'FINANCE_SETTINGS_THROUGH_FUNCTION_ONLY|insert';
    END IF;

    SELECT n.key INTO v_col
      FROM jsonb_each(to_jsonb(NEW)) n
      JOIN jsonb_each(to_jsonb(OLD)) o ON o.key = n.key
     WHERE n.key NOT IN ('locked_before', 'updated_at', 'updated_by',
                         'approval_level1_role_code', 'approval_level2_role_code',
                         'approval_threshold_base', 'approvals_enabled')
       AND n.value IS DISTINCT FROM o.value
     ORDER BY n.key
     LIMIT 1;
    IF v_col IS NOT NULL THEN
        RAISE EXCEPTION 'FINANCE_SETTINGS_THROUGH_FUNCTION_ONLY|%', v_col;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_finance_settings_cfo_columns() IS
'ROLE-1 Batch 2a:一次直连写(row_security_active)若改到 finance_settings 上锁期(locked_before)与审批四列以外的任何一列,或直连 INSERT,按名拒 FINANCE_SETTINGS_THROUGH_FUNCTION_ONLY|<列> —— 那些列只走 set_finance_settings(action.finance_settings,CFO)。判据写成"除了这几列",所以将来新加的列默认归 CFO。INVOKER,以分出直连写与属主路径。';

-- db/functions/set_finance_settings.sql
-- ROLE-1 · Batch 2a(Tim 的矩阵 §12,Batch 2 grilling Q10):财务设置【只归 CFO】的唯一写入口。
--
-- 【为什么要一支函数】CFO 不持任何 .edit 码,所以 finance_settings 的写策略
-- (module.finance.edit)会把他挡在外面;而那条策略不能换 —— 锁期仍归财务。
-- 于是 CFO 那几列走这里(SECURITY DEFINER,要 action.finance_settings),
-- 直连写那几列由 guard_finance_settings_cfo_columns 按名拒。
--
-- 【参数是一份 jsonb,只写出现了的键】今天界面上只有 GST 那一块(Q10:不加新屏),
-- 但这支函数管的是 CFO 那一边的【每一列】:
--     gst_registered · gst_registration_no · gst_rate_pct · system_start_date
--     fy_end_month · fy_end_day · first_fy_end · default_allocation_basis
-- 只 SET 出现了的键:BEFORE UPDATE OF gst_registered, gst_registration_no 的
-- trg_gst_switch 只在那两列真的出现在 SET 里时才触发,不让一次改会计年度的写
-- 去惊动 GST 的业务守卫。
--   · 锁期与审批四列【不在这里】→ FINANCE_SETTINGS_KEY_NOT_HERE|<键>(各有自己的门:
--     手动锁 / close_period / reopen_period;set_approvals_policy)。
--   · 不认识的键 → FINANCE_SETTINGS_KEY_UNKNOWN|<键>;一个空对象 → FINANCE_SETTINGS_NOTHING_TO_CHANGE。
--   · 取值的类型与约束由 jsonb_populate_record 与表自己的 CHECK 把关(一份定义)。
--
-- 【它不绕过任何业务守卫】guard_gst_switch(注销 GST 时有已带税码的单据 → 拒)、
-- guard_finance_settings_sod 都照常触发:SECURITY DEFINER 只跳过【谁可以写】那一层
-- (RLS 与 enforce_write_permission),不跳过【能不能这样写】那一层。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.set_finance_settings(p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_allowed text[] := ARRAY['gst_registered', 'gst_registration_no', 'gst_rate_pct',
                              'system_start_date', 'fy_end_month', 'fy_end_day',
                              'first_fy_end', 'default_allocation_basis'];
    v_elsewhere text[] := ARRAY['locked_before', 'approval_level1_role_code',
                                'approval_level2_role_code', 'approval_threshold_base',
                                'approvals_enabled'];
    v_key  text;
    v_row  finance_settings%ROWTYPE;
    v_new  finance_settings%ROWTYPE;
    v_set  text;
BEGIN
    PERFORM require_permission('action.finance_settings');

    IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' OR p_changes = '{}'::jsonb THEN
        RAISE EXCEPTION 'FINANCE_SETTINGS_NOTHING_TO_CHANGE';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_changes) ORDER BY 1 LOOP
        IF v_key = ANY (v_elsewhere) THEN
            RAISE EXCEPTION 'FINANCE_SETTINGS_KEY_NOT_HERE|%', v_key;
        END IF;
        IF NOT (v_key = ANY (v_allowed)) THEN
            RAISE EXCEPTION 'FINANCE_SETTINGS_KEY_UNKNOWN|%', v_key;
        END IF;
    END LOOP;

    SELECT * INTO v_row FROM finance_settings WHERE id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FINANCE_SETTINGS_ROW_MISSING';
    END IF;
    v_new := jsonb_populate_record(v_row, p_changes);

    SELECT string_agg(format('%I = ($1).%I', k, k), ', ' ORDER BY k) INTO v_set
      FROM jsonb_object_keys(p_changes) k;
    EXECUTE format('UPDATE finance_settings SET %s, updated_by = $2 WHERE id', v_set)
      USING v_new, auth.uid();

    SELECT * INTO v_new FROM finance_settings WHERE id;
    RETURN jsonb_build_object(
        'gst_registered', v_new.gst_registered,
        'gst_registration_no', v_new.gst_registration_no,
        'gst_rate_pct', v_new.gst_rate_pct,
        'system_start_date', v_new.system_start_date,
        'fy_end_month', v_new.fy_end_month,
        'fy_end_day', v_new.fy_end_day,
        'first_fy_end', v_new.first_fy_end,
        'default_allocation_basis', v_new.default_allocation_basis);
END;
$function$;

COMMENT ON FUNCTION public.set_finance_settings(jsonb) IS
'ROLE-1 Batch 2a:CFO 那一边的财务设置(GST 登记、系统起始日、会计年度、默认分摊基准)的唯一写入口。要 action.finance_settings。只 SET 出现了的键;锁期与审批四列按名拒(FINANCE_SETTINGS_KEY_NOT_HERE),它们各有自己的门。业务守卫(guard_gst_switch 等)照常触发。';

-- db/functions/guard_customer_credit_write.sql
-- ROLE-1 · Batch 2a(Tim 的矩阵 §10,Batch 2 grilling Q11):**客户信用限额与冻结只归 CFO**。
--
-- 【形状】与 guard_employee_salary_write(ROLE-1 Batch 1)同一个:customers 这张表别的列
-- 仍归 module.customers.edit(cco / cto / finance),只有 credit_limit_base 与 credit_hold
-- 换主人。一张表两个主人,所以不换写策略,而是一支列守卫:
--   · 直连 INSERT 带着一个限额(非 NULL)或 credit_hold = true → 拒;
--   · 直连 UPDATE 改动两列之一(IS DISTINCT FROM)→ 拒;
--   · 原样写回(客户编辑表单保存时两列没动)→ 放行 —— 拒绝的是【改动】,不是【提到】。
-- 两列都只走 set_customer_credit(SECURITY DEFINER,要 action.customer_credit)。
--
-- 【批量导入不在这里挡】master_import_apply 是属主路径,row_security_active = false,
-- 这支守卫看不见它 —— 所以两列加进了 master_import_forbidden_columns(与月薪同一个理由)。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径;理由见 guard_lock_reopen_path 的抬头。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_customer_credit_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.credit_limit_base IS NOT NULL OR NEW.credit_hold THEN
            RAISE EXCEPTION 'CUSTOMER_CREDIT_THROUGH_FUNCTION_ONLY';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.credit_limit_base IS DISTINCT FROM OLD.credit_limit_base
       OR NEW.credit_hold IS DISTINCT FROM OLD.credit_hold THEN
        RAISE EXCEPTION 'CUSTOMER_CREDIT_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_customer_credit_write() IS
'ROLE-1 Batch 2a:直连写(row_security_active)改动 customers.credit_limit_base / credit_hold,或直连 INSERT 带着限额或冻结,按名拒 CUSTOMER_CREDIT_THROUGH_FUNCTION_ONLY —— 两列只走 set_customer_credit(action.customer_credit,CFO)。原样写回放行。INVOKER,以分出直连写与属主路径。';

-- db/functions/set_customer_credit.sql
-- ROLE-1 · Batch 2a(Tim 的矩阵 §10,Batch 2 grilling Q11):客户信用限额与冻结的唯一写入口 —— CFO 一个。
--
-- 【为什么要一支函数】CFO 不持 module.customers.edit,customers 的写策略会把他挡在外面;
-- 而那条策略不能换(客户别的列仍归 cco / cto / finance)。于是两列走这里
-- (SECURITY DEFINER,要 action.customer_credit),直连改它们由 guard_customer_credit_write 按名拒。
--
-- 【两个参数都要给】限额 NULL = 没设限额(放行),0 = 现款现货 —— 两个都正当,而且相反
-- (SAL-B 的列注释)。所以 NULL 在这里是一个【值】,不是"不改";冻结不许 NULL
-- (列本身 NOT NULL)→ CUSTOMER_CREDIT_HOLD_REQUIRED。负数 → CUSTOMER_CREDIT_LIMIT_INVALID
-- (表上的 CHECK 也会拒,这里先按名说出来)。
--
-- 【留痕不用这里写】trg_customers_credit_history(BEFORE UPDATE OF 两列)照常写
-- customer_credit_history,changed_by = auth.uid() —— 属主路径里 auth.uid() 仍是按下去的那个人。
-- 两列都没变 → 不写(不留一行"改成了原样"的痕),返回 changed = false。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.set_customer_credit(p_customer_id uuid, p_credit_limit_base numeric, p_credit_hold boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c customers%ROWTYPE;
BEGIN
    PERFORM require_permission('action.customer_credit');

    IF p_credit_hold IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_CREDIT_HOLD_REQUIRED';
    END IF;
    IF p_credit_limit_base IS NOT NULL AND p_credit_limit_base < 0 THEN
        RAISE EXCEPTION 'CUSTOMER_CREDIT_LIMIT_INVALID|%', p_credit_limit_base;
    END IF;

    SELECT * INTO v_c FROM customers WHERE id = p_customer_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;

    IF v_c.credit_limit_base IS NOT DISTINCT FROM p_credit_limit_base
       AND v_c.credit_hold IS NOT DISTINCT FROM p_credit_hold THEN
        RETURN jsonb_build_object('code', v_c.code, 'changed', false,
                                  'credit_limit_base', v_c.credit_limit_base, 'credit_hold', v_c.credit_hold);
    END IF;

    UPDATE customers
       SET credit_limit_base = p_credit_limit_base,
           credit_hold = p_credit_hold,
           updated_by = auth.uid()
     WHERE id = p_customer_id;

    RETURN jsonb_build_object('code', v_c.code, 'changed', true,
                              'credit_limit_base', p_credit_limit_base, 'credit_hold', p_credit_hold);
END;
$function$;

COMMENT ON FUNCTION public.set_customer_credit(uuid, numeric, boolean) IS
'ROLE-1 Batch 2a:客户信用限额与冻结的唯一写入口,要 action.customer_credit(CFO)。限额 NULL = 不设限(是一个值,不是"不改");冻结必填。留痕由 trg_customers_credit_history 照常写。';

-- ─── master_import_forbidden_columns
CREATE OR REPLACE FUNCTION public.master_import_forbidden_columns()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT ARRAY[
        'id',                       -- 主键由库生成
        'created_at','updated_at','created_by','updated_by',   -- 审计,由库盖章
        'deleted_at','deleted_by','deletion_reason','owner_id',
        'user_id',                  -- 员工 ↔ 登录账号的关联走 set_user_employee_link
                                    -- (LINK-1 那条"两扇门两套规矩"还没裁,不在这里开第三扇)
        'status',                   -- suppliers.status 由 validate_supplier_status_transition 管
                                    -- 跳转规则;导入直接落一个状态会绕过那条规矩
        'default_payment_term_template_id', -- 指向 payment_term_templates,本刀范围外
        'monthly_salary',           -- ROLE-1(Tim 的矩阵):月薪只走 set_initial_salary(第一份)
                                    -- 与绩效评估 / 调薪申请。master_import_apply 是属主路径,
                                    -- guard_employee_salary_write 看不见它 —— 不在这里挡,
                                    -- 一份员工 CSV 就能绕过整条规矩。
        'credit_limit_base','credit_hold', -- ROLE-1 Batch 2a(Q11):客户信用只走 set_customer_credit
                                    -- (CFO)。同一个理由:导入是属主路径,guard_customer_credit_write 看不见它。
        'approved_by','approved_at' -- ROLE-1 Batch 2a:供应商的批准戳只由 set_supplier_status 盖
    ];
$function$;

-- ─── validate_supplier_status_transition(改体:读 supplier_status_moves();批准盖戳、回草稿清戳)
CREATE OR REPLACE FUNCTION public.validate_supplier_status_transition()
RETURNS trigger LANGUAGE plpgsql
-- SILENT-1(2026-09-08):补上 search_path。这支函数是全库少数没有它的一支;
-- 改到了就补,不静默留着。
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  -- INSERT 时不检查(直连 INSERT 必须是 draft 由 guard_supplier_direct_write 管)
  IF TG_OP = 'INSERT' THEN
    RETURN NEW;
  END IF;

  -- 状态没变,不检查
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- ROLE-1 Batch 2a:合法跳转读 supplier_status_moves() —— 与 set_supplier_status、
  -- 状态面板读的是同一张表(此前这里写着一份、页面上另抄一份)。跳转图一步没改。
  IF NOT EXISTS (SELECT 1 FROM supplier_status_moves() m
                  WHERE m.from_status = OLD.status::text AND m.to_status = NEW.status::text) THEN
    RAISE EXCEPTION 'INVALID_STATUS_TRANSITION|%|%', OLD.status, NEW.status;
  END IF;

  -- ROLE-1 Batch 2a(Q4):批准时盖戳;回到草稿时清空 —— 戳永远说的是此刻生效的那一次批准。
  IF NEW.status = 'approved' THEN
    NEW.approved_by := auth.uid();
    NEW.approved_at := now();
  ELSIF NEW.status = 'draft' THEN
    NEW.approved_by := NULL;
    NEW.approved_at := NULL;
  END IF;

  RETURN NEW;
END;
$function$;


-- ── 4 · 供应商状态变动史(Q3)──────────────────────────────────────────────
CREATE TABLE public.supplier_status_history (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id  uuid NOT NULL REFERENCES public.suppliers (id),
    -- text,不是 supplier_status:重放时本文件可能先于 suppliers.sql(枚举在那里建)。
    -- 取值由写它的唯一入口(trg_suppliers_status_history)从枚举列抄来。
    from_status  text NOT NULL,
    to_status    text NOT NULL,
    changed_at   timestamptz NOT NULL DEFAULT now(),
    changed_by   uuid,
    note         text
);

CREATE INDEX idx_supplier_status_history_supplier
    ON public.supplier_status_history (supplier_id, changed_at DESC);

COMMENT ON TABLE public.supplier_status_history IS
    'ROLE-1 Batch 2a:供应商状态的只增不改变动史,每一步一行(拉黑与恢复也在内)。写入口只有 suppliers 上的 trg_suppliers_status_history;approval_log 另记送审 / 批准 / 驳回。触发器之前的变动没有行:空白好过编造。';

-- 写入触发器挂在 suppliers 上,镜像也在 db/tables/suppliers.sql(表在哪触发器在哪)

-- 守卫函数体在 db/functions/guard_supplier_status_history_append_only.sql
CREATE TRIGGER trg_supplier_status_history_append_only
    BEFORE UPDATE OR DELETE ON public.supplier_status_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_supplier_status_history_append_only();

ALTER TABLE public.supplier_status_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "supplier_status_history select by permission"
    ON public.supplier_status_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'::text));
-- 【没有 INSERT / UPDATE / DELETE 策略】唯一写入口是触发器(属主身份)—— 留痕不该有第二个写法。

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.supplier_status_history FROM anon;

-- ── 5 · 新触发器 ─────────────────────────────────────────────────────────────
CREATE TRIGGER trg_suppliers_direct_write
    BEFORE INSERT OR UPDATE ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION public.guard_supplier_direct_write();

CREATE TRIGGER trg_suppliers_status_history
    AFTER UPDATE OF status ON public.suppliers
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION public.log_supplier_status_change();

CREATE TRIGGER trg_customers_credit_write
    BEFORE INSERT OR UPDATE ON public.customers
    FOR EACH ROW EXECUTE FUNCTION public.guard_customer_credit_write();

CREATE TRIGGER trg_finance_settings_cfo_columns
    BEFORE INSERT OR UPDATE ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION public.guard_finance_settings_cfo_columns();

CREATE TRIGGER trg_purchase_orders_supplier_approved
    BEFORE INSERT ON public.purchase_orders
    FOR EACH ROW EXECUTE FUNCTION public.guard_po_supplier_approved();

-- ── 6 · 科目表 / 币种 / 公司资料:写权换到 action.finance_settings(Q10)──────
ALTER POLICY "accounts insert by permission" ON public.accounts WITH CHECK (has_permission('action.finance_settings'::text));
ALTER POLICY "accounts update by permission" ON public.accounts USING (has_permission('action.finance_settings'::text)) WITH CHECK (has_permission('action.finance_settings'::text));
ALTER POLICY "accounts delete by permission" ON public.accounts USING (has_permission('action.finance_settings'::text));
DROP TRIGGER enforce_write_permission ON public.accounts;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.accounts
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.finance_settings');

ALTER POLICY "currencies insert by permission" ON public.currencies WITH CHECK (has_permission('action.finance_settings'::text));
ALTER POLICY "currencies update by permission" ON public.currencies USING (has_permission('action.finance_settings'::text)) WITH CHECK (has_permission('action.finance_settings'::text));
ALTER POLICY "currencies delete by permission" ON public.currencies USING (has_permission('action.finance_settings'::text));
DROP TRIGGER enforce_write_permission ON public.currencies;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.currencies
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.finance_settings');

ALTER POLICY "company_profile insert by permission" ON public.company_profile WITH CHECK (has_permission('action.finance_settings'::text));
ALTER POLICY "company_profile update by permission" ON public.company_profile USING (has_permission('action.finance_settings'::text)) WITH CHECK (has_permission('action.finance_settings'::text));
ALTER POLICY "company_profile delete by permission" ON public.company_profile USING (has_permission('action.finance_settings'::text));
DROP TRIGGER enforce_write_permission ON public.company_profile;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.company_profile
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.finance_settings');

-- ── 7 · approval_log:枚举 + 读策略(加 'supplier';读的那一支漏掉就是"写得进、读不出")──
ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;
ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check
    CHECK (subject_type IN (
                            'leave_request', 'medical_claim', 'performance_review',
                            'purchase_order', 'payment', 'expense',
                            'pricing_formula', 'stocktake',
                            -- ★ APR-3:报销单。它是【唯一一个形状就是审批、却漏在
                            -- 这份枚举外】的单据(APR-0 §3.1 量出来的),而它自己的
                            -- status 就是审批态(submitted/withdrawn/approved/rejected)。
                            -- 加一个取值要动四处,而其中只有【读策略那一支】漏掉了
                            -- 不会有任何东西变红 —— 见本文件末尾那条策略里的同名分支。
                            'expense_claim',
                            -- WO-1b:工单。可审批的动作是【放行】—— 不是新建
                            -- (草稿谁都可以写),也不是收工(那是事后记录)。
                            'work_order',
                            -- PAY-REQ-1:付款申请(出款与冲销付款)—— CFO 批每一张。
                            -- 'payment' 那一格是 APR-1 预留的,从来没有路径写它;
                            -- 被批的是【申请】,不是付款行(付款行生下来就已经过账)。
                            'payment_request',
                            -- ROLE-1 Batch 2a(Q3 / Q9):供应商的送审、批准、驳回 —— CFO 批。
                            -- 【不是审批引擎的一条链】:没有金额、没有档位,审批开关不关它。
                            'supplier'));
ALTER POLICY "approval_log select by permission" ON public.approval_log
    USING (
        CASE subject_type
            WHEN 'leave_request'      THEN has_permission('module.hr.view'::text)
            WHEN 'medical_claim'      THEN has_permission('module.hr.view'::text)
            WHEN 'performance_review' THEN has_permission('module.hr.view'::text)
            WHEN 'purchase_order'     THEN has_permission('module.purchasing.view'::text)
            WHEN 'payment'            THEN has_permission('module.finance.view'::text)
            WHEN 'expense'            THEN has_permission('module.finance.view'::text)
            -- ★★ APR-3:报销单那一支 —— 这是 APR-0 §3.2 点名的第 ④ 格,
            --   也是四格里【唯一一个漏掉也不会有任何东西变红】的那一格:
            --   写得进、读不出,对每一个人都是 0 行,而且不报错。
            --   WO-1b 正是在这一格上漏了一次(APR0-WORK-ORDER-APPROVALS-INVISIBLE)。
            --   取的码与 expense_claims 自己的读策略同源(module.finance.view)——
            --   ⚠ 照直说:那张表的策略还有【或者这张单说的就是你】那一条腿,
            --   而留痕这一支【没有】给员工本人开口子。理由:一行留痕会说出
            --   "谁批的、什么级别",那是内控记录,不是自助查询;员工在 /me 上
            --   看得见自己那张单的状态,那条路没有变。
            WHEN 'expense_claim'      THEN has_permission('module.finance.view'::text)
            WHEN 'pricing_formula'    THEN has_permission('module.pricing.view'::text)
            WHEN 'stocktake'          THEN has_permission('module.stocktakes.view'::text)
            -- ★ APR-1:WO-1b 漏掉的那一支(APR0-WORK-ORDER-APPROVALS-INVISIBLE)。
            --   它写得进、读不出:线上有 1 行 work_order 留痕,而任何 authenticated
            --   身份读到的都是 0 行【而且不报错】—— 一片正确的空白,与"这张工单
            --   还没有被放行过"在屏幕上逐字相同。
            --   取的码与 work_orders 自己的读策略【同一个】:读工单的判据只该有一份定义。
            --   ⚠ 照直说:cfo 不持 module.processing.view,所以二级审批人仍然读不到它。
            WHEN 'work_order'         THEN has_permission('module.processing.view'::text)
            -- ★ PAY-REQ-1:付款申请那一支 —— 与 payment_requests 自己的读策略同一个码。
            --   漏掉它,写得进、读不出、不报错(APR-3 在报销单上记过的那一格)。
            WHEN 'payment_request'    THEN has_permission('module.finance.view'::text)
            -- ★ ROLE-1 Batch 2a:供应商那一支 —— 与 suppliers 自己的读策略同一个码。
            --   漏掉它,写得进、读不出、不报错(APR-3 记过的那一格)。
            WHEN 'supplier'           THEN has_permission('module.suppliers.view'::text)
            ELSE false
        END
    );

-- ── 8 · operations_now:加一支 supplier_pending_approval(Q9)──────────────
CREATE OR REPLACE VIEW public.operations_now AS
 SELECT item_type,
    permission,
    arm_permission_any(item_type) AS permission_any,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM ( SELECT 'awaiting_assay'::text AS item_type,
            'module.inbound.view'::text AS permission,
            g.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            g.batch_code AS item_code,
            array_to_string(g.missing_metals, ', '::text) AS subject,
            g.arrival_date AS item_date
           FROM batch_required_assay_gaps g
          WHERE g.sampleable
        UNION ALL
         SELECT 'assay_unapplied'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.latest_assay_code AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.has_unapplied_assay
        UNION ALL
         SELECT 'batch_unpriced'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.pricing_status = 'unpriced'::text
        UNION ALL
         SELECT 'allocation_stale'::text AS item_type,
            'module.processing.view'::text AS permission,
            s.run_id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            NULL::text AS subject,
            s.last_cost_change::date AS item_date
           FROM processing_run_allocation_status s
          WHERE s.is_stale OR s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL
        UNION ALL
         SELECT 'po_awaiting_receipt'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.id AS item_id,
            NULL::text AS doc_kind,
            po.code AS item_code,
            po.status AS subject,
            po.order_date AS item_date
           FROM purchase_orders po
          WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
        UNION ALL
         SELECT 'stocktake_open'::text AS item_type,
            'module.stocktakes.view'::text AS permission,
            st.id AS item_id,
            NULL::text AS doc_kind,
            st.code AS item_code,
            NULL::text AS subject,
            st.started_at::date AS item_date
           FROM stocktakes st
          WHERE st.deleted_at IS NULL AND st.status = 'open'::text
        UNION ALL
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_1.id AS item_id,
            NULL::text AS doc_kind,
            s_1.code AS item_code,
            (ct.name_en || ' — '::text) || s_1.legal_name AS subject,
            sc.valid_until AS item_date
           FROM supplier_compliance sc
             JOIN certificate_types ct ON ct.code = sc.cert_type_code
             JOIN suppliers s_1 ON s_1.id = sc.supplier_id
          WHERE sc.deleted_at IS NULL AND s_1.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND sc.valid_until IS NOT NULL AND sc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'qualification_missing'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_2.id AS item_id,
            NULL::text AS doc_kind,
            s_2.code AS item_code,
            s_2.legal_name AS subject,
            s_2.created_at::date AS item_date
           FROM suppliers s_2
          WHERE s_2.deleted_at IS NULL AND s_2.supplies_goods AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
                   FROM supplier_compliance sc2
                  WHERE sc2.supplier_id = s_2.id AND sc2.deleted_at IS NULL))
        UNION ALL
         SELECT 'credit_over_limit'::text AS item_type,
            'module.customers.view'::text AS permission,
            c_1.id AS item_id,
            NULL::text AS doc_kind,
            c_1.code AS item_code,
            c_1.legal_name AS subject,
            COALESCE(( SELECT min(sr.sale_date) AS min
                   FROM sales_records sr
                  WHERE sr.customer_id = c_1.id), CURRENT_DATE) AS item_date
           FROM customers c_1
          WHERE c_1.deleted_at IS NULL AND c_1.credit_limit_base IS NOT NULL AND customer_ar_exposure_visible(c_1.id) >= c_1.credit_limit_base
        UNION ALL
         SELECT 'output_unsold_aging'::text AS item_type,
            'module.output.view'::text AS permission,
            ob.id AS item_id,
            NULL::text AS doc_kind,
            ob.code AS item_code,
            ob.state AS subject,
            COALESCE(ob.output_date, ob.created_at::date) AS item_date
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0::numeric AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
        UNION ALL
         SELECT 'safety_stock_below'::text AS item_type,
            'module.inventory.view'::text AS permission,
            msa.material_id AS item_id,
            NULL::text AS doc_kind,
            msa.code AS item_code,
            (((((trim_scale(msa.available_qty)::text || ' / '::text) || trim_scale(msa.safety_stock_qty)::text) || ' '::text) || COALESCE(msa.unit, ''::text)) || ' — short '::text) || trim_scale(msa.safety_stock_qty - msa.available_qty)::text AS subject,
            COALESCE(msa.last_movement_date, CURRENT_DATE) AS item_date
           FROM material_stock_available msa
          WHERE msa.safety_stock_qty IS NOT NULL AND msa.available_qty < msa.safety_stock_qty
        UNION ALL
         SELECT 'leave_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            lr.id AS item_id,
            NULL::text AS doc_kind,
            lr.code AS item_code,
            e.legal_name AS subject,
            lr.created_at::date AS item_date
           FROM leave_requests lr
             JOIN employees e ON e.id = lr.employee_id
          WHERE lr.status = 'pending'::text AND lr.deleted_at IS NULL
        UNION ALL
         SELECT 'claim_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            mc.id AS item_id,
            NULL::text AS doc_kind,
            mc.code AS item_code,
            e.legal_name AS subject,
            mc.created_at::date AS item_date
           FROM medical_claims mc
             JOIN employees e ON e.id = mc.employee_id
          WHERE mc.status = 'submitted'::text AND mc.deleted_at IS NULL
        UNION ALL
         SELECT 'review_submitted'::text AS item_type,
            'module.hr.view'::text AS permission,
            r.id AS item_id,
            NULL::text AS doc_kind,
            e.code AS item_code,
            e.legal_name AS subject,
            COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
          WHERE r.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            i.invoice_id AS item_id,
            NULL::text AS doc_kind,
            i.code AS item_code,
            i.customer_name AS subject,
            i.due_date AS item_date
           FROM invoice_status i
          WHERE i.overdue
        UNION ALL
         SELECT 'ar_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            COALESCE(ar.sales_record_id, ar.invoice_id) AS item_id,
            ar.doc_kind,
            ar.doc_code AS item_code,
            ar.customer_name AS subject,
            ar.sale_date AS item_date
           FROM ar_open_items ar
          WHERE ar.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'ap_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ap.doc_id AS item_id,
            ap.doc_kind,
            ap.doc_code AS item_code,
            ap.supplier_name AS subject,
            ap.doc_date AS item_date
           FROM ap_open_items ap
          WHERE ap.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'fx_rate_gap'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            g.currency AS item_code,
            array_to_string(g.missing_types, ', '::text) AS subject,
            g.rate_date AS item_date
           FROM fx_rate_gaps g
          WHERE g.rate_date >= (CURRENT_DATE - 45)
        UNION ALL
         SELECT 'bank_unmatched'::text AS item_type,
            'module.finance.view'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.bank_account_code AS item_code,
            s.code AS subject,
            l.line_date AS item_date
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE l.match_status = 'unmatched'::text AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'margin_cost_not_allocated'::text AS item_type,
            'data.view_prices'::text AS permission,
            bm.run_id AS item_id,
            NULL::text AS doc_kind,
            bm.batch_code AS item_code,
            bm.material_name AS subject,
            ob.output_date AS item_date
           FROM batch_margin bm
             JOIN output_batches ob ON ob.id = bm.output_batch_id
          WHERE bm.margin_status = 'no_unit_cost'::text
        UNION ALL
         SELECT 'metal_quote_stale'::text AS item_type,
            'module.pricing.view'::text AS permission,
            mp.latest_id AS item_id,
            NULL::text AS doc_kind,
            mp.metal AS item_code,
            mp.latest_price::text AS subject,
            mp.max_date AS item_date
           FROM ( SELECT p.metal,
                    max(p.price_date) AS max_date,
                    (array_agg(p.id ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_id,
                    (array_agg(p.price_usd_per_tonne ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_price
                   FROM metal_prices p
                  WHERE p.deleted_at IS NULL
                  GROUP BY p.metal) mp
          WHERE (CURRENT_DATE - mp.max_date) > (( SELECT ps.metal_quote_stale_days
                   FROM pricing_settings ps
                 LIMIT 1))
        UNION ALL
         SELECT 'orders_unfulfilled'::text AS item_type,
            'module.sales.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            so.status AS subject,
            so.order_date AS item_date
           FROM sales_orders so
          WHERE so.deleted_at IS NULL AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
        UNION ALL
         SELECT 'work_order_overdue'::text AS item_type,
            'module.processing.view'::text AS permission,
            w.id AS item_id,
            NULL::text AS doc_kind,
            w.code AS item_code,
            w.scheduled_date::text AS subject,
            w.scheduled_date AS item_date
           FROM work_orders w
          WHERE w.status = 'released'::text AND w.scheduled_date IS NOT NULL AND w.scheduled_date < CURRENT_DATE
        UNION ALL
         SELECT 'work_order_variance_beyond'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.work_order_id AS item_id,
            NULL::text AS doc_kind,
            f.work_order_code AS item_code,
                CASE
                    WHEN f.side = 'input'::text THEN (((('input overrun · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                    ELSE (((('output shortfall · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                END AS subject,
            COALESCE(w2.scheduled_date, w2.created_at::date) AS item_date
           FROM work_order_fulfilment f
             JOIN work_orders w2 ON w2.id = f.work_order_id
          WHERE f.has_plan AND f.planned_or_expected_qty > 0::numeric AND (f.side = 'input'::text AND (w2.status = ANY (ARRAY['released'::text, 'closed'::text])) AND f.actual_qty > (f.planned_or_expected_qty * (1::numeric + (( SELECT ps.wo_input_overrun_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)) OR f.side = 'output'::text AND w2.status = 'closed'::text AND f.actual_qty < (f.planned_or_expected_qty * (1::numeric - (( SELECT ps.wo_output_shortfall_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)))
        UNION ALL
         SELECT 'free_time_expiring'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            ((((q.free_days - (CURRENT_DATE - arr.event_date))::text) || ' left of '::text) || q.free_days::text) || COALESCE(' — '::text || f.legal_name, ''::text) AS subject,
            arr.event_date AS item_date
           FROM containers c
             LEFT JOIN suppliers f ON f.id = c.forwarder_id
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'arrived'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) arr ON true
             JOIN forwarder_rate_quotes q ON q.supplier_id = c.forwarder_id AND q.lane_id = c.lane_id AND q.deleted_at IS NULL AND c.departure_date >= q.valid_from AND c.departure_date <= q.valid_to
          WHERE c.deleted_at IS NULL AND q.free_days IS NOT NULL AND (q.free_days - (CURRENT_DATE - arr.event_date)) <= 2
        UNION ALL
         SELECT 'container_no_arrival'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            dep.event_date::text AS subject,
            dep.event_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'departed'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) dep ON true
          WHERE c.deleted_at IS NULL AND (CURRENT_DATE - dep.event_date) >= 14 AND NOT (EXISTS ( SELECT 1
                   FROM container_milestones m2
                  WHERE m2.container_id = c.id AND m2.milestone = 'arrived'::text))
        UNION ALL
         SELECT 'container_eta_overdue'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            c.expected_arrival_date::text AS subject,
            c.expected_arrival_date AS item_date
           FROM containers c
          WHERE c.deleted_at IS NULL AND c.expected_arrival_date IS NOT NULL AND c.expected_arrival_date < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
                   FROM container_milestones m3
                  WHERE m3.container_id = c.id AND m3.milestone = 'arrived'::text))
        UNION ALL
         SELECT 'container_documents_late'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            p.n::text || ' pending'::text AS subject,
            c.departure_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT count(*) AS n
                   FROM container_documents d
                  WHERE d.container_id = c.id AND d.status = 'pending'::text) p ON true
          WHERE c.deleted_at IS NULL AND p.n > 0 AND (CURRENT_DATE - c.departure_date) >= 7
        UNION ALL
         SELECT 'equipment_service_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess.equipment_code AS item_code,
            (ess.service_kind || ' — '::text) || ess.equipment_description AS subject,
            ess.baseline_date AS item_date
           FROM equipment_service_status ess
          WHERE ess.monitored AND ess.disposition = 'warn'::text AND ess.equipment_status <> 'disposed'::text AND ess.is_due
        UNION ALL
         SELECT 'equipment_service_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess_1.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess_1.equipment_code AS item_code,
            (ess_1.service_kind || ' — '::text) || ess_1.equipment_description AS subject,
            ess_1.baseline_date AS item_date
           FROM equipment_service_status ess_1
          WHERE ess_1.monitored AND ess_1.disposition = 'warn'::text AND ess_1.equipment_status <> 'disposed'::text AND ess_1.is_approaching
        UNION ALL
         SELECT 'promise_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            ps.promise_id AS item_id,
            NULL::text AS doc_kind,
            ps.chase_code AS item_code,
            ps.customer_name AS subject,
            ps.promised_date AS item_date
           FROM collection_promise_status ps
          WHERE ps.is_overdue
        UNION ALL
         SELECT 'wht_due'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            to_char(w.period_month::timestamp without time zone, 'YYYY-MM'::text) AS item_code,
            (to_char(w.unremitted_base, 'FM999G999G990D00'::text) || ' '::text) || (( SELECT c.code
                   FROM currencies c
                  WHERE c.is_base)) AS subject,
            w.due_date AS item_date
           FROM wht_liability_by_month w
          WHERE w.unremitted_base > 0::numeric AND (w.due_date - CURRENT_DATE) <= 7
        UNION ALL
         SELECT 'company_licence_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            cc.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(cc.cert_no, ct.code) AS item_code,
            ct.name_en AS subject,
            cc.valid_until AS item_date
           FROM company_compliance cc
             JOIN certificate_types ct ON ct.code = cc.cert_type_code
          WHERE cc.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND cc.valid_until IS NOT NULL AND cc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'import_permit_unverified'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            ib.code AS item_code,
            s.legal_name AS subject,
            ib.arrival_date AS item_date
           FROM inbound_batches ib
             JOIN suppliers s ON s.id = ib.supplier_id
          WHERE ib.deleted_at IS NULL AND ib.imported IS TRUE AND ib.import_permit_verified_at IS NULL
        UNION ALL
         SELECT 'payment_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            pr.id AS item_id,
            NULL::text AS doc_kind,
            pr.code AS item_code,
            COALESCE(s.legal_name, e.legal_name, c.legal_name) AS subject,
            pr.created_at::date AS item_date
           FROM payment_requests pr
             LEFT JOIN suppliers s ON s.id = pr.supplier_id
             LEFT JOIN employees e ON e.id = pr.employee_id
             LEFT JOIN customers c ON c.id = pr.customer_id
          WHERE pr.status = 'submitted'::text
        UNION ALL
         SELECT 'supplier_pending_approval'::text AS item_type,
            'action.supplier_approve'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            s.legal_name AS subject,
            COALESCE(( SELECT max(h.changed_at) AS max
                   FROM supplier_status_history h
                  WHERE h.supplier_id = s.id AND h.to_status = 'pending_review'::text), s.updated_at)::date AS item_date
           FROM suppliers s
          WHERE s.status = 'pending_review'::supplier_status AND s.deleted_at IS NULL) a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type))) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));

-- ── 9 · company-assets 桶:写要 action.finance_settings,读不变 ─────────────────
-- 桶与它的策略【不在镜像里】(AGENTS.md「存储桶与它的策略不在镜像里」),所以它们只活在迁移里;
-- 行为的证明在 db/scripts/2026-09-24-role1b2a-live-proof.sql(对着线上、整支回滚)。
-- 读【不收】:发票 / 送货单 PDF 在生成时要读公司标志,生成它们的人不一定是 CFO。
-- UPDATE 两侧都写(UI-1d 的理由:只写 USING,一行可以被改名挪出这个判据)。
DROP POLICY "authenticated upload company-assets" ON storage.objects;
DROP POLICY "authenticated update company-assets" ON storage.objects;
DROP POLICY "authenticated delete company-assets" ON storage.objects;
CREATE POLICY "finance settings upload company-assets"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'company-assets' AND public.has_permission('action.finance_settings'));
CREATE POLICY "finance settings update company-assets"
    ON storage.objects FOR UPDATE TO authenticated
    USING (bucket_id = 'company-assets' AND public.has_permission('action.finance_settings'))
    WITH CHECK (bucket_id = 'company-assets' AND public.has_permission('action.finance_settings'));
CREATE POLICY "finance settings delete company-assets"
    ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'company-assets' AND public.has_permission('action.finance_settings'));

-- ── 10 · 授权(Q10 / Q11 / Q8 / Q5)─────────────────────────────────────────────
-- cfo:三件只归 CFO 的事。★ 不给 admin 角色(Tim 的指示)。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, c FROM roles r
 CROSS JOIN unnest(ARRAY['action.finance_settings', 'action.customer_credit', 'action.supplier_approve']) c
 WHERE r.code = 'cfo';
-- warehouse:建供应商档案(矩阵 §6)—— edit 蕴含 view。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, c FROM roles r
 CROSS JOIN unnest(ARRAY['module.suppliers.view', 'module.suppliers.edit']) c
 WHERE r.code = 'warehouse';

-- ── 11 · 每一张在途单据,有几个【不是它自己当事人】的人决定得了它 ──────────────
-- 零件与 ROLE-1 Batch 1 的自证逐字相同(按【人】数,Tim 的两个账号只算一个);本刀没有改动
-- 任何一支决定函数的门,所以用"之后"那一组门问。付款申请此刻为 0 张(前提已断言)。
CREATE FUNCTION pg_temp.b2a_pending_decider_check(p_after boolean DEFAULT true)
 RETURNS TABLE(k text, doc text, raiser text, subject text, deciders int, decider_names text)
 LANGUAGE sql STABLE
AS $f$
WITH fs AS (SELECT approval_level1_role_code AS l1, approval_level2_role_code AS l2 FROM public.finance_settings),
real_perm AS (
    SELECT DISTINCT rp.permission_code, rg.user_id
      FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     CROSS JOIN LATERAL public.real_role_grants(r.code) rg),
people AS (SELECT DISTINCT user_id FROM real_perm),
holds AS (SELECT user_id, array_agg(permission_code) AS codes FROM real_perm GROUP BY user_id),
items AS (
    -- 报销单:分档链,直接问 approval_deciders
    SELECT 'expense_claim'::text AS k, c.code::text AS doc, c.created_by AS raiser, c.employee_id AS subj,
           d.user_id AS u
      FROM public.expense_claims c CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim',
                 public.approval_level_for((SELECT b.amount_base FROM public.expense_claim_amount_base(c.id) b)),
                 c.created_by, c.employee_id, fs.l1, fs.l2) d ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- 采购单:分档链;金额档位按更严的二级问(一级的资格 ⊇ 二级,R1)
    SELECT 'purchase_order', p.code, p.created_by, NULL,
           d.user_id
      FROM public.purchase_orders p CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('purchase_order', 'approve_purchase_order', 2::smallint,
                 p.created_by, NULL, fs.l1, fs.l2) d ON true
     WHERE p.approval_status = 'pending' AND p.deleted_at IS NULL
    UNION ALL
    -- 请假:decide_leave_request 的门(之前 module.hr.edit,之后 action.decide_hr_requests)
    --       + 余额函数要 module.hr.view(或本人)+ 四眼(R2 之后覆盖请假)
    SELECT 'leave_request', l.code, l.created_by, l.employee_id, h.user_id
      FROM public.leave_requests l CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = l.employee_id)
                       AND (public.self_leg(l.created_by, l.employee_id, h.user_id) = 'none'
                            OR (p_after AND public.self_approval_exception('leave_request', l.employee_id, h.user_id, fs.l2)))
     WHERE l.status = 'pending' AND l.deleted_at IS NULL
    UNION ALL
    SELECT 'medical_claim_submitted', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = m.employee_id)
                       AND (public.self_leg(m.created_by, m.employee_id, h.user_id) = 'none'
                            OR public.self_approval_exception('medical_claim', m.employee_id, h.user_id, fs.l2))
     WHERE m.status = 'submitted' AND m.deleted_at IS NULL
    UNION ALL
    -- 已批未付的医疗申报:pay_medical_claim 只要 module.finance.edit,没有自付检查(量过,Tim 的矩阵允许)
    SELECT 'medical_claim_approved (pay)', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m
      LEFT JOIN holds h ON 'module.finance.edit' = ANY (h.codes)
     WHERE m.status = 'approved' AND m.deleted_at IS NULL
    UNION ALL
    SELECT 'performance_review', r.id::text, r.submitted_by, r.employee_id, h.user_id
      FROM public.performance_reviews r
      LEFT JOIN holds h ON (CASE WHEN p_after THEN public.review_approval_code(r.submitted_by, r.employee_id)
                                 ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND public.self_leg(r.submitted_by, r.employee_id, h.user_id) = 'none'
     WHERE r.status = 'submitted'
    UNION ALL
    SELECT 'work_order', w.code, w.created_by, NULL, h.user_id
      FROM public.work_orders w
      LEFT JOIN holds h ON 'module.processing.edit' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      LEFT JOIN holds h ON 'module.stocktakes.edit' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
     WHERE s.status = 'open' AND s.deleted_at IS NULL
)
SELECT i.k, i.doc,
       (SELECT email::text FROM auth.users WHERE id = i.raiser),
       (SELECT legal_name FROM public.employees WHERE id = i.subj),
       count(DISTINCT COALESCE(public.account_person(i.u)::text, i.u::text))::int,
       string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = i.u), ' ')
  FROM items i
 GROUP BY i.k, i.doc, i.raiser, i.subj
 ORDER BY 1, 2
$f$;

CREATE TEMP TABLE b2a_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved');

-- ── 12 · 自证:同一笔事务里,失败即整笔回滚 ────────────────────────────────────
DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权 = 之前 + 这五条,不多不少
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT
         SELECT role_code || ':' || permission_code FROM b2a_grants_before)
        EXCEPT
        SELECT unnest(ARRAY['cfo:action.finance_settings', 'cfo:action.customer_credit', 'cfo:action.supplier_approve',
                            'warehouse:module.suppliers.view', 'warehouse:module.suppliers.edit'])
    ) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B2A_PROOF|unexpected grant: %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM (
        SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
        EXCEPT SELECT role_code || ':' || permission_code FROM b2a_grants_before) d;
    IF v_n <> 5 THEN RAISE EXCEPTION 'ROLE1B2A_PROOF|expected 5 new grants, got %', v_n; END IF;
    SELECT string_agg(role_code || ':' || permission_code, ', ') INTO v_bad FROM (
        SELECT role_code, permission_code FROM b2a_grants_before
        EXCEPT SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B2A_PROOF|a grant disappeared: %', v_bad; END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                WHERE r.code = 'admin' AND rp.permission_code IN
                      ('action.finance_settings', 'action.customer_credit', 'action.supplier_approve')) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|admin role received a new code';
    END IF;

    -- ② edit 蕴含 view
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code LIKE 'module.%.edit'
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id
                        AND v.permission_code = replace(rp.permission_code, '.edit', '.view'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B2A_PROOF|edit without view: %', v_bad; END IF;

    -- ③ 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|approvals switched off';
    END IF;

    -- ④ 在途单据一张不少、一张不多;留痕一行没写;分录一张没多
    IF EXISTS ((SELECT b.k, b.id FROM b2a_pending_before b EXCEPT SELECT a.k, a.id FROM b2a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM b2a_pending_after a EXCEPT SELECT b.k, b.id FROM b2a_pending_before b)) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|a pending document changed state';
    END IF;
    IF (SELECT count(*) FROM approval_log) <> (SELECT n FROM b2a_log_before) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|approval_log changed';
    END IF;
    IF (SELECT count(*) FROM journal_entries) <> (SELECT n FROM b2a_je_before) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|journal_entries changed';
    END IF;

    -- ⑤ 供应商一家没变(Q6:本迁移不批准任何一家);没有一家带着批准戳;变动史 0 行
    IF EXISTS (SELECT 1 FROM suppliers s JOIN b2a_suppliers_before b ON b.id = s.id
                WHERE s.status::text <> b.status OR s.created_by IS DISTINCT FROM b.created_by
                   OR s.deleted_at IS DISTINCT FROM b.deleted_at)
       OR (SELECT count(*) FROM suppliers) <> (SELECT count(*) FROM b2a_suppliers_before) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|a supplier changed';
    END IF;
    IF EXISTS (SELECT 1 FROM suppliers WHERE approved_by IS NOT NULL OR approved_at IS NOT NULL) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|a supplier carries an approval stamp';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_status_history) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|supplier_status_history is not empty';
    END IF;

    -- ⑥ 客户信用一格没变
    IF EXISTS (SELECT 1 FROM customers c JOIN b2a_credit_before b ON b.id = c.id
                WHERE c.credit_limit_base IS DISTINCT FROM b.credit_limit_base
                   OR c.credit_hold IS DISTINCT FROM b.credit_hold) THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|a customer credit value changed';
    END IF;

    -- ⑦ 跳转图与 ROLE-1 之前触发器体里那一份逐条相同:18 步,CFO 四类 5 步
    IF (SELECT count(*) FROM supplier_status_moves()) <> 18
       OR (SELECT count(*) FROM supplier_status_moves() WHERE required_code = 'action.supplier_approve') <> 5 THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|supplier_status_moves is not the ruled map';
    END IF;

    -- ⑧ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.b2a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ROLE1B2A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.b2a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ROLE1B2A_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.b2a_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.b2a_pending_decider_check(boolean);

COMMIT;
