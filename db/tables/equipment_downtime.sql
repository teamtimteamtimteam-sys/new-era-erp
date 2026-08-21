-- db/tables/equipment_downtime.sql
-- EQP-2a:一行 = 一台机器【没有在跑】的一段时间。
--
-- 【为什么是一张表,而不是谁身上的一个字段】
--   * 挂在 fixed_assets 上的字段只装得下【当前状态】:机器修好之后,
--     "3 月 3 日到 7 日停过"就没地方待了,更别说第二次停机;
--   * 挂在 processing_runs 上更不对:停机恰恰是【没有加工的那段时间】。
-- 一台机器有很多段停机,每段有自己的起止与原因 —— 那是一张表的形状。
--
-- 【抄的是既有的两个先例,各取它真的有的那一半】
--   * supplier_compliance(CMP-1):一个主体 → 多条带日期的记录,结束可空
--     (所以"还没结束"表示得出来),软删/留痕;
--   * leave_requests:CHECK (end_date >= start_date) —— 本仓库"一段时间不许
--     倒着走"的原话。
--   两个先例各只有一半,所以次序那条写成【允许开口】的形式。
--
-- 【起止用 timestamptz】停机是这套系统里少数几件时刻真的有意义的事;
-- 加工只有 date,是因为加工那边从来没人记过时刻 —— 这里没有那个包袱。
-- 【两个都不给默认值】它们是世界这一侧的事实,不是这一行被敲进来的时刻。
--
-- 【本刀不连保养记录】那些记录 EQP-2b 才存在,所以这里【一列都不留】——
-- 留一个指向不存在的表的空列,读起来像"忘了填"而不是"还没到"。
-- **它的缺席是排期,不是疏漏。**
--
-- NOTE: introduced by db/migrations/2026-08-21-eqp2a-what-the-machine-did.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.equipment_downtime (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    equipment_id uuid NOT NULL REFERENCES public.fixed_assets (id),
    -- 世界侧事实,都不给默认值
    started_at   timestamptz NOT NULL,
    -- 【可空 = 还没结束】—— 这正是记录它的人当下所处的状态
    ended_at     timestamptz,
    reason       text NOT NULL,
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid,
    -- 两个记录下来的事实之差。**不是 D4 禁止的那种算术**:D4 禁的是
    -- 可用率/OEE —— 那需要一个没有人选过的分母。相减不需要判断。
    duration     interval GENERATED ALWAYS AS (ended_at - started_at) STORED,
    CONSTRAINT equipment_downtime_period_order
        CHECK (ended_at IS NULL OR ended_at >= started_at),
    CONSTRAINT equipment_downtime_reason_stated
        CHECK (btrim(reason) <> '')
);

COMMENT ON TABLE public.equipment_downtime IS 'EQP-2a:一行 = 一台机器【没有在跑】的一段时间。
【开口的那一段是常态,不是例外】ended_at 可空 —— 机器停下来的那一刻就有人记它,
而那时没人知道它什么时候好。所以"已开始、未结束"必须表示得出来。
【一台机器同时只能有一段没结束的停机】uq_equipment_downtime_open 那条部分唯一索引 ——
机器不会同时坏两次。
【本刀不连保养记录】保养/维修记录要到 EQP-2b 才存在,所以这里【一列都不留】。
留一个指向不存在的表的空列,读起来像"忘了填"而不是"还没到"。
**这个缺席是排期,不是疏漏** —— EQP-2b 落地时加那条外键。
【本刀刻意不算可用率,也不算 OEE】记下"机器停了多久"是一个【事实】;
算出"可用率 87%"是一个【判断】,而它的分母没有人选过:
日历小时?排班小时?计划生产小时?三种算出来的是三个数,而这盘生意
今天连排班表都不存在(加工那一族里没有任何开始/结束/班次列 —— 实测)。
**返回条件:有人把分母定下来的那一天** —— 那时它是一次决定,不是一个默认值。';

COMMENT ON COLUMN public.equipment_downtime.duration IS 'EQP-2a:这一段停了多久,= ended_at − started_at,由数据库自己算(生成列)。
还没结束时它是 NULL —— 那不是"零",是"还不知道"。';

COMMENT ON CONSTRAINT equipment_downtime_period_order ON public.equipment_downtime IS 'EQP-2a:一段时间不许倒着走 —— 抄的是 leave_requests_date_order 的原话,
但写成【允许开口】的形式:还没结束(ended_at 为空)时这条约束不适用。
两个先例各有一半 —— supplier_compliance 有开口没次序,leave_requests 有次序没开口。';

-- 一台机器同时只能有一段没结束的停机(先例:uq_expenses_live_po_line /
-- idx_year_closes_active —— 同一个"活着的那一条只能有一条"的形状)。
CREATE UNIQUE INDEX uq_equipment_downtime_open
    ON public.equipment_downtime (equipment_id)
    WHERE ended_at IS NULL;

CREATE INDEX idx_equipment_downtime_equipment ON public.equipment_downtime (equipment_id);

ALTER TABLE public.equipment_downtime ENABLE ROW LEVEL SECURITY;

-- 【读:两个模块的 OR】套用 AGENTS.md 第 2 条常设决定(batch_margin 里逐字实现着)。
-- 实测没有哪个业务角色两个都持:operations 有 processing.edit 没有 finance.view,
-- finance/auditor 反过来,只有 admin/gm 两个都有。机器卡在财务、干活的人在加工,
-- 两边都要读得到停机 —— 少了 OR,总有一边看不见。
CREATE POLICY "equipment_downtime select by permission"
    ON public.equipment_downtime
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text) OR has_permission('module.processing.view'::text));

-- 【写:加工侧】记停机的是车间。没有新权限码,也没有把财务的数据给操作侧写 ——
-- 这是一张新表,它自己带策略;fixed_assets 只是被外键引用,而外键校验不走 RLS。
CREATE POLICY "equipment_downtime insert by permission"
    ON public.equipment_downtime
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "equipment_downtime update by permission"
    ON public.equipment_downtime
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
