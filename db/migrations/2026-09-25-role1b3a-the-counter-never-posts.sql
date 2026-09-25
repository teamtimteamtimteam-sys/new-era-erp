-- db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql
-- ROLE-1 Batch 3a —— 盘点录数归仓库、过账归财务,录过数的人永远不能过账;四个登记的缺口关上。
-- 由 db/scripts/build_role1b3a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(ROLE-1 Batch 3 grilling,Tim 2026-09-25:Q2–Q5 · Q10–Q13 全部接受;Q13 拆刀,本刀是 3a)
--   ① 两个新码:action.stocktake_count(开单与录数)→ warehouse · admin;action.stocktake_post(过账)→ finance · admin。
--      module.stocktakes.edit 改义:只剩取消盘点(描述改写)。★ 两个新码都一并授给 admin(Tim 的常设裁定)。
--   ② stocktake_counts:每一次录数与重录,连同录数的人 —— 只增不改;counted_by 由函数写。
--   ③ 盘点三张表没有直连写:stocktakes / stocktake_lines 的 INSERT / UPDATE 策略拿掉,直连 INSERT / UPDATE 按名拒
--      STOCKTAKE_THROUGH_FUNCTION_ONLY;开单 open_stocktake、录数 record_stocktake_count(新,SECURITY DEFINER)。
--   ④ post_stocktake:门换成 action.stocktake_post;开单人那条腿不变;新加录数人那条腿(按人认)
--      STOCKTAKE_COUNTER_CANNOT_POST|单号。
--   ⑤ 缺口 1(Q5):inbound_batch_landed_unit_cost 拿掉 module.stocktakes.edit 那一支;batch_freight_base 与
--      batch_processing_cost_base 先问 data.view_prices(不持的人读 NULL);allocate_processing_costs 改读 _all ——
--      【算一笔要过账的钱不许问权限】,分摊不再靠分摊人碰巧看得见。
--   ⑥ 缺口 2(Q10):assay_results.is_final 直连改 → ASSAY_FINAL_THROUGH_FUNCTION_ONLY。
--   ⑦ 缺口 3(Q11):已定价的收货改供应商 / 采购单 / 采购行 → RECEIPT_PRICED_SOURCE_FROZEN|收货(不分直连与属主路径)。
--   ⑧ 缺口 4 与 Q12:assert_other_decider(新)—— 审批开着、提单人之外二级没人批得动时按名拒;
--      submit_payroll_request(PAYROLL_NO_OTHER_DECIDER|工资期)与六支付款申请提交(PAYMENT_REQUEST_NO_OTHER_DECIDER)调它。
--
-- 【不做什么】不碰审批开关与策略、user_roles、任何业务行;不动工单、加工提交、回滚、注销批次、收货建单(那是 3b)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权 = 之前 + 裁定的那四行,一行不少、一行不多;
-- 新码的持有人正好是裁定的那几个角色;在途单据一张不少、一张不多;approval_log、journal_entries、盘点单与盘点行、
-- 收货(已定价 / 全部)、化验(正式 / 已应用)一行没变;stocktake_counts 是空的;直连写策略没了、守卫挂上;
-- 每一张在途单据都还有一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B3A_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ('action.stocktake_count', 'action.stocktake_post')) THEN
        RAISE EXCEPTION 'ROLE1B3A_PRE|new codes already exist';
    END IF;
    IF to_regclass('public.stocktake_counts') IS NOT NULL THEN
        RAISE EXCEPTION 'ROLE1B3A_PRE|stocktake_counts already exists';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public'
         AND policyname IN ('stocktakes insert by permission', 'stocktakes update by permission',
                            'stocktake_lines insert by permission', 'stocktake_lines update by permission')) <> 4 THEN
        RAISE EXCEPTION 'ROLE1B3A_PRE|the four stocktake write policies are not all there to drop';
    END IF;
    -- 在途盘点上没有行 —— 没有"谁数过"要回填(Step 0 实测 5 张都是 0 行;不假设,问一遍)
    IF EXISTS (SELECT 1 FROM stocktake_lines l JOIN stocktakes s ON s.id = l.stocktake_id
                WHERE s.status = 'open' AND s.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'ROLE1B3A_PRE|an open stocktake has lines — who counted them would have to be backfilled';
    END IF;
    -- 过账要读得到盘点单:finance 今天持 module.stocktakes.view
    IF NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                    WHERE r.code = 'finance' AND rp.permission_code = 'module.stocktakes.view') THEN
        RAISE EXCEPTION 'ROLE1B3A_PRE|finance does not hold module.stocktakes.view';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE b3a_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted';
CREATE TEMP TABLE b3a_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM stocktakes) AS stocktakes,
       (SELECT count(*) FROM stocktake_lines) AS stocktake_lines,
       (SELECT count(*) FROM inbound_batches WHERE unit_price IS NOT NULL) AS receipts_priced,
       (SELECT count(*) FROM inbound_batches) AS receipts_all,
       (SELECT count(*) FROM assay_results WHERE is_final) AS assays_final,
       (SELECT count(*) FROM assay_results WHERE applied_at IS NOT NULL) AS assays_applied,
       (SELECT count(*) FROM payment_requests) AS payment_requests,
       (SELECT count(*) FROM payroll_requests) AS payroll_requests;
CREATE TEMP TABLE b3a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 目录:两个新码;module.stocktakes.edit 的描述改写 ──────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.stocktake_count', 'action', 'Open stocktakes and count', '开盘点单与录数', 'Open a stocktake and record counted quantities on it. Every count and recount is kept with the person who made it; nobody who counted a stocktake, or opened it, may post it. Cancelling a stocktake stays with Stocktakes (edit).', '开一张盘点单并在上面录实点数。每一次录数与重录都连同录数的人一起留下;数过一张盘点单或开过它的人,永远不能过账它。取消盘点仍归「盘点(编辑)」。', 1060),
    ('action.stocktake_post', 'action', 'Post stocktakes', '盘点过账', 'Post a counted stocktake: the differences go into stock and to the ledger (stock gain or loss). Nobody posts a stocktake they opened or counted on.', '把一张数完的盘点单过账:差异进库存、过总账(盘盈或盘亏)。没有人能过账自己开的或数过的盘点单。', 1070);
UPDATE public.permissions SET name_en = 'Stocktakes (edit)', name_zh = '盘点(编辑)',
       description_en = 'Cancel an open stocktake. Opening and counting are "Open stocktakes and count"; posting is "Post stocktakes".', description_zh = '取消一张未过账的盘点单。开单与录数是「开盘点单与录数」;过账是「盘点过账」。'
 WHERE code = 'module.stocktakes.edit';

-- ── 2 · 授权(在函数之前:下面的自证要问到它们)────────────────────────────────
-- 录数归仓库、过账归财务;admin 两个都拿(Tim 的常设裁定)。幂等。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, g.c FROM roles r
  JOIN (VALUES ('warehouse', 'action.stocktake_count'), ('admin', 'action.stocktake_count'),
               ('finance', 'action.stocktake_post'), ('admin', 'action.stocktake_post')) g(role_code, c)
    ON g.role_code = r.code
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 3 · 守卫函数与断言(新;表与触发器要用到它们)─────────────────────────────

-- db/functions/guard_stocktake_direct_write.sql
-- ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q3):**盘点的三张表没有直连写**。
--
-- 【Step 0 量出来的三扇侧门】stocktakes 与 stocktake_lines 的 INSERT / UPDATE 策略开在
-- module.stocktakes.edit 上,于是任何持它的人不经 post_stocktake 就能:
--   · 把 stocktakes.status 直接写成 posted(库存与总账一行没动,单据却说过过账);
--   · 改写 created_by(四眼那条"开单人不能过账"的腿认的就是它);
--   · 在已过账或已取消的单上加行、改行(状态检查只在屏幕的 saveCount 里)。
-- 把过账交给财务、"录过数的人不能过账"都是空话,除非这几扇门关上。
--
-- 【怎么关】两条写策略拿掉;开单走 open_stocktake、录数走 record_stocktake_count、过账走
-- post_stocktake、取消走 cancel_stocktake —— 四支都是 SECURITY DEFINER。本守卫是语句级的,
-- 零行也照样触发(SILENT-1 那一族:没有写策略时直连 UPDATE 是零行、不报错),按名拒
-- STOCKTAKE_THROUGH_FUNCTION_ONLY。属主路径(row_security_active = false)一律放行。
-- 挂在 stocktakes · stocktake_lines · stocktake_counts 三张表上(同一句话,一份定义)。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径;理由见 guard_lock_reopen_path 的抬头。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql.

CREATE OR REPLACE FUNCTION public.guard_stocktake_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'STOCKTAKE_THROUGH_FUNCTION_ONLY';
END;
$function$;

COMMENT ON FUNCTION public.guard_stocktake_direct_write() IS
'ROLE-1 Batch 3a:stocktakes / stocktake_lines / stocktake_counts 的直连写(row_security_active,语句级,零行也触发)按名拒 STOCKTAKE_THROUGH_FUNCTION_ONLY。开单 open_stocktake、录数 record_stocktake_count(action.stocktake_count,仓库)、过账 post_stocktake(action.stocktake_post,财务)、取消 cancel_stocktake(module.stocktakes.edit)—— 四支都是 SECURITY DEFINER。';

-- db/functions/guard_stocktake_count_append_only.sql
-- ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q2):**谁数过,只增不改**。
--
-- stocktake_counts 是"这张盘点单上谁数过"的唯一记录,过账时"录过数的人不能过账"读的就是它。
-- 一行能被改掉或删掉,那条规矩就能被事后抹平 —— 所以 UPDATE 与 DELETE 【不分直连与属主路径】
-- 一律按名拒 STOCKTAKE_COUNT_APPEND_ONLY|盘点单。重录是再插一行,不是改旧的那一行。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql.

CREATE OR REPLACE FUNCTION public.guard_stocktake_count_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'STOCKTAKE_COUNT_APPEND_ONLY|%',
        COALESCE((SELECT s.code FROM stocktakes s WHERE s.id = OLD.stocktake_id), OLD.stocktake_id::text);
END;
$function$;

COMMENT ON FUNCTION public.guard_stocktake_count_append_only() IS
'ROLE-1 Batch 3a:stocktake_counts 只增不改 —— UPDATE / DELETE 不分直连与属主路径,一律按名拒 STOCKTAKE_COUNT_APPEND_ONLY|盘点单。过账时"录过数的人不能过账"读的就是这张表。';

-- db/functions/assert_other_decider.sql
-- ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q12):**提单人之外没人批得动,提交就拒**。
--
-- 【Step 0 量出来的】admin@ 与 tim@ 是同一个人(account_person 两个都是 4737faa9…),二级今天只有
-- tim@ 一个真持有人,而 admin 角色持每一个码(Tim 的常设裁定)—— 于是 admin@ 能提一张工资申请
-- (module.hr.edit)或一张付款 / 转账 / 预扣税申请(module.finance.edit),提单人那条腿按人认,
-- tim@ 批不了,又没有第二个人:它挂在那里,还经 blocks_disable 挡住关审批。收货定价申请在 4b 里
-- 按名拒了同一个形状(RECEIPT_PRICE_NO_OTHER_DECIDER);本函数把那几行抽成一份,给工资申请与六支
-- 付款申请的提交共用。
--
-- 【判据】审批开着时,approval_deciders(本链、本级、提单人 = auth.uid()、无主角)一个人都没有 →
-- RAISE p_refusal(调用方给出按名拒的那一句)。审批关着时不拒:申请生下来就是 approved。
-- 【为什么 RAISE 而不是返回布尔】它是一句断言,不是一个读者 —— 没有返回值的函数,
-- "不拒"与"成功"是同一个字节(void-assertion 那一条)。
-- 【EXECUTE 从 authenticated 收回】调用它的都是 SECURITY DEFINER 的提交函数;approval_deciders
-- 本身也收回了。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql.

