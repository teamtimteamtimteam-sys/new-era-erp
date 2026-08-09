-- SAL-B:信用管控 —— 限额与冻结在客户上,敞口现算,拦截在销售落笔处
--
-- 自成一体、不碰账(docs/sales-scoping.md §6/§8)。要点:
--
-- 【NULL 与 0 相反,这个区别就是本切】credit_limit_base 为 NULL = 【没设限额】
-- (放行 —— 全部既有客户都是这个状态,管控按客户逐个启用,首日什么都不拦);
-- 为 0 = 【现款现货】(任何赊销都拒)。把 NULL 当 0 用,是 restricted-is-not-zero
-- 那个病的第五件衣服 —— 而这一件会拒掉销售。结构上表达:检查写成
-- IF v_limit IS NOT NULL THEN …,fixture 39 A 臂两头钉死。
--
-- 【敞口是导出的,不是存的】存一个"当前欠款余额"必然漂移(与 ar_open_items 的
-- settled 同一条理由)。比较在【本位币】—— 单据币种比较会让 USD 客户越过 SGD
-- 客户越不过的限额,与审批阈值(APR-2 / fixture 35A)同一个病。
--
-- 【没有越权放行的路】被拦了,出路是提高限额或解除冻结 —— 都是客户上有痕迹的改动。
-- 销售上加 override 旗,等于造一个背后没有审批引擎的审批机制(APR-2 的引擎关着)。
-- 但限额与冻结的【每次变动都留痕】(pricing_formula_history 的形状):限额是商务
-- 承诺,为推一单而抬限额恰恰是最该留痕的动作。
--
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. 客户上的两个字段
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.customers
    ADD COLUMN credit_limit_base numeric CHECK (credit_limit_base IS NULL OR credit_limit_base >= 0),
    ADD COLUMN credit_hold boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.customers.credit_limit_base IS
    '信用限额,以本位币计(SAL-B)。【NULL = 没设限额(放行);0 = 现款现货(任何赊销都拒)—— 两个都正当,而且相反】。全部既有客户为 NULL:管控按客户逐个启用,首日什么都不拦 —— 空效果是设计,不是坏了。变动由触发器留痕(customer_credit_history)。';
COMMENT ON COLUMN public.customers.credit_hold IS
    '人工冻结(SAL-B):无论敞口多少都停发 —— 客户在争议一张发票时停止发货不是算术条件。解除也是客户上的显式改动,同样留痕。';

-- ════════════════════════════════════════════════════════════════════════════
-- 2. 变动留痕(pricing_formula_history 的形状:触发器写、只增不改)
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.customer_credit_history (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id       uuid NOT NULL REFERENCES public.customers (id),
    old_credit_limit_base numeric,
    new_credit_limit_base numeric,
    old_credit_hold   boolean,
    new_credit_hold   boolean,
    changed_at        timestamptz NOT NULL DEFAULT now(),
    changed_by        uuid
);

CREATE INDEX idx_customer_credit_history_customer
    ON public.customer_credit_history (customer_id, changed_at DESC);

COMMENT ON TABLE public.customer_credit_history IS
    '客户信用限额/冻结的只增不改变动史(SAL-B,pricing_formula_history 的形状)。触发器写入 —— 客户编辑是普通 UPDATE,没有 RPC 可挂。为推一单而抬限额是最该留痕的动作。触发器之前的状态没有行:空白好过编造。';

CREATE OR REPLACE FUNCTION public.log_customer_credit_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.credit_limit_base IS DISTINCT FROM OLD.credit_limit_base
       OR NEW.credit_hold IS DISTINCT FROM OLD.credit_hold THEN
        INSERT INTO customer_credit_history
            (customer_id, old_credit_limit_base, new_credit_limit_base,
             old_credit_hold, new_credit_hold, changed_by)
        VALUES (NEW.id, OLD.credit_limit_base, NEW.credit_limit_base,
                OLD.credit_hold, NEW.credit_hold, auth.uid());
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_customers_credit_history
    BEFORE UPDATE OF credit_limit_base, credit_hold ON public.customers
    FOR EACH ROW EXECUTE FUNCTION public.log_customer_credit_change();

CREATE OR REPLACE FUNCTION public.guard_customer_credit_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 留痕被改写过就不是留痕了。自己报名(FIN-31)。
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'CREDIT_HISTORY_APPEND_ONLY|update|%', OLD.id;
    ELSE
        RAISE EXCEPTION 'CREDIT_HISTORY_APPEND_ONLY|delete|%', OLD.id;
    END IF;
END;
$function$;

CREATE TRIGGER trg_customer_credit_history_append_only
    BEFORE UPDATE OR DELETE ON public.customer_credit_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_customer_credit_history_append_only();

ALTER TABLE public.customer_credit_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "customer_credit_history select by permission"
    ON public.customer_credit_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.customers.view'::text));
-- 【没有 INSERT 策略】唯一写入口是触发器(属主身份)—— 留痕不该有第二个写法

-- ════════════════════════════════════════════════════════════════════════════
-- 3. 敞口:一份实现,三处消费(拦截、看板臂、屏幕)
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么不读 ar_open_items】那张视图挂 has_permission('module.finance.view'),
-- 而 has_permission 按【调用者】解析 —— sales 角色没有财务权限,从视图读到零行,
-- 敞口塌成 0,拦截静默失效(OPS-14 / batch_margin 的 is_stale 同一个病)。
-- 所以按同一份算术就地算(open_ccy = qty×price − settled,open_base = ×fx_rate,
-- settled 只计 posted 的收款核销)。【重复的定义会漂】—— fixture 39 E 臂断言本函数
-- 与 ar_open_items 对同一客户给出同一个和;改一边必须改两边,注释互指。
CREATE OR REPLACE FUNCTION public.customer_ar_exposure_base(p_customer_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(sum(open_base), 0) FROM (
        SELECT round((sr.quantity * sr.unit_price - COALESCE(s.settled, 0)) * sr.fx_rate, 2) AS open_base
        FROM sales_records sr
        LEFT JOIN LATERAL (
            SELECT sum(pa.allocated_ccy) AS settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.sales_record_id = sr.id
        ) s ON true
        WHERE sr.customer_id = p_customer_id
          AND round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0), 2) > 0
    ) x;
$function$;

COMMENT ON FUNCTION public.customer_ar_exposure_base(uuid) IS
    '客户的应收敞口,本位币(SAL-B)。与 ar_open_items 同一份算术,就地算而不读视图 —— 视图按调用者的 module.finance.view 裁行,sales 读到零行敞口塌成 0(OPS-14 的病)。fixture 39E 钉两者一致。EXECUTE 已从 authenticated 收回:它无调用者检查,靠调不到 —— 消费方是 record_output_sale(definer)与 operations_now(属主视图)。';

COMMIT;
