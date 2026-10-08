-- db/scripts/2026-10-08-mes5a2-live-readings.sql
-- MES-5a-2 · 线上的前后读数 —— 只读,以 postgres(rolbypassrls = true)读【基表】。迁移前跑一次、全部验证之后跑一次,逐行比。
--   ① 逐表指纹:与 2026-10-06-mes1-live-readings.sql 同一支查询(一行一张 public 基表:行数 + 每一行 md5 的 md5;change_log 另算)。
--      本刀让【一张】既有表的一行变:accounts 的 6200 is_system false → true(迁移自己做的,Q25 · 决定记在交回里)。
--      所以另给 accounts 一行"去掉 is_system 的整行"指纹 —— 本意是前后逐字相同。★ 实测它【变了】:accounts 的 touch 触发器
--      同时改了那一行的 updated_at(change_log seq 18917,changed_columns = is_system, updated_at)—— 这一格少去掉了一列;
--      照跑过的样子留着(它就是交回里那两份读数的出处),解释记在 docs/handbacks/MES-5a-2.md §6.3 与 §8。四张新表在之后那一份里多出来:
--      electricity_settings 1 行(迁移自己种的,规则为空),其余三张 0 行。
--   ② 本刀在线上【什么都不设】:没有电表、没有读数、没有分摊、V25 为空;require_calibrated_since 为 NULL(新表不在时印 n/a)。
--   ③ 汇总:账号与停用数、一次性账号数、审批开关、待批单据;通知的条数(没有一条消息离开数据库)。
--   对账(应收 / 应付 unexplained)另由 2026-10-05-at1d3-live-recon.sql 以 tim@ 的会话读(那支函数按读者的码过滤)。
--   ★ 用 query_to_xml 而不是 DO 块:Management API 不回 NOTICE,一次 SELECT 把每一行读数都带回来。
SELECT c.relname AS tbl,
       (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', c.relname), false, true, '')))[1]::text AS n,
       left((xpath('/row/d/text()', query_to_xml(format(
           'SELECT md5(COALESCE(string_agg(md5(x::text), '''' ORDER BY md5(x::text)), '''')) AS d FROM public.%I x', c.relname),
           false, true, '')))[1]::text, 12) AS digest
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'public' AND c.relkind = 'r' AND c.relname <> 'change_log'
UNION ALL
SELECT '~accounts minus is_system', (SELECT count(*)::text FROM accounts),
       left(md5(COALESCE((SELECT string_agg(md5((to_jsonb(x) - 'is_system')::text), '' ORDER BY md5((to_jsonb(x) - 'is_system')::text)) FROM accounts x), '')), 12)
UNION ALL
SELECT '~system accounts', (SELECT count(*)::text FROM accounts WHERE is_system), (SELECT '6200 is_system=' || is_system FROM accounts WHERE code = '6200')
UNION ALL
SELECT '~change_log', (SELECT count(*) || ' rows, max seq ' || max(seq) FROM change_log), ''
UNION ALL
SELECT '~summary',
       (SELECT count(*) || ' accounts · ' || count(*) FILTER (WHERE banned_until > now()) || ' disabled · '
               || count(*) FILTER (WHERE email LIKE '%@test.local') || ' throwaway' FROM auth.users)
       || ' · approvals ' || (SELECT CASE WHEN approvals_enabled THEN 'ON' ELSE 'OFF' END FROM finance_settings),
       (SELECT count(*) || ' notifications' FROM notifications)
UNION ALL
SELECT '~accounts', (SELECT string_agg(u.email || '=' || COALESCE((SELECT string_agg(r.code, '+' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                                                                    WHERE ur.user_id = u.id AND ur.revoked_at IS NULL), '-')
                                       || CASE WHEN u.banned_until > now() THEN '(DISABLED)' ELSE '' END, ' · ' ORDER BY u.email) FROM auth.users u), ''
UNION ALL
SELECT '~probe leftovers', (SELECT count(*) || ' auth / ' FROM auth.users WHERE email LIKE 'mes5a2probe-%')
       || (SELECT count(*) || ' roles / ' FROM roles WHERE code LIKE 'probe-mes5a2probe-%')
       || (SELECT count(*) || ' ZZ-PROBE-MES5A2 rows' FROM (SELECT code FROM suppliers WHERE code LIKE 'ZZ-PROBE-MES5A2%' UNION ALL
                                                           SELECT code FROM materials WHERE code LIKE 'ZZ-PROBE-MES5A2%' UNION ALL
                                                           SELECT code FROM fixed_assets WHERE code LIKE 'ZZ-PROBE-MES5A2%' UNION ALL
                                                           SELECT code FROM operation_types WHERE code = 'zz_probe_mes5a2') z), ''
UNION ALL
SELECT '~energy', 'meters ' || (SELECT count(*) FROM devices WHERE kind = 'meter')
       || ' · readings ' || COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN to_regclass('public.meter_readings') IS NOT NULL
              THEN 'SELECT count(*) AS n FROM meter_readings' ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?')
       || ' · allocations ' || COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN to_regclass('public.electricity_allocations') IS NOT NULL
              THEN 'SELECT (SELECT count(*) FROM electricity_allocations) || ''/'' || (SELECT count(*) FROM electricity_allocation_lines) AS n' ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?')
       || ' · V25 ' || COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN to_regclass('public.electricity_settings') IS NOT NULL
              THEN 'SELECT count(*) || '' row, rule '' || COALESCE(max(shared_pool_rule), ''NULL'') AS n FROM electricity_settings' ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?'),
       'require_calibrated_since ' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL')
       || ' · electricity lines live/estimates open/relieved/remitted ' || (SELECT count(*) FILTER (WHERE deleted_at IS NULL) || '/'
              || count(*) FILTER (WHERE deleted_at IS NULL AND is_estimate AND relieved_at IS NULL) || '/' || count(*) FILTER (WHERE relieved_at IS NOT NULL)
              || '/' || count(*) FILTER (WHERE remitted_at IS NOT NULL) FROM processing_cost_entries WHERE cost_type = 'electricity')
UNION ALL
SELECT '~pending', (SELECT count(*) || ' pending' FROM approval_pending_documents()),
       (SELECT COALESCE(string_agg(subject_type || ':' || code || ':' || amount_base, ' · ' ORDER BY code), '-') FROM approval_pending_documents())
ORDER BY 1;
