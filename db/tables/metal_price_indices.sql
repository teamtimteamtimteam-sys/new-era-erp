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
    updated_by     uuid DEFAULT auth.uid()
);

COMMENT ON COLUMN public.metal_price_indices.quote_currency IS
$$这个指数按什么货币报价。【NULL = 还没有人声明,而不是"未知所以按 USD 算"】。

为什么 SMM 这一行是空的,而且不该被顺手填上:SMM 在市场上以 CNY/吨发布,这一点
可以查到;但【这家公司的 SMM 合同按什么货币结算】是一条交易条款,不是一个市场事实,
而 Tim 没有说过。替他填一个,就是编造一条商务条款 —— 与给那条 80,000 编一个看起来
合理的铜价是同一种伪造(FIN-26:宁可空着,不可编造)。

空着的后果是【明写并且响亮的】:calculate_metal_price_from_terms 在算钱之前拒绝,
报 INDEX_CURRENCY_NOT_STATED|SMM。于是 SMM 这条序列今天就可以录入、可以打标签、
可以在界面上看见,但【在 Tim 回答之前算不出钱】。这正是它该有的样子。

如果答案是 CNY:那是 currencies 里加一行、外加一条换算路径,而换算路径自带
"用哪一天的汇率"这个问题(THE FX RULE 管着它)—— 那是它自己的一刀,
不是在这里顺手改个列名。$$;

ALTER TABLE public.metal_price_indices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "metal_price_indices select"
    ON public.metal_price_indices AS PERMISSIVE FOR SELECT TO authenticated USING (true);

CREATE POLICY "metal_price_indices write by permission"
    ON public.metal_price_indices AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.pricing.edit'))
    WITH CHECK (has_permission('module.pricing.edit'));

-- ── 引导 ────────────────────────────────────────────────────────────────────
INSERT INTO public.metal_price_indices (code, name_en, name_zh, quote_currency, sort_order, notes) VALUES
    ('LME', 'London Metal Exchange', '伦敦金属交易所', 'USD', 1,
     'USD/吨是 LME 的市场惯例 —— 这一条是市场事实,可以直接声明。'),
    ('SMM', 'Shanghai Metals Market', '上海有色网', NULL, 2,
     '报价币种【故意留空】:SMM 在市场上以 CNY/吨发布,但本公司的 SMM 合同按什么货币结算是一条交易条款,Tim 尚未声明。填一个就是编造条款 —— 在他回答之前,按此指数计价会被点名拒绝(INDEX_CURRENCY_NOT_STATED)。理由全文见 metal_price_indices.quote_currency 的列注释。');
