-- MES-4b close-out · read-only live readings (2026-10-08). Identity: postgres over the pooler (rolbypassrls = true); every relation read
-- below is a BASE table or a catalog (RLS takes no part), except where a line says otherwise. Run:
--   PGOPTIONS='-c default_transaction_read_only=on' psql "host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 \
--     user=postgres.wvywpohbwkiinmipmuku dbname=postgres" -X -q -f docs/surveys/MES-5a/closeout-readings.sql
-- Items are the close-out brief's step 1.3 letters (f, g, i) plus the standing live state.
BEGIN READ ONLY;
\pset pager off
\pset format unaligned
SELECT 'identity', current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user),
       current_setting('transaction_read_only'), (now() AT TIME ZONE 'Asia/Singapore')::text;
-- standing live state
SELECT 'accounts', count(*), count(*) FILTER (WHERE banned_until > now()) AS disabled FROM auth.users;
SELECT 'approvals', approvals_enabled FROM finance_settings;
SELECT 'require_calibrated_since', coalesce(require_calibrated_since::text, 'NULL') FROM ingest_settings;

-- f · saleability of the six MES-4b forms (material_forms.may_be_sold)
SELECT 'f_form', code, may_be_sold, implies_dismantling, is_active, coalesce(output_document_key, '(none)')
  FROM material_forms
 WHERE code IN ('cathode_powder','anode_powder','copper_foil','aluminium_foil','collected_dust','harness_bms_busbar')
 ORDER BY code;

-- g · the electrolyte flag on every operation, the share, and who may edit operation_types
SELECT 'g_op', code, is_active, electrolyte_loss_applies, coalesce(electrolyte_share_pct::text, 'NULL'), requires_cell_construction
  FROM operation_types ORDER BY code;
SELECT 'g_op_flag_true', count(*) FILTER (WHERE electrolyte_loss_applies), count(*) FILTER (WHERE electrolyte_share_pct IS NOT NULL), count(*)
  FROM operation_types;
SELECT 'g_policy', polname, polcmd, pg_get_expr(polqual, polrelid), pg_get_expr(polwithcheck, polrelid)
  FROM pg_policy WHERE polrelid = 'public.operation_types'::regclass ORDER BY polname;
SELECT 'g_grant_update', has_table_privilege('authenticated', 'public.operation_types', 'UPDATE');
SELECT 'g_lc', code, may_be_derived, position('后端的环保' IN coalesce(notes, '')) > 0 AS notes_names_back_end_equipment
  FROM loss_categories WHERE code = 'electrolyte_evaporation';

-- who holds the codes the three usability paths ask for (active grants only)
SELECT 'holders', rp.permission_code, string_agg(DISTINCT r.code, ',' ORDER BY r.code) AS roles,
       count(DISTINCT ur.user_id) FILTER (WHERE ur.user_id IS NOT NULL) AS live_accounts
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
  LEFT JOIN user_roles ur ON ur.role_id = r.id AND ur.revoked_at IS NULL
 WHERE rp.permission_code IN ('module.processing.edit','module.materials.edit','module.inbound.edit','module.output.edit',
                              'action.processing_commit','module.materials.view')
 GROUP BY rp.permission_code ORDER BY rp.permission_code;

-- i(1) · the material editor: what a new material of each new form needs (guard_material_condition_axes)
SELECT 'i_kind', code, has_condition_axes, is_active FROM material_kinds ORDER BY code;
SELECT 'i_source', code, is_active FROM material_sources ORDER BY code;
SELECT 'i_materials_on_new_forms', count(*) FROM materials
 WHERE deleted_at IS NULL
   AND form_code IN ('cathode_powder','anode_powder','copper_foil','aluminium_foil','collected_dust','harness_bms_busbar');
SELECT 'i_trigger', tgname, tgenabled FROM pg_trigger WHERE tgrelid = 'public.materials'::regclass AND tgname = 'trg_materials_condition_axes';

-- i(2) · cell batches today: material form carries cells (true) / form-less (NULL, the guard allows) / not a cell form (false);
--         construction empty; locked = the batch fed a committed run (set_batch_cell_construction refuses CELL_CONSTRUCTION_LOCKED)
WITH b AS (
    SELECT 'inbound' AS side, ib.id, ib.code, ib.cell_construction_code AS cc, m.form_code, mf.implies_dismantling AS carries,
           EXISTS (SELECT 1 FROM processing_inputs pi JOIN processing_runs pr ON pr.id = pi.run_id
                    WHERE pi.inbound_batch_id = ib.id AND pr.status = 'committed') AS locked
      FROM inbound_batches ib JOIN materials m ON m.id = ib.material_id LEFT JOIN material_forms mf ON mf.code = m.form_code
     WHERE ib.deleted_at IS NULL
    UNION ALL
    SELECT 'output', ob.id, ob.code, ob.cell_construction_code, m.form_code, mf.implies_dismantling,
           EXISTS (SELECT 1 FROM processing_inputs pi JOIN processing_runs pr ON pr.id = pi.run_id
                    WHERE pi.output_batch_id = ob.id AND pr.status = 'committed')
      FROM output_batches ob JOIN materials m ON m.id = ob.material_id LEFT JOIN material_forms mf ON mf.code = m.form_code
     WHERE ob.deleted_at IS NULL)
SELECT 'i_batches', side, coalesce(carries::text, 'form-less') AS carries, count(*) AS batches,
       count(*) FILTER (WHERE cc IS NULL) AS no_construction,
       count(*) FILTER (WHERE cc IS NULL AND NOT locked) AS settable_now,
       string_agg(code, ',' ORDER BY code) FILTER (WHERE cc IS NULL AND NOT locked AND carries IS TRUE) AS cell_form_settable_codes
  FROM b GROUP BY side, carries ORDER BY side, carries;
SELECT 'i_fn', p.proname, has_function_privilege('authenticated', p.oid, 'EXECUTE')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'set_batch_cell_construction';
ROLLBACK;
