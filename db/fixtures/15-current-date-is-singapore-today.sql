-- 15 数据库的"今天"是新加坡的今天 —— 配置、语义、端到端各钉一臂
--
-- 为什么值得常设(FIN-20):库跑在 UTC 时,每天 SG 00:00–08:00 这八小时里
-- CURRENT_DATE 是【昨天】。两头都在走查里撞到了:record_assay_result 把今天的
-- 化验拒为"未来日期"(ASSAY_DATE_INVALID);reprice_inbound_batch 静默按前一天的
-- 牌价定价、并把分录记在前一天 —— 后者没有任何东西说出来。
--
-- 【坦白局限】fixture 拨不动服务器时钟,"在窗口里执行"无法照字面复现。所以:
--   * A 臂断言【配置本身】—— 一天 24 小时都非空洞:时区设定一丢(平台重置、
--     重建漏掉 database-settings.sql),门在任何时刻都红,不用等到窗口;
--   * B 臂断言配置的【语义】—— CURRENT_DATE 恒等于新加坡日历上的今天。
--     窗口内(UTC 日期 ≠ SG 日期)它单独就能分辨 UTC 库;窗口外由 A 臂顶住;
--   * C/D 臂把走查里撞到的两个症状端到端各钉一遍:凌晨的 gate 运行(比如
--     00:00–08:00 SG 的夜跑)会免费获得真窗口内的完整分辨力。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid;
    v_sup uuid; v_mat uuid; v_batch uuid;
    v_sg_today date; r numeric; a date; v_msg text := NULL;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-15', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    UPDATE finance_settings SET locked_before = NULL;

    v_sg_today := (now() AT TIME ZONE 'Asia/Singapore')::date;

    -- ── A. 配置:库级时区必须是 Asia/Singapore ───────────────────────────────
    --    这一臂全天非空洞。它红 = database-settings.sql 没跑 / 平台把设定重置了。
    IF current_setting('TimeZone') <> 'Asia/Singapore' THEN
        RAISE EXCEPTION 'FIXTURE 15A 失败:TimeZone 应为 Asia/Singapore,实为 %(database-settings.sql 没生效?)',
            current_setting('TimeZone');
    END IF;

    -- ── B. 语义:CURRENT_DATE = 新加坡的今天 ────────────────────────────────
    --    A 过而 B 不过的情形:会话级 SET 把时区又改了 —— 也该红。
    IF CURRENT_DATE <> v_sg_today THEN
        RAISE EXCEPTION 'FIXTURE 15B 失败:CURRENT_DATE=% 而新加坡今天是 %', CURRENT_DATE, v_sg_today;
    END IF;

    -- ── C. 端到端(被拒的那一半):SG 今天的化验必须不是"未来" ─────────────
    INSERT INTO suppliers (code, legal_name, country, counterparty_type) VALUES ('FIXT-S15', 'Fixture Supplier 15', 'SG', 'goods_supplier')
        RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('FIXT-M15', 'Fixture Material 15', 'battery_material', true, 'black_mass', 'end_of_life')
        RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('FIXT-B15', v_mat, v_sup, 100, 100, 'kg', v_sg_today, 'other', 'fixture 15 自带数据') RETURNING id INTO v_batch;

    BEGIN
        PERFORM record_assay_result(p_assay_date => v_sg_today,
            p_metals => jsonb_build_array(jsonb_build_object('metal', 'ni', 'content_pct', 10)),
            p_inbound_batch_id => v_batch, p_weight_basis => 'as_received', p_result_party => 'ours');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    END;
    IF v_msg LIKE 'ASSAY_DATE_INVALID%' THEN
        RAISE EXCEPTION 'FIXTURE 15C 失败:日期为新加坡今天(%)的化验被拒为未来 —— 服务器的"今天"落后了', v_sg_today;
    ELSIF v_msg IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 15C 前提失败:record_assay_result 因别的原因拒绝:%', v_msg;
    END IF;

    -- ── D. 端到端(静默的那一半):CURRENT_DATE 的牌价解析必须落在 SG 今天 ──
    --    走查里 reprice 就是在这里静默用了前一天:窗口内 CURRENT_DATE=昨天,
    --    昨天的牌价存在,精确命中,没人说一个字。这里只插【SG 今天】的牌价:
    --    UTC 库在窗口内会拿 CURRENT_DATE=昨天去查 → 查无此价被拒,as_of 断言兜底。
    UPDATE fx_rates SET deleted_at = now() WHERE currency = 'USD'
      AND rate_date BETWEEN v_sg_today - 6 AND v_sg_today;
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', v_sg_today, 'tt_sell', 1.27);
    SELECT x.rate, x.as_of INTO r, a FROM fx_rate_asof('USD', CURRENT_DATE, 'tt_sell') x;
    IF r IS NULL OR a <> v_sg_today THEN
        RAISE EXCEPTION 'FIXTURE 15D 失败:CURRENT_DATE 的牌价应精确命中 SG 今天(%),实得 rate=% as_of=%',
            v_sg_today, r, a;
    END IF;
END $$;
ROLLBACK;
