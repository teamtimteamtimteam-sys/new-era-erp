-- db/migrations/2026-10-26-table-features-2-totals.sql
-- TABLE-FEATURES-2(v1.4.75,Tim 2026-10-25 Q1 · Q5 与 2026-10-26 Q1–Q9):
--   ① 21 张金额清单的表尾合计 —— 每张一支 list_totals_<清单>(<与页面同一套筛选>),形状见 lib/listTotals.ts 抬头;
--      /inventory 另有 inventory_stock_by_material()(行与表尾同一份算术);
--   ② fiscal_year_end_setting() —— 日期快捷区间「今年」要的财年年末月与日(Q5)。
-- 只新建函数,不动任何表、视图、策略或数据。EXECUTE:apply_migration.sh 在本事务里重放 db/views/zzz_function_grants.sql
--   (收回 PUBLIC / anon,授 authenticated / service_role)。镜像:db/functions/ 下同名文件,本文件逐字由它们拼成。
BEGIN;

-- ── db/functions/fiscal_year_end_setting.sql ──
-- db/functions/fiscal_year_end_setting.sql
-- TABLE-FEATURES-2(Tim 2026-10-26 Q5):日期快捷区间「今年」要读【配置的财年年末】,而 11 张带起止日期的列表里有 7 张不在财务模块里
--   (采购单 · 进料 · 产出 · 加工 · 请假 · 库存流水 · 已删除),它们的读者读不到 finance_settings(SELECT 策略只认 module.finance.view)。
--   Tim 的裁定:一支小函数,只回 fy_end_month 与 fy_end_day 两个数,给任何登录用户。
-- 【必须是 definer,且必须留给 authenticated】—— 与 approvals_enabled 同一个形状(读 finance_settings 一列给财务以外的屏幕);
--   吐露的只有财年年末的月与日,那是每一张财务报表抬头上本来就印着的东西。没有可要求的权限码 —— 挂 module.finance.view 就是今天这条路。
--   check_mirrors.py 的 DEFINER_NO_CHECK_ALLOWED 与 verify_rebuild.py 的 DEFINER_UNCHECKED_EXEC_ALLOWED 同改,理由同此。anon 照 zzz_function_grants.sql 收回。
-- 【first_fy_end 不在这里】裁定只给两个数;live first_fy_end 为 NULL(2026-10-26 以 postgres 读),于是今天没有可见的差别 —— 登记见 docs/known-issues.md。
CREATE OR REPLACE FUNCTION public.fiscal_year_end_setting()
 RETURNS TABLE(fy_end_month integer, fy_end_day integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT fs.fy_end_month, fs.fy_end_day FROM finance_settings fs LIMIT 1;
$function$;

-- ── db/functions/inventory_stock_by_material.sql ──
-- db/functions/inventory_stock_by_material.sql
-- TABLE-FEATURES-2(Tim 2026-10-26:「库存估值合计条由库算的合计取代」):/inventory 台账【每一行】的数 —— 一种物料一行。
--   ★ 存在的理由:表尾合计(list_totals_inventory)由库算,而行此前在 JS 里算(app/inventory/page.tsx 的 rowsByMaterial)。
--     两份实现会在某一天对不上(AGENTS.md「A screen that previews a posting ASKS the database」),于是行也搬进库:
--     页面画本函数的行,list_totals_inventory 加本函数的列 —— 一份实现,两个调用方。
--   ★ 顺带去掉七次无序、无分页的整表读(PostgREST 1,000 行上限处的子集是任意的)。
-- 【批次集合】(与搬家前 page.tsx 的读法逐项相同):
--   * 进料:inbound_batch_valuation 里 remaining_qty > 0 的行(该视图已去掉 deleted_at 的批次)。
--     ★ 物料被删了的进料批次【照算】—— 页面一直把它们画成名为「—」的一行(物料名查表过滤 deleted_at,估值视图不过滤);
--       合计跟着行走。线上 2026-10-26 这样的批次为 0。
--   * 产出:output_batch_lookup 里 deleted_at IS NULL 且 remaining_qty > 0 的行(物料被删的同样照算)。
-- 【每一列的规则】
--   * inbound_stock / output_stock = Σ remaining_qty;priced_qty = Σ 进料 remaining_qty where NOT unpriced(加权均价的分母)。
--   * unit / mixed_unit:这一物料所有在库批次的单位只有一种 → 那一种;不止一种 → mixed_unit = true,unit = NULL(页面画「混合」)。
--   * stock_value(本位币)= Σ remaining_qty × landed_unit_cost,只加 landed_unit_cost 非 NULL 的批次;一张都没有 → NULL。
--     没有 data.view_prices 时视图把 landed_unit_cost 遮成 NULL,于是整列 NULL —— 是否「受限」由调用方按权限说,不由 NULL 倒推。
--   * cost_value(本位币)= Σ remaining_qty × 产出腿 unit_cost_base(processing_output_lookup,同样按 data.view_prices 遮蔽;
--     从未分摊的腿也是 NULL),只加非 NULL 的;一张都没有 → NULL。一个批次至多一条产出腿(取非 NULL 的那一条)。
--   * market_value(USD,不折算 —— lib/valuation.ts 抬头)= Σ remaining_qty × 每公斤市价;
--     每公斤市价 = Σ 有价金属 (content_pct/100 × price_usd_per_tonne/1000)(output_batch_metal_lookup);
--     价 = 每个金属 price_date 最大的一条 metal_prices(deleted_at IS NULL、price_date ≤ 今天的 UTC 日期 —— 与页面原来的
--     new Date().toISOString().slice(0,10) 同一个「今天」,也与 /inventory/output/[materialId] 同一个),
--     且 price_index 等于 pricing_settings.default_metal_index(NULL = 未标注指数的那条序列,IS NOT DISTINCT FROM)。
--     ★ 部分计价:一批里没有价的金属【跳过】,只要有一种金属有价,这一批就有市价(lib/valuation.ts marketValuePerKg 同一规则);
--       一种都没有 → 这一批不计入;一种物料一批都没有 → NULL。单位假定是 kg(不检查,与 JS 同)。不遮蔽(金属价与含量都不是价格)。
--   * 不在库里四舍五入:每一格的显示由页面格式化;合计在 list_totals_inventory 里对精确和取 2 位。
-- 【门】require_permission('module.inventory.view') —— 页面守卫 requireModule(MOD.inventory) 的码。INVOKER:读的就是读者自己读得到的那几张视图。
-- ★ 同一条市价规则在 TS 里还有一份:lib/valuation.ts(/inventory/output/[materialId] 钻取页用)。改规则两处一起改。
CREATE OR REPLACE FUNCTION public.inventory_stock_by_material()
 RETURNS TABLE(material_id uuid, unit text, mixed_unit boolean, inbound_stock numeric, output_stock numeric, priced_qty numeric, stock_value numeric, cost_value numeric, market_value numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_today date := (now() AT TIME ZONE 'UTC')::date;
    v_index text;
BEGIN
    PERFORM require_permission('module.inventory.view');
    SELECT ps.default_metal_index INTO v_index FROM pricing_settings ps WHERE ps.id;

    RETURN QUERY
    WITH price AS (
        SELECT DISTINCT ON (mp.metal) mp.metal, mp.price_usd_per_tonne
          FROM metal_prices mp
         WHERE mp.deleted_at IS NULL
           AND mp.price_date <= v_today
           AND mp.price_index IS NOT DISTINCT FROM v_index
         ORDER BY mp.metal, mp.price_date DESC
    ), per_kg AS (
        SELECT obm.output_batch_id,
               sum(obm.content_pct / 100 * pr.price_usd_per_tonne / 1000) AS usd_per_kg
          FROM output_batch_metal_lookup obm
          JOIN price pr ON pr.metal = obm.metal
         GROUP BY obm.output_batch_id
    ), batch AS (
        SELECT ib.material_id, ib.unit,
               ib.remaining_qty AS inbound_qty, 0::numeric AS output_qty,
               CASE WHEN NOT ib.unpriced THEN ib.remaining_qty ELSE 0 END AS priced_qty,
               ib.remaining_qty * ib.landed_unit_cost AS stock_value,
               NULL::numeric AS cost_value,
               NULL::numeric AS market_value
          FROM inbound_batch_valuation ib
         WHERE ib.remaining_qty > 0
        UNION ALL
        SELECT ob.material_id, ob.unit,
               0, ob.remaining_qty,
               0,
               NULL,
               ob.remaining_qty * leg.unit_cost_base,
               ob.remaining_qty * pk.usd_per_kg
          FROM output_batch_lookup ob
          LEFT JOIN LATERAL (SELECT pol.unit_cost_base FROM processing_output_lookup pol
                              WHERE pol.output_batch_id = ob.id AND pol.unit_cost_base IS NOT NULL
                              LIMIT 1) leg ON true
          LEFT JOIN per_kg pk ON pk.output_batch_id = ob.id
         WHERE ob.deleted_at IS NULL
           AND ob.remaining_qty > 0
    )
    SELECT b.material_id,
           CASE WHEN count(DISTINCT b.unit) = 1 THEN min(b.unit) END,
           count(DISTINCT b.unit) > 1,
           sum(b.inbound_qty),
           sum(b.output_qty),
           sum(b.priced_qty),
           sum(b.stock_value),
           sum(b.cost_value),
           sum(b.market_value)
      FROM batch b
     GROUP BY b.material_id;
END;
$function$;

-- ── db/functions/list_totals_bank_transfers.sql ──
-- db/functions/list_totals_bank_transfers.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q2):/finance/bank 行内转账表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】这张表没有筛选(app/finance/bank/transferRows.ts:31-35 只有排序)。页面只画前 50 笔(TRANSFERS_SHOWN),
--   ★ 合计覆盖【所有】转账,不是那 50 笔(裁定:所有符合筛选的行)。
-- 【两个合计】measure 'out' = amount_out,币种 = bank_native_currency(from_account);'in' = amount_in,币种 = bank_native_currency(to_account)。
--   页面行上的币种取自 bank_reconciliation_status(transferRows.ts:73-87),两者对 1000/1010 是同一个码。
-- 【净额】(Q2)冲销的转账只打 reversed_at 标记,没有镜像行 → 已冲销的【排除】(加 0)。
-- 【门】require_permission('module.finance.view') —— 页面守卫 requireModule(MOD.finance)(bank/page.tsx:44),
--   与 bank_transfers 的 SELECT 策略(bank_transfers.sql:40-42)同一个码。invoker;没有金额被遮,restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_bank_transfers()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text, x.ccy, x.m, round(sum(x.amt), 2), false
      FROM (SELECT bank_native_currency(b.from_account) AS ccy, 'out'::text AS m, b.amount_out AS amt
              FROM bank_transfers b WHERE b.reversed_at IS NULL
            UNION ALL
            SELECT bank_native_currency(b.to_account), 'in'::text, b.amount_in
              FROM bank_transfers b WHERE b.reversed_at IS NULL) x
     GROUP BY x.ccy, x.m
     ORDER BY x.ccy, x.m DESC;
END;
$function$;

-- ── db/functions/list_totals_commissions.sql ──
-- db/functions/list_totals_commissions.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q3):/sales/commissions 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/sales/commissions/page.tsx:47-53 同一套:commission_agreements,deleted_at IS NULL(没有地址栏筛选)。
-- 【只加定额】(Q3)只有 basis = 'fixed_amount' 的行进合计:percentage_of_value 是费率(没有金额),per_tonne 是每吨的价 ——
--   加起来是把单价相加。每个币种一行,measure amount(amount_ccy)→ 表的「费率」列。
-- 【净额】协议没有冲销镜像行;软删的不算(与列表同)。
-- 【门】require_permission('module.suppliers.view') —— 与页面守卫(requireModule(MOD.suppliers))、与表的读策略同一个码。invoker。
-- 【受限】这一列不遮;照实算 bool_or(amount_ccy IS NULL) —— fixed_amount 行的 amount_ccy 由 CHECK 保证非空
--   (commission_agreements.sql:62-67),所以这里的 NULL 只可能是看不见。
CREATE OR REPLACE FUNCTION public.list_totals_commissions()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.suppliers.view');
    RETURN QUERY
    SELECT ''::text, ca.currency::text, 'amount'::text,
           CASE WHEN bool_or(ca.amount_ccy IS NULL) THEN NULL::numeric ELSE round(sum(ca.amount_ccy), 2) END,
           bool_or(ca.amount_ccy IS NULL)
      FROM commission_agreements ca
     WHERE ca.deleted_at IS NULL
       AND ca.basis = 'fixed_amount'
     GROUP BY ca.currency
     ORDER BY 2;
