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
        ('notification_reads', 'Per-viewer "seen" marks on notifications; screen state with no business meaning.');
$function$;
