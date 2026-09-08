-- db/migrations/2026-09-08-pur1-the-purchase-order-document.sql
-- PUR-1:采购单这张纸 —— 合同号、交货地点、逐行定价状态,以及改单能改付款条款。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【本刀最要紧的一件事:改单能改付款条款,而档案接得住】★★
-- ════════════════════════════════════════════════════════════════════════════
--   委托书原话是"an amendment already requires a reason and is already recorded.
--   Payment terms follow the same rule." —— 前半句是真的,后半句【接不上】,
--   而这是量出来的,不是推出来的:
--
--     · amend_purchase_order 的 p_header 只认六样(单据日 / 预计到货 / 贸易术语 /
--       条款正文 / 备注 / 汇率),付款条款【不是一个参数】;
--     · 表单上没有那个字段;
--     · ★ 而【没有任何东西禁止它】★ —— purchase_order_payment_terms 的
--       INSERT/UPDATE/DELETE 策略今天就对持 module.purchasing.edit 的人全开。
--       也就是说这条路【今天就通】,通的是一条直连改库的路。
--     · purchase_order_history 是一张【定列】的表:它有单据日、贸易术语、条款正文、
--       数量、单价……的 old_/new_ 对,**没有任何一列装得下付款计划**;
--       而 purchase_order_payment_terms 上【一个留痕触发器都没有】
--       (它唯一的触发器是 trg_po_payment_terms_event_applicable,那是适用性校验)。
--
--   ★ 所以"锁"从来不存在,存在的是【一个没有人裁过的缺席】。★
--   只把表单打开,买到的是一条**在档案里完全沉默**的改单路径 ——
--   而 PUR-2 建这张历史表的全部理由,正是"只能作废重开"不是规则、是没人建那个按钮。
--   Tim 2026-09-08 裁定:扩档案,两样一起开,不许走便宜那条路。
--
-- 【留痕由触发器写,不由 RPC 写 —— 与 PUR-2 逐字同一条】
--   应用侧留痕是"想写才写"的;触发器接得住每一条路径,**包括上面那条直连改库的**。
--   所以本刀给付款条款加的是一支触发器,不是在 amend_purchase_order 里补一段 INSERT。
--
-- 【付款计划整期存成 jsonb,不是逐列拆开】
--   一期付款是【一件事】(第几期、叫什么、比例还是定额、什么里程碑、哪天、备注),
--   拆成六对 old_/new_ 列会让这张表宽出一倍,而读的人还要自己把它拼回去。
--   形状取自 contract_document_terms.grade_specs 与 pricing_term_commitments:
--   **冻住的事实自成一体**。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【定价状态:一个【存下来的选择】,而它只在【选得动】的方向上生效】★★
-- ════════════════════════════════════════════════════════════════════════════
--   量出来的事实(2026-09-08):`Price: FIXED` 这一行**背后没有列**。
--   po_document_data 现算出四个值,而判据是【事实】不是【选择】:
--     provisional_committed   ← 这一行有一份 pricing_term_commitments
--     provisional_uncommitted ← 挂了 pricing_formula_id、条款没抄下来
--     fixed                   ← 有 estimated_unit_price
--     not_priced              ← 以上都没有
--   线上 11 行里 3 行挂着公式、1 份承诺 —— 也就是说**第二个值今天就已经在用**,
--   它只是【选不动】。
--
--   ★ 于是"让人来选"与"从事实推导"会撞车,而两个方向【不对称】:★
--     · 把一条【没有公式】的行标成 provisional —— 真话,而且这正是今天缺的能力;
--     · 把一条【挂着公式/已承诺】的行标成 fixed —— **假话**,而且是印在
--       供应商手里那张纸上的假话:那一行真的按指数公式结算。
--   Tim 2026-09-08 裁定(Q1 的 b):加列,而**后一种按名拒**。
--
--   【两道防线,刻意的】
--     ① 写的时候按名拒(guard_po_line_price_status)—— 让那次尝试**被看见**,
--        而不是悄悄被忽略;
--     ② 读的时候排序(po_document_data 的 CASE):公式 / 承诺两支排在
--        price_status 之前,于是**即使有一行绕过了①(例如比①还老的行),
--        那张纸上也印不出一个假的 FIXED**。
--   一道闸能被绕过的时候,第二道不是冗余。
--
-- 【交货地点:自由文本,不是选储位】Tim 裁定 —— 一台设备不发去仓库。
--
-- 【本刀【不】动审批链】approval_status 那条线一个字没加:见迁移末尾的注释与
--   docs/forward-queue.md。今天没有任何人批过任何一张单,也就没有名字填得上去。
--
-- 应用:./db/apply_migration.sh db/migrations/2026-09-08-pur1-the-purchase-order-document.sql

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 一 · 交货地点(表头一列,自由文本)
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.purchase_orders
    ADD COLUMN delivery_location text;

COMMENT ON COLUMN public.purchase_orders.delivery_location IS
'PUR-1:这张单的货送到哪里 —— **自由文本,刻意【不是】储位选择器**(Tim 2026-09-08 裁定)。理由是具体的:一台设备订单送到的地方常常根本不是仓库(车间、工地、供应商代管),把它做成 storage_locations 的下拉框会逼人在一份【不适用】的清单里凑一个最接近的答案 —— 而那个答案会被印在发给供应商的纸上。**空着就是空着**:PDF 上不印一个空标签(与 expected_delivery_date 那一格不同,它有 ''—'',因为那一格永远该有一个日期)。';

-- ════════════════════════════════════════════════════════════════════════════
-- 二 · 逐行定价状态(存下来的选择;NULL = 按今天的事实推导)
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.purchase_order_lines
    ADD COLUMN price_status text
        CHECK (price_status IS NULL OR price_status IN ('fixed', 'provisional'));

COMMENT ON COLUMN public.purchase_order_lines.price_status IS
'PUR-1:这一行的价是【定价】还是【暂定价】—— 一个人做出的选择。★**NULL 不是"没选",是"按事实推导"**★:本刀之前的每一行都是 NULL,而它们在纸上照常印出正确的状态(po_document_data 的四支 CASE:有承诺 → provisional_committed,挂公式 → provisional_uncommitted,有单价 → fixed,都没有 → not_priced)。**不回填** —— 回填等于替下单的人做了一个他没做过的选择。★【''fixed'' 有一条它选不动的边界】★:一行挂着 pricing_formula_id、或已经有一份 pricing_term_commitments,它就是【按公式结算】的,把它标成 fixed 是一句**印在供应商纸上的假话** —— guard_po_line_price_status 按名拒(PO_LINE_PRICE_STATUS_CONFLICT)。反过来【是允许的】:把一条没有公式的行标成 provisional,那是真话,而且正是本刀补上的那个能力。';

-- ★【写的时候那道闸】★ 为什么是触发器而不是 CHECK:承诺在【另一张表】上
-- (pricing_term_commitments),CHECK 看不见它。而只挡住 pricing_formula_id
-- 那一半、把另一半留给读取侧,是把一条规矩写成两个地方各一半。
CREATE OR REPLACE FUNCTION public.guard_po_line_price_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    -- 只有 'fixed' 这一个方向需要拦。标成 provisional 永远是真话:
    -- 一行【没有】公式也可以是暂定价(逐笔谈的暂定价,§6.2),那正是本刀补的能力。
    IF NEW.price_status IS DISTINCT FROM 'fixed' THEN
        RETURN NEW;
    END IF;

    IF NEW.pricing_formula_id IS NOT NULL THEN
        SELECT code INTO v_code FROM purchase_orders WHERE id = NEW.purchase_order_id;
        RAISE EXCEPTION 'PO_LINE_PRICE_STATUS_CONFLICT|%|%|%',
            COALESCE(v_code, NEW.purchase_order_id::text), NEW.line_no, 'pricing_formula'
          USING HINT = '这一行挂着计价公式 —— 它按公式结算,把它标成【定价】会在发给供应商的纸上印一句假话。要它是定价,先把公式去掉';
    END IF;

    IF EXISTS (SELECT 1 FROM pricing_term_commitments c
                WHERE c.purchase_order_line_id = NEW.id) THEN
        SELECT code INTO v_code FROM purchase_orders WHERE id = NEW.purchase_order_id;
        RAISE EXCEPTION 'PO_LINE_PRICE_STATUS_CONFLICT|%|%|%',
            COALESCE(v_code, NEW.purchase_order_id::text), NEW.line_no, 'committed_terms'
          USING HINT = '这一行已经抄下了一份结算条款(承诺定价)—— 它按那份条款结算,标成【定价】是一句假话';
    END IF;

    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_po_line_price_status() IS
'PUR-1:一条按公式结算的行不许被标成【定价】。★**只拦一个方向,而那是刻意的**★:标成 provisional 永远是真话(逐笔谈的暂定价不需要公式);标成 fixed 而它挂着公式或已有承诺,是**印在供应商纸上的假话**。这是两道防线里的第一道 —— 第二道在 po_document_data 的 CASE 排序里,那一支保证【即使有一行绕过了这里】纸上也印不出假的 FIXED。';

CREATE TRIGGER guard_po_line_price_status
    BEFORE INSERT OR UPDATE ON public.purchase_order_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_po_line_price_status();

-- ════════════════════════════════════════════════════════════════════════════
-- 三 · 档案接得住:新的三种改动,与三对新的列
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.purchase_order_history
    ADD COLUMN old_delivery_location text,
    ADD COLUMN new_delivery_location text,
    ADD COLUMN old_price_status      text,
    ADD COLUMN new_price_status      text,
    ADD COLUMN payment_term_seq      integer,
    ADD COLUMN old_payment_term      jsonb,
    ADD COLUMN new_payment_term      jsonb;

ALTER TABLE public.purchase_order_history
    DROP CONSTRAINT purchase_order_history_change_type_check;