END;
$function$;

-- ── db/functions/list_totals_credit_notes.sql ──
-- db/functions/list_totals_credit_notes.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1–Q3):/finance/credit-notes 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】无(app/finance/credit-notes/creditNoteRows.ts 的 creditNoteCount / creditNotePage 只排序,不筛)。
-- 【量】total = Σ credit_note_lines.amount(凭证本身不存合计,是各行之和 —— 与 shapeCreditNoteRows 同一个数),
--   按表头 credit_notes.currency 分组,每个币种一行。
-- 【净额】凭证不可变、没有作废或冲销(credit_notes.sql:33),没有要抵的。
-- 【门】require_permission('module.finance.view') —— 与页面守卫 requireModule(MOD.finance)、与 credit_notes / credit_note_lines
--   的 SELECT 策略同一个码。invoker;金额不遮(只有客户名按 module.customers.view 遮),restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_credit_notes()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text,
           cn.currency::text,
           'total'::text,
           round(sum(l.amount), 2),
           false
      FROM credit_notes cn
      JOIN credit_note_lines l ON l.credit_note_id = cn.id
     GROUP BY 2
     ORDER BY 2;
END;
$function$;

-- ── db/functions/list_totals_electricity.sql ──
-- db/functions/list_totals_electricity.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q2):/finance/electricity 分摊表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】页面没有筛选,一次读全 electricity_allocations_masked(app/finance/electricity/page.tsx:46-48)。
-- 【三个合计】measure 'bill' = bill_amount(列键 amount)、'runs' = allocated_amount、'overhead' = overhead_amount;
--   按行上的 currency 分组(每个币种一行)。读【同一张遮蔽视图】—— 基表的金额列对 authenticated 收回了。
-- 【净额】(Q2)撤回的分摊只在 electricity_allocation_reversals 里多一行、原件金额照旧是正数 → 撤回过的【排除】(加 0)。
--   撤回读页面读的那张 electricity_allocation_reversals_masked(page.tsx:50)。
-- 【受限】遮蔽对一个读者是全有或全无(has_permission('data.view_prices'),视图体),三列在表里都 NOT NULL
--   —— 于是 restricted = NOT has_permission('data.view_prices'),与页面的 canViewPrices() 同一个判据;受限时 total 为 NULL。
-- 【门】require_permission('module.finance.view') —— 页面守卫 requireModule(MOD.finance)(electricity/page.tsx:32)。invoker。
CREATE OR REPLACE FUNCTION public.list_totals_electricity()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_hidden boolean;
BEGIN
    PERFORM require_permission('module.finance.view');
    v_hidden := NOT has_permission('data.view_prices');
    RETURN QUERY
    SELECT ''::text, x.ccy, x.m,
           CASE WHEN v_hidden THEN NULL::numeric ELSE round(sum(x.amt), 2) END,
           v_hidden
      FROM (SELECT a.currency::text AS ccy, m.m, m.amt
              FROM electricity_allocations_masked a
              CROSS JOIN LATERAL (VALUES (1, 'bill'::text, a.bill_amount),
                                         (2, 'runs'::text, a.allocated_amount),
                                         (3, 'overhead'::text, a.overhead_amount)) AS m(ord, m, amt)
             WHERE NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals_masked r WHERE r.allocation_id = a.id)) x
     GROUP BY x.ccy, x.m
     ORDER BY x.ccy, min(CASE x.m WHEN 'bill' THEN 1 WHEN 'runs' THEN 2 ELSE 3 END);
