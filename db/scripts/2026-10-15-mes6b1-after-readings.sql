-- MES-6b-1 after reading (2026-10-15) — read-only, BEGIN READ ONLY … ROLLBACK. Run after the migration, the smoke and the live proof.
-- Identity: postgres (rolbypassrls = true) on base tables; counts are real row counts.
-- Complements db/scripts/2026-10-15-mes6b1-opening-readings.sql (re-run unchanged beside this one):
--   what the migration created, that nothing of mine remains, and every change_log row since the opening reading (max seq 34275).
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f db/scripts/2026-10-15-mes6b1-after-readings.sql
BEGIN READ ONLY;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
SELECT 'NEW|NCRs=' || (SELECT count(*) FROM nonconformance_reports) || '|quality limits=' || (SELECT count(*) FROM contract_quality_limits)
    || '|judgements=' || (SELECT count(*) FROM quality_limit_judgements)
    || '|quality_limit_basis set=' || (SELECT count(*) FROM contract_settlement_terms WHERE quality_limit_basis IS NOT NULL)
    || '|ncr_rows=' || (SELECT count(*) FROM ncr_rows);
SELECT 'NEW|guards|' || string_agg(tgname || '=' || tgenabled::text, ',' ORDER BY tgname) FROM pg_trigger
 WHERE tgname IN ('trg_inventory_movements_quality_hold', 'trg_contract_pricing_terms_unpenalised', 'trg_contract_penalty_elements_unpriced',
                  'trg_contract_penalty_elements_substance_role', 'trg_nonconformance_reports_mutation');
SELECT 'MINE|probe suppliers=' || (SELECT count(*) FROM suppliers WHERE code LIKE 'ZZ-PROBE-MES6B1%')
    || '|customers=' || (SELECT count(*) FROM customers WHERE code LIKE 'ZZ-PROBE-MES6B1%')
    || '|materials=' || (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES6B1%')
    || '|contracts=' || (SELECT count(*) FROM contracts WHERE title LIKE 'ZZ-PROBE-MES6B1%')
    || '|ni quotes September 2026=' || (SELECT count(*) FROM metal_prices WHERE metal = 'ni' AND price_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30')
    || '|LME September 2026=' || (SELECT count(*) FROM index_market_calendar WHERE index_code = 'LME' AND calendar_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30')
    || '|probe accounts=' || (SELECT count(*) FROM auth.users WHERE email LIKE 'mes6b1probe-%')
    || '|probe roles=' || (SELECT count(*) FROM roles WHERE code LIKE 'probe-mes6b1probe-%')
    || '|throwaway accounts any=' || (SELECT count(*) FROM auth.users WHERE email LIKE '%@test.local');
SELECT 'LOG|' || table_name || ':' || op || '=' || count(*) FROM change_log WHERE seq > 34275 GROUP BY table_name, op ORDER BY table_name, op;
SELECT 'LOG|since opening rows=' || count(*) || '|first=' || COALESCE(min(occurred_at)::text, '-') || '|last=' || COALESCE(max(occurred_at)::text, '-')
  FROM change_log WHERE seq > 34275;
ROLLBACK;
