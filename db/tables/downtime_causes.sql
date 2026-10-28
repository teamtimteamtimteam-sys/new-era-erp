-- db/tables/downtime_causes.sql
-- MES-7a-1(2026-10-15,MES-0 Q71;MES-7a Step 0 Q3,Tim):【一段停机,是为什么停的】—— 一张固定的清单,每一种原因属于三类之一:
--   failure(坏了)· planned(计划内的停,例如例行保养)· external(机器之外的原因:停电、缺料、等待)。没有"其它"。
--   ★ 可靠性只认 failure 这一类:MTBF / MTTR 的"一次故障" = 一段未作废、原因属于 failure 的停机(MES-0 Q71)。
--   引导每一类一行,不再更细(breakdown · planned_maintenance · external)—— 工厂自己的原因清单是 Tim / cto 的数据,
--   加一种是加一行(/settings/dictionaries,module.processing.edit)。
--   ★ 没有 other:一段说不出为什么的停机,算不进任何一类,而"其它"会把这张清单变成一个兜底桶(规格 §4.1 对损耗说的同一句话)。
--   ★ 一种原因被停机引用之后,它的类别冻住(guard_downtime_cause_class)—— 改类别会悄悄改写已经算过的 MTBF。要改,就新加一种。
--   RUNTIME CONFIG。读:module.processing.view 或 module.finance.view(与停机表的读策略同一对 —— 资产卡上也要读得出原因的名字)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.downtime_causes (
    code       text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$' AND code <> 'other'),
    class      text NOT NULL CHECK (class IN ('failure', 'planned', 'external')),
    name_en    text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh    text NOT NULL CHECK (btrim(name_zh) <> ''),
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.downtime_causes IS
    'MES-7a-1:停机原因与它的类别(failure · planned · external,没有 other)。可靠性只把 failure 类的停机算作一次故障。引导:breakdown · planned_maintenance · external。被引用之后类别冻住。RUNTIME CONFIG。';

COMMENT ON COLUMN public.downtime_causes.class IS
    'MES-7a-1:这一种原因属于哪一类。failure = 机器坏了(MTBF / MTTR 只数这一类);planned = 计划内的停;external = 机器之外的原因。被一段停机引用之后不可再改(DOWNTIME_CAUSE_CLASS_LOCKED)。';

INSERT INTO public.downtime_causes (code, class, name_en, name_zh, sort_order, notes) VALUES
    ('breakdown', 'failure', 'Breakdown', '故障', 10, 'The machine failed. Counted as a failure for MTBF and MTTR.'),
    ('planned_maintenance', 'planned', 'Planned maintenance', '计划保养', 20, 'A planned stop, such as routine servicing. Not a failure.'),
    ('external', 'external', 'External cause', '外部原因', 30, 'A cause outside the machine: no power, no material, waiting. Not a failure.');

ALTER TABLE public.downtime_causes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "downtime_causes select by permission" ON public.downtime_causes
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('module.processing.view'::text)) OR (SELECT has_permission('module.finance.view'::text)));
CREATE POLICY "downtime_causes write by permission" ON public.downtime_causes
    AS PERMISSIVE FOR ALL TO authenticated
    USING ((SELECT has_permission('module.processing.edit'::text))) WITH CHECK ((SELECT has_permission('module.processing.edit'::text)));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.downtime_causes TO authenticated;
REVOKE ALL ON public.downtime_causes FROM anon;

-- 被引用之后类别冻住(删除由停机表的外键挡着)。
CREATE TRIGGER trg_downtime_causes_class
    BEFORE UPDATE ON public.downtime_causes
    FOR EACH ROW EXECUTE FUNCTION public.guard_downtime_cause_class();

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.downtime_causes
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