ALTER TABLE public.purchase_order_history
    ADD CONSTRAINT purchase_order_history_change_type_check
    CHECK (change_type IN ('header_update','line_update','line_add','line_remove','cancelled',
                           'payment_term_add','payment_term_update','payment_term_remove'));

COMMENT ON COLUMN public.purchase_order_history.old_payment_term IS
'PUR-1:改动前的那一期付款,**整期存成一个 jsonb 对象**(seq / label / percentage / fixed_amount_ccy / trigger_event / due_date / notes)。★**为什么不逐列拆开**★:一期付款是【一件事】,拆成六对 old_/new_ 列会让这张表宽出一倍,而读的人还要自己拼回去。形状取自 contract_document_terms.grade_specs 与 pricing_term_commitments —— **冻住的事实自成一体**。新增那一期时它是 NULL,删除那一期时 new_payment_term 是 NULL。';

COMMENT ON COLUMN public.purchase_order_history.new_price_status IS
'PUR-1:改动后这一行的定价状态选择。**NULL 有两种读法,而它们由 change_type 分开**:一次 line_update 里两列都是 NULL,意思是"这次改动没碰它";而一行的 price_status 本身就是 NULL,意思是"按事实推导"(见该列注释)。';

-- ★【留痕由触发器写 —— 与 PUR-2 逐字同一条理由】★
-- 应用侧留痕是"想写才写"的;触发器接得住每一条路径,**包括一条直连改库的 UPDATE**,
-- 而 purchase_order_payment_terms 的策略今天就允许那一条。
CREATE OR REPLACE FUNCTION public.trg_po_history_payment_term()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_reason text := NULLIF(current_setting('evoltrya.amend_reason', true), '');
    v_old jsonb;
    v_new jsonb;
BEGIN
    -- 【建单时的那一批期数不记】与 trg_po_history_line 逐字同一条:否则每张新单
    -- 都会先长出一份"全是新增"的历史,把真正的修改埋掉。
    IF TG_OP = 'INSERT'
       AND current_setting('evoltrya.po_amend_ctx', true) IS DISTINCT FROM '1' THEN
        RETURN NEW;
    END IF;

    IF TG_OP <> 'INSERT' THEN
        v_old := jsonb_build_object(
            'seq', OLD.seq, 'label', OLD.label, 'percentage', OLD.percentage,
            'fixed_amount_ccy', OLD.fixed_amount_ccy, 'trigger_event', OLD.trigger_event,
            'due_date', OLD.due_date, 'notes', OLD.notes);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new := jsonb_build_object(
            'seq', NEW.seq, 'label', NEW.label, 'percentage', NEW.percentage,
            'fixed_amount_ccy', NEW.fixed_amount_ccy, 'trigger_event', NEW.trigger_event,
            'due_date', NEW.due_date, 'notes', NEW.notes);
    END IF;

    -- 一次没有改动的 UPDATE 不记 —— 与表头、明细两支同一条。
    IF TG_OP = 'UPDATE' AND v_old = v_new THEN
        RETURN NEW;
    END IF;

    INSERT INTO purchase_order_history (
        purchase_order_id, change_type, payment_term_seq,
        old_payment_term, new_payment_term, amend_reason)
    VALUES (
        CASE WHEN TG_OP = 'DELETE' THEN OLD.purchase_order_id ELSE NEW.purchase_order_id END,
        CASE TG_OP WHEN 'INSERT' THEN 'payment_term_add'
                   WHEN 'UPDATE' THEN 'payment_term_update'
                   ELSE 'payment_term_remove' END,
        CASE WHEN TG_OP = 'DELETE' THEN OLD.seq ELSE NEW.seq END,
        v_old, v_new, v_reason);

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

COMMENT ON FUNCTION public.trg_po_history_payment_term() IS
'PUR-1:付款计划的编辑史。★**它存在的理由是一次实测**★:改单此前改不了付款条款,而那【不是一道锁】—— purchase_order_payment_terms 的策略今天就对持 module.purchasing.edit 的人全开,缺的是入口与档案。只开入口不扩档案,买到的是一条在档案里完全沉默的改单路径,而那正是 PUR-2 建这张历史表要消灭的东西。**由触发器写,不由 RPC 写**:触发器接得住直连改库的那一条。建单时的那批期数不记(与 trg_po_history_line 同一条:否则新单会先长出一份"全是新增"的历史)。';

CREATE TRIGGER trg_purchase_order_payment_terms_history
    AFTER INSERT OR UPDATE OR DELETE ON public.purchase_order_payment_terms
    FOR EACH ROW EXECUTE FUNCTION public.trg_po_history_payment_term();

-- ════════════════════════════════════════════════════════════════════════════
-- 四 · 列级授权与遮蔽视图(加列 = 三件事,WO-1a 那一课)
-- ════════════════════════════════════════════════════════════════════════════
-- 【两列都【不敏感】】交货地点是一个地址,定价状态是一个分类 —— 都不是钱。
GRANT SELECT (delivery_location) ON public.purchase_orders TO authenticated;
GRANT SELECT (price_status) ON public.purchase_order_lines TO authenticated;

-- ── trg_po_history_header:交货地点 ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_po_history_header()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 只记【商业字段】的改动:updated_at/updated_by 的变化不是编辑史。
    -- 状态转换(cancel/close/reopen)也不记 —— 它们有自己的记录路径,
    -- 记进来会让编辑史被状态噪音淹掉。
    IF NEW.order_date IS NOT DISTINCT FROM OLD.order_date
       AND NEW.expected_delivery_date IS NOT DISTINCT FROM OLD.expected_delivery_date
       AND NEW.fx_rate IS NOT DISTINCT FROM OLD.fx_rate
       AND NEW.estimated_total_ccy IS NOT DISTINCT FROM OLD.estimated_total_ccy
       AND NEW.incoterm IS NOT DISTINCT FROM OLD.incoterm
       AND NEW.terms_text IS NOT DISTINCT FROM OLD.terms_text
       AND NEW.notes IS NOT DISTINCT FROM OLD.notes
       -- PUR-1:交货地点也是【商业字段】—— 改了它而档案一言不发,
       -- 与付款条款那一条是同一个缺席(见迁移抬头)。
       AND NEW.delivery_location IS NOT DISTINCT FROM OLD.delivery_location THEN
        RETURN NEW;
    END IF;

    INSERT INTO purchase_order_history (
        purchase_order_id, change_type,
        old_order_date, new_order_date,
        old_expected_delivery_date, new_expected_delivery_date,
        old_fx_rate, new_fx_rate,
        old_estimated_total_ccy, new_estimated_total_ccy,
        old_incoterm, new_incoterm, old_terms_text, new_terms_text,
        old_notes, new_notes,
        old_delivery_location, new_delivery_location, amend_reason)
    VALUES (NEW.id, 'header_update',
        OLD.order_date, NEW.order_date,
        OLD.expected_delivery_date, NEW.expected_delivery_date,
        OLD.fx_rate, NEW.fx_rate,
        OLD.estimated_total_ccy, NEW.estimated_total_ccy,
        OLD.incoterm, NEW.incoterm, OLD.terms_text, NEW.terms_text,
        OLD.notes, NEW.notes,
        OLD.delivery_location, NEW.delivery_location,
        NULLIF(current_setting('evoltrya.amend_reason', true), ''));
    RETURN NEW;
END;
$function$;

-- ── trg_po_history_line:定价状态 ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_po_history_line()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_reason text := NULLIF(current_setting('evoltrya.amend_reason', true), '');
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- 【建单时的那一批行不记】否则每张新单都会先长出一份"全是新增"的历史,
        -- 把真正的修改埋掉。建单本身有 approval_log 的 auto_approved / submitted。
        IF current_setting('evoltrya.po_amend_ctx', true) IS DISTINCT FROM '1' THEN
            RETURN NEW;
        END IF;
        INSERT INTO purchase_order_history (purchase_order_id, purchase_order_line_id,
            line_no, change_type, new_quantity, new_unit,
            new_estimated_unit_price, new_estimated_amount_ccy, new_price_status, amend_reason)
        VALUES (NEW.purchase_order_id, NEW.id, NEW.line_no, 'line_add',
            NEW.quantity, NEW.unit, NEW.estimated_unit_price, NEW.estimated_amount_ccy,
            NEW.price_status, v_reason);
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO purchase_order_history (purchase_order_id, purchase_order_line_id,
            line_no, change_type, old_quantity, old_unit,
            old_estimated_unit_price, old_estimated_amount_ccy, old_price_status, amend_reason)
        VALUES (OLD.purchase_order_id, OLD.id, OLD.line_no, 'line_remove',
            OLD.quantity, OLD.unit, OLD.estimated_unit_price, OLD.estimated_amount_ccy,
            OLD.price_status, v_reason);
        RETURN OLD;
    END IF;

    IF NEW.quantity IS NOT DISTINCT FROM OLD.quantity
       AND NEW.unit IS NOT DISTINCT FROM OLD.unit
       AND NEW.estimated_unit_price IS NOT DISTINCT FROM OLD.estimated_unit_price
       AND NEW.estimated_amount_ccy IS NOT DISTINCT FROM OLD.estimated_amount_ccy
       -- PUR-1:定价状态是【一个人做出的选择】,改了它而档案沉默,
       -- 与数量、单价被改而档案沉默是同一件事。
       AND NEW.price_status IS NOT DISTINCT FROM OLD.price_status THEN
        RETURN NEW;
    END IF;
    INSERT INTO purchase_order_history (purchase_order_id, purchase_order_line_id,
        line_no, change_type,
        old_quantity, new_quantity, old_unit, new_unit,
        old_estimated_unit_price, new_estimated_unit_price,
        old_estimated_amount_ccy, new_estimated_amount_ccy,
        old_price_status, new_price_status, amend_reason)
    VALUES (NEW.purchase_order_id, NEW.id, NEW.line_no, 'line_update',
        OLD.quantity, NEW.quantity, OLD.unit, NEW.unit,
        OLD.estimated_unit_price, NEW.estimated_unit_price,
        OLD.estimated_amount_ccy, NEW.estimated_amount_ccy,
        OLD.price_status, NEW.price_status, v_reason);
    RETURN NEW;
