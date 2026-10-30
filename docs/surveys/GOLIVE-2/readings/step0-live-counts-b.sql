-- GOLIVE-2 Step 0 · 线上只读:show=500 要读几行(最新 501 笔事务里的行数)· show=20 · 最近 7 天的行数(以 postgres,基表)
WITH tx AS (SELECT txid, max(seq) mx FROM change_log GROUP BY txid ORDER BY 2 DESC LIMIT 501)
SELECT 'PROOF|rows in newest 501 operations=' || (SELECT count(*) FROM change_log WHERE txid IN (SELECT txid FROM tx))
    || ' · newest 21=' || (SELECT count(*) FROM change_log WHERE txid IN (SELECT txid FROM tx ORDER BY mx DESC LIMIT 21))
    || ' · last 7 days=' || (SELECT count(*) FROM change_log WHERE occurred_at > now() - interval '7 days');