CREATE OR REPLACE FUNCTION public.assert_other_decider(p_subject_type text, p_action_function text, p_level smallint, p_refusal text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_l1 text;
    v_l2 text;
BEGIN
    IF NOT approvals_enabled() THEN
        RETURN;
    END IF;
    SELECT approval_level1_role_code, approval_level2_role_code
      INTO v_l1, v_l2 FROM finance_settings LIMIT 1;
    IF NOT EXISTS (SELECT 1 FROM approval_deciders(p_subject_type, p_action_function, p_level,
                                                   auth.uid(), NULL, v_l1, v_l2)) THEN
        RAISE EXCEPTION '%', p_refusal;
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.assert_other_decider(text, text, smallint, text) IS
'ROLE-1 Batch 3a:审批开着、approval_deciders(本链、本级、提单人 = auth.uid())一个人都没有时,RAISE 调用方给的那一句(工资申请 PAYROLL_NO_OTHER_DECIDER|工资期;付款申请一族 PAYMENT_REQUEST_NO_OTHER_DECIDER)。审批关着时不拒。EXECUTE 已从 authenticated 收回。';

-- ── 4 · stocktake_counts(镜像原样)──────────────────────────────────────────
CREATE TABLE public.stocktake_counts (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    stocktake_id      uuid NOT NULL REFERENCES public.stocktakes (id) ON DELETE RESTRICT,
    stocktake_line_id uuid NOT NULL REFERENCES public.stocktake_lines (id) ON DELETE RESTRICT,
    inbound_batch_id  uuid REFERENCES public.inbound_batches (id) ON DELETE RESTRICT,
    output_batch_id   uuid REFERENCES public.output_batches (id) ON DELETE RESTRICT,
    book_qty          numeric NOT NULL,
    counted_qty       numeric NOT NULL CHECK (counted_qty >= 0),
    notes             text,
    counted_by        uuid NOT NULL,
    counted_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT stocktake_counts_one_batch CHECK ((inbound_batch_id IS NULL) <> (output_batch_id IS NULL))
);

CREATE INDEX idx_stocktake_counts_stocktake ON public.stocktake_counts (stocktake_id);
CREATE INDEX idx_stocktake_counts_line ON public.stocktake_counts (stocktake_line_id);

ALTER TABLE public.stocktake_counts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "stocktake_counts select by permission"
    ON public.stocktake_counts
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.stocktakes.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.stocktake_counts FROM anon;

-- 只增不改:UPDATE / DELETE 一律按名拒(属主路径也拒)。
CREATE TRIGGER trg_stocktake_counts_append_only
    BEFORE UPDATE OR DELETE ON public.stocktake_counts
    FOR EACH ROW EXECUTE FUNCTION public.guard_stocktake_count_append_only();

-- 没有写策略:直连写(零行也触发)按名拒 STOCKTAKE_THROUGH_FUNCTION_ONLY。
CREATE TRIGGER trg_stocktake_counts_direct_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.stocktake_counts
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_stocktake_direct_write();

-- ── 5 · 盘点两张表:直连写策略拿掉,直连 INSERT / UPDATE 按名拒 ─────────────────
DROP POLICY "stocktakes insert by permission" ON public.stocktakes;
DROP POLICY "stocktakes update by permission" ON public.stocktakes;
DROP POLICY "stocktake_lines insert by permission" ON public.stocktake_lines;
DROP POLICY "stocktake_lines update by permission" ON public.stocktake_lines;
CREATE TRIGGER trg_stocktakes_direct_write
    BEFORE INSERT OR UPDATE ON public.stocktakes
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_stocktake_direct_write();
CREATE TRIGGER trg_stocktake_lines_direct_write
    BEFORE INSERT OR UPDATE ON public.stocktake_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_stocktake_direct_write();

-- ── 6 · 函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/open_stocktake.sql
-- ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q3 · Q4):开一张盘点单。
-- 开单是录数的第一步,所以门是 action.stocktake_count(仓库与 admin)。
-- 开单人由 auth.uid() 写 —— 此前 createStocktake 直连 INSERT、created_by 由客户端送,
-- 而 post_stocktake 四眼的那条腿认的正是它。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql.

CREATE OR REPLACE FUNCTION public.open_stocktake(p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_code text;
BEGIN
    PERFORM require_permission('action.stocktake_count');

    INSERT INTO stocktakes (notes, created_by, updated_by)
    VALUES (NULLIF(btrim(COALESCE(p_notes, '')), ''), v_user, v_user)
    RETURNING id, code INTO v_id, v_code;

    RETURN jsonb_build_object('stocktake_id', v_id, 'code', v_code);
END;
$function$;

COMMENT ON FUNCTION public.open_stocktake(text) IS
'ROLE-1 Batch 3a:开一张盘点单(action.stocktake_count)。开单人由 auth.uid() 写,不经客户端;开单人永远不能过账这一张(post_stocktake)。';

-- db/functions/record_stocktake_count.sql
-- ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q2 (A) · Q3):录一笔实点数 / 重录。
--
-- 【两处写,一个事务】
--   ① stocktake_lines:这一格【现在】的实点数(过账读它)—— 同一 (盘点单, 批次) 重录覆盖,
--      book_qty 取【保存时点】的批次剩余(与原来的 saveCount 同一口径),created_by = 最后一个录数的人;
--   ② stocktake_counts:追加一行"谁、何时、数成多少"—— 只增不改。过账时"录过数的人不能过账"
--      读的就是这张表,所以重录【不会】抹掉前一个录数的人。
-- 录数的人由 auth.uid() 写,不经客户端。
--
-- 【拒】PERMISSION_DENIED|action.stocktake_count · STOCKTAKE_NOT_FOUND · STOCKTAKE_NOT_OPEN(过账或
-- 取消之后不许再录 —— 此前这一句只在屏幕上)· STOCKTAKE_COUNT_BATCH_REQUIRED(要且只要一个批次)·
-- STOCKTAKE_COUNT_QTY_INVALID(空或负)· BATCH_DELETED(批次不存在或已注销)。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql.

CREATE OR REPLACE FUNCTION public.record_stocktake_count(p_stocktake_id uuid, p_inbound_batch_id uuid, p_output_batch_id uuid, p_counted_qty numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_st      record;
    v_book    numeric;
    v_deleted timestamptz;
    v_found   boolean;
    v_notes   text := NULLIF(btrim(COALESCE(p_notes, '')), '');
    v_line_id uuid;
BEGIN
    PERFORM require_permission('action.stocktake_count');

    SELECT id, code, status, deleted_at INTO v_st
      FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_st.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', COALESCE(p_stocktake_id::text, '?');
    END IF;
    IF v_st.status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_st.status;
    END IF;

    IF (p_inbound_batch_id IS NULL) = (p_output_batch_id IS NULL) THEN
        RAISE EXCEPTION 'STOCKTAKE_COUNT_BATCH_REQUIRED|%', v_st.code;
    END IF;
    IF p_counted_qty IS NULL OR p_counted_qty < 0 THEN
        RAISE EXCEPTION 'STOCKTAKE_COUNT_QTY_INVALID|%', v_st.code;
    END IF;

    IF p_inbound_batch_id IS NOT NULL THEN
        SELECT remaining_qty, deleted_at, true INTO v_book, v_deleted, v_found
          FROM inbound_batches WHERE id = p_inbound_batch_id;
    ELSE
        SELECT remaining_qty, deleted_at, true INTO v_book, v_deleted, v_found
          FROM output_batches WHERE id = p_output_batch_id;
    END IF;
    IF v_found IS NULL OR v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'BATCH_DELETED|%', COALESCE(p_inbound_batch_id, p_output_batch_id)::text;
    END IF;

    IF p_inbound_batch_id IS NOT NULL THEN
        INSERT INTO stocktake_lines (stocktake_id, inbound_batch_id, book_qty, counted_qty, notes, counted_at, created_by)
        VALUES (p_stocktake_id, p_inbound_batch_id, v_book, p_counted_qty, v_notes, now(), v_user)
        ON CONFLICT (stocktake_id, inbound_batch_id) DO UPDATE
           SET book_qty = EXCLUDED.book_qty, counted_qty = EXCLUDED.counted_qty, notes = EXCLUDED.notes,
               counted_at = EXCLUDED.counted_at, created_by = EXCLUDED.created_by
        RETURNING id INTO v_line_id;
    ELSE
        INSERT INTO stocktake_lines (stocktake_id, output_batch_id, book_qty, counted_qty, notes, counted_at, created_by)
        VALUES (p_stocktake_id, p_output_batch_id, v_book, p_counted_qty, v_notes, now(), v_user)
        ON CONFLICT (stocktake_id, output_batch_id) DO UPDATE
           SET book_qty = EXCLUDED.book_qty, counted_qty = EXCLUDED.counted_qty, notes = EXCLUDED.notes,
               counted_at = EXCLUDED.counted_at, created_by = EXCLUDED.created_by
        RETURNING id INTO v_line_id;
    END IF;

    INSERT INTO stocktake_counts (stocktake_id, stocktake_line_id, inbound_batch_id, output_batch_id,
                                  book_qty, counted_qty, notes, counted_by)
    VALUES (p_stocktake_id, v_line_id, p_inbound_batch_id, p_output_batch_id,
            v_book, p_counted_qty, v_notes, v_user);

    UPDATE stocktakes SET updated_by = v_user, updated_at = now() WHERE id = p_stocktake_id;

    RETURN jsonb_build_object('stocktake_id', p_stocktake_id, 'code', v_st.code, 'line_id', v_line_id,
                              'book_qty', v_book, 'counted_qty', p_counted_qty);
END;
$function$;

COMMENT ON FUNCTION public.record_stocktake_count(uuid, uuid, uuid, numeric, text) IS
'ROLE-1 Batch 3a:录数 / 重录(action.stocktake_count)。覆盖 stocktake_lines 那一格的实点数,并在 stocktake_counts 追加一行谁数的(只增不改)—— 过账时录过数的每一个人都被拒。只在盘点单 open 时收;录数的人由 auth.uid() 写。';

-- db/functions/post_stocktake.sql
-- 盘点过账。cut 2a 建的;★ APR-3(2026-09-22)把它接上审批引擎。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★ APR-3 在这里加了两样,而【没有】加第三样 ★★(Tim 的 Q4 裁定)
-- ════════════════════════════════════════════════════════════════════════════
-- 加的:① 四眼(只有 raiser 那条腿 —— 一次盘点【不是关于某个人的】,
--          与工单同形,第二个入参传 NULL,而 NULL 一律不匹配);
--        ② 一行 approval_log 留痕。
--
-- ★【没有加按角色分级,而这是一条裁定,不是遗漏】盘点【没有金额】——
--   stocktakes 表上一个金额列都没有(id/code/status/notes/时间戳/人)。
--   按 Tim 修订后的 N7:按角色分级只管带钱的单据;不带钱的,谁能批仍由它
--   自己的模块权限说了算,这里就是 module.stocktakes.edit。
--   ☞ 所以本函数【不】调 require_approver_for,也因此【不】进
--     approval_chain_gates() 那张名册 —— fixture 203 的 E 臂把名册与
--     「prosrc 里真的调了它的那组函数」钉成逐字相等,加错一行当场红。
--
-- ★【留痕永远写 approved,永远不写 auto_approved】过账是一个人按下去的动作,
--   开着还是关着都是。这与 HR 三条链、以及 APR-3 同时修好的工单放行,
--   是同一条裁定(Tim 的 Q7)。level 恒为 NULL —— 写一个级别就是声称有过
--   一次按级别的授权,而这条链没有。
--
-- ⚠★【它对线上 5 张 open 的盘点是有后果的,照直说】线上 ST-2026-0082…0086
--   五张都是 admin@swm-os.test 建的,于是从本刀起 **admin 自己过不了这五张**。
--   过得了的是另外五个持 module.stocktakes.edit 的人(chooer · fusheng ·
--   phua · sandra · vince)。这是四眼原则要的效果,不是一次回归。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★ ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q2 · Q4):过账归财务,录过数的人永远不能过账 ★★
-- ════════════════════════════════════════════════════════════════════════════
-- · 门从 module.stocktakes.edit 换成 action.stocktake_post(财务与 admin)。录数归仓库
--   (action.stocktake_count);取消仍归 module.stocktakes.edit。
-- · 开单人那条腿不变(SELF_APPROVAL_FORBIDDEN|raiser)。新加【录数的人】那条腿:stocktake_counts
--   里这张单上每一个录过数的人(重录不抹掉前一个),再加 stocktake_lines.created_by(本刀之前的行
--   只记了最后一个保存的人 —— 线上在途的 5 张都是 0 行,但判据不假设这一点)。按人认:
--   self_leg(录数人, NULL, 我) ≠ 'none' → STOCKTAKE_COUNTER_CANNOT_POST|盘点单。
--   NULL 的 created_by 永不匹配;stocktake_counts.counted_by 是 NOT NULL,由函数写。
-- · 上面 APR-3 那段说"过得了的是另外五个持 module.stocktakes.edit 的人"—— 从本刀起过得了的是
--   持 action.stocktake_post 的人(chooer · admin),减去开单人与录过数的人。
--
-- ★【open 不算"在途待批"】approval_pending_documents() 里【没有】盘点 ——
--   open 的意思是"正在点",不是"在等人批";盘点在点完与过账之间没有那一格。
--   把 5 张 open 数成在途,会让屏幕说一句假话。理由写在那个函数的抬头。

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
    PERFORM require_permission('action.stocktake_post');
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

    -- ★ ROLE-1 Batch 3a:录过数的人不能过账(按人认)。开单人那条腿在上一行,先判。
    IF EXISTS (SELECT 1
                 FROM (SELECT c.counted_by AS who FROM stocktake_counts c WHERE c.stocktake_id = p_stocktake_id
                       UNION
                       SELECT l.created_by FROM stocktake_lines l
                        WHERE l.stocktake_id = p_stocktake_id AND l.created_by IS NOT NULL) k
                WHERE self_leg(k.who, NULL::uuid, v_user) <> 'none') THEN
        RAISE EXCEPTION 'STOCKTAKE_COUNTER_CANNOT_POST|%', v_st.code;
    END IF;

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

