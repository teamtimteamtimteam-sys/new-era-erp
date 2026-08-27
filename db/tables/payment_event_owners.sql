-- db/tables/payment_event_owners.sql
-- CASHFLOW-1：每一种需要估计的付款触发事件，谁来保管那个估计（Tim 2026-08-24 裁定）。
--
-- NOTE: introduced by db/migrations/2026-08-28-cashflow1-expected-dates-and-13-week-forecast.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.payment_event_owners (
    trigger_event text PRIMARY KEY
        CHECK (trigger_event IN ('on_shipment', 'on_arrival', 'post_assay')),
    -- ★【为什么是文本而不是 employees 的外键】★ 实测:Sandra Yap 与
    -- Fu Sheng Wong **不在 employees 里**(21 名员工,一个都对不上)。
    -- 做成外键只有两条路:要么种子灌不进去(重建库当场失败),要么【替他们
    -- 编两行员工档案】—— 而后者是凭空造一个人事实。所以先记名字。
    -- 他们成为在册员工的那一天,加一列可空的 employee_id 是一次小改动;
    -- 而现在把它做成外键,是让一条真裁定去迁就一个还不存在的表。
    owner_name    text NOT NULL,
    note          text,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid
);

COMMENT ON TABLE public.payment_event_owners IS
    'CASHFLOW-1:每一种【需要估计的】付款触发事件,谁来保管那个估计。Tim 2026-08-24 裁定:on_shipment → Sandra Yap;on_arrival → Fu Sheng Wong;post_assay → Fu Sheng Wong。【为什么只有三种】另外两种不需要估计:fixed_date 由表上那条 CHECK 保证已经带着真日期,on_order 的日子是 purchase_orders.order_date 这个事实。【为什么 owner 是文本不是外键】实测那两位不在 employees 里(21 名员工,一个都对不上);做成外键要么让重建库灌不进种子,要么逼人替他们编两行员工档案。他们在册那天再加 employee_id 是小事;现在做成外键是让一条真裁定去迁就一个还不存在的行。【它为什么必须存在】一个没人拥有的估计会停止被维护,而一份读着停止维护的估计的预测,会安静地变成虚构 —— 这一刀的全部风险就在这里。';

ALTER TABLE public.payment_event_owners ENABLE ROW LEVEL SECURITY;

CREATE POLICY "payment_event_owners select by permission" ON public.payment_event_owners
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text)
        OR has_permission('module.finance.view'::text));

-- 种子:Tim 的裁定,逐字
INSERT INTO public.payment_event_owners (trigger_event, owner_name, note) VALUES
    ('on_shipment', 'Sandra Yap',    '装运日的预计由商务侧保管 —— 她在跟船期'),
    ('on_arrival',  'Fu Sheng Wong', '到港日的预计由运营侧保管'),
    ('post_assay',  'Fu Sheng Wong', '化验完成日的预计由运营侧保管 —— 实验室周转是他在盯')
ON CONFLICT (trigger_event) DO NOTHING;
