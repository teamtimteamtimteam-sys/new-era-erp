-- db/tables/medical_claims.sql
-- 医疗报销。批准时【不自动记费用】—— 付款路径待定,见 expense_id 一列。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.medical_claims (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code           text NOT NULL UNIQUE,
    employee_id    uuid NOT NULL REFERENCES public.employees (id),
    claim_date     date NOT NULL,
    claim_year     integer NOT NULL,
    amount_sgd     numeric NOT NULL CHECK (amount_sgd > 0),
    description    text,
    receipt_ref    text,
    status         text NOT NULL DEFAULT 'submitted'
                   -- EMP-SELF-1:'withdrawn' —— 员工撤回自己还没被决定的申报(withdraw_medical_claim)
                   CHECK (status IN ('submitted','approved','rejected','paid','withdrawn')),
    decided_at     timestamptz,
    decided_by     uuid,
    decision_notes text,
    -- 【付款方式是 Tim 的运营决定】:走薪资代发,还是单独付款并入账为费用。
    -- 本切【不自动过账】—— 这一列留着,等他定了再把两边挂上。
    expense_id     uuid REFERENCES public.expenses (id),
    deleted_at     timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid DEFAULT auth.uid(),
    -- EMP-SELF-1(ALTER 加的列,留在末尾):撤回的时刻;与报销单同一条形状约束
    withdrawn_at   timestamptz,
    CONSTRAINT medical_claims_withdraw_shape
        CHECK ((status = 'withdrawn') = (withdrawn_at IS NOT NULL))
);

CREATE INDEX idx_medical_claims_employee ON public.medical_claims (employee_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_medical_claims_year ON public.medical_claims (claim_year);


-- SEARCH-2 · 迁移 A:code 上的 trigram GIN —— 买的是【后缀匹配】(`%0001`)。
-- btree 服务得了后缀(强制走索引时规划器会选 code_key 做 Bitmap Index Scan),
-- 但它 seek 不了;今天 319 行上量不出差别,合成 20 万行时 12.0ms vs 33.4ms。
-- 扩展由 db/platform-prelude.sql §4 提供(连同那条 search_path)。
CREATE INDEX medical_claims_code_trgm ON public.medical_claims USING gin (code extensions.gin_trgm_ops);

-- SEARCH-2b · 迁移 C:「最近编辑过」要的那一条 —— `updated_by = auth.uid()`
-- 按 updated_at DESC 取前 5(T3)。SEARCH-0 §Q5 实测:这两列上此前一条索引都没有。
CREATE INDEX medical_claims_recents ON public.medical_claims (updated_by, updated_at DESC);

-- SEARCH-4 · 迁移 B:关联搜索走这一列。为将来的体量建,不为今天的毫秒数
--(320 行上规划器一律 Seq Scan;理由与迁移 A/C 逐字同族)。
CREATE INDEX medical_claims_expense_id_rel ON public.medical_claims (expense_id);
CREATE TRIGGER trg_medical_claims_updated_at
    BEFORE UPDATE ON public.medical_claims
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.medical_claims ENABLE ROW LEVEL SECURITY;
CREATE POLICY "medical_claims select by permission"
    ON public.medical_claims AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "medical_claims select own rows"
    ON public.medical_claims AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());
CREATE POLICY "medical_claims insert by permission"
    ON public.medical_claims AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "medical_claims update by permission"
    ON public.medical_claims AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "medical_claims delete by permission"
    ON public.medical_claims AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ★ U1-A(UNBLOCK-1 Q8,2026-10-05):健康数据要 data.view_health。description(看病的事由)与 amount_sgd(报销金额)
--   从列授权里拿掉,只经 medical_claims_masked 读 —— 那里给持 data.view_health 的人,并【对本人让路】(自己的报销单照旧读得到)。
--   此前 6 个账号里持 module.hr.view 的每一个都读得到别人看病的事由;cto · gm · warehouse 从此读不到。
--   表级 SELECT 授权蕴含所有列,所以先整表收回、再逐列授回(employees 与 payroll_lines 同一个做法);写权限不动。
--   列授权不随 ADD COLUMN 自动延伸:给这张表加列,要回到这一行,并把它放进 medical_claims_masked(gate 的 colgrant)。
REVOKE SELECT ON public.medical_claims FROM authenticated, anon;
-- ★ U1-B(2026-10-05,Tim 对医疗报销费用单的裁定):decision_notes(HR 写的批准 / 驳回理由)也是健康的字 —— 从列授权里拿掉,
--   与 description 同一个判据(data.view_health,或本人)。它此前经费用单那一页的审计记录给了每一个持 module.hr.view 的财务读者。
GRANT SELECT (id, code, employee_id, claim_date, claim_year, receipt_ref, status, decided_at, decided_by,
              expense_id, deleted_at, created_at, created_by, updated_at, updated_by, withdrawn_at)
    ON public.medical_claims TO authenticated;

-- ============================================================================

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.medical_claims
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
