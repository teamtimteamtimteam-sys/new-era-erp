-- db/views/batch_required_assay_gaps.sql
-- ASY-P1:每个【物料声明了化验要求、而其中至少一种金属还没有被一份已应用化验
-- 覆盖】的在册进料批一行,点名缺哪几种(missing_metals)。
--
-- 【"覆盖"读的是哪几列 —— 量过之后选的,不是挑的】两条候选:
--   P1  assay_results(applied_at IS NOT NULL, deleted_at IS NULL)
--       ⋈ assay_result_metals(metal)                        ← 采用
--   P2  inbound_batch_metals.content_source = 'assay'
-- 线上实测(ASY-P1 落地当天):**19 行进料含量的 content_source 全部是 NULL**
-- (PROC-1 之前写入,出处未知,刻意不回填)。用 P2 会把【每一个批次】判成零覆盖,
-- 包括 IN-2026-0152 与 IN-2026-0181 那两个六种金属齐备的。P1 在同一批数据上
-- 给出正确答案,而且它就是"已应用的化验覆盖了这种金属"的字面表达。
--
-- 【手工填的含量不算覆盖,这是有意的】线上 IN-2026-0003 有 co/cu/ni 三行含量却
-- 没有任何化验单。这一支叫 awaiting_ASSAY —— 人手敲进去的数字不是实验室结论。
-- 与 PROC-1 同源:出处是【记录】的,绝不从"有没有数字"反推。
--
-- 【sampleable = remaining_qty > 0】料没了就取不到样,那份化验永远做不出来,
-- 于是那盏灯灭不掉 —— 看板那一支因此只取 sampleable 的行。
-- 【它不是"财务上还补救得了"】:reprice_split 对耗尽的批次照样算,差额整份进 5000。
-- 取样与补价是两件事,这一支管的是前者。
--
-- 【属主权限,不是 invoker】跨 inbound / materials / suppliers 三处。invoker 会让
-- RLS 把读者无权那部分的行【静默丢掉】,而这里行消失意味着"这个批次不缺化验" ——
-- 一个错的好消息(OPS-14 的 xmodule 那一课)。属主权限读全量,体内带读者自己的
-- 模块谓词。
--
-- 【消费者】operations_now 的 awaiting_assay 支(只取 sampleable)、
-- ASY-P2 的批次/物料页、db/fixtures/82。
--
-- NOTE: introduced by
-- db/migrations/2026-08-17-asyp1-required-metals-and-the-arm-that-tells-the-truth.sql.

CREATE VIEW public.batch_required_assay_gaps WITH (security_invoker = off) AS
 SELECT inbound_batch_id,
    batch_code,
    material_id,
    material_code,
    material_name,
    supplier_name,
    arrival_date,
    remaining_qty,
    required_metals,
    missing_metals,
    remaining_qty > 0::numeric AS sampleable
   FROM ( SELECT ib.id AS inbound_batch_id,
            ib.code AS batch_code,
            ib.material_id,
            m.code AS material_code,
            m.name AS material_name,
            sup.legal_name AS supplier_name,
            COALESCE(ib.arrival_date, ib.created_at::date) AS arrival_date,
            ib.remaining_qty,
            array_agg(r.metal ORDER BY r.metal) AS required_metals,
            array_agg(r.metal ORDER BY r.metal) FILTER (WHERE NOT (EXISTS ( SELECT 1
                   FROM assay_results ar
                     JOIN assay_result_metals arm ON arm.assay_result_id = ar.id
                  WHERE ar.inbound_batch_id = ib.id AND ar.deleted_at IS NULL AND ar.applied_at IS NOT NULL AND arm.metal = r.metal))) AS missing_metals
           FROM inbound_batches ib
             JOIN materials m ON m.id = ib.material_id
             JOIN material_required_metals r ON r.material_id = ib.material_id
             LEFT JOIN suppliers sup ON sup.id = ib.supplier_id
          WHERE ib.deleted_at IS NULL
          GROUP BY ib.id, ib.code, ib.material_id, m.code, m.name, sup.legal_name, ib.arrival_date, ib.created_at, ib.remaining_qty) g
  WHERE missing_metals IS NOT NULL AND has_permission('module.inbound.view'::text);

COMMENT ON VIEW public.batch_required_assay_gaps IS
    'ASY-P1:每个【物料声明了化验要求、而其中至少一种金属还没有被一份已应用化验覆盖】的在册进料批一行,点名缺哪几种(missing_metals)。覆盖读 assay_results.applied_at ⋈ assay_result_metals.metal —— 手工敲进 inbound_batch_metals 的含量不算覆盖(这一支叫 awaiting_assay)。sampleable = remaining_qty > 0:料没了就取不到样,那盏灯灭不掉,所以看板那一支只取 sampleable 的行。属主权限 + 体内 module.inbound.view 谓词(跨三个模块,invoker 会静默丢行)。';
