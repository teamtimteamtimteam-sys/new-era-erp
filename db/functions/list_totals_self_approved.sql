-- db/functions/list_totals_self_approved.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1):/finance/self-approved 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【同一个行集】页面读 self_approved_decisions()(app/finance/self-approved/page.tsx:57),那支函数的行集是
--   approval_log 里 a.self_decided 的每一行(self_approved_decisions.sql:WHERE a.self_decided),页面不再筛(page.tsx:70-89)。
--   这里读同一张表、同一个谓词;批准与驳回两种决定都在列表上,所以都计入。
-- 【只加带金额的行】请假那一族金额与币种【都】是合法的 NULL(approval_log.sql:171-173、182-183)—— 不是被遮,跳过。
-- 【受限】每个币种:bool_or(NOT approval_log_amount_visible(subject_type, subject_id)) —— 与 self_approved_decisions 遮金额
--   同一支判据(医疗报销:data.view_health 或本人)。有一笔看不见,那个币种的合计就是「受限」、total 为 NULL;
--   被遮的那几笔的币种不遮(那支函数也不遮 currency),所以受限照样按币种落在它自己那一行。
-- 【净额】一行是一次【决定】,不是一笔过账;本表没有冲销行,照行上的数加总。
-- 【门】SECURITY DEFINER —— 与页面那支 RPC 同一个理由(approval_log 的金额列对 authenticated 收回了,读策略又按单据类型分门),
--   所以第一句就是同一个 require_permission('data.view_self_approvals')(页面守卫 requireFunction(FN.selfApproved) 的判据),
--   没有它就 RAISE。approval_log_amount_visible 里的 has_permission 按【调用者】求值,属主身份不放宽它。
CREATE OR REPLACE FUNCTION public.list_totals_self_approved()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('data.view_self_approvals');
    RETURN QUERY
    SELECT ''::text, x.currency, 'amount'::text,
           CASE WHEN bool_or(x.hidden) THEN NULL::numeric ELSE round(sum(x.amount_ccy), 2) END,
           bool_or(x.hidden)
      FROM (SELECT a.currency::text AS currency, a.amount_ccy,
                   NOT approval_log_amount_visible(a.subject_type, a.subject_id) AS hidden
              FROM approval_log a
             WHERE a.self_decided
               AND a.amount_ccy IS NOT NULL) x
     GROUP BY x.currency
     ORDER BY x.currency;
END;
$function$;