-- db/functions/journal_entry_reversal_route.sql
-- APR-6(2026-09-25,grilling Q6):一张分录【从凭证页】怎么冲 —— 一份判据,三个读它的人
-- (reverse_journal_entry 那扇只会拒的门 · 冲销申请的提交与过账 · 凭证页上那颗钮灰不灰、说什么)。
--
--   'reversed'     已经冲过(status <> posted 或 reversed_by 已挂上)—— 不能再冲。
--   'source_path'  有自己冲销路径的:付款 · 转账 · 代扣税缴纳(各自的冲销申请)、purchase(改价申请)、
--                  invoice / credit_note(作废 / 贷项申请)、expense(reverse_expense)、freight
--                  (reverse_freight_document)、allocation / processing_cost(重分摊 / 加工回滚)、year_close
--                  (reopen_financial_year)、工资期的【过账】分录与它的冲销(撤销申请)。凭证页按名拒
--                  JE_REVERSE_USE_SOURCE_PATH —— 从这里冲掉,总账回来了,那张单据却不知道。
--   'request'      其余一切:手工凭证,以及没有自己路径的系统分录(sale · stocktake · writeoff · prepayment ·
--                  revaluation · depreciation · asset_disposal · shipment · fx · 工资的【付款】分录)。
--                  从凭证页冲它们是一个人的裁量,走同一张 CFO 冲销申请(Q6 (i)(iii))。
--   NULL           没有这张分录。
--
-- 【冲销分录抄原分录的 source_type】所以一张冲销分录落在与原分录同一格 —— 冲掉一张作废留下的冲销,
-- 同样是 source_path(否则 = 不经批准地复活发票),与 reverse_journal_entry 一直以来的判法一致。
-- 工资那一段原样搬自 reverse_journal_entry(PAYROLL-APR-1 Q5):只有被 payroll_lines.paid_journal_entry_id /
-- payroll_periods.cpf_journal_entry_id / deductions_journal_entry_id 指着的【付款】分录(以及它们的冲销)不算
-- source_path —— 它们没有正经的冲销路径(PAYROLL-PAYMENT-NO-REVERSAL-PATH),APR-6 起走冲销申请。
--
-- DEFINER:它读工资表(一个持 finance.view 却读不到 payroll_lines 的人,INVOKER 下会把一张工资过账分录
-- 错读成 'request' —— xmodule 那一族)。本体【不问码】:它也在批准与试跑的内层被调用(那里的主语未必持
-- 凭证页的码,以 postgres 跑的 fixture 根本没有主语);而它只回一个词,不回任何金额、任何行
-- (db/check_mirrors.py DEFINER_NO_CHECK_ALLOWED 记着这条理由)。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.journal_entry_reversal_route(p_entry_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_je journal_entries%ROWTYPE;
BEGIN
    SELECT * INTO v_je FROM journal_entries WHERE id = p_entry_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    IF v_je.status <> 'posted' OR v_je.reversed_by IS NOT NULL THEN
        RETURN 'reversed';
    END IF;
    IF v_je.source_type IN ('payment', 'transfer', 'wht_remittance', 'purchase', 'invoice', 'credit_note',
                            'expense', 'freight', 'allocation', 'processing_cost', 'year_close') THEN
        RETURN 'source_path';
    END IF;
    IF v_je.source_type = 'payroll' AND NOT (
           EXISTS (SELECT 1 FROM payroll_lines pl
                    WHERE pl.paid_journal_entry_id IN (v_je.id, v_je.source_id))
           OR EXISTS (SELECT 1 FROM payroll_periods pp
                       WHERE pp.cpf_journal_entry_id IN (v_je.id, v_je.source_id)
                          OR pp.deductions_journal_entry_id IN (v_je.id, v_je.source_id))) THEN
        RETURN 'source_path';
    END IF;
    RETURN 'request';
END;
$function$;