END;
$function$;

-- ── db/functions/list_totals_expense_claims.sql ──
-- db/functions/list_totals_expense_claims.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1):/finance/claims 已决登记簿的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】页面一次读全 expense_claim_status(app/finance/claims/page.tsx:47-52),再在 JS 里只留 status <> 'submitted'
--   (page.tsx:100-101,待批的那一半是卡片)—— 这里在 SQL 里做同一件事。行谓词就是视图自己的那一句
--   (has_permission('module.finance.view') OR employee_id = current_user_employee(),expense_claim_status.sql),
--   本函数是 invoker、读同一张视图,所以读者拿到的行与页面同一份。
-- 【合计】amount_ccy(员工报的含税总额,NOT NULL > 0)按行上的 currency,每个币种一行。
-- 【净额】报销单本身没有冲销行;"批准被撤销"走冲销那笔费用(expense_reversed),单子仍是 approved、行上照旧是原额
--   —— 与页面那一格同一个数,不另扣。
-- 【门】require_permission('module.finance.view') —— 页面守卫 requireModule(MOD.finance)(claims/page.tsx:35)。
--   没有金额被遮(data.view_prices 只管决定表单),restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_expense_claims()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text, s.currency::text, 'amount'::text, round(sum(s.amount_ccy), 2), false
      FROM expense_claim_status s
     WHERE s.status <> 'submitted'
     GROUP BY s.currency
     ORDER BY s.currency;
END;
$function$;

-- ── db/functions/list_totals_expenses.sql ──
-- db/functions/list_totals_expenses.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1–Q3):/finance/expenses 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/finance/expenses/expenseRows.ts 的 applyExpenseFilters 逐项同一套:expense_date ≥ from、≤ to、payment_status = 状态;
--   科目筛选(resolveExpenseFilter,原先在 JS 里解出一组 id)在这里是 EXISTS(任何一行记在这个科目上)。
-- 【量】每个单据币种一行(amount_ccy)。筛着科目时只加【那个科目的行】的 amount_ccy(一张三行单只有一行是差旅),
--   按表头币种分组 —— 与 page.tsx 原先「只加这个科目的行」同一个意思,只是改成按币种、由库算。
-- 【净额】(Q2)冲销在本表是一张同为正数的镜像单(reverse_expense_internal.sql:143-159),原单翻成 reversed 并以
--   reversed_by_expense 指着它;镜像单(及它的行)在这里记【负数】,一对冲销加起来是 0。
-- 【门】require_permission('module.finance.view') —— 与页面守卫 requireModule(MOD.finance)、与 expenses / expense_lines 的
--   SELECT 策略同一个码。invoker;没有任何金额被遮,restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_expenses(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_payment_status text DEFAULT NULL::text, p_account text DEFAULT NULL::text)
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text,
           e.currency::text,
           'amount'::text,
           round(sum(CASE WHEN EXISTS (SELECT 1 FROM expenses o WHERE o.reversed_by_expense = e.id) THEN -1 ELSE 1 END
                     * CASE WHEN p_account IS NULL THEN e.amount_ccy
                            ELSE (SELECT sum(l.amount_ccy) FROM expense_lines l
                                   WHERE l.expense_id = e.id AND l.account_code = p_account) END), 2),
           false
      FROM expenses e
     WHERE (p_date_from IS NULL OR e.expense_date >= p_date_from)
       AND (p_date_to IS NULL OR e.expense_date <= p_date_to)
       AND (p_payment_status IS NULL OR e.payment_status = p_payment_status)
       AND (p_account IS NULL OR EXISTS (SELECT 1 FROM expense_lines l
                                          WHERE l.expense_id = e.id AND l.account_code = p_account))
     GROUP BY 2
     ORDER BY 2;
END;
$function$;

-- ── db/functions/list_totals_fixed_assets.sql ──
-- db/functions/list_totals_fixed_assets.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1):/finance/assets 台账那张表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
--   (下面那张折旧预览已经有库算的合计行 —— preview_depreciate_fixed_assets 的 total_delta —— 不归本函数。)
-- 【筛选】台账没有筛选,一次读全 fixed_assets(app/finance/assets/page.tsx:102);已处置的资产照样列着,所以照样计入。
-- 【四个合计】
--   'cost'     = cost_ccy,按行上的 currency(原币,每个币种一行);
--   'costBase' = cost_base,本位币;
--   'accum'    = Σ fixed_asset_depreciation.amount_base,本位币;
--   'nbv'      = Σ 每一行的 round(cost_base − 该资产累计折旧, 2),本位币 —— 与那一行的算法逐字同一个
--                (page.tsx:184/196:累计按资产先加、两位小数,再 cost_base − 累计 取两位)。
--   本位币那三列的 currency 给 (SELECT code FROM currencies WHERE is_base)。
-- 【净额】cost_base 本身已是未冲销成本明细之和(fixed_assets.sql 抬头);折旧行只追加、没有冲销镜像 —— 照行上的数加总。
-- 【门】require_permission('module.finance.view') —— 页面守卫 requireModule(MOD.finance)(assets/page.tsx:92),
--   与 fixed_assets / fixed_asset_depreciation 两张表的 SELECT 策略同一个码。invoker;没有金额被遮,restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_fixed_assets()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base text := (SELECT c.code FROM currencies c WHERE c.is_base);
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    WITH per_asset AS (
        SELECT a.currency::text AS ccy, a.cost_ccy, a.cost_base,
               COALESCE((SELECT round(sum(d.amount_base), 2) FROM fixed_asset_depreciation d WHERE d.asset_id = a.id), 0) AS accum
          FROM fixed_assets a
    ), cells AS (
        SELECT p.ccy AS ccy, 1 AS ord, 'cost'::text AS m, p.cost_ccy AS amt FROM per_asset p
        UNION ALL SELECT v_base, 2, 'costBase', p.cost_base FROM per_asset p
        UNION ALL SELECT v_base, 3, 'accum', p.accum FROM per_asset p
        UNION ALL SELECT v_base, 4, 'nbv', round(p.cost_base - p.accum, 2) FROM per_asset p
    )
    SELECT ''::text, c.ccy, c.m, round(sum(c.amt), 2), false
      FROM cells c
     GROUP BY c.ccy, c.ord, c.m
     ORDER BY (c.ccy = v_base) DESC, c.ccy, c.ord;
