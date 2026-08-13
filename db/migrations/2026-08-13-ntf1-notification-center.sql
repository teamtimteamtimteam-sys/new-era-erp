-- db/migrations/2026-08-13-ntf1-notification-center.sql
-- NTF-1:通知中心 —— 把【事件】留下来,而事件与仪表盘的【臂】不是一回事
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【两种东西,两张脸,别合并】
--   * 仪表盘的【臂】(operations_now):一个【持续成立的状态】,它自己会消失 ——
--     把货补上、把单据批掉,那一行就不在了。它没有历史,也不需要历史。
--   * 通知的【事件】:一件【发生过的事】。它不会自己消失,因为它已经发生了;
--     它只能被【读过】。补上货并不会让"三天前你把货收进了一个没配置的库位"
--     这件事变成没发生。
-- 两者混在一起,得到的是一个既不完整又不会清空的列表。所以这一刀只做事件。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【v1 的两个来源,以及第三个【被排除】的来源 —— 理由写在这里,不在对话里】
--
--   (a) IOD-2 的落地告警。它今天是【转瞬即逝】的:RPC 把 warnings 放在返回值里,
--       界面渲染一次,然后就没有了。刷新、换个人看、或者当时没注意 —— 那两句话
--       就再也不存在了,而且【没有任何痕迹说明它响过】。这正是"事件"该被留下来
--       的定义。
--
--   (b) 【事后】的分类违规:配置或分类【改变的那一刻】,已经躺在那里的货变成了
--       违规。IOD-2 的闸只在【货落地那一刻】检查,而那批货不会再落地一次 ——
--       IOD-2 的表头把这件事明写为范围外并排给了"告警那一刀",就是这一刀。
--
--   (c) 【METAL-1 的行情异常:明确不在 v1】—— 它【已经是持久的】:判词写在
--       metal_prices.anomaly_check 上(录入前由触发器算一次、记录而不事后推断),
--       而且它有自己的确认流程(outside 会拦人,ackSignature 保证"我看过了"绑在
--       那一组数字上,换个数字要重新确认)。把它复制成通知,等于给同一件事做了
--       第二份状态,而两份状态迟早会各说各话 —— 这个仓库为"第二份实现"付过很多
--       次账。要接第三个来源,先回答:它是不是已经有一份持久记录?如果是,通知
--       该【指向】它,而不是【复制】它。
--
--   【常驻违规视图仍然排在报表中心那一刀】:本刀只在【改变的那一刻】发事件。
--   "此刻全库还有哪些存量违规"是一个要主动扫全量的问题,那是报表,不是事件。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么整张表逐字照抄 approval_log 的形状】(APR-1)
-- 事件横跨模块,而横跨模块的读取在这个仓库有一条走通了的路:
--   * 主体写成 (subject_type, subject_id, subject_code) 而不是一串可空外键 XOR;
--   * RLS 的 SELECT 按 subject_type 【分派到那个模块自己的权限码】,
--     而且 ELSE false —— 【新增一种主体在有人给它声明模块之前是看不见的】,
--     不是默认公开;
--   * 【没有 INSERT 策略】:唯一的写入口是属主权限的函数。应用侧任何直接 INSERT
--     都会被 RLS 挡下 —— 留痕不该有第二个写法,通知同理;
--   * 只增不改的守卫【自己报名】(FIN-31),不靠外键顺带挡;
--   * REVOKE + 列清单 GRANT SELECT —— 这让它成为一张【被遮蔽的表】:
--     **将来加的列必须同时加进那个清单,否则它写得进、读不出**(AGENTS.md)。
--
-- 【为什么不做 invoker 视图】读者无权的模块,行会被 RLS 【静默丢掉】。对一个
-- 计数来说,丢行 = 少算;而"少算"在铃铛上长得和"没有通知"一模一样。基表 RLS
-- 给的是【按权限的缺席】,页面把缺席读作「你看不到的部分」而不是 0。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 事件表 ═════════════════════════════════════════════════════════════
CREATE TABLE public.notifications (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    occurred_at   timestamptz NOT NULL DEFAULT now(),
    event_type    text NOT NULL,
    subject_type  text NOT NULL,
    subject_id    uuid,
    subject_code  text,
    -- 【够渲染,不用回连】payload 带上码与数量,列表因此不必去 join 五张表;
    -- 而且事件是【当时】的事实 —— 主体后来改了名,这一行仍然说得出当时发生了什么。
    payload       jsonb NOT NULL DEFAULT '{}'::jsonb,
    actor_user_id uuid,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT notifications_event_type_known
        CHECK (event_type IN ('iod_class_unconfigured_location', 'iod_material_unclassified', 'class_violation_after_reclassify', 'class_violation_after_config')),
    CONSTRAINT notifications_subject_type_known
        CHECK (subject_type IN ('material', 'storage_location'))
);

