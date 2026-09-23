-- db/tables/employee_accounts.sql
-- APR-ROUTE-1 Batch B(Tim 的 R3 · Q6):【一个人的额外账号】。
--
-- 【它为什么存在】Tim 会有 admin@swm-os.test,以及之后一个只持 cfo 的账号。
-- employees.user_id 一个员工只放得下一个账号(partial unique index),而自批拒绝、
-- R2 的自批标记、"除了主角还有没有人批得动"都必须认【人】—— 否则第二个账号会
-- 【不带任何标记地】批掉它主人的单。
--
-- 【形状】employees.user_id 仍然是【主账号】;本表只放【额外】的账号:
--   · user_id 是主键 —— 一个账号最多属于一个人;
--   · 一个账号不许既是某人的主账号、又在本表里(两道守卫,两个方向,见下);
--   · "这个账号是谁"的唯一定义是 account_person(),它先查主账号、再回落到本表。
--
-- 【写只经过两支函数】link_additional_account / unlink_additional_account,
-- 闸 action.manage_permissions(Tim 的 Q9)。本表没有 INSERT/UPDATE/DELETE 策略。
-- 每一次链接与解除都落一行 employee_account_history(Q2,只增不改)。
--
-- 【谁读得到】与 employees.user_id 同一批人(人事,外加管账号的人),
-- 外加【这个账号自己】—— ActorName 靠它把第二个账号做的事印成那个人的名字。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1b-one-person-several-accounts-and-gm-reads.sql.

CREATE TABLE public.employee_accounts (
    user_id      uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
    employee_id  uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    linked_at    timestamptz NOT NULL DEFAULT now(),
    linked_by    uuid
);

CREATE INDEX idx_employee_accounts_employee ON public.employee_accounts (employee_id);

COMMENT ON TABLE public.employee_accounts IS
    'APR-ROUTE-1 Batch B(R3):一个人的【额外】登录账号。employees.user_id 仍是主账号;一个账号最多属于一个人(主键),且不许既是主账号又在本表里(guard_employee_account_not_primary · guard_employee_user_not_additional)。"这个账号是谁"的唯一定义是 account_person()。只经 link_additional_account / unlink_additional_account 写(action.manage_permissions),每一次都落 employee_account_history。';

-- ★ 一个账号不许同时是某人的主账号 —— 本表这一侧的守卫
CREATE TRIGGER trg_employee_accounts_not_primary
    BEFORE INSERT OR UPDATE ON public.employee_accounts
    FOR EACH ROW EXECUTE FUNCTION public.guard_employee_account_not_primary();

-- 迁移以 postgres 建表,本来就没有 anon;重建的 prelude 会多给一份 —— 显式收掉
-- (scripts/check-anon-grant-decision.mjs 要求每一张新表对 anon 表态)。
REVOKE ALL ON public.employee_accounts FROM anon;

ALTER TABLE public.employee_accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "employee_accounts select"
    ON public.employee_accounts
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text)
           OR has_permission('action.manage_permissions'::text)
           OR user_id = auth.uid());
