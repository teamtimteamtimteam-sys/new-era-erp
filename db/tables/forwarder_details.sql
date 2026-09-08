-- db/tables/forwarder_details.sql
-- LOG-1a。镜像与 db/migrations/2026-08-19-log1a-*.sql 同源。

CREATE TABLE public.forwarder_details (
    supplier_id     uuid PRIMARY KEY REFERENCES public.suppliers (id),
    main_routes     text,
    ports_served    text,
    free_time_terms text,
    dg_classes      text,
    notes           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.forwarder_details IS
'LOG-1a:货代的物流属性。主键【就是】supplier_id —— 一家公司一个 id,一对一。
这样应付账龄、付款分摊、预付冲抵、外币重估整条链完全不用知道"货代"这回事:它看到的还是一个 supplier。
【这里没有联系人,而且不要往这里加】。联系人是一张【共享的子表】,与供应商/客户共用一套形状,那是单独排队的一刀。
在它到来之前,货代的联系人【没有家】—— 这是一个已知的空缺,不是遗漏;
在这里先长一个私有的联系人列,等共享子表落地时就会有两份联系人,而那正是本仓库反复点名的那种漂移。';

COMMENT ON COLUMN public.forwarder_details.dg_classes IS
'LOG-1a:这家货代做得了哪些危险品类别。**自由文本,故意不建枚举** —— 类别体系(IMDG/ADR/UN)按法规与航线走,而本刀不建模任何具名法规(那是 lane_document_requirements.regime 的活,而且它也是自由文本)。';

CREATE TRIGGER trg_forwarder_details_updated_at
    BEFORE UPDATE ON public.forwarder_details
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.forwarder_details ENABLE ROW LEVEL SECURITY;
CREATE POLICY "forwarder_details select" ON public.forwarder_details
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.logistics.view'::text));
CREATE POLICY "forwarder_details write" ON public.forwarder_details
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));

CREATE TRIGGER trg_forwarder_details_is_forwarder
    BEFORE INSERT OR UPDATE ON public.forwarder_details
    FOR EACH ROW EXECUTE FUNCTION guard_forwarder_details_is_forwarder();

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.forwarder_details
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
