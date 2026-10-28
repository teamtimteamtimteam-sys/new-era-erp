# regenerate db/migrations/2026-10-28-chain-walk-cost.sql from the mirrors (exact text), header + wrap block + functions + self-check tail
mirror=lambda f: open(f).read().rstrip('\n')
grant=lambda sig: f"REVOKE ALL ON FUNCTION {sig} FROM PUBLIC, anon;\nGRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;"
parts=[open('/private/tmp/claude-501/-Users-timchen/d370be5a-b509-4585-8b15-f0b4ce60ace9/scratchpad/mig-header.sql').read().rstrip('\n')+'\nBEGIN;\n', open('/private/tmp/claude-501/-Users-timchen/d370be5a-b509-4585-8b15-f0b4ce60ace9/scratchpad/mig-wrap.sql').read().rstrip('\n')]
for f,sig in [('db/functions/document_relation_arm_pairs.sql','public.document_relation_arm_pairs(text, uuid[])'),('db/functions/document_relation_arm_ids.sql',None),
              ('db/functions/document_chain_step_admitted.sql','public.document_chain_step_admitted(text, uuid[])'),('db/functions/document_chain_step_admits.sql',None),
              ('db/functions/document_detail_hrefs.sql',None),('db/functions/document_detail_href.sql',None),('db/functions/document_chain_walk.sql',None),
              ('db/functions/trail_fk_targets.sql',None),('db/functions/trail_current_image.sql',None),('db/functions/trail_row_visible.sql',None),
              ('db/functions/trail_ref_label.sql',None),('db/functions/change_log_field.sql',None),('db/functions/record_trail.sql',None)]:
    parts.append(f"\n-- ── {f} ──\n"+mirror(f))
    if sig: parts.append(grant(sig))
parts.append('\n'+open('/private/tmp/claude-501/-Users-timchen/d370be5a-b509-4585-8b15-f0b4ce60ace9/scratchpad/mig-tail.sql').read())
open('db/migrations/2026-10-28-chain-walk-cost.sql','w').write('\n'.join(parts))