-- db/functions/inbound_batch_landed_unit_cost.sql
-- CLEANUP-A:落地单位成本的【读者】名 —— 自带判据(R3:授权不是控制)。
-- fu1 起算术委托给 inbound_batch_landed_unit_cost_all:要算过账的钱的调用方读 _all,
-- 因为【给人看一个价格】要问权限,【算一笔要过账的钱】不许问权限。

CREATE OR REPLACE FUNCTION public.inbound_batch_landed_unit_cost(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【R3:授权不是控制】—— 一个【拿得到 EXECUTE】的调用者仍然被这里拦住。
    -- db/fixtures/174 的 E 臂刻意以那样的身份来问,问的就是这一句。
    -- ★ ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q5):原来这里还放行 module.stocktakes.edit
    --   (CLEANUP-A 为盘点 / 注销那条路留的)。fu1 之后那两条路读的是 _all,这一支早已无人走 ——
    --   它只剩一个效果:让持盘点码的仓库读到到岸成本(ROLE1B4A-LANDED-COST-STOCKTAKE-EXCEPTION)。拿掉。
    IF NOT has_permission('data.view_prices'::text) THEN
        RAISE EXCEPTION 'LANDED_COST_PERMISSION_DENIED|%', 'data.view_prices'
          USING HINT = '落地单位成本【是一个价格】—— 要看它得有 data.view_prices。'
                       '这不是"这批货没有金额",是权限:两者在这支函数里必须分得开。'
                       '【要算一笔过账的钱、而不是给人看】的调用方读 _all 那一支。';
    END IF;
    -- 【算术只有一份】委托给 _all,不复制 —— 两份实现会悄悄分开。
    RETURN inbound_batch_landed_unit_cost_all(p_inbound_batch_id);
END
$function$;

COMMENT ON FUNCTION public.inbound_batch_landed_unit_cost(p_inbound_batch_id uuid) IS
    'CLEANUP-A:落地单位成本的【读者】名 —— 自带判据 data.view_prices(ROLE-1 Batch 3a 拿掉了 module.stocktakes.edit 那一支;R3:授权不是控制,一个拿得到 EXECUTE 的调用者也被拦)。拒绝用 RAISE 不用 NULL,因为本支的 NULL 已经有主:它是"这批货真的没有金额",inbound_batch_valuation.unpriced 就定义为它 IS NULL。fu1 起算术委托给 inbound_batch_landed_unit_cost_all —— 【要算过账的钱】的调用方读 _all 那一支,因为账上的金额不许取决于按按钮的人有什么读权限。';

-- ─── batch_freight_base
CREATE OR REPLACE FUNCTION public.batch_freight_base(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【屏幕读取器】0.00 与「受限」不是同一件事:第一个是谎话。
    -- 白名单与 batch_processing_cost_base 逐字相同,理由也逐字相同 ——
    -- 【承重的那一格】allocate_processing_costs 的调用者【必然】读得到这里,于是
    -- 材料成本表达式里这一支【按构造】不可能是 NULL。一个 NULL 加数会让
    -- SUM 跳过整条投料腿(连 unit_price 一起),那比读到 0 更坏。
    -- ★ ROLE-1(2026-09-23):分摊的门从 module.processing.edit 换成 module.finance.edit,
    --   于是承重的是 finance.view 那一格(edit 蕴含 view —— set_role_permissions 的
    --   EDIT_REQUIRES_VIEW)。processing.edit 那一格原样留着:它不放宽任何东西
    --   (持它必持 processing.view),拿掉它是另一刀的事。fixture 163 的 D 臂钉的是这一格。
    -- ★ ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q5):【它是到岸成本的一部分,所以先问
    --   data.view_prices】。此前任何持 module.inbound.view 的人都读到真数,而仓库 4a 起又看得见收货
    --   单价 —— 单价 + (运费 + 加工费) / 数量 = 到岸单位成本(ROLE1B4A-LANDED-COST-STOCKTAKE-EXCEPTION)。
    --   不持它的人读到 NULL(不是 0),页面画「受限」。分摊(allocate_processing_costs)从本刀起读
    --   _all,不再靠调用者碰巧看得见 —— 所以 NULL 毒化求和那件事(fixture 163 D)不再挂在这里。
    SELECT CASE
        WHEN has_permission('data.view_prices')
         AND (has_permission('module.inbound.view')
          OR has_permission('module.finance.view')
          OR has_permission('module.processing.view')
          OR has_permission('module.processing.edit'))
        THEN batch_freight_base_all(p_inbound_batch_id)
        ELSE NULL
    END;
$function$;

-- ─── batch_processing_cost_base
CREATE OR REPLACE FUNCTION public.batch_processing_cost_base(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【屏幕读取器】PROC-COST-1 fu2 立的这条,本刀只把算术抽到
    -- batch_processing_cost_base_all 去 —— 行为一个字节没变,
    -- 变的是"算术"与"受众"从此各有一份定义,而计值路径读的是前者。
    -- ★ ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q5):【它是到岸成本的一部分,所以先问
    --   data.view_prices】。此前任何持 module.inbound.view 的人都读到真数,而仓库 4a 起又看得见收货
    --   单价 —— 单价 + (运费 + 加工费) / 数量 = 到岸单位成本(ROLE1B4A-LANDED-COST-STOCKTAKE-EXCEPTION)。
    --   不持它的人读到 NULL(不是 0),页面画「受限」。分摊(allocate_processing_costs)从本刀起读
    --   _all,不再靠调用者碰巧看得见 —— 所以 NULL 毒化求和那件事(fixture 163 D)不再挂在这里。
    SELECT CASE
        WHEN has_permission('data.view_prices')
         AND (has_permission('module.inbound.view')
          OR has_permission('module.finance.view')
          OR has_permission('module.processing.view')
          OR has_permission('module.processing.edit'))
        THEN batch_processing_cost_base_all(p_inbound_batch_id)
        ELSE NULL
    END;
$function$;

