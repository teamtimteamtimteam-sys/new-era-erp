-- AUDEL-1a:把三个硬删洞堵上,而且是【具名拒绝】,不是外键报错、不是沉默
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【三个洞都是 AUDEL-0 用回滚型探针实测出来的,不是推断的】
--
-- ① **盘点单可以两步硬删,不留任何痕迹。**
--    单删表头(无行时):删掉 1 行。有行时被 stocktake_lines 的 RESTRICT 挡住 ——
--    但【先删行、再删头】照样成功:又是 1 行。
--    这是三个洞里最重的一个:盘点单是【解释一次库存调整的那份单据】,
--    而它的 adjustment 流水是不可改的。文件没了、流水还在 —— 台账说库存动过,
--    没有任何东西说得出为什么。**幸存的证据看起来是完整的**,这才是最坏的地方。
--
-- ② **从未动过的批次可以硬删,而且会连带删掉化验含量。**
--    inbound_batches / output_batches 的 DELETE 策略是开着的
--    (module.inbound.edit / module.output.edit);inventory_movements 与
--    stocktake_lines 的外键是明写的 RESTRICT,所以【一旦动过就删不掉】。
--    但一个还没有任何台账行的批次删得干净利落(实测各 1 行)。
--    **为什么这个"从未动过"的窗口值得单独堵**:inbound_batch_metals /
--    output_batch_metals 的外键是 **CASCADE** —— 那些行是【化验结果】,
--    是实验室对这批料说过的话。批次一删,它们跟着消失,而且不留痕迹。
--    一个录错了的批次要撤销,那是软删(它会写一条 writeoff 流水);
--    硬删不是撤销,是让这件事从来没发生过。
--
-- ③ **零明细的采购单可以硬删**(实测 1 行)。有明细时确实删不掉,但拦住它的
--    是一次【顺带】:CASCADE 删掉明细行时触发了写历史的触发器,而那条历史行的
--    外键指回已经被删的采购单,于是失败。用户看到的原文是:
--
--        insert or update on table "purchase_order_history" violates foreign key
--        constraint "purchase_order_history_purchase_order_id_fkey"
--
--    这句话【既没说是哪张单据,也没说规矩是什么】,而且它对零明细的单子完全
--    不成立。安全靠巧合,而巧合给的是一句看不懂的话 —— 这正是本仓库反复付过
--    学费的那个形状(FIN-31 的"自己报名,不靠外键顺带挡")。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【两层,与流水那一族同形:策略拿掉 + 守卫在场】
-- 盘点那两张表的 DELETE 策略是【够得着的】:PostgREST 把每一张表都暴露出去,
-- 任何持 module.stocktakes.edit 的人都能直接 DELETE,哪怕界面上没有那个按钮。
-- 所以策略删掉。守卫仍然要有 —— 它挡的是服务角色/属主那条路(冒烟、脚本、
-- 将来的 RPC),而那条路正是策略管不到的。
--
-- 【一个必须说清的后果】策略没了之后,**普通登录用户看到的是"0 行",不是那句
-- 具名拒绝** —— RLS 先把行过滤掉,触发器根本轮不到。这与 invoices / shipments /
-- credit_notes / inventory_movements 今天的行为一模一样(AUDEL-0 实测:那四张
-- 表对普通用户都是静默 0 行,具名拒绝只有服务角色看得到)。
-- 批次与采购单【保留】各自的 DELETE 策略,所以那两处的具名拒绝是普通用户
-- 真的看得见的。这个不对称是有意的,写在这里,也写进切次报告。
--
-- 【只挡 DELETE,不挡 UPDATE】软删是一次 UPDATE(置 deleted_at),它必须继续能跑 ——
-- 而且它会写 writeoff 流水(FIN-32)。所以触发器是 BEFORE DELETE,不是家族里
-- 那种 BEFORE UPDATE OR DELETE 的只增不改。
--
-- 【实测:今天没有任何一条合法路径会撞上这三个守卫】应用侧对这五张表零处
-- `.delete()`;数据库函数里零处 `DELETE FROM`;盘点重盘走的是 upsert
-- (onConflict stocktake_id,inbound_batch_id),不是先删后插。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. 盘点:表头与明细行【同一条规矩】
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么明细行也要守】两步路才是那个洞:把行从表头底下删走,与删掉表头
-- 是同一件事 —— 一张少了几行的盘点单,和一张不存在的盘点单,对审计一样没用。
CREATE OR REPLACE FUNCTION public.guard_stocktake_no_hard_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    -- 【消息里点名的是那份【单据】】—— 明细行没有自己的号,它报父单的号,
    -- 因为读到这句话的人要去找的是那张盘点单,不是一个行 id。
    IF TG_TABLE_NAME = 'stocktakes' THEN
        v_code := OLD.code;
    ELSE
        SELECT s.code INTO v_code FROM stocktakes s WHERE s.id = OLD.stocktake_id;
    END IF;
    RAISE EXCEPTION 'STOCKTAKE_NO_HARD_DELETE|%', COALESCE(v_code, '?');