END;
$function$;
-- ── po_document_data:合同号 / 交货地点 / 定价状态 ────────────────
CREATE OR REPLACE FUNCTION public.po_document_data(p_po_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po   record;
    v_sup  record;
    v_lines jsonb;
    v_terms jsonb;
    -- PUR-1:这张单挂在哪一份合同之下 —— 读的是【抄下来的那一份】。
    v_contract_code text;
BEGIN
    PERFORM require_permission('module.purchasing.view');

    SELECT po.id, po.code, po.order_date, po.expected_delivery_date, po.currency,
           po.status, po.approval_status, po.incoterm, po.terms_text, po.notes,
           po.estimated_total_ccy, po.tax_total_ccy, po.supplier_id,
           -- PUR-1:交货地点(自由文本,可空)
           po.delivery_location
    INTO v_po FROM purchase_orders po
    WHERE po.id = p_po_id AND po.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_po_id::text, '?');
    END IF;

    SELECT s.legal_name, s.address, s.country, s.tax_id
    INTO v_sup FROM suppliers s WHERE s.id = v_po.supplier_id;

    -- ── PUR-1:参照合同号 ────────────────────────────────────────────────────
    -- ★★【读 contract_document_terms,【不】读 contracts】★★
    --   contract_document_terms 的表注写得很死:purchase_orders.contract_id 只回答
    --   "挂在哪一份合同上",**任何读取路径都不许拿它回查条款内容** —— 一旦那么写,
    --   "抄"就静悄悄退化成了"引用"。合同编号【就是被抄下来的字段之一】
    --   (contract_code,NOT NULL),所以这里读副本,而不是顺着外键回查。
    --   后果是具体的:合同日后改了编号,这张【已经开出去的】单上印的仍是当时那个 ——
    --   而那正是供应商手里那张纸上写着的东西。
    -- 【没挂合同就是 NULL】PDF 那一侧据此【整块不印】,不印一个空标签。
    SELECT t.contract_code INTO v_contract_code
      FROM contract_document_terms t WHERE t.purchase_order_id = p_po_id;

    -- ── 逐行:定价状态在这里裁决,PDF 只负责画(docs/purchase-order-document.md §B)──
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'line_no', l.line_no,
        'material_name', COALESCE(m.name, fa.description),
        'quantity', l.quantity,
        'unit', l.unit,
        'unit_price', l.estimated_unit_price,          -- 单据币种;可空
        'amount_ccy', l.estimated_amount_ccy,
        -- PO-GST-1:行上的税 —— 供应商手里那张纸要逐行看得见它。
        'tax_code', l.tax_code,
        'tax_rate_pct', l.tax_rate_pct,
        'tax_amount_ccy', l.tax_amount_ccy,
        'expected_assay', l.expected_assay,
        'notes', l.notes,
        -- 【FIN-26 的那次误读,在这里终结】价格是不是手填的【估算】是记录下来的
        -- 事实(price_source),不是从公式在不在推断的
        'price_is_manual_estimate', (l.price_source = 'manual' AND c.id IS NOT NULL),
        'pricing_status', CASE
            WHEN c.id IS NOT NULL                 THEN 'provisional_committed'
            -- 公式挂着、条款没抄下来(FIN-27 之前的旧行):【不印公式今天的条款】——
            -- 那是编造一份承诺,known-wrong 里写明这些行走手工结算
            WHEN l.pricing_formula_id IS NOT NULL THEN 'provisional_uncommitted'
            -- ★★【PUR-1:存下来的那个选择排在这里,而位置就是判据】★★
            --   上面两支(有承诺 / 挂公式)是【事实】,这一支是【选择】——
            --   事实排在选择前面,于是一行按公式结算的料【印不出 FIXED】,
            --   哪怕它的 price_status 不知怎么被写成了 'fixed'。
            --   写入那一侧已经按名拒了(guard_po_line_price_status),
            --   而这里是第二道:**一道闸能被绕过的时候,第二道不是冗余**
            --   (比这道闸更老的行、以及将来任何一条新的写入路径)。
            --   反方向【是允许的】:一行没有公式、被人标成 provisional,
            --   就印暂定价 —— 那是真话,也正是本刀补上的那个能力。
            WHEN l.price_status = 'provisional'   THEN 'provisional_uncommitted'
            WHEN l.estimated_unit_price IS NOT NULL THEN 'fixed'
            -- 【标成 fixed 却一个价都没有】仍然是 not_priced —— 纸上不能说
            -- "价格已定"而那一栏是一横。选择改变不了"没有数字"这件事。
            ELSE 'not_priced'
        END,
        'committed_terms', CASE WHEN c.id IS NOT NULL THEN jsonb_build_object(
            'source_formula_code', c.source_formula_code,
            'source_formula_name', c.source_formula_name,
            'price_basis', c.price_basis,
            'average_days', c.average_days,
            'treatment_charge_usd_per_tonne', c.treatment_charge_usd_per_tonne,
            'flat_discount_pct', c.flat_discount_pct,
            'metals', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                           'metal', cm.metal, 'payable_pct', cm.payable_pct)
                           ORDER BY cm.metal), '[]'::jsonb)
                       FROM pricing_term_commitment_metals cm
                       WHERE cm.commitment_id = c.id)
        ) END
    ) ORDER BY l.line_no), '[]'::jsonb)
    INTO v_lines
    FROM purchase_order_lines l
    -- EQP-1a:【INNER → LEFT】原先是 JOIN materials —— 设备行会从【打印出来的
    -- 采购单】上整行消失,而单据其余部分照常成立:没有错误、没有空行,
    -- 只是那台机器不在发给供应商的纸上。
    LEFT JOIN materials m ON m.id = l.material_id
    LEFT JOIN fixed_assets fa ON fa.id = l.asset_id
    LEFT JOIN pricing_term_commitments c ON c.purchase_order_line_id = l.id
    WHERE l.purchase_order_id = p_po_id;

    -- ── 付款计划(FIN-29 的承诺分期,原样印)────────────────────────────────
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'seq', t.seq, 'label', t.label, 'percentage', t.percentage,
        'fixed_amount_ccy', t.fixed_amount_ccy,
        'trigger_event', t.trigger_event, 'trigger_phrase', pte.phrase_en,
        'due_date', t.due_date, 'notes', t.notes
    ) ORDER BY t.seq), '[]'::jsonb)
    INTO v_terms
    FROM purchase_order_payment_terms t
    LEFT JOIN payment_trigger_events pte ON pte.code = t.trigger_event
    WHERE t.purchase_order_id = p_po_id;

    -- 【单据币种,只有单据币种】(§D)—— 这里没有 fx_rate,没有本位币数字。
    -- 本位币是内部口径:它决定审批级别,不该出现在供应商手里的纸上。
    RETURN jsonb_build_object(
        'code', v_po.code,
        'order_date', v_po.order_date,
        'expected_delivery_date', v_po.expected_delivery_date,
        -- PUR-1:交货地点与参照合同号。**两者都可空,而空就是【不印】** ——
        -- PDF 那一侧不画空标签(见 PurchaseOrderDocument.tsx 的两处判断)。
        'delivery_location', v_po.delivery_location,
        'contract_code', v_contract_code,
        'currency', v_po.currency,
        'status', v_po.status,
        'approval_status', v_po.approval_status,
        'incoterm', v_po.incoterm,
        'terms_text', v_po.terms_text,
        'notes', v_po.notes,
        -- ★★【PO-GST-1:净额 / 税 / 含税额,三个数,一个来源】★★
        -- 屏幕与 PDF 读的都是这三个字段所依据的【同两列】(estimated_total_ccy 与
        -- tax_total_ccy)。此前 PDF 读本函数、屏幕直接读遮蔽视图 —— 两条路今天
        -- 落在同一列上,所以【碰巧】一致;加了税之后再各算各的,迟早各说各话。
        -- 【含税额在这里加一次】gross = net + COALESCE(tax, 0),不另存一列:
        -- 存第三个数就是给自己第三个会漂的地方。
        'estimated_total_ccy', v_po.estimated_total_ccy,
        'tax_total_ccy', v_po.tax_total_ccy,
        'gross_total_ccy', v_po.estimated_total_ccy + COALESCE(v_po.tax_total_ccy, 0),
        -- 【这张单带不带税】NULL 的税额合计不是零税:它是"这张单开在采购单携带税
        -- 之前,或开在 GST 未注册的时候"。PDF 与屏幕对这两种情形说的话不一样。
        'carries_tax', (v_po.tax_total_ccy IS NOT NULL),
        -- ★【有没有一条【不在范围内】的行】★ 有就要在纸上说清:这一部分的 GST
        -- 不付给这家供应商,而是进口清关时付给新加坡海关。见 ①b。
        'has_out_of_scope_line', EXISTS (
            SELECT 1 FROM purchase_order_lines x
             WHERE x.purchase_order_id = p_po_id AND x.tax_code = 'OP'),
        'supplier', jsonb_build_object(
            'legal_name', v_sup.legal_name, 'address', v_sup.address,
            'country', v_sup.country, 'tax_id', v_sup.tax_id),
        'lines', v_lines,
        'payment_terms', v_terms
    );
END;
$function$
;
-- ── create_purchase_order:交货地点 / 定价状态 ────────────────────
-- 【DROP + CREATE,不是 CREATE OR REPLACE】签名多了一个参数,
-- CREATE OR REPLACE 会造出一个【重载】而不是替换它,而 PostgREST 面对
-- 两个同名函数会按参数名去猜 —— 那是一条会在运行时才发现的歧义。
DROP FUNCTION public.create_purchase_order(uuid, date, date, text, numeric, text, text, text, jsonb, jsonb);