END;
$function$;

-- ── db/functions/list_totals_forwarders.sql ──
-- db/functions/list_totals_forwarders.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/logistics/forwarders 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/logistics/forwarders/page.tsx 同一个集合:货代 = supplier_lookup 里 counterparty_type = 'forwarder'、
--   deleted_at IS NULL(:36-44);欠款 = ap_open_items 里 counterparty_id 属于这些货代的 open_base(:83-94)。
-- 【合计】owed —— Σ open_base,本位币(currencies.is_base;页面 :95-99 同一个来源)。每一行「未结应付」照旧在页面上加。
-- 【净额】ap_open_items 自己已经只留未结的、并去掉了被冲销的费用(ap_open_items.sql:152-154)—— 这里不再另算。
-- 【门】require_permission('module.logistics.view') —— 与页面守卫(requireModule(MOD.logistics))同一个码。invoker。
-- 【受限】整个读者:NOT has_permission('module.finance.view')(视图对不持它的人回零行,ap_open_items.sql:178)
--   OR NOT has_permission('data.view_purchase_prices')(视图读 inbound_batches_masked 并只留 unit_price IS NOT NULL,
--   不持它的人【悄悄少了】每一笔入库应付,:110,119;预付抵扣也按它遮成 0)。受限而一行都看不见时 currency 给 NULL。
CREATE OR REPLACE FUNCTION public.list_totals_forwarders()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_hidden boolean;
BEGIN
    PERFORM require_permission('module.logistics.view');
    v_hidden := NOT has_permission('module.finance.view') OR NOT has_permission('data.view_purchase_prices');
    RETURN QUERY
    SELECT ''::text,
           CASE WHEN count(*) > 0 THEN (SELECT c.code FROM currencies c WHERE c.is_base)::text END,
           'owed'::text,
           CASE WHEN v_hidden THEN NULL::numeric ELSE round(sum(o.open_base), 2) END,
           v_hidden
      FROM ap_open_items o
     WHERE o.counterparty_id IN (SELECT f.id FROM supplier_lookup f
                                  WHERE f.counterparty_type = 'forwarder' AND f.deleted_at IS NULL)
    HAVING count(*) > 0 OR v_hidden;
END;
$function$;

-- ── db/functions/list_totals_freight.sql ──
-- db/functions/list_totals_freight.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1–Q3):/finance/freight 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/finance/freight/freightRows.ts 的 freightCount / freightPage 同一个固定谓词:deleted_at IS NULL(页面没有 URL 筛选)。
--   页面只画前 200 张(RowCapNotice 说出来);合计是【所有】符合的单据,不是那 200 张。
-- 【量】amount = amount_base(页面那一列印的就是本位币),currency 给本位币代码。
-- 【净额】(Q2)冲销的运费单只翻成 reversed、金额仍是正数,没有镜像行(reverse_freight_document.sql:60 是 UPDATE)→
--   status = 'reversed' 的排除在外(加 0)。它们仍是列表上的行,所以只要有行,合计就在(全部冲销时读 0.00,不是没有合计)。
-- 【门】require_permission('module.finance.view') —— 与页面守卫 requireModule(MOD.finance) 同一个码(表的 SELECT 策略是
--   inbound.view OR finance.view,宽于这一页的门)。invoker;金额不遮,restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_freight()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text,
           (SELECT c.code FROM currencies c WHERE c.is_base)::text,
           'amount'::text,
           round(COALESCE(sum(f.amount_base) FILTER (WHERE f.status <> 'reversed'), 0), 2),
           false
      FROM freight_documents f
     WHERE f.deleted_at IS NULL
    HAVING count(*) > 0;
END;
$function$;

-- ── db/functions/list_totals_inventory.sql ──
-- db/functions/list_totals_inventory.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1 与「库存估值合计条由库算的合计取代」):/inventory 台账的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【集合】正是台账的行:inventory_stock_by_material() 的每一行(批次集合与每一列的规则写在那支函数的抬头里)。
--   页面没有筛选(快照页,既定约定),所以没有参数。合计 = 每一列在所有物料上的精确和,取 2 位
--   (每一行在屏幕上各自四舍五入,所以表尾与「屏幕上各行之和」可能差几分 —— 表尾是对的那个)。
-- 【三个合计,两个币种】measure:
--   * stockValue  —— 本位币(currencies.is_base)。
--   * costValue   —— 本位币。
--   * marketValue —— USD(metal_prices.price_usd_per_tonne,不折算;lib/valuation.ts 抬头)。币种字面量写在这里而不是交给页面
--     (fixedCurrency):它是这一列的单位,烤在它所乘的那一列的列名里(该表没有币种列),与算它的那支函数放在一起。
--   avgPrice 是价,不合计(裁定:价格类列没有合计)。
-- 【受限】stockValue / costValue:NOT has_permission('data.view_prices') —— 两列被同一条权限遮蔽(inbound_batch_valuation_rows、
--   processing_output_lookup),所以按读者判,不按行数判;受限时 total 为 NULL,而且即使一行都没有也照样各给一行;currency 仍给本位币 —— 列的币种是固定的(列头写着),说出它不泄露任何数,表尾因此仍是「本位币一行、USD 一行」。
--   marketValue 不遮蔽,restricted 恒为 false。
--   ★ 有权限的读者看到的 NULL 是真的「没有」(未计价的批、从未分摊的产出腿),不算受限 —— 与行上那根「—」同一个意思。
-- 【空集】某一列在所有物料上都是 NULL(没有一批计入)且读者不受限 → 那一列不出行(页面不画那一格)。
-- 【门】require_permission('module.inventory.view') —— 页面守卫 requireModule(MOD.inventory)(lib/modules.ts)。INVOKER。
CREATE OR REPLACE FUNCTION public.list_totals_inventory()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base text;
    v_prices boolean;
BEGIN
    PERFORM require_permission('module.inventory.view');
    v_prices := has_permission('data.view_prices');
    SELECT c.code::text INTO v_base FROM currencies c WHERE c.is_base;

    RETURN QUERY
    WITH r AS (
        SELECT sum(s.stock_value) AS stock_value, sum(s.cost_value) AS cost_value, sum(s.market_value) AS market_value
          FROM inventory_stock_by_material() s
    )
    SELECT ''::text, v_base, 'stockValue'::text, round(r.stock_value, 2), false
      FROM r WHERE v_prices AND r.stock_value IS NOT NULL
    UNION ALL
    SELECT ''::text, v_base, 'stockValue'::text, NULL::numeric, true
     WHERE NOT v_prices
    UNION ALL
    SELECT ''::text, v_base, 'costValue'::text, round(r.cost_value, 2), false
      FROM r WHERE v_prices AND r.cost_value IS NOT NULL
    UNION ALL
    SELECT ''::text, v_base, 'costValue'::text, NULL::numeric, true
     WHERE NOT v_prices
    UNION ALL
    SELECT ''::text, 'USD'::text, 'marketValue'::text, round(r.market_value, 2), false
      FROM r WHERE r.market_value IS NOT NULL;
