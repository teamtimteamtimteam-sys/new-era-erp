-- db/tables/expense_claim_items.sql
-- EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q3 · Step 0b Q1–Q10):报销单的【明细】。表头在 expense_claims(报销人 · 币种 ·
-- 用途 · 状态与决定 · 合计);每一笔花销在这里:哪天 · 收据上的金额(含税,与此前一样)· 说明 · 没有收据时的理由 ——
-- 以及批准那一刻由财务给的科目与税码。批准时这张单生出【一张】费用单,每一笔明细是它的一行(行备注 = 明细说明)。
--
-- 【提报人陈述事实,审批人陈述会计】(CLAIM-1;Tim Step 0b Q1)科目与税码由财务在批准时【逐笔】给,什么都不预选;
--   提交时这两列必须是空的,只在 decide_expense_claim_items 那一步写一次(guard_expense_claim_item_mutation)。
-- 【日期】(Q5)一张单的明细落在【同一个日历月】里(一张费用单一个入账期间,EXPENSE_CLAIM_ITEMS_SPAN_MONTHS);
--   非本位币的单所有明细【同一天】(一张费用单一个汇率,EXPENSE_CLAIM_FOREIGN_ITEMS_ONE_DATE)。表头的 spend_date = 最晚那一笔。
-- 【币种】(Q4)一张单一个币种 —— 在表头,明细没有自己的币种列。
-- 【凭据】在 CLAIM-RECEIPTS-1 之前员工传不了收据(docs/known-issues.md § EXPENSE-CLAIM-NO-RECEIPT-UPLOAD),所以每一笔
--   要么那张单上有附件、要么它自己有一句无收据理由;批准时逐笔查(EXPENSE_CLAIM_NO_EVIDENCE|单号|第几笔)。
-- 【说明不遮】(Tim 2026-10-20:一般报销的说明不遮)明细说明与表头用途同一条。【搜索】只读表头的用途(Q7)。
-- 【读】与表头同一条:持 module.finance.view,或者这张单说的就是你。【写】只经属主权限函数(没有写策略)。

CREATE TABLE public.expense_claim_items (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id          uuid NOT NULL REFERENCES public.expense_claims (id),
    line_no           integer NOT NULL CHECK (line_no >= 1),
    spend_date        date NOT NULL,
    amount_ccy        numeric NOT NULL CHECK (amount_ccy > 0),   -- 收据上的金额(含税),表头币种
    description       text NOT NULL CHECK (btrim(description) <> ''),
    no_receipt_reason text,
    account_code      text REFERENCES public.accounts (code),    -- 批准时由财务给
    tax_code          text REFERENCES public.tax_codes (code),   -- 批准时由财务给(GST 关着时为空)
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    CONSTRAINT expense_claim_items_line_no_unique UNIQUE (claim_id, line_no)
);

COMMENT ON TABLE public.expense_claim_items IS
    'EXPENSE-MULTILINE-1(Tim 2026-10-20):报销单的明细 —— 日期、收据金额(含税)、说明、无收据理由;科目与税码由财务在批准时逐笔给(Step 0b Q1)。批准时整张单生出一张费用单,每笔明细一行。表头的金额与日期由 guard_expense_claim_totals 强制等于明细之和 / 最晚那一笔。';

-- 只许在批准那一步写一次科目与税码;别的列不可改,行不可删
CREATE OR REPLACE FUNCTION public.guard_expense_claim_item_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_ITEM_IMMUTABLE';
    END IF;
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.claim_id IS DISTINCT FROM OLD.claim_id
       OR NEW.line_no IS DISTINCT FROM OLD.line_no OR NEW.spend_date IS DISTINCT FROM OLD.spend_date
       OR NEW.amount_ccy IS DISTINCT FROM OLD.amount_ccy OR NEW.description IS DISTINCT FROM OLD.description
       OR NEW.no_receipt_reason IS DISTINCT FROM OLD.no_receipt_reason
       OR NEW.created_at IS DISTINCT FROM OLD.created_at OR NEW.created_by IS DISTINCT FROM OLD.created_by
       OR OLD.account_code IS NOT NULL OR OLD.tax_code IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_ITEM_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_expense_claim_items_immutable
    BEFORE UPDATE OR DELETE ON public.expense_claim_items
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_claim_item_mutation();

-- 表头的合计与日期 = 明细推出来的那一个(guard_expense_claim_totals 住在 db/tables/expense_claims.sql)
CREATE CONSTRAINT TRIGGER trg_expense_claim_items_totals_match
    AFTER INSERT ON public.expense_claim_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_claim_totals();

ALTER TABLE public.expense_claim_items ENABLE ROW LEVEL SECURITY;

-- 与表头同一条:财务看得见全部,员工看得见自己那张单的明细
CREATE POLICY "expense_claim_items select by permission" ON public.expense_claim_items
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('module.finance.view'::text))
        OR EXISTS (SELECT 1 FROM public.expense_claims c
                    WHERE c.id = expense_claim_items.claim_id AND c.employee_id = (SELECT current_user_employee())));

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是属主权限函数(submit_expense_claim_items · decide_expense_claim_items)。
REVOKE ALL ON public.expense_claim_items FROM anon;
