-- db/migrations/2026-09-08-silent1-refused-writes-raise.sql
-- SILENT-1:被拒绝的写不再是一次"成功的空操作" —— 它现在会抛,而且抛的是一个【码】。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【病】RLS 不报错,它只是让语句什么都碰不到
-- ════════════════════════════════════════════════════════════════════════════
--   本库【每一条】写策略都是 `USING (p) WITH CHECK (p)` —— 两侧同一个谓词:
--     UPDATE 98 条,全部同谓词;ALL 33 条,全部同谓词;
--     DELETE 67 条,**连 WITH CHECK 这一半都没有**(DELETE 本来就没有)。
--     而 INSERT 的 103 条两侧【都不同】—— 所以插入一直是会抛的。
--   不满足 p 的人先卡在 USING 上:那一行根本没有进入语句的视野,
--   **WITH CHECK 永远没有机会抛 42501**。零行不是错误,于是 error 为 null,
--   动作层 return { success: true },屏幕上一个字都没有。
--
--   ALERT-1 量到十处,那十处是【碰巧坐在 alert() 后面的】那些。
--   本刀按【形状】重扫:74 处应用写入路径、61 张表,而不是十处。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么是语句级触发器,而不是另外三条路】—— 四条都实测过,不是推的
-- ════════════════════════════════════════════════════════════════════════════
--   ① 改策略成 `USING(true) WITH CHECK(p)`:**只治一半**。
--      实测:containers(此人读得到)→ 抛 42501 ✓;
--            materials(此人读不到)→ 仍然 rows=0 raised=NONE ✗ ——
--      因为 SELECT 策略先把那一行从 WHERE 里藏掉了,WITH CHECK 还是轮不到。
--      而且它抛出来的是 `new row violates row-level security policy for table "…"`,
--      **正是本刀被明令不许去建映射的那一类机器字**。两条理由,各自足够。
--   ② 行级触发器:**根本不会触发**。零行匹配 = 没有任何一行进入触发器。实测确认。
--   ③ 在动作层调 require_permission:只管应用这一条路,SQL / psql / 别的客户端都不管。
--   ④ ★ 语句级触发器:零行也照样触发(实测),**一条策略都不用动**,
--      所以【读权限不可能被改窄】—— 这是结构上的,不是量出来的。
--      而且它抛的是 `PERMISSION_DENIED|<码>`,`refuseFromCoded` 今天就认得。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★【row_security_active:这一格没有它,六个人会被锁在自己的绩效考核外面】★★★
-- ════════════════════════════════════════════════════════════════════════════
--   45 支库函数写这些表,35 支调 require_permission,**10 支没有**。
--   其中 7 支是 SECURITY DEFINER、属主 postgres —— 它们【绕开 RLS】才跑得通:
--     save_self_assessment · submit_review · acknowledge_review ·
--     open_for_self_assessment · set_review_conclusion  (五支全写 performance_reviews)
--     ensure_task_owner_participant · trg_quote_line_touches_parent (两支触发器)
--   performance_reviews 的策略要 `module.hr.edit` —— 一个普通员工【没有】这项权限。
--   他能填自己的自评,靠的就是"DEFINER 绕开 RLS"这一条。
--   **而触发器不认属主豁免:它对 postgres 一样会触发。**
--   所以一支不设防的语句级触发器,会把六个同事全部锁在自己的绩效考核外面 ——
--   **那比本刀要修的缺陷更坏。**
--
--   闸门就是 `row_security_active(TG_RELID)`:RLS 对当前身份不生效时直接放行。
--   四臂实测(活库,BEGIN…ROLLBACK,containers,Fu Sheng Wong 无 purchasing.edit):
--     ① postgres 直写           rls_active=f  rows=1  不拦 ✓
--     ② DEFINER 函数(被拒者调用) rows=1  不拦 ✓  ← 自评那条路
--     ③ 被拒者直写              抛 PERMISSION_DENIED|module.purchasing.edit ✓
--     ④ 有权者(Tim)            rows=1  不抛,18 行照读 ✓
--   另测:ON DELETE CASCADE **不触发**语句级触发器,级联不受影响。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【覆盖:133 张,不是 61 张 —— 而有一张是【故意】不装的】
-- ════════════════════════════════════════════════════════════════════════════
--   带写策略的表共 134 张。装闸 133 张:
--     · 120 张谓词是单一 has_permission(码),码直接取自策略;
--     · 10 张是双码(assay 两张按进/出料;contracts 系 8 张按买/卖方),
--       闸判「一个都不持」才抛,抛的是【字典序第一个】那个码 —— 他确实一个都没有,
--       所以指名任何一个都是真话;
--     · 3 张 tasks 系,取 can_edit_task() 自己要求的 module.tasks.edit。
--   **notification_reads 故意不装** —— 它的谓词是 `user_id = auth.uid()`,
--   那不是一个权限问题,装了只会为"删别人的已读标记"编造一句权限拒绝。
--
--   ★★【这道闸【只】管得住"模块级的没权限"这一半,不许把话说得更大】★★
--   上面那 13 张(tasks 3 + 双码 10)的策略判的是【行】,不是【人】:
--   can_edit_task 还要求你是这条任务的属主或参与者;contracts 还要看这一行
--   是买方合同还是卖方合同。**语句级触发器看不见行**,所以:
--   一个持 module.tasks.edit、却不在这条任务上的人,**今天仍然拿到零行静默**。
--   那一半仍然由 ALERT-1 的应用层兜着(`.select()` + refuseNothingChanged),
--   **数据库没有接管它** —— 这句话是本段的重点,不是它的免责声明。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 闸本身 ────────────────────────────────────────────────────────────────
-- 【为什么是 SECURITY INVOKER(默认)】row_security_active 必须反映【调用者】。
-- 写成 DEFINER 它就永远看见属主的视角,四臂里的 ③ 会当场失效。
CREATE OR REPLACE FUNCTION public.enforce_write_permission()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    -- RLS 对当前身份不生效(属主 / SECURITY DEFINER / 迁移 / 种子)→ 放行。
    -- 没有这一行,自评那条路会当场断。见抬头。
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;

    -- 持有其中【任何一个】码就放行。单码表的 TG_ARGV 长度为 1。
    FOREACH v_code IN ARRAY TG_ARGV LOOP
        IF public.has_permission(v_code) THEN
            RETURN NULL;
        END IF;
    END LOOP;

    -- 一个都不持。抛 require_permission 用了一年的那个形状 ——
    -- refuseFromCoded 今天就认得它,不需要任何新的映射。
    RAISE EXCEPTION 'PERMISSION_DENIED|%', TG_ARGV[0];