CREATE INDEX idx_notifications_occurred ON public.notifications (occurred_at DESC);
CREATE INDEX idx_notifications_subject  ON public.notifications (subject_type, subject_id);
-- 去重要按指纹查【未读】的同类事件,这条让它不必全表扫
CREATE INDEX idx_notifications_fingerprint ON public.notifications ((payload ->> 'fingerprint'));

COMMENT ON TABLE public.notifications IS
    'NTF-1:发生过的事件,只增不改。与 operations_now 的【臂】是两种东西:臂是持续成立、会自己消失的状态,事件是发生过、只能被读过的事实。v1 两个来源:IOD-2 的落地告警(此前转瞬即逝 —— 渲染一次就没了,连响过的痕迹都没有),以及配置/分类改变那一刻的【事后】分类违规(IOD-2 的闸只在货落地那一刻检查,而那批货不会再落地一次)。【METAL-1 的行情异常刻意不在此列】:它已经持久在 metal_prices.anomaly_check 上,并有自己的确认流程,复制过来就是同一件事的第二份状态。要接第三个来源,先问它是不是已经有一份持久记录 —— 如果是,通知应当【指向】它而不是【复制】它。主体是 (subject_type, subject_id),RLS 按 subject_type 分派到该模块的权限码且 ELSE false;没有 INSERT 策略,唯一写入口是属主权限的 notify_* 函数。';

COMMENT ON COLUMN public.notifications.payload IS
    'NTF-1:渲染这条通知所需的一切(码、数量、库位、分类),【故意冗余】—— 列表不必回连五张表,而且事件记的是【当时】的事实,主体后来改名也不会让这一行说错话。含 fingerprint:事后违规按它去重。';

-- ── 只增不改。守卫【自己报名】(FIN-31)—— 不靠外键顺带挡 ──────────────────
CREATE OR REPLACE FUNCTION public.guard_notifications_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'NOTIFICATION_IMMUTABLE';
END;
$function$;

CREATE TRIGGER trg_notifications_append_only
    BEFORE UPDATE OR DELETE ON public.notifications
    FOR EACH ROW EXECUTE FUNCTION public.guard_notifications_append_only();

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- 读:按主体所属模块分派。【ELSE false】—— 将来加一种主体,在有人给它声明模块
-- 之前它是【看不见的】,而不是默认公开。写:【没有 INSERT 策略】,唯一入口是
-- 属主权限的 notify_* 函数;客户端直插一律被 RLS 挡下。
CREATE POLICY "notifications select by permission"
    ON public.notifications
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (
        CASE subject_type
            WHEN 'material'         THEN has_permission('module.materials.view'::text)
            WHEN 'storage_location' THEN has_permission('module.inventory.view'::text)
            ELSE false
        END
    );

-- 【被遮蔽的表】:将来加的列必须同时加进这个清单,否则写得进、读不出(AGENTS.md)。
REVOKE SELECT ON public.notifications FROM authenticated, anon;
GRANT SELECT (id, occurred_at, event_type, subject_type, subject_id, subject_code,
              payload, actor_user_id, created_at)
    ON public.notifications TO authenticated;

-- ═══ 2 · 已读状态 ═══════════════════════════════════════════════════════════
-- 【为什么单独一张表而不是 notifications.read_at】已读是【每个读者自己的】状态,
-- 不是事件的属性。今天只有一个用户,把它写在事件行上确实更省 —— 但那会在第二个
-- 用户出现的那一天【静默变错】(一个人读过就对所有人显示已读),而那种错误不会
-- 报错。多一张表是今天唯一的代价,换的是那一天不会到来。
CREATE TABLE public.notification_reads (
    notification_id uuid NOT NULL REFERENCES public.notifications (id) ON DELETE CASCADE,
    user_id         uuid NOT NULL,
    read_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (notification_id, user_id)
);

COMMENT ON TABLE public.notification_reads IS
    'NTF-1:谁读过哪一条。【每个读者自己的状态】,所以不写在 notifications 行上 —— 写在那里今天更省,但第二个用户出现时会静默变错(一个人读过 = 所有人已读),而那种错不会报错。RLS:只读得到、也只写得动自己的行。';

