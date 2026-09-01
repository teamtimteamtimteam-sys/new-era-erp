-- db/functions/guard_receipt_source_stated.sql
-- RECV-SOURCE-1:一张收货必须说得出它从哪来 —— 采购行或字典理由,永远不许两者皆无(R1)。
--
-- 【只拒 INSERT + 拒【由有变无】,绝不是 CHECK … NOT VALID —— 判过,别再回来】
-- NOT VALID 对 UPDATE 也强制,而本表有七个函数会 UPDATE 它(commit/rollback_
-- processing_run、apply_assay_result、reprice ×2、post_stocktake、soft_delete)。
-- 8 张历史无单收货(R4:不回填)会因此加工不了、化验不了、改价不了、注销不了 ——
-- 把"留着不说明"改写成"留着不能用",亲手制造 R4 禁止的回填压力。
-- materials_kind_stated 至今冻着 7 行,是这笔账已经付过的凭证(PROC-5)。
-- 形状照抄本表自己的先例 guard_arrival_date_not_cleared。
--
-- 【为什么是触发器,不在两个收货 RPC 里】postgres / service_role 直插绕得过
-- RLS(rolbypassrls),够不到 RPC —— SUP-TYPE-1a 的同一条理由。三条建批路径
-- (create_inbound_batch / receive_inbound_batch_against_po / 直插)全在这里汇合。
--
-- 具名拒绝:RECEIPT_SOURCE_REQUIRED(两者皆无;转移守卫同名带批号)、
-- SOURCE_REASON_EXPLANATION_REQUIRED|理由码(R3:requires_explanation 读字典,
-- 不写死 'other')、SOURCE_PROVENANCE_REQUIRED|批号(3e:事后补的理由必须盖章,
-- 正门是 explain_inbound_source)、SOURCE_PROVENANCE_NOT_AT_INTAKE(当场的理由
-- 不许冒充事后记录 —— recorded_at 非空 = 事后补的,这个区别是 R4 要的)。
--
-- NOTE: introduced by db/migrations/2026-09-01-recvsource1-a-receipt-must-say-where-it-came-from.sql.

CREATE OR REPLACE FUNCTION public.guard_receipt_source_stated()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_requires boolean;
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- R1:新收货必须说得出从哪来 —— 采购行,或理由,永远不许两者皆无。
        IF NEW.purchase_order_line_id IS NULL AND NEW.source_reason_code IS NULL THEN
            RAISE EXCEPTION 'RECEIPT_SOURCE_REQUIRED'
              USING HINT = '收货要么对着一张采购行,要么给一个理由(退货/样品/盘盈/其他)。'
                        || '两者皆无的收货,审计轨迹第一环就是断的。';
        END IF;
        -- 出处列只属于【事后】补的说明;收货当场的出处是 created_by/created_at。
        -- 放行这一格,"事后补的"与"当场说的"就再也分不开了(R4 的看得出区别)。
        IF NEW.source_reason_recorded_by IS NOT NULL OR NEW.source_reason_recorded_at IS NOT NULL THEN
            RAISE EXCEPTION 'SOURCE_PROVENANCE_NOT_AT_INTAKE'
              USING HINT = '收货当场给的理由不填 recorded_by/recorded_at —— '
                        || '那两列的意思是【事后】补记,当场的出处就是 created_by。';
        END IF;
    ELSE  -- UPDATE
        -- 转移守卫:说明过的不许改回没说明(与 guard_arrival_date_not_cleared 同形)。
        -- 8 张历史行两者皆无 → OLD 侧不成立 → 它们的每一次 UPDATE 照过 ——
        -- 加工、化验、改价、注销,一样都不冻(这正是不用 NOT VALID 买到的东西)。
        IF NEW.purchase_order_line_id IS NULL AND NEW.source_reason_code IS NULL
           AND (OLD.purchase_order_line_id IS NOT NULL OR OLD.source_reason_code IS NOT NULL) THEN
            RAISE EXCEPTION 'RECEIPT_SOURCE_REQUIRED|%', OLD.code
              USING HINT = '这张收货已经说明过来路,不能改回两者皆无 —— '
                        || '历史上缺失的那些留着,新的缺失不许再产生。';
        END IF;
        -- 3e:事后给一个(新的)理由,是对过去的一个新断言 —— 必须带谁、什么时候。
        -- 正门是 explain_inbound_source(它盖章);直连 UPDATE 不盖章就按名拒。
        IF NEW.source_reason_code IS DISTINCT FROM OLD.source_reason_code
           AND NEW.source_reason_code IS NOT NULL
           AND NEW.source_reason_recorded_at IS NULL THEN
            RAISE EXCEPTION 'SOURCE_PROVENANCE_REQUIRED|%', NEW.code
              USING HINT = '事后补的理由必须记下谁、什么时候 —— 走 explain_inbound_source,'
                        || '不要直接 UPDATE 本表。';
        END IF;
    END IF;

    -- R3(INSERT 与 UPDATE 都查):要说明的理由,没有句子不算说了话。
    -- 查的是字典的 requires_explanation,不是写死的 'other' —— 第五个也要说明的
    -- 理由是一行数据(R2 与 R3 就此不打架)。字典里查无此码时这里放过,
    -- 让外键用它自己的方式说"没有这个理由"。
    IF NEW.source_reason_code IS NOT NULL THEN
        SELECT requires_explanation INTO v_requires
          FROM inbound_source_reasons WHERE code = NEW.source_reason_code;
        IF FOUND AND v_requires AND COALESCE(btrim(NEW.source_reason_note), '') = '' THEN
            RAISE EXCEPTION 'SOURCE_REASON_EXPLANATION_REQUIRED|%', NEW.source_reason_code
              USING HINT = '这个理由要求一句书面说明(requires_explanation)——'
                        || '没有句子的 other 什么都没说(R3)。';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$

;
