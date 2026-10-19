#!/usr/bin/env bash
# NOROLE-SURFACE — fault-injection matrix for fixture 274 and verdict 7, against a LOCAL rebuild that already carries the storage stub and
# db/storage/buckets-and-policies.sql (never live). Each fixture cell runs inside the fixture's own transaction (the injection is the first
# statement after an outer BEGIN; the fixture's ROLLBACK undoes both), so every cell starts from the clean rebuild.
# Every cell must print a FIXTURE 274 / 判词 failure naming its arm; the baseline cell must pass. Usage: <script> "<local dsn>"
set -uo pipefail
L=${1:?local dsn}
cd "$(dirname "$0")/../.."
F=$(ls db/fixtures/274-*.sql)
T=$(mktemp -d)
pass=0; fail=0
cell() {  # name · injection · expected substring
    out=$(psql "$L" -X -q -v ON_ERROR_STOP=1 -c "BEGIN; $2" -f "${4:-$F}" 2>&1 | grep -m1 "FIXTURE 274" | sed 's/.*\(FIXTURE 274.*\)/\1/' | cut -c1-160)
    if [[ "$out" == *"$3"* ]]; then echo "✓ $1 → $out"; pass=$((pass+1)); else echo "✗ $1 → ${out:-<no fixture line>} (expected: $3)"; fail=$((fail+1)); fi
}
for t in user_roles roles role_permissions permissions metal_prices metal_price_indices pricing_settings accounts; do
    cell "open:$t" "CREATE POLICY zz_inj ON public.$t FOR SELECT TO authenticated USING (true);" "REL: a session without the code reads"
done
body=$(awk '/^CREATE VIEW public.collection_promise_status/{on=1} on{print} on&&/;$/{exit}' db/views/collection_promise_status.sql \
       | sed 's/^CREATE VIEW/CREATE OR REPLACE VIEW/; s/  WHERE has_permission(.module.finance.view.::text);/;/')
cell "open:collection_promise_status" "$body" "REL: a session without the code reads"
cell "narrow:accounts (finance viewer loses it)" "DROP POLICY \"accounts select by permission\" ON public.accounts; CREATE POLICY zz_inj ON public.accounts FOR SELECT TO authenticated USING (has_permission('module.finance.edit'));" "REL: module.finance.view alone reads"
sed "s/'user_roles', jsonb_build_array('action.manage_permissions', 'module.hr.view', 'data.view_change_log'),//" "$F" > "$T/f274-trail.sql"
cell "trail:change-history reader" "DROP POLICY \"user_roles select by permission\" ON public.user_roles; CREATE POLICY \"user_roles select by permission\" ON public.user_roles FOR SELECT TO authenticated USING (has_permission('action.manage_permissions') OR user_id = auth.uid() OR has_permission('module.hr.view'));" "TRAIL: the change-log reader" "$T/f274-trail.sql"
cell "trail:employee page (hr viewer)" "DROP POLICY \"user_roles select by permission\" ON public.user_roles; CREATE POLICY \"user_roles select by permission\" ON public.user_roles FOR SELECT TO authenticated USING (has_permission('action.manage_permissions') OR user_id = auth.uid() OR has_permission('data.view_change_log'));" "TRAIL: the employee page trail" "$T/f274-trail.sql"
cell "storage:company-assets open read" "CREATE POLICY zz_inj ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'company-assets');" "BUCKET: a session without the code sees"
cell "storage:po open upload" "CREATE POLICY zz_inj ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'po-documents');" "BUCKET: a session without the code uploads"
cell "storage:material update back" "CREATE POLICY zz_inj ON storage.objects FOR UPDATE TO authenticated USING (bucket_id = 'material-attachments' AND has_permission('module.materials.edit'));" "NOUPDATE"
cell "storage:customer delete recorded" "DROP POLICY \"customer-attachments remove unrecorded by customers.edit\" ON storage.objects; CREATE POLICY zz_inj ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'customer-attachments' AND has_permission('module.customers.edit'));" "DELETE: a recorded attachment was deleted"
cell "storage:cod orphan cleanup gone" "DROP POLICY \"cod-documents remove unrecorded by issue_cod\" ON storage.objects;" "DELETE: action.issue_cod does not delete an orphan"
cell "storage:qt delete opened" "CREATE POLICY zz_inj ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'qt-documents' AND has_permission('module.sales.edit'));" "DELETE: module.sales.edit deletes from qt-documents"
cell "storage:bucket-only policy back (shape)" "CREATE POLICY zz_inj ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'avatars' AND false);" "SHAPE"
out=$(psql "$L" -X -q -v ON_ERROR_STOP=1 -f "$F" 2>&1 | grep -m1 "FIXTURE 274")
[[ "$out" == *"全部通过"* ]] && { echo "✓ baseline (no injection) → passes"; pass=$((pass+1)); } || { echo "✗ baseline → $out"; fail=$((fail+1)); }
# verdict 7 on the same rebuild
psql "$L" -X -q -c 'CREATE POLICY "zz norole fault accounts open" ON public.accounts FOR SELECT TO authenticated USING (true);'
v=$(python3 db/check_norole.py --rebuild "$L" --offline); psql "$L" -X -q -c 'DROP POLICY "zz norole fault accounts open" ON public.accounts;'
[[ "$v" == *"policy public.accounts:zz norole fault accounts open"* && "$v" == *"rows norole:public.accounts"* ]] && { echo "✓ verdict 7: injected USING (true) on accounts named"; pass=$((pass+1)); } || { echo "✗ verdict 7 injection: $v"; fail=$((fail+1)); }
grep -v "^definer	period_close_floor()" db/norole-surface-baseline.tsv > "$T/bl.tsv"
v=$(python3 db/check_norole.py --rebuild "$L" --offline --baseline "$T/bl.tsv")
[[ "$v" == *"definer period_close_floor()"* ]] && { echo "✓ verdict 7: deleted baseline line named"; pass=$((pass+1)); } || { echo "✗ verdict 7 deleted line: $v"; fail=$((fail+1)); }
v=$(python3 db/check_norole.py --rebuild "$L" --offline --baseline /nonexistent/baseline.tsv)
[[ "$v" == *"baseline unreadable"* ]] && { echo "✓ verdict 7: unreadable baseline is red"; pass=$((pass+1)); } || { echo "✗ verdict 7 unreadable: $v"; fail=$((fail+1)); }
v=$(python3 db/check_norole.py --rebuild "$L" --offline)
[[ "$v" == *"all bit"* && "$v" == *"判词【无角色面】:✓"* ]] && { echo "✓ verdict 7 clean, always-on cells (probe · blinded query · removed line · unreadable baseline) bit"; pass=$((pass+1)); } || { echo "✗ verdict 7 clean: $v"; fail=$((fail+1)); }
echo "INJECTIONS pass=$pass fail=$fail"
rm -rf "$T"
[ "$fail" -eq 0 ]
