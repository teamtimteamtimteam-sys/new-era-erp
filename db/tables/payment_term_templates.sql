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
    updated_by  uuid DEFAULT auth.uid()
);

CREATE UNIQUE INDEX idx_payment_term_templates_name_live
    ON public.payment_term_templates (name) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_payment_term_templates_updated_at
    BEFORE UPDATE ON public.payment_term_templates
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.payment_term_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on payment_term_templates"
    ON public.payment_term_templates AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);
