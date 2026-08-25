-- db/functions/guard_gst_switch.sql
-- GST-3:注册开关两个方向的闸。
-- 【开】登记号必须在册 —— IRAS 要求税务发票印它,而发票 PDF 在号码为空时
--   那一行【整条消失】(不是拒绝出票,是安静地不印)。空白字符串与 NULL 同罪:
--   判据要与【印出来的结果】一致,不是与列的可空性一致。
-- 【关】两条拒绝、两个【不同】的理由,不合并:
--   · 带税码的费用单 —— 机械事实:GST-2 让冲销把 tax_code 一起翻过去,
--     而未注册时带税码的行写不进去,于是关掉之后它们再也冲销不了;
--   · 在册的带税发票 —— 判断:它们冲销得了(税腿不带税码),但留下的状态
--     自相矛盾(账上报着某季供应额,公司却声称那一季未注册)。
--   合成一句会让机械的那一半被判断的那一半稀释。
-- 【为什么闸在库上,不在 server action 上】开关本来就是由 SQL 翻的,而
--   module.finance.edit 经 RLS 直接授予 UPDATE —— 只住在 action 里的闸
--   恰好挡不住会用它的那批人。与 trg_approvals_switch 同一个落点、同一个理由。
CREATE OR REPLACE FUNCTION public.guard_gst_switch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n      integer;
    v_codes  text;
BEGIN
    -- ── 开:登记号必须先在册 ────────────────────────────────────────────────
    -- 【为什么是 btrim + NULLIF,不是 IS NOT NULL】一段空白字符串在数据库里
    -- 是"有值"的,而在发票上它与 NULL 一样什么都不印。判据要与【印出来的结果】
    -- 一致,不是与列的可空性一致。
    IF NEW.gst_registered AND NOT OLD.gst_registered THEN
        IF NULLIF(btrim(COALESCE(NEW.gst_registration_no, '')), '') IS NULL THEN
            RAISE EXCEPTION 'GST_REGISTRATION_NO_REQUIRED';
        END IF;
    END IF;

    -- ── 关:两条拒绝,两个【不同】的理由 ────────────────────────────────────
    IF OLD.gst_registered AND NOT NEW.gst_registered THEN

        -- 【① 机械】带税码的费用单:关掉之后它们【冲销不了】。
        -- 判据取自那件真正会坏的事 —— 分录行上带着税码、分录还没有被冲销。
        -- reverse_expense 会把这张分录整个翻边,而翻边【会把 tax_code 一起抄过去】
        -- (GST-2 修的那一条);未注册时 post_journal_entry 拒收带税码的行,
        -- 于是那一笔永远冲不掉。
        SELECT count(*), string_agg(e.code, ', ' ORDER BY e.code)
          INTO v_n, v_codes
          FROM expenses e
          JOIN journal_entries je ON je.id = e.journal_entry_id
         WHERE e.tax_code IS NOT NULL
           AND e.status = 'posted'
           AND je.status = 'posted'
           AND EXISTS (SELECT 1 FROM journal_lines jl
                        WHERE jl.entry_id = je.id AND jl.tax_code IS NOT NULL);
        IF COALESCE(v_n, 0) > 0 THEN
            RAISE EXCEPTION 'GST_CANNOT_DISABLE_WITH_CODED_EXPENSES|%|%', v_n, v_codes
              USING HINT = '先把这些费用单冲销掉(冲销要在开关【还开着】的时候做),再关开关';
        END IF;

        -- 【② 判断】在册的带税发票:它们【冲销得了】(税腿不带税码),
        -- 但留下的状态自相矛盾 —— F5 报着那一季的供应额,而公司声称未注册。
        -- 这一条是判断,不是机械事实,所以它另起一个码、另说一句话。
        SELECT count(*), string_agg(DISTINCT i.code, ', ')
          INTO v_n, v_codes
          FROM invoices i
         WHERE i.status <> 'void'
           AND EXISTS (SELECT 1 FROM invoice_lines il
                        WHERE il.invoice_id = i.id AND il.tax_code IS NOT NULL);
        IF COALESCE(v_n, 0) > 0 THEN
            RAISE EXCEPTION 'GST_CANNOT_DISABLE_WITH_TAXED_INVOICES|%|%', v_n, v_codes
              USING HINT = '这些发票作废之后才谈得上"未注册" —— 否则账上报着供应额,而公司说那一季没注册';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$
;