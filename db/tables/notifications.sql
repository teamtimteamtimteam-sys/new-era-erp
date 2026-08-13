-- db/tables/notifications.sql
-- NTF-1:发生过的事件,只增不改。
--
-- NOTE: introduced by db/migrations/2026-08-13-ntf1-notification-center.sql.
-- First-run script (plain CREATEs).
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【事件 ≠ 仪表盘的臂,别合并】
--   * 臂(operations_now)是一个【持续成立的状态】,补上货它自己就消失了;
--   * 事件是一件【发生过的事】,它不会消失,只能被读过。补上货并不会让
--     "三天前你把货收进了一个没配置的库位"变成没发生。
--
-- 【v1 两个来源,第三个被明确排除】
--   (a) IOD-2 的落地告警 —— 此前【转瞬即逝】:渲染一次就没了,连响过的痕迹
--       都没有。这正是"事件该被留下来"的定义。
--   (b) 配置/分类改变那一刻的【事后】违规 —— IOD-2 的闸只在货落地那一刻查,
--       而那批货不会再落地一次(IOD-2 表头把它写成范围外并排给了这一刀)。
--   (c) 【METAL-1 的行情异常不在此列】:它已经持久在 metal_prices.anomaly_check
--       上,并有自己的确认流程(ackSignature 把"我看过了"绑在那一组数字上)。
--       复制过来 = 同一件事的第二份状态,而两份状态迟早各说各话。
--       **要接第三个来源,先问它是不是已经有一份持久记录 —— 如果是,通知应当
--       【指向】它,而不是【复制】它。**
--   常驻违规视图仍排在报表中心那一刀:那是"此刻全库还有哪些",要主动扫全量。
--
-- 【整张表的形状逐字照抄 approval_log】(APR-1):主体是 (subject_type, subject_id)
-- 而非一串可空外键;RLS 按 subject_type 分派到那个模块的权限码且 **ELSE false**
-- (新主体在有人给它声明模块之前不可见,不是默认公开);【没有 INSERT 策略】——
-- 唯一写入口是属主权限的 notify_* 函数;只增不改的守卫【自己报名】(FIN-31)。
--
-- 【被遮蔽的表】REVOKE + 列清单 GRANT:**将来加的列必须同时加进那个清单,
-- 否则它写得进、读不出**(AGENTS.md 那一条,FIN-6 付过账)。
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE public.notifications (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    occurred_at   timestamptz NOT NULL DEFAULT now(),
    event_type    text NOT NULL,
    subject_type  text NOT NULL,
    subject_id    uuid,
    subject_code  text,
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
CREATE INDEX idx_notifications_fingerprint ON public.notifications ((payload ->> 'fingerprint'));

COMMENT ON TABLE public.notifications IS
    'NTF-1:发生过的事件,只增不改。与 operations_now 的【臂】是两种东西:臂是持续成立、会自己消失的状态,事件是发生过、只能被读过的事实。v1 两个来源:IOD-2 的落地告警(此前转瞬即逝 —— 渲染一次就没了,连响过的痕迹都没有),以及配置/分类改变那一刻的【事后】分类违规(IOD-2 的闸只在货落地那一刻检查,而那批货不会再落地一次)。【METAL-1 的行情异常刻意不在此列】:它已经持久在 metal_prices.anomaly_check 上,并有自己的确认流程,复制过来就是同一件事的第二份状态。要接第三个来源,先问它是不是已经有一份持久记录 —— 如果是,通知应当【指向】它而不是【复制】它。主体是 (subject_type, subject_id),RLS 按 subject_type 分派到该模块的权限码且 ELSE false;没有 INSERT 策略,唯一写入口是属主权限的 notify_* 函数。';

COMMENT ON COLUMN public.notifications.payload IS
    'NTF-1:渲染这条通知所需的一切(码、数量、库位、分类),【故意冗余】—— 列表不必回连五张表,而且事件记的是【当时】的事实,主体后来改名也不会让这一行说错话。含 fingerprint:事后违规按它去重。';

CREATE TRIGGER trg_notifications_append_only
    BEFORE UPDATE OR DELETE ON public.notifications
    FOR EACH ROW EXECUTE FUNCTION public.guard_notifications_append_only();

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

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

REVOKE SELECT ON public.notifications FROM authenticated, anon;
GRANT SELECT (id, occurred_at, event_type, subject_type, subject_id, subject_code,
              payload, actor_user_id, created_at)
    ON public.notifications TO authenticated;
