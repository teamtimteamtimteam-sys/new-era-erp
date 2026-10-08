-- db/functions/guard_batch_module_count.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-5a Step 0 Q4 · Q6,Tim):【模组数这一列的三条规矩】—— 挂在 inbound_batches 与 output_batches 上
--   (BEFORE INSERT OR UPDATE OF module_count, material_id),所以收货、批次页、拆分与直连 SQL 一起盖住。
--   ① 只对仍装着电芯的形态成立:物料的形态 implies_dismantling 为假 → MODULE_COUNT_NOT_APPLICABLE|<批号>|<形态>。
--      没有形态的物料不拦(不知道不等于不适用 —— 与 guard_batch_cell_construction 同一条)。
--   ② 不许低于这一批已经有结论的模组数(含拆出去的),也不许在有结论之后清空:MODULE_COUNT_BELOW_RESULTS|<批号>|<已有结论的模组数>。
--   ③ 这一批此刻开着那道工序的结果状态(已放电并核实)→ 锁住:MODULE_COUNT_LOCKED|<批号>(Q4:核实之后锁住)。
--   【为什么是 SECURITY DEFINER】②③ 要数放电结果与读安全状态 —— 一个持进料编辑码、却不持加工查看码的人直连 UPDATE 时,
--   invoker 读法会被 RLS 安静地数成 0,规矩就漏了。触发器函数的 EXECUTE 不在触发时检查,所以 EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.guard_batch_module_count()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_form       text;
    v_dismantles boolean;
    v_n          bigint;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.module_count IS NOT DISTINCT FROM OLD.module_count
       AND NEW.material_id IS NOT DISTINCT FROM OLD.material_id THEN
        RETURN NEW;
    END IF;

    IF NEW.module_count IS NOT NULL THEN
        SELECT f.code, f.implies_dismantling INTO v_form, v_dismantles
          FROM materials m LEFT JOIN material_forms f ON f.code = m.form_code
         WHERE m.id = NEW.material_id;
        IF v_form IS NOT NULL AND NOT v_dismantles THEN
            RAISE EXCEPTION 'MODULE_COUNT_NOT_APPLICABLE|%|%', NEW.code, v_form
              USING HINT = '模组数只对仍装着电芯的形态成立(整包、模组、散电芯、已开壳电芯、混合料)。这一批的物料形态里没有电芯。';
        END IF;
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.module_count IS DISTINCT FROM OLD.module_count THEN
        SELECT count(*) INTO v_n FROM discharge_module_current_all c WHERE c.batch_id = NEW.id;
        IF v_n > 0 AND (NEW.module_count IS NULL OR NEW.module_count < v_n) THEN
            RAISE EXCEPTION 'MODULE_COUNT_BELOW_RESULTS|%|%', NEW.code, v_n
              USING HINT = '这一批已经有这么多个模组记了放电结论(含拆出去的)—— 模组数不能比它少,也不能清空。';
        END IF;
        IF EXISTS (SELECT 1 FROM discharge_batch_status_all s
                    WHERE s.batch_id = NEW.id AND s.currently_verified) THEN
            RAISE EXCEPTION 'MODULE_COUNT_LOCKED|%', NEW.code
              USING HINT = '这一批已经是"已放电并核实"—— 那个结论是按这个模组数判的,核实之后不再改。';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
