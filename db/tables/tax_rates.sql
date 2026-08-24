-- db/tables/tax_rates.sql
-- GST-1:税率按【生效期间】挂在税码上,而不是写成税码的一个列或一个设置项。
--
-- ★【为什么是一张表,不是一个数字】★ 新加坡的标准税率在这段历史里变过两次:
--   7%(2007-07-01 起)→ 8%(2023-01-01)→ 9%(2024-01-01)。
--   一张 2022 年的发票永远是 7%,重开、贷记、更正申报都得拿到 7%。
--   把税率放在设置里,"改税率"这一个动作会把全部历史单据一起改掉,
--   而且没有任何人会看见 —— 报表安静地变了,没有一条错误。
--
-- ★【没有回退】★ tax_rate_for(code, date) 找不到那一天的生效税率就按名拒:
--   TAX_RATE_NOT_FOUND|code|date。不取最近的一条、不取默认值、不返回 0。
--   这与 FX 那条规矩逐字同源 —— 编一个税率与编一个汇率是同一种谎,
--   而且两者都会以"报表算得出来"的样子通过所有测试。
--
-- 【一次法定调整怎么做】给旧行封口(effective_to = 生效日前一天)+ 插一行新的。
--   不 UPDATE 旧行的 rate_pct:那会把历史一起改掉。
--
-- 【BL 有税率】9% —— 不可抵扣不是"没有税",而是"有税但要不回来":
--   那笔税进采购成本本身,不进 box7。
--
-- 写入只走 SECURITY DEFINER 函数;这里只开 SELECT。
--
-- NOTE: introduced by db/migrations/2026-08-24-gst1-tax-codes-f5-and-filing-periods.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.tax_rates (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tax_code       text NOT NULL REFERENCES public.tax_codes (code),
    rate_pct       numeric(6,3) NOT NULL CHECK (rate_pct >= 0 AND rate_pct <= 100),
    effective_from date NOT NULL,
    effective_to   date,          -- NULL = 至今仍生效
    note           text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tax_rates_window CHECK (effective_to IS NULL OR effective_to >= effective_from),
    -- 同一个税码同一天不能有两条生效行 —— 否则 tax_rate_for 的答案取决于排序,
    -- 而一个取决于排序的税率不是一个税率。
    CONSTRAINT tax_rates_one_start UNIQUE (tax_code, effective_from)
);

ALTER TABLE public.tax_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "tax_rates select by permission"
    ON public.tax_rates
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- ─────────────────────────────────────────────────────────────────────────────
-- 【安装种子:法定税率史】。逐行跟踪线上(check_mirrors 的 SEED_TABLES)。
-- 这一段比大多数种子更硬:一行写错,一张历史单据就会拿到一个当时并不适用的税率,
-- 而且它算得出数、报得出表,不会有任何一条报错提醒。
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.tax_rates (tax_code, rate_pct, effective_from, effective_to, note) VALUES
    ('BL', 9.000, '2024-01-01', NULL, 'Blocked: tax exists but is not claimable'),
    ('EP', 0.000, '2007-07-01', NULL, 'Exempt carries no tax'),
    ('ES', 0.000, '2007-07-01', NULL, 'Exempt carries no tax'),
    ('OP', 0.000, '2007-07-01', NULL, 'Out of scope carries no tax'),
    ('OS', 0.000, '2007-07-01', NULL, 'Out of scope carries no tax'),
    ('SR', 7.000, '2007-07-01', '2022-12-31', 'Statutory 7% (2007-07-01 to 2022-12-31)'),
    ('SR', 8.000, '2023-01-01', '2023-12-31', 'Statutory 8% (Budget 2022 step 1)'),
    ('SR', 9.000, '2024-01-01', NULL, 'Statutory 9% (Budget 2022 step 2)'),
    ('TX', 7.000, '2007-07-01', '2022-12-31', 'Input side mirrors the output rate'),
    ('TX', 8.000, '2023-01-01', '2023-12-31', 'Input side mirrors the output rate'),
    ('TX', 9.000, '2024-01-01', NULL, 'Input side mirrors the output rate'),
    ('ZP', 0.000, '2007-07-01', NULL, 'Zero-rated is 0% by definition'),
    ('ZR', 0.000, '2007-07-01', NULL, 'Zero-rated is 0% by definition');

COMMENT ON TABLE public.tax_rates IS
    'GST-1:税率按【生效期间】挂在税码上。一次法定调整 = 给旧行封口 + 插一行新的;历史单据不受影响。**没有回退** —— 某天没有生效税率就按名拒(TAX_RATE_NOT_FOUND),与 FX 那条「没有牌价就拒绝,绝不假设」逐字同源。';
