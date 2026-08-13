-- db/tables/notification_reads.sql
-- NTF-1:谁读过哪一条。
--
-- NOTE: introduced by db/migrations/2026-08-13-ntf1-notification-center.sql.
-- First-run script (plain CREATEs).
--
-- 【为什么单独一张表,而不是 notifications.read_at】已读是【每个读者自己的】
-- 状态,不是事件的属性。今天只有一个用户,写在事件行上确实更省 —— 但它会在
-- 第二个用户出现的那一天【静默变错】(一个人读过 = 所有人已读),而那种错
-- 不会报错、不会红,只会让人漏掉通知。多一张表是今天唯一的代价。
--
-- 【与 notifications 相反,这张表允许客户端直写】—— 它记的不是"发生了什么"
-- (那必须伪造不出来),而是"我看过了",而那句话本来就只有读者自己说得出。
-- RLS 三条策略都锁在 user_id = auth.uid()。

CREATE TABLE public.notification_reads (
    notification_id uuid NOT NULL REFERENCES public.notifications (id) ON DELETE CASCADE,
    user_id         uuid NOT NULL,
    read_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (notification_id, user_id)
);

COMMENT ON TABLE public.notification_reads IS
    'NTF-1:谁读过哪一条。【每个读者自己的状态】,所以不写在 notifications 行上 —— 写在那里今天更省,但第二个用户出现时会静默变错(一个人读过 = 所有人已读),而那种错不会报错。RLS:只读得到、也只写得动自己的行。';

ALTER TABLE public.notification_reads ENABLE ROW LEVEL SECURITY;

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
