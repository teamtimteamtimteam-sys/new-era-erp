-- db/tables/customer_statements.sql
-- STATEMENT-1:一份【冻下来的】客户对账单。形状取自 bank_reconciliations
-- (不可变事件行 + superseded_at + 理由),而不是取自任何一张单据表。
--
-- NOTE: introduced by db/migrations/2026-08-27-statement1-customer-statements-of-account.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.customer_statements (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code              text NOT NULL UNIQUE,
    customer_id       uuid NOT NULL REFERENCES public.customers (id) ON DELETE RESTRICT,
    period_start      date NOT NULL,
    period_end        date NOT NULL,
    base_currency     text NOT NULL REFERENCES public.currencies (code),
    -- 本位币的五个数。等式在签发那一刻就已经验过(对不上按名拒),
    -- 所以这里存的是【当时确实成立的那五个数】。
    opening_base      numeric NOT NULL,
    charges_base      numeric NOT NULL,
    credits_base      numeric NOT NULL,
    receipts_base     numeric NOT NULL,
    closing_base      numeric NOT NULL,
    -- 【明细也冻】(Tim 2026-08-27)客户争的是行,不是合计。
    -- 只冻合计,屏幕就只能说"我们当时告诉你是 24,000",而说不出是哪几张单据 ——
    -- 而"再推导一遍"正是冻结要避免的那件事。
    lines             jsonb NOT NULL,
    -- 每个币种一段:{currency, opening, charges, credits, receipts, closing}
    by_currency       jsonb NOT NULL,
    -- 期末账龄四档(读 ar_aging_asof 的 buckets,不自己分档)
    buckets           jsonb NOT NULL,
    issued_at         timestamptz NOT NULL DEFAULT now(),
    issued_by         uuid,
    -- 【更正 = 新起一行,旧的标掉,不删】与 bank_reconciliations 逐字同源。
    superseded_at     timestamptz,
    superseded_by     uuid REFERENCES public.customer_statements (id),
    superseded_reason text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT customer_statements_period_shape CHECK (period_end >= period_start),
    CONSTRAINT customer_statements_supersede_shape
        CHECK ((superseded_at IS NULL) = (superseded_by IS NULL))
);

COMMENT ON TABLE public.customer_statements IS
    'STATEMENT-1:一份对账单 = 一行,而那一行是【抄下来的】。签发那一刻把期初/发生/贷记/收款/期末五个本位币数、每币种分段、期末账龄四档、以及【明细行】一起冻在这里;此后底下的收款与贷项凭证再动,这一行一个字不动 —— 与 bank_reconciliations、gst_return_boxes 同一条规矩,理由也是同一个:「我们当时寄出去的是什么」与「今天重算是多少」是两个问题,日后客户问的一定是前一个。【为什么是一行一次事件,不是可改的列】同一段期间数字变了再出一次,是【另一份文件】,不是把上一份改掉:新起一行,旧行落 superseded_at + 理由。写入只走 issue_customer_statement(SECURITY DEFINER),所以这里只开 SELECT。PDF 的版本在 statement_issues 里另算一层。';

CREATE INDEX idx_customer_statements_customer
    ON public.customer_statements (customer_id, period_end DESC);

ALTER TABLE public.customer_statements ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是 issue_customer_statement
-- (属主权限)—— 与 bank_reconciliations、approval_log、七张签发档同一条:
-- 一份档案不该有第二个写法。
CREATE POLICY "customer_statements select by permission" ON public.customer_statements
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
