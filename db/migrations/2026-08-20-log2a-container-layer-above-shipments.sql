-- LOG-2a:集装箱层 —— 【坐在 shipments 之上】,而不是把 shipments 改形状
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这一刀最重要的性质:它一个既有读者都不碰】
-- LOG-2-SURVEY 数出 shipments.sales_order_id 有 10 个读者(库 3、fixture 4、app 3),
-- 并把"一个箱子装两张订单"摆成两条路:把 shipments 改成多对多,或者在它【之上】
-- 加一层。选了后者,于是:
--   * shipments 仍然一张单一张订单,`sales_order_id` NOT NULL 不动;
--   * ship_order 不改、sales_order_fulfilment_status 不改、ship_date 仍在单头;
--   * 那 10 个点位一个都不用走访。
-- **本刀的 fixture 因此必须证明"挂进箱子不改变任何一张订单的完成度"** ——
-- 那是这个设计承重的那一句话,不是一句顺带的话。
--
-- 【运费的钱不在这一层】没有金额、没有应付、不碰 freight_documents。那是第 4 层。
-- 【提单号是承运人给的】所以 bl_number 是箱子上的一个【字段】,不铸 BL- 号段。
-- 【跟踪全靠手工录入】没有对接、没有轮询、没有自动状态机。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- (a) containers
-- ───────────────────────────────────────────────────────────────────────────
CREATE SEQUENCE IF NOT EXISTS public.container_code_seq;

