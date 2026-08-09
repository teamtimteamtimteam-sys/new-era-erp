-- PUR-1:采购单单据 —— 数据一处导出、签发即成档
--
-- 规格在 docs/purchase-order-document.md(A 部分的报告先于本文件写成)。要点:
--   * "发送" = 生成并下载,【签发】作为事实记录(谁、何时、第几版、字节的 SHA-256);
--     没有"已发送"标志 —— 系统不知道对方收没收到,记录自己不知道的事是 ?? 0 那一族谎。
--   * 签发的是【记录,不是视图】:字节存进私有桶,一次签发一个对象,绝不覆盖。
--     付款计划抄副本、计价条款冻结在承诺上 —— 同一个形状第三次出现,答案不变。
--   * 【定价条款印在单据上】(B 部分):条款只活在数据库里的话,两边承诺的就不是
--     同一件事。逐行状态由 po_document_data 在 SQL 里推导 —— 一份实现,页面与 PDF
--     同源,fixture 直接断言("预览要问数据库"那条规矩,这次是单据要问数据库)。
--   * 【单据币种,只有单据币种】(D 部分):输出里没有 fx_rate、没有本位币数字。
--
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. 私有桶(finance-attachments 四件套的形状)
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO storage.buckets (id, name, public)
VALUES ('po-documents', 'po-documents', false);

CREATE POLICY "authenticated read po-documents"
    ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'po-documents');

CREATE POLICY "authenticated upload po-documents"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'po-documents');

-- 【没有 update / delete 策略,这是有意的】签发件是档案:一次签发一个对象,
-- 改与删都不该有第二个写法 —— 与 finance-attachments 不同,那边是可管理的附件。

-- ════════════════════════════════════════════════════════════════════════════
-- 2. 签发记录:只增不改
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.po_issues (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_order_id uuid NOT NULL REFERENCES public.purchase_orders (id),
    -- 每张单自己的版本号,从 1 起。供应商手里那份是【某个具体版本】——
    -- 重新签发产生新版本,旧版本原样留着(fixture 36 钉住)。
    version           integer NOT NULL CHECK (version >= 1),
    -- po-documents 桶里的对象键;字节的 SHA-256 使对象可对着记录校验
    file_path         text NOT NULL,
    sha256            text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at         timestamptz NOT NULL DEFAULT now(),
    issued_by         uuid,
    UNIQUE (purchase_order_id, version)
);

CREATE INDEX idx_po_issues_po ON public.po_issues (purchase_order_id, version DESC);

COMMENT ON TABLE public.po_issues IS
    '采购单签发档(PUR-1),只增不改。谁、何时、第几版、哪个对象、字节摘要。没有"已发送"标志:系统不知道对方收没收到。唯一写入口 record_po_issue();重新签发 = 新的一行,绝不覆盖旧行 —— 供应商手里那份是某个具体版本。';

CREATE OR REPLACE FUNCTION public.guard_po_issues_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 签发档被改写过,就不再证明供应商手里那份是什么了。自己报名(FIN-31)。
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'PO_ISSUE_APPEND_ONLY|update|%', OLD.id;
    ELSE
        RAISE EXCEPTION 'PO_ISSUE_APPEND_ONLY|delete|%', OLD.id;
    END IF;
END;
$function$;

CREATE TRIGGER trg_po_issues_append_only
    BEFORE UPDATE OR DELETE ON public.po_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_po_issues_append_only();

ALTER TABLE public.po_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY "po_issues select by permission"
    ON public.po_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text));
-- 【没有 INSERT 策略】唯一写入口是 record_po_issue()(属主权限)——
-- 与 approval_log 同一条:档案不该有第二个写法。

REVOKE SELECT ON public.po_issues FROM authenticated, anon;
GRANT SELECT (id, purchase_order_id, version, file_path, sha256, issued_at, issued_by)
    ON public.po_issues TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- 3. 单据数据:一份实现,PDF 与 fixture 同源
