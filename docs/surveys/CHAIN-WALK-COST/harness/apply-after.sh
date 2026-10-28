#!/bin/bash
# LOCAL ONLY: bring a local DB to the after-state of this cut, keeping today's functions as *_old for comparison.
set -e
DB="host=/tmp/cwc port=55440 user=postgres dbname=$1"
psql "$DB" -Xq -v ON_ERROR_STOP=1 -f /private/tmp/claude-501/-Users-timchen/d370be5a-b509-4585-8b15-f0b4ce60ace9/scratchpad/old-walk.sql
psql "$DB" -Xq -v ON_ERROR_STOP=1 -c "GRANT EXECUTE ON FUNCTION public.document_chain_walk_old(jsonb,int,text,uuid) TO authenticated"
psql "$DB" -Xq -v ON_ERROR_STOP=1 -c "BEGIN" -f /private/tmp/claude-501/-Users-timchen/d370be5a-b509-4585-8b15-f0b4ce60ace9/scratchpad/mig-wrap.sql -c "COMMIT" | grep -v '^DO$' || true
psql "$DB" -Xq -v ON_ERROR_STOP=1 -f /Users/timchen/Documents/projects/new-era-erp/db/functions/document_chain_walk.sql
psql "$DB" -Xq -v ON_ERROR_STOP=1 -f /private/tmp/claude-501/-Users-timchen/d370be5a-b509-4585-8b15-f0b4ce60ace9/scratchpad/old-trail.sql -c "GRANT EXECUTE ON FUNCTION public.record_trail_old(text,text,integer) TO authenticated"
psql "$DB" -Xq -v ON_ERROR_STOP=1 -f /Users/timchen/Documents/projects/new-era-erp/db/functions/record_trail.sql
psql "$DB" -Xq -v ON_ERROR_STOP=1 -f /Users/timchen/Documents/projects/new-era-erp/db/functions/trail_fk_targets.sql
psql "$DB" -Xq -v ON_ERROR_STOP=1 -f /Users/timchen/Documents/projects/new-era-erp/db/functions/trail_current_image.sql
psql "$DB" -Xq -v ON_ERROR_STOP=1 -f /Users/timchen/Documents/projects/new-era-erp/db/functions/trail_row_visible.sql
psql "$DB" -Xq -v ON_ERROR_STOP=1 -f /Users/timchen/Documents/projects/new-era-erp/db/functions/trail_ref_label.sql
psql "$DB" -Xq -v ON_ERROR_STOP=1 -f /Users/timchen/Documents/projects/new-era-erp/db/functions/document_relation_arm_pairs.sql -c "GRANT EXECUTE ON FUNCTION public.document_relation_arm_pairs(text, uuid[]) TO authenticated" -f /Users/timchen/Documents/projects/new-era-erp/db/functions/document_relation_arm_ids.sql -f /Users/timchen/Documents/projects/new-era-erp/db/functions/document_chain_walk.sql
psql "$DB" -Xq -v ON_ERROR_STOP=1 -f /Users/timchen/Documents/projects/new-era-erp/db/functions/document_chain_step_admitted.sql -c "GRANT EXECUTE ON FUNCTION public.document_chain_step_admitted(text, uuid[]) TO authenticated" -f /Users/timchen/Documents/projects/new-era-erp/db/functions/document_chain_step_admits.sql -f /Users/timchen/Documents/projects/new-era-erp/db/functions/document_chain_walk.sql
psql "$DB" -Xq -v ON_ERROR_STOP=1 -f /Users/timchen/Documents/projects/new-era-erp/db/functions/document_detail_hrefs.sql -f /Users/timchen/Documents/projects/new-era-erp/db/functions/document_detail_href.sql -f /Users/timchen/Documents/projects/new-era-erp/db/functions/document_chain_walk.sql
psql "$DB" -Xq -v ON_ERROR_STOP=1 -f /Users/timchen/Documents/projects/new-era-erp/db/functions/change_log_field.sql -f /Users/timchen/Documents/projects/new-era-erp/db/functions/record_trail.sql