END;
$function$;

-- ── db/functions/list_totals_invoices.sql ──
-- db/functions/list_totals_invoices.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1–Q3):/finance/invoices 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【读】与页面同一张视图 invoice_status(app/finance/invoices/invoiceRows.ts issuedCount/issuedPage;视图读 invoices_masked)。
-- 【筛选】与 invoiceRows.ts 的 applyDates / applyState 逐项同一套:issue_date ≥ from、≤ to;state = 'overdue' → overdue = true,
--   其余 state → payment_state = state(看不见价格的读者那里 overdue / payment_state 由 NULL 合计推出,与列表同样地筛 —— 同一个集合)。
-- 【净额】(Q2)作废的发票被它的冲销抵掉,加 0:作废的不进任何一个合计。于是 status='void' 返回零行(没有可加的),
--   status='all' 与 'issued' 是同一个合计(页面 page.tsx 在 'all' 时把作废的接在后面,它们在这里加 0)。
-- 【量】total(total_base)· settled(settled_base)· open(open_base),都是本位币,currency 给本位币代码。
-- 【受限】total / open 在 invoices_masked 里按 data.view_prices 整个读者地遮(invoices_masked.sql:33-36)→
--   restricted = NOT has_permission('data.view_prices'),total 为 NULL;没有可见行时也照样返回那一行(受限不用零行表示)。
--   settled 不遮(invoice_status.sql:32),restricted 恒为 false。
-- 【门】require_permission('module.finance.view') —— 与页面守卫 requireModule(MOD.finance)、与视图的谓词同一个码。invoker。
CREATE OR REPLACE FUNCTION public.list_totals_invoices(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_state text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_masked boolean;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_status = 'void' THEN
        RETURN;
    END IF;
    v_masked := NOT has_permission('data.view_prices');
    RETURN QUERY
    WITH a AS (
        SELECT count(*) AS n,
               sum(v.total_base) AS t,
               sum(v.settled_base) AS s,
               sum(v.open_base) AS o
          FROM invoice_status v
         WHERE (p_date_from IS NULL OR v.issue_date >= p_date_from)
           AND (p_date_to IS NULL OR v.issue_date <= p_date_to)
           AND (p_state IS NULL
                OR (p_state = 'overdue' AND v.overdue = true)
                OR (p_state <> 'overdue' AND v.payment_state = p_state))
    )
    SELECT ''::text,
           (SELECT c.code FROM currencies c WHERE c.is_base)::text,
           m.measure,
           CASE WHEN m.restr THEN NULL ELSE round(m.val, 2) END,
           m.restr
      FROM a
     CROSS JOIN LATERAL (VALUES (1, 'total'::text, a.t, v_masked),
                                (2, 'settled'::text, a.s, false),
                                (3, 'open'::text, a.o, v_masked)) AS m(ord, measure, val, restr)
     WHERE a.n > 0 OR m.restr
     ORDER BY m.ord;
END;
$function$;

-- ── db/functions/list_totals_journal.sql ──
-- db/functions/list_totals_journal.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1–Q3 · Q6):/finance/journal 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/finance/journal/journalRows.ts 的 applyFilters 同一套:entry_date ≥ from、≤ to(journal_entries 无软删、无状态筛选)。
-- 【量】amount = 每张分录 Σ借方(与 shapeJournalRows 同一个数),读 journal_lines_masked —— 【绝不读基表 journal_lines】:
--   那上面的 restrictive 策略让不持 data.view_pay 的人读不到工资分录的行,合计会悄悄变小、永远说不出「受限」
--   (journal_lines.sql:106-111)。本位币,currency 给本位币代码。
-- 【净额】(Q2)冲销是一张同为正数的冲销分录(reverse_journal_entry_internal.sql:56-70),原分录翻成 reversed 并以
--   reversed_by 指着它;冲销分录在这里记【负数】,一对冲销加起来是 0。
-- 【受限】逐行遮(journal_lines_masked.sql:19,工资分录 × 不持 data.view_pay):集合里任何一行 amounts_restricted →
--   整个合计 restricted、total 为 NULL(Q6:不把看得见的那一部分单独印出来)。
-- 【门】require_permission('module.finance.view') —— 与页面守卫 requireModule(MOD.finance)、与视图的行谓词同一个码。invoker。
CREATE OR REPLACE FUNCTION public.list_totals_journal(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date)
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text,
           (SELECT c.code FROM currencies c WHERE c.is_base)::text,
           'amount'::text,
           CASE WHEN bool_or(l.amounts_restricted) THEN NULL
                ELSE round(sum(CASE WHEN EXISTS (SELECT 1 FROM journal_entries o WHERE o.reversed_by = e.id)
                                    THEN -l.debit ELSE l.debit END), 2) END,
           bool_or(l.amounts_restricted)
      FROM journal_entries e
      JOIN journal_lines_masked l ON l.entry_id = e.id
     WHERE (p_date_from IS NULL OR e.entry_date >= p_date_from)
       AND (p_date_to IS NULL OR e.entry_date <= p_date_to)
    HAVING count(*) > 0;
END;
$function$;

-- ── db/functions/list_totals_medical_claims.sql ──
-- db/functions/list_totals_medical_claims.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/hr/claims 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/hr/claims/claimsRows.ts:60-65 的 filtered() 逐项同一套:employee_id = 员工、claim_year = 年、
--   settlement_state = 状态;读同一张视图 medical_claim_status(claimsRows.ts:73)。
-- 【合计】amount(amount_sgd)。currency 给 NULL:这一列固定是新元,列名与格子(ClaimsTable.tsx)写着 SGD,由页面说出来。
-- 【净额】医疗报销没有冲销镜像行;页面列出所有状态(含 rejected / withdrawn),合计照列表同一个集合。
-- 【门】require_permission('module.hr.view') —— 与页面守卫(requireModule(MOD.hr))同一个码。invoker。
-- 【受限】逐行:视图对不持 data.view_health 的读者把别人的金额置 NULL(medical_claim_status.sql:27-30),
--   基表 amount_sgd NOT NULL CHECK > 0(medical_claims.sql:13)—— 所以这里 NULL 就是「看不见」,不是「没有」。
CREATE OR REPLACE FUNCTION public.list_totals_medical_claims(p_employee uuid DEFAULT NULL::uuid, p_year integer DEFAULT NULL::integer, p_status text DEFAULT NULL::text)
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.hr.view');
    RETURN QUERY
    SELECT ''::text, NULL::text, 'amount'::text,
           CASE WHEN bool_or(m.amount_sgd IS NULL) THEN NULL::numeric ELSE round(sum(m.amount_sgd), 2) END,
           bool_or(m.amount_sgd IS NULL)
      FROM medical_claim_status m
     WHERE (p_employee IS NULL OR m.employee_id = p_employee)
       AND (p_year IS NULL OR m.claim_year = p_year)
       AND (p_status IS NULL OR m.settlement_state = p_status)
    HAVING count(*) > 0;
END;
$function$;

