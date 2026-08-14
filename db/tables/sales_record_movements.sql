-- db/tables/sales_record_movements.sql
-- SO-2b:一次销售【实际写出的每一条出库流水】,一条一行。
--
-- NOTE: introduced by db/migrations/2026-08-14-so2b-1-sales-record-movements.sql.
-- First-run script (plain CREATEs).
--
-- 【为什么它存在】IOD-1 之后销售走 drain_stock:一次销售可以跨几个库位桶,
-- 于是写出【多行】流水。而 sales_records.movement_id 是一个单值外键,只装得下
-- 排空顺序上碰巧排在第一的那条 —— 那一列因此十几周里一直在说半句真话。
-- 它已经被 DROP;腿只在这里。
--
-- 【为什么不留着那一列当"主腿"】留着就是一个【永久的半真】:它会一直看起来
-- 像"这次销售的流水",而"第一条"没有任何业务含义。两个真相源里有一个是半真的,
-- 读的人没有办法知道自己拿到的是哪一个。一处真相,或者不做。
--
-- 【movement_id 上的 UNIQUE 是判据的一半】一条出库腿只能属于一次销售;
-- 没有它,同一条腿可以被两条销售记录同时认领,而"这批货卖了几次"再也答不上来。

CREATE TABLE public.sales_record_movements (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sales_record_id  uuid NOT NULL REFERENCES public.sales_records (id) ON DELETE RESTRICT,
    movement_id      uuid NOT NULL UNIQUE REFERENCES public.inventory_movements (id) ON DELETE RESTRICT,
    created_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.sales_record_movements IS
    'SO-2b:一次销售【实际写出的每一条出库流水】,一条一行。起因:IOD-1 之后销售走 drain_stock,一次销售可以跨几个库位桶而写出多行流水,但 sales_records.movement_id 是单值外键,只装得下排空顺序上碰巧第一的那条 —— 一个永久的半真。那一列已经 DROP,腿只在这里。movement_id 上的 UNIQUE 是判据的一半:一条出库腿只能属于一次销售,否则"这批货卖了几次"再也答不上来。只增不改(guard_sales_record_movements_append_only),没有面向客户端的写策略 —— 唯一写入口是 record_output_sale。';

CREATE INDEX idx_sales_record_movements_sale ON public.sales_record_movements (sales_record_id);

-- 只增不改(函数在 db/functions/guard_sales_record_movements_append_only.sql)。
-- 改一条腿指向别的流水,等于把一笔已经发生的出库改记到另一批货上 ——
-- 与改销售记录本身同罪(SALE_IMMUTABLE)。
CREATE TRIGGER trg_sales_record_movements_append_only
    BEFORE UPDATE OR DELETE ON public.sales_record_movements
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_record_movements_append_only();

ALTER TABLE public.sales_record_movements ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT / UPDATE / DELETE 策略,这是前提而不是遗漏】唯一写入口是
-- record_output_sale(DEFINER)。留一条客户端能直插的路,等于让人写出一条与
-- 台账对不上的腿,而这张表存在的全部意义就是它与流水说的是同一件事。
CREATE POLICY "sales_record_movements select by permission" ON public.sales_record_movements
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
