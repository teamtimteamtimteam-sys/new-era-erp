-- db/tables/payment_term_templates.sql
-- 可复用的付款计划模板。
--
-- 【存在的唯一理由是省去重复录入】—— 回头客的条款往往一样,不该每张 PO 手敲一遍。
-- 模板【不是标准条款】,更不是默认值:套用与否完全自愿,套完之后 PO 上的那份计划就
-- 是独立的副本,改它不影响模板,改模板也不回溯已开的 PO。
--
-- 【本系统不预置任何模板】。迁移里一条种子数据都没有 —— 任何预设的拆法都是在替 Tim
-- 猜他跟某个交易对手谈成了什么,而这正是本切反复要避免的事。模板全部由用户自己建。
--
-- 未删除的模板之间名称唯一(partial unique index);删掉之后可以重用同名。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.payment_term_templates (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    description text,
    is_active   boolean NOT NULL DEFAULT true,
    deleted_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid DEFAULT auth.uid(),
    -- ── FIN-29 追加(ALTER 加的列排在末尾)──────────────────────────────────
    -- 定额腿的币种。【可空】:只有比例的模板不需要币种,百分比对任何币种都成立。
    -- 一旦模板里出现定额腿,这一列必须有值 —— 那条规则跨父子两张表,
    -- CHECK 写不出来(不许子查询),由 guard_template_fixed_needs_currency 执行。
    currency    text REFERENCES public.currencies (code)
);

COMMENT ON COLUMN public.payment_term_templates.currency IS
    '本模板【定额腿】的币种(FIN-29)。可空:只有比例的模板不需要币种,百分比对任何币种都成立。一旦模板里出现定额腿,这一列必须有值(守卫 guard_template_fixed_needs_currency 强制),而 apply_payment_term_template 只接受币种与之相同的采购单 —— 付款条款是谈定的承诺,不按牌价折算。';

CREATE UNIQUE INDEX idx_payment_term_templates_name_live
    ON public.payment_term_templates (name) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_payment_term_templates_updated_at
    BEFORE UPDATE ON public.payment_term_templates
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- FIN-29:清空币种时,若模板里还有定额腿则拦下(守卫函数在
-- db/functions/guard_template_fixed_needs_currency.sql;另一半挂在行表上 ——
-- 只挡一侧等于没挡)。
CREATE TRIGGER trg_ptt_fixed_needs_currency
    BEFORE UPDATE ON public.payment_term_templates
    FOR EACH ROW EXECUTE FUNCTION public.guard_template_fixed_needs_currency();

ALTER TABLE public.payment_term_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "payment_term_templates select by permission"
    ON public.payment_term_templates
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text));

CREATE POLICY "payment_term_templates insert by permission"
    ON public.payment_term_templates
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.purchasing.edit'::text));

CREATE POLICY "payment_term_templates update by permission"
    ON public.payment_term_templates
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.purchasing.edit'::text)) WITH CHECK (has_permission('module.purchasing.edit'::text));

CREATE POLICY "payment_term_templates delete by permission"
    ON public.payment_term_templates
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.purchasing.edit'::text));