-- ── db/functions/list_totals_my_expense_claims.sql ──
-- db/functions/list_totals_my_expense_claims.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/me 费用报销那张表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/me/meRows.ts 的 myExpenseCount / myExpensePage 同一套:expense_claim_status,employee_id = 本人。
--   没有参数:主语就是调用者(current_user_employee());不是员工 → 按名拒。
-- 【合计】amount(amount_ccy),每个币种(单据自己的 currency)一行。
-- 【净额】报销单本身没有冲销镜像行(冲销发生在它生成的那张费用单上,报销单这一行不变);所有状态都在列表里,合计同一个集合。
-- 【门】没有模块码:/me 不挂模块守卫,行由视图的「本人」谓词放行(expense_claim_status.sql 的 WHERE)。invoker。
-- 【受限】视图不遮金额;照实算 bool_or(amount_ccy IS NULL) —— 基表 NOT NULL CHECK > 0(expense_claims.sql:23)。
CREATE OR REPLACE FUNCTION public.list_totals_my_expense_claims()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp uuid;
BEGIN
    v_emp := current_user_employee();
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'LIST_TOTALS_NO_EMPLOYEE'
          USING HINT = '这份合计只算调用者自己的行,而这个登录账号没有对应的员工档案。';
    END IF;
    RETURN QUERY
    SELECT ''::text, c.currency::text, 'amount'::text,
           CASE WHEN bool_or(c.amount_ccy IS NULL) THEN NULL::numeric ELSE round(sum(c.amount_ccy), 2) END,
           bool_or(c.amount_ccy IS NULL)
      FROM expense_claim_status c
     WHERE c.employee_id = v_emp
     GROUP BY c.currency
     ORDER BY 2;
END;
$function$;

-- ── db/functions/list_totals_my_medical_claims.sql ──
-- db/functions/list_totals_my_medical_claims.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/me 医疗报销那张表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/me/meRows.ts 的 myMedicalCount / myMedicalPage 同一套:medical_claim_status,employee_id = 本人。
--   没有参数:主语就是调用者(current_user_employee());不是员工 → 按名拒(/me 对没有员工档案的人不画这张表)。
-- 【合计】amount(amount_sgd)。currency 给 NULL:固定新元,面板格子写着 SGD(MyClaimsPanel.tsx),由页面说出来。
-- 【净额】没有冲销镜像行;所有状态都在列表里,合计同一个集合。
-- 【门】没有模块码:/me 不挂模块守卫,行由视图的「本人」谓词放行(medical_claim_status.sql 末行)。invoker。
-- 【受限】本人的行从不遮(视图 CASE 对 employee_id = current_user_employee() 让路),但照实算:bool_or(amount_sgd IS NULL)
--   —— 基表 NOT NULL,NULL 只可能是遮。
CREATE OR REPLACE FUNCTION public.list_totals_my_medical_claims()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp uuid;
BEGIN
    v_emp := current_user_employee();
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'LIST_TOTALS_NO_EMPLOYEE'
          USING HINT = '这份合计只算调用者自己的行,而这个登录账号没有对应的员工档案。';
    END IF;
    RETURN QUERY
    SELECT ''::text, NULL::text, 'amount'::text,
           CASE WHEN bool_or(m.amount_sgd IS NULL) THEN NULL::numeric ELSE round(sum(m.amount_sgd), 2) END,
           bool_or(m.amount_sgd IS NULL)
      FROM medical_claim_status m
     WHERE m.employee_id = v_emp
    HAVING count(*) > 0;
END;
$function$;

-- ── db/functions/list_totals_my_payslips.sql ──
-- db/functions/list_totals_my_payslips.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/me 工资单那张表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/me/page.tsx:146-149 同一套:payroll_lines_masked,employee_id = 本人(没有状态 / 删除筛选 —— 页面也没有;
--   币种取自那一期,与页面经 my_period_labels() 配币种同一个来源,那支也不看 deleted_at)。
-- 【合计】gross(gross_pay)、employer_cpf、employee_cpf、deductions(other_deductions)、net(net_pay),每个期间币种一行。
-- 【净额】工资单行没有冲销镜像行(UNIQUE 期间 + 员工,payroll_lines.sql:33)—— 照加。
-- 【为什么是 DEFINER】币种住在 payroll_periods 上,它的读策略只有 module.hr.view(与 my_period_labels.sql 抬头同一个理由)。
--   DEFINER 只用来越过那张表的读策略:主语就是调用者 —— 没有参数,current_user_employee() 为 NULL(anon、没有员工档案)
--   → 按名拒;只读 employee_id = 调用者 的行。金额仍从 payroll_lines_masked 读(其 CASE 按调用者的会话求值),不读基表。
-- 【门】没有模块码:/me 不挂模块守卫;调用者检查就是上面那条员工判据。
-- 【受限】本人的行从不遮,但照实算:bool_or(<列> IS NULL) —— 五列基表都 NOT NULL(payroll_lines.sql:26-30),NULL 只可能是遮。
CREATE OR REPLACE FUNCTION public.list_totals_my_payslips()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp uuid;
BEGIN
    v_emp := current_user_employee();
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'LIST_TOTALS_NO_EMPLOYEE'
          USING HINT = '这份合计只算调用者自己的行,而这个登录账号没有对应的员工档案。';
    END IF;
    RETURN QUERY
    WITH s AS (
        SELECT pp.currency::text AS ccy,
               sum(l.gross_pay) AS gross, bool_or(l.gross_pay IS NULL) AS gross_h,
               sum(l.employer_cpf) AS er, bool_or(l.employer_cpf IS NULL) AS er_h,
               sum(l.employee_cpf) AS ee, bool_or(l.employee_cpf IS NULL) AS ee_h,
               sum(l.other_deductions) AS ded, bool_or(l.other_deductions IS NULL) AS ded_h,
               sum(l.net_pay) AS net, bool_or(l.net_pay IS NULL) AS net_h
          FROM payroll_lines_masked l
          JOIN payroll_periods pp ON pp.id = l.payroll_period_id
         WHERE l.employee_id = v_emp
         GROUP BY pp.currency
    )
    SELECT ''::text, s.ccy, m.k, CASE WHEN m.h THEN NULL::numeric ELSE round(m.v, 2) END, m.h
      FROM s CROSS JOIN LATERAL (VALUES
               ('gross'::text, s.gross, s.gross_h),
               ('employer_cpf'::text, s.er, s.er_h),
               ('employee_cpf'::text, s.ee, s.ee_h),
               ('deductions'::text, s.ded, s.ded_h),
               ('net'::text, s.net, s.net_h)) m(k, v, h)
     ORDER BY 2;
END;
$function$;

-- ── db/functions/list_totals_payment_requests.sql ──
-- db/functions/list_totals_payment_requests.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1):/finance/payment-requests 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/finance/payment-requests/requestRows.ts 的 statusSet / applyFilters(:27-29、:45-50)逐项同一套:
--   p_status 'open' = status IN ('submitted','approved');'all' 或 NULL = 不筛;其余 = 那一个状态。
--   页面总是把 parseRequestFilter 解析过的那一个值传进来(默认 'open')。
-- 【合计】amount_ccy 按行上的 currency,每个币种一行;六种 kind 一并计入(列表上的每一行都算,与列表同一个集合)。
-- 【净额】付款申请是一张【申请】,不是一笔过账:冲销申请(payment_reversal 等)是它自己的一行、金额为正,
--   原申请不因此翻状态 —— 没有"镜像行"也没有"被冲销"的标记,所以照行上的数加总。
-- 【门】require_permission('module.finance.view') —— 页面守卫 requireModule(MOD.finance)(payment-requests/page.tsx:33),
--   与 payment_requests 的 SELECT 策略(payment_requests.sql:190-192)同一个码。invoker;没有金额被遮,restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_payment_requests(p_status text DEFAULT NULL::text)
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text, r.currency::text, 'amount'::text, round(sum(r.amount_ccy), 2), false
      FROM payment_requests r
     WHERE CASE WHEN p_status IS NULL OR p_status = 'all' THEN true
                WHEN p_status = 'open' THEN r.status IN ('submitted', 'approved')
                ELSE r.status = p_status END
     GROUP BY r.currency
     ORDER BY r.currency;