CREATE TABLE public.containers (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code             text NOT NULL UNIQUE,          -- 'CTR-YYYY-NNNN',无缝,自己的咨询锁
    -- 【物理箱号】承运人/箱主给的那个号(MSCU1234567 这一类)。自由文本:
    -- ISO 6346 有校验位,但转运、拼箱、陆运段上会出现不合规的写法,
    -- 一条拦得住真实数据的格式检查比没有检查坏。
    container_number text,
    vessel           text,
    voyage           text,
    lane_id          uuid REFERENCES public.lanes (id),
    forwarder_id     uuid REFERENCES public.suppliers (id),
    -- 【世界那一侧的日期,永不默认】船是哪天开的,系统无从知道。
    -- 补一个 CURRENT_DATE 会让"没填"比"填对"更容易通过(AGENTS.md 的日期规矩)。
    departure_date   date NOT NULL,
    -- 【提单号是承运人签发的】—— 我们只是把它抄下来,所以它是一个字段,不是一个号段。
    bl_number        text,
    notes            text,
    -- AUDEL 家族的软删三件套:时刻、人、理由。理由由 soft_delete_container 强制。
    deleted_at       timestamptz,
    deleted_by       uuid,
    delete_reason    text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.containers IS
'LOG-2a:集装箱 / 一次装运的物理载体 —— **坐在 shipments 之上**。
一个箱子可以装多张发货单,而那些发货单可以属于不同客户的不同订单;
但【每一张发货单仍然只属于一张订单】,所以 ship_order、完成度判据、ship_date 全都不动
(LOG-2-SURVEY 数过:那条路上有 10 个读者,这一层一个都不碰)。
【这里没有钱】:没有运费金额、没有应付 —— 那是第 4 层。
【提单号是承运人给的】,所以它是字段不是号段。【跟踪只有手工录入】。';

COMMENT ON COLUMN public.containers.departure_date IS
'LOG-2a:船开的那一天 —— 【世界那一侧的事实,系统永不代填】。
它不决定任何会计期间(收入期间仍由 shipments.ship_date 决定,见本刀抬头),
但它是里程碑与单据时限的锚点,填错了没有任何下游会喊。所以必填、无默认。';

CREATE INDEX idx_containers_lane ON public.containers (lane_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_containers_forwarder ON public.containers (forwarder_id) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_containers_updated_at
    BEFORE UPDATE ON public.containers
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 【货代必须真的是货代】—— LOG-1a 的 counterparty_type 是唯一真源。
CREATE OR REPLACE FUNCTION public.guard_container_forwarder()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE v_type text; v_code text;
BEGIN
    IF NEW.forwarder_id IS NULL THEN RETURN NEW; END IF;
    SELECT counterparty_type, code INTO v_type, v_code
      FROM public.suppliers WHERE id = NEW.forwarder_id;
    IF v_type IS DISTINCT FROM 'forwarder' THEN
        RAISE EXCEPTION 'CONTAINER_FORWARDER_NOT_A_FORWARDER|%', COALESCE(v_code, NEW.forwarder_id::text)
          USING HINT = '这一家不是货代;箱子的承运方只能挂在货代身上';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_containers_forwarder
    BEFORE INSERT OR UPDATE ON public.containers
    FOR EACH ROW EXECUTE FUNCTION guard_container_forwarder();

CREATE OR REPLACE FUNCTION public.next_container_code(p_date date)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_year integer; v_seq integer;
BEGIN
    -- 与 next_shipment_code 一字不差的形状:互斥点是 advisory key 这个字符串,
    -- MAX+1 只是推导;两个并发调用靠这把锁串行,回滚即释放号码。
    v_year := EXTRACT(YEAR FROM p_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('container_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM containers WHERE code LIKE 'CTR-' || v_year::text || '-%';
    RETURN 'CTR-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

CREATE OR REPLACE FUNCTION public.soft_delete_container(p_container_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_user uuid := auth.uid(); v_code text;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    -- 【理由必填,拒绝按名】—— AUDEL 家族那一条:没有理由的注销,事后没人答得出为什么。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DELETE_REASON_REQUIRED|containers|%',
            COALESCE((SELECT code FROM containers WHERE id = p_container_id), '?');
    END IF;
    SELECT code INTO v_code FROM containers
     WHERE id = p_container_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'CONTAINER_NOT_FOUND|%', COALESCE(p_container_id::text, '?');
    END IF;
    UPDATE containers
       SET deleted_at = now(), deleted_by = v_user, delete_reason = btrim(p_reason),
           updated_by = v_user
     WHERE id = p_container_id;
    RETURN jsonb_build_object('id', p_container_id, 'code', v_code, 'deleted_by', v_user);
END;
$function$;

ALTER TABLE public.containers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "containers select" ON public.containers
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.purchasing.view'::text));
CREATE POLICY "containers write" ON public.containers
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));

-- ───────────────────────────────────────────────────────────────────────────
-- (b) shipments.container_id —— 以及【怎么穿过只增不改的守卫,而不是削弱它】
-- ───────────────────────────────────────────────────────────────────────────
ALTER TABLE public.shipments
    ADD COLUMN container_id uuid REFERENCES public.containers (id) ON DELETE RESTRICT;

COMMENT ON COLUMN public.shipments.container_id IS
'LOG-2a:这张发货单装在哪个箱子里。**可空** —— 一张发货单可以先存在、后装箱
(线上那一张 SHP-2026-0001 就保持 NULL,本刀一个字没动它)。
ON DELETE RESTRICT:箱子不能把发货单带走。
【它是 shipments 上唯一可改的列】,见 guard_shipment_append_only 的抬头。';

CREATE INDEX idx_shipments_container ON public.shipments (container_id) WHERE container_id IS NOT NULL;

-- ════════════════════════════════════════════════════════════════════════════
-- 【怎么穿过守卫:按列放行,而不是按调用者放行】
--
-- guard_shipment_append_only 原来对 shipments / shipment_lines / shipment_issues
-- 三张表的任何 UPDATE|DELETE 一律抛 SHIPMENT_IMMUTABLE。装箱需要改 container_id,
-- 于是必须让它过去。有两种做法,这里选了第二种:
--
--   (甲) 会话标志:attach 函数 set_config 一个 GUC,守卫看见就放行。
--        本仓库有这个先例(evoltrya.soft_delete_ctx)。但它放行的是【调用者】——
--        任何拿到那个 GUC 的代码都能改任何列,而守卫再也说不出"改了什么"。
--   (乙) 按列放行:**除 container_id 之外的每一列都必须与旧值一模一样**。
--        它放行的是【一个具体的改动】,不是一个身份。守卫因此仍然守着
--        "发货单的事实不可改"这句话本身 —— 变的只是"箱子指向谁"。
--
-- 选乙。它还有一个性质:即使将来有人绕开 attach_shipment_to_container 直接 UPDATE,
-- 他也只能动这一列 —— 而 shipments 上【没有 UPDATE 策略】,所以那条路本来就只对
-- DEFINER 函数开放。两层各自成立,不互相顶替。
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.guard_shipment_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    -- 删除:三张表都永不允许。
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'SHIPMENT_IMMUTABLE|%', TG_OP;
    END IF;

    -- 【唯一的例外:shipments 上只有 container_id 变了】
    IF TG_TABLE_NAME = 'shipments' THEN
        IF (NEW.id, NEW.code, NEW.sales_order_id, NEW.ship_date, NEW.notes,
            NEW.created_at, NEW.created_by)
           IS NOT DISTINCT FROM
           (OLD.id, OLD.code, OLD.sales_order_id, OLD.ship_date, OLD.notes,
            OLD.created_at, OLD.created_by)
        THEN
            RETURN NEW;   -- 只动了 container_id(或什么都没动)
        END IF;
    END IF;

    -- 发货单、发货行、送货单签发档共用这一条:只增不改。
    -- 【为什么没有"作废"】货发出去了就是发出去了 —— 2500 已经释放进 4000、
    -- 库存已经离开台账。改一张发货单等于把一件发生过的物理事件改写成另一件;
    -- 更正走【贷项凭证】。
    RAISE EXCEPTION 'SHIPMENT_IMMUTABLE|%', TG_OP;
END;
$function$;

COMMENT ON FUNCTION public.guard_shipment_append_only() IS
'SO-3b 建立,LOG-2a 起开了【一个按列的口子】:shipments.container_id 可以改,其它每一列仍然不可改,DELETE 仍然一律拒绝。
放行的是一个具体的改动,不是一个调用者身份 —— 所以守卫仍然说得出"什么可以变"。装箱/拆箱走 attach_shipment_to_container / detach_shipment_from_container。';

CREATE OR REPLACE FUNCTION public.attach_shipment_to_container(p_shipment_id uuid, p_container_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_ship text; v_ctr text;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT code INTO v_ship FROM shipments WHERE id = p_shipment_id FOR UPDATE;
    IF v_ship IS NULL THEN
        RAISE EXCEPTION 'SHIPMENT_NOT_FOUND|%', COALESCE(p_shipment_id::text, '?');
    END IF;
    -- 【软删的箱子不能再装货】—— 它已经被人按名注销过了
    SELECT code INTO v_ctr FROM containers
     WHERE id = p_container_id AND deleted_at IS NULL;
    IF v_ctr IS NULL THEN
        RAISE EXCEPTION 'CONTAINER_NOT_FOUND|%', COALESCE(p_container_id::text, '?')
          USING HINT = '这个箱子不存在,或者已经被注销了';
    END IF;

    UPDATE shipments SET container_id = p_container_id WHERE id = p_shipment_id;
    RETURN jsonb_build_object('shipment', v_ship, 'container', v_ctr);
END;
$function$;

CREATE OR REPLACE FUNCTION public.detach_shipment_from_container(p_shipment_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_ship text; v_old uuid;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    -- 【拆箱要理由】。装错箱与改主意是两件事,而事后只有理由分得开它们。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DETACH_REASON_REQUIRED|%',
            COALESCE((SELECT code FROM shipments WHERE id = p_shipment_id), '?');
    END IF;
    SELECT code, container_id INTO v_ship, v_old FROM shipments WHERE id = p_shipment_id FOR UPDATE;
    IF v_ship IS NULL THEN
        RAISE EXCEPTION 'SHIPMENT_NOT_FOUND|%', COALESCE(p_shipment_id::text, '?');
    END IF;
    IF v_old IS NULL THEN
        RAISE EXCEPTION 'SHIPMENT_NOT_IN_A_CONTAINER|%', v_ship;
    END IF;

    UPDATE shipments SET container_id = NULL WHERE id = p_shipment_id;
    -- 理由留在箱子的里程碑上 —— 这一层的留痕就在那里,不另开一张表
    INSERT INTO public.container_milestones (container_id, milestone, event_date, note, recorded_by)
    VALUES (v_old, 'other', CURRENT_DATE,
            'detached ' || v_ship || ': ' || btrim(p_reason), auth.uid());
    RETURN jsonb_build_object('shipment', v_ship, 'detached_from', v_old);
END;
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- (c) container_milestones —— 只增不改,更正靠追加
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE public.container_milestones (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    container_id uuid NOT NULL REFERENCES public.containers (id) ON DELETE RESTRICT,
    milestone    text NOT NULL CHECK (milestone IN
                     ('booked','gated_in','loaded','departed','arrived',
                      'customs_cleared','delivered','other')),
    -- 【NOT NULL 且【没有默认值】】—— 见表注释里那一段区分
    event_date   date NOT NULL,
    note         text,
    recorded_by  uuid DEFAULT auth.uid(),
    recorded_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.container_milestones IS
'LOG-2a:箱子走到哪一步了。**只增不改** —— 记错了就再记一条并在 note 里说清楚,
绝不回头改一行。一条被改过的里程碑,读起来与一条本来就对的一模一样,而那正是这类记录要防的事。
【milestone 是一个小枚举 + 自由文本 note】:枚举给可比性,note 给现实。other 是留给现实的那一格,不是兜底的垃圾桶。
【跟踪只有手工录入】—— 没有对接、没有轮询、没有自动状态机。所以这里的每一行都有一个人。';

COMMENT ON COLUMN public.container_milestones.event_date IS
'LOG-2a:这一步是哪天发生的。**NOT NULL,且没有默认值 —— 调用方必须自己给。**
【要把两种日期分清楚,否则这条规矩会被读成教条】:
  * 世界那一侧的事件(departed / arrived / customs_cleared)系统【无从知道】,
    必须有人录;给它一个 CURRENT_DATE 默认值,会让"没填"比"填对"更容易通过。
  * 系统自己见证的事件(例如拆箱时追加的那条 other)日期是【已知的】,
    由那个调用方显式传今天 —— 那不是"系统替人猜",是"系统记下自己做过的事"。
区别在于【谁知道这件事】,不在于用了哪个函数。';

CREATE INDEX idx_container_milestones_container
    ON public.container_milestones (container_id, event_date DESC);

CREATE OR REPLACE FUNCTION public.guard_container_milestone_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'CONTAINER_MILESTONE_IMMUTABLE|%', TG_OP
      USING HINT = '里程碑只增不改:记错了就再记一条,并在 note 里说明';
END;
$function$;

CREATE TRIGGER trg_container_milestones_append_only
    BEFORE UPDATE OR DELETE ON public.container_milestones
    FOR EACH ROW EXECUTE FUNCTION guard_container_milestone_append_only();

ALTER TABLE public.container_milestones ENABLE ROW LEVEL SECURITY;
CREATE POLICY "container_milestones select" ON public.container_milestones
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.purchasing.view'::text));
CREATE POLICY "container_milestones insert" ON public.container_milestones
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.purchasing.edit'::text));

-- ───────────────────────────────────────────────────────────────────────────
-- (d) container_documents —— 从航段清单实例化,外加自由追加
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE public.container_documents (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    container_id  uuid NOT NULL REFERENCES public.containers (id) ON DELETE RESTRICT,
    document_type text NOT NULL,
    regime        text,
    status        text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','received','not_applicable')),
    -- 【判成"不适用"要理由】—— 见下面的守卫
    na_reason     text,
    -- 这一行是从航段清单实例化来的,还是人后加的?两者不是一回事。
    from_lane     boolean NOT NULL DEFAULT false,
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid DEFAULT auth.uid(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.container_documents IS
'LOG-2a:这一箱货实际要备齐的单据。**由航段清单实例化**(lane_document_requirements),
外加人可以自由追加 —— 现实里总有清单没写到的东西,而一份改不动的清单会被绕过去。
from_lane 把两者分开:清单来的与人后加的,回头看时不是同一回事。
【regime 只是一个属性】,本层照旧不为任何具名法规建模(与 lane_document_requirements 同一条)。
【"不适用"要理由】:一个没有理由的 n/a 与一个漏掉的单据,在屏幕上长得一模一样。';

CREATE OR REPLACE FUNCTION public.guard_container_document_na_reason()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.status = 'not_applicable' AND (NEW.na_reason IS NULL OR btrim(NEW.na_reason) = '') THEN
        RAISE EXCEPTION 'CONTAINER_DOC_NA_REASON_REQUIRED|%', NEW.document_type
          USING HINT = '判一份单据"不适用"要写明为什么 —— 没有理由的不适用与漏掉长得一样';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_container_documents_na_reason
    BEFORE INSERT OR UPDATE ON public.container_documents
    FOR EACH ROW EXECUTE FUNCTION guard_container_document_na_reason();

CREATE TRIGGER trg_container_documents_updated_at
    BEFORE UPDATE ON public.container_documents
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.container_documents ENABLE ROW LEVEL SECURITY;
CREATE POLICY "container_documents select" ON public.container_documents
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.purchasing.view'::text));
CREATE POLICY "container_documents write" ON public.container_documents
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));

-- 从航段清单实例化。【它对"没定过"与"定过且为空"给出不同的答案,而不是都返回 0】
CREATE OR REPLACE FUNCTION public.instantiate_container_documents(p_container_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_lane uuid; v_state text; v_n integer := 0;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT lane_id INTO v_lane FROM containers WHERE id = p_container_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTAINER_NOT_FOUND|%', COALESCE(p_container_id::text, '?');
    END IF;
    IF v_lane IS NULL THEN
        RETURN jsonb_build_object('lane_state', 'no_lane', 'created', 0);
    END IF;

    SELECT checklist_state INTO v_state FROM lane_checklist_status WHERE lane_id = v_lane;

    -- 【三种状态原样传出去,不折叠成一个数字】。把 not_defined answer 成 created=0,
    -- 就是把"没人看过"说成"什么都不需要"。
    IF v_state = 'not_defined' THEN
        RETURN jsonb_build_object('lane_state', 'not_defined', 'created', 0);
    END IF;

    INSERT INTO container_documents (container_id, document_type, regime, from_lane)
    SELECT p_container_id, r.document_type, r.regime, true
      FROM lane_document_requirements r
     WHERE r.lane_id = v_lane AND r.deleted_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM container_documents d
                        WHERE d.container_id = p_container_id
                          AND d.document_type = r.document_type
                          AND d.from_lane);
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RETURN jsonb_build_object('lane_state', v_state, 'created', v_n);
END;
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- (e) 读视图:箱子一行,带着它的发货单、订单、客户、最新里程碑、清单状态
-- ───────────────────────────────────────────────────────────────────────────
CREATE VIEW public.container_overview
WITH (security_invoker = on) AS
SELECT
    c.id,
    c.code,
    c.container_number,
    c.vessel,
    c.voyage,
    c.departure_date,
    c.bl_number,
    c.lane_id,
    c.forwarder_id,
    f.legal_name AS forwarder_name,
    (SELECT count(*) FROM shipments s WHERE s.container_id = c.id)::integer AS shipment_count,
    (SELECT count(DISTINCT o.customer_id)
       FROM shipments s JOIN sales_orders o ON o.id = s.sales_order_id
      WHERE s.container_id = c.id)::integer AS customer_count,
    (SELECT m.milestone FROM container_milestones m
      WHERE m.container_id = c.id ORDER BY m.event_date DESC, m.recorded_at DESC LIMIT 1)
        AS latest_milestone,
    (SELECT m.event_date FROM container_milestones m
      WHERE m.container_id = c.id ORDER BY m.event_date DESC, m.recorded_at DESC LIMIT 1)
        AS latest_milestone_date,
    -- 【清单状态从航段那边原样带过来】—— 三种状态,不折叠
    COALESCE(ls.checklist_state, 'no_lane') AS lane_checklist_state,
    (SELECT count(*) FROM container_documents d
      WHERE d.container_id = c.id AND d.status = 'pending')::integer AS documents_pending
FROM public.containers c
LEFT JOIN public.suppliers f ON f.id = c.forwarder_id
LEFT JOIN public.lane_checklist_status ls ON ls.lane_id = c.lane_id
WHERE c.deleted_at IS NULL;

COMMENT ON VIEW public.container_overview IS
'LOG-2a:箱子一行 —— 发货单数、涉及几个客户、最新里程碑、清单状态、待收单据数。
【lane_checklist_state 原样带着三种状态】(not_defined / defined_empty / defined,外加没挂航段的 no_lane):
把 not_defined 折叠成"0 条待收",就是把"没人看过"显示成"齐了"。
security_invoker = on:行过滤就是 RLS 本身。';

GRANT SELECT ON public.container_overview TO anon, authenticated, service_role;

COMMIT;