-- ════════════════════════════════════════════════════════════════════════════
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
BEGIN
    PERFORM require_permission('module.purchasing.view');

    SELECT po.id, po.code, po.order_date, po.expected_delivery_date, po.currency,
           po.status, po.approval_status, po.incoterm, po.terms_text, po.notes,
           po.estimated_total_ccy, po.supplier_id
    INTO v_po FROM purchase_orders po
    WHERE po.id = p_po_id AND po.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_po_id::text, '?');
    END IF;

    SELECT s.legal_name, s.address, s.country, s.tax_id
    INTO v_sup FROM suppliers s WHERE s.id = v_po.supplier_id;

    -- ── 逐行:定价状态在这里裁决,PDF 只负责画(docs/purchase-order-document.md §B)──
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'line_no', l.line_no,
        'material_name', m.name,
        'quantity', l.quantity,
        'unit', l.unit,
        'unit_price', l.estimated_unit_price,          -- 单据币种;可空
        'amount_ccy', l.estimated_amount_ccy,
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
            WHEN l.estimated_unit_price IS NOT NULL THEN 'fixed'
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
    JOIN materials m ON m.id = l.material_id
    LEFT JOIN pricing_term_commitments c ON c.purchase_order_line_id = l.id
    WHERE l.purchase_order_id = p_po_id;

    -- ── 付款计划(FIN-29 的承诺分期,原样印)────────────────────────────────
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'seq', t.seq, 'label', t.label, 'percentage', t.percentage,
        'fixed_amount_ccy', t.fixed_amount_ccy,
        'trigger_event', t.trigger_event, 'due_date', t.due_date, 'notes', t.notes
    ) ORDER BY t.seq), '[]'::jsonb)
    INTO v_terms
    FROM purchase_order_payment_terms t WHERE t.purchase_order_id = p_po_id;

    -- 【单据币种,只有单据币种】(§D)—— 这里没有 fx_rate,没有本位币数字。
    -- 本位币是内部口径:它决定审批级别,不该出现在供应商手里的纸上。
    RETURN jsonb_build_object(
        'code', v_po.code,
        'order_date', v_po.order_date,
        'expected_delivery_date', v_po.expected_delivery_date,
        'currency', v_po.currency,
        'status', v_po.status,
        'approval_status', v_po.approval_status,
        'incoterm', v_po.incoterm,
        'terms_text', v_po.terms_text,
        'notes', v_po.notes,
        'estimated_total_ccy', v_po.estimated_total_ccy,
        'supplier', jsonb_build_object(
            'legal_name', v_sup.legal_name, 'address', v_sup.address,
            'country', v_sup.country, 'tax_id', v_sup.tax_id),
        'lines', v_lines,
        'payment_terms', v_terms
    );
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 4. 签发:唯一写入口
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.record_po_issue(p_po_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po record;
    v_version integer;
    v_id uuid;
BEGIN
    PERFORM require_permission('module.purchasing.edit');

    SELECT id, code, approval_status INTO v_po
    FROM purchase_orders WHERE id = p_po_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_po_id::text, '?');
    END IF;
    -- 【未获批的单不能签发,无条件】审批关着时单据生来就是 approved,这里没有代价;
    -- 开着时,这补上 APR-2 A4 点名的缺口 ——"发给供应商"这个动作当时不存在,
    -- 现在存在了,就要把关。一张待批的单发出去,是在审批之前完成承诺。
    IF v_po.approval_status <> 'approved' THEN
        RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_po.code, v_po.approval_status;
    END IF;
    IF p_file_path IS NULL OR btrim(p_file_path) = '' THEN
        RAISE EXCEPTION 'ISSUE_FILE_PATH_REQUIRED';
    END IF;
    IF p_sha256 IS NULL OR p_sha256 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'ISSUE_SHA256_INVALID';
    END IF;

    -- 版本号逐单递增;UNIQUE (po, version) 挡并发,FOR UPDATE 挡同事务竞态
    PERFORM 1 FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
    SELECT COALESCE(max(version), 0) + 1 INTO v_version
    FROM po_issues WHERE purchase_order_id = p_po_id;

    INSERT INTO po_issues (purchase_order_id, version, file_path, sha256, issued_by)
    VALUES (p_po_id, v_version, p_file_path, p_sha256, auth.uid())
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('issue_id', v_id, 'version', v_version, 'code', v_po.code);
END;
$function$;

COMMIT;
