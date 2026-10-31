-- db/tables/required_trainings.sql
-- ESG-2(Tim 2026-10-31 Q8 · Q9):【必修培训清单】—— 哪些培训是【必须有】的、对谁必须、有效多久。培训合规页(ESG › 培训合规)按它算覆盖与到期。
--   一行 = 一门必修培训:名字 · 类别(与 training_records.category 同一组)· 有效期(月;空 = 不过期,除非那一条记录自己写了到期日)·
--   对谁必须(applies_to):everyone 全体在职员工 · office 办公室 · shopfloor 车间(employees.work_category)· positions 点名的岗位(position_ids,至少一个)。
--   【培训记录挂到这一门上】training_records.required_training_id(HR 的培训表单里选)。不挂的老记录照旧在,页面把它们数成「没挂到必修培训」。
--   【到期】一条记录的到期日 = 它自己写的 expiry_date;没写而这一门有有效期 → completed_date + 有效期;两样都没有 → 不过期。
--     「快到期」= 90 天内,「紧急」= 30 天内(与 hr_alerts 的 training_expiry 同一组窗口,Q8)。
--   【停用不删】retired_at:不再必修的一门从覆盖里拿掉,挂着它的记录照旧在。
--   【写】只经 required_training_save / required_training_retire(action.manage_esg:admin · cco · cfo)。【读】module.hr.view 或 action.manage_esg。
--
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
-- First-run script (plain CREATEs).
CREATE TABLE public.required_trainings (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name             text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    category         text CHECK (category IN ('induction','safety','compliance','cybersecurity','technical','leadership','other')),
    validity_months  integer CHECK (validity_months IS NULL OR validity_months BETWEEN 1 AND 240),
    applies_to       text NOT NULL CHECK (applies_to IN ('everyone','office','shopfloor','positions')),
    position_ids     uuid[] NOT NULL DEFAULT '{}'::uuid[],
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid DEFAULT auth.uid(),
    retired_at       timestamptz,
    retired_by       uuid,
    CONSTRAINT required_trainings_positions_shape CHECK ((applies_to = 'positions') = (cardinality(position_ids) > 0)),
    CONSTRAINT required_trainings_retired_shape CHECK ((retired_at IS NULL) = (retired_by IS NULL))
);
CREATE UNIQUE INDEX required_trainings_name_active ON public.required_trainings (lower(btrim(name))) WHERE retired_at IS NULL;
COMMENT ON TABLE public.required_trainings IS
    'ESG-2(Q8):必修培训清单 —— 名字、类别、有效期(月)、对谁必须(全体 / 办公室 / 车间 / 点名的岗位)。培训记录经 training_records.required_training_id 挂上来;培训合规页按它算覆盖与到期。停用不删。只经 required_training_save / _retire 写(action.manage_esg)。';
CREATE TRIGGER trg_required_trainings_updated_at
    BEFORE UPDATE ON public.required_trainings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
ALTER TABLE public.required_trainings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "required_trainings select by permission" ON public.required_trainings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_any_permission(ARRAY['module.hr.view'::text, 'action.manage_esg'::text])));
-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是两支属主权限函数。
REVOKE ALL ON public.required_trainings FROM authenticated, anon;
GRANT SELECT ON public.required_trainings TO authenticated;
