\set ON_ERROR_STOP 1
SET lock_timeout = '10s';
BEGIN;
SELECT 'PROOF|A|postgres|' || json_build_object(
  'seven_grants', (SELECT count(*) || ' ' || md5(string_agg(r.code || '/' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code IN ('admin','cco','cfo','cto','finance','gm','warehouse')),
  'user_roles', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.user_roles t),
  'change_log', (SELECT count(*) || ' max ' || max(seq) FROM public.change_log),
  'contracts', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contracts t), 'contract_document_terms', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contract_document_terms t), 'terms_requests', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.terms_requests t),
  'sales_settlements', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.sales_settlements t), 'cod_issues', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.cod_issues t),
  'anon_relations', (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r','v','m','p','f')
                       AND has_table_privilege('anon', c.oid, 'SELECT')),
  'auth_reads_copy_pricing', has_column_privilege('authenticated', 'public.contract_document_terms', 'pricing_terms', 'SELECT'),
  'auth_reads_copy_settlement', has_column_privilege('authenticated', 'public.contract_document_terms', 'settlement_terms', 'SELECT'),
  'auth_reads_copy_code', has_column_privilege('authenticated', 'public.contract_document_terms', 'contract_code', 'SELECT'),
  'anon_any_on_copy', has_table_privilege('anon', 'public.contract_document_terms', 'SELECT,INSERT,UPDATE,DELETE'),
  'auth_reads_tr_snapshot', has_column_privilege('authenticated', 'public.terms_requests', 'snapshot', 'SELECT'),
  'auth_reads_tr_label', has_column_privilege('authenticated', 'public.terms_requests', 'label', 'SELECT'),
  'auth_exec_compute', has_function_privilege('authenticated', 'public.sale_settlement_compute(uuid,uuid,uuid)', 'EXECUTE'),
  'auth_exec_record', has_function_privilege('authenticated', 'public.record_sale_settlement(uuid,uuid,uuid)', 'EXECUTE'),
  'new_functions', (SELECT string_agg(proname, ',' ORDER BY proname) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                      AND proname IN ('change_log_page','change_log_count','dictionary_usage_counts','contract_copy_price_visible','trail_subject_member_map','trail_subject_root_map')),
  'new_views', (SELECT string_agg(relname, ',' ORDER BY relname) FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname IN ('contract_document_terms_masked','terms_requests_masked')),
  'txid_index', (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'idx_change_log_txid'),
  'inlined_constants', (SELECT string_agg(proname || '=' || coalesce(array_to_string(proconfig, ';'), 'none'), ',' ORDER BY proname) FROM pg_proc
                          WHERE pronamespace = 'public'::regnamespace AND proname IN ('trail_subjects','trail_subject_members','trail_log_only_tables','change_log_mask_rules')))::text;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|A|cfo|old|' || (SELECT count(*) || ' rows ' || md5(coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.seq)::text, ''))
     FROM public.change_log_rows(p_by_entry => true, p_limit => 21) x);
RESET ROLE;
-- ── migration body ──

-- ── trail_subjects ──
CREATE OR REPLACE FUNCTION public.trail_subjects()
 RETURNS TABLE(subject text, view_codes text[], root_table text, root_key text, root_rule text, root_columns text[])
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT * FROM (VALUES
        ('purchase_order',    ARRAY['module.purchasing.view'],    'purchase_orders',    'id', 'table', NULL::text[]),
        ('processing_run',    ARRAY['module.processing.view'],    'processing_runs',    'id', 'table', NULL),
        ('role',              ARRAY['action.manage_permissions'], 'roles',              'id', 'table', NULL),
        ('inbound_batch',     ARRAY['module.inbound.view'],       'inbound_batches',    'id', 'table', NULL),
        ('output_batch',      ARRAY['module.output.view'],        'output_batches',     'id', 'table', NULL),
        ('work_order',        ARRAY['module.processing.view'],    'work_orders',        'id', 'table', NULL),
        ('stocktake',         ARRAY['module.stocktakes.view'],    'stocktakes',         'id', 'table', NULL),
        ('equipment',         ARRAY['module.processing.view'],    'fixed_assets',       'id', 'page',  NULL),
        ('shift_handover',    ARRAY['module.processing.view'],    'shift_handovers',    'id', 'table', NULL),
        ('warehouse_request', ARRAY['module.inventory.view', 'module.finance.view'], 'warehouse_requests', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-2
        ('quote',             ARRAY['module.sales.view'],         'quotes',             'id', 'table', NULL),
        ('sales_order',       ARRAY['module.sales.view'],         'sales_orders',       'id', 'table', NULL),
        ('shipment',          ARRAY['module.sales.view', 'action.ship_goods'], 'shipments', 'id', 'table', NULL),
        ('customer',          ARRAY['module.customers.view'],     'customers',          'id', 'table', NULL),
        ('commission_agreement', ARRAY['module.suppliers.view'],  'commission_agreements', 'id', 'table', NULL),
        ('supplier',          ARRAY['module.suppliers.view'],     'suppliers',          'id', 'table', NULL),
        ('container',         ARRAY['module.logistics.view'],     'containers',         'id', 'table', NULL),
        ('forwarder',         ARRAY['module.logistics.view'],     'suppliers',          'id', 'page',  NULL),
        ('lane',              ARRAY['module.logistics.view'],     'lanes',              'id', 'table', NULL),
        ('port',              ARRAY['module.logistics.view'],     'ports',              'id', 'table', NULL),
        ('company_licence',   ARRAY['module.suppliers.view'],     'company_compliance', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-3
        ('material',          ARRAY['module.materials.view'],     'materials',          'id', 'table', NULL),
        ('storage_location',  ARRAY['module.inventory.view'],     'storage_locations',  'id', 'table', NULL),
        ('metal_price',       ARRAY['action.metal_prices'],       'metal_prices',       'id', 'table', NULL),
        ('pricing_formula',   ARRAY['module.pricing.view'],       'pricing_formulas',   'id', 'table', NULL),
        ('task',              ARRAY['module.tasks.view'],         'tasks',              'id', 'table', NULL),
        ('processing_settings', ARRAY['module.processing.view'],  'processing_settings', 'id', 'table',
            ARRAY['wo_input_overrun_pct', 'wo_output_shortfall_pct']),
        ('pricing_settings',  ARRAY['module.pricing.view'],       'pricing_settings',   'id', 'table',
            ARRAY['metal_price_change_warn_pct']),
        ('receiving_settings', ARRAY['module.inbound.view'],      'receiving_settings', 'id', 'table',
            ARRAY['grn_short_pct', 'grn_over_pct', 'grn_assay_tolerance_pct']),
        -- AUDIT-TRAIL-1c-1
        ('journal_entry',     ARRAY['module.finance.view'],       'journal_entries',    'id', 'table', NULL),
        ('invoice',           ARRAY['module.finance.view'],       'invoices',           'id', 'table', NULL),
        ('credit_note',       ARRAY['module.finance.view'],       'credit_notes',       'id', 'table', NULL),
        ('payment',           ARRAY['module.finance.view'],       'payments',           'id', 'table', NULL),
        ('payment_request',   ARRAY['module.finance.view'],       'payment_requests',   'id', 'table', NULL),
        ('expense',           ARRAY['module.finance.view'],       'expenses',           'id', 'table', NULL),
        ('payable',           ARRAY['module.finance.view'],       'inbound_batches',    'id', 'page',
            ARRAY['supplier_id', 'purchase_order_id', 'quantity', 'unit', 'unit_price', 'pricing_status', 'arrival_date',
                  'deleted_at', 'deleted_by', 'delete_reason']),
        -- AUDIT-TRAIL-1c-2
        ('sale',              ARRAY['module.finance.view'],       'sales_records',      'id', 'table', NULL),
        ('freight',           ARRAY['module.finance.view'],       'freight_documents',  'id', 'table', NULL),
        ('fixed_asset',       ARRAY['module.finance.view'],       'fixed_assets',       'id', 'table', NULL),
        ('bank_statement',    ARRAY['module.finance.view'],       'bank_statements',    'id', 'table', NULL),
        ('gst_period',        ARRAY['module.finance.view'],       'gst_periods',        'id', 'table', NULL),
        ('fx_rate',           ARRAY['module.finance.view'],       'fx_rates',           'id', 'table', NULL),
        ('management_pack',   ARRAY['module.finance.view'],       'management_packs',   'id', 'table', NULL),
        ('contract',          ARRAY['module.suppliers.view'],     'contracts',          'id', 'table', NULL),
        -- AUDIT-TRAIL-1c-3
        ('finance_lock',      ARRAY['module.finance.view'],       'finance_settings',   'id', 'table', ARRAY['locked_before']),
        ('finance_gst',       ARRAY['module.finance.view'],       'finance_settings',   'id', 'table',
            ARRAY['gst_registered', 'gst_registration_no']),
        ('company_profile',   ARRAY['module.finance.view'],       'company_profile',    'id', 'table', NULL),
        ('year_close',        ARRAY['module.finance.view'],       'year_closes',        'id', 'table', NULL),
        ('journal_request',   ARRAY['module.finance.view'],       'journal_requests',   'id', 'table', NULL),
        ('expense_claim',     ARRAY['module.finance.view'],       'expense_claims',     'id', 'table', NULL),
        ('my_expense_claim',  ARRAY[]::text[],                    'expense_claims',     'id', 'table', NULL),
        ('bank_transfer',     ARRAY['module.finance.view'],       'bank_transfers',     'id', 'table', NULL),
        ('wht_remittance',    ARRAY['module.finance.view'],       'wht_remittances',    'id', 'table', NULL),
        ('cash_forecast',     ARRAY['module.finance.view'],       'cash_forecasts',     'id', 'table', NULL),
        ('cash_forecast_line', ARRAY['module.finance.view'],      'cash_forecast_lines', 'id', 'table', NULL),
        ('bank_import_profile', ARRAY['module.finance.view'],     'bank_import_profiles', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1d-1
        ('account',           ARRAY['action.manage_permissions'], 'auth.users',         'id', 'table', NULL),
        ('approval_policy',   ARRAY['action.manage_permissions'], 'finance_settings',   'id', 'table',
            ARRAY['approvals_enabled', 'approval_threshold_base', 'approval_level1_role_code', 'approval_level2_role_code']),
        ('employee',          ARRAY['module.hr.view'],            'employees',          'id', 'table', NULL),
        ('department',        ARRAY['module.hr.view'],            'departments',        'id', 'table', NULL),
        ('training_record',   ARRAY['module.hr.view'],            'training_records',   'id', 'table', NULL),
        ('import_batch',      ARRAY['action.bulk_import'],        'import_batches',     'id', 'table', NULL),
        ('dictionary_substances',          ARRAY['module.materials.view'], 'substances',             'code', 'collection', NULL),
        ('dictionary_battery_chemistries', ARRAY['module.materials.view'], 'battery_chemistries',    'code', 'collection', NULL),
        ('dictionary_material_kinds',      ARRAY['module.materials.view'], 'material_kinds',         'code', 'collection', NULL),
        ('dictionary_inbound_safety_states', ARRAY['module.materials.view'], 'inbound_safety_states', 'code', 'collection', NULL),
        ('dictionary_laboratories',        ARRAY['module.inbound.view'],   'laboratories',           'code', 'collection', NULL),
        ('dictionary_inbound_source_reasons', ARRAY['module.inbound.view'], 'inbound_source_reasons', 'code', 'collection', NULL),
        -- MES-3a(2026-10-06,MES-3a Step 0 Q4 · Q12):NEA 废物类别字典 —— 与其余六本同一个形状(清单块,/settings/dictionaries)
        ('dictionary_nea_waste_categories', ARRAY['module.materials.view'], 'nea_waste_categories', 'code', 'collection', NULL),
        -- MES-3b(2026-10-07):危险品 UN 编号字典(module.materials.view)· 标签模板字典(module.inventory.view)
        ('dictionary_dangerous_goods_codes', ARRAY['module.materials.view'], 'dangerous_goods_codes', 'code', 'collection', NULL),
        ('dictionary_label_templates',      ARRAY['module.inventory.view'], 'label_templates',       'code', 'collection', NULL),
        -- MES-4a(2026-10-07,MES-4a Step 0 Q33):一道工序 —— 它的参数与指标、挂着的机器、配方与每一版、容差(根行自己那几列);
        --   页面 /operation/operation-types/[code],门 module.processing.view;根键 code(成员按 operation_type_code 挂在它下面)。
        --   异常事件种类字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries)。
        ('operation_type',    ARRAY['module.processing.view'],    'operation_types',    'code', 'table', NULL),
        ('dictionary_processing_event_types', ARRAY['module.processing.view'], 'processing_event_types', 'code', 'collection', NULL),
        --   班次字典 —— MES-4a 把它放进 /settings/dictionaries(新的"时刻"字段:V6 · V7 的去处),于是它也有一段清单块的记录。
        ('dictionary_shifts', ARRAY['module.processing.view'], 'shifts', 'code', 'collection', NULL),
        -- MES-4b(2026-10-07,MES-4b Step 0 Q3 · Q21):电芯结构字典与交叉污染流字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries)。
        ('dictionary_cell_constructions', ARRAY['module.processing.view'], 'cell_constructions', 'code', 'collection', NULL),
        ('dictionary_contamination_streams', ARRAY['module.processing.view'], 'contamination_streams', 'code', 'collection', NULL),
        -- MES-7a-1(2026-10-15,MES-7a Step 0 Q20):停机原因字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries)。
        --   【不是一个新的记录主语】一段停机的原因与来源照旧在 equipment 主语下说(停机是那一页的成员);这一行只是字典那一段的记录。
        ('dictionary_downtime_causes', ARRAY['module.processing.view'], 'downtime_causes', 'code', 'collection', NULL),
        -- MES-6a-2(2026-10-10,MES-6a Step 0 Q3 · Q39):化验指标字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries;读与那一节同一个码)。
        ('dictionary_assay_indicators', ARRAY['module.materials.view'], 'assay_indicators', 'code', 'collection', NULL),
        -- AUDIT-TRAIL-1d-2
        ('leave_request',     ARRAY['module.hr.view'],            'leave_requests',     'id', 'table', NULL),
        ('my_leave_request',  ARRAY[]::text[],                    'leave_requests',     'id', 'table', NULL),
        ('leave_grant',       ARRAY['module.hr.view'],            'leave_grants',       'id', 'table', NULL),
        ('leave_types',       ARRAY['module.hr.view'],            'leave_types',        'code', 'collection', NULL),
        ('public_holidays',   ARRAY['module.hr.view'],            'public_holidays',    'id', 'collection', NULL),
        ('medical_claim',     ARRAY['module.hr.view'],            'medical_claims',     'id', 'table', NULL),
        ('my_medical_claim',  ARRAY[]::text[],                    'medical_claims',     'id', 'table', NULL),
        ('overtime_batch',    ARRAY['module.hr.view', 'action.overtime_enter', 'action.overtime_approve'], 'overtime_batches', 'id', 'table', NULL),
        ('attendance_period', ARRAY['module.hr.view'],            'attendance_periods', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1d-3
        ('payroll_period',      ARRAY['module.hr.view'],          'payroll_periods',     'id', 'table', NULL),
        ('performance_review',  ARRAY['module.hr.view'],          'performance_reviews', 'id', 'table', NULL),
        ('my_review',           ARRAY[]::text[],                  'performance_reviews', 'id', 'gate:reviewer', NULL),
        ('review_cycle',        ARRAY['module.hr.view'],          'review_cycles',       'id', 'table', NULL),
        ('review_rating_scale', ARRAY['module.hr.view'],          'review_rating_scale', 'code', 'collection', NULL),
        ('kpi_entry',           ARRAY['module.hr.view'],          'kpi_entries',         'id', 'table', NULL),
        -- MES-1
        ('device',              ARRAY['module.processing.view'],  'devices',             'id', 'table', NULL),
        ('ingest_settings',     ARRAY['module.processing.view'],  'ingest_settings',     'id', 'table', NULL),
        -- MES-2(2026-10-06,MES-2 Step 0 Q33):地磅单 —— 收货或物流查看码任一(与表的读策略逐字同一对,Q22)
        ('weighbridge_ticket',  ARRAY['module.inbound.view', 'module.logistics.view'], 'weighbridge_tickets', 'id', 'table', NULL),
        -- MES-5a-2(2026-10-08,MES-5a Step 0 Q31):一张电费单的分摊(/finance/electricity/[id],财务查看码)· 分摊的设定(V25,单行设置作根)
        ('electricity_allocation', ARRAY['module.finance.view'],  'electricity_allocations', 'id', 'table', NULL),
        ('electricity_settings',   ARRAY['module.finance.view'],  'electricity_settings',    'id', 'table', NULL),
        -- MES-5b-3(2026-10-09,MES-5b Step 0 Q32 · Q35):一份配料计划(/operation/blending/[id],加工查看码 —— 与表的读策略同一个)
        ('blending_plan',          ARRAY['module.processing.view'], 'blending_plans',        'id', 'table', NULL),
        -- MES-6a-1(2026-10-09,MES-6a Step 0 Q39):一份样品 · 一件化验争议(质量查看码 —— 页面的门;行再过一次它自己那张表的读规则)·
        --   质量的设定(V16,单行设置作根)
        ('sample',                 ARRAY['module.quality.view'],   'samples',               'id', 'table', NULL),
        ('assay_dispute',          ARRAY['module.quality.view'],   'assay_disputes',        'id', 'table', NULL),
        ('quality_settings',       ARRAY['module.quality.view'],   'quality_settings',      'id', 'table', NULL),
        -- MES-6b-1(2026-10-15,MES-6b Step 0 Q39):一张不合格报告(质量查看码 —— 页面的门;行再过一次它自己那张表的读规则)
        ('ncr',                    ARRAY['module.quality.view'],   'nonconformance_reports', 'id', 'table', NULL),
        -- MES-6b-2(2026-10-15,MES-6b Step 0 Q38 · Q39):一张分析证书(/quality/coa/[id];产出查看码 —— 与证书表的读策略同一个,Q30)
        ('coa',                    ARRAY['module.output.view'],    'certificates_of_analysis', 'id', 'table', NULL),
        -- MES-7b-1(2026-10-16,MES-7b Step 0 Q19):一件事故(安全查看码 —— 页面的门;行再过一次它自己那张表的读规则)·
        --   安全的设定(V19,单行设置作根)· 事故种类字典(清单块,/settings/dictionaries)
        ('incident',               ARRAY['module.safety.view'],    'incidents',             'id', 'table', NULL),
        ('safety_settings',        ARRAY['module.safety.view'],    'safety_settings',       'id', 'table', NULL),
        ('dictionary_incident_kinds', ARRAY['module.safety.view'], 'incident_kinds',        'code', 'collection', NULL),
        -- MES-7b-2(2026-10-16,MES-7b Step 0 Q19):一次巡检 · 一张巡检清单(安全查看码 —— 页面的门;行再过一次它自己那张表的读规则)·
        --   监测参数字典(清单块,/settings/dictionaries)· 环境监测结果(只有清单页,整张表一条记录)
        ('inspection_run',         ARRAY['module.safety.view'],    'inspection_runs',       'id', 'table', NULL),
        ('inspection_template',    ARRAY['module.safety.view'],    'inspection_templates',  'id', 'table', NULL),
        ('dictionary_environmental_parameters', ARRAY['module.safety.view'], 'environmental_parameters', 'code', 'collection', NULL),
        ('safety_environment',     ARRAY['module.safety.view'],    'environmental_results', 'id', 'collection', NULL),
        -- MES-8a(2026-10-16,MES-8 Step 0 Q22):供应商评审(只有评分卡页,整张表一条记录 —— 'collection';每一家的评审也出现在那家供应商下)·
        --   供应商评分的设定(V23 / V24,单行设置作根)· 一份供应商对账单(财务查看码;它的签发档住在这里)
        ('supplier_scorecard_review', ARRAY['module.suppliers.view'], 'supplier_scorecard_reviews', 'id', 'collection', NULL),
        ('supplier_score_settings', ARRAY['module.suppliers.view'], 'supplier_score_settings', 'id', 'table', NULL),
        ('supplier_statement',     ARRAY['module.finance.view'],   'supplier_statements',   'id', 'table', NULL),
        -- MES-8b-1(2026-10-17,MES-8 Step 0 Q22):一份合规包(合规查看码;它的签发档住在这里)· 合规包的设定(V26 / V27,单行设置作根)
        ('compliance_pack',        ARRAY['module.compliance.view'], 'compliance_packs',     'id', 'table', NULL),
        ('compliance_settings',    ARRAY['module.compliance.view'], 'compliance_settings',  'id', 'table', NULL)
    ) AS s(subject, view_codes, root_table, root_key, root_rule, root_columns);
$function$;

