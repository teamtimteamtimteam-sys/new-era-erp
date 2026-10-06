-- db/functions/journal_request_amount_visible.sql
-- U1-B(2026-10-05,U1A-PAYROLL-REVERSAL-REQUEST-SHOWS-AMOUNT):一张手工凭证申请的【金额】(journal_requests.amount_base)对当前读者看不看得见。
--   发薪、公积金、扣款那几张分录的冲销走手工凭证的冲销申请,申请抄着被冲销那张分录的合计 —— 一期一个人时就是一个人的实发工资。
--   U1-A 把工资分录本身收到 data.view_pay(journal_lines_masked);本函数让【申请】跟同一条规矩走(Tim:照 data.view_pay 那条规矩遮)。
-- 【判据】持 data.view_pay,或这张申请冲销的不是一张工资分录(target_entry_id → journal_entries.source_type 不是 'payroll')。
--   与 journal_lines_masked 的 CASE 逐字同一个谓词;一张新凭证的申请(kind = 'entry',没有被冲销的分录)不是工资,照常给。
--   写成 has_permission OR EXISTS(…不是工资…),不写成 NOT EXISTS(…是工资…):读不到那一行的人(或那一行不存在)落在
--   【看不见】那一边 —— 关着失败。
-- 【四个读者,一份判据】journal_requests_masked 的 CASE · approval_log_amount_visible 的 journal_request 那一支(审批留痕与
--   change_log_rule_visible 的 apr_amount 跟着它)· change_log_rule_visible 的 jr_amount(申请自己的变更记录)·
--   提交与决定两支函数的返回值。
-- 【不是 SECURITY DEFINER】它读 journal_requests(id · target_entry_id,列授权里有)与 journal_entries(source_type),两张都按
--   module.finance.view 给 —— 与申请自己的读门同一个码,读得到申请的人就读得到这两列。
CREATE OR REPLACE FUNCTION public.journal_request_amount_visible(p_request_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT has_permission('data.view_pay'::text)
        OR EXISTS (SELECT 1
                     FROM journal_requests r
                     LEFT JOIN journal_entries e ON e.id = r.target_entry_id
                    WHERE r.id = p_request_id
                      AND e.source_type IS DISTINCT FROM 'payroll');
$function$
