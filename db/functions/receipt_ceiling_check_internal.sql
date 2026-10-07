-- db/functions/receipt_ceiling_check_internal.sql
-- MES-3a(2026-10-06,MES-0 Q32 · Q33;MES-3a Step 0 Q5–Q10,Tim):【一批进厂的料,对着执照的库存上限判一次,并且记下来】。
--   调用方:create_inbound_batch · receive_inbound_batch_against_po · create_output_batch —— 在批次落库【之后】、同一笔事务里
--   (于是这一批自己的入库流水已经在存量里;拒绝即整笔回滚,什么都没发生)。处理、回滚、盘点、转移不调它(Q9):
--   它们不是从外面进料,超了由提醒臂 storage_ceiling_exceeded 说出来(Q13)。
--   ① 执照:收货那一天在效的 gwdf(storage_licence_in_force,Q5)。没有 → licence_not_in_force,照收。
--   ② 类别:物料的 nea_waste_category_code。没有 → category_not_set,照收(今天每一种物料都是这样,V29)。
--   ③ 锁:那一张执照行,与这一类的上限行(FOR UPDATE)—— 两张并发的收货不可能都"刚好没超":后到的那一笔等前一笔提交,
--      再按提交后的存量判(READ COMMITTED,每一句一个新快照)。锁在读存量【之前】。
--   ④ 吨:这一批与这一类(以及总量)的存量换成吨(quantity_in_tonnes)。换不成 → 这一类或总量给了上限就按名拒
--      STORAGE_CEILING_UNIT_NOT_CONVERTIBLE|<批号>|<类别或 *>,没给就记 unit_not_convertible(Q8)。
--   ⑤ 判:这一类给了上限而收进来之后超了 → STORAGE_CEILING_EXCEEDED|<执照号>|<类别>|<之前 t>|<这一批 t>|<上限 t>;
--      执照的总上限(approved_storage_limit_tonnes,所有有类别的存量之和)给了而超了 → 同一个码,类别写 *(Q6)。
--   ⑥ 记:within(这一类给了上限、没超)· ceiling_not_set(这一类没给 —— Q33:照收,记下来;总量给了的照样判过、记在 total_*)。
--   返回写下的那一行(jsonb)。内层:不是 SECURITY DEFINER、没有调用者检查,EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.receipt_ceiling_check_internal(p_inbound_batch_id uuid, p_output_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_material uuid;
    v_qty      numeric;
    v_unit     text;
    v_on       date;
    v_code     text;
    v_lic      uuid;
    v_lic_no   text;
    v_cat      text;
    v_qt       numeric;
    v_lim      numeric;
    v_tot_lim  numeric;
    v_cat_t    numeric;
    v_cat_bad  bigint;
    v_tot_t    numeric;
    v_tot_bad  bigint;
    v_outcome  text;
    v_row      receipt_ceiling_checks%ROWTYPE;
BEGIN
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'STORAGE_CEILING_ONE_BATCH';
    END IF;
    IF p_inbound_batch_id IS NOT NULL THEN
        SELECT b.material_id, b.quantity, b.unit, b.arrival_date, b.code INTO v_material, v_qty, v_unit, v_on, v_code
          FROM inbound_batches b WHERE b.id = p_inbound_batch_id;
    ELSE
        SELECT b.material_id, b.quantity, b.unit, b.output_date, b.code INTO v_material, v_qty, v_unit, v_on, v_code
          FROM output_batches b WHERE b.id = p_output_batch_id;
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STORAGE_CEILING_BATCH_NOT_FOUND|%', COALESCE(p_inbound_batch_id, p_output_batch_id);
    END IF;
    v_on := COALESCE(v_on, (now() AT TIME ZONE 'Asia/Singapore')::date);
    v_qt := quantity_in_tonnes(v_qty, v_unit);

    v_lic := storage_licence_in_force(v_on);
    IF v_lic IS NULL THEN
        v_outcome := 'licence_not_in_force';
    ELSE
        SELECT m.nea_waste_category_code INTO v_cat FROM materials m WHERE m.id = v_material;
        IF v_cat IS NULL THEN
            v_outcome := 'category_not_set';
        END IF;
    END IF;

    IF v_outcome IS NULL THEN
        -- ③ 锁在读存量之前
        SELECT cc.cert_no, cc.approved_storage_limit_tonnes INTO v_lic_no, v_tot_lim
          FROM company_compliance cc WHERE cc.id = v_lic FOR UPDATE;
        SELECT l.limit_tonnes INTO v_lim
          FROM licence_storage_limits l WHERE l.licence_id = v_lic AND l.category_code = v_cat FOR UPDATE;

        SELECT a.tonnes, a.unconvertible_batches INTO v_cat_t, v_cat_bad
          FROM nea_category_on_hand_all a WHERE a.category_code = v_cat;
        SELECT sum(a.tonnes), sum(a.unconvertible_batches) INTO v_tot_t, v_tot_bad FROM nea_category_on_hand_all a;

        -- ④ 换算不成吨
        IF v_qt IS NULL OR COALESCE(v_cat_bad, 0) > 0 THEN
            IF v_lim IS NOT NULL THEN
                RAISE EXCEPTION 'STORAGE_CEILING_UNIT_NOT_CONVERTIBLE|%|%', v_code, v_cat;
            END IF;
            v_outcome := 'unit_not_convertible';
        END IF;
        IF v_tot_lim IS NOT NULL AND (v_qt IS NULL OR COALESCE(v_tot_bad, 0) > 0) THEN
            RAISE EXCEPTION 'STORAGE_CEILING_UNIT_NOT_CONVERTIBLE|%|*', v_code;
        END IF;

        IF v_outcome IS NULL THEN
            -- ⑤ 判(存量里已经有这一批)
            IF v_lim IS NOT NULL AND v_cat_t > v_lim THEN
                RAISE EXCEPTION 'STORAGE_CEILING_EXCEEDED|%|%|%|%|%', v_lic_no, v_cat,
                    round(v_cat_t - v_qt, 3), round(v_qt, 3), v_lim;
            END IF;
            IF v_tot_lim IS NOT NULL AND v_tot_t > v_tot_lim THEN
                RAISE EXCEPTION 'STORAGE_CEILING_EXCEEDED|%|*|%|%|%', v_lic_no,
                    round(v_tot_t - v_qt, 3), round(v_qt, 3), v_tot_lim;
            END IF;
            v_outcome := CASE WHEN v_lim IS NULL THEN 'ceiling_not_set' ELSE 'within' END;
        END IF;
    END IF;

    INSERT INTO receipt_ceiling_checks (inbound_batch_id, output_batch_id, licence_id, category_code, outcome, quantity_t,
                                        on_hand_before_t, limit_t, total_on_hand_before_t, total_limit_t, checked_on)
    VALUES (p_inbound_batch_id, p_output_batch_id, v_lic, v_cat, v_outcome, v_qt,
            CASE WHEN v_outcome IN ('within', 'ceiling_not_set') THEN COALESCE(v_cat_t, 0) - v_qt END,
            v_lim,
            CASE WHEN v_outcome IN ('within', 'ceiling_not_set') AND COALESCE(v_tot_bad, 0) = 0 THEN COALESCE(v_tot_t, 0) - v_qt END,
            v_tot_lim, v_on)
    RETURNING * INTO v_row;
    RETURN to_jsonb(v_row);
END;
$function$;
