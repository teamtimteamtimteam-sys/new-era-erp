-- db/tables/wht_rates.sql
-- WHT-1:预提税率按【生效期间】挂在性质上,与 db/tables/tax_rates.sql 逐字同形。
--
-- ★【没有回退】★ wht_rate_for(nature, date) 找不到那一天的生效税率就按名拒:
--   WHT_RATE_NOT_FOUND|nature|date。不取最近的一条、不取默认值、不返回 0。
--   与 FX 和 GST 那两条规矩逐字同源 —— 编一个税率与编一个汇率是同一种谎。
--
-- ★★【表里的【内容】是一项法律事实,这个仓库没有认定它的资格】★★
--   形状是工程判断,已经做完;那六个数不是。每一行的 note 写着它的出处,
--   而「SEED BASELINE」是一句诚实话:起始日期是这张表的基线,
--   不是查证过的法令生效日。**第一笔真实的非居民付款之前必须逐行核对。**
--   同一句话写在 docs/accounting-policies.md,那份是给公司外面的人看的。
--
-- NOTE: introduced by db/migrations/2026-08-28-wht1-withholding-tax-on-non-resident-payments.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.wht_rates (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nature         text NOT NULL REFERENCES public.wht_natures (code),
    rate_pct       numeric(6,3) NOT NULL CHECK (rate_pct >= 0 AND rate_pct <= 100),
    effective_from date NOT NULL,
    effective_to   date,          -- NULL = 至今仍生效
    note           text NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT wht_rates_window CHECK (effective_to IS NULL OR effective_to >= effective_from),
    -- 同一种性质同一天不能有两条生效行 —— 否则 wht_rate_for 的答案取决于排序,
    -- 而一个取决于排序的税率不是一个税率(与 tax_rates_one_start 同一条)。
    CONSTRAINT wht_rates_one_start UNIQUE (nature, effective_from)
);

ALTER TABLE public.wht_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "wht_rates select by permission"
    ON public.wht_rates
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

INSERT INTO public.wht_rates (nature, rate_pct, effective_from, effective_to, note) VALUES
    -- 【''none'' 的 0% 不是一个税率,是那个显式判断的算术后果】它存在是为了让
    -- wht_rate_for 对每一个在册性质都答得出来 —— 一个"某些性质有率、某些没有"的
    -- 字典,会逼每一个调用方自己写一个特例分支,而那就是第二份实现。
    ('none',                   0.000, '1900-01-01', NULL,
     'Not subject to withholding — 0% is the arithmetic consequence of a recorded judgement, not a statutory rate. Dated from 1900 so the answer never depends on the document date.'),
    ('interest',              15.000, '2007-07-01', NULL,
     'ITA s45 — 15% on the gross payment. SEED BASELINE: the start date is this table''s baseline, not a researched commencement date.'),
    ('royalty',               10.000, '2007-07-01', NULL,
     'ITA s45A — 10% on the gross payment. SEED BASELINE: see the interest row.'),
    ('know_how',              10.000, '2007-07-01', NULL,
     'ITA s45A — 10% on the gross payment. SEED BASELINE: see the interest row.'),
    ('rent_movable_property', 15.000, '2007-07-01', NULL,
     'ITA s45D — 15% on the gross payment. SEED BASELINE: see the interest row.'),
    ('management_fee',        17.000, '2010-01-01', NULL,
     'Prevailing corporate rate, 17% from YA2010. A payment dated before 2010-01-01 refuses by name — the earlier history is deliberately not seeded rather than guessed.'),
    ('technical_service_fee', 17.000, '2010-01-01', NULL,
     'Prevailing corporate rate, 17% from YA2010. Same boundary as management_fee.');

COMMENT ON TABLE public.wht_rates IS
'WHT-1:预提税率按【生效期间】挂在性质上。一次法定调整 = 给旧行封口 + 插一行新的,
不 UPDATE 旧行 —— 那会把历史一起改掉。**没有回退**:某天没有生效税率就按名拒
(WHT_RATE_NOT_FOUND),不取最近的一条、不返回 0。与 tax_rate_for 和 fx_rate_for
逐字同源 —— 编一个税率、编一个汇率,是同一种谎,而且两者都会以"报表算得出来"的
样子通过所有测试。

★★【这张表的【内容】是一项法律事实,而这个仓库【没有】认定它的资格】★★
形状(按日期解析、不回退、一次调整封口加行)是工程判断,已经做完了。
**里面那六个数不是。** 它们按上面 note 里写着的出处种下,而每一行的
"SEED BASELINE" 是一句诚实话:起始日期是这张表的基线,不是查证过的法令生效日。
**在第一笔真实的非居民付款之前,这六行必须由 Tim 或会计师逐行核对。**
核对之前,这套机器会算出数、报得出表、一条错误都不会有 —— 那正是危险所在。
这一条同时写在 docs/accounting-policies.md,那份文件是给公司【外面】的人看的。

【条约(DTA)不在这张表里】双边税收协定可以把这些税率【调低】,而适用与否
取决于对方能不能出具居民证明书。那是【逐笔的判断】,不是一个可以按日期查出来的
标量 —— 所以它是债务上的一个覆盖值 + 一个证明书编号,见 expenses.wht_treaty_ref。';