CREATE OR REPLACE FUNCTION public.create_purchase_order(p_supplier_id uuid, p_order_date date, p_expected_delivery date, p_currency text, p_fx_rate numeric, p_incoterm text, p_terms_text text, p_notes text, p_lines jsonb, p_payment_terms jsonb DEFAULT '[]'::jsonb, p_delivery_location text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    -- APR-2c:审批生效与否决定这张单生为什么状态。三态见迁移文件头。
    v_appr_on    boolean := approvals_enabled();
    v_user       uuid := auth.uid();
    v_date       date;
    v_fx         numeric;
    v_po_id      uuid := gen_random_uuid();
    v_code       text;
    v_line       jsonb;
    v_line_no    integer;
    v_line_id    uuid;      -- FIN-27:承诺挂在行上,需要它的 id
    v_qty        numeric;
    v_price      numeric;
    v_price_status text;      -- PUR-1:这一行的定价状态选择(可空 = 按事实推导)
    v_src          text;      -- FIN-26:computed / manual / NULL(旧调用方)
    v_prov         jsonb;     -- FIN-26:computed 行的重导出依据
    v_amount     numeric;
    v_material   uuid;
    v_asset       uuid;
    v_formula    uuid;
    v_f          record;
    v_total      numeric := 0;
    -- ── PO-GST-1:税 ─────────────────────────────────────────────────────────
    v_sup_tax_default text;     -- 供应商的默认进项税码(播种用)
    v_gst        boolean := gst_registered();
    v_tax_code   text;
    v_tax_rate   numeric;
    v_line_tax   numeric;
    v_tax_total  numeric := 0;
    v_count      integer := 0;
    v_committed  integer := 0;  -- FIN-27:抄下条款的行数
    v_term       jsonb;
    v_seq        integer;
    v_expect     integer := 0;
    v_pct_total  numeric := 0;
    v_term_count integer := 0;
    v_retentions integer := 0;
    -- ── EQP-PAY-1 ──────────────────────────────────────────────────────────
    -- A2:混装单在门上【先】拒一次。计数而不是布尔,好让参数形状与既有那道
    -- guard_po_lines_single_kind 逐字相同(|单号|材料行数|设备行数)。
    v_n_material integer := 0;
    v_n_asset    integer := 0;
    v_kind       text;              -- 'equipment' / 'material'
    v_applicable boolean;           -- R5:这一期的里程碑用不用得上
    v_ret        jsonb;              -- R6:这条设备行的质保金(可选 —— 没有就【没有这一行】)
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    IF p_order_date IS NULL THEN
        RAISE EXCEPTION 'ORDER_DATE_REQUIRED';
    END IF;
    v_date := p_order_date;
    IF p_supplier_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', COALESCE(p_supplier_id::text, '?');
    END IF;

    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【下单日】的行方卖出价(tt_sell)估值。
    -- 当日无牌价即拒 —— 这也逼着牌价当天录入(隔天可能就查不到了)。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, p_order_date, 'tt_sell');

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- ── PO-GST-1:供应商的默认进项税码 —— 【行上的税码由它播种】────────────
    -- Tim 的裁定:供应商记录上那个「默认税码」字段【就是】判据。不看国别、
    -- 不看 tax_residence、不新增字段:海外供应商由 Tim 在供应商记录上设成 OP,
    -- 本地设成 TX,而这张单只是【服从供应商记录上写着的那个】。
    SELECT default_tax_code INTO v_sup_tax_default FROM suppliers WHERE id = p_supplier_id;

    v_code := next_purchase_order_code(v_date);

    INSERT INTO purchase_orders (id, code, supplier_id, order_date, expected_delivery_date,
                                 currency, fx_rate, estimated_total_ccy, status,
                                 approval_status, approved_at, approved_by,
                                 incoterm, terms_text, notes, created_by, updated_by,
                                 delivery_location)
    VALUES (v_po_id, v_code, p_supplier_id, v_date, p_expected_delivery,
            -- APR-2:新单【生为 draft/pending】—— 此前是 confirmed/approved,
            -- 于是"提单人发起"根本无处可放。批准把它推到 confirmed。
            p_currency, v_fx, 0,
            -- APR-2c:审批生效 → draft/pending,等人批;审批未生效 → 直接 confirmed/approved,
            -- 而【界面会明说审批未生效】,不是悄悄放行。两者都不是默认值,是一个被声明的状态。
            CASE WHEN v_appr_on THEN 'draft'   ELSE 'confirmed' END,
            CASE WHEN v_appr_on THEN 'pending' ELSE 'approved'  END,
            CASE WHEN v_appr_on THEN NULL ELSE now() END,
            CASE WHEN v_appr_on THEN NULL ELSE v_user END,
            p_incoterm, p_terms_text, p_notes, v_user, v_user,
            -- PUR-1:自由文本。空串与只有空白的输入一律收成 NULL ——
            -- 一个空串会让 PDF 那一侧画出一个空的标签,而"没填"该是【不印】。
            NULLIF(btrim(COALESCE(p_delivery_location, '')), ''));

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_count := v_count + 1;
        v_line_no := COALESCE((v_line->>'line_no')::integer, v_count);
        v_material := (v_line->>'material_id')::uuid;
        -- EQP-1a:设备行 —— 引用一张【已经存在】的资产卡,行不创建资产
        v_asset := (v_line->>'asset_id')::uuid;
        v_qty := (v_line->>'quantity')::numeric;
        v_price := (v_line->>'estimated_unit_price')::numeric;
        v_formula := (v_line->>'pricing_formula_id')::uuid;
        -- ── PUR-1:这一行的定价状态 ──────────────────────────────────────
        -- 【省略 = NULL = 按事实推导】不是"默认定价"。既有调用方一个字不改,
        -- 而它们开出来的单在纸上印的状态与本刀之前【逐字相同】。
        v_price_status := NULLIF(btrim(COALESCE(v_line->>'price_status', '')), '');
        IF v_price_status IS NOT NULL AND v_price_status NOT IN ('fixed', 'provisional') THEN
            -- 【按名拒,不让表上那条 CHECK 去炸】屏幕上拿到一条裸约束原文,
            -- 读的人无从知道可选值是哪两个(与本函数其余具名拒绝同一条)。
            RAISE EXCEPTION 'PO_LINE_PRICE_STATUS_INVALID|%|%', v_line_no, v_price_status
              USING HINT = '定价状态只有两个取值:fixed(定价)与 provisional(暂定价)。留空表示按事实推导 —— 挂了公式就是暂定价,有单价就是定价';
        END IF;

        -- EQP-1a:恰一非空 —— 与表上那条 CHECK 同一句话,在这里【先】说一遍,
        -- 好让走门的人拿到一个具名拒绝而不是一条约束原文。
        IF num_nonnulls(v_material, v_asset) <> 1 THEN
            RAISE EXCEPTION 'PO_LINE_KIND_INVALID|%', v_line_no
              USING HINT = '一行要么订材料、要么订一台已建卡的设备,不能都给、也不能都不给';
        END IF;

        -- ── EQP-PAY-1(A2):混装单,在门上先拒一次 ────────────────────────
        -- 【这不是第二份实现】表上那道 trg_po_lines_single_kind(EQP-1a)是
        -- DEFERRABLE INITIALLY DEFERRED —— 它在 COMMIT 那一刻才炸,那时整张单
        -- 已经建完了。这里在插入第二种行的【那一刻】就拒,并且说得出该怎么办。
        -- 错误码与参数形状与那一道【逐字相同】:一条规矩只能有一个码,
        -- 否则屏幕上会有一半的拒绝印出裸码。
        IF v_material IS NOT NULL THEN v_n_material := v_n_material + 1; END IF;
        IF v_asset    IS NOT NULL THEN v_n_asset    := v_n_asset    + 1; END IF;
        IF v_n_material > 0 AND v_n_asset > 0 THEN
            RAISE EXCEPTION 'PO_LINES_MIXED_KINDS|%|%|%', v_code, v_n_material, v_n_asset
              USING HINT = '一张采购单要么全是材料行、要么全是设备行 —— 请开两张单:一张订料,一张订机器。两者的收货路径、成本处理与付款里程碑都不同';
        END IF;

        IF v_material IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM materials WHERE id = v_material AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'MATERIAL_NOT_FOUND|%', COALESCE(v_material::text, '?');
        END IF;
        IF v_asset IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM fixed_assets WHERE id = v_asset
        ) THEN
            RAISE EXCEPTION 'ASSET_NOT_FOUND|%', COALESCE(v_asset::text, '?');
        END IF;
        -- EQP-1a-TAIL:设备行的 quantity 与 unit 【省略即给默认,给错则按名拒】。
        -- 只给默认不够 —— 一个明确传了 quantity = 5 的调用方会通过下面那条
        -- "> 0" 的校验,然后撞上一条【裸的约束违例】,而屏幕上永不出现裸码。
        IF v_asset IS NOT NULL THEN
            IF v_qty IS NULL THEN v_qty := 1; END IF;
            IF v_qty <> 1 THEN
                RAISE EXCEPTION 'PO_LINE_EQUIPMENT_QTY|%|%', v_line_no, v_qty
                  USING HINT = '一条设备行订的是【一台】机器 —— 四台是四条行,它们各有各的资产卡与投用日';
            END IF;
            IF COALESCE(v_line->>'unit', 'unit') <> 'unit' THEN
                RAISE EXCEPTION 'PO_LINE_EQUIPMENT_UNIT|%|%', v_line_no, v_line->>'unit'
                  USING HINT = '设备行的计量单位恒为 unit —— 留空即取它;填 kg 会让这台机器被加进公斤里';
            END IF;
        END IF;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_INVALID|%', v_line_no;
        END IF;
        IF v_formula IS NOT NULL THEN
            SELECT id, code, is_active, deleted_at INTO v_f
            FROM pricing_formulas WHERE id = v_formula;
            IF NOT FOUND OR v_f.deleted_at IS NOT NULL THEN
                RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', v_formula;
            END IF;
            IF NOT v_f.is_active THEN
                RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_f.code;
            END IF;
        END IF;

        -- 没给估价就是 0:PO 是承诺,估算金额可以留白(公式定价的料常常如此)
        v_amount := CASE WHEN v_price IS NULL THEN 0 ELSE round(v_qty * v_price, 2) END;
        v_total := v_total + v_amount;

        -- ── FIN-26:价格出处 ─────────────────────────────────────────────────
        -- computed / manual 是【记录】,不是从 expected_assay 是否为空【推断】——
        -- 推断在谁改了一个字段没改另一个的那一刻就失真。computed 必带 provenance
        -- (够重新导出这个数:化验、逐金属行情与日期、汇率与取自哪天、公式当时的
        -- 参数快照 —— 公式是可编辑的,行上引用的 id 指不住当时的样子)。
        v_src  := v_line->>'price_source';
        v_prov := v_line->'price_provenance';
        IF v_src IS NOT NULL AND v_src NOT IN ('computed', 'manual') THEN
            RAISE EXCEPTION 'PRICE_SOURCE_INVALID|%|%', v_line_no, v_src;
        END IF;
        IF v_src = 'computed' AND (v_prov IS NULL OR jsonb_typeof(v_prov) <> 'object') THEN
            RAISE EXCEPTION 'PROVENANCE_REQUIRED|%', v_line_no;
        END IF;
        IF v_src IS DISTINCT FROM 'computed' THEN
            v_prov := NULL;   -- 手填/未声明的行不留出处 —— 空白好过编造(B3)
        END IF;
        IF v_price IS NULL THEN
            v_src := NULL; v_prov := NULL;   -- 没有价就没有出处
        END IF;

        -- ── PO-GST-1:这一行的税 ─────────────────────────────────────────────
        -- 【税码在行上】一张单可以混税率:标准税率的货,旁边一条零税率或不在
        -- 范围内的行 —— 表头一个码说不出这件事。本行可以覆盖供应商的默认。
        --
        -- ★【没有税码就按名拒,不当成零】★ resolve_tax_code 已经替我们守着这一条
        -- (TAX_CODE_REQUIRED|supplier),而它正是【费用那一层用的同一支函数】——
        -- 采购单在这件事上与费用【逐字同一条规矩】。一个悄悄的 0 会印在一张
        -- 要发给供应商的纸上,那是一个错的数,不是一个空白。
        --
        -- 【GST 未注册时:与建 GST 之前一模一样】不解析、不盖码、不算税,
        -- 三列留 NULL —— 与 create_invoice / create_order_invoice 逐字同一个形状。
        IF v_gst THEN
            v_tax_code := resolve_tax_code(v_line->>'tax_code', v_sup_tax_default, 'input', 'supplier');
            v_tax_rate := tax_rate_for(v_tax_code, v_date);
            -- 【逐行取整】口径与出处见 tax_amount_for 的抬头。
            -- v_amount 为 NULL(公式定价、下单时还没有价)时税也是 NULL ——
            -- 没有净额就没有税额,而不是零。
            v_line_tax := CASE WHEN v_amount IS NULL THEN NULL
                               ELSE tax_amount_for(v_amount, v_tax_rate) END;
            v_tax_total := v_tax_total + COALESCE(v_line_tax, 0);
        ELSE
            IF NULLIF(btrim(COALESCE(v_line->>'tax_code', '')), '') IS NOT NULL THEN
                RAISE EXCEPTION 'GST_NOT_REGISTERED|%', v_line->>'tax_code';
            END IF;
            v_tax_code := NULL; v_tax_rate := NULL; v_line_tax := NULL;
        END IF;

        INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, asset_id, quantity,
                                          unit, pricing_formula_id, estimated_unit_price,
                                          estimated_amount_ccy, expected_assay, notes, created_by,
                                          price_source, price_provenance,
                                          tax_code, tax_rate_pct, tax_amount_ccy,
                                          price_status)
        VALUES (v_po_id, v_line_no, v_material, v_asset, v_qty,
                COALESCE(v_line->>'unit', CASE WHEN v_asset IS NOT NULL THEN 'unit' ELSE 'kg' END), v_formula, v_price,
                v_amount, v_line->'expected_assay', v_line->>'notes', v_user,
                v_src, v_prov,
                v_tax_code, v_tax_rate, v_line_tax,
                -- PUR-1:标成 fixed 而这一行挂着公式,由 guard_po_line_price_status
                -- 按名拒(PO_LINE_PRICE_STATUS_CONFLICT)—— 那一行真的按公式结算,
                -- 而这张纸是发给供应商的。
                v_price_status)
        RETURNING id INTO v_line_id;

        -- ── FIN-27:承诺时抄下结算条款 ───────────────────────────────────────
        -- 【与估价无关】公式定价的行下单时常常没有单价,而条款照样是谈定的 ——
        -- 有公式就抄,不看 estimated_unit_price。抄下之后,公式此后怎么改、
        -- 被停用还是被软删,都碰不到这一行的结算。
        IF v_formula IS NOT NULL THEN
            PERFORM commit_pricing_terms(v_formula, v_line_id, NULL);
            v_committed := v_committed + 1;
        END IF;

        -- ── EQP-PAY-1(R6):这条设备行的质保金 ────────────────────────────────
        -- ★【可选,而"没有"是【结构性】的】★ 负载里没有 retention 这一键,就【不建行】。
        -- 系统里因此不存在"0% 的质保金"这种东西 —— 表上那条 CHECK 是 percentage > 0,
        -- 一行 0% 存不进去。"没有质保金"与"0% 质保金"是两个不同的事实,
        -- 而这里保证它们连长得一样的机会都没有。
        --
        -- 【为什么在这支函数里,而不是建完单之后再补一刀】质保金是条款的一部分。
        -- 分成两次调用,第二次失败就会留下一张【条款不全】的单,而它看起来完全正常。
        v_ret := v_line->'retention';
        IF v_ret IS NOT NULL AND jsonb_typeof(v_ret) = 'object' THEN
            IF v_asset IS NULL THEN
                RAISE EXCEPTION 'RETENTION_NOT_AN_EQUIPMENT_LINE|%', v_line_no
                  USING HINT = '质保金是设备的事 —— 一条材料行没有验收,也就没有可以起算的锚';
            END IF;
            INSERT INTO purchase_order_line_retentions
                (purchase_order_line_id, percentage, fixed_amount_ccy, retention_months,
                 anchor_event, notes)
            VALUES (v_line_id,
                    (v_ret->>'percentage')::numeric,
                    (v_ret->>'fixed_amount_ccy')::numeric,
                    COALESCE((v_ret->>'retention_months')::integer, 12),
                    COALESCE(v_ret->>'anchor_event', 'acceptance_complete'),
                    v_ret->>'notes');
            v_retentions := v_retentions + 1;
        END IF;
    END LOOP;

    -- 【净额那一列的含义没有变】estimated_total_ccy 仍然是净额 —— 审批级别、
    -- 付款里程碑的百分比、现金预测三样都挂在它上面(见该列注释)。税另立一列。
    UPDATE purchase_orders SET estimated_total_ccy = v_total,
                               tax_total_ccy = CASE WHEN v_gst THEN v_tax_total ELSE NULL END,
                               updated_by = v_user
    WHERE id = v_po_id;

    -- EQP-PAY-1:行落完了,所以这张单的种类【现在】问得出来。混装已在上面拒掉,
    -- 所以这两种情形互斥。
    v_kind := CASE WHEN v_n_asset > 0 THEN 'equipment' ELSE 'material' END;

    -- 付款计划是【可选的】:有些采购就是到货即付,没有分期可言。
    IF p_payment_terms IS NOT NULL AND jsonb_typeof(p_payment_terms) = 'array'
       AND jsonb_array_length(p_payment_terms) > 0 THEN
        FOR v_term IN SELECT * FROM jsonb_array_elements(p_payment_terms)
        LOOP
            v_expect := v_expect + 1;
            v_seq := (v_term->>'seq')::integer;
            IF v_seq IS DISTINCT FROM v_expect THEN
                RAISE EXCEPTION 'TERMS_SEQ_INVALID';
            END IF;
            v_pct_total := v_pct_total + COALESCE((v_term->>'percentage')::numeric, 0);

            -- ── EQP-PAY-1(R5):这一期的里程碑,在这一类单上用得上吗 ────────
            -- 【此前这里一个字都不校验】—— 直接 INSERT,让表上的 CHECK 去炸,
            -- 于是屏幕上拿到的是一条裸约束原文。现在先按名拒。
            SELECT CASE WHEN v_kind = 'equipment' THEN applies_to_equipment
                        ELSE applies_to_material END
            INTO v_applicable
            FROM payment_trigger_events WHERE code = v_term->>'trigger_event';

            IF v_applicable IS NULL THEN
                RAISE EXCEPTION 'TERMS_EVENT_UNKNOWN|%|%', v_seq, COALESCE(v_term->>'trigger_event', '?')
                  USING HINT = '不认识这一种付款里程碑 —— 可选的种类是 payment_trigger_events 里的行';
            END IF;
            IF NOT v_applicable THEN
                RAISE EXCEPTION 'PO_TERM_EVENT_NOT_APPLICABLE|%|%|%|%',
                    v_code, v_seq, v_term->>'trigger_event', v_kind
                  USING HINT = '这一种里程碑在这一类采购单上用不上 —— 一台机器永远不会被化验(post_assay)。可选的种类见 payment_trigger_events 的适用性两列';
            END IF;

            INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                                      fixed_amount_ccy, trigger_event, due_date, notes)
            VALUES (v_po_id, v_seq, v_term->>'label',
                    (v_term->>'percentage')::numeric,
                    (v_term->>'fixed_amount_ccy')::numeric,
                    v_term->>'trigger_event',
                    (v_term->>'due_date')::date,
                    v_term->>'notes');
            v_term_count := v_term_count + 1;
        END LOOP;

        IF v_pct_total > 100 THEN
            RAISE EXCEPTION 'TERMS_PCT_EXCEEDS|%', v_pct_total;
        END IF;
    END IF;

    -- APR-2:提单即留痕。级别留空 —— 级别是【审批当时】按金额算出来的,
    -- 提单时算出来存下就是一个会过期的副本。
    -- 审批生效时这是一次【提交】;未生效时没有人做过决定,记 auto_approved ——
    -- 与 APR-1 回填那三张旧单同一个词,理由也同一个:记录真实发生的事,不要把
    -- "系统直接盖章"伪装成一次人的决定。
    IF v_appr_on THEN
        PERFORM record_approval_decision('purchase_order', v_po_id, 'submitted', NULL, NULL);
    ELSE
        PERFORM record_approval_decision('purchase_order', v_po_id, 'auto_approved', NULL,
            '审批流未启用(finance_settings.approvals_enabled = false)—— 系统直接盖章,没有人做过这个决定');
    END IF;

    RETURN jsonb_build_object(
        'purchase_order_id', v_po_id,
        'code', v_code,
        'estimated_total_ccy', v_total,
        'tax_total_ccy', CASE WHEN v_gst THEN v_tax_total ELSE NULL END,
        'gross_total_ccy', CASE WHEN v_gst THEN v_total + v_tax_total ELSE NULL END,
        'line_count', v_count,
        'committed_line_count', v_committed,
        'term_count', v_term_count,
        'retention_count', v_retentions,
        'order_kind', v_kind
    );
