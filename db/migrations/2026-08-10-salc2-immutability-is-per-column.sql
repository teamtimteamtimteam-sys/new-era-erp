-- SAL-C2:不可变守卫改成【逐列判断】—— 否则 SAL-C 的放宽永远够不着
--
-- fixture 44 当场顶出来:补挂被 SALE_IMMUTABLE 拒了。原因不在新写的那一条,
-- 而在 cut 2a 留下的这两行:
--     OR OLD.cogs_entry_id IS NOT NULL
--     OR NEW.cogs_entry_id IS NULL
-- 它们默认【本表唯一合法的 UPDATE 就是给 cogs_entry_id 首挂】:于是任何
-- cogs_entry_id 仍为 NULL 的更新一律被拒(第二行),而 cogs 一旦挂上,整行
-- 就再也不能有任何 UPDATE(第一行)。当时只有一条放宽,这么写没问题;
-- 现在有两条,这种写法就把第二条挡在门外 —— 而且是【无论如何都够不着】。
--
-- 改成逐列表述:每一列各自说清"允许怎样的变化",互不牵连。
--   cogs_entry_id:只允许 NULL → 非 NULL(语义与从前一字不差)
--   customer_id  :只允许 NULL → 非 NULL,且只在 attribute_sale_customer 的 ctx 在场时
--   其余每一列   :一律不许变(原样保留)
-- 唯一放宽的是:cogs 已挂的行现在仍可【补挂客户】—— 这正是必须的,
-- 线上那笔无主销售的 COGS 早就过账了,按旧写法它永远补挂不上。
-- NOTE: apply with ./db/apply_migration.sh
BEGIN;

CREATE OR REPLACE FUNCTION public.reject_sales_record_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'SALE_IMMUTABLE';
    END IF;
    IF NEW.id              IS DISTINCT FROM OLD.id
       OR NEW.output_batch_id IS DISTINCT FROM OLD.output_batch_id
       OR NEW.quantity        IS DISTINCT FROM OLD.quantity
       OR NEW.unit_price      IS DISTINCT FROM OLD.unit_price
       OR NEW.currency        IS DISTINCT FROM OLD.currency
       OR NEW.fx_rate         IS DISTINCT FROM OLD.fx_rate
       OR NEW.amount_base      IS DISTINCT FROM OLD.amount_base
       OR NEW.sale_date       IS DISTINCT FROM OLD.sale_date
       OR NEW.notes           IS DISTINCT FROM OLD.notes
       OR NEW.movement_id     IS DISTINCT FROM OLD.movement_id
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
       OR NEW.created_by      IS DISTINCT FROM OLD.created_by
       -- SAL-A:出处两列同样不可变 —— 卖出去之后改口"这是算出来的"与改价同罪
       OR NEW.price_source     IS DISTINCT FROM OLD.price_source
       OR NEW.price_provenance IS DISTINCT FROM OLD.price_provenance
       -- cut 2a:cogs_entry_id 首挂(NULL → 非 NULL),挂上之后不许再动
       OR (NEW.cogs_entry_id IS DISTINCT FROM OLD.cogs_entry_id
           AND NOT (OLD.cogs_entry_id IS NULL AND NEW.cogs_entry_id IS NOT NULL))
       -- SAL-C:customer_id 的【单向】放宽 —— 只允许 NULL → 某客户,且只允许
       -- attribute_sale_customer 那一次(ctx 在场)。改投他人 / 退回 NULL 一律拒:
       -- 把已存在的债改记到另一个人头上是另一种行为,不该从这条路够得着。
       OR (NEW.customer_id IS DISTINCT FROM OLD.customer_id
           AND NOT (OLD.customer_id IS NULL
                    AND NEW.customer_id IS NOT NULL
                    AND current_setting('evoltrya.attribution_ctx', true) = 'attribute_sale_customer'))
    THEN
        RAISE EXCEPTION 'SALE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

COMMIT;
