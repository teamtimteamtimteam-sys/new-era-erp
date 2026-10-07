-- db/tables/licence_storage_limits.sql
-- MES-3a(2026-10-06,MES-0 Q32 · V2;MES-3a Step 0 Q5 · Q12,Tim):【一张执照对一类 NEA 废物批准的库存上限】,吨。
--   一行 = 执照 × 类别;同一张执照同一类只有一行(唯一约束)。没有行 = "上限没给"(V2)—— 不是"没有上限":
--   收货照收,并在 receipt_ceiling_checks 记下 ceiling_not_set(Q33)。有行 → 收货时对着那一类的存量判,超了按名拒。
--   执照自己那一行的 approved_storage_limit_tonnes 是总上限(Q6),也照样判。
--   【谁改】执照页 /purchasing/licences,码与执照本身同一个:module.suppliers.edit。历史 = 变更记录(Q12)。
--   【用哪一张执照】收货那一天在效的 gwdf 执照(storage_licence_in_force —— 销毁证书的同一条挑法,Q5)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.licence_storage_limits (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    licence_id    uuid NOT NULL REFERENCES public.company_compliance (id),
    category_code text NOT NULL REFERENCES public.nea_waste_categories (code),
    limit_tonnes  numeric NOT NULL CHECK (limit_tonnes > 0),
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid DEFAULT auth.uid(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid DEFAULT auth.uid(),
    CONSTRAINT licence_storage_limits_one_per_category UNIQUE (licence_id, category_code)
);

COMMENT ON TABLE public.licence_storage_limits IS
    'MES-3a:一张执照对一类 NEA 废物批准的库存上限(吨,V2)。没有行 = 上限没给:收货照收并记 ceiling_not_set;有行 = 收货时超了按名拒 STORAGE_CEILING_EXCEEDED。改在 /purchasing/licences(module.suppliers.edit)。';

CREATE TRIGGER trg_licence_storage_limits_updated_at
    BEFORE UPDATE ON public.licence_storage_limits
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.licence_storage_limits ENABLE ROW LEVEL SECURITY;
-- 与 company_compliance 同一对码:读 module.suppliers.view,写 module.suppliers.edit。
CREATE POLICY "licence_storage_limits select by permission"
    ON public.licence_storage_limits AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'));
CREATE POLICY "licence_storage_limits insert by permission"
    ON public.licence_storage_limits AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.suppliers.edit'));
CREATE POLICY "licence_storage_limits update by permission"
    ON public.licence_storage_limits AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.suppliers.edit'))
    WITH CHECK (has_permission('module.suppliers.edit'));
CREATE POLICY "licence_storage_limits delete by permission"
    ON public.licence_storage_limits AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.suppliers.edit'));

REVOKE ALL ON public.licence_storage_limits FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.licence_storage_limits
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.suppliers.edit');
