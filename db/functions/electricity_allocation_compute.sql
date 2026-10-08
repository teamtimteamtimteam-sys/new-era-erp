-- db/functions/electricity_allocation_compute.sql
-- MES-5a-2(2026-10-08,MES-0 Q26 · Q27;MES-5a Step 0 Q21–Q28,Tim):【一张电费单怎么分 —— 分账的规则只住在这里】。
--   预览(preview_electricity_allocation)与过账(post_electricity_allocation)都调它、都原样用它算出来的数(AGENTS.md
--   「一个预览的屏幕问数据库」)。它什么都不写。内层:不是 DEFINER,authenticated 调不到。
--
--   ① 拒:时间段没给 / 倒着 / 结束在将来;账单金额或 kWh 不是正数;币种没给;【不是本位币】(currencies.is_base,Q28)→
--      ELECTRICITY_BILL_CURRENCY_NOT_BASE|币种|本位币;与一张已有的分摊时间段重叠 → ELECTRICITY_PERIOD_OVERLAPS|EXP-…|起|止。
--   ② 每一台电表这段时间量到多少:这段时间(period_from 00:00 到 period_to 24:00,新加坡时间)里它的【当前】读数(没被更正、
--      没被撤回),按 (read_at, id) 排,相邻两条之差的和;后一条是寄存器清零的那一对不计(跨过清零的量不出来)。
--      少于两条读数 → 这台表"量不出来"(measured = false),不是零。
--   ③ 每一台有电表的机器(电表的 equipment_id):它的电表都量得出来 → machine_kwh = 各表之和;有一台量不出来 → 整台机器
--      "量不出来",它这段时间的电不算"量到的"(落进不计量),它的炉一条都不分、它们的估计一条都不冲(Q26:只冲覆盖到的)。
--      共用池电表(equipment_id 为空)量到的 → shared_pool_kwh,留在 6200(Q25,V25 没给之前;给了也不在本刀里按它摊)。
--   ④ 每一台量得出来的机器,这段时间里(process_date 在段内)在它上面已提交、没回滚的每一炉:
--      【每一炉】都记了自己的 energy_kwh(更正链末端,有值)而且合计 > 0 → 按记下的电量的比例分(basis = recorded_energy);
--      否则整台机器【全部】按运行时长(ended_at − started_at,分钟)分(basis = run_time)(Q22,Tim)。运行时长缺 → 拒
--      ELECTRICITY_RUN_TIME_MISSING|PROC-…;合计为零 → 拒 ELECTRICITY_RUN_TIME_ZERO|机器。一炉已经分到过 → 拒 ELECTRICITY_RUN_ALREADY_ALLOCATED。
--      每一炉的 kWh = machine_kwh × 份额,到 0.001;最后一炉拿余数,于是各炉之和【恰好】等于 machine_kwh。
--      这台机器这段时间一炉都没有 → 它量到的电进 unallocated_metered_kwh(留在 6200)。
--   ⑤ 量到的合计(各机器 + 共用池)不许超过账单 kWh → ELECTRICITY_METERED_EXCEEDS_BILL|量到|账单(多出来的电从哪儿来,说不出来)。
--      unmetered_kwh = 账单 kWh − 量到的。单价 = 账单金额 ÷ 账单 kWh。
--   ⑥ 每一炉的金额 = kWh × 单价,到分;overhead_amount = 账单金额 − 各炉之和(6200)。分到分的尾差若让各炉之和比账单多(只可能是几分),
--      从最大的那一炉扣回 —— 于是 overhead 永不为负、两边恰好平。
--   ⑦ 要冲掉的估计:这些炉上手敲的、还没结过的电费估计(is_estimate,没软删,没冲抵,没汇出)。没被覆盖的炉上的一条都不列。
--   ⑧ 分录(过账那一张,预览里原样给出):借 2200 各炉之和 · 借 6200 余数 · 贷 应付 2000(未付)或银行(已付)账单全额。
--      各炉的成本行自己的录入分录(借 5110 / 贷 2200)与估计被冲掉时的冲销分录(借 2200 / 贷 5110)由 fin_journal_cost_entry 照旧过。
--   返回 jsonb(见末尾)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.

