-- db/scripts/2026-10-06-mes1-live-readings.sql
-- MES-1 · 线上的前后读数 —— 与 2026-10-05-u1b-live-readings.sql 逐字同一支查询(只换了这两行抬头):只读,以 postgres(rolbypassrls = true)读【基表】。
--   迁移前跑一次、全部验证之后跑一次,逐表比;七张新表在之后那一份里多出来,只该有探针网关自己的行(与两张种子表)。
--   一行一张 public 基表:行数 + 每一行的 md5 再 md5(change_log 另算:行数与最大序号,探针的一次性账号会让它长)。
--   再加一行"汇总":账号与停用数、审批开关、待批单据的指纹。对账(应收 / 应付 unexplained)另由
--   2026-10-05-at1d3-live-recon.sql 以 tim@ 的会话读(那支函数按读者的码过滤)。
-- ★ 用 query_to_xml 而不是 DO 块:Management API 不回 NOTICE,一次 SELECT 把每张表的读数都带回来。
SELECT c.relname AS tbl,
       (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', c.relname), false, true, '')))[1]::text AS n,
       left((xpath('/row/d/text()', query_to_xml(format(
           'SELECT md5(COALESCE(string_agg(md5(x::text), '''' ORDER BY md5(x::text)), '''')) AS d FROM public.%I x', c.relname),
           false, true, '')))[1]::text, 12) AS digest
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'public' AND c.relkind = 'r' AND c.relname <> 'change_log'
UNION ALL
SELECT '~summary',
       (SELECT count(*) || ' rows, max seq ' || max(seq) FROM change_log),
       (SELECT count(*) || ' accounts · ' || count(*) FILTER (WHERE banned_until > now()) || ' disabled · '
               || count(*) FILTER (WHERE email LIKE '%@test.local') || ' throwaway' FROM auth.users)
       || ' · approvals ' || (SELECT CASE WHEN approvals_enabled THEN 'ON' ELSE 'OFF' END FROM finance_settings)
       || ' · ' || (SELECT count(*) || ' grants without account' FROM user_roles ur WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = ur.user_id))
UNION ALL
SELECT '~accounts', (SELECT string_agg(u.email || '=' || COALESCE((SELECT string_agg(r.code, '+' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                                                                    WHERE ur.user_id = u.id AND ur.revoked_at IS NULL), '-')
                                       || CASE WHEN u.banned_until > now() THEN '(DISABLED)' ELSE '' END, ' · ' ORDER BY u.email) FROM auth.users u), ''
UNION ALL
SELECT '~pending', (SELECT count(*) || ' pending' FROM approval_pending_documents()),
       (SELECT COALESCE(string_agg(subject_type || ':' || code || ':' || amount_base, ' · ' ORDER BY code), '-') FROM approval_pending_documents())
ORDER BY 1;
