-- db/tables/gst_return_boxes.sql
-- GST-1:**报出去的那一份的快照。**
--
-- 申报那一刻,把 F5 每一格的数字抄下来存在这里。此后底下的分录再动
-- (更正、补记、重估),这一份也不动 —— 与已签发单据同一条规矩。
--
-- ★【为什么必须抄下来,而不是每次重算】★ 因为"我们当时报了多少"与
--   "现在算出来是多少"是两个不同的问题,而且日后 IRAS 问的一定是前一个。
--   只留一个重算函数,等于宣称这两个问题永远同一个答案 —— 一旦有人补了一张
--   上季度的发票,那句宣称就成了假话,而报表不会告诉任何人它变了。
--   两者不一致【本身就是一条要人看的信息】,把它抹平才是错的。
--
-- ★【不可改、不可删】★ trg_gst_return_boxes_immutable 拦下 UPDATE 与 DELETE,
--   报 GST_RETURN_IMMUTABLE|box。想改数字,走 correct_gst_return —— 更正是
--   一个新事件。
--
-- 写入只走 file_gst_return / correct_gst_return(SECURITY DEFINER);
-- 这里只开 SELECT。
--
-- NOTE: introduced by db/migrations/2026-08-24-gst1-tax-codes-f5-and-filing-periods.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.gst_return_boxes (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    period_id  uuid NOT NULL REFERENCES public.gst_periods (id),
    box        text NOT NULL,                 -- 'box1' … 'box9', 'box13'
    -- 【连措辞一起抄】IRAS 日后改了格子的叫法,这一份仍然显示当时那一份的措辞。
    label_en   text NOT NULL,
    label_zh   text NOT NULL,
    value_base numeric(18,2) NOT NULL,        -- 本位币(SGD)
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT gst_return_boxes_one_per_period UNIQUE (period_id, box)
);

CREATE OR REPLACE FUNCTION public.guard_gst_return_boxes_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'GST_RETURN_IMMUTABLE|%', COALESCE(OLD.box, NEW.box);
END;
$function$;

CREATE TRIGGER trg_gst_return_boxes_immutable
    BEFORE UPDATE OR DELETE ON public.gst_return_boxes
    FOR EACH ROW EXECUTE FUNCTION public.guard_gst_return_boxes_immutable();

ALTER TABLE public.gst_return_boxes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "gst_return_boxes select by permission"
    ON public.gst_return_boxes
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

COMMENT ON TABLE public.gst_return_boxes IS
    'GST-1:**报出去的那一份的快照。** 申报那一刻把每一格的数字抄下来,此后底下的数据再动,这一份也不动 —— 与已签发单据同一条规矩。想知道"现在算出来是多少",调 f5_return();想知道"当时报了多少",读这张表。两者不一致本身就是一条要人看的信息。';