END;
$function$;

CREATE TRIGGER trg_stocktakes_no_hard_delete
    BEFORE DELETE ON public.stocktakes
    FOR EACH ROW EXECUTE FUNCTION public.guard_stocktake_no_hard_delete();

CREATE TRIGGER trg_stocktake_lines_no_hard_delete
    BEFORE DELETE ON public.stocktake_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_stocktake_no_hard_delete();

-- 【策略拿掉】—— 见抬头:PostgREST 把它暴露给任何持 module.stocktakes.edit 的人,
-- 而界面上根本没有这个按钮。两层里的第一层。
DROP POLICY "stocktakes delete by permission" ON public.stocktakes;
DROP POLICY "stocktake_lines delete by permission" ON public.stocktake_lines;

-- ════════════════════════════════════════════════════════════════════════════
-- 2. 批次:进料与产出【同一条规矩】,而且【与动没动过无关】
-- ════════════════════════════════════════════════════════════════════════════
-- 外键的 RESTRICT 只在批次已经有台账行/销售/盘点行时才拦得住。这个守卫不问
-- 那个问题:一个刚建出来、还没动过的批次同样删不掉 —— 因为它的化验含量
-- (inbound_batch_metals / output_batch_metals,CASCADE)一样是实验室结果。
CREATE OR REPLACE FUNCTION public.guard_batch_no_hard_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 撤销一个录错的批次走【软删】(置 deleted_at)—— 它会写一条 writeoff 流水,
    -- 于是"这批料曾经在册、后来被注销"仍然读得出来。硬删不是撤销:
    -- 它让这件事从来没发生过,并且带走化验含量。
    RAISE EXCEPTION 'BATCH_NO_HARD_DELETE|%', OLD.code;
END;
$function$;

CREATE TRIGGER trg_inbound_batches_no_hard_delete
    BEFORE DELETE ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_no_hard_delete();

CREATE TRIGGER trg_output_batches_no_hard_delete
    BEFORE DELETE ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_no_hard_delete();

-- ════════════════════════════════════════════════════════════════════════════
-- 3. 采购单:把那句看不懂的外键报错换成一句人话
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.guard_purchase_order_no_hard_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 【自己报名,不靠外键顺带挡】(FIN-31 那一条)。此前拦住带明细采购单的是
    -- purchase_order_history 的外键,而那句报错既没说是哪张单、也没说规矩;
    -- 零明细的单子它更是完全不拦。撤销一张采购单走 cancel_purchase_order,
    -- 它留下 cancelled_at 与 cancel_reason。
    RAISE EXCEPTION 'PO_NO_HARD_DELETE|%', OLD.code;
END;
$function$;

CREATE TRIGGER trg_purchase_orders_no_hard_delete
    BEFORE DELETE ON public.purchase_orders
    FOR EACH ROW EXECUTE FUNCTION public.guard_purchase_order_no_hard_delete();

COMMIT;
