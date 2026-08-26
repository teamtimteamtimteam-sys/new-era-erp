-- FX-RATES-1 FU2(2026-08-27):批量录入的包装 —— 它【循环调用同一个函数】。
-- NOTE: apply with ./db/apply_migration.sh
--
-- 【为什么是包装而不是第二份实现】一个写入口的全部力气在这一句:
-- **表格【不可能】比表单校验得松,因为没有第二个地方可以放松。**
-- 本函数一行代码的校验都没有 —— 它只负责【一笔事务】与【逐格报错】。
--
-- 【全有或全无】一格不合格,整次提交都不落地。理由不是洁癖:
-- **半张存进去的周表在列表页上【看起来是完整的】** —— 于是没存上的那两行
-- 正是没有人会注意到、直到某次月结被挡住才发现的那两行。
-- 而那恰恰是这一刀要修的病,从另一条路走回来。(import_bank_statement 同一条。)
--
-- 【逐格报错】抛出来的信息带上是第几行,让人改得动:
-- FX_BULK_ROW|<序号>|<原始错误>。

BEGIN;

CREATE OR REPLACE FUNCTION public.record_fx_rates_bulk(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_row   jsonb;
    v_idx   integer := 0;
    v_done  integer := 0;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
        RAISE EXCEPTION 'FX_BULK_INVALID';
    END IF;
    IF jsonb_array_length(p_rows) = 0 THEN
        RAISE EXCEPTION 'FX_BULK_EMPTY';
    END IF;

    FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
        v_idx := v_idx + 1;
        BEGIN
            -- 【就是那一个函数】校验、留痕、未来日期的拒绝,全在它里面。
            -- p_reason 恒为 NULL:批量只【填空】,不覆盖 —— 已在册的那一格
            -- 会被 record_fx_rate 自己按 FX_RATE_EXISTS 挡回来。
            PERFORM record_fx_rate(
                v_row->>'currency',
                (v_row->>'rate_date')::date,
                v_row->>'rate_type',
                (v_row->>'rate')::numeric,
                COALESCE(v_row->>'source', 'DBS'),
                NULLIF(btrim(COALESCE(v_row->>'notes', '')), ''),
                NULL);
            v_done := v_done + 1;
        EXCEPTION WHEN OTHERS THEN
            -- 【带上第几行再抛】整笔事务照样回滚(全有或全无),
            -- 但人得知道是哪一格。
            RAISE EXCEPTION 'FX_BULK_ROW|%|%', v_idx, SQLERRM;
        END;
    END LOOP;

    RETURN jsonb_build_object('recorded', v_done);
END;
$function$;

COMMIT;
