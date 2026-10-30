-- db/tables/contract_signatories.sql
-- CONTRACT-ESIGN(Tim 2026-10-29 · 2026-10-30 Q3):【签署人名单】—— 谁可以代表公司在系统里签合同。是【具名的人】,不是一个角色:
--   一行 = 一名有登录账号的员工 + 他签字时印出来的职衔。加入与移除都只经函数(contract_signatory_add / _remove),
--   要 action.manage_signatories(只授 admin);两次都进变更记录。
-- 【移除不删行】removed_at / removed_by 记下来;移除不作废他已经签过的任何一份(Q7)—— contract_files.signatory_id 指着这一行,
--   外键 RESTRICT 保证一份签过的文件永远找得到它的签署人那一行。一个人同一时刻最多一行在册(部分唯一索引);再加入是新的一行。
-- 【谁读】持 action.manage_signatories 的人读全部(设置页);每个人读得到自己那一行(签字页要知道自己在不在册)。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contract_signatories (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id  uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    title        text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 120),
    added_at     timestamptz NOT NULL DEFAULT now(),
    added_by     uuid NOT NULL,
    removed_at   timestamptz,
    removed_by   uuid,
    CONSTRAINT contract_signatories_removed CHECK ((removed_at IS NULL) = (removed_by IS NULL))
);

CREATE UNIQUE INDEX contract_signatories_one_active ON public.contract_signatories (employee_id) WHERE removed_at IS NULL;

COMMENT ON TABLE public.contract_signatories IS
    'CONTRACT-ESIGN(Tim 2026-10-29 · Q3):签署人名单 —— 具名的人(一名有登录账号的员工 + 职衔),不是角色。只经 contract_signatory_add / _remove 写(action.manage_signatories,只授 admin)。移除只记 removed_at,不作废他签过的任何一份(Q7)。';

-- 【只许移除一次,别的列不可改】函数之外的路也挡在这里。删行不挡:签过字的那一行由 contract_files 的外键(RESTRICT)护着,
--   没签过字的一行只有属主路径删得掉(没有任何删除策略)—— 一次性证明收尾时用。
CREATE OR REPLACE FUNCTION public.guard_contract_signatory_write()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF (to_jsonb(NEW) - 'removed_at' - 'removed_by') IS DISTINCT FROM (to_jsonb(OLD) - 'removed_at' - 'removed_by')
       OR OLD.removed_at IS NOT NULL THEN
        RAISE EXCEPTION 'CONTRACT_SIGNATORY_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_contract_signatories_guard
    BEFORE UPDATE ON public.contract_signatories
    FOR EACH ROW EXECUTE FUNCTION public.guard_contract_signatory_write();

ALTER TABLE public.contract_signatories ENABLE ROW LEVEL SECURITY;

CREATE POLICY "contract_signatories select by permission or own row" ON public.contract_signatories
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('action.manage_signatories'::text))
        OR employee_id = (SELECT current_user_employee()));

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是属主权限函数(contract_signatory_add · _remove)。
REVOKE ALL ON public.contract_signatories FROM authenticated, anon;
GRANT SELECT ON public.contract_signatories TO authenticated;