END;
$function$;

COMMENT ON FUNCTION public.enforce_write_permission() IS
 'SILENT-1: statement-level write gate. A refused UPDATE/DELETE matches zero rows and '
 'raises nothing, so the application reports success. This raises PERMISSION_DENIED|<code> '
 'instead. Guarded by row_security_active() so owner/DEFINER paths (the employee''s own '
 'performance-review flow) are unaffected. Changes no policy, so read access cannot narrow.';

-- ── 133 张表的闸 ──────────────────────────────────────────────────────────
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.accounts
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.assay_result_metals
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.inbound.edit', 'module.output.edit');   -- 双码:一个都不持才抛
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.assay_results
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.inbound.edit', 'module.output.edit');   -- 双码:一个都不持才抛
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.bank_import_profiles
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.bank_line_matches
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.bank_statement_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.bank_statements
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.bank_transfers
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.batch_processing_cost_allocations
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.battery_chemistries
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.cash_forecast_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.certificate_types
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.suppliers.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.commission_agreements
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.suppliers.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.company_compliance
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.suppliers.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.company_profile
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.container_documents
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.containers
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_grade_specs
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.customers.edit', 'module.suppliers.edit');   -- 双码:一个都不持才抛
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_insurance_obligations
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.customers.edit', 'module.suppliers.edit');   -- 双码:一个都不持才抛
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_penalty_elements
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.customers.edit', 'module.suppliers.edit');   -- 双码:一个都不持才抛
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_pricing_terms
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.customers.edit', 'module.suppliers.edit');   -- 双码:一个都不持才抛
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_refining_charges
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.customers.edit', 'module.suppliers.edit');   -- 双码:一个都不持才抛
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_settlement_terms
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.customers.edit', 'module.suppliers.edit');   -- 双码:一个都不持才抛
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_volume_commitments
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.customers.edit', 'module.suppliers.edit');   -- 双码:一个都不持才抛
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contracts
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.customers.edit', 'module.suppliers.edit');   -- 双码:一个都不持才抛
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.currencies
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.customer_attachments
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.customers.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.customers
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.customers.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.deep_discharge_judgements
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.departments
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.employees
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.equipment_downtime
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.equipment_maintenance
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.equipment_service_intervals
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.festival_doodles
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.manage_permissions');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.finance_attachments
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.finance_settings
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.forwarder_details
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.forwarder_rate_quotes
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.freight_allocations
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.freight_documents
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.fx_rates
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.handover_item_types
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.home_greetings
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.manage_permissions');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.hr_settings
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.inbound_batch_metals
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.inbound.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.inbound_batch_safety_states
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.inbound.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.inbound_batches
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.inbound.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.inbound_chemistry_certainties
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.inbound_safety_states
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.inbound_source_reasons
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.index_market_calendar
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.pricing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.invoice_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.invoices
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.kpi_cycles
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.kpi_score_rubric
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.laboratories
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.lane_document_requirements
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.lanes
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.leave_accrual_rates
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.leave_grants
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.leave_requests
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.leave_types
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.loss_categories
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.loss_metal_fates
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.maintenance_settings
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.material_attachments
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.material_forms
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.material_kinds
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.material_size_formats
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.material_sources
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.materials
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.medical_claims
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.metal_price_indices
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.pricing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.metal_prices
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.pricing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.operation_type_input_forms
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.operation_type_output_forms
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.operation_type_safety_states
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.operation_types
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.output_batch_metals
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.output.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.output_batch_purposes
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.output_batch_safety_states
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.output.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.output_batches
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.output.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.payment_term_template_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.payment_term_templates
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.payroll_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.payroll_periods
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.performance_reviews
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.period_closes
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.ports
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.pricing_formula_metals
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.pricing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.pricing_formulas
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.pricing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.pricing_settings
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.pricing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.processing_cost_entries
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.processing_inputs
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.processing_outputs
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.processing_run_losses
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.processing_runs
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.processing_settings
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.public_holidays
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.purchase_order_line_retentions
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.purchase_order_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.purchase_order_payment_terms
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.purchase_orders
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.quote_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.sales.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.quotes
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.sales.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.receiving_settings
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.inbound.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.review_cycles
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.review_goals
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.review_rating_scale
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.role_permissions
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.manage_permissions');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.roles
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.manage_permissions');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.sales_order_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.sales.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.sales_orders
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.sales.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.sales_records
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.shift_handover_equipment_refs
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.shift_handover_items
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.shift_handovers
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.shifts
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.stocktake_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.stocktakes.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.stocktakes
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.stocktakes.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.storage_location_allowed_classes
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.inventory.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.storage_locations
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.inventory.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.substances
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.supplier_attachments
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.suppliers.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.supplier_compliance
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.suppliers.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.suppliers
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.suppliers.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.task_nodes
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.tasks.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.task_participants
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.tasks.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.tasks
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.tasks.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.training_records
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.user_roles
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.manage_permissions');
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.waste_classifications
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');