-- ─── allocate_processing_costs
CREATE OR REPLACE FUNCTION public.allocate_processing_costs(p_run_id uuid, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- Cost allocation. Metals with a usable price (deleted_at IS NULL, price_date <= run
-- process_date) contribute to metal value; metals WITHOUT one contribute 0 and are
-- recorded in allocation_snapshot.skipped_metals (the former missing-price hard error is gone).
-- NO_METAL_VALUE still blocks when the total metal value across all legs is 0.
-- (Phase 1 follow-up 1, 2026-07-03.)
-- cut 2a (2026-07-06): 10a 资本化分录(借 1220 / 贷 1200 材料 + 贷 5xxx 费用;
-- 重分摊 = 冲旧 + 重挂);10b 给无 COGS 的既有销售按原 sale_date 补挂 COGS。
DECLARE
    v_user                 uuid := auth.uid();
    v_run                  processing_runs%ROWTYPE;
    v_basis                text;
    v_process_date         date;
    v_material             numeric;
    v_process              numeric;
    v_total                numeric;
    v_inputs_without_price integer;
    v_total_basis          numeric;
    v_total_metal_value    numeric;
    v_bad_code             text;
    v_bad_metal            text;
    v_prices_used          jsonb;
    v_default_index        text;
    v_skipped_metals       jsonb;
    v_outputs              jsonb;
    v_sum_alloc            numeric;
    v_snapshot             jsonb;
    v_ct                   record;
    v_sale                 record;
    v_cap_lines            jsonb;
    v_cap_total            numeric;
    v_cap_je               jsonb;
    v_cap_entry_id         uuid;
    v_cogs                 numeric;
    v_cogs_je              jsonb;
    -- FIN-24:差额法用
    v_prior                jsonb;      -- 分摊前各产出腿的 allocated(差额的"已记录"侧)
    v_rec_src              jsonb;      -- 已记录的各来源(material / 各 cost_type)
    v_rec_total            numeric;
    v_by_source            jsonb;      -- 本次各来源(写进 snapshot,下次的"已记录")
    v_delta                numeric;
    v_leg                  record;
    v_d1220                numeric := 0;
    v_d5000                numeric := 0;
    v_d5200                numeric := 0;
    v_l1220                numeric;
    v_l5000                numeric;
    v_other                numeric;
    v_cred_total           numeric := 0;
    v_deb_total            numeric;
    v_cap_status           text;
    -- FIN-25:再加工
    v_material_in          numeric;   -- 进料批投料(→ 1200)
    v_material_re          numeric;   -- 产出批投料(→ 1220 解除上游)
    v_upstream_incomplete  boolean;
    v_re_without_price     integer;
    -- PROC-COST-1:状态改变型分支
    v_state_changing       boolean;
    v_sc_out_inputs        integer;
    v_sc_in_inputs         integer;
    v_sc_basis_total       numeric;
    v_sc_rows              jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. Lock the run; must exist and be a live committed run.
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;
    IF v_run.deleted_at IS NOT NULL OR v_run.status <> 'committed' THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.status;
    END IF;

    -- PROC-COST-1:那条"无处可落"的拒绝在这里【换成了真正的去处】——
    -- 状态改变型的分支在第 6 步之后(它需要 v_material / v_process 都已算出)。
    -- 仍然拒绝的四种情形在分支里逐一按名点出,理由见本迁移的 2e 段。

    -- 2. Resolve + validate basis.
    v_basis := COALESCE(p_basis, v_run.allocation_basis);
    IF v_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', v_basis;
    END IF;
    v_process_date := v_run.process_date;

    -- 3. Unit guard: all math assumes kg.
    SELECT ib.code INTO v_bad_code
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id AND ib.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    SELECT ob.code INTO v_bad_code
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id AND ob.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    -- 4. Material cost(FIN-25 起两路):进料批按 inbound.unit_price;产出批
    --    (再加工)按上游 processing_outputs.unit_cost_base。NULL 价照旧计 0 并
    --    计数 —— 【允许,不拒绝】:车间按天走,财务分摊按月走,拒绝会让车间等
    --    财务。零不静默:cost_incomplete 标记打在本单产出上,逐级传染(见 9c),
    --    上游补分摊后本单过期,重跑即修复。
    -- FRT-1:材料成本 = 【落地成本】,不只是单价 —— 单价 + 分摊到该批的单位运费。
    -- 运费资本化进批次之后,这里若仍只读 unit_price,运费就停在 1200/5000,
    -- 永远走不到产出批的 unit_cost_base,batch_margin 会继续停在运费之前的那个数
    -- (而运费那张分录本身完全正确)。这正是"资本化的错误藏在存货里"最具体的一种。
    SELECT COALESCE(SUM(pi.quantity_consumed
             * (COALESCE(ib.unit_price, 0)
                -- ★ ROLE-1 Batch 3a:读 _all —— 【算一笔要过账的钱不许问权限】(inbound_batch_landed_unit_cost
                -- 的同一条规矩)。此前读带判据的屏幕读取器,靠的是分摊的人碰巧看得见;一个 NULL 加数会
                -- 让 SUM 跳过整条投料腿(fixture 163 D)。
                + CASE WHEN ib.quantity > 0 THEN batch_freight_base_all(ib.id) / ib.quantity ELSE 0 END
                -- PROC-COST-1:第三个成本组件 —— 该批身上已资本化的加工成本
                -- (放电等状态改变型工序留下的)。【不加这一项,成本就走不出去】:
                -- 它是进料批上的资本化成本【唯一】能到达损益表的那条路。
                + CASE WHEN ib.quantity > 0 THEN batch_processing_cost_base_all(ib.id) / ib.quantity ELSE 0 END)), 0),
           COUNT(*) FILTER (WHERE ib.unit_price IS NULL)
      INTO v_material_in, v_inputs_without_price
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id;

    SELECT COALESCE(SUM(pi.quantity_consumed * COALESCE(po_up.unit_cost_base, 0)), 0),
           COUNT(*) FILTER (WHERE po_up.unit_cost_base IS NULL),
           COALESCE(bool_or(po_up.unit_cost_base IS NULL OR po_up.cost_incomplete), false)
      INTO v_material_re, v_re_without_price, v_upstream_incomplete
    FROM processing_inputs pi
    JOIN processing_outputs po_up ON po_up.output_batch_id = pi.output_batch_id
    WHERE pi.run_id = p_run_id;
    v_inputs_without_price := v_inputs_without_price + COALESCE(v_re_without_price, 0);
    v_material := v_material_in + v_material_re;

    -- 5. Process cost = Σ live cost entries.
    SELECT COALESCE(SUM(amount_base), 0) INTO v_process
    FROM processing_cost_entries
    WHERE run_id = p_run_id AND deleted_at IS NULL;

    -- 6. Total.
    v_total := v_material + v_process;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-COST-1:【状态改变型 —— 成本资本化回投料批】
    -- 没有产出腿,于是收件人是那批【还在那里的】原料本身。深度放电不产出任何
    -- 新东西:料进去、料出来,只是不带电了 —— 所以它仍然是原料,成本落在 1200。
    -- 【只有加工成本资本化,材料成本【不】动】那批料的价值早就在 1200 上了;
    -- 再借一次 1200 就是拿 1200 对自己重复计数。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT NOT k.produces_outputs INTO v_state_changing
      FROM operation_types ot
      JOIN operation_kinds k ON k.code = ot.kind_code
     WHERE ot.code = v_run.operation_type_code;
    v_state_changing := COALESCE(v_state_changing, false);

    IF v_state_changing THEN
        -- 【拒绝 1】金属价值基准按【产出批的金属含量】拆分,而这里没有产出批。
        -- 那不是"算出来是零",是那个基准在这里根本没有可读的数。
        IF v_basis = 'metal_value' THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_BASIS|%|%', v_run.code, v_basis
              USING HINT = '金属价值基准读的是产出批的金属含量(output_batch_metals),而状态改变型工序没有产出批。按质量(weight)分摊。';
        END IF;

        SELECT count(*) FILTER (WHERE pi.output_batch_id IS NOT NULL),
               count(*) FILTER (WHERE pi.inbound_batch_id IS NOT NULL)
          INTO v_sc_out_inputs, v_sc_in_inputs
          FROM processing_inputs pi
         WHERE pi.run_id = p_run_id;

        -- 【拒绝 2】成本载体按 inbound_batch_id 记地址,自产产出批不在那个地址空间里。
        -- **按名拒绝,不许悄悄把成本丢掉** —— 要建这条路,先决定产出批的资本化载体
        -- 是什么(产出批已有 unit_cost_base,那是另一种形状,不是这一张台账)。
        IF v_sc_out_inputs > 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_OUTPUT_INPUT|%|%', v_run.code, v_sc_out_inputs
              USING HINT = '成本载体 batch_processing_cost_allocations 按进料批记地址,自产产出批不在它的地址空间里。这条路要建,先决定产出批的资本化载体是什么 —— 在那之前按名拒绝,而不是悄悄把这笔成本丢掉。';
        END IF;

        -- 【拒绝 3】没有投料批,资本化没有收件人。
        IF v_sc_in_inputs = 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_NO_INPUT|%', v_run.code
              USING HINT = '这张单没有进料批投料,资本化没有收件人。';
        END IF;

        SELECT COALESCE(SUM(pi.quantity_consumed), 0) INTO v_sc_basis_total
          FROM processing_inputs pi
         WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL;
        IF v_sc_basis_total <= 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_NO_BASIS|%', v_run.code
              USING HINT = '投料量合计为零,按质量分摊没有可用的分母。';
        END IF;

        -- 【拒绝 4 与既有路径同一条】资本化分录被人工冲销 → 基准与总账已分道。
        IF v_run.capitalization_entry_id IS NOT NULL THEN
            SELECT status INTO v_cap_status FROM journal_entries WHERE id = v_run.capitalization_entry_id;
            IF v_cap_status <> 'posted' THEN
                RAISE EXCEPTION 'ALLOCATION_LEDGER_DIVERGED|%', v_run.code;
            END IF;
            -- 【重分摊 = 冲旧 + 重挂,而这在这里是安全的 —— 论证只在这里成立】
            -- FIN-24 禁止转化型这么做,是因为成本已顺着产出批流向已售份额,而已过账
            -- 的 COGS 从不重述。状态改变型【没有产出批】:成本停在 1200 上一批仍然
            -- 是原料的货上,没有任何下游把它当成本消费掉。若那批料后来被一张转化型
            -- 加工单吃掉,那张单会因【第七过期源】而过期,重跑即修正。
            PERFORM reverse_journal_entry_internal(v_run.capitalization_entry_id,
                reversal_date_for(v_run.capitalization_entry_id),
                'Re-allocation ' || v_run.code);
            UPDATE processing_runs
               SET capitalization_entry_id = NULL, capitalized_cost_base = 0
             WHERE id = p_run_id;
        END IF;

        -- ── 台账:先删后插(幂等)。按投料量拆,最大份额吸收进位余数 ────────────
        -- 【零成本不写行 —— 一面为零而举的旗,等于喊狼来了】fu3:载体行是
        -- 第七过期源。一张【一分钱成本都没有】的放电单若也写下载体行,
        -- 它会把吃过那批料的下游单标成过期 —— 而那张单要重跑出来的数
        -- 与它现在的数【一模一样】。本仓库对无条件举旗已有成文处置
        -- (fixture 54:含量没变就不举旗,"没人看的旗和没有旗是同一样东西")。
        -- 【先删仍然无条件执行】:300 → 0 的重分摊必须真的把那一行拿掉。
        DELETE FROM batch_processing_cost_allocations WHERE run_id = p_run_id;

        IF round(v_process, 2) <> 0 THEN
        WITH legs AS (
            SELECT pi.inbound_batch_id AS ib, SUM(pi.quantity_consumed) AS q
              FROM processing_inputs pi
             WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL
             GROUP BY pi.inbound_batch_id
        ),
        calc AS (
            SELECT ib, q,
                   round(v_process * q / v_sc_basis_total, 2) AS raw,
                   row_number() OVER (ORDER BY q DESC, ib) AS rn
              FROM legs
        ),
        adj AS (
            SELECT c.*, (round(v_process, 2) - SUM(c.raw) OVER ()) AS rem FROM calc c
        )
        INSERT INTO batch_processing_cost_allocations
            (run_id, inbound_batch_id, amount_base, basis_qty, basis_total_qty)
        SELECT p_run_id, ib, raw + CASE WHEN rn = 1 THEN rem ELSE 0 END, q, v_sc_basis_total
          FROM adj;
        END IF;

        SELECT jsonb_agg(jsonb_build_object(
                   'inbound_batch_id', a.inbound_batch_id,
                   'amount_base', a.amount_base,
                   'basis_qty', a.basis_qty)
               ORDER BY a.inbound_batch_id)
          INTO v_sc_rows
          FROM batch_processing_cost_allocations a WHERE a.run_id = p_run_id;

        -- ── 分录:借 1200 / 贷 5xxx —— 【重分类,不是新成本】────────────────────
        -- 电费在录入那一刻就已经进了总账(fin_journal_cost_entry:借 5110 / 贷 2200)。
        -- 这一步不新增任何金额,它把已经在 COGS 里的钱拨进存货。
        v_cap_lines := '[]'::jsonb;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
              FROM processing_cost_entries
             WHERE run_id = p_run_id AND deleted_at IS NULL
             GROUP BY cost_type
             ORDER BY cost_type
        LOOP
            IF v_ct.amt > 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type),
                    'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_ct.amt);
            ELSIF v_ct.amt < 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type),
                    'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', -v_ct.amt);
            END IF;
        END LOOP;

        v_cap_entry_id := NULL;
        IF round(v_process, 2) <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object(
                'account_code', '1200',
                'side', CASE WHEN v_process > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(round(v_process, 2)),
                'line_memo', 'capitalised onto input batch — state-changing run')) || v_cap_lines;
            v_cap_je := post_journal_entry(CURRENT_DATE, 'Capitalize ' || v_run.code,
                'allocation', p_run_id, v_cap_lines);
            v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
        END IF;

        -- 【快照】capitalized_by_source 只列各 cost_type,【故意没有 material 一项】——
        -- 材料没有被资本化(它早就在 1200 上了),写进去会让后来的人以为它进过账。
        v_by_source := '{}'::jsonb;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
              FROM processing_cost_entries
             WHERE run_id = p_run_id AND deleted_at IS NULL
             GROUP BY cost_type
        LOOP
            v_by_source := v_by_source || jsonb_build_object(v_ct.cost_type, v_ct.amt);
        END LOOP;

        UPDATE processing_runs
        SET material_cost_base   = round(v_material, 2),
            process_cost_base    = round(v_process, 2),
            total_cost_base      = round(v_total, 2),
            allocation_basis     = v_basis,
            allocation_snapshot  = jsonb_build_object(
                'capitalized_by_source', v_by_source,
                'capitalised_component', 'process_only',
                'capitalised_onto', 'input_batches',
                'destination_account', '1200',
                'basis', v_basis,
                'computed_at', now(),
                'inputs_without_price', v_inputs_without_price,
                'allocations', COALESCE(v_sc_rows, '[]'::jsonb)),
            allocated_at         = now(),
            allocated_by         = v_user,
            capitalized_cost_base   = round(v_process, 2),
            capitalization_entry_id = v_cap_entry_id,
            updated_at           = now(),
            updated_by           = v_user
        WHERE id = p_run_id;

        RETURN jsonb_build_object(
            'run_id', p_run_id,
            'basis', v_basis,
            'state_changing', true,
            'material_cost_base', round(v_material, 2),
            'process_cost_base', round(v_process, 2),
            'total_cost_base', round(v_total, 2),
            'capitalized_cost_base', round(v_process, 2),
            'capitalised_onto', COALESCE(v_sc_rows, '[]'::jsonb),
            'inputs_without_price', v_inputs_without_price,
            'outputs', '[]'::jsonb
        );
    END IF;

    -- 7. Basis totals. Metals without a usable price contribute 0 (LEFT JOIN + COALESCE)
    --    and are recorded in skipped_metals; only a zero grand total blocks (NO_METAL_VALUE).
    IF v_basis = 'metal_value' THEN
        -- METAL-2:分摊【没有交易可以继承指数】—— 一张加工单不是一笔谈定的买卖,
        -- 没有对手方、没有条款,所以它按 pricing_settings 的房屋约定取价。
        -- 【这是默认值在替一条缺席的条款站位,不是"这批成本按某个声明的指数结算了"】。
        -- 快照里一并记下用的是哪个指数,免得日后有人把它读成一条谈定的条款。
        SELECT default_metal_index INTO v_default_index FROM pricing_settings WHERE id;

        SELECT COALESCE(SUM(
                 po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0)
               ), 0)
          INTO v_total_metal_value
        FROM processing_outputs po
        JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
        LEFT JOIN LATERAL (
            SELECT mp.price_usd_per_tonne
            FROM metal_prices mp
            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
              AND mp.price_index IS NOT DISTINCT FROM v_default_index   -- METAL-2
              AND mp.price_date <= v_process_date
            ORDER BY mp.price_date DESC
            LIMIT 1
        ) pr ON true
        WHERE po.run_id = p_run_id;

        IF COALESCE(v_total_metal_value, 0) = 0 THEN
            RAISE EXCEPTION 'NO_METAL_VALUE';
        END IF;

        v_total_basis := v_total_metal_value;

        SELECT COALESCE(jsonb_agg(
                   jsonb_build_object('metal', metal,
                                      'price_usd_per_tonne', price_usd_per_tonne,
                                      'price_date', price_date)
                   ORDER BY metal), '[]'::jsonb)
          INTO v_prices_used
        FROM (
            SELECT DISTINCT ON (mp.metal) mp.metal, mp.price_usd_per_tonne, mp.price_date
            FROM metal_prices mp
            WHERE mp.deleted_at IS NULL AND mp.price_date <= v_process_date
              AND mp.price_index IS NOT DISTINCT FROM v_default_index   -- METAL-2
              AND mp.metal IN (
                  SELECT DISTINCT obm.metal
                  FROM processing_outputs po
                  JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
                  WHERE po.run_id = p_run_id AND obm.content_pct > 0
              )
            ORDER BY mp.metal, mp.price_date DESC
        ) q;

        -- Metals present (content > 0) on this run with NO usable price row: excluded from
        -- value (they contributed 0 above) and reported in the snapshot as skipped.
        SELECT COALESCE(jsonb_agg(m ORDER BY m), '[]'::jsonb)
          INTO v_skipped_metals
        FROM (
            SELECT DISTINCT obm.metal AS m
            FROM processing_outputs po
            JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
            WHERE po.run_id = p_run_id AND obm.content_pct > 0
              AND NOT EXISTS (
                  SELECT 1 FROM metal_prices mp
                  WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                    AND mp.price_date <= v_process_date
              )
        ) s;
    ELSE
        SELECT COALESCE(SUM(quantity_produced), 0) INTO v_total_basis
        FROM processing_outputs WHERE run_id = p_run_id;
        v_total_metal_value := NULL;
        v_prices_used := '[]'::jsonb;
        v_skipped_metals := '[]'::jsonb;
    END IF;

    -- FIN-24:差额法的"已记录"侧 —— 在下面的 UPDATE 改写之前,把各产出腿
    -- 当前的 allocated 拍下来。目标 − 已记录 = 应过账的差额(与重估/折旧同形)。
    SELECT COALESCE(jsonb_object_agg(po.output_batch_id::text,
                    COALESCE(po.allocated_cost_base, 0)), '{}'::jsonb)
      INTO v_prior
    FROM processing_outputs po WHERE po.run_id = p_run_id;

    -- 8 + 9. Allocate (largest-share row absorbs the rounding remainder), persist legs,
    --        and collect the per-output result — all in one statement.
    WITH legs AS (
        SELECT po.id AS leg_id, po.output_batch_id, po.quantity_produced,
               CASE WHEN v_basis = 'weight' THEN po.quantity_produced::numeric
                    ELSE COALESCE((
                        SELECT SUM(po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0))
                        FROM output_batch_metals obm
                        LEFT JOIN LATERAL (
                            SELECT mp.price_usd_per_tonne
                            FROM metal_prices mp
                            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                              AND mp.price_date <= v_process_date
                            ORDER BY mp.price_date DESC
                            LIMIT 1
                        ) pr ON true
                        WHERE obm.output_batch_id = po.output_batch_id
                    ), 0)
               END AS basis_value
        FROM processing_outputs po
        WHERE po.run_id = p_run_id
    ),
    calc AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               round(v_total * basis_value / NULLIF(v_total_basis, 0), 2) AS alloc_raw,
               row_number() OVER (ORDER BY basis_value DESC, leg_id) AS rn
        FROM legs
    ),
    adj AS (
        SELECT c.*, (round(v_total, 2) - SUM(alloc_raw) OVER ()) AS remainder
        FROM calc c
    ),
    final AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               alloc_raw + CASE WHEN rn = 1 THEN remainder ELSE 0 END AS allocated
        FROM adj
    ),
    upd AS (
        UPDATE processing_outputs po
        SET allocated_cost_base = f.allocated,
            unit_cost_base = round(f.allocated / f.quantity_produced, 4)
        FROM final f
        WHERE po.id = f.leg_id
        RETURNING f.output_batch_id, f.basis_value, f.allocated, po.unit_cost_base
    )
    SELECT jsonb_agg(
               jsonb_build_object(
                   'output_batch_id', output_batch_id,
                   'share', round(basis_value / NULLIF(v_total_basis, 0), 6),
                   'allocated_cost_base', allocated,
                   'unit_cost_base', unit_cost_base)
               ORDER BY output_batch_id),
           COALESCE(SUM(allocated), 0)
      INTO v_outputs, v_sum_alloc
    FROM upd;

    -- 9b. Snapshot + run header.
    -- FIN-24:by_source = 本次各来源的入账口径(材料 + 逐 cost_type,各 2 位),
    -- 下一次差额跑的"已记录"就从这里读 —— recorded,不再从分录反推。
    v_by_source := jsonb_build_object('material', round(v_material_in, 2));
    IF round(v_material_re, 2) <> 0 THEN
        -- 再加工材料单列一源:首挂贷 1220(解除上游产出),差额与 material 同贷 5000
        v_by_source := v_by_source || jsonb_build_object('material_reprocessed', round(v_material_re, 2));
    END IF;
    FOR v_ct IN
        SELECT cost_type, round(sum(amount_base), 2) AS amt
        FROM processing_cost_entries
        WHERE run_id = p_run_id AND deleted_at IS NULL
        GROUP BY cost_type
    LOOP
        v_by_source := v_by_source || jsonb_build_object(v_ct.cost_type, v_ct.amt);
    END LOOP;

    v_snapshot := jsonb_build_object(
        'capitalized_by_source', v_by_source,
        'basis', v_basis,
        'computed_at', now(),
        'inputs_without_price', v_inputs_without_price,
        'total_output_metal_value_usd',
            CASE WHEN v_basis = 'metal_value' THEN round(v_total_metal_value, 2) ELSE NULL END,
        'prices_used', v_prices_used,
        -- METAL-2:用的是哪个指数,以及它【是房屋约定而不是条款】。
        -- 读快照的人必须能分清这两件事:这批成本不是"按 LME 结算"的,
        -- 它是"在没有条款可循时,按当时的房屋约定取了 LME 的价"。
        'price_index', v_default_index,
        'price_index_is_house_default', true,
        'skipped_metals', v_skipped_metals
    );

    -- 9c(FIN-25):不完整成本标记 —— 任何投料无价、或上游产出自己就带着标记,
    --    本单全部产出打上 cost_incomplete。零永不静默,层层传染;上游补分摊后
    --    本单过期(状态视图第三支),重跑即清。
    UPDATE processing_outputs
    SET cost_incomplete = (v_inputs_without_price > 0 OR v_upstream_incomplete)
    WHERE run_id = p_run_id;

    -- FIN-36c:告诉基准触发器"这次基准变动是【跟着重分摊一起发生的】,不是漂移"。
    -- 与年结用 evoltrya.close_ctx 穿过期间锁是同一个惯用法(post_journal_entry)。
    -- 【为什么不靠时间戳判断】now() 是事务时间:同一个事务里两次分摊拿到相同的
    -- allocated_at,任何"看 allocated_at 变没变"的判据都会失效(fixture 就在一个
    -- 事务里跑)。显式的上下文标记不受事务边界影响。
    PERFORM set_config('evoltrya.alloc_ctx', '1', true);

    UPDATE processing_runs
    SET material_cost_base   = round(v_material, 2),
        process_cost_base    = round(v_process, 2),
        total_cost_base      = round(v_total, 2),
        allocation_basis    = v_basis,
        allocation_snapshot = v_snapshot,
        allocated_at        = now(),
        allocated_by        = v_user,
        updated_at          = now(),
        updated_by          = v_user
    WHERE id = p_run_id;

    -- 标记只覆盖上面那一条 UPDATE:同一事务里【之后】的裸改基准仍算漂移
    PERFORM set_config('evoltrya.alloc_ctx', '', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- 10a.【FIN-24:首挂全额,此后差额 —— 不再全额冲销重挂】
    -- 旧实现重述资本化(1220 按新价整体改写)而已过账 COGS 从不重述:卖掉份额的
    -- 价差留在库存里,卖得越多错得越多;材料价差贷 1200,而 reprice 早把已耗份额
    -- 记进了 5000 —— 两处叠加 = 重复计数 + 1200 变负(实测:100kg@1 全耗、重定价
    -- 到 2、重分摊 → 1220=200 但 5000 多挂 100、1200=−100)。
    -- 差额法(与重估/折旧同形):目标 − 已记录,只过差额,第二次跑为零。
    --   * 每个产出批按【自己】的处置比例拆(Part B:一炉多批、各卖各的):
    --       在库 + 已售未挂COGS → 1220(后者价值仍躺在 1220,10b 随后按新单位成本解除)
    --       已售已挂COGS       → 5000(COGS 补差)
    --       注销/盘亏           → 5200(处置在产出粒度可知,注销总额是运营信号,
    --                              不并进材料成本 —— Tim 的裁定,推翻了与 reprice
    --                              一致性的论证;reprice 在进料粒度分不出注销与
    --                              耗用、整体进 5000 的不精确,另记 known-issues)
    --   * 贷方:材料差额 → 5000(reprice 把已耗价差停在那里;5000 同时是 COGS
    --     科目,已售份额的借方与之同户恰好互抵 —— 这一巧合是本设计的支点);
    --     费用差额 → 各自成本科目(fin_cost_account)。
    --   * 产出批喂回再加工在 schema 上【不可表示】(processing_inputs 只指
    --     inbound_batches)—— 处置只有在库/已售/注销三种。粉线大概率多段加工,
    --     真建了再加工必须先扩这套拆分(known-issues 有账)。
    -- ════════════════════════════════════════════════════════════════════════
    v_rec_total := COALESCE(v_run.capitalized_cost_base, 0);
    IF v_run.capitalization_entry_id IS NOT NULL THEN
        SELECT status INTO v_cap_status FROM journal_entries WHERE id = v_run.capitalization_entry_id;
        IF v_cap_status <> 'posted' THEN
            -- 资本化分录被人工冲销:存量"已记录"与总账已分道,差额法的基准不再可信。
            -- 这是【唯一】剩下的红色情形:人工冲销是人做的决定,修复也该是人工分录。
            RAISE EXCEPTION 'ALLOCATION_LEDGER_DIVERGED|%', v_run.code;
        END IF;
    END IF;

    IF v_run.capitalization_entry_id IS NULL THEN
        -- ── 首挂:全额资本化(原路径)────────────────────────────────────────
        v_cap_lines := '[]'::jsonb;
        v_cap_total := 0;
        IF round(v_material_in, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', round(v_material_in, 2));
            v_cap_total := v_cap_total + round(v_material_in, 2);
        END IF;
        -- FIN-25:再加工材料 —— 解除的是上游产出的 1220,不是原料的 1200。
        -- 同科目 Dr(资本化进本单产出)/Cr(解除上游)两腿并存,净额即增量。
        IF round(v_material_re, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', round(v_material_re, 2), 'line_memo', 're-processed input relieved');
            v_cap_total := v_cap_total + round(v_material_re, 2);
        END IF;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
            FROM processing_cost_entries
            WHERE run_id = p_run_id AND deleted_at IS NULL
            GROUP BY cost_type
            ORDER BY cost_type
        LOOP
            IF v_ct.amt > 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            ELSIF v_ct.amt < 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', -v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            END IF;
        END LOOP;

        v_cap_entry_id := NULL;
        IF v_cap_total <> 0 THEN
            v_cap_lines := jsonb_build_array(
                jsonb_build_object('account_code', '1220',
                                   'side', CASE WHEN v_cap_total > 0 THEN 'debit' ELSE 'credit' END,
                                   'currency', base_currency_code(), 'amount_ccy', abs(v_cap_total))
            ) || v_cap_lines;
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Capitalize ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = v_cap_total,
            capitalization_entry_id = v_cap_entry_id
        WHERE id = p_run_id;
    ELSE
        -- ── 差额路径 ─────────────────────────────────────────────────────────
        -- 已记录的各来源:优先 snapshot(FIN-24 起写入);老单从已过账的资本化
        -- 分录行反推 —— 1200 行 = 材料,5xxx 行按 fin_cost_account 的反向映射。
        v_rec_src := v_run.allocation_snapshot->'capitalized_by_source';
        IF v_rec_src IS NULL THEN
            SELECT COALESCE(jsonb_object_agg(q.src, q.amt), '{}'::jsonb) INTO v_rec_src FROM (
                SELECT CASE a.code
                           WHEN '1200' THEN 'material'
                           WHEN '5100' THEN 'labour'
                           WHEN '5110' THEN 'electricity'
                           WHEN '5120' THEN 'gas'
                           WHEN '5130' THEN 'depreciation'
                           WHEN '5140' THEN 'consumables'
                           WHEN '5150' THEN 'waste_treatment'
                           WHEN '5190' THEN 'other'
                       END AS src,
                       round(SUM(jl.credit) - SUM(jl.debit), 2) AS amt
                FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
                WHERE jl.entry_id = v_run.capitalization_entry_id AND a.code <> '1220'
                GROUP BY a.code) q
            WHERE q.src IS NOT NULL;
        END IF;

        -- 贷方:逐来源差额。材料 → 5000(不是 1200!—— reprice 已把已耗价差记在
        -- 5000,这里把属于未售产出的部分从 5000 拨进 1220,双方不再叠加);
        -- 费用 → 各自成本科目。负差翻借方。
        v_cap_lines := '[]'::jsonb;
        v_cred_total := 0;
        FOR v_ct IN
            SELECT key AS src, (v_by_source->>key)::numeric - COALESCE((v_rec_src->>key)::numeric, 0) AS d
            FROM jsonb_object_keys(v_by_source) AS key
            UNION
            SELECT key, 0 - (v_rec_src->>key)::numeric
            FROM jsonb_object_keys(v_rec_src) AS key
            WHERE v_by_source->>key IS NULL
            ORDER BY 1
        LOOP
            IF v_ct.d <> 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object(
                    'account_code', CASE WHEN v_ct.src IN ('material', 'material_reprocessed') THEN '5000' ELSE fin_cost_account(v_ct.src) END,
                    'side', CASE WHEN v_ct.d > 0 THEN 'credit' ELSE 'debit' END,
                    'currency', base_currency_code(), 'amount_ccy', abs(v_ct.d),
                    'line_memo', 'allocation delta: ' || v_ct.src);
                v_cred_total := v_cred_total + v_ct.d;
            END IF;
        END LOOP;

        -- 借方:逐产出批的差额,按该批自己的处置比例拆
        FOR v_leg IN
            SELECT po.output_batch_id, po.quantity_produced AS qty,
                   po.allocated_cost_base AS new_alloc,
                   COALESCE((v_prior->>po.output_batch_id::text)::numeric, 0) AS old_alloc,
                   ob.remaining_qty,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NOT NULL), 0) AS sold_cogs,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NULL), 0) AS sold_nocogs,
                   -- FIN-25 第四处置:被下游加工消耗的份额 → 5000 停车
                   --(与 reprice 对已耗进料完全同构:下游过期后重跑,其材料差额
                   -- 贷 5000 收回停车 —— 传导靠既有过期旗逐级走,不递归)
                   COALESCE((SELECT SUM(pi2.quantity_consumed) FROM processing_inputs pi2
                             WHERE pi2.output_batch_id = po.output_batch_id), 0) AS consumed_proc
            FROM processing_outputs po
            JOIN output_batches ob ON ob.id = po.output_batch_id
            WHERE po.run_id = p_run_id
        LOOP
            v_delta := round(v_leg.new_alloc - v_leg.old_alloc, 2);
            IF v_delta = 0 OR v_leg.qty = 0 THEN CONTINUE; END IF;
            v_other := GREATEST(0, v_leg.qty - v_leg.remaining_qty - v_leg.sold_cogs - v_leg.sold_nocogs - v_leg.consumed_proc);
            v_l1220 := round(v_delta * (v_leg.remaining_qty + v_leg.sold_nocogs) / v_leg.qty, 2);
            v_l5000 := round(v_delta * (v_leg.sold_cogs + v_leg.consumed_proc) / v_leg.qty, 2);
            -- 5200 取残差,保证三桶之和恰等于该批差额
            v_d1220 := v_d1220 + v_l1220;
            v_d5000 := v_d5000 + v_l5000;
            v_d5200 := v_d5200 + (v_delta - v_l1220 - v_l5000);
        END LOOP;

        -- 强制配平:Σ借(三桶)与 Σ贷(逐来源)各自取整后可差一两分 ——
        -- 差额并进 1220 桶(金额最大、且是"目标状态"侧,与 8+9 步的
        -- largest-share-absorbs 同一习惯)。
        v_deb_total := v_d1220 + v_d5000 + v_d5200;
        v_d1220 := v_d1220 + round(v_cred_total - v_deb_total, 2);

        IF v_d1220 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '1220',
                'side', CASE WHEN v_d1220 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d1220),
                'line_memo', 'in-stock share')) || v_cap_lines;
        END IF;
        IF v_d5000 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5000',
                'side', CASE WHEN v_d5000 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d5000),
                'line_memo', 'sold/consumed share — COGS catch-up / re-processing park')) || v_cap_lines;
        END IF;
        IF v_d5200 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5200',
                'side', CASE WHEN v_d5200 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d5200),
                'line_memo', 'written-off share')) || v_cap_lines;
        END IF;

        -- 幂等出口:没有任何差额 → 不过账(allocated_at 照常刷新,过期标记消除)
        IF jsonb_array_length(v_cap_lines) > 0 THEN
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Re-allocation delta ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            -- 差额分录记进 snapshot 的留痕数组;capitalization_entry_id 仍指首挂
            v_snapshot := v_snapshot || jsonb_build_object('delta_entry_ids',
                COALESCE(v_run.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)
                    || to_jsonb((v_cap_je->>'entry_id')::text));
            UPDATE processing_runs SET allocation_snapshot = v_snapshot WHERE id = p_run_id;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = round(v_rec_total + v_cred_total, 2)
        WHERE id = p_run_id;
    END IF;

    -- 10b. cut 2a:COGS 补挂 —— 只补此前无 COGS 分录的销售(cogs_entry_id IS NULL),
    --      用最新 unit_cost_base,按各自原 sale_date(撞期间锁则 PERIOD_LOCKED 直接抛出)。
    --      已挂 COGS 不追溯重述(标准成本式简化;重述属人工冲销决策)。
    FOR v_sale IN
        SELECT sr.id, sr.quantity, sr.sale_date, ob.code AS batch_code, po.unit_cost_base
        FROM sales_records sr
        JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = p_run_id
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        WHERE sr.cogs_entry_id IS NULL
        ORDER BY sr.sale_date, sr.created_at
    LOOP
        v_cogs := round(v_sale.quantity * v_sale.unit_cost_base, 2);
        IF v_cogs <> 0 THEN
            v_cogs_je := post_journal_entry(
                v_sale.sale_date,
                'COGS ' || v_sale.batch_code,
                'sale', v_sale.id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_cogs_je->>'entry_id')::uuid WHERE id = v_sale.id;
        END IF;
    END LOOP;

    -- 10. Return.
    RETURN jsonb_build_object(
        'run_id', p_run_id,
        'basis', v_basis,
        'material_cost_base', round(v_material, 2),
        'process_cost_base', round(v_process, 2),
        'total_cost_base', round(v_total, 2),
        'inputs_without_price', v_inputs_without_price,
        'outputs', COALESCE(v_outputs, '[]'::jsonb)
    );
