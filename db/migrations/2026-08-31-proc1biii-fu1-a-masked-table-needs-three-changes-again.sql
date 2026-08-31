-- PROC-1B-iii · fu1:遮蔽表加一列 = 三件事,而主刀又只做了一件
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【同一个形状,一周之内第二次】★★
-- 2026-08-31 早些时候的 procwire1bi-fu1 写着一模一样的抬头:
--   "加列的时候要问的不是「这一列敏不敏感」,而是「这张表【是不是】遮蔽表」——
--    后者是一个可以查的事实(有没有 _masked 伴生),前者是一个判断,而判断会漏。"
-- **那句话是对的,而它没能拦住这一次。** 主刀给 purchase_order_lines 加了
-- deep_discharge_judgement_code、给 inbound_batches 加了 deep_discharge_actual_code,
-- 而两张都是遮蔽表 —— 三件事只做了第一件。
--
-- 线上实测(改之前,两条都是):
--   has_column_privilege('authenticated','purchase_order_lines',
--                        'deep_discharge_judgement_code','SELECT') = false
--   has_column_privilege('authenticated','inbound_batches',
--                        'deep_discharge_actual_code','SELECT') = false
-- 也就是说:**这两列存在,但每一个登录用户都读不到它们。**
-- 采购单页上那个判断会永远显示成"未填写",进料批页上那个实际会永远是"未记录",
-- 而 grn_discrepancies 的差异会永远是 NULL —— **一个字的报错都不会有。**
-- ★ 这一刀最要命的地方正在这里:那个"永远 NULL"与本刀刻意设计的
--   "缺一侧就是 NULL"【长得一模一样】。缺陷会藏在正确行为的背后。★
--
-- 【它是怎么被抓到的,记下来 —— 因为这一条比上面那句注解管用】
-- 不是靠人记得那条规矩,是 `npm run build`:
--   ① check-masked-reads 先拒了直连 purchase_order_lines 的读取;
--   ② 改成读 _masked 之后,**tsc 当场说那张视图上没有这一列**。
-- 两道机械检查接力,把一条"要靠人记着"的规矩变成了一次编译失败。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── ① 列级授权 ──────────────────────────────────────────────────────────────
-- 【不遮蔽,原样透出】这两列都不是钱,也不是个人信息:一条"这批料能不能深度
-- 放电"的判断,与 form_code / chemistry_certainty_code 同一类 —— 它是【工艺
-- 路由】要用的事实,谁看得见这张单/这一批,谁就该看得见它。
GRANT SELECT (deep_discharge_judgement_code) ON public.purchase_order_lines TO authenticated;
GRANT SELECT (deep_discharge_actual_code)    ON public.inbound_batches      TO authenticated;

-- ── ② _masked 伴生视图:【每一列都必须在】,授没授权都一样 ────────────────────
-- (colgrant 的第二个分支;CREATE OR REPLACE 只允许在末尾追加列,而这两列
--  本来就是 ALTER 加的、排在 attnum 末尾 —— 顺序天然对得上。)

CREATE OR REPLACE VIEW public.purchase_order_lines_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_id,
    line_no,
    material_id,
    quantity,
    unit,
    pricing_formula_id,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN estimated_unit_price
            ELSE NULL::numeric
        END AS estimated_unit_price,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN estimated_amount_ccy
            ELSE NULL::numeric
        END AS estimated_amount_ccy,
    expected_assay,
    notes,
    created_at,
    created_by,
    price_source,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN price_provenance
            ELSE NULL::jsonb
        END AS price_provenance,
    asset_id,
    deep_discharge_judgement_code
   FROM purchase_order_lines
  WHERE has_permission('module.purchasing.view'::text);

CREATE OR REPLACE VIEW public.inbound_batches_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    material_id,
    supplier_id,
    quantity,
    unit,
    remaining_qty,
    arrival_date,
    stage,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    purchase_order_id,
    purchase_order_line_id,
    pricing_formula_id,
    pricing_status,
    deleted_by,
    delete_reason,
    declared_qty,
    chemistry_certainty_code,
    imported,
    import_permit_ref,
    import_permit_verified_by,
    import_permit_verified_at,
    deep_discharge_actual_code
   FROM inbound_batches
  WHERE has_permission('module.inbound.view'::text);

COMMIT;