END;
$function$
;
-- ── amend_purchase_order:付款条款 / 交货地点 / 定价状态 ──────────
-- 【DROP + CREATE】理由与 create_purchase_order 逐字相同:签名多了一个参数。
DROP FUNCTION public.amend_purchase_order(uuid, text, jsonb, jsonb);

CREATE OR REPLACE FUNCTION public.amend_purchase_order(p_purchase_order_id uuid, p_reason text, p_header jsonb DEFAULT NULL::jsonb, p_lines jsonb DEFAULT NULL::jsonb, p_payment_terms jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_po       record;
    v_el       jsonb;
    v_line_id  uuid;
    v_qty      numeric;
    v_price    numeric;
    v_price_status text;      -- PUR-1:这一行的定价状态选择
    -- ── PUR-1:付款条款 ─────────────────────────────────────────────────────
    v_term       jsonb;
    v_seq        integer;
    v_expect     integer;
    v_pct_total  numeric;
    v_new_date date;
    v_fx       numeric;
    v_total    numeric;
    v_plan_fixed numeric;
    v_plan_pct   numeric;
    v_changed  integer := 0;
    -- ── PO-GST-1:改单之后,存下来的税要跟着改过的行走 ────────────────────────
    v_gst        boolean := gst_registered();
    v_sup_tax_default text;
    v_tax_code   text;
    v_tax_rate   numeric;
BEGIN
    PERFORM require_permission('module.purchasing.edit');

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        -- 【理由必填】一次改动没有理由,历史上就是一行"数字变了"而没有"为什么"。
        RAISE EXCEPTION 'PO_AMEND_REASON_REQUIRED';
    END IF;

    SELECT * INTO v_po FROM purchase_orders
     WHERE id = p_purchase_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;

    -- 【已结束 / 已作废的单不能改】先 reopen,让状态变化成为一次有记录的动作,
    -- 而不是修改的副作用。
    IF v_po.status IN ('closed','cancelled') THEN
        RAISE EXCEPTION 'PO_NOT_AMENDABLE|%|%', v_po.code, v_po.status;
    END IF;

    -- PO-GST-1:新增行要用到供应商的默认进项税码(与建单同一条播种规则)。
    SELECT default_tax_code INTO v_sup_tax_default FROM suppliers WHERE id = v_po.supplier_id;

    -- 理由传给留痕触发器(触发器读不到函数参数)
    PERFORM set_config('evoltrya.amend_reason', btrim(p_reason), true);
    PERFORM set_config('evoltrya.po_amend_ctx', '1', true);

    -- ── 表头 ────────────────────────────────────────────────────────────────
    IF p_header IS NOT NULL AND jsonb_typeof(p_header) = 'object' THEN
        v_new_date := COALESCE((p_header->>'order_date')::date, v_po.order_date);
        -- 【汇率从不由调用方递入】改单据日就要重取牌价:缺牌价即拒绝、绝不编一个。
        -- 采购是我们买外币 → tt_sell。本位币恒 1(定义,不是兜底)。
        IF v_new_date IS DISTINCT FROM v_po.order_date THEN
            IF v_po.currency = base_currency_code() THEN
                v_fx := 1;
            ELSE
                v_fx := fx_rate_for(v_po.currency, v_new_date, 'tt_sell');
            END IF;
        ELSE
            v_fx := v_po.fx_rate;
        END IF;

        UPDATE purchase_orders SET
            order_date = v_new_date,
            expected_delivery_date = CASE WHEN p_header ? 'expected_delivery_date'
                THEN (p_header->>'expected_delivery_date')::date ELSE expected_delivery_date END,
            incoterm = CASE WHEN p_header ? 'incoterm' THEN p_header->>'incoterm' ELSE incoterm END,
            terms_text = CASE WHEN p_header ? 'terms_text' THEN p_header->>'terms_text' ELSE terms_text END,
            notes = CASE WHEN p_header ? 'notes' THEN p_header->>'notes' ELSE notes END,
            -- PUR-1:交货地点。【键在不在,与值是不是空,是两件事】——
            -- 不传这个键 = 不动它;传一个空串 = 把它清掉(收成 NULL,于是纸上不印)。
            delivery_location = CASE WHEN p_header ? 'delivery_location'
                THEN NULLIF(btrim(COALESCE(p_header->>'delivery_location', '')), '')
                ELSE delivery_location END,
            fx_rate = v_fx,
            updated_by = v_user
        WHERE id = p_purchase_order_id;
    END IF;

    -- ── 明细 ────────────────────────────────────────────────────────────────
    IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
        FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
        LOOP
            v_line_id := NULLIF(v_el->>'id', '')::uuid;

            IF COALESCE((v_el->>'remove')::boolean, false) THEN
                IF v_line_id IS NULL THEN
                    RAISE EXCEPTION 'PO_LINE_REMOVE_NEEDS_ID';
                END IF;
                -- 收过货的行删不掉 —— 守卫触发器点名拒(货真的到了,单据上却没有出处)
                DELETE FROM purchase_order_lines
                 WHERE id = v_line_id AND purchase_order_id = p_purchase_order_id;
                v_changed := v_changed + 1;
                CONTINUE;
            END IF;

            v_qty := (v_el->>'quantity')::numeric;
            -- EQP-1a-TAIL:设备行同一条规矩 —— 省略即给默认,给错则按名拒。
            IF (v_el->>'asset_id') IS NOT NULL THEN
                IF v_qty IS NULL THEN v_qty := 1; END IF;
                IF v_qty <> 1 THEN
                    RAISE EXCEPTION 'PO_LINE_EQUIPMENT_QTY|%|%', COALESCE(v_el->>'line_no','?'), v_qty
                      USING HINT = '一条设备行订的是【一台】机器 —— 四台是四条行';
                END IF;
                IF COALESCE(v_el->>'unit', 'unit') <> 'unit' THEN
                    RAISE EXCEPTION 'PO_LINE_EQUIPMENT_UNIT|%|%', COALESCE(v_el->>'line_no','?'), v_el->>'unit'
                      USING HINT = '设备行的计量单位恒为 unit —— 留空即取它';
                END IF;
            END IF;
            IF v_qty IS NULL OR v_qty <= 0 THEN
                RAISE EXCEPTION 'PO_LINE_QUANTITY_INVALID|%', COALESCE(v_el->>'line_no', '?');
            END IF;
            v_price := NULLIF(v_el->>'estimated_unit_price', '')::numeric;
            -- PUR-1:定价状态 —— 与建单同一条校验,同一个码。
            v_price_status := NULLIF(btrim(COALESCE(v_el->>'price_status', '')), '');
            IF v_price_status IS NOT NULL AND v_price_status NOT IN ('fixed', 'provisional') THEN
                RAISE EXCEPTION 'PO_LINE_PRICE_STATUS_INVALID|%|%',
                    COALESCE(v_el->>'line_no', '?'), v_price_status
                  USING HINT = '定价状态只有两个取值:fixed(定价)与 provisional(暂定价)。留空表示按事实推导';
            END IF;

            IF v_line_id IS NULL THEN
                -- 新增行:与建单同口径(金额 = 数量 × 单价,无价则 0)
                -- EQP-1a:改单也能加设备行 —— 恰一非空,与建单同一句话
                IF num_nonnulls((v_el->>'material_id')::uuid, (v_el->>'asset_id')::uuid) <> 1 THEN
                    RAISE EXCEPTION 'PO_LINE_KIND_INVALID|%', COALESCE(v_el->>'line_no', '?')
                      USING HINT = '一行要么订材料、要么订一台已建卡的设备,不能都给、也不能都不给';
                END IF;
                IF (v_el->>'asset_id') IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM fixed_assets WHERE id = (v_el->>'asset_id')::uuid
                ) THEN
                    RAISE EXCEPTION 'ASSET_NOT_FOUND|%', v_el->>'asset_id';
                END IF;
                -- ── PO-GST-1:改单加进来的【新行】与建单同口径 ──────────────
                -- ★ 税率按【这张单的下单日】解析,不是按今天 ★ 一张单上所有的行
                -- 共用同一个日期的税率;拿今天的税率去补一条 2023 年的单上的新行,
                -- 会让同一张纸上出现两个不同的税率。
                IF v_gst THEN
                    v_tax_code := resolve_tax_code(v_el->>'tax_code', v_sup_tax_default, 'input', 'supplier');
                    v_tax_rate := tax_rate_for(v_tax_code, v_po.order_date);
                ELSE
                    IF NULLIF(btrim(COALESCE(v_el->>'tax_code', '')), '') IS NOT NULL THEN
                        RAISE EXCEPTION 'GST_NOT_REGISTERED|%', v_el->>'tax_code';
                    END IF;
                    v_tax_code := NULL; v_tax_rate := NULL;
                END IF;
                INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, asset_id,
                    quantity, unit, estimated_unit_price, estimated_amount_ccy, notes, created_by,
                    tax_code, tax_rate_pct, tax_amount_ccy, price_status)
                VALUES (p_purchase_order_id,
                    COALESCE((v_el->>'line_no')::integer,
                        (SELECT COALESCE(MAX(line_no), 0) + 1 FROM purchase_order_lines
                          WHERE purchase_order_id = p_purchase_order_id)),
                    (v_el->>'material_id')::uuid, (v_el->>'asset_id')::uuid,
                    v_qty, COALESCE(v_el->>'unit', CASE WHEN (v_el->>'asset_id') IS NOT NULL THEN 'unit' ELSE 'kg' END),
                    v_price, round(v_qty * COALESCE(v_price, 0), 2), v_el->>'notes', v_user,
                    v_tax_code, v_tax_rate,
                    CASE WHEN v_tax_rate IS NULL THEN NULL
                         ELSE tax_amount_for(round(v_qty * COALESCE(v_price, 0), 2), v_tax_rate) END,
                    v_price_status);
            ELSE
                -- 【已收下限由触发器把关】砍到已收之下 → PO_LINE_BELOW_RECEIVED
                UPDATE purchase_order_lines SET
                    quantity = v_qty,
                    -- PUR-1:键在不在,与值是不是空,是两件事(与表头那一条同形)。
                    -- 传 '' 把它清回 NULL —— 也就是"别再替我选了,按事实推导"。
                    price_status = CASE WHEN v_el ? 'price_status'
                        THEN v_price_status ELSE price_status END,
                    unit = COALESCE(v_el->>'unit', unit),
                    estimated_unit_price = CASE WHEN v_el ? 'estimated_unit_price'
                        THEN v_price ELSE estimated_unit_price END,
                    estimated_amount_ccy = round(v_qty * COALESCE(
                        CASE WHEN v_el ? 'estimated_unit_price' THEN v_price
                             ELSE estimated_unit_price END, 0), 2),
                    -- ★★【PO-GST-1:改过的行,税跟着【新的净额】重算 —— 但税【率】
                    --     不重解析】★★ 改单改的是数量或单价,不是这一行的税务性质,
                    --     也不是这张单的日期。用行上冻着的那个 tax_rate_pct 重算,
                    --     于是 ①c 那条"存下来的税不随今天的税率漂移"在改单之后仍然成立。
                    --     【历史行(tax_rate_pct 为 NULL)保持 NULL】—— 改一改数量,
                    --     不该让一张 PO-GST-1 之前的单凭空长出一个它当时没有的税额。
                    tax_amount_ccy = CASE WHEN tax_rate_pct IS NULL THEN NULL
                        ELSE tax_amount_for(round(v_qty * COALESCE(
                            CASE WHEN v_el ? 'estimated_unit_price' THEN v_price
                                 ELSE estimated_unit_price END, 0), 2), tax_rate_pct) END
                WHERE id = v_line_id AND purchase_order_id = p_purchase_order_id;
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', v_line_id;
                END IF;
            END IF;
            v_changed := v_changed + 1;
        END LOOP;
    END IF;

    -- ── 总额:与明细【同一条语句】算完 ───────────────────────────────────────
    -- 【顺序就是要点】这一列是 APR-2 作废触发器盯着的东西。若先改行、再另起一条
    -- 语句写总额,触发器判断时依据的总额与产生它的那批行已经不是一回事 ——
    -- 那会产生一个看起来完全正常、却基于陈旧数字的审批决定。
    -- PO-GST-1:税额合计与净额【在同一条语句里】算完 —— 理由与上面那段逐字相同
    -- (作废触发器盯着的是净额那一列,而两个数必须来自同一批行)。
    -- 【SUM 而不是 COALESCE(...,0)】全是 NULL(历史单/未注册)时合计就是 NULL,
    -- 那正是"这张单没有税"与"这张单的税是零"的区别。
    UPDATE purchase_orders po SET
        estimated_total_ccy = COALESCE(s.total, 0),
        tax_total_ccy = s.tax_total,
        updated_by = v_user
    FROM (SELECT COALESCE(SUM(estimated_amount_ccy), 0) AS total,
                 SUM(tax_amount_ccy) AS tax_total
            FROM purchase_order_lines WHERE purchase_order_id = p_purchase_order_id) s
    WHERE po.id = p_purchase_order_id;

    SELECT estimated_total_ccy INTO v_total FROM purchase_orders WHERE id = p_purchase_order_id;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★【PUR-1:改单可以改付款条款 —— 而档案接得住,那才是本段的重点】★★
    -- ════════════════════════════════════════════════════════════════════════
    --   【此前改不了,而那【不是】一道锁】(2026-09-08 实测):没有参数、没有
    --   表单字段,而 purchase_order_payment_terms 的 INSERT/UPDATE/DELETE 策略
    --   对持 module.purchasing.edit 的人【全开】—— 也就是说这条路今天就通,
    --   通的是一条直连改库、且在档案里【完全沉默】的路。
    --   留痕在触发器上(trg_po_history_payment_term),不在这里 —— 与 PUR-2 同一条:
    --   触发器接得住每一条路径,包括上面那一条。
    --
    --   ★【为什么是【按期落位】而不是整表删了重灌】★
    --     删了重灌在档案里读起来是"整份计划被换掉了",而真相常常是"第二期
    --     从 40% 改成了 30%"。按 seq 落位之后,没动过的那几期【一条历史都不长】
    --     (触发器对无改动的 UPDATE 直接返回),读的人一眼看得出改的是哪一期。
    --
    --   ★【NULL 与 [] 是两件事】★ 不传这个参数 = 不动付款计划(既有调用方
    --     一个字不用改);传一个空数组 = 把整份计划清掉,那是一次明说的动作。
    --
    --   【适用性不在这里判】trg_po_payment_terms_event_applicable 已经在表上按名拒
    --   (PO_TERM_EVENT_NOT_APPLICABLE)—— 在这里再抄一遍就是同一条规矩的第二份实现。
    IF p_payment_terms IS NOT NULL THEN
        IF jsonb_typeof(p_payment_terms) <> 'array' THEN
            RAISE EXCEPTION 'PO_PAYMENT_TERMS_INVALID|%', jsonb_typeof(p_payment_terms)
              USING HINT = '付款计划要么不传(不动它),要么传一个数组(整份计划按期落位)';
        END IF;

        -- 【先整份验完,再动一个字】—— 验到一半才拒,会留下一份改了一半的计划。
        v_expect := 0; v_pct_total := 0;
        FOR v_term IN SELECT * FROM jsonb_array_elements(p_payment_terms)
        LOOP
            v_expect := v_expect + 1;
            v_seq := (v_term->>'seq')::integer;
            -- 与建单【同一个码】:一条规矩只能有一个码,否则屏幕上会有一半的
            -- 拒绝印出裸码(EQP-PAY-1 A2 那一课)。
            IF v_seq IS DISTINCT FROM v_expect THEN
                RAISE EXCEPTION 'TERMS_SEQ_INVALID';
            END IF;
            v_pct_total := v_pct_total + COALESCE((v_term->>'percentage')::numeric, 0);
        END LOOP;
        IF v_pct_total > 100 THEN
            RAISE EXCEPTION 'TERMS_PCT_EXCEEDS|%', v_pct_total;
        END IF;

        -- 多出来的期数先删(触发器记 payment_term_remove)
        DELETE FROM purchase_order_payment_terms
         WHERE purchase_order_id = p_purchase_order_id AND seq > v_expect;

        FOR v_term IN SELECT * FROM jsonb_array_elements(p_payment_terms)
        LOOP
            INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label,
                percentage, fixed_amount_ccy, trigger_event, due_date, notes)
            VALUES (p_purchase_order_id, (v_term->>'seq')::integer, v_term->>'label',
                (v_term->>'percentage')::numeric, (v_term->>'fixed_amount_ccy')::numeric,
                v_term->>'trigger_event', (v_term->>'due_date')::date, v_term->>'notes')
            ON CONFLICT (purchase_order_id, seq) DO UPDATE SET
                label            = EXCLUDED.label,
                percentage       = EXCLUDED.percentage,
                fixed_amount_ccy = EXCLUDED.fixed_amount_ccy,
                trigger_event    = EXCLUDED.trigger_event,
                due_date         = EXCLUDED.due_date,
                notes            = EXCLUDED.notes;
            v_changed := v_changed + 1;
        END LOOP;
    END IF;

    -- ── 付款计划:定额腿必须仍然加得上 ───────────────────────────────────────
    -- 【PUR-1:这道闸现在【也】管新传进来的那份计划】—— 顺序没有变,
    -- 它读的仍然是库里此刻的计划,而上面那一段已经把新计划落位了。
    SELECT COALESCE(SUM(fixed_amount_ccy), 0), COALESCE(SUM(percentage), 0)
      INTO v_plan_fixed, v_plan_pct
      FROM purchase_order_payment_terms WHERE purchase_order_id = p_purchase_order_id;

    IF v_plan_fixed > 0 THEN
        -- 【定额腿在场:拒绝,不缩放】一条定额腿之所以是定额,正因为有人谈的是一个
        -- 数字而不是一个比例。替它按比例缩放,就是系统替操作员重新谈了一次条款,
        -- 而没有任何人被告知(与调高信用额度让告警安静同族)。
        -- 报出三个数:订单额、计划额、差额 —— 补救归操作员,而两条路都是有记录的动作。
        DECLARE
            v_plan_total numeric :=
                v_plan_fixed + round(v_total * v_plan_pct / 100.0, 2);
        BEGIN
            IF round(v_plan_total, 2) <> round(v_total, 2) THEN
                RAISE EXCEPTION 'PO_PLAN_FIXED_MISMATCH|%|%|%',
                    round(v_total, 2), round(v_plan_total, 2),
                    round(v_plan_total - v_total, 2);
            END IF;
        END;
    END IF;
    -- 【比例计划不在此列,而且这不是遗漏】百分比的意思就是"订单的这一份",
    -- 它按构造跟着总额走;定额的意思是"这么多钱",只有它需要被拦住。

    PERFORM set_config('evoltrya.po_amend_ctx', '', true);
    PERFORM set_config('evoltrya.amend_reason', '', true);

    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'lines_changed', v_changed,
        'estimated_total_ccy', v_total,
        'approval_status', (SELECT approval_status FROM purchase_orders WHERE id = p_purchase_order_id));
