-- db/tables/customer_credit_history.sql
-- 客户信用限额/冻结的只增不改变动史(SAL-B,pricing_formula_history 的形状)。
-- 触发器写入 —— 客户编辑是普通 UPDATE,没有 RPC 可挂;为推一单而抬限额是最该
-- 留痕的动作。触发器之前的状态没有行:空白好过编造。
-- NOTE: introduced by db/migrations/2026-08-10-salb-credit-control.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.customer_credit_history (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id       uuid NOT NULL REFERENCES public.customers (id),
    old_credit_limit_base numeric,
    new_credit_limit_base numeric,
    old_credit_hold   boolean,
    new_credit_hold   boolean,
    changed_at        timestamptz NOT NULL DEFAULT now(),
    changed_by        uuid
);

CREATE INDEX idx_customer_credit_history_customer
    ON public.customer_credit_history (customer_id, changed_at DESC);

COMMENT ON TABLE public.customer_credit_history IS
    '客户信用限额/冻结的只增不改变动史(SAL-B,pricing_formula_history 的形状)。触发器写入 —— 客户编辑是普通 UPDATE,没有 RPC 可挂。为推一单而抬限额是最该留痕的动作。触发器之前的状态没有行:空白好过编造。';

-- 写入触发器挂在 customers 上,镜像也在 db/tables/customers.sql(表在哪触发器在哪)

-- 守卫函数体在 db/functions/guard_customer_credit_history_append_only.sql

CREATE TRIGGER trg_customer_credit_history_append_only
    BEFORE UPDATE OR DELETE ON public.customer_credit_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_customer_credit_history_append_only();

ALTER TABLE public.customer_credit_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "customer_credit_history select by permission"
    ON public.customer_credit_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.customers.view'::text));
-- 【没有 INSERT 策略】唯一写入口是触发器(属主身份)—— 留痕不该有第二个写法
