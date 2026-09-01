-- db/tables/shifts.sql
-- PROC-SUPPORT-1(R4):班次字典。RUNTIME CONFIG —— 加一个班次是加一行。
-- ★ starts_at / ends_at 是这个数据库里【第一对】time 类型的列;在本刀之前
--   public 架构里 time/timetz 列总数为 0。那件事解释了为什么"这个班处理了什么"
--   连不到加工单上 —— 缺的是 processing_runs 那一侧的时刻(G8),不是这一侧。
--
-- NOTE: introduced by db/migrations/2026-09-01-procsupport1-a-an-operation-is-not-optional.sql.

CREATE TABLE public.shifts (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    -- ★ 全库第一个 time 列。可空 —— 【空 = 还没有人说过几点到几点】,不是 00:00。
    starts_at  time,
    ends_at    time,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    -- 【起止时刻要么都有、要么都没有】只有一头的班次说不出它覆盖哪一段。
    CONSTRAINT shifts_hours_paired CHECK (num_nonnulls(starts_at, ends_at) <> 1)
);

COMMENT ON TABLE public.shifts IS
    'PROC-SUPPORT-1(R4):班次字典。RUNTIME CONFIG —— 加一个班次是加一行。
【Tim:会有两个班】所以引导播两行。班次的【定义】不取决于产线怎么跑,这是它可以现在就建的全部理由。
★【starts_at / ends_at 是这个数据库里【第一对】time 类型的列】★ 在本刀之前,`public` 架构里 time/timetz 类型的列**总数为 0**。记下这件事,因为它解释了下面那条缺口【不是一次疏忽】。
★★【它连不到加工单,而这不是本表的毛病】★★ processing_runs 唯一的世界侧时间是 process_date,一个 **date**。于是**没有任何办法判断一张加工单属于哪一个班次**。那是阶段 7 的 **G8「一炉的时长 / 跨班次」**。在 G8 落地之前,交接班【答不出】"这个班处理了什么" —— 本刀因此**不建那一栏**,而不是建一个会装猜测的自由文本。';

COMMENT ON COLUMN public.shifts.starts_at IS
    '这个班几点开始。**可空,而空的意思是【还没有人说过】,不是 00:00。**
【为什么引导的两行都空着】Tim 说了「会有两个班」—— 那是他的话,所以两行是有出处的;但他【没有】说几点到几点,而这个库的规矩是:一个没人说过的数不许被发明出来填上。与 metal_prices.source 没有默认值、work_order_expected_outputs.basis 没有默认值同一条。Tim 在班次这一屏上填一次,线上就与镜像文件不同,那是系统在正常工作。';

INSERT INTO public.shifts (code, name_en, name_zh, starts_at, ends_at, is_active, sort_order, notes) VALUES
    ('day',   'Day shift',   '早班', NULL, NULL, true, 1,
     '【Tim:会有两个班】名字有出处,时刻没有 —— 所以时刻留空,等他说。'),
    ('night', 'Night shift', '晚班', NULL, NULL, true, 2,
     '同上。**两行都不带时刻是刻意的**,不是漏填。');

ALTER TABLE public.shifts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "shifts select all" ON public.shifts
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "shifts write by permission" ON public.shifts
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shifts TO authenticated;
