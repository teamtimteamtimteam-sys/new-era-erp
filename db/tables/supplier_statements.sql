-- db/tables/supplier_statements.sql
-- MES-8a(2026-10-16,MES-0 Q79 · MES-8 Step 0 Q7 · Q8 · Q9,Tim):一份【冻下来的】供应商对账单 —— 客户对账单(customer_statements)的形状,
--   对着应付那一侧。SST-YYYY-NNNN,按年无洞(next_supplier_statement_code,宽度 GREATEST(4, 位数),不截到 4 位)。
--   签发那一刻冻下来的:收件人(供应商的代码与名字)、我们的抬头(company_profile 的法定名、注册号、地址、联络)、期间、期初、发生(收货 · 费用 · 运费记上的应付)、贷记(冲销与改价调低)、付款、预付冲抵、期末(本位币),
--     每一笔【明细行】(lines,逐笔逐分录,收货行标着当时是不是暂定价)、期末的未结单据(open_items)、挂账的付款(on_account)、
--     【已收到、尚未计价】的收货(unpriced,只有数量,不计金额 —— Q8),以及勾稽的两边(ledger_base · list_base 与它们的差 0)。
--   ★【对不上就不签发】(Q7):期末(按总账 2000 归到这一家的分录算)必须等于【另一份独立推导】—— 期末未结单据(ap_aging_asof)
--     减挂账的付款、减登记的残留。差一分就 SUPPLIER_STATEMENT_DOES_NOT_TIE 按名拒;所以这一行里的数字【当时确实对得上】。
--   【更正 = 新起一行,旧的标掉,不删】(customer_statements / bank_reconciliations 逐字同源):superseded_at + by + 理由。
--   写入只走 issue_supplier_statement(SECURITY DEFINER,module.finance.edit);读 module.finance.view(对账单就是应付总账,决定 1)。
--   员工(报销)永远不会有一份 —— supplier_id 只指 suppliers。PDF 的版本在 supplier_statement_issues 里另算一层。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.supplier_statements (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                   text NOT NULL UNIQUE,
    supplier_id            uuid NOT NULL REFERENCES public.suppliers (id) ON DELETE RESTRICT,
    -- 【连收件人与抬头一起冻】PDF 只从这一行渲染(Q9):供应商改了名字、公司换了地址,寄出去的那一份照旧印当时的
    supplier_code          text NOT NULL,
    supplier_name          text NOT NULL,
    company                jsonb NOT NULL CHECK (jsonb_typeof(company) = 'object' AND btrim(COALESCE(company ->> 'legal_name', '')) <> ''),
    period_start           date NOT NULL,
    period_end             date NOT NULL,
    base_currency          text NOT NULL REFERENCES public.currencies (code),
    opening_base           numeric NOT NULL,
    charges_base           numeric NOT NULL,
    credits_base           numeric NOT NULL,
    payments_base          numeric NOT NULL,
    prepayments_base       numeric NOT NULL,
    closing_base           numeric NOT NULL,
    -- 勾稽的另一边:期末未结单据之和、挂账的付款、登记的残留(三者推出的期末与 closing_base 相等,签发时验过)
    list_base              numeric NOT NULL,
    on_account_base        numeric NOT NULL,
    residue_base           numeric NOT NULL,
    lines                  jsonb NOT NULL CHECK (jsonb_typeof(lines) = 'array'),
    open_items             jsonb NOT NULL CHECK (jsonb_typeof(open_items) = 'array'),
    on_account             jsonb NOT NULL CHECK (jsonb_typeof(on_account) = 'array'),
    unpriced               jsonb NOT NULL CHECK (jsonb_typeof(unpriced) = 'array'),
    by_currency            jsonb NOT NULL CHECK (jsonb_typeof(by_currency) = 'array'),
    issued_at              timestamptz NOT NULL DEFAULT now(),
    issued_by              uuid,
    superseded_at          timestamptz,
    superseded_by          uuid REFERENCES public.supplier_statements (id),
    superseded_reason      text,
    created_at             timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT supplier_statements_period_shape CHECK (period_end >= period_start),
    CONSTRAINT supplier_statements_supersede_shape
        CHECK ((superseded_at IS NULL) = (superseded_by IS NULL) AND (superseded_at IS NULL) = (superseded_reason IS NULL)),
    -- 等式在签发那一刻就验过;这里再钉一次【行本身】:期初 + 发生 − 贷记 − 付款 − 预付冲抵 = 期末;期末 = 未结 − 挂账 − 残留
    CONSTRAINT supplier_statements_arithmetic
        CHECK (round(opening_base + charges_base - credits_base - payments_base - prepayments_base, 2) = round(closing_base, 2)),
    CONSTRAINT supplier_statements_ties
        CHECK (round(list_base - on_account_base - residue_base, 2) = round(closing_base, 2))
);

CREATE INDEX supplier_statements_code_trgm ON public.supplier_statements USING gin (code extensions.gin_trgm_ops);
CREATE INDEX supplier_statements_superseded_by_rel ON public.supplier_statements (superseded_by);
CREATE INDEX idx_supplier_statements_supplier ON public.supplier_statements (supplier_id, period_end DESC);

COMMENT ON TABLE public.supplier_statements IS
    'MES-8a:一份供应商对账单 = 一行,而那一行是【抄下来的】。签发那一刻把期初 / 发生 / 贷记 / 付款 / 预付冲抵 / 期末六个本位币数、每一笔明细(收货行标暂定价)、期末未结单据、挂账付款、已收到尚未计价的收货(只有数量)一起冻在这里;之后底下的收货、付款与费用再动,这一行一个字不动。期末按总账 2000 归到这一家的分录算,签发时必须等于期末未结 − 挂账 − 残留(SUPPLIER_STATEMENT_DOES_NOT_TIE)。同一段期间再出一份 = 新起一行、旧行落 superseded_* + 理由。写入只走 issue_supplier_statement;读 module.finance.view。PDF 只从这一行渲染,字节在私有桶 supplier-statement-documents,哈希在 supplier_statement_issues。';
COMMENT ON COLUMN public.supplier_statements.lines IS
    '期间内每一笔归到这一家的总账 2000 发生(按分录):日期、种类(receipt · expense · freight · payment · prepayment)、单据号、分录号、本位币金额(+ 记上 / − 减少)、原币与币种、收货行当时是不是暂定价(provisional)。';
COMMENT ON COLUMN public.supplier_statements.unpriced IS
    '期末那天已收到、而那天还没有价的收货 —— 只有单号、日期、物料、数量与单位,不计金额(Q8:"received, not yet priced")。';

CREATE TRIGGER trg_supplier_statements_write
    BEFORE UPDATE OR DELETE ON public.supplier_statements
    FOR EACH ROW EXECUTE FUNCTION public.guard_supplier_statement_write();

ALTER TABLE public.supplier_statements ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是 issue_supplier_statement(属主权限)。
CREATE POLICY "supplier_statements select by permission" ON public.supplier_statements
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
GRANT SELECT ON public.supplier_statements TO authenticated;
REVOKE ALL ON public.supplier_statements FROM anon;
