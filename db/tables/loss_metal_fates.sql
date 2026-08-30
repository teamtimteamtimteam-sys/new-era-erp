-- db/tables/loss_metal_fates.sql
-- PROC-BUILD-1:损耗类别的【金属去向】取值。三个:金属留着 / 金属走了 / 还不知道。
--
-- 【为什么 unknown 是一个正当取值而不是一个空】本仓库为「空的两种意思」付过很多次账
-- (METAL-1 的 no_reference、SS-1 的阈值为 NULL)。这里把「我们查过,而答案是不知道」
-- 做成一个【说得出口的值】,于是它与「没有人填过」分得开 —— 后者由 NOT NULL 拦掉。
--
-- NOTE: introduced by db/migrations/2026-08-30-procbuild1-loss-categories-forms-and-saleability.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.loss_metal_fates (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.loss_metal_fates IS
'PROC-BUILD-1:损耗类别的【金属去向】取值。三个:金属留着 / 金属走了 / 还不知道。

【为什么 unknown 是一个正当取值而不是一个空】本仓库为「空的两种意思」付过很多次账
(METAL-1 的 no_reference、SS-1 的阈值为 NULL)。这里把「我们查过,而答案是不知道」
做成一个【说得出口的值】,于是它与「没有人填过」分得开 —— 后者由 NOT NULL 拦掉。';

INSERT INTO public.loss_metal_fates (code, name_en, name_zh, sort_order, notes) VALUES
    ('stays',   'Metal stays behind', '金属留着',   1, 'W2-(i):质量走了、金属没走。回收率【不该】为这一部分扣分。'),
    ('leaves',  'Metal leaves',       '金属走了',   2, 'W2-(ii):质量与金属一起走。这是回收率该扣分的那一种。'),
    ('unknown', 'Not yet known',      '还不知道',   3, '**这是一个决定,不是一个空。** 线上产出批化验 0 条,所以某些流带不带走金属【今天答不了】。把它记成 stays 或 leaves 都是在编一个数,而那个数会直接流进回收率。');

ALTER TABLE public.loss_metal_fates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "loss_metal_fates select all" ON public.loss_metal_fates
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "loss_metal_fates insert by permission" ON public.loss_metal_fates
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.processing.edit'::text));
CREATE POLICY "loss_metal_fates update by permission" ON public.loss_metal_fates
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.loss_metal_fates TO authenticated;