END;
$function$;

-- db/functions/guard_assay_applied_columns.sql
-- ROLE-1 · Batch 2b(Batch 2 grilling Q15 · Batch 2b grilling Q4):**应用化验结果只归 cto**
-- (action.apply_assay),记录化验结果仍归 module.inbound.edit / module.output.edit。
--
-- 【为什么需要一支守卫】assay_results 的写策略仍开在 inbound.edit / output.edit 上(记录结果
-- 的人要写它),于是一个持这两个码的人可以不经 apply_assay_result / apply_output_assay /
-- unapply_assay_result,直接把 applied_at / applied_by / superseded_by 写成"已应用"或"已撤销"——
-- 批次不重算价、含量不抄,但屏幕与提醒会把它当成应用过。本守卫把这三列收成只走函数:
--   · 直连 INSERT 带着其中任何一列(非 NULL)→ ASSAY_APPLY_THROUGH_FUNCTION_ONLY;
--   · 直连 UPDATE 改动其中任何一列(IS DISTINCT FROM)→ 同上;
--   · 别的列(备注、实验室、证书号……)照旧归记录的人。
-- 三支函数都是 SECURITY DEFINER,row_security_active = false,本守卫看不见它们。
--
-- ★ ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q10):**is_final 也只走函数**。
--   is_final 只在 record_assay_result(SECURITY DEFINER)里随那一行生下来;没有任何屏幕改它。
--   4b 起收货的 pricing_status 在 CFO 批准一张化验来源的申请时、且那份化验 is_final 才升 final,
--   而批准时读的是【那一刻】的 is_final(指纹里没有它)—— 直连改它就能左右批准之后是不是 final
--   (ROLE1B4B-ASSAY-IS-FINAL-DIRECT-EDIT)。直连 UPDATE 改它 → ASSAY_FINAL_THROUGH_FUNCTION_ONLY,
--   进料与产出两侧一律。记错了的正式标记,改法是录一份新化验取代旧的,不是改旧的。
--   直连 INSERT 带什么 is_final 都放行:一行没应用的化验,标记还不左右任何东西。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径;理由见 guard_lock_reopen_path 的抬头。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2b-contracts-prices-direct-sale-and-assay.sql.

