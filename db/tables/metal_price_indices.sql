-- db/tables/metal_price_indices.sql
-- 金属行情的【指数】字典(METAL-2)。Doc 1 里 Tim 的原话是产出按 "LME or SMM"
-- 计价 —— 合同挑指数,所以指数必须是行情的一个轴,而不是一句备注。
--
-- NOTE: introduced by db/migrations/2026-08-11-metal2-two-series-lme-and-smm.sql.
-- First-run script (plain CREATEs).
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG —— 下面的种子是"全新安装的默认值",不是线上快照】
-- 加第三个指数(Fastmarkets、Asian Metal)应当是【加一行】,不是跑一次迁移 ——
-- 与 certificate_types 同一条。所以它是表,不是 CHECK 约束。
-- 写入策略开在 module.pricing.edit;读给所有登录用户(行情是市场事实,OPS-15)。
-- 【线上与本文件不一致是正常的】,check_mirrors.py 不逐行比对本表。
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 【指数与 source 是两个轴,不要合并】source 答的是"这个数字怎么来的"
-- (manual / 将来的 feed:lme),指数答的是"这是哪个市场的数字"。将来抓 LME 的
-- 喂价要【同时】说 feed 与 LME,手键的 SMM 要同时说 manual 与 SMM ——
-- 挤进一列,两句话都说不成。

CREATE TABLE public.metal_price_indices (
    code           text PRIMARY KEY,
    name_en        text NOT NULL,
    name_zh        text NOT NULL,
    quote_currency text REFERENCES public.currencies (code),
    is_active      boolean NOT NULL DEFAULT true,
    sort_order     integer NOT NULL DEFAULT 0,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid DEFAULT auth.uid(),
    -- ── METAL-3 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 这个 quote_currency 是【怎么定下来的】—— 见下面的列注释。
    -- 'contract' = 有签下来的合同这么写;'house_assumption' = 公司认为合理,
    -- 但还没有任何一笔交易这么约定过。
    quote_currency_basis text
        CHECK (quote_currency_basis IN ('house_assumption','contract')),
    -- 声明了币种就必须说清它是怎么来的 —— 否则"CNY"会读成一条合同条款
    CONSTRAINT metal_price_indices_currency_basis_shape
        CHECK (quote_currency IS NULL OR quote_currency_basis IS NOT NULL)
);

COMMENT ON COLUMN public.metal_price_indices.quote_currency_basis IS
$$这个指数的 quote_currency 是【怎么定下来的】:'contract' = 有签下来的合同这么写;
'house_assumption' = 公司认为合理、但还没有任何一笔交易这么约定过。

为什么要有这一列:光写 quote_currency = 'CNY' 会读成"合同就是这么定的"。
Tim 给出 CNY 时明说了那是他认为合理的条款,而不是签下来的 —— 今天一笔 SMM 交易
都还没有。真的 SMM 合同出现时可能另有说法,而代码不该读起来像是已经知道了。
计价出处里一并记下当时是哪一种,于是【按假设算出来的那些数】日后与【按合同算出来的】
分得开。合同落地时改这一个字段,不需要动任何代码。$$;

COMMENT ON COLUMN public.metal_price_indices.quote_currency IS
$$这个指数按什么货币报价。【NULL = 还没有人声明,而不是"未知所以按 USD 算"】——
按一个没声明币种的指数计价会被点名拒绝(INDEX_CURRENCY_NOT_STATED),而不是把那些
数字默认当成美元。新加进来的指数默认就是这个状态。

【这个币种是怎么定下来的,看 quote_currency_basis】'contract' 是签下来的,
'house_assumption' 是公司认为合理但还没有任何一笔交易这么约定过。两者在计价出处里
都会被记下,于是"按假设算出来的数"日后与"按合同算出来的"分得开。

SMM 今天是 CNY / house_assumption(METAL-3):Tim 说了按当天汇率换算是合理的做法,
但一笔 SMM 交易都还没有。换算发生在【读的时候】,按【报价那一天】的中间价,
两条腿(报价币 → 本位币 → USD);报价本身按发布原样以 CNY 存,
存成换好的 USD 会把某一天的汇率焊进一条市场记录、并丢掉原始数字。$$;

ALTER TABLE public.metal_price_indices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "metal_price_indices select"
    ON public.metal_price_indices AS PERMISSIVE FOR SELECT TO authenticated USING (true);

CREATE POLICY "metal_price_indices write by permission"
    ON public.metal_price_indices AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.pricing.edit'))
    WITH CHECK (has_permission('module.pricing.edit'));

-- ── 引导 ────────────────────────────────────────────────────────────────────
INSERT INTO public.metal_price_indices (code, name_en, name_zh, quote_currency, quote_currency_basis, sort_order, notes) VALUES
    ('LME', 'London Metal Exchange', '伦敦金属交易所', 'USD', 'contract', 1,
     'USD/吨是 LME 的市场惯例 —— 这一条是市场事实,不是某一笔合同的条款,所以按 contract(已确定)记,不是房屋假设。'),
    ('SMM', 'Shanghai Metals Market', '上海有色网', 'CNY', 'house_assumption', 2,
     'SMM 以 CNY/吨发布。报价币种【CNY 是房屋假设,不是合同条款】—— Tim 认为按当天汇率换算是合理的做法,但今天还没有任何一笔 SMM 交易这么约定过(quote_currency_basis = house_assumption)。真的合同出现时可能另有说法,届时改这一行即可。换算发生在读的时候:按【报价那一天】的中间价,两条腿(CNY→本位币→USD)。');
