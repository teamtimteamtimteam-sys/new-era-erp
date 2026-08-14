-- db/migrations/2026-08-14-so2b-0-create-sales-order-one-door.sql
-- SO-2b 之一:建单收归【一扇门】—— 而那扇门关上的,是一条从来没写进去过的留痕
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【起因不是洁癖,是一条已经在线上错了的数据】
-- SO-1 的建单走的是三条【客户端直插】:
--     supabase.from('sales_orders').insert(...)
--     supabase.from('sales_order_lines').insert(...)
--     await supabase.from('sales_order_history').insert({ change_type: 'created' })
-- 第三条【没有 INSERT 策略】(SO-1 有意为之:留痕的唯一写入口应当是属主权限的
-- 函数),于是它被 RLS 拒;而那一句连返回值都没有解构,于是拒得无声无息。
-- 线上核对:SO-2026-0001 的历史里只有 confirmed 与 issued,【没有 created】——
-- 那张单是怎么来的,历史里查不到。
--
-- 【这正是 check-error-swallowing 自己写明的盲区】它抓的是 `data ?? []` 那一族;
-- 一个从头到尾没有解构 error 的 `await`,它看不见。所以这里【不是加一句
-- if (error) throw】—— 那只是把同一个形状再赌一次。三张表一次写完、要么全成
-- 要么全不成,才是这条错误不可能再发生的写法。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【形状照抄建批次那一刀(IOD-1b)】一个 SECURITY DEFINER 函数,
-- require_permission('module.sales.edit'),同一个事务里写单头 + 单行 + 留痕;
-- 然后【撤掉客户端的 INSERT 策略】。撤掉那条策略是这扇门的【前提】,不是一次
-- 顺手收紧:留着侧门,下一个人照样可以插一张没有留痕的单,而这一刀就白做了。
--
-- 【只撤 INSERT】UPDATE/DELETE 策略原样留着 —— 改单(SO-1b)还没落地,
-- 而确认之后的冻结由 guard_sales_order_confirmed_immutable 把门,与本刀无关。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【补记 SO-2026-0001 的那一行 created,以及为什么这不是伪造】
-- 本仓库反复拒绝"回填":化验出处、行情检查、承诺条款 —— 那些都是【事后重算
-- 一个当时没人算过的判断】,补出来的是一句没人说过的话。
-- 这一行不同:那张单【确实被建出来了】,时间戳就写在 sales_orders.created_at,
-- 建单的人就写在 created_by。缺的不是事实,是【记录事实的那次写入】。
-- 所以补的是一条真的事,而且不用任何推断:两列原样抄过来。
-- detail 里【写明它是补记的、以及为什么】—— 一条不说自己是补记的补记,
-- 与伪造在读者眼里没有区别。
--
-- 镜像:db/functions/create_sales_order.sql(新)、
--       db/tables/{sales_orders,sales_order_lines}.sql(撤策略)。
-- 行为断言:fixture 65。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 唯一的那扇门 ═══════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.create_sales_order(
    p_customer_id uuid,
    p_order_date date,
    p_currency text,
    p_fx_rate numeric,
    p_lines jsonb,
    p_notes text DEFAULT NULL,
    p_terms_text text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_code  text;
    v_id    uuid;
    v_line  jsonb;
    v_i     int := 0;
    v_n     int;
BEGIN
    PERFORM require_permission('module.sales.edit');

    -- 【订单日永不默认】物理事件日:补一个 CURRENT_DATE 会让"留空"比"填对"
    -- 更容易通过(AGENTS.md 的日期规矩,FIN-10 那一族的命名)。
    IF p_order_date IS NULL THEN
        RAISE EXCEPTION 'ORDER_DATE_REQUIRED';
    END IF;
    IF p_customer_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'SO_CREATE_CUSTOMER_INVALID|%', COALESCE(p_customer_id::text, '?');
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies WHERE code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- 【汇率没有默认值 —— FIN-35】假设出来的 1:1 在非本位币单据上永远是错的,
    -- 而且看起来完全正常。
    IF p_fx_rate IS NULL OR p_fx_rate <= 0 THEN
        RAISE EXCEPTION 'SO_CREATE_FX_INVALID|%', COALESCE(p_fx_rate::text, '?');
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'SO_CREATE_NO_LINES';
    END IF;

    v_code := next_sales_order_code(p_order_date);

    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate, notes, terms_text, created_by)
    VALUES (v_code, p_customer_id, p_order_date, p_currency, p_fx_rate,
            NULLIF(btrim(COALESCE(p_notes, '')), ''),
            NULLIF(btrim(COALESCE(p_terms_text, '')), ''), v_user)
    RETURNING id INTO v_id;

    -- 【逐行校验,并且【点名是第几行、哪一格】】一句"某一行不合法"等于让人
    -- 自己去数第几行 —— 表单上有二十个格子。
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_i := v_i + 1;
        IF NOT EXISTS (SELECT 1 FROM materials
                        WHERE id = NULLIF(v_line->>'material_id', '')::uuid AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SO_CREATE_LINE_INVALID|%|material', v_i;
        END IF;
        IF COALESCE((v_line->>'quantity')::numeric, 0) <= 0 THEN
            RAISE EXCEPTION 'SO_CREATE_LINE_INVALID|%|quantity', v_i;
        END IF;
        IF COALESCE((v_line->>'unit_price')::numeric, 0) <= 0 THEN
            RAISE EXCEPTION 'SO_CREATE_LINE_INVALID|%|unit_price', v_i;
        END IF;
        -- FIN-26 的配对:出处与依据要么都有、要么都没有。表侧的 CHECK 也管着,
        -- 但那条 CHECK 报的是约束名 —— 按名拒才说得出是第几行。
        IF (v_line ? 'price_source') <> (v_line ? 'price_provenance') THEN
            RAISE EXCEPTION 'SO_CREATE_LINE_INVALID|%|provenance', v_i;
        END IF;

        INSERT INTO sales_order_lines
            (sales_order_id, line_no, material_id, quantity, unit_price, price_source, price_provenance, notes)
        VALUES (v_id, v_i,
                (v_line->>'material_id')::uuid,
                (v_line->>'quantity')::numeric,
                (v_line->>'unit_price')::numeric,
                NULLIF(v_line->>'price_source', ''),
                CASE WHEN v_line ? 'price_provenance' THEN v_line->'price_provenance' END,
                NULLIF(btrim(COALESCE(v_line->>'notes', '')), ''));
    END LOOP;

    -- 【留痕与单据同一个事务】—— 这一行就是这整支迁移的起因。
    INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
    VALUES (v_id, 'created', v_code, v_user);

    -- 【断言,不是假设】三张表都写到了才算建成。将来有人给上面任何一段加一个
    -- 提前 RETURN,这里当场炸,而不是留下一张没有行、或者没有留痕的单。
    SELECT count(*) INTO v_n FROM sales_order_lines WHERE sales_order_id = v_id;
    IF v_n <> v_i OR v_i = 0 THEN
        RAISE EXCEPTION 'SO_CREATE_LINES_LOST|%|%', v_i, v_n;
    END IF;

    RETURN jsonb_build_object('id', v_id, 'code', v_code, 'lines', v_i);
END;
$function$;

-- ═══ 2 · 把侧门关上(这是那扇门的前提,不是一次顺手收紧)═════════════════════
DROP POLICY "sales_orders insert by permission" ON public.sales_orders;
DROP POLICY "sales_order_lines insert by permission" ON public.sales_order_lines;

-- ═══ 3 · 补记 SO-2026-0001 那一行 created ═══════════════════════════════════
-- 【补的是一件确实发生过的事,而且不用任何推断】日期与人都原样抄自单据自己的
-- created_at / created_by。detail 里写明它是补记 —— 一条不说自己是补记的补记,
-- 与伪造在读者眼里没有区别。
-- 【幂等】NOT EXISTS 兜着:这支迁移重放两遍不会写出两行。
-- 【为什么用 WHERE 而不是只对那一张单硬编码】判据是"确认过/签发过、却没有
-- created 留痕的单",而不是一个单号 —— 同一个缺陷若还漏了别的单,这里一并补上,
-- 而不是补一张漏一张。
INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_at, changed_by)
SELECT o.id, 'created',
       o.code || ' 【补记 · SO-2b 2026-08-14】建单时这一行被 RLS 拒(sales_order_history 没有客户端 INSERT 策略)'
              || '且错误被丢弃,从未写入。此处按单据自己的 created_at / created_by 补记 —— '
              || '补的是一件确实发生过的事,日期与人都不是推断出来的。',
       o.created_at, o.created_by
  FROM sales_orders o
 WHERE o.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM sales_order_history h
                    WHERE h.sales_order_id = o.id AND h.change_type = 'created');

COMMIT;
