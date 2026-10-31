-- db/tables/company_policies.sql
-- ESG-2(Tim 2026-10-31 Q9 · Q10):【公司制度登记簿】—— 一行 = 一份制度的【一个版本】:标题 · 版本号 · 负责人(一名员工)· 生效日 · 复审日 · 文件在哪(一句文字,
--   不上传文件 —— 免费档 900 MB 的存储上限,也不开新桶)。
--   【新版本取代旧版本】supersedes_id 指着它取代的那一版;被取代的那一版记 superseded_at(由写函数一并写,同一笔事务)。一份制度的「现在」= 没被取代的那一版。
--     一版最多被取代一次(部分唯一索引)。行写下之后只有 superseded_at 那一格会被写一次,别的列不改、不删(守卫)。
--   【复审逾期】现在那一版的复审日早于新加坡的今天 → 页面标「复审逾期」(company_policy_rows.review_overdue)。
--   【写】只经 company_policy_record(action.manage_esg:admin · cco · cfo)。
--   【读】每一个登录的【员工】(有员工档案的人)与持 action.manage_esg 的人 —— 供应商门户的账号也是 authenticated,所以判据不是 true。
--
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
-- First-run script (plain CREATEs).
CREATE TABLE public.company_policies (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title              text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 200),
    version            text NOT NULL CHECK (length(btrim(version)) BETWEEN 1 AND 40),
    owner_employee_id  uuid NOT NULL REFERENCES public.employees (id),
    effective_date     date NOT NULL,
    review_date        date NOT NULL,
    document_ref       text NOT NULL CHECK (length(btrim(document_ref)) BETWEEN 1 AND 500),
    supersedes_id      uuid REFERENCES public.company_policies (id),
    superseded_at      timestamptz,
    recorded_at        timestamptz NOT NULL DEFAULT now(),
    recorded_by        uuid DEFAULT auth.uid(),
    CONSTRAINT company_policies_review_after_effective CHECK (review_date >= effective_date),
    CONSTRAINT company_policies_not_self CHECK (supersedes_id IS NULL OR supersedes_id <> id)
);
CREATE UNIQUE INDEX company_policies_superseded_once ON public.company_policies (supersedes_id) WHERE supersedes_id IS NOT NULL;
CREATE INDEX company_policies_owner_employee_id_rel ON public.company_policies (owner_employee_id);
COMMENT ON TABLE public.company_policies IS
    'ESG-2(Q10):公司制度登记簿 —— 一行是一份制度的一个版本(标题、版本号、负责人、生效日、复审日、文件在哪的一句文字)。新版本经 supersedes_id 取代旧版本,旧版本记 superseded_at。只经 company_policy_record 写(action.manage_esg);每一位员工都读得到。';

-- 只许 superseded_at 被写一次;别的列不改;不删(语句级的删除守卫让 RLS 碰不到行时照样抛)。
CREATE OR REPLACE FUNCTION public.guard_company_policy_write()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'COMPANY_POLICY_IMMUTABLE';
    END IF;
    IF (to_jsonb(NEW) - 'superseded_at') IS DISTINCT FROM (to_jsonb(OLD) - 'superseded_at')
       OR OLD.superseded_at IS NOT NULL OR NEW.superseded_at IS NULL THEN
        RAISE EXCEPTION 'COMPANY_POLICY_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_company_policies_guard
    BEFORE UPDATE ON public.company_policies
    FOR EACH ROW EXECUTE FUNCTION public.guard_company_policy_write();
CREATE TRIGGER trg_company_policies_no_delete
    BEFORE DELETE ON public.company_policies
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_company_policy_write();
CREATE TRIGGER trg_company_policies_truncate
    BEFORE TRUNCATE ON public.company_policies
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.company_policies ENABLE ROW LEVEL SECURITY;
CREATE POLICY "company_policies select by employees" ON public.company_policies
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT current_user_employee()) IS NOT NULL OR (SELECT has_permission('action.manage_esg'::text)));
REVOKE ALL ON public.company_policies FROM authenticated, anon;
GRANT SELECT ON public.company_policies TO authenticated;
