-- db/functions/asset_disposal_requests_visible.sql
-- APR-9(2026-09-27):资产页上"处置申请"那一块读的就是这里 —— 财务看得见自己提的,CFO 看得见要他批的。
--   谁读得到:module.finance.view(资产页的门;AGENTS.md 常设决定 1:它蕴含看得见价格)。其余 → 零行。
--   p_asset_id 给了就只给那一台的;只给在等的全部 + 最近决定 / 撤回的 p_recent 张。
--   estimate(提交时试跑)与 result(批准时真的过出来的)并排给出(Q7);current_matches = 卡此刻与提交时的
--   fingerprint 一样(不一样,批准会被 ASSET_CHANGED_SINCE_REQUEST 拒,屏幕先说出来)。
--   raised_by_me = 提单人就是读者这个人(按人认);result_entry_code 给屏幕画到凭证的链接。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.asset_disposal_requests_visible(p_asset_id uuid DEFAULT NULL::uuid, p_recent integer DEFAULT 10)
 RETURNS TABLE(id uuid, status text, label text, asset_id uuid, asset_code text, asset_description text, proceeds_base numeric, bank_account text, reason text, estimate jsonb, amount_base numeric, current_matches boolean, created_at timestamptz, created_by_email text, raised_by_me boolean, decided_at timestamptz, decided_by_email text, decision_notes text, disposal_date date, result jsonb, result_entry_id uuid, result_entry_code text, withdrawn_at timestamptz, withdraw_reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH r AS (
        SELECT q.*, (q.status = 'submitted') AS is_open,
               row_number() OVER (PARTITION BY (q.status = 'submitted')
                                  ORDER BY COALESCE(q.decided_at, q.withdrawn_at, q.created_at) DESC) AS rn
          FROM asset_disposal_requests q
         WHERE has_permission('module.finance.view')
           AND (p_asset_id IS NULL OR q.asset_id = p_asset_id))
    SELECT r.id, r.status, r.label, r.asset_id, a.code, a.description, r.proceeds_base, r.bank_account, r.reason,
           r.estimate, r.amount_base,
           asset_disposal_fingerprint(r.asset_id) IS NOT DISTINCT FROM r.snapshot,
           r.created_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.created_by),
           self_leg(r.created_by, NULL, auth.uid()) = 'raiser',
           r.decided_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.decided_by),
           r.decision_notes, r.disposal_date, r.result, r.result_entry_id,
           (SELECT je.code FROM journal_entries je WHERE je.id = r.result_entry_id),
           r.withdrawn_at, r.withdraw_reason
      FROM r
      JOIN fixed_assets a ON a.id = r.asset_id
     WHERE r.is_open OR r.rn <= GREATEST(COALESCE(p_recent, 10), 0)
     ORDER BY r.is_open DESC, COALESCE(r.decided_at, r.withdrawn_at, r.created_at) DESC
$function$;
