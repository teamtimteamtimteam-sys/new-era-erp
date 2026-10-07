-- db/tables/label_prints.sql
-- MES-3b(2026-10-07,MES-0 Q40 · §4.3;MES-3b Step 0 Q6–Q8,Tim):【每一次印标签】—— 一行一次,只追加。
--   一行记:印的是哪一样东西(进料批 · 产出批 · 库位,三选一)、用的哪个模板与纸、几份、是不是补印(补印要理由)、
--   二维码里装的是什么(短链接的路径,/b/<批号> 或 /loc/<库位号>)、印上去的那几个字段的快照、谁、什么时候。
--   【记的是"发去打印了",不是"纸出来了"】浏览器不告诉页面纸有没有出来;页面先写这一行,再调 window.print()(Q6)。
--   【补印】同一样东西第一次之后的每一次,不论模板 —— 理由必填,在函数里拒(LABEL_REPRINT_REASON_REQUIRED),不只是页面上。
--   【没有 PDF,没有 sha256】什么都不归档:标签是浏览器印的 HTML(Q8)。
--   写它的只有 record_label_print(属主身份,先按那样东西自己的查看码把关)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.label_prints (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    object_kind         text NOT NULL CHECK (object_kind IN ('inbound_batch', 'output_batch', 'storage_location')),
    inbound_batch_id    uuid REFERENCES public.inbound_batches (id),
    output_batch_id     uuid REFERENCES public.output_batches (id),
    storage_location_id uuid REFERENCES public.storage_locations (id),
    template_code       text NOT NULL REFERENCES public.label_templates (code),
    page_size           text NOT NULL CHECK (page_size IN ('A6', 'A5')),
    copies              integer NOT NULL CHECK (copies >= 1),
    is_reprint          boolean NOT NULL,
    reprint_reason      text,
    qr_payload          text NOT NULL,
    printed_fields      jsonb NOT NULL,
    printed_at          timestamptz NOT NULL DEFAULT now(),
    printed_by          uuid NOT NULL DEFAULT auth.uid(),
    -- 【两句,不是一句】第一句写成 num_nonnulls(…) = 1 这个形状是承重的:关联图(db/views/document_relations.sql 第 ② 条筛子)
    --   只认这个形状为"三选一",认出来才不会把这张表当成一座 inbound_batches ↔ output_batches 的假桥(fixture 103 实测抓到)。
    CONSTRAINT label_prints_one_object CHECK (num_nonnulls(inbound_batch_id, output_batch_id, storage_location_id) = 1),
    CONSTRAINT label_prints_kind_matches CHECK (
        (object_kind = 'inbound_batch') = (inbound_batch_id IS NOT NULL)
        AND (object_kind = 'output_batch') = (output_batch_id IS NOT NULL)
        AND (object_kind = 'storage_location') = (storage_location_id IS NOT NULL)),
    CONSTRAINT label_prints_reprint_reason CHECK (
        (NOT is_reprint AND reprint_reason IS NULL)
     OR (is_reprint AND reprint_reason IS NOT NULL AND btrim(reprint_reason) <> ''))
);

COMMENT ON TABLE public.label_prints IS
    'MES-3b:每一次印标签(只追加)。一样东西(进料批 · 产出批 · 库位)× 模板 × 份数;第一次之后都是补印,要理由。qr_payload = 短链接路径;printed_fields = 印上去的字段快照。记的是"发去打印了",浏览器不报纸出没出来。只有 record_label_print 写。';

CREATE INDEX idx_label_prints_inbound  ON public.label_prints (inbound_batch_id, printed_at)    WHERE inbound_batch_id IS NOT NULL;
CREATE INDEX idx_label_prints_output   ON public.label_prints (output_batch_id, printed_at)     WHERE output_batch_id IS NOT NULL;
CREATE INDEX idx_label_prints_location ON public.label_prints (storage_location_id, printed_at) WHERE storage_location_id IS NOT NULL;

-- 【语句级,连 UPDATE 也是】没有写策略时 authenticated 的 UPDATE / DELETE 在 RLS 那里是零行,行级触发器不会醒(SILENT-1 那一族)。
CREATE TRIGGER trg_label_prints_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.label_prints
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.label_prints ENABLE ROW LEVEL SECURITY;

-- 跟着那样东西判:进料批要进料查看码,产出批要产出查看码,库位要库存查看码。没有写策略:只有 record_label_print(属主身份)写。
CREATE POLICY "label_prints select by permission" ON public.label_prints
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
            OR (output_batch_id IS NOT NULL AND has_permission('module.output.view'::text))
            OR (storage_location_id IS NOT NULL AND has_permission('module.inventory.view'::text))));

REVOKE ALL ON public.label_prints FROM anon;