ALTER TABLE public.notification_reads ENABLE ROW LEVEL SECURITY;

-- 自己的行,自己读自己写。【标记已读是读者对自己说的话】,所以这张表允许客户端
-- 直写(与 notifications 相反)—— 它记的不是"发生了什么",而是"我看过了"。
CREATE POLICY "notification_reads select own"
    ON public.notification_reads
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (user_id = auth.uid());

CREATE POLICY "notification_reads insert own"
    ON public.notification_reads
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "notification_reads delete own"
    ON public.notification_reads
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (user_id = auth.uid());

-- ═══ 3 · 发射器一:IOD-2 的落地告警 ═════════════════════════════════════════
-- 【一处实现,四个落地点共用】—— 与 check_location_class 同一条理由:把这段
-- 抄进四个函数,就是四份会漂开的实现,而漏掉的那一处会【静默地不发通知】。
--
-- 【不去重】每一次收货都是一件【真的发生过】的事:同一个库位收两次货就是两件事。
-- 事后违规那一侧才去重,理由见那个函数的抬头(那里的"改变"是被写法造出来的)。
--
-- 【主体 = 补救所在的那张页面】(LINKS-1 的判据):库位没配置 → 库位页;
-- 物料没分类 → 物料页。
CREATE OR REPLACE FUNCTION public.notify_landing_warnings(p_warn text[], p_location_id uuid, p_material_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    w        text;
    v_code   text;
    v_loc    text;
    v_mat    text;
    v_actor  uuid := auth.uid();
BEGIN
    IF p_warn IS NULL OR array_length(p_warn, 1) IS NULL THEN
        RETURN;
    END IF;

    SELECT code INTO v_loc FROM storage_locations WHERE id = p_location_id;
    SELECT code INTO v_mat FROM materials         WHERE id = p_material_id;

    FOREACH w IN ARRAY p_warn LOOP
        v_code := split_part(w, '|', 1);

        IF v_code = 'IOD_CLASS_UNCONFIGURED_LOCATION' THEN
            INSERT INTO notifications (event_type, subject_type, subject_id, subject_code, payload, actor_user_id)
            VALUES ('iod_class_unconfigured_location', 'storage_location', p_location_id, v_loc,
                    jsonb_build_object('code', v_code,
                                       'location_id', p_location_id, 'location_code', v_loc,
                                       'material_id', p_material_id, 'material_code', v_mat,
                                       'fingerprint', 'landing|' || v_code || '|' || COALESCE(p_location_id::text,'') || '|' || COALESCE(p_material_id::text,'')),
                    v_actor);

        ELSIF v_code = 'IOD_MATERIAL_UNCLASSIFIED' THEN
            INSERT INTO notifications (event_type, subject_type, subject_id, subject_code, payload, actor_user_id)
            VALUES ('iod_material_unclassified', 'material', p_material_id, v_mat,
                    jsonb_build_object('code', v_code,
                                       'location_id', p_location_id, 'location_code', v_loc,
                                       'material_id', p_material_id, 'material_code', v_mat,
                                       'fingerprint', 'landing|' || v_code || '|' || COALESCE(p_location_id::text,'') || '|' || COALESCE(p_material_id::text,'')),
                    v_actor);
        END IF;
        -- 【未知的码不发通知,也不抛】:告警码的集合会长,而一次收货不该因为
        -- 通知这一侧没跟上而失败。漏发是看得见的(码在 warnings 里照样上屏)。
    END LOOP;
END;
$function$;

-- ═══ 4 · 发射器二:事后的分类违规 ═══════════════════════════════════════════
-- 【它回答的是 IOD-2 明确不回答的那个问题】:配置或分类【改变的那一刻】,
-- 已经躺在那里的货是不是变成了违规。IOD-2 的闸只在货落地那一刻检查,而那批货
-- 不会再落地一次给它机会。
--
-- 【判据与 IOD-2 逐字同形 —— 三态,只有一态算违规】
--   物料未分类        → 不发(那是"没人做过决定",是告警态,不是违规)
--   库位未配置(零行)→ 不发(同上)
--   配了、且不含这一类 → 【发】—— 唯一一个"有人做过决定、而货与它冲突"的格子
--
-- 【可用量:同一条一句话的规则】stock_status = 'available',按 (物料, 库位) 聚合。
-- 没有复制任何 drain/状态流转逻辑 —— 那些写在流水【怎么产生】那一侧。
-- 暂扣的货不算:一批扣着的货不是"能用的货",而违规说的是"能用的货放错了地方"。
--
-- 【为什么必须去重】库位那张表的写法是【整体删掉再插回去】
-- (replaceAllowedClasses)—— 于是【每一次保存都长得像一次改变】,哪怕一个字
-- 没动。不去重,操作员每按一次保存就多一条一模一样的通知。
-- 判据:同指纹、且【还没被读过】的事件已经在,就不再写一条。已经读过的会再发 ——
-- 那是对的:读过意味着"我知道了",而它【又发生了一次】值得再说一次。
CREATE OR REPLACE FUNCTION public.notify_class_violations(p_cause text, p_material_ids uuid[], p_location_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r       record;
    v_fp    text;
    v_actor uuid := auth.uid();
BEGIN
    FOR r IN
        WITH avail AS (
            SELECT mv.location_id,
                   COALESCE(ib.material_id, ob.material_id) AS material_id,
                   sum(mv.qty_delta) AS qty
              FROM inventory_movements mv
                   LEFT JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
                   LEFT JOIN output_batches  ob ON ob.id = mv.output_batch_id
             WHERE mv.stock_status = 'available'
               AND mv.location_id IS NOT NULL
             GROUP BY 1, 2
            HAVING sum(mv.qty_delta) > 0
        )
        SELECT a.location_id, a.material_id, a.qty,
               m.code AS material_code, m.waste_classification_code AS class_code,
               sl.code AS location_code
          FROM avail a
               JOIN materials m          ON m.id  = a.material_id
               JOIN storage_locations sl ON sl.id = a.location_id
         WHERE (p_material_ids IS NULL OR a.material_id = ANY (p_material_ids))
           AND (p_location_ids IS NULL OR a.location_id = ANY (p_location_ids))
           AND m.deleted_at IS NULL
           -- 未分类 = 没人做过决定 → 不是违规
           AND m.waste_classification_code IS NOT NULL
           -- 零行 = 未配置 = 没人做过决定 → 不是违规
           AND EXISTS (SELECT 1 FROM storage_location_allowed_classes c
                        WHERE c.location_id = a.location_id)
           -- 配了、且不含这一类 → 违规
           AND NOT EXISTS (SELECT 1 FROM storage_location_allowed_classes c
                            WHERE c.location_id = a.location_id
                              AND c.classification_code = m.waste_classification_code)
    LOOP
        v_fp := r.material_id::text || '|' || r.location_id::text || '|' || r.class_code;

        -- 去重:同指纹且【未读】的已经在 → 不再写
        IF EXISTS (
            SELECT 1 FROM notifications n
             WHERE n.payload ->> 'fingerprint' = v_fp
               AND NOT EXISTS (SELECT 1 FROM notification_reads nr
                                WHERE nr.notification_id = n.id))
        THEN
            CONTINUE;
        END IF;

        INSERT INTO notifications (event_type, subject_type, subject_id, subject_code, payload, actor_user_id)
        VALUES (
            CASE p_cause WHEN 'material_reclassified' THEN 'class_violation_after_reclassify'
                         ELSE 'class_violation_after_config' END,
            CASE p_cause WHEN 'material_reclassified' THEN 'material' ELSE 'storage_location' END,
            CASE p_cause WHEN 'material_reclassified' THEN r.material_id ELSE r.location_id END,
            CASE p_cause WHEN 'material_reclassified' THEN r.material_code ELSE r.location_code END,
            jsonb_build_object('fingerprint', v_fp,
                               'class', r.class_code,
                               'qty', trim_scale(r.qty),
                               'material_id', r.material_id, 'material_code', r.material_code,
                               'location_id', r.location_id, 'location_code', r.location_code),
            v_actor);
    END LOOP;
END;
$function$;

-- ── 触发器:物料的分类【变了】────────────────────────────────────────────────
-- 【SECURITY DEFINER】触发器函数默认以【调用者】身份执行,而 notify_class_violations
-- 对 authenticated 是收权的(它能凭空写通知)。所以这一层要以属主身份跑。
CREATE OR REPLACE FUNCTION public.trg_notify_material_reclassified()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM notify_class_violations('material_reclassified', ARRAY[NEW.id], NULL);
    RETURN NULL;
END;
$function$;

CREATE TRIGGER trg_materials_notify_reclassified
    AFTER UPDATE ON public.materials
    FOR EACH ROW
    WHEN (OLD.waste_classification_code IS DISTINCT FROM NEW.waste_classification_code)
    EXECUTE FUNCTION public.trg_notify_material_reclassified();

-- ── 触发器:库位的许可分类【被写了】──────────────────────────────────────────
-- 【语句级 + 过渡表】replaceAllowedClasses 是"整体删掉再插回去",所以要看的是
-- 【这一条语句写完之后的最终集合】,而不是逐行。用 NEW TABLE 拿到受影响的库位,
-- 再由发射器按最终集合判定。
--
-- 【DELETE 那一半故意不接】一个被清空的库位 = 【未配置】= 告警态,不是违规
-- (三态规矩)。给它发违规,就是把"没人做过决定"说成"决定了不行"。
CREATE OR REPLACE FUNCTION public.trg_notify_location_classes_written()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_locs uuid[];
BEGIN
    SELECT array_agg(DISTINCT location_id) INTO v_locs FROM new_rows;
    IF v_locs IS NOT NULL THEN
        PERFORM notify_class_violations('location_configured', NULL, v_locs);
    END IF;
    RETURN NULL;
END;
$function$;

CREATE TRIGGER trg_slac_notify_written
    AFTER INSERT ON public.storage_location_allowed_classes
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.trg_notify_location_classes_written();


-- ═══ 5 · 四条落地腿:在既有的 warnings 分支上多发一次事件 ══════════════════
-- 【签名一个字不改】—— 只在 v_warn 拿到之后多一行 PERFORM。返回值仍然带着
-- warnings(界面那一次即时提示不变),通知是【额外】留下来的那一份。
-- 定义取自线上 pg_get_functiondef 逐字节,只插入那一行 —— 加一个发射器不该
-- 顺手重写四个函数体(SS-1 那次手打差点改掉三支仪表盘臂,教训记在那一刀)。

CREATE OR REPLACE FUNCTION public.create_inbound_batch(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date, p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    PERFORM require_permission('module.inbound.edit');

    -- IOD-2-fu1:到货日【按名】必填。不写这一句,漏出去的是 FIN-32 的约束原文。
    -- 【不给默认值】:CURRENT_DATE 会让留空比填对更容易通过。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    -- 【顺序要紧】库位先校验再落库:拒绝必须发生在写入之前,否则一次被拒的
    -- 收货会留下半个批次(单事务会回滚,但错误信息的语义也该是"什么都没发生")。
    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸。同样在写入之前 —— 它可能抛 IOD_CLASS_EXCLUDED。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, unit, remaining_qty, arrival_date,
        stage, unit_price, notes, purchase_order_id, purchase_order_line_id,
        created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_arrival_date,
        COALESCE(p_stage,'待加工'), p_unit_price, p_notes, p_purchase_order_id, p_purchase_order_line_id,
        v_user, v_user)
    RETURNING id INTO v_id;

    -- 用毕即清 —— 同 commit_processing_run 的 movement_ctx:免得同事务内后续的
    -- 插入把这个库位当成自己的(那正是 ctx 这种机制唯一的锋利处)。
    PERFORM set_config('evoltrya.location_ctx', '', true);
    -- IOD-2:返回值从 uuid 变成 jsonb —— 告警要有地方回去。batch_id 仍在里面。
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

CREATE OR REPLACE FUNCTION public.receive_inbound_batch_against_po(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_arrival_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    PERFORM require_permission('module.inbound.edit');

    -- IOD-2-fu1:同上 —— 现场收货这条路一样进得到 FIN-32 的约束。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸,写入之前。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    -- 单位固定 kg、stage 用默认值 —— 与收货表单今天的行为逐字一致。
    -- 【采购单侧的那一串拒绝(PO_NOT_RECEIVABLE / PO_LINE_MISMATCH /
    --  PO_NOT_APPROVED / SUPPLIER_QUALIFICATION_EXPIRED)仍由表上的触发器抛出】,
    -- 这个函数一个字都不重复它们 —— 重复一遍就是第二份会漂开的判断。
    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, remaining_qty, unit, arrival_date,
        notes, purchase_order_id, purchase_order_line_id, created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, p_quantity, 'kg', p_arrival_date,
        p_notes, p_purchase_order_id, p_purchase_order_line_id, v_user, v_user)
    RETURNING id INTO v_id;

    PERFORM set_config('evoltrya.location_ctx', '', true);
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_output_batch(p_material_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_output_date date DEFAULT NULL::date, p_state text DEFAULT '库存中'::text, p_customer_id uuid DEFAULT NULL::uuid, p_purity text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    PERFORM require_permission('module.output.edit');

    -- IOD-2-fu1:产出日【按名】必填 —— 手走就是在这一条上看见了约束原文。
    IF p_output_date IS NULL THEN
        RAISE EXCEPTION 'OUTPUT_DATE_REQUIRED';
    END IF;

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸,写入之前。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    INSERT INTO output_batches (
        material_id, customer_id, quantity, unit, remaining_qty, output_date,
        state, purity, notes, created_by, updated_by)
    VALUES (
        p_material_id, p_customer_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_output_date,
        COALESCE(p_state,'库存中'), p_purity, p_notes, v_user, v_user)
    RETURNING id INTO v_id;

    PERFORM set_config('evoltrya.location_ctx', '', true);
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_stock_transfer(p_qty numeric, p_to_location_id uuid, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_from_location_id uuid DEFAULT NULL::uuid, p_stock_status text DEFAULT 'available'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_pair     uuid := gen_random_uuid();
    v_have     numeric;
    v_today    date := CURRENT_DATE;
    v_material uuid;
    v_warn     text[];
BEGIN
    PERFORM require_permission('module.inventory.edit');

    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'STK_ONE_BATCH';
    END IF;
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'STK_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;
    IF p_stock_status IS NULL OR p_stock_status NOT IN ('available','on_hold') THEN
        RAISE EXCEPTION 'STK_QTY_INVALID|%', COALESCE(p_stock_status, '?');
    END IF;
    -- 【源与目的相同】不是一次无害的空操作:它会写下两行互相抵消的流水,
    -- 把台账弄脏,而且几乎总是意味着操作的人选错了一边。
    IF p_from_location_id IS NOT DISTINCT FROM p_to_location_id THEN
        RAISE EXCEPTION 'IOD_TRANSFER_SAME_LOCATION';
    END IF;
    -- 目的地必须是一个【在用】的库位。停用的库位不该再收货(LOC-1 的停用语义)。
    IF p_to_location_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = p_to_location_id AND is_active) THEN
        RAISE EXCEPTION 'IOD_TRANSFER_TO_INACTIVE|%', COALESCE(p_to_location_id::text, '?');
    END IF;

    -- 【同一粒度】对着派生桶比,与 STK-1 的暂扣/释放一模一样:
    -- remaining_qty 没有库位轴,在这个粒度上现算是唯一可能的来源。
    v_have := derived_stock_qty(p_inbound_batch_id, p_output_batch_id, p_from_location_id, p_stock_status);
    IF p_qty > v_have THEN
        RAISE EXCEPTION 'IOD_TRANSFER_EXCEEDS_BUCKET|%|%', p_qty, v_have;
    END IF;

    -- IOD-2:落闸,【只在入腿上】。物料从批次反查 —— 两种批次二选一(上面的
    -- XOR 已经保证恰好一个非空),两张表都有 material_id NOT NULL。
    -- 【出腿一个字都不查】:分类管的是货可以待在哪里,不是货能不能离开;拦住
    -- 一批放错地方的货【离开】,只会把它焊死在错的地方。
    v_material := COALESCE(
        (SELECT material_id FROM inbound_batches WHERE id = p_inbound_batch_id),
        (SELECT material_id FROM output_batches  WHERE id = p_output_batch_id));
    v_warn := check_location_class(p_to_location_id, v_material);
    -- NTF-1:告警留一份下来(入腿的库位/物料)。返回值那一份不变。
    PERFORM notify_landing_warnings(v_warn, p_to_location_id, v_material);

    -- 成对:出源库位、进目的库位。【状态原样带过去】—— 转移搬的是位置,
    -- 不是状态;一批被扣住的货换个货架仍然是被扣住的。
    INSERT INTO inventory_movements
        (inbound_batch_id, output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_inbound_batch_id, p_output_batch_id, p_from_location_id, 'transfer_out',
         -p_qty, p_stock_status, v_pair, v_today, NULLIF(btrim(COALESCE(p_note,'')),''), v_user),
        (p_inbound_batch_id, p_output_batch_id, p_to_location_id, 'transfer_in',
          p_qty, p_stock_status, v_pair, v_today, NULLIF(btrim(COALESCE(p_note,'')),''), v_user);

    RETURN jsonb_build_object('pair_id', v_pair, 'qty', p_qty,
                              'stock_status', p_stock_status,
                              'warnings', to_jsonb(v_warn));
END;
$function$;

COMMIT;
