-- db/views/incident_batch_rows.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q7,Tim):一件事故的批次链接,带批号与事故的标签 —— 事故页的「碰过的批次」与批次页的「关联的事故」都读它。
--   【属主权限】行谓词 = incident_batches 的读策略(module.safety.view,或那一批自己那一页的查看码)。
--   借来的列只有标签:批号与物料名、事故编号、种类的名字、发生时刻 —— 显示标签跟着单据走(常设裁定之三);
--   一个只持批次查看码的人看得见"这一批链在 INC-… 上、是哪一种、什么时候",看不见那件事故的任何别的东西(事故页的门是 module.safety.view)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.

CREATE VIEW public.incident_batch_rows WITH (security_invoker = off) AS
 SELECT b.id,
    b.incident_id,
    i.code AS incident_code,
    c.kind_code,
    k.name_en AS kind_name_en,
    k.name_zh AS kind_name_zh,
    c.occurred_at AS incident_occurred_at,
        CASE
            WHEN b.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    COALESCE(b.inbound_batch_id, b.output_batch_id) AS batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
    COALESCE(im.name, om.name) AS material_name,
    b.basis,
    b.linked_at,
    b.linked_by,
    b.unlinked_at,
    b.unlinked_by,
    b.unlink_reason,
    b.unlinked_at IS NULL AS active
   FROM incident_batches b
     JOIN incidents i ON i.id = b.incident_id
     JOIN incident_current_all c ON c.id = b.incident_id
     JOIN incident_kinds k ON k.code = c.kind_code
     LEFT JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
     LEFT JOIN materials im ON im.id = ib.material_id
     LEFT JOIN output_batches ob ON ob.id = b.output_batch_id
     LEFT JOIN materials om ON om.id = ob.material_id
  WHERE has_permission('module.safety.view'::text)
     OR (b.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
     OR (b.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text));

COMMENT ON VIEW public.incident_batch_rows IS
    'MES-7b-1:事故 × 批次的链接(有效的与解除的),带批号、物料名、事故编号、种类与时刻。属主权限,行谓词 = incident_batches 的读策略。事故页与批次页读它。';

-- ★ 默认权限会把 INSERT / UPDATE / DELETE 也授给 authenticated(线上 pg_default_acl:postgres 建的表与视图 authenticated=arwdDxtm),
--   而一张简单的属主视图是【可以写穿的】—— 以属主身份写基表,绕开 RLS 与那几支 DEFINER 函数的码。所以先全收,再只授回 SELECT。
REVOKE ALL ON public.incident_batch_rows FROM authenticated, anon;
GRANT SELECT ON public.incident_batch_rows TO authenticated;