END;
$function$;

-- ── db/functions/list_totals_payments.sql ──
-- db/functions/list_totals_payments.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q2 · Q4):/finance/payments 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/finance/payments/paymentRows.ts 的 applyFilters 逐项同一套:payment_date ≥ from、≤ to、direction = 方向。
-- 【两个合计,不轧差】(Q4)grp 'received' = direction 'in','paid' = 'out';每个币种各一行。
-- 【净额】(Q2)冲销在本表里是一条【同方向、同为正数】的镜像行(reverse_payment_internal.sql:56-63),原件翻成 reversed。
--   镜像行由原件的 reversed_by_payment 指着;它在这里记【负数】,于是一对冲销加起来是 0,而按日期切开时两半各落在
--   各自的日子上 —— 与总账上原分录与冲销分录各自的日期一致。
-- 【门】require_permission('module.finance.view') —— 与页面守卫(requireModule(MOD.finance))、与 payments 的 SELECT 策略同一个码。
--   本函数是 invoker:读的就是读者自己读得到的那些行,与列表同一份。没有任何金额被遮,所以 restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_payments(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_direction text DEFAULT NULL::text)
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT CASE WHEN p.direction = 'in' THEN 'received' ELSE 'paid' END,
           p.currency::text,
           'amount'::text,
           round(sum(CASE WHEN EXISTS (SELECT 1 FROM payments o WHERE o.reversed_by_payment = p.id)
                          THEN -p.amount_ccy ELSE p.amount_ccy END), 2),
           false
      FROM payments p
     WHERE (p_date_from IS NULL OR p.payment_date >= p_date_from)
       AND (p_date_to IS NULL OR p.payment_date <= p_date_to)
       AND (p_direction IS NULL OR p.direction = p_direction)
     GROUP BY 1, 2
     ORDER BY 1 DESC, 2;
END;
$function$;

-- ── db/functions/list_totals_payroll.sql ──
-- db/functions/list_totals_payroll.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/hr/payroll 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/hr/payroll/page.tsx:33-37 同一套:payroll_periods_masked,deleted_at IS NULL(没有地址栏筛选)。
-- 【合计】应发合计 gross(gross_total)与实发合计 net(net_pay_total),每个币种(期间自己的 currency)一行。
-- 【净额】工资期间没有冲销镜像行(状态只有 draft / posted,payroll_periods.sql:24),一期一行 —— 照加。
-- 【门】require_permission('module.hr.view') —— 与页面守卫(requireModule(MOD.hr))、与视图的行谓词同一个码。invoker。
-- 【受限】整个读者:NOT has_permission('data.view_pay') —— 与 payroll_periods_masked.sql:15-34 的 CASE 同一个码。
--   受限而一行都没有时,仍每个 measure 回一行(currency NULL,total NULL,restricted true)。
CREATE OR REPLACE FUNCTION public.list_totals_payroll()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_hidden boolean;
BEGIN
    PERFORM require_permission('module.hr.view');
    v_hidden := NOT has_permission('data.view_pay');
    RETURN QUERY
    WITH s AS (
        SELECT p.currency::text AS ccy, sum(p.gross_total) AS gross, sum(p.net_pay_total) AS net
          FROM payroll_periods_masked p
         WHERE p.deleted_at IS NULL
         GROUP BY p.currency
    )
    SELECT ''::text, s.ccy, m.k, CASE WHEN v_hidden THEN NULL::numeric ELSE round(m.v, 2) END, v_hidden
      FROM s CROSS JOIN LATERAL (VALUES ('gross'::text, s.gross), ('net'::text, s.net)) m(k, v)
    UNION ALL
    SELECT ''::text, NULL::text, m.k, NULL::numeric, true
      FROM (VALUES ('gross'::text), ('net'::text)) m(k)
     WHERE v_hidden AND NOT EXISTS (SELECT 1 FROM s)
     ORDER BY 2, 3;
END;
$function$;

-- ── db/functions/list_totals_purchase_orders.sql ──
-- db/functions/list_totals_purchase_orders.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/purchasing/orders 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/purchasing/orders/orderRows.ts 逐项同一套(parsePoListParams :48-57 · applyFilters :84-90 · applyStatus :91-95):
--   order_date ≥ from、≤ to、supplier_id = 供应商;状态 = cancelled 时读 purchase_orders_masked(status = 'cancelled',
--   deleted_at IS NULL —— 与 poPage 那一支同一个关系,orderRows.ts:117-126),否则读 purchase_order_status
--   (它自己排除已取消与已删除,purchase_order_status.sql 末尾)并按 status = 状态。
-- 【合计】每个单据币种一行:net(estimated_total_ccy)、tax(tax_total_ccy,只加 carries_tax 的单 —— 未计税的单税额是
--   【合法的 NULL】,屏幕印「—」,不是遮;一张计税的单都没有的币种不回 tax)、gross(gross_total_ccy = 净额 + COALESCE(税,0),
--   与屏幕 orderRows.ts:190 同一个数)。prepaid(prepaid_base)是本位币,另一行;只在非已取消那一支(已取消那一支屏幕上是 n/a)。
-- 【净额】采购单没有冲销镜像行;已取消的单默认不在集合里(与列表同),只在筛「已取消」时自成一个集合。
-- 【门】require_permission('module.purchasing.view') —— 与页面守卫(requireModule(MOD.purchasing))、两张视图的行谓词同一个码。invoker。
-- 【受限】整个读者:net / tax / gross = NOT has_permission('data.view_purchase_prices')(purchase_orders_masked.sql 的 CASE);
--   prepaid = NOT has_permission('module.finance.view')(purchase_order_status.sql 的 CASE)。受限而一行都没有时,
--   仍每个 measure 回一行(currency NULL,total NULL,restricted true)。
CREATE OR REPLACE FUNCTION public.list_totals_purchase_orders(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_supplier uuid DEFAULT NULL::uuid, p_status text DEFAULT NULL::text)
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_price_hidden boolean;
    v_prepaid_hidden boolean;
    v_cancelled boolean;
    v_base text;