-- ── trail_subject_members ──
CREATE OR REPLACE FUNCTION public.trail_subject_members()
 RETURNS TABLE(subject text, ord integer, table_name text, parent_table text, fk_column text, match jsonb, hop text, shown boolean, home boolean)
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT * FROM (VALUES
        -- 采购单:明细行 · 付款计划 · 保留金 · 条款承诺 · 签发 · 合同条款 · 审批 · 修改史(Tim 的 AT-1a 范围)
        ('purchase_order', 1, 'purchase_order_lines',           'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 2, 'purchase_order_payment_terms',   'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 3, 'purchase_order_line_retentions', 'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 4, 'pricing_term_commitments',       'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 5, 'po_issues',                      'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 6, 'contract_document_terms',        'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 7, 'approval_log',                   'purchase_orders',      'subject_id',             '{"subject_type": "purchase_order"}'::jsonb, 'down', true, true),
        ('purchase_order', 8, 'purchase_order_history',         'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        -- 加工单:投入 · 产出 · 成本条目及其修改史 · 成本分摊 · 损耗;1b-1 加:回滚申请及其审批(Q12)
        ('processing_run', 1, 'processing_inputs',                 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 2, 'processing_outputs',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 3, 'processing_cost_entries',           'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 4, 'processing_cost_entry_history',     'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 5, 'batch_processing_cost_allocations', 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 6, 'processing_run_losses',             'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 7, 'warehouse_requests',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, false),
        ('processing_run', 8, 'approval_log',                      'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        -- 角色:授权(加上 / 拿掉);AUDIT-TRAIL-1d-1 加:授给了谁(Q22 —— 家在账号那一边:授出去的是那个账号)
        ('role', 1, 'role_permissions', 'roles', 'role_id', '{}'::jsonb, 'down', true, true),
        ('role', 2, 'user_roles',       'roles', 'role_id', '{}'::jsonb, 'down', true, false),

        -- ── 进料批次(1b-1)────────────────────────────────────────────────────────────────────────────
        -- 批次自己的:金属含量 · 化验与化验的金属 · 安全状态 · 价格 · 收货定价申请与它的审批 · 预付款核销 · 条款承诺 ·
        --   库存流水 · 盘点行与盘点的每一次清点 · 加工投入 · 成本分摊 · 销毁证书与签发 · 仓库申请(注销、证书作废)与它的审批 ·
        --   运费分摊 · 付款核销 · 财务附件
        ('inbound_batch',  1, 'inbound_batch_metals',              'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  2, 'assay_results',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  3, 'assay_result_metals',               'assay_results',               'assay_result_id',  '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  4, 'inbound_batch_safety_states',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  5, 'price_history',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  6, 'receipt_price_requests',            'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  7, 'approval_log',                      'receipt_price_requests',      'subject_id',       '{"subject_type": "receipt_price_request"}'::jsonb, 'down', true, true),
        ('inbound_batch',  8, 'prepayment_applications',           'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  9, 'pricing_term_commitments',          'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 10, 'pricing_term_commitment_metals',    'pricing_term_commitments',    'commitment_id',    '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 11, 'inventory_movements',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 12, 'stocktake_lines',                   'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 13, 'stocktake_counts',                  'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 14, 'processing_inputs',                 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 15, 'batch_processing_cost_allocations', 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 16, 'certificates_of_destruction',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 17, 'cod_issues',                        'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 18, 'warehouse_requests',                'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 19, 'warehouse_requests',                'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 20, 'approval_log',                      'warehouse_requests',          'subject_id',       '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch', 21, 'freight_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 22, 'payment_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 23, 'finance_attachments',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4),只取碰到这个批次的那些事:
        --   它收货的采购单 → 那张单的审批与修改史(旧 approval / po_change 两支)
        ('inbound_batch', 24, 'purchase_orders',                   'inbound_batches',             'purchase_order_id', '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 25, 'approval_log',                      'purchase_orders',             'subject_id',        '{"subject_type": "purchase_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 26, 'purchase_order_history',            'purchase_orders',             'purchase_order_id', '{}'::jsonb, 'down', true,  false),
        --   消耗它的加工单 → 那张单的成本修改史、成本条目(垫脚石)、工单(垫脚石)→ 工单的审批与修改史
        ('inbound_batch', 27, 'processing_runs',                   'processing_inputs',           'run_id',            '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 28, 'processing_cost_entry_history',     'processing_runs',             'run_id',            '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 29, 'processing_cost_entries',           'processing_runs',             'run_id',            '{}'::jsonb, 'down', false, false),
        ('inbound_batch', 30, 'work_orders',                       'processing_runs',             'work_order_id',     '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 31, 'approval_log',                      'work_orders',                 'subject_id',        '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 32, 'work_order_history',                'work_orders',                 'work_order_id',     '{}'::jsonb, 'down', true,  false),
        --   盘点过它的那一次盘点(垫脚石)→ 那次盘点过账的分录
        ('inbound_batch', 33, 'stocktakes',                        'stocktake_lines',             'stocktake_id',      '{}'::jsonb, 'up',  false, false),
        --   分录:直接挂在批次上的(计价、注销)· 预付款核销的 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('inbound_batch', 34, 'journal_entries',                   'inbound_batches',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 35, 'journal_entries',                   'prepayment_applications',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 36, 'journal_entries',                   'processing_cost_entries',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 37, 'journal_entries',                   'processing_runs',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 38, 'journal_entries',                   'stocktakes',                  'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 39, 'journal_entries',                   'journal_entries',             'reversed_by',       '{}'::jsonb, 'up',  true,  false),

        -- ── 产出批次(1b-1)────────────────────────────────────────────────────────────────────────────
        ('output_batch',  1, 'output_batch_metals',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  2, 'assay_results',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  3, 'assay_result_metals',               'assay_results',      'assay_result_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  4, 'output_batch_safety_states',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  5, 'inventory_movements',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  6, 'processing_outputs',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  7, 'processing_inputs',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  8, 'stocktake_lines',                   'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  9, 'stocktake_counts',                  'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 10, 'warehouse_requests',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 11, 'approval_log',                      'warehouse_requests', 'subject_id',      '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch', 12, 'sales_records',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 13, 'sales_record_movements',            'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 14, 'sales_attribution_log',             'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 15, 'invoice_lines',                     'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 16, 'payment_allocations',               'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 17, 'sales_order_reservations',          'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 18, 'shipment_lines',                    'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 19, 'traceability_report_issues',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 20, 'sales_settlements',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4):产出它 / 消耗它的加工单 → 成本修改史、成本条目(垫脚石)、工单 → 审批与修改史;
        --   盘点过它的盘点(垫脚石);它的销售对应的订单行(垫脚石)→ 那一行的订单修改史(旧 so_change 一支)
        ('output_batch', 21, 'processing_runs',                   'processing_outputs', 'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 22, 'processing_runs',                   'processing_inputs',  'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 23, 'processing_cost_entry_history',     'processing_runs',    'run_id',              '{}'::jsonb, 'down', true,  false),
        ('output_batch', 24, 'processing_cost_entries',           'processing_runs',    'run_id',              '{}'::jsonb, 'down', false, false),
        ('output_batch', 25, 'work_orders',                       'processing_runs',    'work_order_id',       '{}'::jsonb, 'up',  false, false),
        ('output_batch', 26, 'approval_log',                      'work_orders',        'subject_id',          '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('output_batch', 27, 'work_order_history',                'work_orders',        'work_order_id',       '{}'::jsonb, 'down', true,  false),
        ('output_batch', 28, 'stocktakes',                        'stocktake_lines',    'stocktake_id',        '{}'::jsonb, 'up',  false, false),
        ('output_batch', 29, 'sales_order_lines',                 'sales_records',      'sales_order_line_id', '{}'::jsonb, 'up',  false, false),
        ('output_batch', 30, 'sales_order_history',               'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true,  false),
        --   分录:注销(直接挂在批次上)· 销售与发货的成本 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('output_batch', 31, 'journal_entries',                   'output_batches',     'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 32, 'journal_entries',                   'sales_records',      'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 33, 'journal_entries',                   'processing_cost_entries', 'source_id',      '{}'::jsonb, 'down', true,  false),
        ('output_batch', 34, 'journal_entries',                   'processing_runs',    'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 35, 'journal_entries',                   'stocktakes',         'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 36, 'journal_entries',                   'journal_entries',    'reversed_by',         '{}'::jsonb, 'up',  true,  false),

        -- ── 工单(1b-1):明细 · 预期产出 · 修改史 · 放行审批 ─────────────────────────────────────────────
        ('work_order', 1, 'work_order_lines',            'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 2, 'work_order_expected_outputs', 'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 3, 'work_order_history',          'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 4, 'approval_log',                'work_orders', 'subject_id',    '{"subject_type": "work_order"}'::jsonb, 'down', true, true),

        -- ── 盘点(1b-1):盘点行 · 每一次清点 · 过账审批 · 过账分录(财务读)─────────────────────────────────
        ('stocktake', 1, 'stocktake_lines',  'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 2, 'stocktake_counts', 'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 3, 'approval_log',     'stocktakes', 'subject_id',   '{"subject_type": "stocktake"}'::jsonb, 'down', true, true),
        ('stocktake', 4, 'journal_entries',  'stocktakes', 'source_id',    '{"source_type": "stocktake"}'::jsonb, 'down', true, false),

        -- ── 设备(1b-1,Q22):保养维修 · 停机 · 保养周期 · 交接班里提到的那次停机 ────────────────────────────
        ('equipment', 1, 'equipment_maintenance',         'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 2, 'equipment_downtime',            'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 3, 'equipment_service_intervals',   'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 4, 'shift_handover_equipment_refs', 'equipment_downtime', 'downtime_id',  '{}'::jsonb, 'down', true, false),

        -- ── 交接班(1b-1,Q23):交接事项 · 提到的停机 ───────────────────────────────────────────────────
        ('shift_handover', 1, 'shift_handover_items',          'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),
        ('shift_handover', 2, 'shift_handover_equipment_refs', 'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),

        -- ── 仓库申请(1b-1,Q12):/inventory 那一块 —— 申请本身与它的审批 ─────────────────────────────────
        ('warehouse_request', 1, 'approval_log', 'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a)· 商务:报价、订单、发货、客户、佣金、供应商、物流 ══
        -- ── 报价:明细(硬删的行从影像里找)· 签发档 · 事件史 ─────────────────────────────────────────
        ('quote', 1, 'quote_lines',  'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 2, 'qt_issues',    'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 3, 'quote_history', 'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        -- ── 销售订单:明细 · 明细的预留 · 发货放行与它的明细、审批 · 签发档 · 事件史 · 合同条款 ──────────────
        --   ★ 预留、发货单明细、订单事件史以前挂在产出批次下面(home = false);它们的【家】是这张订单 / 这张发货单,
        --     所以 /settings/change-history 的 Record 一栏从此指向订单 / 发货单(trail_row_record 只沿 home 走)。
        ('sales_order', 1, 'sales_order_lines',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 2, 'sales_order_reservations', 'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true, true),
        ('sales_order', 3, 'shipping_releases',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 4, 'shipping_release_lines',   'shipping_releases',  'release_id',          '{}'::jsonb, 'down', true, true),
        ('sales_order', 5, 'approval_log',             'shipping_releases',  'subject_id',          '{"subject_type": "shipping_release"}'::jsonb, 'down', true, true),
        ('sales_order', 6, 'so_issues',                'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 7, 'sales_order_history',      'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 8, 'contract_document_terms',  'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        -- ── 发货单(M1:销售或发货的人都读得到):明细 · 送货单签发档 ─────────────────────────────────────
        ('shipment', 1, 'shipment_lines',  'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        ('shipment', 2, 'shipment_issues', 'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        -- ── 客户:联系人 · 附件 · 信用史 · 对账单与它的签发档 · 催收与它挂的单据、承诺
        --   (后四张只给财务读 —— 读不了的人那几行是 Restricted,Q4)────────────────────────────────────
        ('customer', 1, 'counterparty_contacts',      'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 2, 'customer_attachments',       'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 3, 'customer_credit_history',    'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 4, 'customer_statements',        'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 5, 'statement_issues',           'customer_statements', 'statement_id', '{}'::jsonb, 'down', true, true),
        ('customer', 6, 'collection_chases',          'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 7, 'collection_chase_documents', 'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        ('customer', 8, 'collection_promises',        'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        -- ── 供应商:合规证书 · 附件 · 联系人 · 状态变动史 · 审批(送审、批准、驳回)────────────────────────
        ('supplier', 1, 'supplier_compliance',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 2, 'supplier_attachments',    'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 3, 'counterparty_contacts',   'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 4, 'supplier_status_history', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 5, 'approval_log',            'suppliers', 'subject_id',  '{"subject_type": "supplier"}'::jsonb, 'down', true, true),
        -- ── 集装箱:里程碑 · 单据清单 ────────────────────────────────────────────────────────────────
        ('container', 1, 'container_milestones', 'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        ('container', 2, 'container_documents',  'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        -- ── 货代(M3):物流属性(一家一行,主键就是 supplier_id)· 按航段的报价 ──────────────────────────────
        ('forwarder', 1, 'forwarder_details',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('forwarder', 2, 'forwarder_rate_quotes', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        -- ── 航段:它的单据清单;港口:从它出发、到它为止的航段(两个外键,两行)──────────────────────────────
        ('lane', 1, 'lane_document_requirements', 'lanes', 'lane_id',             '{}'::jsonb, 'down', true, true),
        ('port', 1, 'lanes',                      'ports', 'origin_port_id',      '{}'::jsonb, 'down', true, false),
        ('port', 2, 'lanes',                      'ports', 'destination_port_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a)· 主数据与工具:物料、库位、金属价格、公式、任务 ══
        -- ── 物料:附件 · 必须化验的金属(复合主键,叶子)───────────────────────────────────────────────
        ('material', 1, 'material_attachments',     'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        ('material', 2, 'material_required_metals', 'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        -- ── 库位:允许存放的废物分类(Q13:保存只改变动的那几条,一次调用 —— save_storage_location)──────────
        ('storage_location', 1, 'storage_location_allowed_classes', 'storage_locations', 'location_id', '{}'::jsonb, 'down', true, true),
        -- ── 公式:应付金属(叶子)· 修改史 · 条款申请(只给持价格码的人读,别人那一行是 Restricted,Q4)· 申请的审批 ────
        ('pricing_formula', 1, 'pricing_formula_metals',  'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 2, 'pricing_formula_history', 'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 3, 'terms_requests',          'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 4, 'approval_log',            'terms_requests',   'subject_id', '{"subject_type": "terms_request"}'::jsonb, 'down', true, true),
        -- ── 任务(Q3:私人任务也是):步骤 · 参与者 · 修改史(三张表的人都是员工 id,M2)─────────────────────
        ('task', 1, 'task_nodes',        'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 2, 'task_participants', 'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 3, 'task_history',      'tasks', 'task_id', '{}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a)· 账上的单据 ══════════════════════════════════
        -- 冲销分录的 source_id 指的是【原分录】(reverse_journal_entry_internal),不是原单据 —— 所以一张单据够到它的冲销,
        --   只走原分录的 reversed_by(往上一跳,M4;批次 ord 39 的同一个做法),绝不按 source_id = 单据 id 去找。
        -- 一张冲销分录的行【不】挂在原分录上(Q33):行(ord 1)排在冲销(ord 2)之前展开,所以只取到根分录自己的行。
        -- ── 分录:行 · 它的冲销(往上)· 它冲的那一张(往下,在冲销分录的页上)· 申请(人工分录 / 冲销)与申请的审批 ──
        ('journal_entry', 1, 'journal_lines',    'journal_entries',  'entry_id',                '{}'::jsonb, 'down', true, true),
        ('journal_entry', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('journal_entry', 3, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'down', true, false),
        ('journal_entry', 4, 'journal_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('journal_entry', 5, 'journal_requests', 'journal_entries',  'target_entry_id',         '{}'::jsonb, 'down', true, false),
        ('journal_entry', 6, 'approval_log',     'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, false),
        -- AUDIT-TRAIL-1c-3:一次折旧的分录带着它记到每一张资产卡上的那一行(/finance/assets 的折旧批次一块读这张分录;
        --   家仍是资产那一页 —— 每一张资产卡自己也有它那一行,Step 0 §a)
        ('journal_entry', 7, 'fixed_asset_depreciation', 'journal_entries', 'journal_entry_id', '{}'::jsonb, 'down', true, false),
        -- ── 发票:行 · 签发档 · 作废 / 贷项申请与它的审批 · 由它开出的贷项通知 · 核销它的收款 · 它的分录与冲销 ──────
        ('invoice', 1, 'invoice_lines',    'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 2, 'invoice_issues',   'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 3, 'invoice_requests', 'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 4, 'approval_log',     'invoice_requests', 'subject_id',              '{"subject_type": "invoice_request"}'::jsonb, 'down', true, true),
        ('invoice', 5, 'credit_notes',     'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 6, 'payment_allocations', 'invoices',      'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 7, 'journal_entries',  'invoices',         'entry_id',                '{}'::jsonb, 'up',   true, false),
        ('invoice', 8, 'journal_entries',  'invoice_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        ('invoice', 9, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        -- ── 贷项通知:行 · 签发档 · 开出它的那张申请与审批 · 它的分录 ──────────────────────────────────────────
        ('credit_note', 1, 'credit_note_lines', 'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 2, 'cn_issues',         'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 3, 'invoice_requests',  'credit_notes',     'result_credit_note_id', '{}'::jsonb, 'down', true, false),
        ('credit_note', 4, 'approval_log',      'invoice_requests', 'subject_id',            '{"subject_type": "invoice_request"}'::jsonb, 'down', true, false),
        ('credit_note', 5, 'journal_entries',   'credit_notes',     'entry_id',              '{}'::jsonb, 'up',   true, false),
        -- ── 收付款:核销行 · 附件 · 冲销它的那一笔(往上)/ 它冲的那一笔(往下,在镜像单上)· 付出它的申请 · 冲它的申请 ·
        --    申请的审批 · 它的分录与冲销 ────────────────────────────────────────────────────────────────────────
        ('payment', 1, 'payment_allocations', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, true),
        ('payment', 2, 'finance_attachments', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 3, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'up',   true, false),
        ('payment', 4, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'down', true, false),
        ('payment', 5, 'payment_requests',    'payments',         'result_payment_id',   '{}'::jsonb, 'down', true, false),
        ('payment', 6, 'payment_requests',    'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 7, 'approval_log',        'payment_requests', 'subject_id',          '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        ('payment', 8, 'journal_entries',     'payments',         'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('payment', 9, 'journal_entries',     'journal_entries',  'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 付款申请(六种:付款 · 付款冲销 · 行内转账 · 转账冲销 · 代扣税缴纳 · 缴纳冲销):审批 · 付出的那一笔 ·
        --    被冲的那一笔(垫脚石:它自己的事不是这张申请的)· 转账 · 缴纳 · 过账的分录与冲销 ──────────────────
        --    ★ 一张"代扣税缴纳"申请没有指向它造出的那一笔缴纳的外键(形状检查让 wht_remittance_id 在这一种上恒为空)——
        --      唯一的路是 申请 → result_journal_entry_id → wht_remittances.journal_entry_id(ord 8)。
        ('payment_request',  1, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, true),
        ('payment_request',  2, 'payments',         'payment_requests', 'result_payment_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  3, 'payments',         'payment_requests', 'payment_id',              '{}'::jsonb, 'up',   false, false),
        ('payment_request',  4, 'bank_transfers',   'payment_requests', 'result_transfer_id',      '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  5, 'bank_transfers',   'payment_requests', 'transfer_id',             '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  6, 'wht_remittances',  'payment_requests', 'wht_remittance_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  7, 'journal_entries',  'payment_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  8, 'wht_remittances',  'journal_entries',  'journal_entry_id',        '{}'::jsonb, 'down', true,  false),
        ('payment_request',  9, 'journal_entries',  'bank_transfers',   'reversal_entry_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request', 10, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true,  false),
        -- ── 费用 / 供应商账单:核销行 · 附件 · 定金冲抵 · 冲销它的那一张(往上)/ 它冲的那一张(往下)· 报销单与它的审批 ·
        --    资本化进资产的那一笔成本 · 它的分录 · 定金冲抵的分录 · 冲销 ────────────────────────────────────────
        ('expense',  1, 'payment_allocations',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  2, 'finance_attachments',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  3, 'prepayment_applications',  'expenses',                'expense_id',          '{}'::jsonb, 'down', true, true),
        ('expense',  4, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('expense',  5, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'down', true, false),
        ('expense',  6, 'expense_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  7, 'approval_log',             'expense_claims',          'subject_id',          '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('expense',  8, 'fixed_asset_cost_entries', 'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  9, 'journal_entries',          'expenses',                'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('expense', 10, 'journal_entries',          'prepayment_applications', 'source_id',           '{}'::jsonb, 'down', true, false),
        ('expense', 11, 'journal_entries',          'journal_entries',         'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- AUDIT-TRAIL-1d-2(Q37):医疗报销付款时建的那张费用单 —— 费用页够得到是哪一张报销单让它生出来的(家仍在报销单那一页)
        ('expense', 12, 'medical_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        -- EXPENSE-MULTILINE-1(Tim 2026-10-20):费用单的行 —— 家在费用单(行没有自己的页面)
        ('expense', 13, 'expense_lines',            'expenses',                'expense_id',          '{}'::jsonb, 'down', true, true),
        -- ── 应付(Q5,M3 · M6):只有钱的那几样 —— 核销 · 运费分摊 · 定金冲抵 · 财务附件 · 价格 · 计价 / 注销 / 定金的分录与冲销 ──
        ('payable', 1, 'payment_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 2, 'freight_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 3, 'prepayment_applications', 'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 4, 'finance_attachments',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 5, 'price_history',           'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 6, 'journal_entries',         'inbound_batches',         'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 7, 'journal_entries',         'prepayment_applications', 'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 8, 'journal_entries',         'journal_entries',         'reversed_by',      '{}'::jsonb, 'up',   true, false),

        -- ══ AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a)· 其余的单据与合同 ══════════════════════════════════
        -- ── 销售(Q14):出库 · 归属客户 · 开票的那一行 · 收款核销 · 附件 · 收入 / 成本分录与它们的冲销 ─────────────────
        --    ★ 销售自己是一个主语的根了 —— /settings/change-history 的 Record 一栏把销售那一行与它的子行归到【这一笔销售】
        --      (以前归到产出批次:产出批次 ord 12 的 home 改成 false,于是从子行往上走到销售就停下)
        ('sale', 1, 'sales_record_movements', 'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 2, 'sales_attribution_log',  'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 3, 'invoice_lines',          'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 4, 'payment_allocations',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 5, 'finance_attachments',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, true),
        ('sale', 6, 'journal_entries',        'sales_records',   'source_id',       '{"source_type": "sale"}'::jsonb, 'down', true, false),
        ('sale', 7, 'journal_entries',        'sales_records',   'cogs_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('sale', 8, 'journal_entries',        'journal_entries', 'reversed_by',     '{}'::jsonb, 'up',   true, false),
        -- ── 运费单:分摊到的批次(家在这里 —— 它是这张单分出去的)· 付它的核销 · 过账分录 · 冲销分录 ───────────────────
        ('freight', 1, 'freight_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, true),
        ('freight', 2, 'payment_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, false),
        ('freight', 3, 'journal_entries',     'freight_documents', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('freight', 4, 'journal_entries',     'freight_documents', 'reversal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('freight', 5, 'journal_entries',     'journal_entries',   'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 资产(财务那一页,Q10):资产卡的修改史 · 成本 · 折旧与折旧基点 · 处置申请与它的审批 · 处置 / 折旧的分录 ·
        --    保养维修、停机、保养间隔(家仍是 equipment —— 加工那一页)─────────────────────────────────────────────
        ('fixed_asset',  1, 'fixed_asset_history',              'fixed_assets',             'fixed_asset_id',      '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  2, 'fixed_asset_cost_entries',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  3, 'fixed_asset_depreciation',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  4, 'fixed_asset_depreciation_anchors', 'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  5, 'asset_disposal_requests',          'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  6, 'approval_log',                     'asset_disposal_requests',  'subject_id',          '{"subject_type": "asset_disposal_request"}'::jsonb, 'down', true, true),
        ('fixed_asset',  7, 'equipment_maintenance',            'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  8, 'equipment_downtime',               'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  9, 'equipment_service_intervals',      'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 10, 'shift_handover_equipment_refs',    'equipment_downtime',       'downtime_id',         '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 11, 'journal_entries',                  'fixed_assets',             'disposal_journal_id', '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 12, 'journal_entries',                  'fixed_asset_depreciation', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 13, 'journal_entries',                  'journal_entries',          'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 对账单:行与每一行的匹配 · 对账记录与它写明的差额 ────────────────────────────────────────────────────
        ('bank_statement', 1, 'bank_statement_lines',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 2, 'bank_line_matches',                  'bank_statement_lines', 'statement_line_id', '{}'::jsonb, 'down', true, true),
        ('bank_statement', 3, 'bank_reconciliations',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 4, 'bank_reconciliation_variance_items', 'bank_reconciliations', 'reconciliation_id', '{}'::jsonb, 'down', true, true),
        -- ── GST 期间:申报那一刻抄下来的每一格 · 申报申请与它的审批。★ Q22:更正期间【不】挂在原期间上(那样更正件之后的
        --    每一次改动都会出现在原件上);更正件自己的记录以"为 GST-… 开的更正"开头,原件页上那一条链接照旧 ──────────────
        ('gst_period', 1, 'gst_return_boxes',    'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 2, 'gst_filing_requests', 'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 3, 'approval_log',        'gst_filing_requests', 'subject_id', '{"subject_type": "gst_filing_request"}'::jsonb, 'down', true, true),
        -- ── 汇率:它的修改史(录入 · 更正 · 撤回 —— 一件事两行:记录开始之后变更记录那一行说,之前修改史那一行说)──────
        ('fx_rate', 1, 'fx_rate_history', 'fx_rates', 'fx_rate_id', '{}'::jsonb, 'down', true, true),
        -- ── 管理包:没有成员(一份新包取代旧包时,旧包自己那几列说"被谁取代";不经 superseded_by 自连 —— 那会把前一份的
        --    整段历史拉到这一份上)
        -- ── 合同:七张条款表 · 它的申请(生效)与申请的审批(没有 pricing.view 的读者那几行是 Restricted,Q21)·
        --    把它挂到采购单 / 销售订单上的那一份快照(家仍在那张订单上)────────────────────────────────────────────
        ('contract',  1, 'contract_grade_specs',           'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  2, 'contract_insurance_obligations', 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  3, 'contract_volume_commitments',    'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  4, 'contract_pricing_terms',         'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  5, 'contract_settlement_terms',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  6, 'contract_refining_charges',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  7, 'contract_penalty_elements',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  8, 'terms_requests',                 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  9, 'approval_log',                   'terms_requests', 'subject_id',  '{"subject_type": "terms_request"}'::jsonb, 'down', true, false),
        ('contract', 10, 'contract_document_terms',        'contracts',      'contract_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a)· 期末、设置与清单页上的记录 ══════════════════════════
        -- ── 锁期(Q25 · Q3 · M7):月结 / 反结的 period_closes 与 finance_settings 之间一个键都没有 —— 整张表属于那一行。
        --    关账在同一笔里写 period_closes 一行、把锁往后挪;反结在同一笔里给那一行盖反结的戳、把锁往回挪 —— 各是一条
        ('finance_lock', 1, 'period_closes', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 年结:结转分录(往上)· 反结的冲销分录(往上)──────────────────────────────────────────────────
        ('year_close', 1, 'journal_entries', 'year_closes', 'closing_journal_id',  '{}'::jsonb, 'up', true, false),
        ('year_close', 2, 'journal_entries', 'year_closes', 'reversal_journal_id', '{}'::jsonb, 'up', true, false),
        -- ── 人工分录 / 冲销申请(Q17):它的审批(家在这里 —— 一张还没批的申请没有分录,它唯一的家是它自己)· 过账的那一张 ──
        ('journal_request', 1, 'approval_log',    'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, true),
        ('journal_request', 2, 'journal_entries', 'journal_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        -- ── 报销单(Q20):审批 · 收据(附件)· 批准时记下的那张费用单(往上)。/me 上报销人自己读同样的几张(M8)──────
        ('expense_claim',    1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, true),
        -- CLAIM-RECEIPTS-1(Tim 2026-10-21,Q13 · 委托书:收据进报销单的审计记录):每一笔的收据取代了整张单的附件那条路
        ('expense_claim',    2, 'expense_claim_receipts', 'expense_claims', 'claim_id', '{}'::jsonb, 'down', true, true),
        ('expense_claim',    3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        ('my_expense_claim', 1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('my_expense_claim', 2, 'expense_claim_receipts', 'expense_claims', 'claim_id', '{}'::jsonb, 'down', true, false),
        ('my_expense_claim', 3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        -- EXPENSE-MULTILINE-1(Tim 2026-10-20):报销单的明细 —— 家在报销单那一块(/finance/claims);/me 上本人读同样的几笔
        ('expense_claim',    4, 'expense_claim_items', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, true),
        ('my_expense_claim', 4, 'expense_claim_items', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, false),
        -- ── 行内转账:过账分录 · 冲销分录(往上)· 付出它 / 冲它的申请(往下,两把外键 —— 港口的先例)与申请的审批 ──
        ('bank_transfer', 1, 'journal_entries',  'bank_transfers',   'journal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 2, 'journal_entries',  'bank_transfers',   'reversal_entry_id',  '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 3, 'payment_requests', 'bank_transfers',   'result_transfer_id', '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 4, 'payment_requests', 'bank_transfers',   'transfer_id',        '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 5, 'approval_log',     'payment_requests', 'subject_id',         '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        -- ── 代扣税缴纳(Q30):它的分录 · 冲销那一张(经原分录的 reversed_by,往上)· 冲它的申请(wht_remittance_id)·
        --    付出它的申请(那种申请没有指向缴纳的外键 —— 只能经分录:payment_requests.result_journal_entry_id,往下)· 审批 ──
        ('wht_remittance', 1, 'journal_entries',  'wht_remittances',  'journal_entry_id',        '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 3, 'payment_requests', 'wht_remittances',  'wht_remittance_id',       '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 4, 'payment_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 5, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a · §d · §e)· 机制、设置与员工 ══════════════════════════════
        -- ── 账号(M9,Q24):授给它的角色(家在这里,Q22)· 它作为附加账号挂在谁身上 · 那张挂接史 · 它是谁的主账号
        --    (employees.user_id —— M10 只取那一列:那名员工别的每一次编辑不是账号的事)──────────────────────────────
        ('account', 1, 'user_roles',               'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 2, 'employee_accounts',        'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 3, 'employee_account_history', 'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 4, 'employees',                'auth.users', 'user_id', '{}'::jsonb, 'down', true, false),
        -- ── 审批方针(M7 · Q25):修改史整张属于那一行设置(两张表之间没有键 —— 锁期 / period_closes 的同一个做法)──────────
        ('approval_policy', 1, 'finance_settings_history', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 员工(Q28):任职履历 · 调薪申请与它的审批(只给 view_pay 的人读,别人那几行是 Restricted)· 培训(家在培训那一页,Q29)·
        --    附加账号与它的挂接史 · 账号的镜像(Q24 · Q21):主账号与附加账号(往上一跳到 auth.users,M9)与授给它们的角色 ——
        --    每一行照它自己的读规则:授权人人读得到,账号事件与挂接史只给 manage_permissions,别人是 Restricted ────────────────
        ('employee', 1, 'employment_history',       'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 2, 'salary_change_requests',   'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 3, 'approval_log',             'salary_change_requests', 'subject_id',  '{"subject_type": "salary_change_request"}'::jsonb, 'down', true, true),
        ('employee', 4, 'training_records',         'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 5, 'employee_accounts',        'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 6, 'employee_account_history', 'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 7, 'auth.users',               'employees',              'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 8, 'auth.users',               'employee_accounts',      'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 9, 'user_roles',               'auth.users',             'user_id',     '{}'::jsonb, 'down', true, false),
        -- ── 部门 · 培训记录 · 导入批次:没有成员。六本字典:M11 集合,没有成员 ──────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a)· 请假与考勤 ══════════════════════════════════════════
        -- ── 请假:消耗账(批准时扣、取消时还 —— 家在这里)· 审批 ─────────────────────────────────────────────
        --    /me 上本人读同样的两张(M8);两张的读规则都只给 hr.view,所以本人看到的是 Restricted(Q4 · Q14)
        ('leave_request',    1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, true),
        ('leave_request',    2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, true),
        ('my_leave_request', 1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, false),
        ('my_leave_request', 2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, false),
        -- ── 医疗报销:审批 · 付它的那张费用单(往上,M4)· 费用的分录 · 核销 · 冲销它的费用单与分录(只给财务,别人 Restricted)──
        ('medical_claim',    1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, true),
        ('medical_claim',    2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('medical_claim',    5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, false),
        ('my_medical_claim', 2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('my_medical_claim', 5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        -- ── 加班:行(删掉的行从 DELETE 的影像里找)· 审批(送审 · 批准 · 退回)──────────────────────────────────
        ('overtime_batch',   1, 'overtime_lines',      'overtime_batches', 'batch_id',          '{}'::jsonb, 'down', true, true),
        ('overtime_batch',   2, 'approval_log',        'overtime_batches', 'subject_id',        '{"subject_type": "overtime_batch"}'::jsonb, 'down', true, true),
        -- ── 考勤:每人一行(开月 · 补新人 · 记录 · 完成时冻住的那几列 —— 完成那一下的整批改动在界面上是一句)──────────
        ('attendance_period', 1, 'attendance_lines',   'attendance_periods', 'period_id',       '{}'::jsonb, 'down', true, true),
        -- ── 假期发放(清单块)· 假别 · 公共假期(M11 集合):没有成员 ──────────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a)· 工资与评审 ══════════════════════════════════════════
        -- ── 工资期:工资行(每次保存删了重插 —— 一次操作里按员工配对,Q11;家在这里)· 过账 / 撤销的申请与它们的审批 ·
        --    这一期的分录(过账 · 发薪 · CPF · 代扣款)按 source_id + source_type = 'payroll' 找 —— 【不】经 journal_entry_id
        --    往上走:撤销过账会把那一列置空(unpost_payroll_period_internal),往上一跳读的是今天的样子,过账与它的冲销会一起丢掉;
        --    source_id 撤不掉。冲销分录自己的 source_id 是原分录(1c-1),所以它经 reversed_by 往上一跳。分录只给财务(别人 Restricted)
        ('payroll_period',     1, 'payroll_lines',    'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     2, 'payroll_requests', 'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     3, 'approval_log',     'payroll_requests',    'subject_id',        '{"subject_type": "payroll_request"}'::jsonb, 'down', true, true),
        ('payroll_period',     4, 'journal_entries',  'payroll_periods',     'source_id',         '{"source_type": "payroll"}'::jsonb, 'down', true, false),
        ('payroll_period',     5, 'journal_entries',  'journal_entries',     'reversed_by',       '{}'::jsonb, 'up',   true, false),
        -- ── 评审:目标(删掉的目标从 DELETE 的影像里找)· 审批(送审 · 批准 · 本人确认;作废不写审批)──────────────────
        --    批准时改的员工那一行与任职履历【不】挂进来(Q7):它们没有指回评审的键,评审那一段按评审自己的几列说出结论
        --    /my-reviews 上审核人读同样的两张(M12);审批那几行的读规则是 hr.view,不持它的审核人看到的是 Restricted(Q5 · Q4)
        ('performance_review', 1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, true),
        ('performance_review', 2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, true),
        ('my_review',          1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, false),
        ('my_review',          2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, false),
        -- ── MES-1:设备 —— 网关钥匙(发放与撤销;哈希被 never 规则遮住)。收件箱 · 传输日志 · 中断不进变更记录(MES-0 Q14),不在这里 ──
        ('device',             1, 'gateway_keys',     'devices',             'gateway_id',        '{}'::jsonb, 'down', true, true),
        -- ── MES-2:设备 —— 校准记录(记 · 作废;Q33)。地磅单 —— 它的称重(毛重 · 皮重 · 更正)、分出去的份、照片(传 · 撤)。
        --    草稿与确认时改过的值不挂进来:它们的读码是加工(查看),不是地磅单的门;确认队列与地磅单页上直接列它们 ──
        ('device',             2, 'instrument_calibrations', 'devices',      'device_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 1, 'weighings',        'weighbridge_tickets', 'ticket_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 2, 'weighbridge_ticket_shares', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 3, 'weighbridge_ticket_photos', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        -- ── MES-3a(2026-10-06,MES-3a Step 0 Q12 · Q10):执照 —— 它每一类 NEA 废物的库存上限(给 · 改 · 拿掉)。
        --    进料批 / 产出批 —— 它进厂那一刻库存上限的判法(一批一行,只追加)。──
        ('company_licence',    1, 'licence_storage_limits', 'company_compliance', 'licence_id',  '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     40, 'receipt_ceiling_checks', 'inbound_batches',    'inbound_batch_id', '{}'::jsonb, 'down', true, true),
        ('output_batch',      37, 'receipt_ceiling_checks', 'output_batches',     'output_batch_id',  '{}'::jsonb, 'down', true, false),
        -- ── MES-3b(2026-10-07,MES-3b Step 0 Q7 · Q27):每一次印标签(印 · 补印与理由)—— 挂在它印的那样东西下面。
        --    一张表挂三个主语,只有一处是家(trail_row_record 沿 home 往上走):进料批那一支,与 receipt_ceiling_checks 同一个选法 ──
        ('inbound_batch',     41, 'label_prints',           'inbound_batches',    'inbound_batch_id',    '{}'::jsonb, 'down', true, true),
        ('output_batch',      38, 'label_prints',           'output_batches',     'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('storage_location',   2, 'label_prints',           'storage_locations',  'storage_location_id', '{}'::jsonb, 'down', true, false),
        -- ── MES-4a(2026-10-07,MES-4a Step 0 Q33):加工单 —— 记下的值、异常事件、结平、表头更正(都只追加,都按 run_id 挂)。
        --    一道工序 —— 它的字段、挂着的机器、配方(按 operation_type_code 挂在根行的 code 下)与配方的每一版(挂在配方下)。──
        ('processing_run',     9, 'processing_run_values',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    10, 'processing_run_events',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    11, 'processing_run_closures',    'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    12, 'processing_run_corrections', 'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('operation_type',     1, 'operation_type_fields',      'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     2, 'operation_type_equipment',   'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     3, 'process_recipes',            'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     4, 'process_recipe_versions',    'process_recipes',  'recipe_id',           '{}'::jsonb, 'down', true, true),
        -- ── MES-4b(2026-10-07,MES-4b Step 0 Q28):交叉污染抽检 —— 挂在它那一炉(家)与它抽的那一批极片下面(receipt_ceiling_checks 的先例:
        --    一张表挂两个主语,只有一处是家)。没抽的那一种没有批次,只出现在加工单上。──
        ('processing_run',    13, 'contamination_checks',       'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('output_batch',      39, 'contamination_checks',       'output_batches',   'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-1(2026-10-08,MES-5a Step 0 Q31):放电 —— 逐模组结果、通道分配、拆去隔离的模组。家在那一炉(结果与分配挂在放电那一炉,
        --    拆分挂在拆分那一炉);也出现在它们说的那一批上,结果还出现在记下它的放电柜上(device_id;今天手工录入不填它)。──
        ('processing_run',    14, 'discharge_module_results',      'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    15, 'discharge_channel_assignments', 'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    16, 'discharge_module_splits',       'processing_runs', 'split_run_id',     '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     42, 'discharge_module_results',      'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     43, 'discharge_module_splits',       'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('output_batch',      40, 'discharge_module_results',      'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('output_batch',      41, 'discharge_module_splits',       'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('device',             3, 'discharge_module_results',      'devices',         'device_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-2(2026-10-08,MES-5a Step 0 Q31):电表读数住在那台电表下;一张电费单分给一炉的那一份住在那张单下,也出现在那一炉上。──
        ('device',             4, 'meter_readings',                'devices',                 'device_id',     '{}'::jsonb, 'down', true, true),
        ('electricity_allocation', 1, 'electricity_allocation_lines', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    17, 'electricity_allocation_lines',  'processing_runs',         'run_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5b-2(2026-10-09,MES-5b Step 0 Q32 · Q34;MES5B1-V37-NOT-ON-OPERATION-TRAIL,Tim):一张电费单的撤回住在那张单下,
        --    也出现在它覆盖过的每一炉上(经那一炉的那一行往上一跳到那张分摊 —— 垫脚石,自己的改动不进来 —— 再往下到撤回)。
        --    一道工序每一种产出形态的预期得率(V37)住在那道工序下(按 operation_type_code 挂在根行的 code 下,与它的字段同形)。──
        ('electricity_allocation', 2, 'electricity_allocation_reversals', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    18, 'electricity_allocations',          'electricity_allocation_lines', 'allocation_id', '{}'::jsonb, 'up',   false, false),
        ('processing_run',    19, 'electricity_allocation_reversals', 'electricity_allocations',      'allocation_id', '{}'::jsonb, 'down', true, false),
        ('operation_type',     5, 'operation_type_output_forms',      'operation_types',              'operation_type_code', '{}'::jsonb, 'down', true, true),
        -- ── MES-5b-3(2026-10-09,MES-5b Step 0 Q32 · Q35):一份配料计划的目标品位与候选批次都住在那份计划下。──
        ('blending_plan',      1, 'blending_plan_targets',            'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        ('blending_plan',      2, 'blending_plan_lines',              'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        -- ── MES-6a-1(2026-10-09,MES-6a Step 0 Q39):一份样品的保管记录住在那份样品下;样品、它的保管记录与化验争议也出现在它们那一批上
        --    (家在样品 / 争议自己那里)。──
        ('sample',             1, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     44, 'samples',                          'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     45, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     46, 'assay_disputes',                   'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      42, 'samples',                          'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      43, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('output_batch',      44, 'assay_disputes',                   'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-6a-2(2026-10-10,MES-6a Step 0 Q39):一份化验的指标(残粉 · 箔纯度 · 粒径)与它的金属行同一个形状 ——
        --    住在那份化验挂着的那一批下(化验没有自己的主语;它的金属行也是这样挂的)。──
        ('inbound_batch',     47, 'assay_result_indicators',          'assay_results',                'assay_result_id',     '{}'::jsonb, 'down', true, true),
        ('output_batch',      45, 'assay_result_indicators',          'assay_results',                'assay_result_id',     '{}'::jsonb, 'down', true, true),
        -- ── MES-6b-1(2026-10-15,MES-6b Step 0 Q39):不合格报告也出现在它那一批上(家在报告自己那里);质量验收限的判定住在产出批下
        --    (判定挂在批次上,没有自己的主语);合同的第八张条款表住在合同下。──
        ('inbound_batch',     48, 'nonconformance_reports',           'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      46, 'nonconformance_reports',           'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      47, 'quality_limit_judgements',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, true),
        ('contract',          11, 'contract_quality_limits',          'contracts',                    'contract_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-6b-2(2026-10-15,MES-6b Step 0 Q38 · Q39):一张分析证书 —— 它的字节档案(家在证书)、作废它的 CFO 申请与那张申请的审批。
        --    证书也出现在两个批次主语下(家在证书自己那里):产出批 —— 它自己的证书、字节、作废申请与审批;进料批 —— 吃过这一批的加工单
        --    做出来的产出批上的证书(垫脚石:加工单 → 它的产出腿 → 那一批产出,只走一层;证书说的"来料化学确定度"正是这一批的事)。──
        ('coa',                1, 'coa_issues',                       'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, true),
        ('coa',                2, 'warehouse_requests',               'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('coa',                3, 'approval_log',                     'warehouse_requests',           'subject_id',          '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch',      48, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      49, 'coa_issues',                       'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('output_batch',      50, 'warehouse_requests',               'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('output_batch',      51, 'approval_log',                     'warehouse_requests',           'subject_id',          '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch',     49, 'processing_outputs',               'processing_runs',              'run_id',              '{}'::jsonb, 'down', false, false),
        ('inbound_batch',     50, 'output_batches',                   'processing_outputs',           'output_batch_id',     '{}'::jsonb, 'up',   false, false),
        ('inbound_batch',     51, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-7a-2(2026-10-16,MES-7a Step 0 Q20):备件出给保养与退回 —— 没有自己的主语(它没有自己的页)。家在设备(经那一条保养记录);
        --    也出现在进料批下(出的是这一批),连同那张分录(借 6800 / 贷 1200,source_type = maintenance_part,财务读)。──
        ('equipment',          5, 'maintenance_part_issues',          'equipment_maintenance',        'maintenance_id',      '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     52, 'maintenance_part_issues',          'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     53, 'journal_entries',                  'maintenance_part_issues',      'source_id',           '{"source_type": "maintenance_part"}'::jsonb, 'down', true, false),
        -- ── MES-7b-1(2026-10-16,MES-7b Step 0 Q12 · Q19):一件事故 —— 之后的事实与批次链接住在这里;交接班的引用住在交接班下(家),
        --    也出现在事故上;来源 incident 的不合格报告也出现在事故上(家在报告自己那里)。批次链接也出现在那一批上(Q19:事故在批次上看得见)。──
        ('incident',           1, 'incident_updates',                 'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, true),
        ('incident',           2, 'incident_batches',                 'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, true),
        ('incident',           3, 'shift_handover_incident_refs',     'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, false),
        ('incident',           4, 'nonconformance_reports',           'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, false),
        ('shift_handover',     3, 'shift_handover_incident_refs',     'shift_handovers',              'handover_id',         '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     54, 'incident_batches',                 'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      52, 'incident_batches',                 'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-7b-2(2026-10-16,MES-7b Step 0 Q19):一次巡检 —— 它的结果、发现与发现的关闭住在这里;引用一条发现的不合格报告也出现在这里
        --    (家在报告自己那里)。一张巡检清单 —— 它的检查项住在这里。──
        ('inspection_run',      1, 'inspection_results',               'inspection_runs',              'run_id',              '{}'::jsonb, 'down', true, true),
        ('inspection_run',      2, 'inspection_findings',              'inspection_runs',              'run_id',              '{}'::jsonb, 'down', true, true),
        ('inspection_run',      3, 'inspection_finding_closures',      'inspection_findings',          'finding_id',          '{}'::jsonb, 'down', true, true),
        ('inspection_run',      4, 'nonconformance_reports',           'inspection_findings',          'inspection_finding_id', '{}'::jsonb, 'down', true, false),
        ('inspection_template', 1, 'inspection_template_items',        'inspection_templates',         'template_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-8a(2026-10-16,MES-8 Step 0 Q22):一份供应商对账单 —— 它的签发档住在这里。一家供应商的评审也出现在它下面
        --    (家在评分卡页那条集合记录里)。──
        ('supplier_statement',  1, 'supplier_statement_issues',        'supplier_statements',          'statement_id',        '{}'::jsonb, 'down', true, true),
        ('supplier',            6, 'supplier_scorecard_reviews',       'suppliers',                    'supplier_id',         '{}'::jsonb, 'down', true, false),
        -- ── MES-9a(2026-10-19,MES-9 Step 0 §6 · Q21):一家供应商的门户账号 —— 开、撤销、匿名化住在这里 ──
        ('supplier',            7, 'supplier_portal_users',            'suppliers',                    'supplier_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-9c(2026-10-20,MES-9 Step 0 §5 · §6 · Q19 · Q21):门户交上来的证书 —— 交、接受、驳回住在这里 ──
        ('supplier',            8, 'portal_certificate_submissions',   'suppliers',                    'supplier_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-8b-1(2026-10-17,MES-8 Step 0 Q22):一份合规包 —— 它的签发档住在这里。──
        ('compliance_pack',     1, 'compliance_pack_issues',           'compliance_packs',             'pack_id',             '{}'::jsonb, 'down', true, true)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- ── trail_log_only_tables ──
CREATE OR REPLACE FUNCTION public.trail_log_only_tables()
 RETURNS TABLE(table_name text, schema_name text, rel_name text, image_columns text[], read_code text)
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT * FROM (VALUES
        ('auth.users', 'auth', 'users', ARRAY['id', 'email', 'created_at', 'banned_until'], 'action.manage_permissions')
    ) AS l(table_name, schema_name, rel_name, image_columns, read_code);
$function$;

-- ── trail_subject_member_map ──
CREATE OR REPLACE FUNCTION public.trail_subject_member_map()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT COALESCE(jsonb_object_agg(g.table_name, g.members), '{}'::jsonb)
      FROM (SELECT tm.table_name, jsonb_agg(to_jsonb(tm) ORDER BY tm.subject, tm.ord) AS members
              FROM trail_subject_members() tm WHERE tm.home GROUP BY tm.table_name) g;
$function$;

-- ── trail_subject_root_map ──
CREATE OR REPLACE FUNCTION public.trail_subject_root_map()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT COALESCE(jsonb_object_agg(g.root_table, g.subjects), '{}'::jsonb)
      FROM (SELECT ts.root_table, jsonb_agg(ts.subject ORDER BY ts.subject) AS subjects
              FROM trail_subjects() ts GROUP BY ts.root_table) g;
$function$;

-- ── trail_pk_columns ──
CREATE OR REPLACE FUNCTION public.trail_pk_columns(p_table text)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- GOLIVE-2(第 13 行):PL/pgSQL 而不是 SQL —— 与 trail_fk_targets 同一个理由(CHAIN-WALK-COST):带 SET 子句的 SQL 函数每调一次都重新规划
    --   这一串目录连接;PL/pgSQL 在一个会话里把计划缓存下来。查询逐字未变。
    RETURN (SELECT array_agg(a.attname::text ORDER BY k.ord)
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
      CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
     WHERE c.relname = p_table AND i.indisprimary);
END;
$function$;

-- ── trail_row_record ──
CREATE OR REPLACE FUNCTION public.trail_row_record(p_table text, p_key jsonb, p_old jsonb, p_new jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_img   jsonb;
    v_cur   record;
    v_table text := p_table;
    v_id    text;
    v_pk    text[];
    m       record;
    f       record;
    v_hops  integer := 0;
    v_lab   jsonb;
    v_dkey  text;
    v_route text;
    v_mode  text;
BEGIN
    IF p_key IS NULL OR to_regclass(format('public.%I', p_table)) IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_cur FROM trail_current_image(p_table, p_key);
    v_img := COALESCE(v_cur.image, '{}'::jsonb) || COALESCE(p_old, '{}'::jsonb) || COALESCE(p_new, '{}'::jsonb);
    v_pk := trail_pk_columns(p_table);
    v_id := CASE WHEN cardinality(v_pk) = 1 THEN p_key ->> v_pk[1] END;

    IF NOT EXISTS (SELECT 1 FROM document_types dt WHERE dt.table_name = p_table)
       AND NOT (trail_subject_root_map() ? p_table) THEN
        -- ② 登记过的子行:沿父键往上走,最多三跳
        --   AUDIT-TRAIL-1c-1(M7):hop = 'all' 的家是那个单行设置表本身 —— 没有外键可走,那一行的键取它唯一那一行的根键
        LOOP
            -- GOLIVE-2(第 13 行):成员表按表名预先分好组的常量(trail_subject_member_map,规划时求一次)—— 每一跳不再扫一遍 402 行;
            --   同一个筛选、同一个排序(subject, ord),答案逐字不变
            SELECT tm.* INTO m FROM jsonb_to_recordset(trail_subject_member_map() -> v_table)
                       AS tm(subject text, ord integer, table_name text, parent_table text, fk_column text, match jsonb, hop text, shown boolean, home boolean)
             WHERE tm.table_name = v_table AND tm.home AND v_img @> tm.match
               AND ((tm.hop = 'down' AND v_img ->> tm.fk_column IS NOT NULL)
                    OR (tm.hop = 'all' AND EXISTS (SELECT 1 FROM trail_subjects() ts
                                                    WHERE ts.subject = tm.subject AND ts.root_table = tm.parent_table)))
             ORDER BY tm.subject, tm.ord LIMIT 1;
            EXIT WHEN NOT FOUND OR v_hops >= 3;
            v_table := m.parent_table;
            IF m.hop = 'all' THEN
                EXECUTE format('SELECT t.%I::text FROM public.%I t LIMIT 1',
                               (SELECT ts.root_key FROM trail_subjects() ts WHERE ts.subject = m.subject), v_table)
                   INTO v_id;
            ELSE
                v_id := v_img ->> m.fk_column;
            END IF;
            v_hops := v_hops + 1;
            SELECT * INTO v_cur FROM trail_current_image(v_table, jsonb_build_object('id', v_id));
            v_img := COALESCE(v_cur.image, '{}'::jsonb);
        END LOOP;
        -- ③ 没走动:找第一列指着单据的外键
        IF v_hops = 0 THEN
            FOR f IN SELECT ft.* FROM trail_fk_targets(p_table) ft
                      WHERE ft.target_table IN (SELECT dt.table_name FROM document_types dt)
                        AND ft.column_name NOT IN ('created_by', 'updated_by') LOOP
                IF v_img ->> f.column_name IS NOT NULL THEN
                    v_table := f.target_table;
                    v_id := v_img ->> f.column_name;
                    EXIT;
                END IF;
            END LOOP;
        END IF;
    END IF;
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('table', v_table, 'id', NULL, 'label', NULL, 'gone', false);
    END IF;
    v_lab := trail_ref_label(v_table, COALESCE((trail_pk_columns(v_table))[1], 'id'), v_id);
    SELECT dt.key, dt.route, dt.link_mode INTO v_dkey, v_route, v_mode FROM document_types dt WHERE dt.table_name = v_table ORDER BY dt.key LIMIT 1;
    IF v_table = 'sales_records' THEN
        v_dkey := 'sale'; v_route := '/finance/receivables'; v_mode := 'detail';
    ELSIF v_table = 'overtime_batches' THEN
        v_dkey := 'overtime_batch'; v_route := '/hr/overtime'; v_mode := 'detail';
    ELSIF v_table = 'performance_reviews' THEN
        v_dkey := 'performance_review'; v_route := '/hr/reviews'; v_mode := 'detail';
    END IF;
    RETURN jsonb_build_object('table', v_table, 'id', v_id,
        'label', v_lab ->> 'label', 'gone', COALESCE((v_lab ->> 'gone')::boolean, false),
        'doc_key', v_dkey, 'route', v_route, 'link_mode', v_mode);
END;
$function$;

-- ── contract_copy_price_visible ──
CREATE OR REPLACE FUNCTION public.contract_copy_price_visible(p_sales_order_id uuid, p_purchase_order_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN p_sales_order_id IS NOT NULL THEN has_permission('data.view_prices')
                WHEN p_purchase_order_id IS NOT NULL THEN has_permission('data.view_purchase_prices')
                ELSE false END;
$function$;

-- ── change_log_mask_rules ──
CREATE OR REPLACE FUNCTION public.change_log_mask_rules()
 RETURNS TABLE(table_name text, column_name text, rule text)
 LANGUAGE sql
 IMMUTABLE
AS $function$
    VALUES
        ('approval_log'::text, 'amount_ccy'::text, 'apr_amount'::text),
        ('gateway_keys', 'key_hash', 'never'),
        ('approval_log', 'amount_base', 'apr_amount'),
        ('approval_log', 'note', 'apr_note'),
        ('company_profile', 'bank_name', 'code:data.view_banking'),
        ('company_profile', 'bank_account_name', 'code:data.view_banking'),
        ('company_profile', 'bank_account_no', 'code:data.view_banking'),
        ('company_profile', 'bank_swift', 'code:data.view_banking'),
        ('company_profile', 'bank_address', 'code:data.view_banking'),
        ('employees', 'work_email', 'code_or_self:data.view_identity:id'),
        ('employees', 'work_phone', 'code_or_self:data.view_identity:id'),
        ('employees', 'identity_no', 'code_or_self:data.view_identity:id'),
        ('employees', 'work_pass_no', 'code_or_self:data.view_identity:id'),
        ('employees', 'monthly_salary', 'code_or_self:data.view_pay:id'),
        ('employees', 'notes', 'code:module.hr.view'),
        ('employees', 'separation_notes', 'code:module.hr.view'),
        ('employment_history', 'old_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('employment_history', 'new_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('inbound_batches', 'unit_price', 'code:data.view_purchase_prices'),
        ('invoice_lines', 'unit_price', 'code:data.view_prices'),
        ('invoice_lines', 'amount_base', 'code:data.view_prices'),
        ('invoice_lines', 'amount_ccy', 'code:data.view_prices'),
        ('invoice_lines', 'tax_base', 'code:data.view_prices'),
        ('invoices', 'subtotal_base', 'code:data.view_prices'),
        ('invoices', 'tax_base', 'code:data.view_prices'),
        ('invoices', 'total_base', 'code:data.view_prices'),
        ('invoices', 'fx_rate', 'code:data.view_prices'),
        ('journal_lines', 'debit', 'pay_journal:data.view_pay'),
        ('journal_lines', 'credit', 'pay_journal:data.view_pay'),
        ('journal_lines', 'amount_ccy', 'pay_journal:data.view_pay'),
        ('journal_requests', 'amount_base', 'jr_amount'),
        ('leave_requests', 'reason', 'code_or_self:data.view_health:employee_id'),
        ('leave_requests', 'certificate_ref', 'code_or_self:data.view_health:employee_id'),
        ('leave_requests', 'exception_reason', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'amount_sgd', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'description', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'decision_notes', 'code_or_self:data.view_health:employee_id'),
        -- MES-7b-1(Q6):事故的受伤细节 —— 抄自 incidents_masked 里那句 CASE(data.view_health,或受伤的那名员工本人)
        ('incidents', 'injured_employee_id', 'code_or_self:data.view_health:injured_employee_id'),
        ('incidents', 'injured_person_name', 'code_or_self:data.view_health:injured_employee_id'),
        ('incidents', 'injury_nature', 'code_or_self:data.view_health:injured_employee_id'),
        ('incidents', 'injury_treatment', 'code_or_self:data.view_health:injured_employee_id'),
        ('incidents', 'days_lost', 'code_or_self:data.view_health:injured_employee_id'),
        ('payment_term_template_lines', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('payroll_lines', 'gross_pay', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'employer_cpf', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'employee_cpf', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'other_deductions', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'net_pay', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_periods', 'gross_total', 'code:data.view_pay'),
        ('payroll_periods', 'employer_cpf_total', 'code:data.view_pay'),
        ('payroll_periods', 'employee_cpf_total', 'code:data.view_pay'),
        ('payroll_periods', 'other_deductions_total', 'code:data.view_pay'),
        ('payroll_periods', 'net_pay_total', 'code:data.view_pay'),
        ('payroll_requests', 'snapshot', 'code:data.view_pay'),
        ('payroll_requests', 'gross_total', 'code:data.view_pay'),
        ('payroll_requests', 'amount_base', 'code:data.view_pay'),
        ('performance_reviews', 'new_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('prepayment_applications', 'amount_base', 'code:data.view_purchase_prices'),
        ('prepayment_applications', 'amount_ccy', 'code:data.view_purchase_prices'),
        ('price_history', 'old_unit_price', 'code:data.view_purchase_prices'),
        ('price_history', 'new_unit_price', 'code:data.view_purchase_prices'),
        ('price_history', 'original_price', 'code:data.view_purchase_prices'),
        ('price_history', 'fx_rate', 'code:data.view_purchase_prices'),
        ('pricing_formula_history', 'old_payable_pct', 'pft3'),
        ('pricing_formula_history', 'new_payable_pct', 'pft3'),
        ('pricing_formula_history', 'old_treatment_charge_usd_per_tonne', 'pft3'),
        ('pricing_formula_history', 'new_treatment_charge_usd_per_tonne', 'pft3'),
        ('pricing_formula_history', 'old_flat_discount_pct', 'pft3'),
        ('pricing_formula_history', 'new_flat_discount_pct', 'pft3'),
        ('pricing_formula_metals', 'payable_pct', 'pft:formula_id'),
        ('pricing_formulas', 'treatment_charge_usd_per_tonne', 'pft:direction'),
        ('pricing_formulas', 'flat_discount_pct', 'pft:direction'),
        ('pricing_term_commitment_metals', 'payable_pct', 'code:data.view_purchase_prices'),
        ('pricing_term_commitments', 'treatment_charge_usd_per_tonne', 'code:data.view_purchase_prices'),
        ('pricing_term_commitments', 'flat_discount_pct', 'code:data.view_purchase_prices'),
        ('processing_cost_entries', 'amount_base', 'code:data.view_prices'),
        ('electricity_allocations', 'bill_amount', 'code:data.view_prices'),
        ('electricity_allocations', 'price_per_kwh', 'code:data.view_prices'),
        ('electricity_allocations', 'allocated_amount', 'code:data.view_prices'),
        ('electricity_allocations', 'overhead_amount', 'code:data.view_prices'),
        ('electricity_allocations', 'relieved_estimate_amount', 'code:data.view_prices'),
        ('electricity_allocation_lines', 'amount', 'code:data.view_prices'),
        ('electricity_allocation_reversals', 'bill_amount', 'code:data.view_prices'),
        ('electricity_allocation_reversals', 'actual_line_amount', 'code:data.view_prices'),
        ('electricity_allocation_reversals', 'restored_estimate_amount', 'code:data.view_prices'),
        ('processing_cost_entry_history', 'old_amount_base', 'code:data.view_prices'),
        ('processing_cost_entry_history', 'new_amount_base', 'code:data.view_prices'),
        ('processing_outputs', 'allocated_cost_base', 'code:data.view_prices'),
        ('processing_outputs', 'unit_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'material_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'process_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'total_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'capitalized_cost_base', 'code:data.view_prices'),
        ('warehouse_requests', 'amount_base', 'code:data.view_prices'),
        ('purchase_order_history', 'old_fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_payment_term', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_payment_term', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'released_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'withheld_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'price_provenance', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'tax_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_payment_terms', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'tax_total_ccy', 'code:data.view_purchase_prices'),
        ('sales_records', 'unit_price', 'code:data.view_prices'),
        ('sales_records', 'fx_rate', 'code:data.view_prices'),
        ('sales_records', 'amount_base', 'code:data.view_prices'),
        ('sales_records', 'price_provenance', 'code:data.view_prices'),
        ('sales_settlements', 'metal_value_usd', 'code:data.view_prices'),
        ('sales_settlements', 'refining_charge_usd', 'code:data.view_prices'),
        ('sales_settlements', 'penalty_usd', 'code:data.view_prices'),
        ('sales_settlements', 'amount_usd', 'code:data.view_prices'),
        ('sales_settlements', 'breakdown', 'code:data.view_prices'),
        ('sales_settlements', 'terms_snapshot', 'code:data.view_prices'),
        ('contract_pricing_terms', 'payable_pct', 'contract_price'),
        ('contract_refining_charges', 'usd_per_tonne_of_metal', 'contract_price'),
        ('contract_penalty_elements', 'usd_per_tonne_per_pct_over', 'contract_price'),
        ('contract_insurance_obligations', 'min_amount', 'contract_price'),
        ('contract_document_terms', 'pricing_terms', 'cdt_price'),
        ('contract_document_terms', 'settlement_terms', 'cdt_price'),
        ('terms_requests', 'snapshot', 'tr_snapshot');
$function$;

-- ── change_log_rule_visible ──
CREATE OR REPLACE FUNCTION public.change_log_rule_visible(p_rule text, p_table text, p_key jsonb, p_old jsonb, p_new jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_part text[] := string_to_array(p_rule, ':');
    v_fid  text;
BEGIN
    IF p_rule = 'never' THEN
        RETURN false;
    ELSIF v_part[1] = 'code' THEN
        RETURN has_permission(v_part[2]);
    ELSIF v_part[1] = 'code_or_self' THEN
        RETURN has_permission(v_part[2])
            OR COALESCE(change_log_field(p_table, p_key, p_old, p_new, v_part[3]) = current_user_employee()::text, false);
    ELSIF v_part[1] = 'pay_journal' THEN
        RETURN has_permission(v_part[2])
            OR COALESCE(change_log_field('journal_entries',
                            jsonb_build_object('id', change_log_field(p_table, p_key, p_old, p_new, 'entry_id')),
                            NULL, NULL, 'source_type') <> 'payroll', false);
    ELSIF p_rule = 'apr_amount' THEN
        RETURN COALESCE(approval_log_amount_visible(change_log_field(p_table, p_key, p_old, p_new, 'subject_type'),
                                                    change_log_field(p_table, p_key, p_old, p_new, 'subject_id')::uuid), false);
    ELSIF p_rule = 'apr_note' THEN
        RETURN COALESCE(approval_log_note_visible(change_log_field(p_table, p_key, p_old, p_new, 'subject_type'),
                                                  change_log_field(p_table, p_key, p_old, p_new, 'subject_id')::uuid), false);
    ELSIF p_rule = 'contract_price' THEN
        RETURN COALESCE(contract_terms_price_visible(change_log_field(p_table, p_key, p_old, p_new, 'contract_id')::uuid), false);
    ELSIF p_rule = 'cdt_price' THEN
        RETURN COALESCE(contract_copy_price_visible(change_log_field(p_table, p_key, p_old, p_new, 'sales_order_id')::uuid,
                                                    change_log_field(p_table, p_key, p_old, p_new, 'purchase_order_id')::uuid), false);
    ELSIF p_rule = 'tr_snapshot' THEN
        IF change_log_field(p_table, p_key, p_old, p_new, 'formula_id') IS NOT NULL THEN
            RETURN pricing_formula_terms_visible(
                change_log_field('pricing_formulas', jsonb_build_object('id', change_log_field(p_table, p_key, p_old, p_new, 'formula_id')),
                                 NULL, NULL, 'direction'));
        END IF;
        RETURN COALESCE(contract_terms_price_visible(change_log_field(p_table, p_key, p_old, p_new, 'contract_id')::uuid), false);
    ELSIF p_rule = 'jr_amount' THEN
        RETURN COALESCE(journal_request_amount_visible(change_log_field(p_table, p_key, p_old, p_new, 'id')::uuid), false);
    ELSIF p_rule = 'pft:direction' THEN
        RETURN pricing_formula_terms_visible(change_log_field(p_table, p_key, p_old, p_new, 'direction'));
    ELSIF p_rule IN ('pft:formula_id', 'pft3') THEN
        v_fid := change_log_field(p_table, p_key, p_old, p_new, 'formula_id');
        IF NOT pricing_formula_terms_visible(
               change_log_field('pricing_formulas', jsonb_build_object('id', v_fid), NULL, NULL, 'direction')) THEN
            RETURN false;
        END IF;
        IF p_rule = 'pft:formula_id' THEN
            RETURN true;
        END IF;
        RETURN pricing_formula_terms_visible(COALESCE(change_log_field(p_table, p_key, p_old, p_new, 'old_direction'), 'both'))
           AND pricing_formula_terms_visible(COALESCE(change_log_field(p_table, p_key, p_old, p_new, 'new_direction'), 'both'));
    END IF;
    RETURN false;
END;
$function$;

-- ── change_log_page ──
CREATE OR REPLACE FUNCTION public.change_log_page(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_table text DEFAULT NULL::text, p_tables text[] DEFAULT NULL::text[], p_record_ids text[] DEFAULT NULL::text[], p_actor uuid DEFAULT NULL::uuid, p_no_session boolean DEFAULT false, p_removed_account boolean DEFAULT false, p_entries integer DEFAULT 21, p_before bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    r        record;
    v_mask   jsonb;
    v_entries integer := LEAST(GREATEST(COALESCE(p_entries, 21), 1), 1001);
    v_txids  bigint[];
    v_mx     bigint[];
    v_vkey   text;
    v_vis    boolean;
    v_cache  jsonb := '{}'::jsonb;
    v_acache jsonb := '{}'::jsonb;
    v_akey   text;
    v_cimg   record;
    v_old    jsonb;
    v_new    jsonb;
    v_rr     boolean;
    v_actor  jsonb;
    v_bt     jsonb;
    v_refs   jsonb;
    v_out    jsonb[] := ARRAY[]::jsonb[];
    v_n      integer;
    v_win    integer;
    v_wrows  bigint;
BEGIN
    PERFORM require_permission('data.view_change_log');

    -- ① 这一次要哪几次操作:按事务里(符合筛选的)最大 seq 倒序 —— 与 change_log_rows 同一个定义,但不再每次把整张表按事务分组:
    --   沿 seq 倒序取一个窗口(主键索引),窗口里每笔事务的最大 seq 就是它在全表里的最大 seq(倒序第一次出现即最大);
    --   窗口里凑不满 p_entries 笔就把窗口放大四倍再取。p_before:窗口从它下面开始,并剔除在它上面还有行的事务(那几笔属于上一页)。
    v_win := v_entries * 16;
    LOOP
        WITH w AS MATERIALIZED (
                    SELECT c.txid, c.seq
                      FROM change_log c
                     WHERE (p_before IS NULL OR c.seq < p_before)
                       AND (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
                       AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
                       AND (p_table IS NULL OR c.table_name = p_table)
                       AND (p_tables IS NULL OR c.table_name = ANY (p_tables))
                       AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = ANY (p_record_ids)))
                       AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
                       AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
                       AND (NOT COALESCE(p_removed_account, false)
                            OR (c.actor_kind = 'user' AND c.actor_employee IS NULL
                                AND NOT EXISTS (SELECT 1 FROM auth.users u2 WHERE u2.id = c.actor_account)))
                     ORDER BY c.seq DESC
                     LIMIT v_win)
        SELECT (SELECT count(*) FROM w), array_agg(g.g_tx ORDER BY g.g_mx DESC), array_agg(g.g_mx ORDER BY g.g_mx DESC)
          INTO v_wrows, v_txids, v_mx FROM (
            SELECT w.txid AS g_tx, max(w.seq) AS g_mx
              FROM w
             GROUP BY w.txid
            HAVING p_before IS NULL OR NOT EXISTS (
                SELECT 1 FROM change_log c3
                 WHERE c3.txid = w.txid AND c3.seq >= p_before
                   AND (p_from IS NULL OR c3.occurred_at >= p_from::timestamptz)
                   AND (p_to IS NULL OR c3.occurred_at < (p_to + 1)::timestamptz)
                   AND (p_table IS NULL OR c3.table_name = p_table)
                   AND (p_tables IS NULL OR c3.table_name = ANY (p_tables))
                   AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c3.row_key) k WHERE k.value = ANY (p_record_ids)))
                   AND (p_actor IS NULL OR c3.actor_account = p_actor OR c3.actor_employee = p_actor)
                   AND (NOT COALESCE(p_no_session, false) OR c3.actor_kind = 'no_session')
                   AND (NOT COALESCE(p_removed_account, false)
                        OR (c3.actor_kind = 'user' AND c3.actor_employee IS NULL
                            AND NOT EXISTS (SELECT 1 FROM auth.users u3 WHERE u3.id = c3.actor_account))))
             ORDER BY max(w.seq) DESC
             LIMIT v_entries) g;
        EXIT WHEN COALESCE(cardinality(v_txids), 0) >= v_entries OR COALESCE(v_wrows, 0) < v_win;
        v_win := v_win * 4;
    END LOOP;
    IF v_txids IS NULL THEN
        RETURN jsonb_build_object('rows', '[]'::jsonb, 'entries', 0, 'next_before', NULL, 'exhausted', true);
    END IF;
    -- ② 那几次操作里符合筛选的每一行 —— 与 change_log_rows(p_by_entry => true)逐字同一套筛选与同一段逐行遮蔽
    FOR r IN
        SELECT c.seq AS c_seq, c.occurred_at AS c_at, c.table_name AS c_table, c.row_key AS c_key,
               c.op AS c_op, c.actor_account AS c_account, u.email::text AS c_email,
               c.actor_employee AS c_employee, e.code AS c_emp_code,
               COALESCE(e.preferred_name, e.legal_name) AS c_emp_name,
               c.actor_kind AS c_kind, c.db_role AS c_role, c.changed_columns AS c_cols,
               c.old AS c_old, c.new AS c_new, c.redacted_at AS c_redacted, c.txid AS c_tx
          FROM change_log c
          LEFT JOIN auth.users u ON u.id = c.actor_account
          LEFT JOIN employees e ON e.id = c.actor_employee
         WHERE c.txid = ANY (v_txids)
           AND (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
           AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
           AND (p_table IS NULL OR c.table_name = p_table)
           AND (p_tables IS NULL OR c.table_name = ANY (p_tables))
           AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = ANY (p_record_ids)))
           AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
           AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
           AND (NOT COALESCE(p_removed_account, false)
                OR (c.actor_kind = 'user' AND c.actor_employee IS NULL AND u.id IS NULL))
         ORDER BY c.seq DESC
    LOOP
        -- 人名:同一次调用里同一个 (kind, 账号, 员工) 只问一次
        v_akey := r.c_kind || '|' || COALESCE(r.c_account::text, '') || '|' || COALESCE(r.c_employee::text, '');
        IF v_acache ? v_akey THEN
            v_actor := v_acache -> v_akey;
        ELSE
            v_actor := trail_actor(r.c_kind, r.c_account, r.c_employee);
            v_acache := v_acache || jsonb_build_object(v_akey, v_actor);
        END IF;

        v_mask := change_log_mask_row(r.c_table, r.c_key, r.c_old, r.c_new);
        v_old := NULLIF(v_mask -> 'old', 'null'::jsonb);
        v_new := NULLIF(v_mask -> 'new', 'null'::jsonb);
        v_rr := (v_mask ->> 'row_restricted')::boolean;
        v_vkey := r.c_table || '|' || COALESCE(r.c_key::text, '');
        IF v_cache ? v_vkey THEN
            v_vis := (v_cache ->> v_vkey)::boolean;
        ELSE
            SELECT * INTO v_cimg FROM trail_current_image(r.c_table, r.c_key);
            v_vis := COALESCE(trail_row_visible(r.c_table, r.c_key, COALESCE(v_cimg.image, r.c_new, r.c_old)), false);
            v_cache := v_cache || jsonb_build_object(v_vkey, v_vis);
        END IF;
        IF NOT v_vis AND NOT v_rr THEN
            v_old := change_log_restrict(r.c_old, NULL);
            v_new := change_log_restrict(r.c_new, NULL);
            v_rr := true;
        END IF;
        IF v_rr OR r.c_table = 'auth.users' THEN
            v_bt := NULL;
            v_refs := '{}'::jsonb;
        ELSE
            v_bt := trail_row_record(r.c_table, r.c_key, v_old, v_new);
            v_refs := trail_refs(r.c_table, v_old, v_new, r.c_key);
        END IF;
        v_out := v_out || jsonb_build_object(
            'seq', r.c_seq, 'occurred_at', r.c_at, 'table_name', r.c_table, 'row_key', r.c_key, 'op', r.c_op,
            'actor_account', r.c_account, 'actor_email', r.c_email, 'actor_employee', r.c_employee,
            'actor_employee_code', r.c_emp_code, 'actor_employee_name', r.c_emp_name, 'actor_kind', r.c_kind,
            'db_role', r.c_role, 'changed_columns', to_jsonb(r.c_cols), 'old', v_old, 'new', v_new,
            'redacted_at', r.c_redacted, 'row_restricted', v_rr, 'txid', r.c_tx, 'actor', v_actor,
            'belongs_to', v_bt, 'refs', v_refs);
    END LOOP;
    v_n := cardinality(v_txids);
    RETURN jsonb_build_object('rows', to_jsonb(v_out), 'entries', v_n,
        'next_before', v_mx[v_n],
        'exhausted', v_n < v_entries);
END;
$function$;

-- ── change_log_count ──
CREATE OR REPLACE FUNCTION public.change_log_count(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_table text DEFAULT NULL::text, p_tables text[] DEFAULT NULL::text[], p_record_ids text[] DEFAULT NULL::text[], p_actor uuid DEFAULT NULL::uuid, p_no_session boolean DEFAULT false, p_removed_account boolean DEFAULT false)
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n bigint;
BEGIN
    PERFORM require_permission('data.view_change_log');
    SELECT count(*) INTO v_n
      FROM change_log c
     WHERE (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
       AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
       AND (p_table IS NULL OR c.table_name = p_table)
       AND (p_tables IS NULL OR c.table_name = ANY (p_tables))
       AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = ANY (p_record_ids)))
       AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
       AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
       AND (NOT COALESCE(p_removed_account, false)
            OR (c.actor_kind = 'user' AND c.actor_employee IS NULL
                AND NOT EXISTS (SELECT 1 FROM auth.users u2 WHERE u2.id = c.actor_account)));
    RETURN v_n;
END;
$function$;

-- ── dictionary_usage_counts ──
CREATE OR REPLACE FUNCTION public.dictionary_usage_counts(p_refs jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r     record;
    v_map jsonb;
    v_out jsonb := '{}'::jsonb;
BEGIN
    -- 按读者自己的权限数(SECURITY INVOKER):每一张引用表的行级策略照样生效,读不了那张表的人照样被拒(42501)——
    --   与页面原来逐值发的 count(*) HEAD 同一个答案、同一种失败;只是一张引用表一条按值分组的查询,一次往返。
    FOR r IN SELECT x.ref_table, x.ref_column
               FROM jsonb_to_recordset(p_refs) AS x(ref_table text, ref_column text) LOOP
        IF to_regclass(format('public.%I', r.ref_table)) IS NULL THEN
            RAISE EXCEPTION 'DICT_USAGE_UNKNOWN_TABLE|%', r.ref_table;
        END IF;
        EXECUTE format('SELECT COALESCE(jsonb_object_agg(k, n), ''{}''::jsonb) FROM (SELECT t.%I::text AS k, count(*) AS n FROM public.%I t WHERE t.%I IS NOT NULL GROUP BY 1) s',
                       r.ref_column, r.ref_table, r.ref_column)
           INTO v_map;
        v_out := v_out || jsonb_build_object(r.ref_table || '.' || r.ref_column, v_map);
    END LOOP;
    RETURN v_out;
END;
$function$;

-- ── terms_requests_visible ──
CREATE OR REPLACE FUNCTION public.terms_requests_visible(p_recent integer DEFAULT 10, p_formula_id uuid DEFAULT NULL::uuid, p_contract_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, kind text, status text, label text, formula_id uuid, contract_id uuid, subject_code text, reason text, proposed jsonb, snapshot jsonb, created_at timestamp with time zone, created_by_email text, raised_by_me boolean, decided_at timestamp with time zone, decided_by_email text, decision_notes text, withdrawn_at timestamp with time zone, withdraw_reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH r AS (
        SELECT q.*, (q.status = 'submitted') AS is_open,
               COALESCE(f.code, c.code) AS subject_code,
               CASE WHEN q.formula_id IS NOT NULL THEN pricing_formula_terms_visible(f.direction) ELSE contract_terms_price_visible(q.contract_id) END AS terms_ok,
               row_number() OVER (PARTITION BY (q.status = 'submitted')
                                  ORDER BY COALESCE(q.decided_at, q.withdrawn_at, q.created_at) DESC) AS rn
          FROM terms_requests q
          LEFT JOIN pricing_formulas f ON f.id = q.formula_id
          LEFT JOIN contracts c ON c.id = q.contract_id
         WHERE (p_formula_id IS NULL OR q.formula_id = p_formula_id)
           AND (p_contract_id IS NULL OR q.contract_id = p_contract_id)
           AND ((q.formula_id IS NOT NULL AND has_permission('module.pricing.view'))
             OR (q.contract_id IS NOT NULL
                 AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'))
                   OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'))))))
    SELECT r.id, r.kind, r.status, r.label, r.formula_id, r.contract_id, r.subject_code, r.reason,
           CASE WHEN r.terms_ok THEN r.proposed END,
           CASE WHEN r.terms_ok THEN r.snapshot END,
           r.created_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.created_by),
           self_leg(r.created_by, NULL, auth.uid()) = 'raiser',
           r.decided_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.decided_by),
           r.decision_notes, r.withdrawn_at, r.withdraw_reason
      FROM r
     WHERE r.is_open OR r.rn <= GREATEST(COALESCE(p_recent, 10), 0)
     ORDER BY r.is_open DESC, COALESCE(r.decided_at, r.withdrawn_at, r.created_at) DESC
$function$;

-- ── record_sale_settlement ──
CREATE OR REPLACE FUNCTION public.record_sale_settlement(p_sales_order_id uuid, p_output_batch_id uuid, p_assay_result_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- SETTLE-1:把一次结算**记下来**。算术不在这里 —— 它在 sale_settlement_compute。
--
-- ★【一处实现,两个调用者】★ 预览与落库读**同一段算术**。本仓库为
--   "两份实现在写下来那天一致、之后悄悄分开"付过四次账(AGENTS.md 的预览规则)。
--
-- ★【它是 SECURITY DEFINER,所以它【自己】问一次权限】★
--   sales_settlements 没有 INSERT 策略(刻意的:检查与写入必须同一笔事务,
--   否则分两步之间那道缝足够让一份不合口径的结算先被写下来)。
--   而"一支 definer 函数没有权限检查"是本仓库点名过的陷阱 —— 所以下面第一件事
--   就是按名问一次,而不是靠调用它的人记得先问。
--
-- ★【它【不过账】】★ 一分钱都不进总账。理由两条,各自独立:
--   ① 会计政策 5.7 自己标着 NOT BUILT;② PRICE-1 声明过断点,两阶段开票还不存在。
DECLARE
    v_r  jsonb;
    v_id uuid;
BEGIN
    IF NOT has_permission('module.customers.edit'::text) THEN
        RAISE EXCEPTION 'SETTLEMENT_PERMISSION_DENIED|%', 'module.customers.edit'
          USING HINT = '记录一次销售结算要有客户模块的编辑权限 —— 这不是数据缺失,是权限';
    END IF;

    -- 算(所有拒绝都在那一支里,而它们与写入在同一笔事务)
    v_r := sale_settlement_compute(p_sales_order_id, p_output_batch_id, p_assay_result_id);

    INSERT INTO sales_settlements (
        sales_order_id, output_batch_id, assay_result_id,
        settling_party_used, weight_basis_used,
        gross_weight_kg, moisture_pct, settlement_weight_kg,
        metal_value_usd, refining_charge_usd, penalty_usd, amount_usd,
        breakdown, terms_snapshot, computed_by)
    VALUES (
        p_sales_order_id, p_output_batch_id, p_assay_result_id,
        v_r->>'settling_party_used', v_r->>'weight_basis_used',
        (v_r->>'gross_weight_kg')::numeric,
        (v_r->>'moisture_pct')::numeric,
        (v_r->>'settlement_weight_kg')::numeric,
        (v_r->>'metal_value_usd')::numeric,
        (v_r->>'refining_charge_usd')::numeric,
        (v_r->>'penalty_usd')::numeric,
        (v_r->>'amount_usd')::numeric,
        v_r->'breakdown', v_r->'terms_snapshot', auth.uid())
    RETURNING id INTO v_id;

    -- GOLIVE-2(Tim Q5):不持 data.view_prices 的调用者拿回的结算里,那六样钱读成受限 —— 与 sales_settlements_masked 同一组列、同一个码,
    --   同一种受限的写法({"$restricted": true},change_log_restrict 那一个)。写进 sales_settlements 的仍是真数。
    IF NOT has_permission('data.view_prices'::text) THEN
        v_r := v_r || jsonb_build_object(
            'metal_value_usd', '{"$restricted": true}'::jsonb, 'refining_charge_usd', '{"$restricted": true}'::jsonb,
            'penalty_usd', '{"$restricted": true}'::jsonb, 'amount_usd', '{"$restricted": true}'::jsonb,
            'breakdown', '{"$restricted": true}'::jsonb, 'terms_snapshot', '{"$restricted": true}'::jsonb);
    END IF;
    RETURN v_r || jsonb_build_object('settlement_id', v_id, 'posted_to_ledger', false);
END
$function$;

COMMENT ON FUNCTION public.record_sale_settlement(uuid, uuid, uuid) IS
    'SETTLE-1:把一次销售结算**记下来** —— **它不过账**(返回值里那句 posted_to_ledger=false 是刻意印出来的)。算术在 sale_settlement_compute:**一处实现,两个调用者**,预览与落库读同一段算术(本仓库为「两份实现悄悄分开」付过四次账)。★**它是 SECURITY DEFINER,所以它自己先按名问一次权限**★ —— sales_settlements 没有 INSERT 策略(刻意的:检查与写入必须同一笔事务),而「definer 函数没有权限检查」是本仓库点名过的陷阱。★**为什么不过账**★:① 会计政策 5.7 自己标着 NOT BUILT(差额科目已裁定、过账路径没有);② PRICE-1 声明过断点,两阶段开票还不存在,**没有开票就没有东西喂给过账路**。';

-- ── 第 13 行 · 按事务取行的索引 ──
CREATE INDEX idx_change_log_txid ON public.change_log (txid);

-- ── Q4 · 冻结副本的价格列 ──
REVOKE SELECT ON public.contract_document_terms FROM authenticated, anon;
REVOKE ALL ON public.contract_document_terms FROM anon;
GRANT SELECT (id, purchase_order_id, sales_order_id, contract_id, contract_code, contract_title, incoterm, currency, payment_terms_days, grade_specs, linked_at, linked_by) ON public.contract_document_terms TO authenticated;

-- ── Q6 · 条款申请的快照列 ──
REVOKE SELECT ON public.terms_requests FROM authenticated;
GRANT SELECT (id, kind, status, label, formula_id, contract_id, reason, proposed, fingerprint, decided_at, decided_by, decision_notes, executed_at, withdrawn_at, withdrawn_by, withdraw_reason, created_at, created_by) ON public.terms_requests TO authenticated;

-- ── contract_document_terms_masked ──
CREATE VIEW public.contract_document_terms_masked WITH (security_invoker = off) AS
 SELECT
    t.id,
    t.purchase_order_id,
    t.sales_order_id,
    t.contract_id,
    t.contract_code,
    t.contract_title,
    t.incoterm,
    t.currency,
    t.payment_terms_days,
    t.grade_specs,
    t.linked_at,
    t.linked_by,
        CASE
            WHEN contract_copy_price_visible(t.sales_order_id, t.purchase_order_id) THEN t.pricing_terms
            ELSE ( SELECT COALESCE(jsonb_agg(CASE WHEN jsonb_typeof(e.value) = 'object' AND e.value ? 'payable_pct'
                                                   THEN jsonb_set(e.value, '{payable_pct}', 'null'::jsonb) ELSE e.value END
                                              ORDER BY e.ordinality), '[]'::jsonb)
                     FROM jsonb_array_elements(t.pricing_terms) WITH ORDINALITY e(value, ordinality))
        END AS pricing_terms,
        CASE
            WHEN contract_copy_price_visible(t.sales_order_id, t.purchase_order_id) THEN t.settlement_terms
            ELSE t.settlement_terms
                 || CASE WHEN jsonb_typeof(t.settlement_terms -> 'refining_charges') = 'array' THEN jsonb_build_object('refining_charges',
                        ( SELECT COALESCE(jsonb_agg(CASE WHEN jsonb_typeof(r.value) = 'object' AND r.value ? 'usd_per_tonne_of_metal'
                                                         THEN jsonb_set(r.value, '{usd_per_tonne_of_metal}', 'null'::jsonb) ELSE r.value END
                                                    ORDER BY r.ordinality), '[]'::jsonb)
                            FROM jsonb_array_elements(t.settlement_terms -> 'refining_charges') WITH ORDINALITY r(value, ordinality)))
                         ELSE '{}'::jsonb END
                 || CASE WHEN jsonb_typeof(t.settlement_terms -> 'penalty_elements') = 'array' THEN jsonb_build_object('penalty_elements',
                        ( SELECT COALESCE(jsonb_agg(CASE WHEN jsonb_typeof(p.value) = 'object' AND p.value ? 'usd_per_tonne_per_pct_over'
                                                         THEN jsonb_set(p.value, '{usd_per_tonne_per_pct_over}', 'null'::jsonb) ELSE p.value END
                                                    ORDER BY p.ordinality), '[]'::jsonb)
                            FROM jsonb_array_elements(t.settlement_terms -> 'penalty_elements') WITH ORDINALITY p(value, ordinality)))
                         ELSE '{}'::jsonb END
        END AS settlement_terms
   FROM contract_document_terms t
     JOIN contracts c ON c.id = t.contract_id
  WHERE (c.customer_id IS NOT NULL AND ( SELECT has_permission('module.customers.view'::text) AS has_permission))
     OR (c.supplier_id IS NOT NULL AND ( SELECT has_permission('module.suppliers.view'::text) AS has_permission));

REVOKE ALL ON public.contract_document_terms_masked FROM authenticated, anon;
GRANT SELECT ON public.contract_document_terms_masked TO authenticated;

-- ── terms_requests_masked ──
CREATE VIEW public.terms_requests_masked WITH (security_invoker = off) AS
 SELECT
    q.id,
    q.kind,
    q.status,
    q.label,
    q.formula_id,
    q.contract_id,
    q.reason,
    q.proposed,
        CASE
            WHEN (CASE WHEN q.formula_id IS NOT NULL THEN pricing_formula_terms_visible(f.direction)
                       ELSE contract_terms_price_visible(q.contract_id) END) THEN q.snapshot
            ELSE NULL::jsonb
        END AS snapshot,
    q.fingerprint,
    q.decided_at,
    q.decided_by,
    q.decision_notes,
    q.executed_at,
    q.withdrawn_at,
    q.withdrawn_by,
    q.withdraw_reason,
    q.created_at,
    q.created_by
   FROM terms_requests q
     LEFT JOIN pricing_formulas f ON f.id = q.formula_id
     LEFT JOIN contracts c ON c.id = q.contract_id
  WHERE (q.formula_id IS NOT NULL AND ( SELECT has_permission('module.pricing.view'::text) AS has_permission)
            AND ( SELECT has_permission('data.view_prices'::text) AS has_permission)
            AND ( SELECT has_permission('data.view_purchase_prices'::text) AS has_permission))
     OR (q.contract_id IS NOT NULL
         AND ((c.customer_id IS NOT NULL AND ( SELECT has_permission('module.customers.view'::text) AS has_permission))
           OR (c.supplier_id IS NOT NULL AND ( SELECT has_permission('module.suppliers.view'::text) AS has_permission))));

REVOKE ALL ON public.terms_requests_masked FROM authenticated, anon;
GRANT SELECT ON public.terms_requests_masked TO authenticated;

-- ── Q5 · 结算的算术只由 record_sale_settlement 调 ──
REVOKE EXECUTE ON FUNCTION public.sale_settlement_compute(uuid, uuid, uuid) FROM authenticated;

-- 新函数的 EXECUTE:apply_migration.sh 在本事务里重放 db/views/zzz_function_grants.sql(先全收、再授 authenticated / service_role、再按名收回)。
-- ── function grants replay (apply_migration.sh does this inside the migration's transaction) ──
-- db/views/zzz_function_grants.sql
-- 【函数的 EXECUTE 权限 —— 镜像此前完全没有记它们】
--
-- ════════════════════════════════════════════════════════════════════════════
-- pg_get_functiondef 不吐 GRANT/REVOKE,而表镜像是【手写】把 GRANT 补进去的
-- (22 个表镜像里都有),函数镜像没有。后果是实测出来的:
--     live    calculate_metal_price_internal  anon=false authenticated=false
--     rebuilt calculate_metal_price_internal  anon=true  authenticated=true
--     live    reverse_journal_entry_internal  anon=false authenticated=false
--     rebuilt reverse_journal_entry_internal  anon=true  authenticated=true
-- 也就是说【这个系统里每一次 REVOKE 都活不过一次重建】。照镜像切到生产,
-- 冲销分录的引擎会向匿名用户敞开 —— 而匿名 key 是随应用公开发出去的。
--
-- 【为什么这个文件住在 db/views/ 而不是 db/functions/】重放顺序是
-- functions → tables → views,而【表镜像里也定义函数】(守卫触发器、取号函数,共 36 个)。
-- 放在 db/functions 里跑,那 36 个还没建出来,REVOKE ON ALL FUNCTIONS 收不到它们 ——
-- 实测:重建之后 anon 仍能调 36 个。放在 views 阶段、文件名 zzz 排最后,才真的收得干净。
-- 它不定义任何视图,只声明权限。
--
-- 【anon 在 public 架构里不该有任何 EXECUTE】anon 就是互联网。
-- 未登录的界面(登录页、设置密码页)走的是 Supabase auth 端点,不调 public 的函数,
-- 所以这是一句可以下得很死的断言,而不是需要逐个斟酌的清单。
-- 真有哪个函数将来必须给 anon,就在下面显式加一行【并写明理由】。
-- ════════════════════════════════════════════════════════════════════════════

-- 先全部收回(含 PUBLIC —— 默认授权给的是 PUBLIC,authenticated 是从它继承的;
-- 只收 authenticated/anon 是没有用的,OPS-3 实测过)。
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon;

-- 再把登录用户与服务角色需要的授回。
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, service_role;

-- 【内层函数:连 authenticated 也不给】它们没有调用者检查,靠的就是调不到。
-- 有调用者检查的函数不在此列 —— 那是另一半保证(见 check 的 C1 不变式)。
REVOKE EXECUTE ON FUNCTION public.calculate_metal_price_internal(uuid, jsonb, numeric, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_journal_entry_internal(uuid, date, text) FROM authenticated;
-- FIN-27:条款解析与承诺写入的内层算子。同上 —— 没有调用者检查,靠的就是调不到;
-- 它们只从 calculate_metal_price_internal / apply_assay_result /
-- reprice_from_committed_terms / create_purchase_order 的函数体内被调用(属主身份)。
-- SOD-1(2026-08-24):职责分离的三支内层函数。**gate 的 B2 抓到它们**,
-- 而其中两支是真的越权读:sod_manual_posters_in / sod_supplier_creator 是
-- SECURITY DEFINER 且没有调用者检查,留着 authenticated 的 EXECUTE,任何登录用户
-- 都能绕过 RLS 读出"谁记过手工凭证"与"谁建了这家供应商"。
-- 三支都只从 guard_payment_sod / guard_finance_settings_sod 的函数体内被调用,
-- 而那两个是属主身份跑的触发器 —— 所以收回之后照常工作,靠的就是调不到。
-- (approvals_readiness 不在此列:它【要】被页面调用,所以走的是另一半保证 ——
--  fu2 给它加了 require_permission(...)。★ APR-1(N6)把那个码从 module.finance.view
--  换成了 action.manage_permissions —— 与 /settings/approvals 那一页的闸同一个码,
--  于是屏幕与它调的函数不再是两个码守同一块屏幕。)
REVOKE EXECUTE ON FUNCTION public.assert_segregated(text, uuid[], text) FROM authenticated;

-- GST-1(2026-08-24):两支查表函数。**gate 的 definer 判词点了它们的名**。
-- 它们都是 SECURITY DEFINER 且没有调用者检查:tax_rate_for 绕过 tax_rates 的 RLS,
-- gst_registered 绕过 finance_settings 的 RLS。
-- 实测 app / lib 里没有任何一处调它们 —— 界面调的是 f5_return / f5_box_detail
-- (两者都带 require_permission),以及 finance_settings.gst_registered 这一【列】
-- (走该表自己的 RLS)。库内只有 f5_return 与 post_journal_entry 调它们,
-- 两个都是 SECURITY DEFINER,以属主身份执行,收回之后照常工作。
-- 【为什么不给它们加 require_permission】它们被属主(postgres)在 definer 内部调用,
-- 而 postgres 没有 claims —— 加了门反而会在过账与出表的路上抛权限错。
-- 与上面三支同形:够不着的东西不需要门,需要的是【真的够不着】。
REVOKE EXECUTE ON FUNCTION public.gst_registered() FROM authenticated;

-- EQP-PAY-1(2026-09-01):一张采购单是设备单还是材料单。**gate 的 B2 点了它的名。**
-- 它是 SECURITY DEFINER 且没有调用者检查 —— 而那是【故意的】:它是给守卫触发器
-- 认主语用的。若它受 RLS 约束,一个看不见行的调用者会拿到 NULL,而守卫会因此
-- 【静默放行】—— 正是本仓库记过的"守卫对主语缺席这一格是瞎的"那条病。
--
-- 【为什么不给它加 require_permission,而是收回 EXECUTE】它唯一的库内调用者
-- guard_payment_term_applicable 是【属主身份跑的触发器】,而属主(postgres)没有
-- claims —— 加一道门反而会在每一次写付款计划的路上抛权限错。与上面
-- gst_registered / tax_rate_for 同形:**够不着的东西不需要门,需要的是【真的够不着】。**
-- app / lib 里没有任何一处调它(实测);报表里要用它,以 postgres 身份跑。
REVOKE EXECUTE ON FUNCTION public.purchase_order_kind(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.tax_rate_for(text, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.sod_manual_posters_in(date, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.sod_supplier_creator(uuid) FROM authenticated;

-- COD-1(2026-09-07):销毁证书的三支内层函数。**gate 的 B2 点了它们的名,
-- 而其中一支是真的越权动作** —— void_cod_internal 是 SECURITY DEFINER 且【没有
-- 调用者检查】,留着 authenticated 的 EXECUTE,任何登录用户都能作废任何一张
-- 已签发的销毁证书,完全绕开 action.issue_cod。带门的那一支叫 void_cod;
-- 这一支存在,是因为【冲销加工单的人不持有签发权限】,而冲销必须能作废证书。
--
-- 三支各自的唯一调用者,全部是属主身份跑的 SECURITY DEFINER:
--   * void_cod_internal      ← void_cod、refresh_cod_for_batch
--   * refresh_cod_for_batch  ← commit_processing_run / rollback_processing_run /
--                              soft_delete_inbound_batch(三处挂钩)
--   * cod_delivery_completion ← refresh_cod_for_batch、cod_certificate_data
-- 所以收回之后照常工作,靠的就是【真的够不着】。
--
-- 【为什么不给它们加 require_permission,而是收回 EXECUTE】与上面 gst_registered /
-- purchase_order_kind 同形,但这里的理由更硬一格:refresh_cod_for_batch 是在
-- 【投料的那个人】的会话里被调用的,而运营角色不持有 action.issue_cod ——
-- 加一道门会让"提交加工单"这个动作本身抛权限错。
--
-- ★【界面因此走带门的那一支】★ 面板要显示"为什么还不能签发",而那句话
-- 由 cod_certificate_data 的 CANNOT_CERTIFY|批号|理由 抛出 —— 它有
-- action.issue_cod 的门。判据仍然只有一份实现,而外面只有一扇门。
REVOKE EXECUTE ON FUNCTION public.void_cod_internal(uuid, text, uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.refresh_cod_for_batch(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.cod_delivery_completion(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.pricing_terms_of_formula(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.pricing_terms_of_commitment(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.calculate_metal_price_from_terms(jsonb, jsonb, numeric, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.commit_pricing_terms(uuid, uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.resolve_pricing_commitment(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.committed_terms_price(uuid, date) FROM authenticated;
-- TASK-1c-a-fu1:【一个事实,一个写入者】那个函数 —— 归属人置为活跃参与者。
-- 它没有调用者检查,只从两扇门的触发器体内被调用(属主身份),所以靠的就是调不到。
-- 门被 gate 的 B2 抓到过一次:留着 authenticated 的 EXECUTE,任何登录用户都能
-- 把【自己】插成【任何一张任务】的活跃参与者 —— 而活跃参与者正是 can_edit_task
-- 团队分支的全部判据。也就是说它等于一把万能写权限。
REVOKE EXECUTE ON FUNCTION public.ensure_task_owner_participant(uuid, uuid, uuid) FROM authenticated;
-- APR-1:审批留痕的唯一写入口。没有调用者检查 —— 它只从 decide_leave_request /
-- decide_medical_claim / submit_review / approve_review / acknowledge_review 的函数体内
-- 以属主身份被调用,而那五个各自已经把过关了。给了 authenticated 就等于任何登录用户
-- 都能伪造一行留痕,而留痕正是"不可伪造"才有意义的东西。
REVOKE EXECUTE ON FUNCTION public.record_approval_decision(text, uuid, text, smallint, text) FROM authenticated;
-- APR-2:审批引擎的两个内层算子。approval_level_for 读的是 finance_settings 上的阈值,
-- require_approver_for 是"你能不能批这一级"的判词本身 —— 两个都没有调用者检查,
-- 靠的就是调不到。公开入口是 approve_purchase_order / reject_purchase_order,
-- 它们各自 require_permission。给了 authenticated 就等于把阈值和授权判断敞开。
REVOKE EXECUTE ON FUNCTION public.approval_level_for(numeric) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.require_approver_for(smallint) FROM authenticated;
-- ★ APR-3:分档那个比较号搬出来单独成一支(approval_level_at)。它【不是】DEFINER
-- (它一个东西都不读:两个入参,一次比较),所以 gate 的 B2 与它无关;收权是为了
-- 与它的公开入口 approval_level_for 一致 —— 两支答的是同一个问题,不该一支敞着。
REVOKE EXECUTE ON FUNCTION public.approval_level_at(numeric, numeric) FROM authenticated;
-- ★ APR-3:一张报销单值多少本位币。【不是】DEFINER —— 它读 expense_claims 与
-- fx_rates,而那两张表的 RLS 正是这个问题该有的答案。收权的理由不是安全(RLS
-- 已经管住了),是【它是一支内层算子】:它的三个调用方都以属主身份跑,而一个
-- 敞着的内层算子迟早会长出第四个调用方,那时谁也说不清它该答什么。
REVOKE EXECUTE ON FUNCTION public.expense_claim_amount_base(uuid) FROM authenticated;
-- ★★ APR-3:哪些单据正在等人批。SECURITY DEFINER 且【没有】调用者检查,
-- 与 real_role_holders / approval_gate_intersections 逐字同源同理由:它的三个
-- 调用方里两个是【属主身份跑的触发器】(guard_approvals_switch 的关闭那一支与
-- APPROVALS_POLICY_WOULD_STRAND),属主没有 claims,加一道门会在每一次写策略的
-- 路上抛权限错;第三个 approvals_readiness 自己开头就查 action.manage_permissions。
-- 给了 authenticated 就等于把采购与财务两个模块的在途单据编号一起敞开。
REVOKE EXECUTE ON FUNCTION public.approval_pending_documents() FROM authenticated;
-- SAL-B:客户敞口算子。无调用者检查,靠调不到 —— 消费方是 record_output_sale
-- (definer)与 operations_now(属主视图),两者都以属主身份执行。给了
-- authenticated 就等于把任意客户的应收敞口敞开给没有财务权限的人。
REVOKE EXECUTE ON FUNCTION public.customer_ar_exposure_base(uuid) FROM authenticated;
-- IOD-1:库存排空与冲销镜像的内层算子。无调用者检查,靠的就是调不到 ——
-- drain_stock 的调用方是 record_output_sale(output.edit)、commit_processing_run
-- (processing.edit)与注销触发器(批次侧的 edit),【三者各自已经把过关】,
-- 而它们分属不同模块:给 drain_stock 挑一个权限码只能挑一个比三者都松的,
-- 那不是把关、那是把关的样子。mirror_consume_restore 只从 rollback_processing_run
-- 体内被调用。给了 authenticated 就等于任何登录用户都能凭空写出入库/出库流水。
REVOKE EXECUTE ON FUNCTION public.drain_stock(numeric, text, date, uuid, uuid, text[], uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.mirror_consume_restore(uuid, uuid, uuid, numeric, date, uuid) FROM authenticated;
-- IOD-1b:收货库位的翻译器。三个建批次 RPC 共用它,而那三个分属两个模块
-- (进料 inbound.edit / 产出 output.edit)且各自已把过关 —— 给它挑一个权限码
-- 只能挑一个比两者都松的。靠"调不到"。
REVOKE EXECUTE ON FUNCTION public.resolve_receipt_location(uuid) FROM authenticated;
-- IOD-2:库位/物料分类的判词。同 resolve_receipt_location —— 四个落地点共用它,
-- 而那四个分属三个模块(inbound.edit / output.edit / inventory.edit)且各自已把
-- 过关;给它挑一个权限码只能挑一个比三者都松的,那不是把关、是把关的样子。
-- 它没有调用者检查,靠的就是调不到(gate 的 B2 判词认这条出路)。
REVOKE EXECUTE ON FUNCTION public.check_location_class(uuid, uuid) FROM authenticated;
-- NTF-1:两个通知发射器。【它们能凭空写出一条通知】,而 notifications 之所以可信,
-- 靠的正是"只有属主身份的函数写得进"(与 approval_log 同一条:留痕不该有第二个
-- 写法)。给了 authenticated,任何登录用户都能伪造一条"某某库位违规"的事件 ——
-- 而通知是拿来被相信的东西。
-- 【调用它们的是谁】notify_landing_warnings 从四个建批次 RPC 的函数体内被调用
-- (那四个是 DEFINER,以属主身份执行);notify_class_violations 从两个触发器函数
-- 内被调用,而那两个触发器函数【也声明了 SECURITY DEFINER】—— 触发器函数默认以
-- 调用者身份跑,不声明就会在这里撞上"调不到"。
REVOKE EXECUTE ON FUNCTION public.notify_landing_warnings(text[], uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_class_violations(text, uuid[], uuid[]) FROM authenticated;
-- SO-3b:发货单号的取号器。无调用者检查,靠的就是调不到 —— 唯一调用方是
-- ship_order(DEFINER,module.sales.edit,以属主身份执行)。给了 authenticated
-- 就等于任何登录用户都能凭空烧掉一个无缝单号,而无缝的意思正是"号码之间没有洞"。
REVOKE EXECUTE ON FUNCTION public.next_shipment_code(date) FROM authenticated;
-- LOG-2a:集装箱取号器。同 next_shipment_code —— 无调用者检查,靠的就是调不到。
REVOKE EXECUTE ON FUNCTION public.next_container_code(date) FROM authenticated;
-- SO-3b fu5:"这一行已经许出去多少"(已发 + 活预留)。无调用者检查,靠的就是
-- 调不到 —— 消费方是 reserve_stock(DEFINER,module.sales.edit),以及下一刀
-- SO-1b 的改单下限。它读的是订单行的履约情况,而那是 module.sales.view 的东西;
-- 给了 authenticated 就等于任何登录用户都能一行一行问出别人订单的发货进度。
REVOKE EXECUTE ON FUNCTION public.line_spoken_for(uuid) FROM authenticated;
-- SO-1b:"这张单发完了没有"(已发 vs 已订)。同上 —— 没有调用者检查,靠的就是
-- 调不到;两个消费方 ship_order 与 amend_sales_order 都是 DEFINER、都要
-- module.sales.edit,以属主身份执行。给了 authenticated 就等于任何登录用户都能
-- 一张一张问出别人订单的履约进度,而那是 module.sales.view 的东西。
REVOKE EXECUTE ON FUNCTION public.sales_order_fulfilment_status(uuid) FROM authenticated;
-- CN-1:贷项凭证的取号器。同 next_shipment_code —— 无调用者检查,靠的就是调不到;
-- 唯一调用方是 create_credit_note(DEFINER,module.finance.edit,以属主身份执行)。
-- 给了 authenticated 就等于任何登录用户都能凭空烧掉一个无缝单号,而无缝的意思
-- 正是"号码之间没有洞"。
REVOKE EXECUTE ON FUNCTION public.next_credit_note_code(date) FROM authenticated;
-- SO-4a:报价的取号器。同上 —— 无调用者检查,靠的就是调不到。
-- 【而建报价【走直连】,没有 RPC 门可以代取】—— 两者放在一起,客户端就永远
-- 拿不到号。解法不是把它授出去,是让号【根本不由客户端取】:
-- generate_quote_code(BEFORE INSERT,属主身份)在同一条语句里补上,
-- 先例是 customers.generate_customer_code。客户端插的是一行没有号的报价。
REVOKE EXECUTE ON FUNCTION public.next_quote_code(date) FROM authenticated;
-- EQP-1c-a:固定资产的取号器。同 next_shipment_code / next_container_code /
-- next_quote_code —— 没有调用者检查,靠的就是调不到。它有【两个】调用方
-- (record_expense 的新建支与 create_fixed_asset),两个都是 DEFINER 且各自
-- require_permission('module.finance.edit'),以属主身份执行。给了 authenticated
-- 就等于任何登录用户都能凭空烧掉一个 FA 号,而"无缝"的意思正是号码之间没有洞。
REVOKE EXECUTE ON FUNCTION public.next_fixed_asset_code(date) FROM authenticated;

-- GST-2(2026-08-25):税码解析器。与上面 GST-1 那两支【逐字同一条理由】——
-- SECURITY DEFINER、没有调用者检查、绕过 tax_codes 的 RLS 读出整本税码字典。
-- 界面从不调它:屏幕上的税码下拉读的是 tax_codes 这张表本身(走它自己的 RLS,
-- 谓词是 has_permission('module.finance.view'))。库内只有 create_invoice /
-- create_order_invoice / record_expense 调它,三支都是 SECURITY DEFINER、
-- 以属主身份执行,收回之后照常工作。
-- 【为什么不给它加 require_permission】它被属主(postgres)在 definer 内部调用,
-- 而 postgres 没有 claims —— 加了门反而会在开票与记费用的路上抛权限错。
REVOKE EXECUTE ON FUNCTION public.resolve_tax_code(text, text, text, text) FROM authenticated;

-- CHAIN-BUILD-1(2026-08-30):审批链的两支内层判据。
-- 【为什么收回】两支都是 SECURITY DEFINER 且【没有调用者检查】,而 gate 的 B2
-- 正是查这个。它们【不需要】门,需要的是【真的够不着】——
-- real_role_holders 读 auth.users(账号是否确认/封禁/删除)与 user_roles,
-- 给了 authenticated 就等于任何登录用户都能把整个账号目录的登录状态问出来;
-- role_can_see_amounts 读 role_permissions,同理会把权限矩阵问出来。
-- 【唯一的调用方,逐个点名】三支都是 SECURITY DEFINER、以属主身份执行,
-- 而且三支各自已经把过关(readiness 有 require_permission;另两支是闸自己):
--   · real_role_holders   ← guard_approvals_switch / approvals_readiness / require_approver_for
--   · role_can_see_amounts ← guard_approvals_switch / approvals_readiness
-- 收回之后照常工作,靠的就是调不到 —— 与上面 SOD-1 那三支逐字同一条理由。
REVOKE EXECUTE ON FUNCTION public.real_role_holders(text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.role_can_see_amounts(text) FROM authenticated;

-- ★ APR-2(2026-09-22):approval_gate_intersections —— 与上面这两支【同源同理由】。
-- 它经 real_role_grants 读 auth.users 的登录状态,并把整张 role_permissions
-- 摊平成"谁真的持有哪个码"。给了 authenticated 就等于把账号目录 + 权限矩阵
-- 一次问出来 —— 比单独任何一支都宽。
-- 【唯一的两个调用方】approvals_readiness(自己有 require_permission)与
-- guard_approvals_switch(属主身份跑的触发器),两者都是 SECURITY DEFINER,
-- 收回之后照常工作,靠的就是调不到。
-- ⚠【为什么这一行必须在这里】C-1 的 real_role_grants 实测过:
--   apply_migration.sh 在 COMMIT 【之前】重放本文件,而本文件第一句是
--   REVOKE EXECUTE ON ALL FUNCTIONS ... FROM PUBLIC 后面跟着 GRANT ... TO authenticated
--   —— 只写在迁移里的那次 REVOKE 会被原样冲掉,而迁移报告成功。
REVOKE EXECUTE ON FUNCTION public.approval_gate_intersections(text, text) FROM authenticated;

-- ★ APR-2:approval_chain_gates 与 forbid_self_approval 【故意不收】。
--   两支都【不是】SECURITY DEFINER,也都不读任何受 RLS 约束的东西:
--   前者是一张常量名册,后者只比较 auth.uid() 与两个传进来的 uuid。
--   ☞ 照直写下来,免得下一个人以为它们是被漏掉的 —— 一份"该收而没收"的
--     清单与一份"想过、不收"的清单,在文件里长得一模一样。
--   ★ APR-ROUTE-1 之后【后半句不再逐字成立】:forbid_self_approval 现在经
--     self_leg 与 self_approval_exception 去问(两者都已收回)。它仍然【不收】——
--     它自己不是 DEFINER,一个 authenticated 直接调它会在那两支上撞 42501,
--     什么都探不到;而它唯一的调用方是 DEFINER 决定函数,以属主身份执行。

-- ★ C-1(2026-09-04):real_role_grants —— 与上面 real_role_holders 【同源同理由】。
-- 它就是那四条判据的行级形状(返回 grant_id + user_id),real_role_holders 如今
-- 是它的投影。所以它读的东西一字不差:auth.users 的确认/封禁/删除 + user_roles。
-- 给了 authenticated 就等于把整个账号目录的登录状态问出来 —— 收回。
-- 【唯一的调用方】guard_last_admin(user_roles 上的 BEFORE UPDATE/DELETE 触发器)。
-- ★ 它正是因此才被改成 SECURITY DEFINER 的:调用者权限的触发器以 authenticated
--   身份跑,收回之后就【调不到】,守卫会在每一次撤销授权时抛权限错。
--   DEFINER 让它以属主身份跑,于是"收回"与"守卫能用"同时成立。
--
-- ⚠【这一行是被实测逼出来的,不是照抄】C-1 起初只把 REVOKE 写在迁移里。
--   apply_migration.sh 在 COMMIT 之后会【重新断言一遍本文件】(那是它的兜底),
--   而本文件当时没有这一行 —— 于是那次 REVOKE 被原样冲掉,
--   实测 has_function_privilege('authenticated', 'real_role_grants', 'EXECUTE') = true,
--   一条【活的 B2 违规】。**收回必须写在这里,写在迁移里不算数。**
REVOKE EXECUTE ON FUNCTION public.real_role_grants(text) FROM authenticated;

-- PROC-COST-2(2026-08-31):【计值读取器】与【单位落地成本】三支内层函数。
-- 三支都是 SECURITY DEFINER 且【没有调用者检查】,而 gate 的 B2 正是查这个。
-- 它们【不该】有门,需要的是【真的够不着】—— 理由与上面那一族逐字同源,
-- 但这里的"为什么不加门"有它自己的一条,值得写清楚:
--
-- 【为什么这两支【必须】没有判据】batch_freight_base / batch_processing_cost_base
-- 是【屏幕读取器】,无权返回 NULL(受限)——「受限」与 0.00 不是同一件事。
-- 而注销与盘点要过账的那个金额【不许取决于谁按的按钮】:一个只有
-- module.inbound.edit 的仓管按下注销时,若计值读的是带判据的那一支,
-- COALESCE(NULL, 0) 会让它安静地退回按 unit_price 计值 —— 也就是 PROC-COST-2
-- 正在修的那个缺陷原样复发,而且再没有人看得见。所以算术与受众拆成两层:
-- 算术在 _all 这一对里(只有一份定义),受众在带判据的那一对里。
--
-- 【唯一的调用方,逐个点名】三支都只从属主身份执行的地方被调用:
--   · batch_freight_base_all          ← batch_freight_base(definer,带判据)
--                                       inbound_batch_landed_unit_cost(definer)
--                                       allocate_processing_costs(definer,ROLE-1 Batch 3a 起)
--   · batch_processing_cost_base_all  ← batch_processing_cost_base(definer,带判据)
--                                       inbound_batch_landed_unit_cost(definer)
--                                       allocate_processing_costs(definer,ROLE-1 Batch 3a 起)
--   · inbound_batch_landed_unit_cost_all ← emit_batch_writeoff_movement(触发器,definer)
--                                       post_stocktake(definer)
--                                       inventory_control_reconciliation(definer)
--                                       inventory_valuation_snapshot(definer)
--     【CLEANUP-A fu1】它是【过账】原语,刻意没有判据 —— 账上的金额不许取决于
--     按按钮的人有什么读权限。所以它必须靠"调不到"活着,与上面那一对同一条规矩。
--   · inbound_batch_landed_unit_cost  ← inbound_batch_valuation_rows(definer)
--     【它自己带判据(CLEANUP-A / R3)】,收权是第二层,不是唯一那层。
--     (此处原写着 post_stocktake(definer,module.stocktakes.edit)—— 不对:fu1 起 post_stocktake
--      读 _all。ROLE-1 Batch 3a 顺手更正,并拿掉了判据里 stocktakes.edit 那一支。)
-- 给了 authenticated 就等于把【绕过 RLS 的运费与加工成本读取】敞开给任何登录
-- 用户 —— 那正是带判据的那一对存在的全部理由,而这三支会把它一句话作废。
-- 收回之后照常工作,靠的就是调不到。
REVOKE EXECUTE ON FUNCTION public.batch_freight_base_all(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.batch_processing_cost_base_all(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.inbound_batch_landed_unit_cost(uuid) FROM authenticated;
-- CLEANUP-A fu1:过账原语,无判据,必须靠"调不到"活着。
REVOKE EXECUTE ON FUNCTION public.inbound_batch_landed_unit_cost_all(uuid) FROM authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ COD-2(2026-09-08):本仓库【第一条】给 anon 的 EXECUTE ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- 本文件抬头写着:「anon 在 public 架构里不该有任何 EXECUTE……真有哪个函数
-- 将来必须给 anon,就在下面显式加一行【并写明理由】。」这就是那一行,
-- 而下面是那个理由。
--
-- 【它是什么】cod_verification(text) —— 销毁证书核验页的取数。供应商扫证书上
-- 的二维码打开 /verify/cod/<令牌>,那一页就是这支函数的输出。**这是本系统
-- 第一个不用登录就打得开的页面**,而这支函数是它够得着的【唯一】一样东西。
--
-- 【为什么必须给 anon,不能靠"页面在服务端用 service_role 读"】
--   两种都成立,而选这一种的理由是【判据落在哪里】:给 anon 授权,把关的是
--   数据库 —— 这支函数收一个令牌、回一份白名单子集,任何调用者都只拿得到那些。
--   走 service_role 的话,把关的是"那一页恰好是服务端渲染的、而且它恰好只
--   显示了该显示的" —— 一次页面重写就可能悄悄改掉它,而没有任何东西会说话。
--   ★ 一条能在数据库这边说清的判据,不该寄存在一个页面的写法里。★
--
-- 【它没有调用者检查,而这是【正确的】】它的"权限"就是【持有那个令牌】:
--   122 位随机、与证书号毫无关系、改一位数字得到的是一个不存在的值。
--   一个匿名的核验入口若还要问 has_permission,它就永远回答不了任何人。
--   check_mirrors 的 DEFINER_NO_CHECK_ALLOWED 里有它,理由逐字同此。
--
-- 【它的限流住在函数体里,不在路由上】anon key 随浏览器包发出去,所以
--   POST /rest/v1/rpc/cod_verification 是第二条门,不经过 Vercel ——
--   一个住在路由上的限流器会被它要拦的那个工具整个绕过去。
--
-- ⚠★【这一行【必须】在这里,而不是只在迁移里】★⚠ 与 C-1 的 real_role_grants
--   那一段【方向相反、道理相同】:db/apply_migration.sh 把本文件拼在 COMMIT
--   之前、同一个事务里重跑一遍,而本文件的第一句是
--       REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon;
--   一条只写在迁移里的 GRANT 会在提交之前被它冲掉,**而迁移报告成功**。
--   所以真源在这里,写在那句 REVOKE 的【后面】。
GRANT EXECUTE ON FUNCTION public.cod_verification(text) TO anon;

-- COD-2:执照判据(在完成日当天在效的那一张 GWDF)。与 cod_delivery_completion
-- 逐字同一条理由 —— SECURITY DEFINER、没有调用者检查,靠的就是【调不到】。
-- 它绕过 company_compliance 的 RLS(那张表的谓词借的是 module.suppliers.view,
-- 而仓储现场读不到它,却仍然被这道闸管着 —— 那正是它必须 DEFINER 的原因)。
-- 给了 authenticated 就等于任何登录用户都能把公司的执照号、发证机关与有效期
-- 问出来。唯一的两个调用方 issue_cod 与 cod_certificate_data 都是 DEFINER、
-- 各自 require action.issue_cod,以属主身份执行,收回之后照常工作。
REVOKE EXECUTE ON FUNCTION public.cod_governing_licence(date) FROM authenticated;

-- ★ APR-ROUTE-1(2026-09-23):五支新的内层函数,全部【收回】。
--   五支都是 SECURITY DEFINER、没有调用者检查,靠的就是【调不到】:
--     account_person          —— 回答【任意一个账号】是哪一名员工(账号目录);
--     self_leg                —— 经它能逐个探测"某账号是不是某单据的提单人/主角";
--     self_approval_exception —— 经 real_role_holders 读审批人名单;
--     approval_level_eligible —— 同上;
--     approval_deciders       —— 读 auth.users 的登录状态与整张权限矩阵。
--   调用方(forbid_self_approval 在 DEFINER 决定函数里、record_approval_decision、
--   require_approver_for、approval_gate_intersections、approvals_readiness、
--   guard_approvals_switch)全部以属主身份执行,收回之后照常工作。
--   ⚠ 写在这里而不是只写在迁移里:理由见上面 approval_gate_intersections 那一段。
--   ☞ self_approved_decisions【不收】:它有自己的调用者检查
--     (require_permission('data.view_self_approvals')),而 /finance/self-approved 要调它。
REVOKE EXECUTE ON FUNCTION public.account_person(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.self_leg(uuid, uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.self_approval_exception(text, uuid, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.approval_level_eligible(smallint, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.approval_deciders(text, text, smallint, uuid, uuid, text, text) FROM authenticated;

-- PAY-REQ-1(2026-09-23):付款申请的内层引擎与算子。**这几支没有调用者检查,靠的就是调不到。**
--   record_payment_internal / reverse_payment_internal —— 原 record_payment / reverse_payment
--     的函数体,拿掉了 require_permission(CFO 批准时要用它们试跑,而 CFO 不持 finance.edit)。
--     留着 authenticated 的 EXECUTE,任何登录用户都能不经申请直接出款 —— 本刀要关的正是这扇门。
--     唯一的外门:record_payment(收款 + 豁免出款)与 pay_payment_request(已批准的申请)。
--   payment_request_dry_run —— 按 id 试跑一张申请再回滚;无检查,只从申请函数体内调用。
--   payment_request_conflict / payment_request_payee_check —— 申请函数体内的两个判断。
--   调用方全部是 SECURITY DEFINER,以属主身份执行,收回之后照常工作。
REVOKE EXECUTE ON FUNCTION public.record_payment_internal(text, uuid, numeric, text, numeric, text, date, text, jsonb, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_payment_internal(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payment_request_dry_run(uuid, date, numeric) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payment_request_conflict(jsonb, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payment_request_payee_check(text, uuid) FROM authenticated;

-- PAY-REQ-1 · Batch B(2026-09-23):行内转账、转账冲销、代扣税缴纳与其冲销的内层引擎。
--   同一条理由:它们拿掉了权限检查(CFO 批准时要用它们试跑,而 CFO 不持 finance.edit),
--   靠的就是调不到。唯一的外门是 pay_payment_request(一张已批准的申请);
--   record_bank_transfer / reverse_bank_transfer / remit_wht 只剩按名拒绝的外壳。
REVOKE EXECUTE ON FUNCTION public.record_bank_transfer_internal(date, text, text, numeric, numeric, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_bank_transfer_internal(uuid, date, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.remit_wht_internal(date, date, text, text, text, numeric) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_wht_remittance_internal(uuid, date, text) FROM authenticated;

-- PAYROLL-APR-1(2026-09-24):工资过账的内层引擎与申请的算子。**这几支没有调用者检查,靠的就是调不到。**
--   post_payroll_period_internal / unpost_payroll_period_internal —— 原 post_payroll_period /
--     unpost_payroll_period 的函数体,拿掉了 require_permission(CFO 批准时要用它们试跑,而 CFO
--     不持 module.hr.edit)。留着 authenticated 的 EXECUTE,任何登录用户都能不经申请直接过账 ——
--     本刀要关的正是这扇门。唯一的外门:post_payroll_period / unpost_payroll_period(要一张已批的申请)。
--   payroll_request_dry_run —— 按 id 试跑一张申请再回滚;只从申请函数体内调用。
--   payroll_period_fingerprint —— 一个期间此刻的那一组数(含逐行摘要),只从申请函数体内调用。
--   ☞ payroll_period_frozen 【不在】此列:调它的是两支 INVOKER 守卫,收回就 42501
--     (period_close_floor 同一条;两处 allowlist 有它)。
REVOKE EXECUTE ON FUNCTION public.post_payroll_period_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.unpost_payroll_period_internal(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_request_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_period_fingerprint(uuid) FROM authenticated;
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22):四支内层函数,没有调用者检查,靠的就是调不到 ——
--   reverse_payroll_payment_internal —— 冲一次工资付款的引擎;外门是 reverse_payroll_payment(要一张批过的申请)与申请的两次试跑。
--   assert_entry_not_bank_matched —— 银行行已配对就按名拒(Q6);只在四支冲销引擎的函数体内调用。
--   payroll_payment_entry_kind —— 从已付的戳认付款种类;只在引擎、路由、付薪页读者(都是 DEFINER)里调用。
--   leave_service_entitlement —— 按服务期给的额度(B1);只在 leave_balance_internal 里调用。
REVOKE EXECUTE ON FUNCTION public.reverse_payroll_payment_internal(uuid, date, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_entry_not_bank_matched(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_payment_entry_kind(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.leave_service_entitlement(text, date, date) FROM authenticated;

-- ROLE-1 Batch 4a(2026-09-25,侧门 (c)):reprice_inbound_batch 是每一条定价路径落进来的那支【引擎】
--   (写 unit_price、price_history,过 purchase 分录)。它留着 authenticated 的 EXECUTE,就是
--   set_inbound_unit_price 之外的第二扇公开的定价门。外门只剩:set_inbound_unit_price ·
--   reprice_from_committed_terms · create_inbound_batch(带价)—— 各问 action.price_receipts ——
--   与 apply_assay_result(action.apply_assay)。引擎自己仍问 data.view_purchase_prices
--   (看不见价格的人不能定价),所以它【有】调用者检查;收回是再加的一道,不是唯一的一道。
REVOKE EXECUTE ON FUNCTION public.reprice_inbound_batch(uuid, numeric, text, numeric, text) FROM authenticated;

-- ROLE-1 Batch 4b(2026-09-25):收货定价申请的内层算子。**这几支没有调用者检查,靠的就是调不到。**
--   receipt_price_submit_internal —— 四扇门(定价面板 · 按承诺条款改价 · 收货台带价 · 应用化验)
--     各问完自己的码才落进来;留着 EXECUTE,任何登录用户都能不经那几扇门直接提申请(或在审批
--     关着时直接过账)。
--   receipt_price_post_internal —— 过账本身(调引擎);只从批准、审批关着时的提交与试跑里调用。
--   receipt_price_request_dry_run · receipt_price_withdraw_internal · receipt_price_fingerprint ·
--   receipt_settled_base —— 只从申请函数体内调用。
--   ☞ receipt_price_open 【不在】此列:调它的是两支 INVOKER 守卫,收回就 42501
--     (payroll_period_frozen 同一条;两处 allowlist 有它)。
REVOKE EXECUTE ON FUNCTION public.receipt_price_submit_internal(uuid, numeric, text, text, uuid, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_price_post_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_price_request_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_price_withdraw_internal(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_price_fingerprint(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_settled_base(uuid) FROM authenticated;

-- ROLE-1 Batch 3a(2026-09-25,Q12):assert_other_decider —— 提单人之外没人批得动时按名拒的那一句断言。
--   只从 SECURITY DEFINER 的提交函数(submit_payroll_request 与六支付款申请提交)里调用;它读
--   approval_deciders(本身已收回),留着 EXECUTE 就是把"谁批得了"这张名单的一个问法敞开。
REVOKE EXECUTE ON FUNCTION public.assert_other_decider(text, text, smallint, text) FROM authenticated;
-- U1-B(2026-10-05):带主角的那一版,同一条理由。
REVOKE EXECUTE ON FUNCTION public.assert_other_decider_for_subject(text, text, smallint, uuid, text) FROM authenticated;

-- APR-5a(2026-09-25):贷项 / 作废申请的内层算子。**这几支没有调用者检查,靠的就是调不到。**
--   void_invoice_internal · create_credit_note_internal —— 原 void_invoice / create_credit_note 的函数体(去掉门);
--     留着 EXECUTE,财务就能不经 CFO 直接作废、直接开贷项,而这正是本刀要关的那一扇。
--   invoice_request_submit_internal —— 两扇提交的门各问完 module.finance.edit 才落进来。
--   invoice_request_post_internal —— 过账本身;只从批准、审批关着时的提交与试跑里调用。
--   invoice_request_dry_run —— 只从提交里调用。
REVOKE EXECUTE ON FUNCTION public.void_invoice_internal(uuid, text, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.create_credit_note_internal(uuid, date, text, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.invoice_request_submit_internal(uuid, text, date, text, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.invoice_request_post_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.invoice_request_dry_run(uuid) FROM authenticated;

-- APR-5b(2026-09-25,grilling Q7):预留的两支内层算子。**没有调用者检查,靠的就是调不到。**
--   release_reservation_internal —— 原 release_reservation 的函数体(去掉门)。两个调用方各自先问:
--     release_reservation(module.sales.edit)· ship_order(action.ship_goods,部分发货先放回多出来的那一截)。
--   reserve_stock_internal —— 原 reserve_stock 的函数体(去掉门)。调用方:reserve_stock(module.sales.edit)·
--     release_reservation_internal(部分释放就地重新预留剩余)。
--   留着 EXECUTE,任何登录用户都能不经销售就改别人订单的预留 —— 而仓库发货正是要够得着这一半、够不着那一半。
REVOKE EXECUTE ON FUNCTION public.release_reservation_internal(uuid, numeric, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reserve_stock_internal(uuid, uuid, numeric, uuid) FROM authenticated;

-- APR-6(2026-09-25,grilling Q1):**人手里过手工凭证的门从 post_journal_entry 换成 submit_journal_request。**
--   post_journal_entry —— 过账核心,INVOKER、本体不问码、收调用方给的任意 source_type。线上调它的 30 支函数
--     全是 SECURITY DEFINER(属主 postgres),在属主身份下执行,不需要 authenticated 的 EXECUTE;而留着它,
--     持 module.finance.edit 的人就能不经 CFO 过一张任意标签的分录(一张 'purchase' 进 2000 · 一笔贷银行)——
--     ROLE1B4A-PURCHASE-JOURNAL-FORGEABLE 与 PAYREQ1-MANUAL-JOURNAL-CREDITS-BANK 两扇门的根。
--   journal_request_submit_internal —— 两扇提交的门各问完 module.finance.edit 才落进来。
--   journal_request_post_internal —— 过账本身;只从批准、审批关着时的提交与试跑里调用。
--   journal_request_dry_run —— 只从提交里调用。**这几支没有调用者检查,靠的就是调不到。**
REVOKE EXECUTE ON FUNCTION public.post_journal_entry(date, text, text, uuid, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.journal_request_submit_internal(text, date, text, jsonb, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.journal_request_post_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.journal_request_dry_run(uuid) FROM authenticated;

-- APR-7(2026-09-25):**注销、回滚、证书作废的门换成了四张申请**(仓库提,CFO 批)。
--   soft_delete_inbound_batch_internal / soft_delete_output_batch_internal / rollback_processing_run_internal ——
--     原来三扇门的函数体(去掉了码的检查)。调用者:空批一步删的两扇门(先问 action.batch_write_off 与
--     "要不要经 CFO")与 warehouse_request_execute_internal。留着 EXECUTE,任何登录用户都能不经 CFO、
--     不经任何码注销一批料或回滚一张加工单 —— 那正是本刀要关的门。
--   warehouse_request_submit_internal —— 四扇提交的门各问完自己的码才落进来。
--   warehouse_request_execute_internal —— 生效本身;只从批准、审批关着时的提交与试跑里调用。
--   warehouse_request_dry_run —— 只从提交里调用。
--   warehouse_request_touches / warehouse_request_freezing / warehouse_request_snapshot —— 三支读者只给上面几支
--     与冻结守卫用;snapshot 会把供应商名、证书号交给任何登录用户。**这几支没有调用者检查,靠的就是调不到。**
REVOKE EXECUTE ON FUNCTION public.soft_delete_inbound_batch_internal(uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.soft_delete_output_batch_internal(uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.rollback_processing_run_internal(uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_submit_internal(text, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_touches(text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_freezing(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_snapshot(text, uuid) FROM authenticated;
-- warehouse_request_conflict / batch_write_off_needs_request:只从两扇一步删的门与提交里调(属主身份);屏幕从
--   warehouse_requests_visible 与批次行自己的数读同一件事,不需要它们。
REVOKE EXECUTE ON FUNCTION public.warehouse_request_conflict(text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.batch_write_off_needs_request(uuid, uuid) FROM authenticated;

-- APR-8(2026-09-26):**合同条款与定价公式的生效换成了一张申请**(cco 提,CFO 批)。
--   terms_request_submit_internal —— 四扇提交的门各问完自己的码才落进来。
--   terms_request_execute_internal —— 生效本身(把条款写进公式并启用 / 把合同改成 active);只从批准、审批关着时的
--     提交与试跑里调用。留着 EXECUTE,任何登录用户都能不经 CFO 让一张公式或一份合同生效 —— 那正是本刀要关的门。
--   terms_request_dry_run —— 只从提交里调用。
--   terms_request_snapshot / terms_request_fingerprint / formula_terms_state / contract_terms_state —— 会把公式的
--     费率与比例、合同的条款交给任何登录用户(公式表的费率列本来只经遮蔽视图读)。**这几支没有调用者检查,靠的就是调不到。**
--   contract_terms_lock_reason 【留着】:两支合同守卫以调用者身份问它;它只说出 active 或那一张在等申请的 label。
REVOKE EXECUTE ON FUNCTION public.terms_request_submit_internal(text, uuid, jsonb, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_snapshot(text, uuid, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_fingerprint(text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.formula_terms_state(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.contract_terms_state(uuid) FROM authenticated;

-- APR-9(2026-09-27):**调薪与固定资产处置换成了申请**(调薪:财务提、CFO 批 / CFO 是当事人时 cco 批;处置:财务提、CFO 批)。
--   salary_change_execute_internal / asset_disposal_execute_internal / dispose_fixed_asset_internal —— 生效本身
--     (改月薪、过处置分录)。留着 EXECUTE,任何登录用户都能不经批准改一个人的月薪或处置一台资产 —— 那正是本刀要关的门。
--   asset_disposal_dry_run —— 只从提交里调用。
--   salary_change_fingerprint / salary_change_open / salary_change_deciders / salary_effective_period_block /
--   pay_decision_code / asset_disposal_fingerprint —— 会交出月薪、账号 ↔ 员工对照或资产成本;
--     **没有调用者检查,靠的就是调不到**。屏幕经 salary_change_requests_visible / asset_disposal_requests_visible /
--     review_approval_code(本来就给)读它们的答案。
REVOKE EXECUTE ON FUNCTION public.salary_change_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.asset_disposal_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.dispose_fixed_asset_internal(uuid, date, numeric, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.asset_disposal_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_change_fingerprint(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_change_open(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_change_deciders(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_effective_period_block(date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.pay_decision_code(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.asset_disposal_fingerprint(uuid) FROM authenticated;

-- APR-10(2026-09-27):**GST 申报换成了申请;采购单按品类开、按开单人或这一类的码改。**
--   gst_filing_execute_internal —— 生效本身(写 gst_return_boxes、期间 → approved)。留着 EXECUTE,任何登录用户都能
--     不经 CFO 批就把一组数定成"批准过的申报"—— 那正是本刀要关的门。
--   assert_po_manager —— 只从五扇改单的门里调(全是 DEFINER);它自己不查调用者之外的任何事,靠的是调不到。
--     屏幕读 po_may_manage(只回读者自己的一个布尔)。
REVOKE EXECUTE ON FUNCTION public.gst_filing_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_po_manager(uuid) FROM authenticated;

-- OVERTIME-1(2026-09-28):三支内层判据只由 DEFINER 的加班函数与 complete_attendance_period 在属主身份下调用。
REVOKE EXECUTE ON FUNCTION public.overtime_approved_hours(date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.overtime_assert_month_open(date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.overtime_other_approver_exists(uuid, uuid[]) FROM authenticated;

-- HISTORY-1(2026-09-28):通用变更记录的内层函数只由 DEFINER 的读法(change_log_rows)、写法(change_log_capture
--   触发器)与匿名化(anonymise_employee)在属主身份下调用。
--   change_log_field —— 按表名动态读【任意一张表】的任意一列:给了 authenticated 就是一扇绕过列级遮蔽的门
--     (以调用者身份跑时列权限仍挡着,但那是第二道;第一道是调不到)。
--   change_log_rule_visible / change_log_task_visible —— 经它们能逐行探测别人的员工 id 与任务归属。
--   change_log_redact_employee —— 唯一能改 change_log 的路;只许 anonymise_employee 走(它自己也查码)。
--   change_log_capture —— 触发器函数,不该被直接调。
--   ☞ change_log_rows / change_log_filters / record_account_event【不收】:各自查 data.view_change_log /
--     action.manage_permissions,屏幕与服务端动作要调它们。change_log_mask_gaps / change_log_coverage_gaps
--     只读目录与常量名单,gate 与 fixture 调它们。
REVOKE EXECUTE ON FUNCTION public.change_log_field(text, jsonb, jsonb, jsonb, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.change_log_rule_visible(text, text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.change_log_task_visible(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.change_log_redact_employee(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.change_log_capture() FROM authenticated;

-- AUDIT-TRAIL-1a(2026-09-29):审计记录的内层函数只由 DEFINER 的读法(record_trail · change_log_rows ·
--   change_log_filters)在属主身份下调用,自己没有调用者检查,靠的就是调不到:
--   change_log_mask_row —— 遮蔽那一步;它调的 change_log_field 能按表名读任意一张表。
--   trail_current_image / trail_ref_label / trail_refs / trail_row_record —— 按表名动态读任意一行(或它最后的影像)。
--   trail_row_visible —— 给了 authenticated 就是一支"任意一行你看不看得见"的探针。
--   trail_actor —— 回答任意一个账号 / 员工 id 是谁(与 account_person 同一个理由)。
--   ☞ record_trail / change_log_find_records【不收】:前者查主语的查看码与根行的读规则,后者查 data.view_change_log。
--     trail_subjects / trail_subject_members / trail_prelog_sources / trail_pk_columns / trail_fk_targets /
--     change_log_began_at 只读常量名单或目录,留着(fixture 与检查脚本会调)。
REVOKE EXECUTE ON FUNCTION public.change_log_mask_row(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_current_image(text, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_ref_label(text, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_refs(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_row_record(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_row_visible(text, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_actor(text, uuid, uuid) FROM authenticated;

-- AUDIT-TRAIL-1d-1(2026-10-04):M12 的门只由 record_trail(属主身份)调用 —— 给了 authenticated 就是一支
--   "这一份评审的审核人是不是你"的探针。M9 / M10 的两张登记表(trail_log_only_tables · trail_member_columns)只读常量,留着
--   (与 trail_subjects 同一个理由:fixture 与检查脚本会调)。save_employee【不收】:它是员工表单的那一次写入,
--   按调用者的身份跑(SECURITY INVOKER),表的策略与守卫照常管。
REVOKE EXECUTE ON FUNCTION public.trail_root_gate(text, text, jsonb) FROM authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ MES-1(2026-10-06):本仓库【第二条】、也是 MES 组里【唯一一条】给 anon 的 EXECUTE ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- 【它是什么】ingest_submit(text, text, jsonb) —— 车间网关唯一够得着的东西(MES-0 Q4,Tim)。网关带着项目的公开 apikey
--   POST /rest/v1/rpc/ingest_submit;它的"权限"是那把 244 位随机的网关钥匙,函数里只比 sha256(MES-0 Q5)。
-- 【它碰得到什么】白名单:只插入收件箱、传输日志与网关中断(两种桶的四个计数列除外),一行设备都不改,不跑转换代码,
--   只回调用者自己的序号与固定的码。函数抬头逐条写着;fixture 249 按事务内的逐表计数证"它只写了这三张"。
-- 【为什么给 anon,不给一个登录角色或一个 Supabase 账号】MES-0 §3.3:authenticated 默认执行每一支函数、44 条策略
--   USING (true) —— 一个登录的网关第一天就读得到内部的表;而 db/check_grants.py 只看 anon,一个登录角色它看不见。
-- ⚠★【必须写在这里,写在本文件第一句 REVOKE 的后面】与 cod_verification 同一个理由:apply_migration.sh 把本文件拼在
--   COMMIT 之前、同一个事务里重跑,一条只写在迁移里的 GRANT 会被那句 REVOKE 冲掉,而迁移报告成功。
GRANT EXECUTE ON FUNCTION public.ingest_submit(text, text, jsonb) TO anon;
-- ★ 而且【只】给 anon(MES-1 Step 0 Q4,Tim):本文件第 31 行把每一支函数授给 authenticated 与 service_role ——
--   给了 authenticated,任何一个登录的人都能冒充网关送数(只要拿得到钥匙)而且绕开网关那条路的全部语义;
--   service_role 是服务端的钥匙,没有一条合法的服务端路径要调它。两个都收回;fixture 249 GRANT 臂两个都断言。
--   ☞ 这两句写在第 31 行【之后】,所以每一次重放都是"先全授、再收回"—— 顺序就是判据。
REVOKE EXECUTE ON FUNCTION public.ingest_submit(text, text, jsonb) FROM authenticated, service_role;

-- MES-1:分派器与转换器是【内层】—— 没有调用者检查,只由 ingest_process_pending / retry_inbox_row(各自查码)以属主身份调。
--   给了 authenticated,就是一支"随便哪一行收件箱都替你转换"的后门,也绕开了处理按钮的那一道码。
REVOKE EXECUTE ON FUNCTION public.ingest_transform_row(bigint) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.transform_connection_test_v1(jsonb) FROM authenticated;

-- MES-2(2026-10-06):四支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   transform_weighing_v1:称重的转换器(分派器与确认按名字调它)。
--   capture_confirm_internal:确认一张草稿(confirm_capture_draft · submit_manual_capture · correct_weighing)。给了 authenticated,
--     就是一支绕开 action.confirm_capture 把草稿写成正式记录的后门。
--   weighbridge_share_internal:把地磅单分一份出去(两支收货函数 · share_weighbridge_ticket)—— 给了,就绕开收货与发货那两个码。
--   assert_receipt_reading_calibrated:校准闸(reprice_inbound_batch · preview_reprice_inbound_batch · issue_cod)。
--   calibration_status_from【不收】:它是一句纯判断(IMMUTABLE,不读任何表),属主视图里由读者的身份执行 —— 收了它,
--   weighing_calibration / instrument_calibration_now 对每一个读者 42501(AGENTS.md「属主视图替得了表,替不了函数的 EXECUTE」)。
REVOKE EXECUTE ON FUNCTION public.transform_weighing_v1(jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.capture_confirm_internal(uuid, jsonb, jsonb, jsonb, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.weighbridge_share_internal(uuid, uuid, uuid, numeric, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_receipt_reading_calibrated(uuid) FROM authenticated;

-- MES-3a(2026-10-06):两支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   receipt_ceiling_check_internal:库存上限的判法与那一行记录(两支收货函数 · create_output_batch)。给了 authenticated,
--     就是一支随手往 receipt_ceiling_checks 里写判法、还能锁执照行的后门。
--   assert_quarantine_landing:隔离闸(两支收货函数 · create_stock_transfer)。
--   quantity_in_tonnes【不收】:一句纯换算(IMMUTABLE),属主视图里由读者的身份执行。
--   storage_licence_in_force【不收】:它是 DEFINER,只回一个 id;storage_ceiling_status 与 pending_values 以读者身份调它。
REVOKE EXECUTE ON FUNCTION public.receipt_ceiling_check_internal(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_quarantine_landing(text[], uuid) FROM authenticated;

-- MES-3b(2026-10-07):三支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   label_object_data:一张标签上印什么(物料名与供应商名以属主身份读 —— Q2 的并入)。给了 authenticated,就是一支绕开 materials /
--     suppliers 的 RLS、按 id 读任何一批物料名与供应商名的后门。调用方:label_print_context。
--   label_print_context:印标签之前的全部判断(种类、查看码、模板、以前印过几次)。调用方:label_print_preview · record_label_print。
--   batch_quarantine_states:一批身上开着的要隔离的状态。调用方:shipment_document · shipping_queue_rows。
--   resolve_scan_code / label_print_preview / record_label_print【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.label_object_data(text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.label_print_context(text, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.batch_quarantine_states(uuid) FROM authenticated;

-- MES-4a(2026-10-07):五支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   assert_run_header:一张新加工单的表头说不说得通(commit_processing_run · correct_run_header;以及 processing_runs 的 INSERT 触发器 ——
--     直连插入早在 guard_processing_direct_write 那一步就按名拒了,触发器只在属主路径上真的跑到它)。
--   assert_run_equipment:这一炉的机器(EQP-2a 的三条 + 工序 ↔ 资产)。调用方:commit_processing_run · correct_run_header。给了 authenticated,
--     就是一支按 id 探 fixed_assets(只给财务读)的后门。
--   record_manual_weighing_internal:在提交那一刻落一条手工称重(收件箱 → 转换 → 草稿 → 确认)。给了,就绕开 action.confirm_capture。
--   record_run_value_internal:给一炉记 / 更正一个值。调用方:commit_processing_run · record_run_value · correct_run_value。给了,就绕开
--     action.processing_aftercare 与"加工单必须已提交"那一句。
--   run_event_check:一件异常事件的五样(record_run_event · correct_run_event)。
--   record_run_value / correct_run_value / record_run_event / correct_run_event / record_run_loss / correct_run_loss / close_run_balance /
--   correct_run_header / create_recipe_version / processing_runs_unclosed_balance【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.assert_run_header(date, timestamp with time zone, timestamp with time zone, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_run_equipment(text, uuid, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.record_manual_weighing_internal(numeric, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.record_run_value_internal(uuid, text, jsonb, text, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.run_event_check(text, timestamp with time zone, numeric, text, text) FROM authenticated;

-- MES-4b(2026-10-07):一支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   contamination_check_internal:一次交叉污染抽检的判据与落库(record_contamination_check · correct_contamination_check)。
--     给了 authenticated,就绕开 action.processing_aftercare,也绕开"只能更正链的末端"那一句。
--   set_batch_cell_construction / record_derived_electrolyte_loss / rederive_electrolyte_loss / record_contamination_check /
--   correct_contamination_check【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   guard_batch_cell_construction 是触发器函数(与其余触发器同一条:EXECUTE 只在被直接调用时才有意义)。
REVOKE EXECUTE ON FUNCTION public.contamination_check_internal(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text, bigint, text) FROM authenticated;

-- MES-5a-1(2026-10-08):四支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   discharge_result_internal:一条放电模组结果的判据与落库(record / correct_discharge_module_result)—— 给了 authenticated,
--     就绕开 action.confirm_capture,也绕开"只能更正链的末端"。
--   discharge_channel_internal:一条通道分配的判据与落库(assign / correct_discharge_channel)—— 绕开 action.processing_aftercare。
--   discharge_verify_batch:按逐模组结论改一批的安全状态 —— 给了 authenticated,任何人都能把一批"核实"成已放电(火闸的另一侧)。
--   create_stock_transfer_internal:库存转移的函数体(create_stock_transfer 判 module.inventory.edit 后转交;拆去隔离判
--     action.processing_aftercare 后转交)—— 给了 authenticated,就绕开库存编辑码。
--   guard_batch_module_count 是 SECURITY DEFINER 的触发器函数(它要数放电结果、读安全状态,不能被 RLS 数成 0);
--     触发器触发时不查 EXECUTE,所以收回它只关掉"被直接调用"那一条路。
--   set_batch_module_count / record_discharge_module_result / correct_discharge_module_result / assign_discharge_channel /
--   correct_discharge_channel / split_failed_modules_to_quarantine【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.discharge_result_internal(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.discharge_channel_internal(uuid, text, uuid, integer, text, boolean, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.discharge_verify_batch(text, uuid, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.create_stock_transfer_internal(numeric, uuid, uuid, uuid, uuid, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_batch_module_count() FROM authenticated;

-- MES-5a-2(2026-10-08):两支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   meter_reading_internal:一条电表读数的判据与落库(record / correct_meter_reading)—— 给了 authenticated,就绕开 action.confirm_capture,
--     也绕开"只能更正链的末端"。
--   electricity_allocation_compute:电费单怎么分(preview / post_electricity_allocation)—— 它自己不写任何东西,但它不查码,
--     而它读的是电表读数、各炉的电量与运行时长、估计的金额(加工成本的金额要 data.view_prices);给了 authenticated 就是一支绕开那道遮蔽的读法。
--   record_meter_reading / correct_meter_reading / preview_electricity_allocation / post_electricity_allocation / set_electricity_shared_pool_rule
--   【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.meter_reading_internal(uuid, timestamp with time zone, numeric, boolean, text, text, boolean, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.electricity_allocation_compute(date, date, numeric, numeric, text, text, text) FROM authenticated;

-- MES-5b-2(2026-10-09):一支【内层】与一支触发器函数。
--   reverse_expense_internal:冲一张费用单的那一段(reverse_expense 与 reverse_electricity_allocation 共用)—— 它不查码;给了 authenticated
--     就是一支绕开 module.finance.edit、也绕开"电费分摊的费用单只许整张撤回"的冲销。
--   guard_electricity_line_one_live_allocation:分摊行的插入守卫(触发器函数;触发时不查 EXECUTE,收掉只是让它不在 API 上)。
--   reverse_electricity_allocation【不收】:它是 DEFINER,自己查码,员工就是要调它。
REVOKE EXECUTE ON FUNCTION public.reverse_expense_internal(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_electricity_line_one_live_allocation() FROM authenticated;

-- MES-5b-3(2026-10-09):一支【内层】与两支触发器函数。
--   blending_plan_write_children:配料计划的判据与落库(create / amend_blending_plan 共用;INVOKER,在它们里面以属主身份跑)—— 它不查码;给了 authenticated
--     就是一支绕开 action.wo_create、也绕开"只有草稿改得动"的写法。
--   guard_blending_run_from_plan · guard_blended_batch_metals_from_assay:触发器函数(触发时不查 EXECUTE,收掉只是让它们不在 API 上;
--     后一支是 DEFINER,更不该在 API 上)。
--   create / amend / release / cancel / execute_blending_plan【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   next_blending_plan_code【不收】:与 next_work_order_code 一样,是一支只读的取号函数(读 document_types 与编号的最大值)。
REVOKE EXECUTE ON FUNCTION public.blending_plan_write_children(uuid, uuid, uuid, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_blending_run_from_plan() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_blended_batch_metals_from_assay() FROM authenticated;

-- MES-6a-1(2026-10-09):一支触发器函数。
--   guard_assay_sample_batch:化验指着的样品必须是同一批的(触发器函数;触发时不查 EXECUTE,收掉只是让它不在 API 上 —— 它是 DEFINER,更不该在)。
--   record_sample / record_sample_event / set_quality_settings / open_assay_dispute / record_dispute_umpire / withdraw_assay_dispute /
--   resolve_assay_dispute / link_dispute_fee【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   next_sample_code【不收】:与 next_blending_plan_code 一样,是一支只读的取号函数。
REVOKE EXECUTE ON FUNCTION public.guard_assay_sample_batch() FROM authenticated;

-- MES-6a-2(2026-10-10):一支触发器函数与一支【内层】。
--   guard_substance_role:定价那几张表只收按含量计价的金属、惩罚条款只收惩罚元素(触发器函数;触发时不查 EXECUTE,收掉只是让它不在 API 上)。
--   payable_metals_only:把一张含量清单里的惩罚元素拿掉(只给那几支 DEFINER 计价读者在体内用;给了 authenticated 也只是一支无害的过滤器,
--     收掉是让 API 上少一支没有屏幕的函数)。
--   record_assay_result 的新签名(尾部多了 p_indicators)【不收】:它是 DEFINER,自己查码,员工就是要调它(上面那一句整体授权覆盖它)。
REVOKE EXECUTE ON FUNCTION public.guard_substance_role() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payable_metals_only(jsonb) FROM authenticated;

-- MES-6b-1(2026-10-15):三支触发器函数与两支【内层】。
--   guard_quality_hold:质量暂扣守在流水上(触发器函数;触发时不查 EXECUTE,收掉只是让它不在 API 上 —— 它是 DEFINER,更不该在)。
--   guard_substance_priced_and_penalised:一种物质在一份合同里要么计价、要么罚(触发器函数,DEFINER)。
--   guard_ncr_mutation:不合格报告只追加(触发器函数)。
--   ncr_open_internal:落一张不合格报告(取号、写一行)—— 不问码、不判来源;给了 authenticated 就是一支绕开 module.quality.edit、
--     也绕开"系统才开 quality_limit"的写法。
--   judge_quality_limits:判一批对一张单的质量验收限并在越限时开报告 —— 不问码;只在 record_assay_result / reserve_stock_internal 里以属主身份跑。
--   open_ncr / decide_ncr【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   batch_quality_hold【不收】:它是 INVOKER,以调用者的读规则读(销售结算的预览以读者身份调它);assay_is_supplement 同理【不收】。
--   next_ncr_code【不收】:与 next_sample_code 一样,是一支只读的取号函数。
REVOKE EXECUTE ON FUNCTION public.guard_quality_hold() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_substance_priced_and_penalised() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_ncr_mutation() FROM authenticated;
-- MES-7b-1:末尾多了 p_incident_id(来源 incident 的那一张指着的事故)—— 签名换了,这一行跟着换。
-- MES-7b-2:末尾又多了 p_inspection_finding_id(来源 inspection 的那一张引用的巡检发现)—— 签名又换了,这一行再跟着换。
REVOKE EXECUTE ON FUNCTION public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid, uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.judge_quality_limits(uuid, uuid, text) FROM authenticated;

-- MES-6b-2(2026-10-15):一支触发器函数与五支【内层】。
--   guard_coa_mutation:分析证书签发之后只许作废、作废之后只许填一次替代品(触发器函数)。
--   coa_governing_assay · coa_output_calibration_problem · coa_issue_blockers · coa_assemble:证书说话的那一份化验、称重的校准、拒绝清单、
--     纸上每一个值 —— 不问码,以属主身份读批次、化验、争议、报告、合同副本与客户名;给了 authenticated 就是一扇绕开 module.output.view
--     读这些的门。外面经 coa_certificate_data(查 module.output.view)与 issue_coa(查 action.issue_coa)读它们。
--   void_coa_internal:作废一张分析证书 —— 只经 CFO 批准的 coa_void 申请走到这里;给了 authenticated 就是一扇绕开 CFO 的作废门。
--   issue_coa / record_coa_issue / submit_coa_void_request / coa_certificate_data【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   next_coa_code【不收】:与 next_ncr_code 一样,是一支只读的取号函数。
REVOKE EXECUTE ON FUNCTION public.guard_coa_mutation() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_governing_assay(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_output_calibration_problem(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_issue_blockers(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_assemble(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.void_coa_internal(uuid, text, uuid) FROM authenticated;
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q3 · Q6):设备记录的内层与触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_downtime_cause · guard_downtime_cause_class · guard_equipment_direct_write:触发器函数(停机的原因与来源 · 被引用的原因类别冻住 ·
--     三张设备表不许绕过函数写)。
--   equipment_record_target · downtime_cause_check:五支设备记录函数共用的两句判据(一台在册的机器 · 一个能用的原因代号)。
--     调用方都是 DEFINER(open_ · close_ · correct_equipment_downtime · record_equipment_maintenance · save_equipment_service_interval),
--     以属主身份读 fixed_assets 与 downtime_causes。
--   那五支、equipment_reliability 与 coa_issuer【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.guard_downtime_cause() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_downtime_cause_class() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_equipment_direct_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.equipment_record_target(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.downtime_cause_check(text) FROM authenticated;
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q12 · Q13 · Q14):备件出库的内层与触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_maintenance_movement · guard_part_issue_write · guard_maintenance_capitalise_parts:触发器函数(两种保养流水只经那两支函数 ·
--     出库记录只可追加、只经函数写 · 还挂着件的保养记录不能资本化)。
--   inbound_batch_maintenance_net_qty:一批出给保养的净数量 —— 只在 reprice_inbound_batch · preview_reprice_inbound_batch ·
--     inventory_control_reconciliation(都是 DEFINER)里被调用;它不问码。
--   issue_spare_parts · return_spare_parts【不收】:它们是 DEFINER,自己查 module.inventory.edit,员工就是要调它们。
--   reprice_split【不收】(签名换成五个入参):纯算术,IMMUTABLE,不读任何表 —— 与它换签名之前一样。
REVOKE EXECUTE ON FUNCTION public.guard_maintenance_movement() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_part_issue_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_maintenance_capitalise_parts() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.inbound_batch_maintenance_net_qty(uuid) FROM authenticated;
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q4 · Q7):事故登记簿的四支触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_incident_kind_code(用过的种类代号冻住)· guard_incident_write(事故写下就不改、只经函数写、来源 / 时刻 / 种类 / 停机 / 事件的行规矩)·
--   guard_incident_update_write(之后的事实只可追加、只经函数写)· guard_incident_batch_write(链接只经函数写、只在解链接那一次改)。
--   record_incident · record_incident_update · link_incident_batch · unlink_incident_batch · suggest_incident_batches · set_safety_settings【不收】:
--   它们是 DEFINER,自己查码(module.safety.edit / module.safety.view),员工就是要调它们。
--   business_days_after · next_incident_code【不收】:一支只读公共假期表的算术、一支只读的取号函数(与 next_ncr_code 一样)。
REVOKE EXECUTE ON FUNCTION public.guard_incident_kind_code() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_incident_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_incident_update_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_incident_batch_write() FROM authenticated;
-- MES-7b-2(2026-10-16,MES-7b Step 0 Q13 · Q14 · Q16):巡检与环境监测的四支触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_inspection_template_write(清单与检查项只经函数写、清单不许删)· guard_inspection_record_write(巡检 / 结果 / 发现 / 关闭交了就不改、
--   只经函数写、发现只挂在不合格的那一项上)· guard_environmental_parameter_code(限值成对、用过的代号冻住)· guard_environmental_result_write
--   (结果只追加、只经函数写、采样日不在未来)。
--   save_inspection_template · record_inspection_run · record_inspection_finding · close_inspection_finding · raise_inspection_finding_task ·
--   record_environmental_result【不收】:它们是 DEFINER,自己查码(module.safety.edit / module.safety.view),员工就是要调它们。
--   next_inspection_code【不收】:一支只读的取号函数(与 next_incident_code 一样)。
REVOKE EXECUTE ON FUNCTION public.guard_inspection_template_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_inspection_record_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_environmental_parameter_code() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_environmental_result_write() FROM authenticated;
-- MES-8a(2026-10-16,MES-8 Step 0 Q2 · Q5 · Q7):三支触发器函数与一支内层 —— 没有调用者检查,靠的就是调不到。
--   guard_supplier_scorecard_review_write(评审只追加)· guard_supplier_statement_write(签发了的对账单只许被取代)·
--   guard_supplier_statement_issue_write(签发档只追加)·
--   supplier_grade_advice_internal(等级建议的那一份实现;create_purchase_order 调它,对外的是 supplier_grade_advice,查 module.suppliers.view)。
--   supplier_scorecard_measures · supplier_scorecard_preview · record_supplier_review · set_supplier_score_settings · supplier_grade_advice ·
--   supplier_statement_data · issue_supplier_statement · record_supplier_statement_issue【不收】:它们是 DEFINER,自己查码。
--   supplier_scorecard_measure_keys · supplier_scorecard_grade · next_supplier_statement_code【不收】:纯函数 / 取号,不读不写别人的东西。
REVOKE EXECUTE ON FUNCTION public.guard_supplier_scorecard_review_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_supplier_statement_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_supplier_statement_issue_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.supplier_grade_advice_internal(uuid, jsonb, numeric) FROM authenticated;
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q10 · Q12 · Q14–Q17):两支触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_compliance_pack_write(冻下来的包只许被取代)· guard_compliance_pack_issue_write(签发档只追加)。
--   inbound_batch_margin · inventory_metal_exposure · compliance_pack_data · freeze_compliance_pack · record_compliance_pack_issue ·
--   set_compliance_settings · compliance_pack_month_status【不收】:它们是 DEFINER,自己查码。
REVOKE EXECUTE ON FUNCTION public.guard_compliance_pack_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_compliance_pack_issue_write() FROM authenticated;
-- MES-8b-2(2026-10-17,MES-8 Step 0 Q19 · Q20):本刀没有要收的函数 —— floor_board · set_floor_board_settings · session_is_floor_display_only 是 DEFINER,
--   自己查码(session_is_floor_display_only 只读调用者自己的授权,所以对每一个登录的人开放);floor_board_arms 是纯函数,不读任何表。

-- ════════════════════════════════════════════════════════════════════════════
-- MES-9a(2026-10-19,MES-9 Step 0 Q2 · Q3 · Q11 · Q27,Tim):【供应商门户】—— 三类函数,三种授法。
-- ════════════════════════════════════════════════════════════════════════════
-- ① 门户会话调的(portal_me · portal_export_my_data):【只】授 supplier_portal。authenticated 与 service_role 从第 31 行那一句拿到的收回 ——
--    一个员工会话(或 hook 被关掉之后拿着 authenticated 令牌的门户账号)调它们是 42501,门户看得见地停下(Q11)。
--    supplier_portal 能执行的每一支都在 db/portal-grants-baseline.tsv 里(判词八,两侧逐条相等);fixture 275 对其中每一支跑两家供应商。
REVOKE EXECUTE ON FUNCTION public.portal_me() FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_export_my_data() FROM authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_me() TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_export_my_data() TO supplier_portal;
-- ② 内层判据 portal_require_link:谁都不授 —— 只由 ① 在它们自己的 DEFINER 体内调用(属主身份)。
REVOKE EXECUTE ON FUNCTION public.portal_require_link() FROM authenticated, service_role;
-- ③ access token hook:只授 supabase_auth_admin(Supabase Auth 调它的那个身份)。它对每一个人的每一次签发都跑,
--    authenticated / anon / service_role 都没有理由调它。
REVOKE EXECUTE ON FUNCTION public.portal_access_token_hook(jsonb) FROM authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_access_token_hook(jsonb) TO supabase_auth_admin;
-- 员工那一侧的(portal_user_create_link · portal_user_revoke · portal_contact_anonymise · portal_actor_labels · set_account_setting)
--   照第 31 行授给 authenticated —— 它们是 DEFINER,自己查码(action.manage_portal_users / action.manage_permissions)或会话(auth.uid())。
-- ④ MES-9b(2026-10-19,MES-9 Step 0 Q14 · Q22):供应商看得见什么 —— 四支,同 ① 的授法:【只】授 supplier_portal。
--    portal_documents · portal_deliveries(清单,只读)· portal_document_open(写调用者自己的一行下载记录,交出路径与哈希)·
--    portal_can_read_object(storage.objects 上那条 TO supplier_portal 的读策略的判据 —— 策略以调用者身份求值,所以门户角色要执行得到它)。
--    fixture 276 对其中每一支跑两家供应商;判词八逐条比基线。
REVOKE EXECUTE ON FUNCTION public.portal_documents() FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_deliveries() FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_document_open(text, uuid) FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_can_read_object(text, text) FROM authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_documents() TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_deliveries() TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_document_open(text, uuid) TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_can_read_object(text, text) TO supplier_portal;
-- ⑤ MES-9c(2026-10-20,MES-9 Step 0 §5 · Q19 · V39):门户交证书 —— 五支,同 ① 的授法:【只】授 supplier_portal。
--    portal_certificates(清单与 V39)· portal_submission_begin(先按 V39 判,登记一行 uploading)· portal_submission_finish(字节到了 → 等审核)·
--    portal_submission_abandon(没传成 → 收回)· portal_can_upload_object(portal-uploads 上两条 TO supplier_portal 策略的判据)。
--    fixture 277 对其中每一支跑两家供应商;判词八逐条比基线。员工审核那两支(portal_submission_accept · _reject)照第 31 行授给
--    authenticated —— DEFINER,自己查 module.suppliers.edit(Q19)。
REVOKE EXECUTE ON FUNCTION public.portal_certificates() FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_submission_begin(text, text, text, bigint, text, date, date) FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_submission_finish(uuid) FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_submission_abandon(uuid) FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_can_upload_object(text, text) FROM authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_certificates() TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_submission_begin(text, text, text, bigint, text, date, date) TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_submission_finish(uuid) TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_submission_abandon(uuid) TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_can_upload_object(text, text) TO supplier_portal;

-- ════════════════════════════════════════════════════════════════════════════
-- F16(MES-7b-2,2026-10-16,Tim):【视图一律不可写】—— 收回 anon / authenticated(与 PUBLIC)在 public 里【每一张视图】上的
--   INSERT · UPDATE · DELETE · TRUNCATE。
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么】平台的默认权限把 arwdDxtm 授给每一个新建的关系,视图也一样;而一张【简单】的属主权限视图是可以自动更新的 ——
--   写穿它,对基表用的是【视图属主】的权限,RLS 不按调用者判。MES-7b-1 量到 163 张视图对 authenticated 带着写授权
--   (MES7B1-VIEW-DEFAULT-WRITE-GRANTS);MES-7b-2 在线上以一个不持任何码的一次性账号量:45 张视图收下了一句零行的写
--   (db/scripts/2026-10-16-mes7b2-view-writes.mjs)。应用与 db/ 里没有一处写穿视图(F16 第 2 步的勘察,交回报告里逐条列着)。
-- 【为什么住在这个文件里】这个文件在重建的最后一步跑(视图都建好了),而 db/apply_migration.sh 在【每一支迁移的同一个事务里】再跑它一遍 ——
--   于是"以后的视图也拿不到写授权"不靠任何人记得:一支迁移建了一张新视图,它提交的那一刻这一段已经把写授权收回了。
--   ★ 那正是委托书"默认权限也要改"那一句要的结果。PostgreSQL 的 ALTER DEFAULT PRIVILEGES 分不出视图与表(对象类型只有 TABLES 一种),
--     在线上把它改成"不授写"会让【以后的每一张新表】也拿不到 authenticated 的写 —— 而 303 份表镜像里 273 份靠的就是那条默认授权,
--     重建库(prelude 照旧按默认授)与线上会在每一张新表上悄悄分开。所以本刀【不改】默认权限,改用这一段 + gate 的 viewwrite 断言
--     (线上与重建两侧都问:任何一张视图对 anon / authenticated 带写授权就红)。
-- 【幂等】对一张没有写授权的视图 REVOKE 是空操作;跑两遍不改任何 relacl。
DO $f16$
DECLARE
    v record;
BEGIN
    FOR v IN SELECT c.oid::regclass AS rel
               FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'public' AND c.relkind = 'v'
              ORDER BY c.relname LOOP
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON %s FROM PUBLIC, anon, authenticated', v.rel);
    END LOOP;
END
$f16$;

-- ★ SYSTEM-MAP-2(2026-10-27):self_approval_allows 是 forbid_self_approval 的判据(从它搬出来的),经 self_leg /
--   self_approval_exception 去问(两者都已收回)—— 与它们同一条理由收回。waiting_decisions / waiting_mine /
--   waiting_decision_reach 【不收】:它们是 SECURITY DEFINER,只答【调用者自己】(auth.uid() / current_user_employee()),
--   operations_now(属主视图)调用 waiting_decisions,而视图里的函数按读者判 EXECUTE。
REVOKE EXECUTE ON FUNCTION public.self_approval_allows(uuid, uuid, text, uuid) FROM authenticated;

-- GOLIVE-2(Tim 2026-10-30 Q5):结算的算术只由 record_sale_settlement(SECURITY DEFINER,先问 module.customers.edit,不持 data.view_prices
--   时把六样钱读成受限)调用。它自己是 SECURITY INVOKER、没有价格码的判断 —— 留着 authenticated 的 EXECUTE,任何登录用户都能直接调它,
--   绕过 sales_settlements_masked 拿到结算金额(app / lib 里没有任何一处调它)。收回之后它照常在 record_sale_settlement 的函数体里以属主身份跑。
REVOKE EXECUTE ON FUNCTION public.sale_settlement_compute(uuid, uuid, uuid) FROM authenticated;

SELECT 'PROOF|B|postgres|' || json_build_object(
  'seven_grants', (SELECT count(*) || ' ' || md5(string_agg(r.code || '/' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code IN ('admin','cco','cfo','cto','finance','gm','warehouse')),
  'user_roles', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.user_roles t),
  'change_log', (SELECT count(*) || ' max ' || max(seq) FROM public.change_log),
  'contracts', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contracts t), 'contract_document_terms', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.contract_document_terms t), 'terms_requests', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.terms_requests t),
  'sales_settlements', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.sales_settlements t), 'cod_issues', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.cod_issues t),
  'anon_relations', (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r','v','m','p','f')
                       AND has_table_privilege('anon', c.oid, 'SELECT')),
  'auth_reads_copy_pricing', has_column_privilege('authenticated', 'public.contract_document_terms', 'pricing_terms', 'SELECT'),
  'auth_reads_copy_settlement', has_column_privilege('authenticated', 'public.contract_document_terms', 'settlement_terms', 'SELECT'),
  'auth_reads_copy_code', has_column_privilege('authenticated', 'public.contract_document_terms', 'contract_code', 'SELECT'),
  'anon_any_on_copy', has_table_privilege('anon', 'public.contract_document_terms', 'SELECT,INSERT,UPDATE,DELETE'),
  'auth_reads_tr_snapshot', has_column_privilege('authenticated', 'public.terms_requests', 'snapshot', 'SELECT'),
  'auth_reads_tr_label', has_column_privilege('authenticated', 'public.terms_requests', 'label', 'SELECT'),
  'auth_exec_compute', has_function_privilege('authenticated', 'public.sale_settlement_compute(uuid,uuid,uuid)', 'EXECUTE'),
  'auth_exec_record', has_function_privilege('authenticated', 'public.record_sale_settlement(uuid,uuid,uuid)', 'EXECUTE'),
  'new_functions', (SELECT string_agg(proname, ',' ORDER BY proname) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                      AND proname IN ('change_log_page','change_log_count','dictionary_usage_counts','contract_copy_price_visible','trail_subject_member_map','trail_subject_root_map')),
  'new_views', (SELECT string_agg(relname, ',' ORDER BY relname) FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname IN ('contract_document_terms_masked','terms_requests_masked')),
  'txid_index', (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'idx_change_log_txid'),
  'inlined_constants', (SELECT string_agg(proname || '=' || coalesce(array_to_string(proconfig, ';'), 'none'), ',' ORDER BY proname) FROM pg_proc
                          WHERE pronamespace = 'public'::regnamespace AND proname IN ('trail_subjects','trail_subject_members','trail_log_only_tables','change_log_mask_rules')))::text;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|B|cfo|old|' || (SELECT count(*) || ' rows ' || md5(coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.seq)::text, ''))
     FROM public.change_log_rows(p_by_entry => true, p_limit => 21) x);
SELECT 'PROOF|B|cfo|new|' || (SELECT count(*) || ' rows ' || md5(coalesce(jsonb_agg(e ORDER BY (e ->> 'seq')::bigint)::text, ''))
     FROM jsonb_array_elements(public.change_log_page(p_entries => 21) -> 'rows') e);
SELECT 'PROOF|B|cfo|count7d|' || public.change_log_count(p_from => (now() AT TIME ZONE 'Asia/Singapore')::date - 6, p_to => (now() AT TIME ZONE 'Asia/Singapore')::date);
SELECT 'PROOF|B|cfo|dict|' || (SELECT count(*) FROM jsonb_object_keys(public.dictionary_usage_counts('[{"ref_table": "assay_result_metals", "ref_column": "metal"}, {"ref_table": "blending_plan_targets", "ref_column": "metal"}, {"ref_table": "contract_grade_specs", "ref_column": "metal"}, {"ref_table": "contract_penalty_elements", "ref_column": "substance"}, {"ref_table": "contract_pricing_terms", "ref_column": "metal"}, {"ref_table": "contract_refining_charges", "ref_column": "metal"}, {"ref_table": "inbound_batch_metals", "ref_column": "metal"}, {"ref_table": "material_required_metals", "ref_column": "metal"}, {"ref_table": "metal_prices", "ref_column": "metal"}, {"ref_table": "output_batch_metals", "ref_column": "metal"}, {"ref_table": "pricing_formula_history", "ref_column": "metal"}, {"ref_table": "pricing_formula_metals", "ref_column": "metal"}, {"ref_table": "pricing_term_commitment_metals", "ref_column": "metal"}, {"ref_table": "materials", "ref_column": "chemistry"}, {"ref_table": "materials", "ref_column": "kind_code"}, {"ref_table": "inbound_batch_safety_states", "ref_column": "safety_state_code"}, {"ref_table": "assay_results", "ref_column": "lab_name"}, {"ref_table": "inbound_batches", "ref_column": "source_reason_code"}, {"ref_table": "materials", "ref_column": "nea_waste_category_code"}, {"ref_table": "licence_storage_limits", "ref_column": "category_code"}, {"ref_table": "materials", "ref_column": "dg_code"}, {"ref_table": "label_prints", "ref_column": "template_code"}, {"ref_table": "processing_runs", "ref_column": "shift_code"}, {"ref_table": "shift_handovers", "ref_column": "shift_code"}, {"ref_table": "processing_run_events", "ref_column": "event_type_code"}, {"ref_table": "inbound_batches", "ref_column": "cell_construction_code"}, {"ref_table": "output_batches", "ref_column": "cell_construction_code"}, {"ref_table": "contamination_checks", "ref_column": "stream_code"}, {"ref_table": "equipment_downtime", "ref_column": "cause_code"}, {"ref_table": "incidents", "ref_column": "kind_code"}, {"ref_table": "environmental_results", "ref_column": "parameter_code"}, {"ref_table": "assay_result_indicators", "ref_column": "indicator"}]'::jsonb)));
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"c8116e6c-80db-4a16-be12-24fb6ce6859d","role":"authenticated"}', true) \g /dev/null
DO $w$ BEGIN PERFORM public.change_log_page(p_entries => 21); RAISE NOTICE 'PROOF|B|warehouse|change_log_page READ (should have refused)';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PROOF|B|warehouse|refused %', split_part(SQLERRM, '|', 1); END $w$;
RESET ROLE;
ROLLBACK;