END;
$function$
;
-- ── purchase_orders_masked:追加 delivery_location ────────────────────────
CREATE OR REPLACE VIEW public.purchase_orders_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    supplier_id,
    order_date,
    expected_delivery_date,
    currency,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN estimated_total_ccy
            ELSE NULL::numeric
        END AS estimated_total_ccy,
    status,
    approval_status,
    approved_at,
    approved_by,
    incoterm,
    terms_text,
    notes,
    closed_at,
    cancelled_at,
    cancel_reason,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    deleted_by,
    delete_reason,
    cancelled_by,
    -- CONTRACT-1:这张单据挂在哪一份合同之下。**新列加在末尾** ——
    -- CREATE OR REPLACE VIEW 只许末尾追加,中间插一列要 DROP + 重建。
    -- 【它必须出现在这张视图里】purchase_orders 是遮蔽表,而 colgrant 那道闸要求
    -- 它的每一列要么被列授权、要么在 _masked 里(WO-1a 那一课:ADD/GRANT/_masked
    -- 三件事要在同一次迁移里做完 —— KPI-1 为漏掉后两件付过一次账)。
    -- 【条款不从这一列读】它只是导航;条款读 contract_document_terms 那份副本。
    contract_id,
    -- PO-GST-1(2026-09-03):这张单的税额合计。**是钱** —— 与 estimated_total_ccy
    -- 同一扇门。净额那一列一个字节没动,含税额在读的那一侧相加(见列注释)。
        CASE
            WHEN has_permission('data.view_prices'::text) THEN tax_total_ccy
            ELSE NULL::numeric
        END AS tax_total_ccy,
    -- PO-GST-1-fu2:含税额 —— **屏幕读这一列,自己不做加法**。
    -- 委托 ①d 的那条要求:屏幕与 PDF 必须读同一个来源。net 与 tax 本来就是同两列,
    -- 而 gross = net + tax 这次加法若两边各写一遍,就是第二份实现。
    -- 【不落库成第三列】导出量不存;存了就会有"净额改了而它没跟上"的错数。
    -- 遮蔽自然传导:分量为 NULL 时整个表达式就是 NULL。
        CASE WHEN has_permission('data.view_prices'::text)
             THEN estimated_total_ccy + COALESCE(tax_total_ccy, 0)
             ELSE NULL::numeric END AS gross_total_ccy,
    -- 这张单【算过税吗】—— NULL 的税额合计【不是】零税:它是"开在 PO-GST-1 之前,
    -- 或开在 GST 未注册的时候"。屏幕靠它决定说哪一句话,而不是印一个 0.00。
    (tax_total_ccy IS NOT NULL) AS carries_tax,
    -- PUR-1(2026-09-08):交货地点。**新列加在末尾** —— CREATE OR REPLACE VIEW
    -- 只许末尾追加,中间插一列要 DROP + 重建(与上面 contract_id 那一条同一课)。
    -- 【不遮蔽】它是一个地址,不是钱。
    delivery_location
   FROM purchase_orders
  WHERE has_permission('module.purchasing.view'::text);


