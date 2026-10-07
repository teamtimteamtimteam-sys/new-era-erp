-- db/functions/guard_batch_cell_construction.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-0 Q45;MES-4b Step 0 Q4 · Q7,Tim):【电芯结构这一列的两条规矩】—— 挂在 inbound_batches 与 output_batches 上
--   (BEFORE INSERT OR UPDATE OF cell_construction_code, material_id),所以收货、提交加工单的继承、批次页、直连 SQL 四条路一起盖住。
--   ① 只对仍装着电芯的形态成立:物料的形态 implies_dismantling 为假 → CELL_CONSTRUCTION_NOT_APPLICABLE|<批号>|<形态>。
--      【没有形态的物料不拦】不知道它是什么形态,不等于知道它不装电芯 —— 与 guard_inbound_condition_applicable 同一条
--      ("不知道"绝不能被当成"不适用"来拒人)。空着永远合法。
--   ② 喂过一张已提交、没回滚的加工单之后不再改(改成别的值或改回空):CELL_CONSTRUCTION_LOCKED|<那张加工单>。
--      更正的路是回滚那一张(回滚之后它不再是 committed,锁就开了)。
--   不是 SECURITY DEFINER:它是触发器;写入只经两支收货函数、commit_processing_run 与 set_batch_cell_construction(都是 DEFINER),
--   或持表的写码的直连 UPDATE —— 那一条也照样过这两条规矩。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE OR REPLACE FUNCTION public.guard_batch_cell_construction()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_form       text;
    v_dismantles boolean;
    v_run        text;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.cell_construction_code IS NOT DISTINCT FROM OLD.cell_construction_code
       AND NEW.material_id IS NOT DISTINCT FROM OLD.material_id THEN
        RETURN NEW;
    END IF;

    IF NEW.cell_construction_code IS NOT NULL THEN
        SELECT f.code, f.implies_dismantling INTO v_form, v_dismantles
          FROM public.materials m LEFT JOIN public.material_forms f ON f.code = m.form_code
         WHERE m.id = NEW.material_id;
        IF v_form IS NOT NULL AND NOT v_dismantles THEN
            RAISE EXCEPTION 'CELL_CONSTRUCTION_NOT_APPLICABLE|%|%', NEW.code, v_form
              USING HINT = '电芯结构(卷绕 / 叠片)只对仍装着电芯的形态成立(整包、模组、散电芯、已开壳电芯、混合料)。这一批的物料形态里没有电芯。';
        END IF;
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.cell_construction_code IS DISTINCT FROM OLD.cell_construction_code THEN
        SELECT r.code INTO v_run
          FROM public.processing_inputs pi JOIN public.processing_runs r ON r.id = pi.run_id
         WHERE r.status = 'committed' AND r.deleted_at IS NULL
           AND ((TG_TABLE_NAME = 'inbound_batches' AND pi.inbound_batch_id = NEW.id)
                OR (TG_TABLE_NAME = 'output_batches' AND pi.output_batch_id = NEW.id))
         ORDER BY r.process_date, r.code
         LIMIT 1;
        IF v_run IS NOT NULL THEN
            RAISE EXCEPTION 'CELL_CONSTRUCTION_LOCKED|%', v_run
              USING HINT = '这一批已经喂过一张已提交的加工单 —— 那一炉是按这个结构跑的。要改,先回滚那一张。';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$