BEGIN
    PERFORM require_permission('module.purchasing.view');
    v_price_hidden := NOT has_permission('data.view_purchase_prices');
    v_prepaid_hidden := NOT has_permission('module.finance.view');
    v_cancelled := COALESCE(p_status = 'cancelled', false);
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    RETURN QUERY
    WITH r AS (
        SELECT po.currency::text AS ccy, po.estimated_total_ccy AS net, po.tax_total_ccy AS tax,
               po.gross_total_ccy AS gross, po.carries_tax AS taxed, NULL::numeric AS prepaid
          FROM purchase_orders_masked po
         WHERE v_cancelled
           AND po.status = 'cancelled' AND po.deleted_at IS NULL
           AND (p_date_from IS NULL OR po.order_date >= p_date_from)
           AND (p_date_to IS NULL OR po.order_date <= p_date_to)
           AND (p_supplier IS NULL OR po.supplier_id = p_supplier)
        UNION ALL
        SELECT s.currency::text, s.estimated_total_ccy, s.tax_total_ccy,
               s.gross_total_ccy, s.carries_tax, s.prepaid_base
          FROM purchase_order_status s
         WHERE NOT v_cancelled
           AND (p_date_from IS NULL OR s.order_date >= p_date_from)
           AND (p_date_to IS NULL OR s.order_date <= p_date_to)
           AND (p_supplier IS NULL OR s.supplier_id = p_supplier)
           AND (p_status IS NULL OR s.status = p_status)
    ), by_ccy AS (
        SELECT r.ccy, sum(r.net) AS net, sum(r.tax) FILTER (WHERE r.taxed) AS tax, bool_or(r.taxed) AS any_taxed,
               sum(r.gross) AS gross
          FROM r
         GROUP BY r.ccy
    )
    SELECT ''::text, b.ccy, m.k, CASE WHEN v_price_hidden THEN NULL::numeric ELSE round(m.v, 2) END, v_price_hidden
      FROM by_ccy b CROSS JOIN LATERAL (VALUES ('net'::text, b.net, true), ('tax'::text, b.tax, b.any_taxed),
                                               ('gross'::text, b.gross, true)) m(k, v, present)
     WHERE m.present OR v_price_hidden
    UNION ALL
    SELECT ''::text, NULL::text, m.k, NULL::numeric, true
      FROM (VALUES ('net'::text), ('tax'::text), ('gross'::text)) m(k)
     WHERE v_price_hidden AND NOT EXISTS (SELECT 1 FROM r)
    UNION ALL
    SELECT ''::text, CASE WHEN EXISTS (SELECT 1 FROM r) THEN v_base END, 'prepaid'::text,
           CASE WHEN v_prepaid_hidden THEN NULL::numeric ELSE round(sum(r.prepaid), 2) END, v_prepaid_hidden
      FROM r
    HAVING NOT v_cancelled AND (count(*) > 0 OR v_prepaid_hidden)
     ORDER BY 2, 3;
END;
$function$;

-- ── db/functions/list_totals_self_approved.sql ──
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

-- ── db/functions/list_totals_settlements.sql ──
-- db/functions/list_totals_settlements.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/contracts 上「已记录的结算」那张表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/contracts/page.tsx:112-116 同一套:sales_settlements,superseded_by IS NULL(没有地址栏筛选)。
-- 【合计】amount(amount_usd)。currency 给 NULL:这一列固定是美元,列头(contracts.settlement.colAmount)写着 USD。
-- 【净额】被改记的结算由 superseded_by 指向新的那一条,旧的不在集合里 —— 每一笔结算只算它当前的那一次。
-- 【门】require_permission('module.suppliers.view') —— 与页面守卫(requireModule(MOD.suppliers))同一个码。invoker。
-- 【受限】整个读者:NOT has_permission('module.customers.view')。页面的门是 suppliers.view,而这张表的读策略要
--   customers.view(sales_settlements.sql:90-92)—— 不持它的读者读到【零行】,而那不是「没有结算」。
--   所以那时回一行 restricted(currency NULL,total NULL),不回零行。
CREATE OR REPLACE FUNCTION public.list_totals_settlements()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.suppliers.view');
    IF NOT has_permission('module.customers.view') THEN
        RETURN QUERY SELECT ''::text, NULL::text, 'amount'::text, NULL::numeric, true;
        RETURN;
    END IF;
    RETURN QUERY
    SELECT ''::text, NULL::text, 'amount'::text, round(sum(ss.amount_usd), 2), false
      FROM sales_settlements ss
     WHERE ss.superseded_by IS NULL
    HAVING count(*) > 0;
END;
$function$;

-- ── db/functions/list_totals_wht_liability.sql ──
-- db/functions/list_totals_wht_liability.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1):/finance/wht 那张【按月欠税】表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】页面没有筛选,一次读全 wht_liability_by_month(app/finance/wht/page.tsx:48-50)。本函数读同一张视图
--   (属主权限、行谓词 has_permission('module.finance.view'))—— 不另起一份对总账与 wht_remittances 的算术。
-- 【三个合计】measure 'withheld' = withheld_base、'remitted' = remitted_base、'unremitted' = unremitted_base,
--   全是本位币:currency 给 (SELECT code FROM currencies WHERE is_base)。
--   Σ unremitted ≡ 2150 的科目余额(视图抬头那条不变量),所以它不是一个余额列的合计,是那个余额本身。
-- 【净额】(Q2)已在视图里:冲销的汇款整笔掉出 remitted(e.status = 'posted'),它的冲销分录带同一个 source_type、
--   也不进 withheld —— 一对冲销加起来是 0。
-- 【门】require_permission('module.finance.view') —— 页面守卫 requireModule(MOD.finance)(wht/page.tsx:36),与视图谓词同一个码。
--   invoker;没有金额被遮,restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_wht_liability()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base text := (SELECT c.code FROM currencies c WHERE c.is_base);
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text, v_base, m.m, round(sum(m.amt), 2), false
      FROM wht_liability_by_month w
      CROSS JOIN LATERAL (VALUES (1, 'withheld'::text, w.withheld_base),
                                 (2, 'remitted'::text, w.remitted_base),
                                 (3, 'unremitted'::text, w.unremitted_base)) AS m(ord, m, amt)
     GROUP BY m.ord, m.m
     ORDER BY m.ord;
END;
$function$;

-- ── db/functions/list_totals_wht_remittances.sql ──
-- db/functions/list_totals_wht_remittances.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q2):/finance/wht 那张【汇款登记】表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】页面没有筛选,一次读全 wht_remittances(app/finance/wht/page.tsx:51-53)。
-- 【合计】amount_base,本位币:currency 给 (SELECT code FROM currencies WHERE is_base)。
-- 【净额】(Q2)冲销一笔汇款只把它的分录翻成 reversed,登记簿上那一行照旧是正数 → 冲销过的【排除】(加 0)。
--   判据与页面逐字同一条:分录 status 不是 'posted' 就算已冲销(page.tsx:127 `entryStatus.get(...) !== 'posted'`),
--   也与 wht_liability_by_month 的 remitted 那一半同一条 —— 于是本合计 ≡ 上面那张表的 remitted 合计。
-- 【门】require_permission('module.finance.view') —— 页面守卫 requireModule(MOD.finance)(wht/page.tsx:36),
--   与 wht_remittances 的 SELECT 策略(wht_remittances.sql:67-70)同一个码。invoker;没有金额被遮,restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_wht_remittances()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text, (SELECT c.code FROM currencies c WHERE c.is_base)::text, 'amount'::text, round(sum(r.amount_base), 2), false
      FROM wht_remittances r
     WHERE EXISTS (SELECT 1 FROM journal_entries e WHERE e.id = r.journal_entry_id AND e.status = 'posted')
    HAVING count(*) > 0;
END;
$function$;

NOTIFY pgrst, 'reload schema';

COMMIT;
