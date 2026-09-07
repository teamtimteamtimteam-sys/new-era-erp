-- db/tables/cod_verification_failures.sql
-- COD-2:核验查询的【失败预算】—— 限流的全部状态,一张表、两列。
--
-- ★★【为什么限流在库里,而不是在那条 Next 路由上】★★
--   委托书原文写的是"给路由限流"。那是错的,而错在一件可量的事上:
--   **anon key 是随浏览器包一起发出去的**,所以 POST /rest/v1/rpc/cod_verification
--   是【第二条门】,它根本不经过 Vercel。一个住在路由上的限流器,会被它要拦的
--   那个工具整个绕过去,同时在报告里印出一个数字。
--   第二条:应用跑在 Vercel(serverless)上,进程内计数器每次冷启动清零、
--   每个区域各算各的 —— 它连自己的依据都说不出来。
--
-- 【只记失败,而这是设计的关键】有效令牌【永不】被限流:攻击者拿不出有效令牌,
--   所以他限不掉任何一个真实持有人。一个连有效令牌也拦的全局预算,
--   等于给全世界发了一个拒绝服务开关。
--
-- 【表的规模封顶在 30 行上下】到了预算就不再插入,窗口自己滴干 ——
--   探测打不出一张会长大的表。数字与依据写在 cod_verification() 的函数体里。
--
-- 【没有任何 RLS 策略,这是刻意的】它不是给人读的东西:写它的只有
--   cod_verification()(SECURITY DEFINER),读它的没有人。
--
-- NOTE: introduced by db/migrations/2026-09-08-cod2-the-verification-page.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.cod_verification_failures (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    failed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE public.cod_verification_failures IS
    'COD-2:核验查询的【失败预算】。每一次查不到的核验(令牌不存在或格式不对)在这里留一行,超过预算之后一律回 throttled。★【有效令牌永不被限流】★ —— 攻击者拿不出有效令牌,所以他限不掉任何一个真实持有人。滚动窗口 10 分钟、预算 30 次,依据写在 cod_verification() 的函数体里。表的规模因此封顶在 30 行上下:到了预算就不再插入,窗口自己滴干。';

ALTER TABLE public.cod_verification_failures ENABLE ROW LEVEL SECURITY;

-- 【没有任何策略,这是刻意的】唯一的写入口是 cod_verification()。
REVOKE ALL ON public.cod_verification_failures FROM anon, authenticated;

CREATE INDEX idx_cod_verification_failures_at ON public.cod_verification_failures (failed_at);
