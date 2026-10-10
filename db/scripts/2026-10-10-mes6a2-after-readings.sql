-- db/scripts/2026-10-10-mes6a2-after-readings.sql
-- MES-6a-2 · 只读读数(开场之后、线上证明前后各读一次)—— BEGIN READ ONLY … ROLLBACK,以 postgres(rolbypassrls)读基表。
--   ① 物质与它们的 role;② 本刀与我的证明在线上留下了什么(指标值 · 惩罚元素 · F / Cl 含量 · ZZ-PROBE-MES6A2 · mes6a2probe 账号与角色);
--   ③ 七个账号、角色、停用;审批;require_calibrated_since;目录与 admin;在途单据;
--   ④ 开场以来(change_log seq > 30694,开场读数 2026-10-10 10:37:25 CST)每一行变更,按表 · 操作 · 谁(账号邮箱 / 无会话)归组 ——
--      在册的行有没有被改,由这一段回答(8 张豁免表不记,另由 ⑤ 的指纹回答);
--   ⑤ 每一张 public 基表的行数与内容指纹(md5,按 to_jsonb 文本排序)—— 证明前后各存一份,比对两份。
-- 用法:psql "<live dsn>" -X -v ON_ERROR_STOP=1 -v tag=<before|after> -f db/scripts/2026-10-10-mes6a2-after-readings.sql
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user);
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST|' || :'tag';
SELECT 'SUBSTANCE|' || code || '|' || name_en || '|' || name_zh || '|' || COALESCE(symbol, '-') || '|sort=' || sort_order || '|active=' || is_active || '|role=' || role
  FROM substances ORDER BY sort_order;
SELECT 'INDICATOR|' || code || '|' || name_en || '|' || unit || '|active=' || is_active FROM assay_indicators ORDER BY sort_order;
SELECT 'LEFT|indicator values=' || (SELECT count(*) FROM assay_result_indicators)
    || '|penalty elements=' || (SELECT count(*) FROM contract_penalty_elements)
    || '|F/Cl contents=' || ((SELECT count(*) FROM assay_result_metals WHERE metal IN ('f', 'cl')) + (SELECT count(*) FROM output_batch_metals WHERE metal IN ('f', 'cl'))
                             + (SELECT count(*) FROM inbound_batch_metals WHERE metal IN ('f', 'cl')) + (SELECT count(*) FROM material_required_metals WHERE metal IN ('f', 'cl')))
    || '|F/Cl on price paths=' || ((SELECT count(*) FROM metal_prices WHERE metal IN ('f', 'cl')) + (SELECT count(*) FROM pricing_formula_metals WHERE metal IN ('f', 'cl'))
                             + (SELECT count(*) FROM contract_pricing_terms WHERE metal IN ('f', 'cl')) + (SELECT count(*) FROM contract_refining_charges WHERE metal IN ('f', 'cl')))
    || '|contracts=' || (SELECT count(*) FROM contracts)
    || '|assays=' || (SELECT count(*) FROM assay_results)
    || '|probe rows=' || ((SELECT count(*) FROM suppliers WHERE code LIKE 'ZZ-PROBE-MES6A2%') + (SELECT count(*) FROM customers WHERE code LIKE 'ZZ-PROBE-MES6A2%')
                          + (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES6A2%') + (SELECT count(*) FROM contracts WHERE title LIKE 'ZZ-PROBE-MES6A2%'))
    || '|mes6a2probe accounts=' || (SELECT count(*) FROM auth.users WHERE email LIKE 'mes6a2probe-%')
    || '|throwaway accounts=' || (SELECT count(*) FROM auth.users WHERE email LIKE '%@test.local')
    || '|probe roles=' || (SELECT count(*) FROM roles WHERE code LIKE 'probe-%');
SELECT 'S|approvals_on=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '?') || '|l2=' || COALESCE(approval_level2_role_code, '?')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '?')
    || '|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL')
    || '|catalogue=' || (SELECT count(*) FROM permissions)
    || '|admin=' || (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin') FROM finance_settings;
SELECT 'ACCOUNT|' || u.email || '|' || COALESCE(string_agg(r.code || '(' || (SELECT count(*) FROM role_permissions rp WHERE rp.role_id = r.id) || ')', ',' ORDER BY r.code), '-')
    || '|banned=' || COALESCE(u.banned_until::text, 'no') || '|deleted=' || COALESCE(u.deleted_at::text, 'no')
  FROM auth.users u LEFT JOIN user_roles ur ON ur.user_id = u.id LEFT JOIN roles r ON r.id = ur.role_id
 WHERE u.email NOT LIKE '%@test.local' GROUP BY u.email, u.banned_until, u.deleted_at ORDER BY u.email;
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(subject_type || ':' || code || ':' || amount_base, ',' ORDER BY code), '') FROM approval_pending_documents();
SELECT 'LOG|since seq 30694|' || c.table_name || '|' || c.op || '|' || COALESCE(u.email, c.actor_kind || '/' || c.db_role) || '|n=' || count(*)
    || '|first=' || to_char(min(c.occurred_at) AT TIME ZONE 'Asia/Singapore', 'HH24:MI:SS') || '|last=' || to_char(max(c.occurred_at) AT TIME ZONE 'Asia/Singapore', 'HH24:MI:SS')
  FROM change_log c LEFT JOIN auth.users u ON u.id = c.actor_account
 WHERE c.seq > 30694 GROUP BY c.table_name, c.op, COALESCE(u.email, c.actor_kind || '/' || c.db_role) ORDER BY min(c.seq);
SELECT 'LOG|max seq=' || max(seq) || '|rows=' || count(*) FROM change_log;
DO $d$
DECLARE r record; n bigint; h text;
BEGIN
    FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
              WHERE s.nspname = 'public' AND c.relkind = 'r' AND c.relname <> 'change_log' ORDER BY c.relname LOOP
        EXECUTE format('SELECT count(*), md5(COALESCE(string_agg(to_jsonb(t)::text, %L ORDER BY to_jsonb(t)::text), %L)) FROM public.%I t', '|', '', r.relname) INTO n, h;
        RAISE NOTICE 'DIGEST|%|%|%', r.relname, n, h;
    END LOOP;
END
$d$;
ROLLBACK;
SELECT 'READ_OWN_EXIT_HINT|done';