-- ════════════════════════════════════════════════════════════════════════════
-- 【第二件事:供应商状态跳转,把一句中文散文换成一个码】
-- ════════════════════════════════════════════════════════════════════════════
--   旧写法:RAISE EXCEPTION '非法状态跳转: % → %'  —— 一句【散文,不是码】。
--   本地化器接不住散文(它们的契约是"认不出来就原样还回去"),
--   于是英文界面上出现:「Status change failed: 非法状态跳转: active → draft」。
--   这与本刀主体是同一类缺陷:一次拒绝,以界面翻不动的形态到达人面前。
--
--   换成 `INVALID_STATUS_TRANSITION|<from>|<to>` —— 与 PERMISSION_DENIED|<码>
--   逐字同一个形状,六个 *ErrorCodes.ts 的正则本来就照这个形状解析。
--   两个状态都留在里面,所以那句话说得出【是哪两个状态】。
--
--   ☞ 顺手补上 SET search_path:这支函数是全库少数【没有】它的一支。
--     它是触发器,跑在写方的 search_path 上;补上它与本刀无关,
--     但既然改到了这一支,不补就是明知而留。**改了就说,不静默。**
CREATE OR REPLACE FUNCTION public.validate_supplier_status_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  -- INSERT 时不检查
  IF TG_OP = 'INSERT' THEN
    RETURN NEW;
  END IF;

  -- 状态没变,不检查
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- 定义合法跳转
  IF NOT (
    (OLD.status = 'draft'          AND NEW.status IN ('pending_review', 'archived')) OR
    (OLD.status = 'pending_review' AND NEW.status IN ('approved', 'rejected', 'draft')) OR
    (OLD.status = 'rejected'       AND NEW.status IN ('draft', 'archived')) OR
    (OLD.status = 'approved'       AND NEW.status IN ('active', 'suspended', 'archived')) OR
    (OLD.status = 'active'         AND NEW.status IN ('suspended', 'blacklisted', 'archived')) OR
    (OLD.status = 'suspended'      AND NEW.status IN ('active', 'blacklisted', 'archived')) OR
    (OLD.status = 'blacklisted'    AND NEW.status IN ('archived')) OR
    (OLD.status = 'archived'       AND NEW.status IN ('draft'))  -- 归档后可恢复为草稿
  ) THEN
    RAISE EXCEPTION 'INVALID_STATUS_TRANSITION|%|%', OLD.status, NEW.status;
  END IF;

  RETURN NEW;
END;
$function$;

COMMIT;