-- ── purchase_order_lines_masked:追加 price_status ────────────────────────
CREATE OR REPLACE VIEW public.purchase_order_lines_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_id,
    line_no,
    material_id,
    quantity,
    unit,
    pricing_formula_id,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN estimated_unit_price
            ELSE NULL::numeric
        END AS estimated_unit_price,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN estimated_amount_ccy
            ELSE NULL::numeric
        END AS estimated_amount_ccy,
    expected_assay,
    notes,
    created_at,
    created_by,
    price_source,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN price_provenance
            ELSE NULL::jsonb
        END AS price_provenance,
    asset_id,
    -- PROC-1B-iii fu1:遮蔽表加一列 = 三件事(列 + 列级授权 + 本视图)。
    -- 【不遮蔽,原样透出】它是工艺路由要用的事实,不是钱、不是个人信息。
    deep_discharge_judgement_code,
    -- PO-GST-1(2026-09-03):税码与税率【不遮蔽】—— 一个是分类,一个是法定税率,
    -- 都不是钱;税【额】是钱,而且从被扣住的净额推得出来,所以随 data.view_prices,
    -- 与 estimated_amount_ccy 同一扇门。
    tax_code,
    tax_rate_pct,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN tax_amount_ccy
            ELSE NULL::numeric
        END AS tax_amount_ccy,
    -- PUR-1(2026-09-08):这一行的定价状态选择。**新列加在末尾**(同上一条)。
    -- 【不遮蔽】它是一个分类 —— 它说的是"这个价定了没有",不是那个价是多少。
    price_status
   FROM purchase_order_lines
  WHERE has_permission('module.purchasing.view'::text);



