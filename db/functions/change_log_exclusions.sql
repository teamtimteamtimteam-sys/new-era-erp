-- db/functions/change_log_exclusions.sql
-- HISTORY-1(Tim 的 Q5):不挂变更记录触发器的表 —— 【唯一】的一份名单,每一条带理由。
--
-- 三处读它,所以它只能有一份:
--   · change_log_coverage_gaps() —— gate 的 changelog 那一行(线上 + 重建)与 fixture 234;
--   · scripts/check-change-log-coverage.mjs —— 构建里的静态检查,从本文件的 VALUES 里读;
--   · db/scripts/gen_change_log_bindings.py —— 生成绑定清单时跳过这几张。
-- ★ 规矩(docs/change-log.md):新建的每一张 public 表,要么在 db/views/zzz_change_log_triggers.sql
--   里有两条绑定,要么在这里有一行带理由的豁免。两者都没有,构建与 gate 都会红。
-- ★ MES-1(2026-10-06,MES-0 Q14,Tim):第二种被接受的豁免 —— 【采集层的三份日志】(收件箱 · 传输日志 · 网关中断)。
--   它们本身就是只追加的日志(守卫按名拒改与删);再记一遍是把规格 §2.1 警告的量翻一倍,而不多一个事实。
--   状态的变化记在行上(收件箱的 attempts · last_attempt_* · discarded_*)。
-- ★ MES-9b(2026-10-19,MES-9 Step 0 Q22,Tim):第九张 —— 门户下载记录(portal_document_downloads)。同一类:它本身就是一份只追加的日志
--   (守卫按名拒改、删、清空),每一行就是一个事实;再记一遍是把量翻一倍而不多一个事实。豁免 8 → 9。
-- ★ TABLE-FEATURES-3(2026-10-26,Tim Q3):第十张 —— 保存的视图(saved_views)。与 notification_reads 同一类:每个读者自己的屏幕偏好,
--   没有业务含义。豁免 9 → 10。
-- ★ ESG-2(2026-10-31,Tim Q13):第十一、十二张 —— 两张举报表(whistleblowing_reports · whistleblowing_updates)。不同的一类:
--   变更记录会把每一行的【操作人】印给持 data.view_change_log 的人(admin · cfo · auditor),那就把「谁交了举报」交了出去;
--   而这两张表本身只追加(守卫按名拒改、删、清空)、每一行自带谁在何时。举报的内容与交的人只在举报页上给它的读者。豁免 10 → 12。
CREATE OR REPLACE FUNCTION public.change_log_exclusions()
 RETURNS TABLE(table_name text, reason text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    VALUES
        ('change_log'::text, 'The change log itself; a trigger on it would record its own writes.'::text),
        ('festival_doodles', 'Home-screen holiday artwork; screen decoration with no business meaning.'),
        ('gateway_outages', 'Ingestion log (MES-1): itself an append-only record of gateway silences; logging it again doubles the volume and adds no fact.'),
        ('home_greetings', 'Home-screen greeting text; screen decoration with no business meaning.'),
        ('ingest_inbox', 'Ingestion log (MES-1): itself an append-only landing table; its status changes are recorded on the row (attempts, last attempt, discard).'),
        ('ingest_transmissions', 'Ingestion log (MES-1): itself an append-only log of every gateway call; logging it again doubles the volume and adds no fact.'),
        ('notification_reads', 'Per-viewer "seen" marks on notifications; screen state with no business meaning.'),
        ('saved_views', 'Per-user saved list views (TABLE-FEATURES-3, Tim Q3): a reader''s own screen preference with no business meaning.'),
        ('portal_document_downloads', 'Supplier portal download log (MES-9b, MES-9 Step 0 Q22): itself an append-only record of every issued document a portal user took; logging it again doubles the volume and adds no fact.'),
        ('whistleblowing_reports', 'Whistleblowing reports (ESG-2, Tim Q13): the change log prints each row''s actor to every change-history reader, which would reveal who filed a report; the table is append-only and carries its own who and when, shown only to the report''s readers.'),
        ('whistleblowing_updates', 'Whistleblowing status updates (ESG-2, Tim Q13): append-only, readable only by the report''s readers; the change log would show their content and actors to every change-history reader.'),
        ('scan_events', 'Scan log (MES-3b): itself an append-only record of every scan resolved on a page; logging it again doubles the volume and adds no fact.');
$function$;
