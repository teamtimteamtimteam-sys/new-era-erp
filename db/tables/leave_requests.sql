-- db/tables/leave_requests.sql
-- 请假申请。days 由 submit_leave_request 算出,不采信调用方传入。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.leave_requests (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code            text NOT NULL UNIQUE,
    employee_id     uuid NOT NULL REFERENCES public.employees (id),
    leave_type_code text NOT NULL REFERENCES public.leave_types (code),
    start_date      date NOT NULL,
    end_date        date NOT NULL,
    start_half_day  boolean NOT NULL DEFAULT false,
    end_half_day    boolean NOT NULL DEFAULT false,
    -- days 由 submit_leave_request 用 calculate_leave_days 算出,【不采信调用方传入的值】
    days            numeric NOT NULL CHECK (days > 0),
    reason          text,
    certificate_ref text,
    status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','approved','rejected','cancelled')),
    decided_at      timestamptz,
    decided_by      uuid,
    decision_notes  text,
    deleted_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid DEFAULT auth.uid(),
    -- cut 2b 例外路径。【ALTER 加的列留在末尾】,与线上 attnum 顺序一致(见 AGENTS.md)。
    -- days 由 HR 手填而非 calculate_leave_days 算出,两种情形:
    -- 六天制/轮班下周一至周五口径不对;以及逐案变通标准天数(恩恤/婚假)。
    is_exception    boolean NOT NULL DEFAULT false,
    exception_reason text,
    CONSTRAINT leave_requests_date_order CHECK (end_date >= start_date),
    -- 没有理由的例外,三个月后没人知道当时为什么这么批
    CONSTRAINT leave_requests_exception_reason
        CHECK (NOT is_exception OR (exception_reason IS NOT NULL AND btrim(exception_reason) <> ''))
);

CREATE INDEX idx_leave_requests_employee ON public.leave_requests (employee_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_leave_requests_status ON public.leave_requests (status);
CREATE INDEX idx_leave_requests_start ON public.leave_requests (start_date);


-- SEARCH-2 · 迁移 A:code 上的 trigram GIN —— 买的是【后缀匹配】(`%0001`)。
-- btree 服务得了后缀(强制走索引时规划器会选 code_key 做 Bitmap Index Scan),
-- 但它 seek 不了;今天 319 行上量不出差别,合成 20 万行时 12.0ms vs 33.4ms。
-- 扩展由 db/platform-prelude.sql §4 提供(连同那条 search_path)。
CREATE INDEX leave_requests_code_trgm ON public.leave_requests USING gin (code extensions.gin_trgm_ops);

-- SEARCH-2b · 迁移 C:「最近编辑过」要的那一条 —— `updated_by = auth.uid()`
-- 按 updated_at DESC 取前 5(T3)。SEARCH-0 §Q5 实测:这两列上此前一条索引都没有。
CREATE INDEX leave_requests_recents ON public.leave_requests (updated_by, updated_at DESC);
CREATE TRIGGER trg_leave_requests_updated_at
    BEFORE UPDATE ON public.leave_requests
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.leave_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "leave_requests select by permission"
    ON public.leave_requests AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
-- 自助:自己的申请自己看得见(权限 cut 4 的行级模式)
CREATE POLICY "leave_requests select own rows"
    ON public.leave_requests AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());

-- ★ LEAVE-BAL-1(Tim Q12,2026-09-28):【写只走 SECURITY DEFINER 函数】——
--   submit_leave_request / decide_leave_request / cancel_leave_request。
--   此前持 module.hr.edit 的人(admin · finance · hr)可以经 PostgREST 直接 INSERT 一张单、
--   或把一张单 UPDATE 成 approved、改它的天数,整个绕过余额检查与四眼。
--   于是这里【故意】没有 INSERT / UPDATE / DELETE 策略,并且收回写权限 —— 先例 import_batches。
--   读照旧:上面两条读策略不动。
REVOKE ALL ON public.leave_requests FROM authenticated;
GRANT SELECT ON public.leave_requests TO authenticated;

-- ============================================================================

-- 列注释:说明写在数据库里,重建出来的库也带着它们(OPS-1 补齐)。
COMMENT ON COLUMN public.leave_requests.is_exception IS
    'True when days were entered by hand rather than computed from calculate_leave_days — for a six-day or shift schedule where Mon-Fri counting is wrong. Since LEAVE-BAL-1 (2026-09-28) an exception is balance-checked like any other request and cannot grant more than the entitlement: days beyond it are recorded as a separate unpaid-leave request.';

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
-- ★ LEAVE-BAL-1 之后 authenticated 已没有写权限(见上面的 REVOKE),直接写在触发器之前就 42501;
--   这支触发器留着,是第二道 —— 哪天有人把写权限授回去,它仍然拦住没有 module.hr.edit 的人。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.leave_requests
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