-- ════════════════════════════════════════════════════════════════════════════
-- 五 · 新建函数的 EXECUTE 权限(zzz_function_grants 那一课,逐个补)
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【为什么这一段非有不可 —— 而它是量出来的】★★
--   db/views/zzz_function_grants.sql 抬头写着:PUBLIC 的默认 EXECUTE 在
--   OPS-3 那次被整批收回过("每一次 REVOKE 都活不过一次重建")。
--   但那是一次【对当时已存在的函数】的 REVOKE,不是 ALTER DEFAULT PRIVILEGES ——
--   **今天新建的任何一支函数,仍然带着给 PUBLIC 的默认 EXECUTE 出生**,
--   而 PUBLIC 里坐着 anon,anon 就是互联网。
--   所以本刀新建/重建的四支逐个收回、逐个授回,落到与线上其余函数
--   一模一样的 ACL(postgres / authenticated / service_role,实测对照过)。
--
--   【为什么不重放 zzz_function_grants 开头那两句】那两句是
--   REVOKE ... ON ALL FUNCTIONS + GRANT ... ON ALL FUNCTIONS —— 重放它们会把
--   文件后半段【逐个收回】的那些内层函数(calculate_metal_price_internal、
--   sod_* 三支、gst_registered……)重新授给 authenticated,
--   也就是把 SOD-1 与 GST-1 的处置一并撤销。**范围大的那句不是更安全的那句。**
-- ★★【本刀【不】自己写 REVOKE/GRANT —— 而那是一次遵从,不是一次遗漏】★★
--   PostgreSQL 把新函数的 EXECUTE 默认授给 PUBLIC,而 PUBLIC 里坐着 anon。
--   这件事在本仓库发生过三次(FIN-22 / FIN-23 / FIN-27),而处置【已经做完了】:
--   db/apply_migration.sh 在【同一个事务里】把 db/views/zzz_function_grants.sql
--   重跑一遍(纯 GRANT/REVOKE、幂等、实测重跑两遍 178 支函数的 proacl 一个不变),
--   于是本刀新建的四支 —— guard_po_line_price_status / trg_po_history_payment_term /
--   create_purchase_order / amend_purchase_order —— 自动落到与其余函数
--   一模一样的 ACL(postgres / authenticated / service_role)。
--   ★ 在这里再抄一遍那两行,就是同一条规矩的第二份实现 ★:
--     preflight_migration.py 的抬头已经把话说死了 ——「预防比检测强,所以那一半
--     不在这里」。而更糟的是,想"稳妥"改成重放 zzz 开头那两句
--     (REVOKE/GRANT ON ALL FUNCTIONS)会把该文件后半段逐个收回的内层函数
--     (calculate_metal_price_internal、sod_* 三支、gst_registered……)
--     重新授给 authenticated —— **范围大的那句不是更安全的那句**。
--   【应用方式因此不是可选的】:./db/apply_migration.sh db/migrations/<本文件>

-- ════════════════════════════════════════════════════════════════════════════
-- 六 · 本刀【刻意没有做】的那一件事
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【审批状态那一行,一个字都没有印,而这是一次裁定,不是一次遗漏】★★
--   Tim 的字段清单里有 `Approved by:` 加上批准人的名字。**本刀不建它,
--   也【不】在那个位置印任何东西。**理由是量出来的(2026-09-08):
--     · finance_settings.approvals_enabled = false;
--     · 线上 11 张采购单,approval_status 全是 'approved';
--     · 而 create_purchase_order 自己把这件事记成了 auto_approved,理由栏写着
--       "审批流未启用 —— 系统直接盖章,没有人做过这个决定"。
--   也就是说【今天没有任何人批准过任何一张单】,也就没有一个名字填得上那一行。
--   印下单人的名字、印 CFO 的名字、或者印 "System" —— 三者都是
--   **一张发给供应商的单据上的假话**。
--   开关本身也【没有任何界面】能打开(approvals_readiness 报得出 can_enable,
--   但没有页面调用它去切换)。
--   ★ 打开审批链是它自己的一刀 ★ —— 它伸出采购单之外(报销、请假、销售单、
--   贷项凭证都是候选),已登记在 docs/forward-queue.md。
--   **不要"把字段补齐"。** 补齐它的唯一正确方式是先让一个人真的批准过。

COMMIT;
