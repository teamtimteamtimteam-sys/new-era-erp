-- db/functions/freeze_management_pack.sql
-- GLEXPORT-1:把一个【已关账】月份的管理报表包冻下来。
--
-- ★【它自己不算任何东西 —— payload 就是 management_pack_data 的返回值】★
--   一份实现,两个调用方(屏幕预览与本函数)。于是"屏幕上看到的"与"冻下来的"
--   **不可能**是两个数;在这里重算一遍就是第二份实现,而那正是本仓库付过四次账
--   的形状。
--
-- ★【只有关账的月份冻得下来,而这条拒绝是本刀的裁定】★
--   `PACK_MONTH_NOT_LOCKED`。理由整段写在 db/tables/management_packs.sql 的表注释里:
--   仓库为"什么时候该冻"裁过三次,三次的触发点都是**有东西离开了这栋楼**,
--   而不是有人按了「计算」。一个开放月份的包还没有承诺任何事。
--   判据 `locked_before > period_end` 与 file_gst_return 的 GST_PERIOD_NOT_LOCKED
--   逐字同源:那一期的每一天都已经不能再过账。
--
-- 【重出一份要说出理由】旧行落 superseded,新行是【另一份包】,不是同一份的 v2。

CREATE OR REPLACE FUNCTION public.freeze_management_pack(p_period_month date, p_notes text DEFAULT NULL::text, p_supersede_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_start   date;
    v_end     date;
    v_locked  date;
    v_base    text;
    v_prev    management_packs%ROWTYPE;
    v_reason  text;
    v_payload jsonb;
    v_seq     integer;
    v_code    text;
    v_id      uuid := gen_random_uuid();
BEGIN
    -- 【SECURITY DEFINER 必须自己问调用者是谁】一支不问的 definer 函数就是一条
    -- 绕过 RLS 的路;这个形状在本仓库上线过两次、两次都由闸抓住。
    -- 产出是一次写,所以要 edit;而 payload 来自只要 view 的那支函数。
    PERFORM require_permission('module.finance.edit');
    PERFORM require_permission('module.finance.view');

    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'PACK_PERIOD_REQUIRED';
    END IF;
    v_start := date_trunc('month', p_period_month)::date;
    v_end   := (v_start + INTERVAL '1 month - 1 day')::date;

    SELECT locked_before INTO v_locked FROM finance_settings;
    -- ★ 本刀的裁定,按名拒并把两个日期都说出来 —— 一条只说"不行"的拒绝
    --   会让人去猜是哪一天挡着。
    IF v_locked IS NULL OR v_locked <= v_end THEN
        RAISE EXCEPTION 'PACK_MONTH_NOT_LOCKED|%|%', to_char(v_start, 'YYYY-MM'),
            COALESCE(v_locked::text, '—')
          USING HINT = '只有已关账的月份才冻得下来 —— 开放月份看得到实时预览、也导得出 CSV,但那不是一份可以存档的包;先在月结那一步关账';
    END IF;

    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 已有在册的一份?那就要说出为什么再出一份。
    SELECT * INTO v_prev FROM management_packs
     WHERE period_month = v_start AND superseded_at IS NULL;
    IF FOUND THEN
        v_reason := NULLIF(btrim(COALESCE(p_supersede_reason, '')), '');
        IF v_reason IS NULL THEN
            RAISE EXCEPTION 'PACK_SUPERSEDE_REASON_REQUIRED|%', v_prev.code
              USING HINT = '这个月已经有一份在册的包 —— 再出一份要说明为什么(重开期间补记了什么?哪个数变了?)';
        END IF;
    END IF;

    -- 【payload 是调用来的,不是算来的】
    v_payload := management_pack_data(v_start);

    -- 编号:同一个月可以有多份(重出),第二份起带序号。
    -- 咨询锁串行化,与 EXP/JE/收付款/汇缴的取号手法一致。
    PERFORM pg_advisory_xact_lock(hashtext('mgmt_pack_' || to_char(v_start, 'YYYY-MM'))::bigint);
    SELECT COUNT(*) + 1 INTO v_seq FROM management_packs WHERE period_month = v_start;
    v_code := 'PACK-' || to_char(v_start, 'YYYY-MM') ||
              CASE WHEN v_seq > 1 THEN '-' || v_seq::text ELSE '' END;

    -- ★【旧的那一份必须【先】落 superseded,而这是探针当场抓到的】★
    --   idx_management_packs_live_month 是一条【部分唯一索引】
    --   ((period_month) WHERE superseded_at IS NULL)—— 一个月只许有一份在册。
    --   所以"先插新的、再标旧的"会撞唯一约束:那一瞬间同一个月有两份在册。
    --   顺序反过来就没有那一瞬间。指向新行不需要等它写下来 ——
    --   v_id 是【预先生成】的,与 record_payment / record_expense 让分录先行、
    --   单据带着链接一次到位是同一个手法。
    IF v_prev.id IS NOT NULL THEN
        UPDATE management_packs
           SET superseded_at = now(), superseded_by = v_id, superseded_reason = v_reason
         WHERE id = v_prev.id;
    END IF;

    INSERT INTO management_packs (id, code, period_month, period_start, period_end,
                                  locked_before_at_production, base_currency, payload,
                                  notes, produced_by)
    VALUES (v_id, v_code, v_start, v_start, v_end,
            v_locked, v_base, v_payload, p_notes, auth.uid());

    RETURN jsonb_build_object(
        'pack_id',      v_id,
        'code',         v_code,
        'period_month', v_start,
        'period_end',   v_end,
        'locked_before_at_production', v_locked,
        'superseded',   v_prev.code);
END;
$function$
;
