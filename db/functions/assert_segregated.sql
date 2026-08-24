-- db/functions/assert_segregated.sql
-- SOD-1:职责分离【那条规矩本身】—— 一次比较,一处 RAISE。
--
-- 规矩只有一句:**做第二步的人,不可以是做过第一步的那个人。**
-- 两条路(过账+关账 / 建收款人+付款)共用这一份实现;它们不同的是【问法】,
-- 不是规矩 —— 取数由 sod_manual_posters_in() 与 sod_supplier_creator() 各自回答。
-- 错误码当参数收,因为两条路的【出路】不是同一句话,而拒绝必须说出出路。
--
-- 【两处 RETURN 都是有意的,而且含义不同】
--   · auth.uid() 为 NULL:没有主语可比(迁移、后台作业、service_role)。
--     它意味着**不设 claims 的 fixture 是空转的** —— db/fixtures/127 每一臂都设。
--   · 主语集合为空:规矩【不适用】,而那与"查过了,没问题"不是一回事。
--     今天对 8 家 created_by 为 NULL 的既有供应商成立,记在
--     docs/known-issues.md 的 SOD-1-BLIND 条。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql.

CREATE OR REPLACE FUNCTION public.assert_segregated(p_code text, p_first_actors uuid[], p_subject text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_actor uuid := auth.uid();
BEGIN
    -- 【没有主语时不判】auth.uid() 为 NULL 的调用方是迁移、后台作业、service_role ——
    -- 它们本来就绕过 RLS,这里不是一个新洞。但它意味着**以 postgres 跑的 fixture
    -- 不设 claims 就是空转的**(AGENTS.md 反复记过的那种"空洞的臂"),
    -- 所以 db/fixtures/127 每一臂都设 request.jwt.claims。
    IF v_actor IS NULL THEN
        RETURN;
    END IF;

    -- 【空集就是空集,不是"通过"】第一步没有留下主语(例如 created_by 为 NULL)时,
    -- 这条规矩**没有可比的对象**,于是它不适用 —— 而"不适用"与"查过了,没问题"
    -- 不是一回事。这个区别写在 docs/known-issues.md 的 SOD-1-BLIND 条,
    -- 因为它今天对 8 家既有供应商成立。
    IF p_first_actors IS NULL OR cardinality(p_first_actors) = 0 THEN
        RETURN;
    END IF;

    IF v_actor = ANY (p_first_actors) THEN
        RAISE EXCEPTION '%|%', p_code, COALESCE(p_subject, '?');
    END IF;
END;
$function$;