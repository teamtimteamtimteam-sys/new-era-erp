-- db/tables/container_documents.sql
-- LOG-2a。守卫函数在 db/functions/guard_container_document_na_reason.sql;
-- 实例化函数在 db/functions/instantiate_container_documents.sql。

CREATE TABLE public.container_documents (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    container_id  uuid NOT NULL REFERENCES public.containers (id) ON DELETE RESTRICT,
    document_type text NOT NULL,
    regime        text,
    status        text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','received','not_applicable')),
    na_reason     text,
    from_lane     boolean NOT NULL DEFAULT false,
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid DEFAULT auth.uid(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.container_documents IS
'LOG-2a:这一箱货实际要备齐的单据。**由航段清单实例化**(lane_document_requirements),
外加人可以自由追加 —— 现实里总有清单没写到的东西,而一份改不动的清单会被绕过去。
from_lane 把两者分开:清单来的与人后加的,回头看时不是同一回事。
【regime 只是一个属性】,本层照旧不为任何具名法规建模。
【"不适用"要理由】:一个没有理由的 n/a 与一个漏掉的单据,在屏幕上长得一模一样。';

CREATE TRIGGER trg_container_documents_na_reason
    BEFORE INSERT OR UPDATE ON public.container_documents
    FOR EACH ROW EXECUTE FUNCTION guard_container_document_na_reason();

CREATE TRIGGER trg_container_documents_updated_at
    BEFORE UPDATE ON public.container_documents
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.container_documents ENABLE ROW LEVEL SECURITY;
CREATE POLICY "container_documents select" ON public.container_documents
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.logistics.view'::text));
CREATE POLICY "container_documents write" ON public.container_documents
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));
