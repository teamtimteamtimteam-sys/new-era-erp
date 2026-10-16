-- MES-7b-2 · LOCAL harness only (never live): inspections and environmental results of my own on a fresh rebuild of this cut's mirrors,
-- for the layout survey (desktop + 390px) of pages that have no data on live (no template, run, finding, parameter or result is created on live).
-- Run as postgres on the rebuild AFTER docs/surveys/MES-7b-1/local-seed.sql (which creates the role clones and their employees):
--   psql "<local dsn>" -f docs/surveys/MES-7b-2/local-seed.sql
-- Every write goes through the writers, acting as the admin clone (SET ROLE authenticated + request.jwt.claims), so the guards are exercised.
\set ON_ERROR_STOP 1
DO $refuse$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE email = 'clone-admin@test.local') THEN
    RAISE EXCEPTION 'local-seed: run docs/surveys/MES-7b-1/local-seed.sql first (no clone-admin)';
  END IF;
  IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') > 0 THEN
    RAISE EXCEPTION 'local-seed: this database has real accounts — refusing (local harness only)';
  END IF;
END $refuse$;

INSERT INTO environmental_parameters (code, name_en, name_zh, unit, limit_value, limit_basis, sort_order) VALUES
  ('hf_stack', 'Hydrogen fluoride at the stack', '烟囱氟化氢', 'mg/Nm3', 5, 'max', 10),
  ('ph_discharge', 'pH of the trade effluent', '工业废水 pH', 'pH', 6, 'min', 20),
  ('dust_stack', 'Particulate matter at the stack', '烟囱颗粒物', 'mg/Nm3', NULL, NULL, 30);

DO $s$
DECLARE
  v_admin uuid := 'a0000000-0000-4000-8000-000000000001';
  v_emp uuid; v_emp2 uuid; v_lab text;
  t1 uuid; t2 uuid; t3 uuid; r1 jsonb; r2 jsonb; r3 jsonb; v_f uuid; v_j jsonb;
BEGIN
  SELECT id INTO v_emp FROM employees WHERE user_id = v_admin;
  SELECT id INTO v_emp2 FROM employees WHERE code = 'CLONE-WAREHOUSE';
  SELECT code INTO v_lab FROM laboratories ORDER BY code LIMIT 1;
  PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_admin), true);
  SET LOCAL ROLE authenticated;

  t1 := (save_inspection_template(NULL, 'discharge', 'Discharge bay weekly', 'Discharge bay',
         '["Extinguishers in place and charged", "Cells stored dry, off the floor, away from the drain", "Emergency stop tested and labelled", "Spill kit complete and within reach of the discharge benches"]'::jsonb,
         7, true, 'Walk the bay left to right.') ->> 'template_id')::uuid;
  t2 := (save_inspection_template(NULL, 'fire-monthly', 'Fire equipment monthly', 'Whole site',
         '["Hose reels unobstructed", "Fire doors close fully", "Exit signs lit"]'::jsonb, NULL, true, NULL) ->> 'template_id')::uuid;
  t3 := (save_inspection_template(NULL, 'old-store', 'Old chemical store', 'Store B',
         '["Store locked"]'::jsonb, 30, false, NULL) ->> 'template_id')::uuid;

  r1 := record_inspection_run(t1, now() - interval '9 days', v_emp,
         '[{"position":1,"result":"pass"},{"position":2,"result":"fail","note":"Two pallets of cells stood on the floor next to the drain grate."},{"position":3,"result":"pass"},{"position":4,"result":"na","note":"Spill kit out for refill."}]'::jsonb,
         NULL, NULL, 'Bay busy with an inbound delivery.',
         format('[{"position":2,"corrective_action":"Move the cells onto the racking and mark the drain zone.","owner_employee_id":"%s","due_date":"%s"}]', v_emp2, CURRENT_DATE - 2)::jsonb);
  r2 := record_inspection_run(t2, now() - interval '3 days', v_emp,
         '[{"position":1,"result":"pass"},{"position":2,"result":"fail","note":"Door to the stairwell sticks on the frame."},{"position":3,"result":"pass"}]'::jsonb,
         NULL, NULL, NULL,
         format('[{"position":2,"corrective_action":"Plane the door and re-hang the closer.","owner_employee_id":"%s"}]', v_emp)::jsonb);
  -- a correction of r2 (the inspector mistyped item 3)
  r3 := record_inspection_run(t2, now() - interval '3 days' + interval '1 hour', v_emp,
         '[{"position":1,"result":"pass"},{"position":2,"result":"fail","note":"Door to the stairwell sticks on the frame."},{"position":3,"result":"fail","note":"One exit sign above the store is dark."}]'::jsonb,
         NULL, NULL, NULL, NULL, (r2 ->> 'run_id')::uuid, 'Item 3 was recorded as a pass by mistake.');

  SELECT id INTO v_f FROM inspection_findings WHERE run_id = (r2 ->> 'run_id')::uuid;
  PERFORM raise_inspection_finding_task(v_f);
  PERFORM close_inspection_finding(v_f, 'Door planed and closer re-hung; closes fully.');
  SELECT id INTO v_f FROM inspection_findings WHERE run_id = (r1 ->> 'run_id')::uuid;
  PERFORM raise_inspection_finding_task(v_f);

  PERFORM record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 20, v_lab, 'FRL-24-0311', 3.2);
  v_j := record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 6, v_lab, 'FRL-24-0388', 7.5, true,
         'Scrubber dosing raised; second sample booked.');
  PERFORM record_environmental_result('ph_discharge', 'Effluent pit', CURRENT_DATE - 6, v_lab, 'FRL-24-0389', 6.8);
  PERFORM record_environmental_result('dust_stack', 'Stack A', CURRENT_DATE - 6, v_lab, 'FRL-24-0390', 12.4);
  RAISE NOTICE 'local-seed MES-7b-2: templates % % %, runs % % %, exceedance incident %', t1, t2, t3, r1 ->> 'code', r2 ->> 'code', r3 ->> 'code', v_j ->> 'incident_code';
  RESET ROLE;
END $s$;

SELECT 'RUN|' || r.code || '|' || r.id FROM inspection_runs r ORDER BY r.code;
SELECT 'TPL|' || t.code || '|' || t.id FROM inspection_templates t ORDER BY t.code;
SELECT 'INC|' || i.code || '|' || i.id FROM incidents i ORDER BY i.code;
