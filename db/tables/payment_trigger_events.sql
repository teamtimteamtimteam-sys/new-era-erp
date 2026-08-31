-- db/tables/payment_trigger_events.sql
-- EQP-PAY-1:付款里程碑字典。
--
-- 【本表存在之前,这份清单住在六个地方、零行数据里】两张表各一条 CHECK
-- (purchase_order_payment_terms / payment_term_template_lines),加上
-- app/purchasing/orders/new/actions.ts 的 TRIGGERS、NewOrderForm.tsx 的
-- TRIGGER_OPTIONS、messages/{en,zh}.ts 的 trigger 标签、以及单据 PDF 的
-- TRIGGER_PHRASE。"加一种里程碑"当时意味着改六处代码,而漏掉一处的后果是
-- 一个值在一处存在、在另一处不存在 —— 那正是本表要消灭的漂移。
--
-- ★【为什么是一张表配两个适用性布尔量,不是"材料字典"与"设备字典"两张表】★
-- on_order 与 fixed_date 对材料和设备**是同一个概念**。拆成两张表就是把同一个
-- 概念写成两行,而两行会漂:改了一边忘了另一边,同一个词在两张单上开始表示不同的事。
--
-- 【排除的判据是"这件事会不会发生在它身上"】post_assay 对设备为 false —— 机器不化验
-- (这就是 Tim 用系统时撞见的那个缺陷,变成一格数据)。而 on_shipment 对设备
-- 【是 true】:凭装运单据付款是设备进口的常规。R5 说一个用不上的选项比一个缺失的
-- 更糟(因为它选得中);反过来把一个用得上的选项拿掉,同样是错的。
--
-- 【本表是 RUNTIME CONFIG 吗?不是 —— 它是 SEED】适用性不是操作员的偏好,
-- 是"这件事会不会发生在这类采购上"这个事实。它变了意味着业务变了,该走迁移。
--
-- NOTE: introduced by db/migrations/2026-09-01-eqppay1-b-equipment-milestones-and-retention.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.payment_trigger_events (
    code                 text PRIMARY KEY,
    name_en              text NOT NULL,
    name_zh              text NOT NULL,
    -- 单据正文里的介词短语(PDF 用)。【与 name_en 分开】:标签是 "On order",
    -- 而句子里要的是 "on order" —— PurchaseOrderDocument 此前自己 replace('_',' ')
    -- 再补一个 on,印出过 "on on shipment"。介词属于数据,不属于那份模板。
    phrase_en            text NOT NULL,
    applies_to_material  boolean NOT NULL,
    applies_to_equipment boolean NOT NULL,
    can_anchor_retention boolean NOT NULL DEFAULT false,
    sort_order           integer NOT NULL,
    is_active            boolean NOT NULL DEFAULT true,
    created_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT payment_trigger_events_applies_to_something
        CHECK (applies_to_material OR applies_to_equipment)
);

COMMENT ON TABLE public.payment_trigger_events IS
'EQP-PAY-1:付款里程碑字典。【本表存在之前,这份清单住在六个地方、零行数据里】——
两张表各一条 CHECK,加上 actions.ts / NewOrderForm.tsx / messages(en+zh)/ 单据 PDF。
"加一种里程碑"当时意味着改六处代码,而漏掉一处的后果是一个值在一处存在、在另一处不存在。

★【为什么是一张表配两个适用性布尔量,不是"材料字典"与"设备字典"两张表】★
on_order 与 fixed_date 对材料和设备**是同一个概念**。拆成两张表就是把同一个概念
写成两行,而两行会漂:改了一边忘了另一边,同一个词在两张单上开始表示不同的事。

【排除的判据是"这件事会不会发生在它身上"】post_assay 对设备为 false —— 机器不化验。
而 on_shipment 对设备【是 true】:凭装运单据付款是设备进口的常规。R5 说一个用不上的
选项比一个缺失的更糟(因为它选得中);反过来把一个用得上的选项拿掉,同样是错的。';

COMMENT ON COLUMN public.payment_trigger_events.can_anchor_retention IS
'这个事件有没有一个【系统真的记录得下来】的日期 —— 只有为 true 的事件才能当质保金的锚。
今天只有 acceptance_complete 为 true,它的日期在 fixed_assets.acceptance_date。
【为什么必须有这一格】质保金的到期日是"锚事件的日期 + N 个月"。锚在一个没有日期的
事件上(比如 training_complete),到期日就【算不出来】—— 而算不出来的到期日,
要么变成一个永远不到期的行,要么诱使人去编一个日期。两个都比拒绝差。';

-- ═══ 种子 ═══════════════════════════════════════════════════════════════════
-- 【材料那一侧原样保留 5 种】本刀不动材料;设备那一侧新增三种,
-- 而"交付/到货"由既有的 on_arrival 承担 —— 不为同一件事新开一行。
INSERT INTO public.payment_trigger_events
    (code, name_en, name_zh, phrase_en, applies_to_material, applies_to_equipment, can_anchor_retention, sort_order) VALUES
    ('on_order',              'On order',              '下单时',   'on order',                       true,  true,  false, 10),
    ('on_shipment',           'On shipment',           '装运时',   'on shipment',                    true,  true,  false, 20),
    ('on_arrival',            'On arrival',            '到货时',   'on arrival',                     true,  true,  false, 30),
    ('post_assay',            'After assay',           '化验后',   'after assay',                    true,  false, false, 40),
    ('installation_complete', 'Installation complete', '安装完成', 'on completion of installation',  false, true,  false, 50),
    ('acceptance_complete',   'Acceptance complete',   '验收合格', 'on acceptance',                  false, true,  true,  60),
    ('training_complete',     'Training complete',     '培训完成', 'on completion of training',      false, true,  false, 70),
    ('fixed_date',            'Fixed date',            '固定日期', 'on the fixed date',              true,  true,  false, 80);

ALTER TABLE public.payment_trigger_events ENABLE ROW LEVEL SECURITY;

-- 字典是【给下拉框读的】,而下拉框出现在采购与财务两处屏幕上。
CREATE POLICY "payment_trigger_events select by permission"
    ON public.payment_trigger_events
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text)
        OR has_permission('module.finance.view'::text));