CREATE OR REPLACE FUNCTION public.guard_assay_applied_columns()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.applied_at IS NOT NULL OR NEW.applied_by IS NOT NULL OR NEW.superseded_by IS NOT NULL THEN
            RAISE EXCEPTION 'ASSAY_APPLY_THROUGH_FUNCTION_ONLY';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.applied_at IS DISTINCT FROM OLD.applied_at
       OR NEW.applied_by IS DISTINCT FROM OLD.applied_by
       OR NEW.superseded_by IS DISTINCT FROM OLD.superseded_by THEN
        RAISE EXCEPTION 'ASSAY_APPLY_THROUGH_FUNCTION_ONLY';
    END IF;
    IF NEW.is_final IS DISTINCT FROM OLD.is_final THEN
        RAISE EXCEPTION 'ASSAY_FINAL_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_assay_applied_columns() IS
'ROLE-1 Batch 2b:直连写(row_security_active)改动 assay_results.applied_at / applied_by / superseded_by,或直连 INSERT 带着其中任何一列,按名拒 ASSAY_APPLY_THROUGH_FUNCTION_ONLY;直连 UPDATE 改 is_final 按名拒 ASSAY_FINAL_THROUGH_FUNCTION_ONLY(ROLE-1 Batch 3a)—— 应用与撤销应用只走 apply_assay_result / apply_output_assay / unapply_assay_result(action.apply_assay,cto)。记录结果的其余列照旧。INVOKER,以分出直连写与属主路径。';

-- db/functions/guard_inbound_batch_price_request.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q5 · Q3):收货表头上两道闸。
--
-- ① 【一张定价申请在等的时候,它批的那几样东西不许动】(Q5)
--    供应商、采购单、采购行被改,或收货被注销(deleted_at 由空变有)→
--    RECEIPT_PRICE_REQUEST_OPEN|收货|那一张申请。
--    ★ 这一道【不分直连写与属主路径】:注销走的是 soft_delete_inbound_batch(SECURITY DEFINER),
--      它自己也按名拒一次;这里是第二道 —— 将来哪一支属主函数改了供应商,照样撞上。
--    数量与含量由指纹在批准时再比(RECEIPT_PRICE_CHANGED_SINCE_REQUEST);含量的直连写另由
--    guard_inbound_batch_metals_price_request 当场拒。
-- ② 【pricing_status 只经函数写】(Q3)
--    直连写(row_security_active)改 pricing_status → PRICING_STATUS_VIA_FUNCTION|收货。
--    Step 0 实测:任何持 module.inbound.edit 的人都能直接把一张收货写成 final,而 Q3 的
--    「final 只在 CFO 批准时置」没有这一道就只是一句话。属主路径(批准那一支)看不见本守卫。
--
-- ③ 【一张已定价的收货,供应商 / 采购单 / 采购行永远不许再换】(ROLE-1 Batch 3a,Tim 2026-09-25,
--    Batch 3 grilling Q11 · ROLE1B4A-RECEIPT-SUPPLIER-CHANGE-AFTER-PRICING)
--    unit_price 不为空 = 已定价(ap_open_items 就按它收这张收货)。应付挂在 inbound_batches.supplier_id
--    名下、分录行上没有往来方 —— 换供应商会把一笔应付【悄悄】搬到另一家名下,已付的钱(A 付的)留在
--    一张现在属于 B 的收货上;换采购行会换掉下一次改价用的承诺条款。→ RECEIPT_PRICED_SOURCE_FROZEN|收货。
--    ★ 不分直连写与属主路径:今天没有一支属主函数改这三列(Step 0 量过);将来哪一支改了,照样撞上。
--    ★ 在等的申请那一句(①)先判:它说得更具体。
--    ★ 代价,照直说:一张供应商记错了的已定价收货【今天没有更正的路】—— 注销在有未付应付时也拒
--      (INBOUND_HAS_OPEN_PAYABLE)。更正的生命周期登记为以后的事(Tim 的 Q11)。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径(②);在不在等由 receipt_price_open(DEFINER)问
-- —— 不持采购价码的写入者在 INVOKER 里读不到申请表,会把"看不见"读成"没有申请"。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_inbound_batch_price_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_open text;
BEGIN
    IF NEW.supplier_id IS DISTINCT FROM OLD.supplier_id
       OR NEW.purchase_order_id IS DISTINCT FROM OLD.purchase_order_id
       OR NEW.purchase_order_line_id IS DISTINCT FROM OLD.purchase_order_line_id
       OR (NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL) THEN
        v_open := receipt_price_open(OLD.id);
        IF v_open IS NOT NULL THEN
            RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_OPEN|%|%', OLD.code, v_open;
        END IF;
    END IF;
    IF OLD.unit_price IS NOT NULL
       AND (NEW.supplier_id IS DISTINCT FROM OLD.supplier_id
            OR NEW.purchase_order_id IS DISTINCT FROM OLD.purchase_order_id
            OR NEW.purchase_order_line_id IS DISTINCT FROM OLD.purchase_order_line_id) THEN
        RAISE EXCEPTION 'RECEIPT_PRICED_SOURCE_FROZEN|%', OLD.code;
    END IF;
    IF NEW.pricing_status IS DISTINCT FROM OLD.pricing_status AND row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'PRICING_STATUS_VIA_FUNCTION|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_inbound_batch_price_request() IS
'ROLE-1 Batch 4b:① 一张收货挂着在等的定价申请时,改供应商 / 采购单 / 采购行或注销它,按名拒 RECEIPT_PRICE_REQUEST_OPEN|收货|申请(不分直连与属主路径);② 直连写(row_security_active)改 pricing_status,按名拒 PRICING_STATUS_VIA_FUNCTION|收货 —— final 只在 CFO 批准化验来源的申请时置(Tim 的 Q3);③ 已定价的收货改供应商 / 采购单 / 采购行,按名拒 RECEIPT_PRICED_SOURCE_FROZEN|收货(ROLE-1 Batch 3a,不分直连与属主路径)。INVOKER;在不在等经 receipt_price_open(DEFINER)问。';

