-- db/tables/gst_periods.sql
-- GST-1:GST 申报期间(标准为一个季度)。
--
-- ★【它与会计期间锁不是同一件事】★ 两者都叫"关账",却按不同节奏走:
--   · finance_settings.locked_before 按【月】推进,跟着月结走;
--   · gst_periods 按【季】推进,跟着申报走。
--   但一份"已申报"而底下分录还能改的申报是一句假话 —— 报给 IRAS 的数字与
--   库里现在算出来的数字会无声地分开。所以 file_gst_return 的前置条件是
--   locked_before > period_end(那一季的每个月都已关账),
--   拒绝有名字:GST_PERIOD_NOT_LOCKED|code|period_end|locked_before。
--
-- ★【申报这个动作发生在 IRAS 网站上,不在这里】★ 这张表记录的是
--   "报了什么 / 什么时候报的 / 谁报的 / 参考号是多少",不是一次提交。
--   把它写成"提交"会让人以为按下按钮就报完了,那是一个会让公司逾期的误解。
--
-- ★【更正是一个新事件,不是一次编辑】★ 与已签发单据同一条规矩:
--   correct_gst_return 建【新的一行】(code 为 <原 code>-F7-N),
--   corrects_period_id 指着被更正的那一期,原来那一份原样保留、状态仍是 filed。
--   理由必填 —— 一次没有理由的更正,日后对着 IRAS 无从交代。
--
-- 写入只走 SECURITY DEFINER 函数(open_gst_period / file_gst_return /
-- correct_gst_return);这里只开 SELECT。
--
-- NOTE: introduced by db/migrations/2026-08-24-gst1-tax-codes-f5-and-filing-periods.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.gst_periods (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code               text NOT NULL UNIQUE,          -- 'GST-2025-Q1';更正件为 'GST-2025-Q1-F7-1'
    period_start       date NOT NULL,
    period_end         date NOT NULL,
    status             text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'filed')),
    filed_at           timestamptz,
    filed_by           uuid,
    filed_on           date,                          -- 实际在 IRAS 报出去的那一天
    filed_reference    text,                          -- IRAS 的回执 / 参考号
    notes              text,
    -- 更正件指向被更正的那一期;原件的这一列为 NULL。
    corrects_period_id uuid REFERENCES public.gst_periods (id),
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid DEFAULT auth.uid(),
    CONSTRAINT gst_periods_window CHECK (period_end >= period_start),
    -- 【状态与它的证据必须一起成立】open 就不该有申报痕迹,filed 就必须有
    -- 时间与报出去的日期。少了这条,一行可以既是 'filed' 又没有任何申报记录,
    -- 而那种行会以"已申报"的样子出现在屏幕上。
    CONSTRAINT gst_periods_filed_shape CHECK (
        (status = 'open'  AND filed_at IS NULL AND filed_on IS NULL AND filed_reference IS NULL)
     OR (status = 'filed' AND filed_at IS NOT NULL AND filed_on IS NOT NULL)
    )
);

ALTER TABLE public.gst_periods ENABLE ROW LEVEL SECURITY;
CREATE POLICY "gst_periods select by permission"
    ON public.gst_periods
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

COMMENT ON TABLE public.gst_periods IS
    'GST-1:GST 申报期间(季度)。与会计期间锁【不是同一件事】—— 会计锁按月、随月结推进,GST 期间按季、随申报推进。但一个"已申报"而底下分录还能改的期间是一句假话,所以申报的前置条件是 locked_before > period_end(那一季每个月都已关账)。更正【不是编辑】:它是新的一行,corrects_period_id 指着被更正的那一期。';
