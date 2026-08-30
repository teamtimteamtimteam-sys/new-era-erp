-- db/functions/licence_storage_within_limit.sql
-- CMPL-1(R2):在场危废有没有超出执照批准的贮存上限 —— ★读不到输入就【抛】,绝不放行★
--
-- 【先例】anonymise_employee 在 hr_settings.personal_data_retention_months 为 NULL 时
--   `RAISE EXCEPTION 'PDPA_RETENTION_PERIOD_NOT_SET'`。**抛,不是返回一个凑合的答案。**
--   R2 引的正是这一条:一个"没录上限就一律通过"的检查比没有检查更坏 ——
--   没有检查时人知道自己不知道;有一个永远通过的检查时,人以为自己知道。
--
-- ★★【三种缺法给三条【不同】的码,绝不合并】★★
--   · LICENCE_STORAGE_LIMIT_NOT_SET       吨数算得出来,但没有人录过上限
--   · HAZARDOUS_QTY_NOT_COMPUTABLE        上限录了,但吨数算不出来
--   · LICENCE_STORAGE_INPUTS_BOTH_MISSING 两样都缺 —— **今天线上就是这一种**
--   合成一句话就是 CHAIN-BUILD-1 刚修好的那个病:两种不同的"缺"长得一样,
--   于是人去修错的那一件(去录上限,而真正缺的是那条根本没建的推导)。
--
-- 【它今天只会走第三条,而这不妨碍它上线】TOLL-0 把这条标准写进了
--   dashboard-arm-inventory:APR-2c 禁的是【一个无法被证明有判别力的屏幕元件】,
--   **不禁一条 fixture 建得出、触发得了、注入得动的【拒绝】**。fixture 152 走全三种 + 对照。
CREATE OR REPLACE FUNCTION public.licence_storage_within_limit()
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_limit numeric;
    v_qty   numeric;
BEGIN
    PERFORM require_permission('module.suppliers.view');

    -- 取【最宽松的那一张】在效执照上的上限:一家公司可能持多张执照,
    -- 而"有没有超"要对着真正管着它的那一张判。今天 0 行,所以必然是 NULL。
    SELECT max(approved_storage_limit_tonnes) INTO v_limit
      FROM company_compliance
     WHERE deleted_at IS NULL
       AND approved_storage_limit_tonnes IS NOT NULL
       AND (status IS NULL OR status = 'active')
       AND (valid_until IS NULL OR valid_until >= CURRENT_DATE);

    v_qty := hazardous_qty_on_hand_tonnes();

    -- ★ 三种缺法,三条码 —— 绝不合并 ★
    IF v_limit IS NULL AND v_qty IS NULL THEN
        RAISE EXCEPTION 'LICENCE_STORAGE_INPUTS_BOTH_MISSING';
    ELSIF v_limit IS NULL THEN
        RAISE EXCEPTION 'LICENCE_STORAGE_LIMIT_NOT_SET';
    ELSIF v_qty IS NULL THEN
        RAISE EXCEPTION 'HAZARDOUS_QTY_NOT_COMPUTABLE';
    END IF;

    -- 两样都在,才谈得上判断。
    RETURN v_qty <= v_limit;
END;
$function$;

COMMENT ON FUNCTION public.licence_storage_within_limit() IS
'CMPL-1(R2):在场危废有没有超出执照批准的贮存上限。★**读不到输入就抛,绝不放行**★ —— 一个"没录上限就一律通过"的实现比没有这道检查更坏,因为它**制造出信心**(与 PDPA 保留期未设时 anonymise_employee 按名拒是同一个形状,那也是 R2 引的先例)。★**三种缺法给三条不同的码**★:LICENCE_STORAGE_LIMIT_NOT_SET(吨数算得出、没录上限)/ HAZARDOUS_QTY_NOT_COMPUTABLE(录了上限、吨数算不出)/ LICENCE_STORAGE_INPUTS_BOTH_MISSING(两样都缺 —— **今天线上就是这一种**)。合成一句话就是 CHAIN-BUILD-1 刚修好的那个病:两种不同的零长得一样,人就会去修错的那一件。吨数为什么算不出来见 hazardous_qty_on_hand_tonnes()。';