CREATE OR REPLACE FUNCTION public.electricity_allocation_compute(p_period_from date, p_period_to date, p_bill_amount numeric, p_bill_kwh numeric, p_currency text, p_payment_status text, p_bank_account text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base      text := base_currency_code();
    v_start     timestamptz;
    v_end       timestamptz;
    v_clash     record;
    v_mruns     jsonb;
    v_txt       text;
    v_meter     record;
    v_r         record;
    v_prev      numeric;
    v_kwh       numeric;
    v_n         int;
    v_reset     boolean;
    v_meters    jsonb := '[]'::jsonb;
    v_pool      jsonb := '[]'::jsonb;
    v_machines  jsonb := '[]'::jsonb;
    v_runs      jsonb := '[]'::jsonb;
    v_est       jsonb := '[]'::jsonb;
    v_mach      record;
    v_machine_kwh numeric;
    v_measured  boolean;
    v_all_own   boolean;
    v_sum_w     numeric;
    v_basis     text;
    v_cnt       int;
    v_i         int;
    v_run       record;
    v_w         numeric;
    v_run_kwh   numeric;
    v_given     numeric;
    v_metered   numeric := 0;
    v_pool_kwh  numeric := 0;
    v_unalloc   numeric := 0;
    v_alloc_kwh numeric := 0;
    v_price     numeric;
    v_alloc_amt numeric := 0;
    v_overhead  numeric;
    v_excess    numeric;
    v_big       int;
    v_est_amt   numeric := 0;
    v_est_n     int := 0;
    v_credit    text;
    v_journal   jsonb;
    v_k         int;
BEGIN
    -- ① 参数与本位币 ──────────────────────────────────────────────────────
    IF p_period_from IS NULL OR p_period_to IS NULL THEN
        RAISE EXCEPTION 'ELECTRICITY_PERIOD_REQUIRED';
    END IF;
    IF p_period_from > p_period_to THEN
        RAISE EXCEPTION 'ELECTRICITY_PERIOD_INVALID|%|%', p_period_from, p_period_to;
    END IF;
    IF p_period_to > CURRENT_DATE THEN
        RAISE EXCEPTION 'ELECTRICITY_PERIOD_IN_FUTURE|%', p_period_to;
    END IF;
    IF p_bill_amount IS NULL OR p_bill_amount <= 0 THEN
        RAISE EXCEPTION 'ELECTRICITY_BILL_AMOUNT_INVALID';
    END IF;
    IF p_bill_kwh IS NULL OR p_bill_kwh <= 0 THEN
        RAISE EXCEPTION 'ELECTRICITY_BILL_KWH_INVALID';
    END IF;
    IF p_currency IS NULL OR btrim(p_currency) = '' THEN
        RAISE EXCEPTION 'ELECTRICITY_BILL_CURRENCY_REQUIRED';
    END IF;
    IF v_base IS NULL THEN
        RAISE EXCEPTION 'BASE_CURRENCY_NOT_SET';
    END IF;
    IF upper(btrim(p_currency)) <> v_base THEN
        RAISE EXCEPTION 'ELECTRICITY_BILL_CURRENCY_NOT_BASE|%|%', upper(btrim(p_currency)), v_base;
    END IF;
    IF p_payment_status IS NULL OR p_payment_status NOT IN ('paid', 'unpaid') THEN
        RAISE EXCEPTION 'PAYMENT_STATUS_INVALID|%', COALESCE(p_payment_status, '?');
    END IF;
    IF p_payment_status = 'paid' THEN
        IF p_bank_account IS NULL OR bank_native_currency(p_bank_account) IS DISTINCT FROM v_base THEN
            RAISE EXCEPTION 'ELECTRICITY_BANK_NOT_BASE|%|%', COALESCE(p_bank_account, '?'), v_base;
        END IF;
        v_credit := p_bank_account;
    ELSE
        v_credit := '2000';
    END IF;
    SELECT a.period_from, a.period_to, e.code INTO v_clash
      FROM electricity_allocations a JOIN expenses e ON e.id = a.expense_id
     WHERE daterange(a.period_from, a.period_to, '[]') && daterange(p_period_from, p_period_to, '[]')
     ORDER BY a.period_from LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'ELECTRICITY_PERIOD_OVERLAPS|%|%|%', v_clash.code, v_clash.period_from, v_clash.period_to;
    END IF;

    v_start := (p_period_from::timestamp) AT TIME ZONE 'Asia/Singapore';
    v_end   := ((p_period_to + 1)::timestamp) AT TIME ZONE 'Asia/Singapore';

    -- ② 每一台电表这段时间量到多少(不建临时表:预览可能跑在只读事务里)───────────────
    FOR v_meter IN
        SELECT d.id, d.code, d.name, d.equipment_id FROM devices d
         WHERE d.kind = 'meter'
           AND (d.retired_at IS NULL
                OR EXISTS (SELECT 1 FROM meter_readings r WHERE r.device_id = d.id AND r.read_at >= v_start AND r.read_at < v_end))
         ORDER BY d.code
    LOOP
        v_prev := NULL; v_kwh := 0; v_n := 0; v_reset := false;
        FOR v_r IN
            SELECT r.register_kwh, r.is_register_reset FROM meter_readings r
             WHERE r.device_id = v_meter.id AND r.read_at >= v_start AND r.read_at < v_end AND NOT r.withdrawn
               AND NOT EXISTS (SELECT 1 FROM meter_readings x WHERE x.corrects_id = r.id)
             ORDER BY r.read_at, r.id
        LOOP
            v_n := v_n + 1;
            IF v_prev IS NOT NULL THEN
                IF v_r.is_register_reset THEN
                    v_reset := true;
                ELSE
                    v_kwh := v_kwh + (v_r.register_kwh - v_prev);
                END IF;
            END IF;
            v_prev := v_r.register_kwh;
        END LOOP;
        v_meters := v_meters || jsonb_build_object('device_id', v_meter.id, 'code', v_meter.code, 'name', v_meter.name,
                                                   'equipment_id', v_meter.equipment_id, 'kwh', CASE WHEN v_n >= 2 THEN v_kwh END,
                                                   'readings', v_n, 'has_reset', v_reset, 'measured', v_n >= 2);
    END LOOP;

    SELECT COALESCE(jsonb_agg(e - 'equipment_id' ORDER BY e ->> 'code'), '[]'::jsonb),
           COALESCE(sum((e ->> 'kwh')::numeric) FILTER (WHERE (e ->> 'measured')::boolean), 0)
      INTO v_pool, v_pool_kwh
      FROM jsonb_array_elements(v_meters) e WHERE e ->> 'equipment_id' IS NULL;

    -- ③ ④ 每一台有电表的机器 ────────────────────────────────────────────────
    FOR v_mach IN
        SELECT (e ->> 'equipment_id')::uuid AS equipment_id, fa.code AS equipment_code, fa.description,
               bool_and((e ->> 'measured')::boolean) AS measured, sum((e ->> 'kwh')::numeric) AS kwh,
               jsonb_agg(e - 'equipment_id' ORDER BY e ->> 'code') AS meters
          FROM jsonb_array_elements(v_meters) e JOIN fixed_assets fa ON fa.id = (e ->> 'equipment_id')::uuid
         WHERE e ->> 'equipment_id' IS NOT NULL
         GROUP BY (e ->> 'equipment_id')::uuid, fa.code, fa.description
         ORDER BY fa.code
    LOOP
        v_measured := v_mach.measured;
        v_machine_kwh := CASE WHEN v_measured THEN v_mach.kwh END;
        v_basis := NULL; v_cnt := 0;
        IF v_measured THEN
            v_metered := v_metered + v_machine_kwh;
            -- 这台机器这段时间里的每一炉(已提交、没回滚、process_date 在段内)
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'run_id', r.id, 'code', r.code,
                       'own_kwh', (SELECT v.value_number FROM processing_run_values v
                                    WHERE v.run_id = r.id AND v.field_code = 'energy_kwh' AND v.value_number IS NOT NULL
                                      AND NOT EXISTS (SELECT 1 FROM processing_run_values x WHERE x.corrects_id = v.id)
                                    ORDER BY v.id DESC LIMIT 1),
                       'minutes', CASE WHEN r.started_at IS NOT NULL AND r.ended_at IS NOT NULL
                                       THEN round(extract(epoch FROM (r.ended_at - r.started_at)) / 60.0, 2) END,
                       'allocated', EXISTS (SELECT 1 FROM electricity_allocation_lines l WHERE l.run_id = r.id))
                     ORDER BY r.code), '[]'::jsonb)
              INTO v_mruns
              FROM processing_runs r
             WHERE r.equipment_id = v_mach.equipment_id AND r.status = 'committed' AND r.deleted_at IS NULL
               AND r.process_date BETWEEN p_period_from AND p_period_to;
            v_cnt := jsonb_array_length(v_mruns);
            IF v_cnt = 0 THEN
                v_unalloc := v_unalloc + v_machine_kwh;
            ELSE
                SELECT x ->> 'code' INTO v_txt FROM jsonb_array_elements(v_mruns) x WHERE (x ->> 'allocated')::boolean
                 ORDER BY x ->> 'code' LIMIT 1;
                IF v_txt IS NOT NULL THEN
                    RAISE EXCEPTION 'ELECTRICITY_RUN_ALREADY_ALLOCATED|%', v_txt;
                END IF;
                SELECT bool_and(x ->> 'own_kwh' IS NOT NULL), sum((x ->> 'own_kwh')::numeric) INTO v_all_own, v_sum_w
                  FROM jsonb_array_elements(v_mruns) x;
                IF v_all_own AND v_sum_w > 0 THEN
                    v_basis := 'recorded_energy';
                ELSE
                    v_basis := 'run_time';
                    SELECT x ->> 'code' INTO v_txt FROM jsonb_array_elements(v_mruns) x WHERE x ->> 'minutes' IS NULL
                     ORDER BY x ->> 'code' LIMIT 1;
                    IF v_txt IS NOT NULL THEN
                        RAISE EXCEPTION 'ELECTRICITY_RUN_TIME_MISSING|%', v_txt;
                    END IF;
                    SELECT sum((x ->> 'minutes')::numeric) INTO v_sum_w FROM jsonb_array_elements(v_mruns) x;
                    IF COALESCE(v_sum_w, 0) <= 0 THEN
                        RAISE EXCEPTION 'ELECTRICITY_RUN_TIME_ZERO|%', v_mach.equipment_code;
                    END IF;
                END IF;
                v_i := 0; v_given := 0;
                FOR v_run IN SELECT x FROM jsonb_array_elements(v_mruns) x LOOP
                    v_i := v_i + 1;
                    v_w := CASE WHEN v_basis = 'recorded_energy' THEN (v_run.x ->> 'own_kwh')::numeric ELSE (v_run.x ->> 'minutes')::numeric END;
                    IF v_i < v_cnt THEN
                        v_run_kwh := round(v_machine_kwh * v_w / v_sum_w, 3);
                    ELSE
                        v_run_kwh := v_machine_kwh - v_given;
                    END IF;
                    v_given := v_given + v_run_kwh;
                    v_runs := v_runs || jsonb_build_object(
                        'run_id', v_run.x ->> 'run_id', 'code', v_run.x ->> 'code', 'equipment_id', v_mach.equipment_id,
                        'equipment_code', v_mach.equipment_code, 'basis', v_basis, 'own_kwh', v_run.x -> 'own_kwh',
                        'minutes', v_run.x -> 'minutes', 'weight', v_w, 'share', round(v_w / v_sum_w, 6),
                        'machine_kwh', v_machine_kwh, 'kwh', v_run_kwh);
                END LOOP;
                v_alloc_kwh := v_alloc_kwh + v_machine_kwh;
            END IF;
        END IF;
        v_machines := v_machines || jsonb_build_object(
            'equipment_id', v_mach.equipment_id, 'equipment_code', v_mach.equipment_code, 'description', v_mach.description,
            'measured', v_measured, 'kwh', v_machine_kwh, 'basis', v_basis, 'runs', v_cnt, 'meters', v_mach.meters);
    END LOOP;

    -- ⑤ 量到的合计不许超过账单 ───────────────────────────────────────────────
    v_metered := v_metered + v_pool_kwh;
    IF v_metered > p_bill_kwh THEN
        RAISE EXCEPTION 'ELECTRICITY_METERED_EXCEEDS_BILL|%|%', v_metered, p_bill_kwh;
    END IF;
    v_price := p_bill_amount / p_bill_kwh;

    -- ⑥ 每一炉的金额;尾差 ──────────────────────────────────────────────────
    FOR v_k IN 0 .. jsonb_array_length(v_runs) - 1 LOOP
        v_runs := jsonb_set(v_runs, ARRAY[v_k::text, 'amount'],
                            to_jsonb(round((v_runs -> v_k ->> 'kwh')::numeric * p_bill_amount / p_bill_kwh, 2)));
        v_alloc_amt := v_alloc_amt + (v_runs -> v_k ->> 'amount')::numeric;
    END LOOP;
    v_excess := v_alloc_amt - p_bill_amount;
    IF v_excess > 0 THEN
        SELECT (o.ord - 1)::int INTO v_big FROM jsonb_array_elements(v_runs) WITH ORDINALITY AS o(e, ord)
         ORDER BY (o.e ->> 'amount')::numeric DESC, o.ord LIMIT 1;
        v_runs := jsonb_set(v_runs, ARRAY[v_big::text, 'amount'], to_jsonb((v_runs -> v_big ->> 'amount')::numeric - v_excess));
        v_alloc_amt := p_bill_amount;
    END IF;
    v_overhead := p_bill_amount - v_alloc_amt;

    -- ⑦ 要冲掉的估计(只在被覆盖的炉上)─────────────────────────────────────────
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', e.id, 'run_id', e.run_id, 'run_code', r.code, 'amount', e.amount_base)
                              ORDER BY r.code, e.created_at, e.id), '[]'::jsonb),
           COALESCE(sum(e.amount_base), 0), count(*)
      INTO v_est, v_est_amt, v_est_n
      FROM processing_cost_entries e JOIN processing_runs r ON r.id = e.run_id
     WHERE e.run_id IN (SELECT (x ->> 'run_id')::uuid FROM jsonb_array_elements(v_runs) x)
       AND e.cost_type = 'electricity' AND e.is_estimate AND e.deleted_at IS NULL
       AND e.remitted_at IS NULL AND e.relieved_at IS NULL;

    -- ⑧ 分录 ───────────────────────────────────────────────────────────────
    v_journal := '[]'::jsonb;
    IF v_alloc_amt > 0 THEN
        v_journal := v_journal || jsonb_build_object('account_code', '2200', 'side', 'debit', 'currency', v_base,
                                                     'amount_ccy', v_alloc_amt, 'line_memo', 'electricity shares of the runs covered');
    END IF;
    IF v_overhead > 0 THEN
        v_journal := v_journal || jsonb_build_object('account_code', '6200', 'side', 'debit', 'currency', v_base,
                                                     'amount_ccy', v_overhead, 'line_memo', 'unmetered, shared and unallocated electricity');
    END IF;
    v_journal := v_journal || jsonb_build_object('account_code', v_credit, 'side', 'credit', 'currency', v_base,
                                                 'amount_ccy', p_bill_amount, 'line_memo', 'electricity bill');

    RETURN jsonb_build_object(
        'period_from', p_period_from, 'period_to', p_period_to, 'currency', v_base,
        'bill_amount', p_bill_amount, 'bill_kwh', p_bill_kwh, 'price_per_kwh', round(v_price, 6),
        'metered_kwh', v_metered, 'allocated_kwh', v_alloc_kwh, 'shared_pool_kwh', v_pool_kwh,
        'unallocated_metered_kwh', v_unalloc, 'unmetered_kwh', p_bill_kwh - v_metered,
        'allocated_amount', v_alloc_amt, 'overhead_amount', v_overhead,
        'relieved_estimate_amount', v_est_amt, 'relieved_estimate_count', v_est_n,
        'shared_pool_rule', (SELECT s.shared_pool_rule FROM electricity_settings s WHERE s.id),
        'machines', v_machines, 'pool_meters', v_pool, 'runs', v_runs, 'estimates', v_est, 'journal', v_journal);
END;
$function$