-- db/functions/submit_payroll_request.sql
-- PAYROLL-APR-1(2026-09-24):提一张工资申请 —— 过账(post)或撤销过账(reversal)。
--
-- Tim 的矩阵 §5:财务提(module.hr.edit —— 工资期本来就归这个码),CFO 批每一张、不分档。
--   · post     —— 期间必须是 draft、有行;
--   · reversal —— 期间必须是 posted;理由必填(PAYROLL_REVERSAL_REASON_REQUIRED),
--                 审批人读的就是它,执行时它也是撤销分录上的那一句。
--   · 一个期间同时只挂一张未了结的申请(PAYROLL_REQUEST_OPEN;唯一索引是第二道)。
--   · snapshot = payroll_period_fingerprint:批的那一组数(grilling Q4)。
--   · 提交时照执行那一刻的同一支引擎试跑一遍(payroll_request_dry_run,grilling Q7)——
--     考勤没做齐、期间已锁、已付过钱,这里就按引擎的原话拒,而不是等 CFO 批完才撞上。
--
-- 【审批关着时】生下来就是 approved,留痕 auto_approved —— 没有人按过批准,留痕就不许说有人按过
-- (采购单与付款申请同形,PAY-REQ-1 的 Q8)。
-- 【主角】工资期是公司的单据(Tim 的 Q1 (A)):留痕的主角为 NULL,见 payroll_requests 抬头。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.submit_payroll_request(p_payroll_period_id uuid, p_kind text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p     payroll_periods%ROWTYPE;
    v_id    uuid := gen_random_uuid();
    v_on    boolean := approvals_enabled();
    v_label text;
    v_n     integer;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_p FROM payroll_periods
     WHERE id = p_payroll_period_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;

    IF p_kind = 'post' THEN
        IF v_p.status = 'posted' THEN
            RAISE EXCEPTION 'PAYROLL_ALREADY_POSTED|%', v_p.code;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM payroll_lines WHERE payroll_period_id = p_payroll_period_id) THEN
            RAISE EXCEPTION 'NO_LINES';
        END IF;
    ELSIF p_kind = 'reversal' THEN
        IF v_p.status <> 'posted' THEN
            RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
        END IF;
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'PAYROLL_REVERSAL_REASON_REQUIRED|%', v_p.code;
        END IF;
    ELSE
        RAISE EXCEPTION 'PAYROLL_REQUEST_KIND_UNKNOWN|%|%', v_p.code, COALESCE(p_kind, '?');
    END IF;

    IF EXISTS (SELECT 1 FROM payroll_requests r
                WHERE r.payroll_period_id = p_payroll_period_id AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_OPEN|%', v_p.code;
    END IF;

    -- ★ ROLE-1 Batch 3a(Q12):提单人之外没人批得动 → 按名拒(审批关着时不拒)。
    PERFORM assert_other_decider('payroll_request', 'decide_payroll_request', 2::smallint,
                                 'PAYROLL_NO_OTHER_DECIDER|' || v_p.code);

    SELECT count(*) + 1 INTO v_n FROM payroll_requests
     WHERE payroll_period_id = p_payroll_period_id AND kind = p_kind;
    v_label := v_p.code || ' · ' || p_kind || ' #' || v_n::text;

    INSERT INTO payroll_requests (id, payroll_period_id, kind, status, label, snapshot,
                                  currency, fx_rate, gross_total, amount_base, notes, created_by)
    VALUES (v_id, p_payroll_period_id, p_kind,
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            v_label, payroll_period_fingerprint(p_payroll_period_id),
            v_p.currency, v_p.fx_rate, v_p.gross_total, round(v_p.gross_total * v_p.fx_rate, 2),
            NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid());

    PERFORM payroll_request_dry_run(v_id);

    IF v_on THEN
        PERFORM record_approval_decision('payroll_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payroll_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'label', v_label,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END);
END;
$function$
;

-- db/functions/submit_payment_request.sql
-- PAY-REQ-1(2026-09-23):提一张【出款】申请。参数与 record_payment 同一组
-- (日期那一格是【计划】付款日;真正的付款日在付款那一步给)。
--
-- 顺序:权限 → 必填 → 这一笔真的需要申请吗 → 收款人没被拉黑/暂停 → 单据没挂在别的
-- 未了结申请上 → 落一行 → 按引擎试跑一遍(不合规矩就在这里按原话拒,而不是等 CFO 批完、
-- 付款时才拒)→ 按审批开关定状态、写留痕。
--
-- 【豁免的那一种不许走申请】payment_request_required 说 false 的出款(Q1:整笔付已批准
-- 的报销 / 医疗申报)按名拒 PAYMENT_REQUEST_NOT_REQUIRED —— 为一笔 Tim 明说不批的钱
-- 去排 CFO 的队,是让他签一个没有理由改的数。页面问的是同一支判据,所以正常走不到这里。
--
-- 【审批关着时】生下来就是 approved,留痕 auto_approved(Tim 的 Q8,与采购单同形):
-- 那条路上确实没有任何人按过"批准"。路径只有一条:申请 → 付款。
--
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.submit_payment_request(p_counterparty_id uuid, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_bank_account text DEFAULT NULL::text, p_planned_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_allocations jsonb DEFAULT '[]'::jsonb, p_counterparty_kind text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_kind     text;
    v_id       uuid := gen_random_uuid();
    v_code     text;
    v_conflict text;
    v_res      jsonb;
    v_on       boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');

    IF p_planned_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    v_kind := COALESCE(NULLIF(btrim(p_counterparty_kind), ''), 'supplier');
    IF v_kind NOT IN ('supplier', 'employee') THEN
        RAISE EXCEPTION 'COUNTERPARTY_KIND_INVALID|out|%', v_kind;
    END IF;
    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' THEN
        RAISE EXCEPTION 'ALLOC_INVALID|not_an_array';
    END IF;

    IF NOT payment_request_required('out', v_kind, p_counterparty_id, p_amount, p_currency, p_allocations) THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_NOT_REQUIRED'
          USING HINT = '整笔付已批准的报销 / 医疗申报,直接记付款,不走申请(PAY-REQ-1 Q1)';
    END IF;

    IF v_kind = 'supplier' THEN
        PERFORM payment_request_payee_check('payment_out', p_counterparty_id);
    END IF;

    v_conflict := payment_request_conflict(p_allocations, NULL);
    IF v_conflict IS NOT NULL THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_TARGET_RESERVED|%', v_conflict;
    END IF;

    -- ★ ROLE-1 Batch 3a(Q12):提单人之外没人批得动 → 按名拒(审批关着时不拒)。先于取号:拒了不烧号。
    PERFORM assert_other_decider('payment_request', 'decide_payment_request', 2::smallint,
                                 'PAYMENT_REQUEST_NO_OTHER_DECIDER');
    v_code := next_payment_request_code(p_planned_date);
    -- amount_base 先落 0、试跑之后立刻改成引擎算出来的数 —— 试跑按 id 读这一行,
    -- 所以行要先在;同一个事务里,没有任何人看得见那个 0。
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  supplier_id, employee_id, amount_ccy, currency, amount_base,
                                  fx_rate, bank_account_code, planned_date, allocations, notes,
                                  created_by)
    VALUES (v_id, v_code, 'payment_out',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            v_kind,
            CASE WHEN v_kind = 'supplier' THEN p_counterparty_id END,
            CASE WHEN v_kind = 'employee' THEN p_counterparty_id END,
            p_amount, p_currency, 0, p_fx_rate, NULLIF(btrim(COALESCE(p_bank_account, '')), ''),
            p_planned_date, p_allocations, NULLIF(btrim(COALESCE(p_notes, '')), ''),
            auth.uid());

    v_res := payment_request_dry_run(v_id);
    UPDATE payment_requests SET amount_base = (v_res->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('payment_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payment_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'code', v_code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
                              'amount_base', (v_res->>'amount_base')::numeric);
END;
$function$
;

-- db/functions/submit_payment_reversal_request.sql
-- PAY-REQ-1(2026-09-23,Tim 的 Q6):提一张【冲销】申请 —— 收款或出款都算。
-- 理由必填(它就是审批人要读的那一句,也是冲销分录上的备注)。
-- 同一笔付款同时只能有一张未了结的冲销申请(payment_requests_one_open_reversal)。
-- 提交时照 reverse_payment_internal 试跑一遍:已冲销、期间锁这些在这里就按原话拒。
--
-- 【审批关着时】生下来就是 approved,留痕 auto_approved —— 与出款申请同一条(Q8)。
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.submit_payment_reversal_request(p_payment_id uuid, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p    payments%ROWTYPE;
    v_id   uuid := gen_random_uuid();
    v_code text;
    v_on   boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_p FROM payments WHERE id = p_payment_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_NOT_FOUND|%', COALESCE(p_payment_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' OR v_p.reversed_by_payment IS NOT NULL THEN
        RAISE EXCEPTION 'PAYMENT_ALREADY_REVERSED|%', v_p.code;
    END IF;
    IF p_notes IS NULL OR btrim(p_notes) = '' THEN
        RAISE EXCEPTION 'PAYMENT_REVERSAL_REASON_REQUIRED|%', v_p.code;
    END IF;
    IF EXISTS (SELECT 1 FROM payment_requests r
                WHERE r.payment_id = p_payment_id AND r.kind = 'payment_reversal'
                  AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'PAYMENT_REVERSAL_ALREADY_REQUESTED|%', v_p.code;
    END IF;

    -- ★ ROLE-1 Batch 3a(Q12):提单人之外没人批得动 → 按名拒(审批关着时不拒)。先于取号:拒了不烧号。
    PERFORM assert_other_decider('payment_request', 'decide_payment_request', 2::smallint,
                                 'PAYMENT_REQUEST_NO_OTHER_DECIDER');
    v_code := next_payment_request_code(CURRENT_DATE);
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  supplier_id, employee_id, customer_id,
                                  amount_ccy, currency, amount_base, fx_rate, bank_account_code,
                                  payment_id, notes, created_by)
    VALUES (v_id, v_code, 'payment_reversal',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            v_p.counterparty_type, v_p.supplier_id, v_p.employee_id, v_p.customer_id,
            v_p.amount_ccy, v_p.currency, v_p.amount_base, NULL, v_p.bank_account_code,
            p_payment_id, btrim(p_notes), auth.uid());

    PERFORM payment_request_dry_run(v_id);

    IF v_on THEN
        PERFORM record_approval_decision('payment_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payment_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'code', v_code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END);
END;
$function$
;

-- db/functions/submit_bank_transfer_request.sql
-- PAY-REQ-1 · Batch B(2026-09-23,Tim 的 Q15):提一张【行内转账】申请。
-- 参数与 record_bank_transfer 同一组(日期那一格是【计划】转账日;真正的转账日在执行那一步给)。
--
-- 顺序:权限 → 必填 → 落一行 → 按引擎试跑一遍(同币种金额不等、同一个账户、期间锁……
-- 都在这里按原话拒)→ 本位币额取试跑那张分录的借方合计 → 按审批开关定状态、写留痕。
-- 批的是冻结的那组:两个账户、两边金额、参考号;执行时一个字都改不了。
--
-- 【没有收款人】转账是两个自家账户之间挪钱,counterparty_type 为 NULL(表的形状约束允许
-- 且只允许这四种新申请这样)。付款的那道"收款人被拉黑/暂停"检查于是不适用。
--
-- 【审批关着时】生下来就是 approved,留痕 auto_approved —— 与出款申请同一条(Batch A 的 Q8)。
-- NOTE: introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.submit_bank_transfer_request(p_planned_date date, p_from_account text, p_to_account text, p_amount_out numeric, p_amount_in numeric, p_bank_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id   uuid := gen_random_uuid();
    v_code text;
    v_res  jsonb;
    v_on   boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');

    IF p_planned_date IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;
    IF p_from_account IS NULL OR p_from_account NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_from_account, '?');
    END IF;
    IF p_to_account IS NULL OR p_to_account NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_to_account, '?');
    END IF;
    IF p_amount_out IS NULL OR p_amount_out <= 0 OR p_amount_in IS NULL OR p_amount_in <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;

    -- ★ ROLE-1 Batch 3a(Q12):提单人之外没人批得动 → 按名拒(审批关着时不拒)。先于取号:拒了不烧号。
    PERFORM assert_other_decider('payment_request', 'decide_payment_request', 2::smallint,
                                 'PAYMENT_REQUEST_NO_OTHER_DECIDER');
    v_code := next_payment_request_code(p_planned_date);
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  amount_ccy, currency, amount_base, bank_account_code,
                                  to_account_code, amount_in, bank_reference,
                                  planned_date, notes, created_by)
    VALUES (v_id, v_code, 'bank_transfer',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            NULL,
            p_amount_out, bank_native_currency(p_from_account), 0, p_from_account,
            p_to_account, p_amount_in, NULLIF(btrim(COALESCE(p_bank_reference, '')), ''),
            p_planned_date, NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid());

    v_res := payment_request_dry_run(v_id);
    UPDATE payment_requests SET amount_base = (v_res->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('payment_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payment_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'code', v_code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
                              'amount_base', (v_res->>'amount_base')::numeric);
END;
$function$
;

-- db/functions/submit_bank_transfer_reversal_request.sql
-- PAY-REQ-1 · Batch B(2026-09-23,Tim 的 Q4):提一张【转账冲销】申请。
-- 理由必填(它就是审批人要读的那一句,也是冲销分录上的备注)。冲销日在执行那一步给(必填)。
-- 同一笔转账同时只能有一张未了结的冲销申请(payment_requests_one_open_transfer_reversal)。
-- 金额、两个账户从原转账【抄过来】,只供审批人看;执行时引擎照原分录逐行翻边。
-- 提交时试跑一遍:已冲销、期间锁这些在这里就按原话拒。
-- NOTE: introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.submit_bank_transfer_reversal_request(p_transfer_id uuid, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t    bank_transfers%ROWTYPE;
    v_id   uuid := gen_random_uuid();
    v_code text;
    v_res  jsonb;
    v_on   boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_t FROM bank_transfers WHERE id = p_transfer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_NOT_FOUND|%', COALESCE(p_transfer_id::text, '?');
    END IF;
    IF v_t.reversed_at IS NOT NULL THEN
        RAISE EXCEPTION 'TRANSFER_ALREADY_REVERSED|%', p_transfer_id;
    END IF;
    IF p_notes IS NULL OR btrim(p_notes) = '' THEN
        RAISE EXCEPTION 'REVERSAL_REASON_REQUIRED';
    END IF;
    IF EXISTS (SELECT 1 FROM payment_requests r
                WHERE r.transfer_id = p_transfer_id AND r.kind = 'bank_transfer_reversal'
                  AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'TRANSFER_REVERSAL_ALREADY_REQUESTED|%', p_transfer_id;
    END IF;

    -- ★ ROLE-1 Batch 3a(Q12):提单人之外没人批得动 → 按名拒(审批关着时不拒)。先于取号:拒了不烧号。
    PERFORM assert_other_decider('payment_request', 'decide_payment_request', 2::smallint,
                                 'PAYMENT_REQUEST_NO_OTHER_DECIDER');
    v_code := next_payment_request_code(CURRENT_DATE);
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  amount_ccy, currency, amount_base, bank_account_code,
                                  to_account_code, amount_in, bank_reference,
                                  transfer_id, notes, created_by)
    VALUES (v_id, v_code, 'bank_transfer_reversal',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            NULL,
            v_t.amount_out, bank_native_currency(v_t.from_account), 0, v_t.from_account,
            v_t.to_account, v_t.amount_in, v_t.bank_reference,
            p_transfer_id, btrim(p_notes), auth.uid());

    v_res := payment_request_dry_run(v_id);
    UPDATE payment_requests SET amount_base = (v_res->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('payment_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payment_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'code', v_code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END);
END;
$function$
;

-- db/functions/submit_wht_remittance_request.sql
-- PAY-REQ-1 · Batch B(2026-09-23,Tim 的 Q15):提一张【代扣税缴纳】申请。
--
-- ★【金额是推导出来的,申请冻结的是提交那一刻的数】欠多少从 wht_liability_by_month 读
--   (与 remit_wht_internal 读同一张视图 —— 不在这里另算一份)。CFO 批的就是这个数;
--   执行时推导值变了,remit_wht_internal 按名拒 WHT_REMIT_AMOUNT_CHANGED。
-- ★ 同一个代扣月同时只能有一张未了结的缴纳申请(payment_requests_one_open_wht_month):
--   两张各自都试跑得过、合起来汇两遍,是试跑看不见的(试跑只看已过账的缴纳)。
--
-- 参考号必填、银行默认 1000 且必须是本位币户 —— 与 remit_wht 同一组规矩,由试跑按原话拒。
-- 两道权限检查与 remit_wht 同形:edit,以及读那张视图要的 view(WHT-1 fu1)。
-- 日期与参考号的 DEFAULT NULL 与 remit_wht 同一条:页面空着就【不传】,由这里按名拒
-- (WHT_REMIT_DATE_REQUIRED / WHT_FILED_REFERENCE_REQUIRED)—— 不是一个默认值。
-- NOTE: introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.submit_wht_remittance_request(p_period_month date, p_planned_date date DEFAULT NULL::date, p_filed_reference text DEFAULT NULL::text, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_month  date;
    v_ref    text;
    v_amount numeric;
    v_id     uuid := gen_random_uuid();
    v_code   text;
    v_res    jsonb;
    v_on     boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');
    PERFORM require_permission('module.finance.view');

    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'WHT_PERIOD_REQUIRED';
    END IF;
    v_month := date_trunc('month', p_period_month)::date;
    IF p_planned_date IS NULL THEN
        RAISE EXCEPTION 'WHT_REMIT_DATE_REQUIRED|%', v_month;
    END IF;
    v_ref := NULLIF(btrim(COALESCE(p_filed_reference, '')), '');
    IF v_ref IS NULL THEN
        RAISE EXCEPTION 'WHT_FILED_REFERENCE_REQUIRED|%', v_month;
    END IF;
    IF EXISTS (SELECT 1 FROM payment_requests r
                WHERE r.period_month = v_month AND r.kind = 'wht_remittance'
                  AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_ALREADY_REQUESTED|%', v_month;
    END IF;

    SELECT unremitted_base INTO v_amount FROM wht_liability_by_month WHERE period_month = v_month;
    IF COALESCE(v_amount, 0) <= 0 THEN
        RAISE EXCEPTION 'WHT_NOTHING_TO_REMIT|%|%', v_month, COALESCE(v_amount, 0);
    END IF;

    -- ★ ROLE-1 Batch 3a(Q12):提单人之外没人批得动 → 按名拒(审批关着时不拒)。先于取号:拒了不烧号。
    PERFORM assert_other_decider('payment_request', 'decide_payment_request', 2::smallint,
                                 'PAYMENT_REQUEST_NO_OTHER_DECIDER');
    v_code := next_payment_request_code(p_planned_date);
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  amount_ccy, currency, amount_base, bank_account_code,
                                  period_month, filed_reference, planned_date, notes, created_by)
    VALUES (v_id, v_code, 'wht_remittance',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            NULL,
            v_amount, base_currency_code(), v_amount,
            COALESCE(NULLIF(btrim(COALESCE(p_bank_account, '')), ''), '1000'),
            v_month, v_ref, p_planned_date, NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid());

    v_res := payment_request_dry_run(v_id);
    UPDATE payment_requests SET amount_base = (v_res->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('payment_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payment_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'code', v_code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
                              'amount_base', (v_res->>'amount_base')::numeric);
END;
$function$
;

-- db/functions/submit_wht_remittance_reversal_request.sql
-- PAY-REQ-1 · Batch B(2026-09-23,Tim 的 Q3):提一张【代扣税缴纳冲销】申请 ——
-- 一笔缴纳的更正从此走这里(通用冲销口对 wht_remittance 的分录同一刀关上)。
-- 理由必填;冲销日在执行那一步给(必填)。同一笔缴纳同时只能有一张未了结的冲销申请。
-- 金额从原缴纳【抄过来】,只供审批人看;执行时引擎照原分录逐行翻边
-- (reverse_wht_remittance_internal),这个月的欠款于是原样回来。
-- NOTE: introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.submit_wht_remittance_reversal_request(p_remittance_id uuid, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_w    wht_remittances%ROWTYPE;
    v_st   text;
    v_id   uuid := gen_random_uuid();
    v_code text;
    v_res  jsonb;
    v_on   boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_w FROM wht_remittances WHERE id = p_remittance_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_NOT_FOUND|%', COALESCE(p_remittance_id::text, '?');
    END IF;
    SELECT status INTO v_st FROM journal_entries WHERE id = v_w.journal_entry_id;
    IF v_st IS DISTINCT FROM 'posted' THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_ALREADY_REVERSED|%', v_w.code;
    END IF;
    IF p_notes IS NULL OR btrim(p_notes) = '' THEN
        RAISE EXCEPTION 'REVERSAL_REASON_REQUIRED';
    END IF;
    IF EXISTS (SELECT 1 FROM payment_requests r
                WHERE r.wht_remittance_id = p_remittance_id AND r.kind = 'wht_remittance_reversal'
                  AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'WHT_REVERSAL_ALREADY_REQUESTED|%', v_w.code;
    END IF;

    -- ★ ROLE-1 Batch 3a(Q12):提单人之外没人批得动 → 按名拒(审批关着时不拒)。先于取号:拒了不烧号。
    PERFORM assert_other_decider('payment_request', 'decide_payment_request', 2::smallint,
                                 'PAYMENT_REQUEST_NO_OTHER_DECIDER');
    v_code := next_payment_request_code(CURRENT_DATE);
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  amount_ccy, currency, amount_base,
                                  period_month, filed_reference, wht_remittance_id, notes, created_by)
    VALUES (v_id, v_code, 'wht_remittance_reversal',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            NULL,
            v_w.amount_base, base_currency_code(), v_w.amount_base,
            v_w.period_month, v_w.filed_reference, p_remittance_id, btrim(p_notes), auth.uid());

    v_res := payment_request_dry_run(v_id);
    UPDATE payment_requests SET amount_base = (v_res->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('payment_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payment_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'code', v_code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END);
END;
$function$
;

-- ── 7 · 自证 ──────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.b3a_pending_decider_check(p_after boolean DEFAULT true)
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
      -- ROLE-1 Batch 3a:过账归 action.stocktake_post;开单人与录过数的每一个人都不算(按人认)
      LEFT JOIN holds h ON 'action.stocktake_post' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.stocktake_counts c
                                        WHERE c.stocktake_id = s.id
                                          AND public.self_leg(c.counted_by, NULL, h.user_id) <> 'none')
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

CREATE TEMP TABLE b3a_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权 = 之前 + 裁定的那四行,一行不少、一行不多
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT (SELECT role_code || ':' || permission_code FROM b3a_grants_before
                 UNION SELECT unnest(ARRAY['warehouse:action.stocktake_count', 'admin:action.stocktake_count', 'finance:action.stocktake_post', 'admin:action.stocktake_post'])))
        UNION ALL
        ((SELECT role_code || ':' || permission_code FROM b3a_grants_before
          UNION SELECT unnest(ARRAY['warehouse:action.stocktake_count', 'admin:action.stocktake_count', 'finance:action.stocktake_post', 'admin:action.stocktake_post']))
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B3A_PROOF|grants differ from before + ruled: %', v_bad; END IF;
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.stocktake_count';
    IF v_bad IS DISTINCT FROM 'admin warehouse' THEN RAISE EXCEPTION 'ROLE1B3A_PROOF|stocktake_count holders are %', v_bad; END IF;
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.stocktake_post';
    IF v_bad IS DISTINCT FROM 'admin finance' THEN RAISE EXCEPTION 'ROLE1B3A_PROOF|stocktake_post holders are %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;业务行一行没变;"谁数过"是空的
    IF EXISTS ((SELECT b.k, b.id FROM b3a_pending_before b EXCEPT SELECT a.k, a.id FROM b3a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM b3a_pending_after a EXCEPT SELECT b.k, b.id FROM b3a_pending_before b)) THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM b3a_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM stocktakes) AS stocktakes,
       (SELECT count(*) FROM stocktake_lines) AS stocktake_lines,
       (SELECT count(*) FROM inbound_batches WHERE unit_price IS NOT NULL) AS receipts_priced,
       (SELECT count(*) FROM inbound_batches) AS receipts_all,
       (SELECT count(*) FROM assay_results WHERE is_final) AS assays_final,
       (SELECT count(*) FROM assay_results WHERE applied_at IS NOT NULL) AS assays_applied,
       (SELECT count(*) FROM payment_requests) AS payment_requests,
       (SELECT count(*) FROM payroll_requests) AS payroll_requests) n) THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|a business row count changed: % → %',
            (SELECT row(c.*)::text FROM b3a_counts_before c), (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM stocktakes) AS stocktakes,
       (SELECT count(*) FROM stocktake_lines) AS stocktake_lines,
       (SELECT count(*) FROM inbound_batches WHERE unit_price IS NOT NULL) AS receipts_priced,
       (SELECT count(*) FROM inbound_batches) AS receipts_all,
       (SELECT count(*) FROM assay_results WHERE is_final) AS assays_final,
       (SELECT count(*) FROM assay_results WHERE applied_at IS NOT NULL) AS assays_applied,
       (SELECT count(*) FROM payment_requests) AS payment_requests,
       (SELECT count(*) FROM payroll_requests) AS payroll_requests) n);
    END IF;
    IF EXISTS (SELECT 1 FROM stocktake_counts) THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|stocktake_counts is not empty';
    END IF;

    -- ④ 结构:直连写策略没了;三支直连写守卫 + 只增不改守卫挂上;到岸成本判据里没有盘点码了
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('stocktakes', 'stocktake_lines')
                AND cmd IN ('INSERT', 'UPDATE')) THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|a stocktake write policy is still there';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE tgname IN ('trg_stocktakes_direct_write', 'trg_stocktake_lines_direct_write',
                                                             'trg_stocktake_counts_direct_write', 'trg_stocktake_counts_append_only');
    IF v_n <> 4 THEN RAISE EXCEPTION 'ROLE1B3A_PROOF|expected 4 stocktake guard triggers, got %', v_n; END IF;
    IF pg_get_functiondef('public.inbound_batch_landed_unit_cost(uuid)'::regprocedure) LIKE '%has_permission(''module.stocktakes.edit''%' THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|landed cost still lets module.stocktakes.edit through';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.post_stocktake(uuid)'::regprocedure) NOT LIKE '%require_permission(''action.stocktake_post'')%' THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|post_stocktake is not gated on action.stocktake_post';
    END IF;

    -- ⑤ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.b3a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ROLE1B3A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.b3a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.b3a_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.b3a_pending_decider_check(boolean);

COMMIT;
