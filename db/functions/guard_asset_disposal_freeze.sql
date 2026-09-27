-- db/functions/guard_asset_disposal_freeze.sql
-- APR-9(2026-09-27,grilling Q8):**一台资产的处置在等 CFO 的时候,卡上改得动价值的列冻结。**
-- 挂在 fixed_assets 上(BEFORE UPDATE,逐行)。成本(原币 / 币种 / 汇率 / 本位币)、残值、年限、购置日、投用日、
-- 折旧科目、状态与三支处置列,任何一样要变,而这台资产挂着一张 submitted 的处置申请 → ASSET_DISPOSAL_REQUESTED|<code>|<label>。
-- 于是:记支出往这台资产上追加成本(record_expense)、冲销它的成本明细(reverse_expense)、投用它
-- (set_asset_in_service)—— 三条路都要改这张卡,一支守卫全部拦住,没有侧门。
-- 【照常】折旧(写 fixed_asset_depreciation,不改这张卡 —— 关账要它,close_period 的 DEPRECIATION_OUTSTANDING)、
-- 保养、计划投用日、验收日、描述、类别、备注。
-- 【放行】只有那一张申请自己的执行:evoltrya.asset_disposal_ctx = 它的 id(asset_disposal_execute_internal 设)。
-- 【为什么不是 row_security_active 那一种】fixed_assets 没有写策略,每一个写它的都是属主路径;
-- 要拦的正是属主路径里的那几支函数。INVOKER:在属主路径里跑就是属主,读得到申请表。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_asset_disposal_freeze()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_req record;
BEGIN
    IF (NEW.cost_ccy, NEW.currency, NEW.fx_rate, NEW.cost_base, NEW.residual_base, NEW.useful_life_months,
        NEW.acquisition_date, NEW.in_service_date, NEW.depreciation_account_code, NEW.status,
        NEW.disposal_date, NEW.disposal_proceeds_base, NEW.disposal_journal_id)
       IS NOT DISTINCT FROM
       (OLD.cost_ccy, OLD.currency, OLD.fx_rate, OLD.cost_base, OLD.residual_base, OLD.useful_life_months,
        OLD.acquisition_date, OLD.in_service_date, OLD.depreciation_account_code, OLD.status,
        OLD.disposal_date, OLD.disposal_proceeds_base, OLD.disposal_journal_id) THEN
        RETURN NEW;
    END IF;
    SELECT q.id, q.label INTO v_req FROM asset_disposal_requests q
     WHERE q.asset_id = OLD.id AND q.status = 'submitted'
     LIMIT 1;
    IF NOT FOUND THEN
        RETURN NEW;
    END IF;
    IF v_req.id::text = COALESCE(current_setting('evoltrya.asset_disposal_ctx', true), '') THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'ASSET_DISPOSAL_REQUESTED|%|%', OLD.code, v_req.label;
END;
$function$;

COMMENT ON FUNCTION public.guard_asset_disposal_freeze() IS
'APR-9(Q8):一台资产挂着一张在等的处置申请时,卡上的成本、残值、年限、购置日、投用日、折旧科目、状态与处置列不许变 —— ASSET_DISPOSAL_REQUESTED|资产|申请。追加成本、冲销成本明细、投用三条路因此全部按名拒;折旧、保养、计划与验收日照常。只放那一张申请自己的执行(evoltrya.asset_disposal_ctx)。';
