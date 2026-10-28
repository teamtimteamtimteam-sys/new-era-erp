-- db/migrations/2026-10-28-chain-walk-cost.sql
-- CHAIN-WALK-COST(v1.4.80,Tim 2026-10-28 裁定 Q1–Q4 + 加的 inbound_batch_margin):单据链条与变更记录对【每一个角色】都便宜。
--   读数与等价证明:docs/surveys/CHAIN-WALK-COST/(Step 0 的病因;Step 1 的前后读数、逐行相同的比对)。
--   ① 每一条 public 策略里的权限判断与读者身份按【语句】求一次,不按行:has_permission(…) / has_any_permission(…) /
--      current_user_employee() / auth.uid() → (SELECT …)(560 条;镜像那一侧是 db/scripts/2026-10-28-chain-walk-cost-wrap-policies.py,
--      构建闸 scripts/check-policy-permission-wrap.mjs;随行的 12 条与 storage 的 53 条在 db/policy-permission-allowlist.tsv)。
--   ② 单据链条一跳一条集合查询:document_relation_arm_pairs(声明的边,一组)· document_chain_step_admitted(宿主步骤的判据,一组)·
--      document_detail_hrefs(地址,一组)成为唯一的实现,单张那几支改成它们的写法;document_chain_walk 整次只读一遍关联图。
--   ③ 变更记录:成员按外键自己的类型找、"之前"那一段只在排得进这一页时才拼、每一行的读规则与名字只为这一页画出来的行算;
--      trail_fk_targets / trail_current_image / trail_row_visible / trail_ref_label / change_log_field 走索引。
--   签名一支都没有变;两支新函数显式收回 PUBLIC / anon、授 authenticated(apply_migration.sh 还会回放 zzz_function_grants)。
--   没有表结构变化、没有数据变化。下面每一段函数逐字是它的镜像。
BEGIN;

-- ── ① 每一条策略里的权限判断按语句求一次值,不按行(Tim 2026-10-28 Q1)────────────────────────────────────
--   has_permission('x') → (SELECT has_permission('x'))(has_any_permission 同)。参数全是字面量(实测 754 处,0 处随行变),
--   于是包成标量子查询之后它是一个 InitPlan:同一条语句里求一次、每一行复用同一个值 —— 答案不变,只是不再每一行算一遍。
--   只动 public 的策略;storage 的策略不碰(LIVE SAFETY:portal-uploads / claim-receipts 两个桶的策略不许动)。
--   镜像那一侧是 db/scripts/2026-10-28-chain-walk-cost-wrap-policies.py 对 db/tables/*.sql 做的同一件事;gate 的镜像判词比两边的目录。
DO $wrap$
DECLARE
    p    record;
    q    text;
    w    text;
    n    integer := 0;
    v_id constant text := '(?<!SELECT )\m(current_user_employee\(\)|auth\.uid\(\))';
    v_re constant text := '(?<!SELECT )\m(has_(?:any_)?permission\((?:''(?:[^'']|'''')*''::text(?:\[\])?|ARRAY\[(?:[^\]''])*(?:''(?:[^'']|'''')*''(?:::text)?(?:, )?)*\](?:::text\[\])?)\))';
BEGIN
    FOR p IN SELECT * FROM pg_policies WHERE schemaname = 'public' ORDER BY tablename, policyname LOOP
        q := regexp_replace(regexp_replace(p.qual, v_re, '(SELECT \1)', 'g'), v_id, '(SELECT \1)', 'g');
        w := regexp_replace(regexp_replace(p.with_check, v_re, '(SELECT \1)', 'g'), v_id, '(SELECT \1)', 'g');
        CONTINUE WHEN q IS NOT DISTINCT FROM p.qual AND w IS NOT DISTINCT FROM p.with_check;
        EXECUTE format('ALTER POLICY %I ON public.%I%s%s', p.policyname, p.tablename,
                       CASE WHEN p.qual IS NOT NULL THEN format(' USING (%s)', q) ELSE '' END,
                       CASE WHEN p.with_check IS NOT NULL THEN format(' WITH CHECK (%s)', w) ELSE '' END);
        n := n + 1;
    END LOOP;
    IF n <> 560 THEN
        RAISE EXCEPTION 'CHAIN_WALK_COST_WRAP|改了 % 条策略,应当恰好 560 条(541 条有权限判断 + 19 条只有身份判断;2026-10-28 本地重建)—— 先查清差在哪里', n;
    END IF;
    -- 改完之后,public 的策略里一处不带 SELECT 的权限判断都不许剩
    SELECT count(*) INTO n FROM pg_policies pp,
           regexp_matches(coalesce(pp.qual, '') || ' ' || coalesce(pp.with_check, ''), '(\(\s*SELECT\s+)?\m(has_(any_)?permission\(|current_user_employee\(\)|auth\.uid\(\))', 'g') m
     WHERE pp.schemaname = 'public' AND m[1] IS NULL;
    IF n <> 0 THEN
        RAISE EXCEPTION 'CHAIN_WALK_COST_WRAP|改完之后仍有 % 处权限 / 身份判断没有包成 (SELECT …)', n;
    END IF;
END
$wrap$;

-- ── db/functions/document_relation_arm_pairs.sql ──
-- db/functions/document_relation_arm_pairs.sql
-- CHAIN-WALK-COST(v1.4.80,Tim 2026-10-28):一条【声明的】关联(document_relation_arms 的一行)从【一组】单据走到哪几张 —— 每一行带着它从哪一张来(src)。
--   document_relation_arm_ids(arm, id) 现在只是它的单张写法(ARRAY[id]);十条路只写在这里一份。
--   单据链条一跳交一整圈的来源单据进来(document_chain_walk):以前每一张来源各调一次,而读者身份下(INVOKER、RLS)这些路上的判断
--   用不上索引(行级安全不让非 leakproof 的条件当索引条件),于是一年体量的一张月结对账单从 200 笔付款各扫一遍全部付款申请。现在一圈扫一遍。
--
-- ★ INVOKER,与 document_relation_arm_ids / search_related() 同一条理由:「你看得见哪几张」由 RLS 自己回答。这里一条权限判据都不写。
-- ★ 认不出的 arm 名【响】(RAISE),不是空集 —— 一个拼错的名字与一张真的没有关联的单据,在屏幕上分不开。
-- ★ 每一支只读它那一条路上的表;日期与状态的判据写在 document_relation_arms 那一行的 reason 里,两边说同一句话。
--
-- NOTE: introduced by db/migrations/2026-10-28-chain-walk-cost.sql.

CREATE OR REPLACE FUNCTION public.document_relation_arm_pairs(p_arm text, p_ids uuid[])
 RETURNS TABLE(src uuid, id uuid)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    IF p_arm = 'payment_request_to_inbound_batch' THEN
        RETURN QUERY
        SELECT DISTINCT r.id, (a->>'inbound_batch_id')::uuid
          FROM public.payment_requests r
          CROSS JOIN LATERAL jsonb_array_elements(r.allocations) a
         WHERE r.id = ANY (p_ids) AND COALESCE(a->>'inbound_batch_id', '') <> '';
    ELSIF p_arm = 'inbound_batch_to_payment_request' THEN
        RETURN QUERY
        SELECT DISTINCT s.id, r.id
          FROM public.payment_requests r
          CROSS JOIN LATERAL jsonb_array_elements(r.allocations) a
          JOIN unnest(p_ids) AS s(id) ON a->>'inbound_batch_id' = s.id::text;
    ELSIF p_arm = 'payment_to_bank_statement' THEN
        RETURN QUERY
        SELECT DISTINCT p.id, bl.statement_id
          FROM public.payments p
          JOIN public.journal_lines jl ON jl.entry_id = p.journal_entry_id
          JOIN public.bank_line_matches m ON m.journal_line_id = jl.id
          JOIN public.bank_statement_lines bl ON bl.id = m.statement_line_id
         WHERE p.id = ANY (p_ids);
    ELSIF p_arm = 'bank_statement_to_payment' THEN
        RETURN QUERY
        SELECT DISTINCT bl.statement_id, p.id
          FROM public.bank_statement_lines bl
          JOIN public.bank_line_matches m ON m.statement_line_id = bl.id
          JOIN public.journal_lines jl ON jl.id = m.journal_line_id
          JOIN public.payments p ON p.journal_entry_id = jl.entry_id
         WHERE bl.statement_id = ANY (p_ids);
    ELSIF p_arm = 'attendance_period_to_payroll_period' THEN
        RETURN QUERY
        SELECT ap.id, pp.id
          FROM public.attendance_periods ap
          JOIN public.payroll_periods pp ON pp.period_month = ap.period_month AND pp.deleted_at IS NULL
         WHERE ap.id = ANY (p_ids);
    ELSIF p_arm = 'payroll_period_to_attendance_period' THEN
        RETURN QUERY
        SELECT pp.id, ap.id
          FROM public.payroll_periods pp
          JOIN public.attendance_periods ap ON ap.period_month = pp.period_month
         WHERE pp.id = ANY (p_ids);
    ELSIF p_arm = 'overtime_batch_to_payroll_period' THEN
        RETURN QUERY
        SELECT ob.id, pp.id
          FROM public.overtime_batches ob
          JOIN public.payroll_periods pp ON pp.period_month = ob.period_month AND pp.deleted_at IS NULL
         WHERE ob.id = ANY (p_ids) AND ob.status = 'approved';
    ELSIF p_arm = 'payroll_period_to_overtime_batch' THEN
        RETURN QUERY
        SELECT pp.id, ob.id
          FROM public.payroll_periods pp
          JOIN public.overtime_batches ob ON ob.period_month = pp.period_month AND ob.status = 'approved'
         WHERE pp.id = ANY (p_ids);
    ELSIF p_arm = 'leave_request_to_payroll_period' THEN
        RETURN QUERY
        SELECT lr.id, pp.id
          FROM public.leave_requests lr
          JOIN public.payroll_periods pp
            ON pp.period_month BETWEEN date_trunc('month', lr.start_date)::date
                                   AND date_trunc('month', lr.end_date)::date
           AND pp.deleted_at IS NULL
         WHERE lr.id = ANY (p_ids) AND lr.status = 'approved' AND lr.deleted_at IS NULL;
    ELSIF p_arm = 'payroll_period_to_leave_request' THEN
        RETURN QUERY
        SELECT pp.id, lr.id
          FROM public.payroll_periods pp
          JOIN public.leave_requests lr
            ON pp.period_month BETWEEN date_trunc('month', lr.start_date)::date
                                   AND date_trunc('month', lr.end_date)::date
           AND lr.status = 'approved' AND lr.deleted_at IS NULL
         WHERE pp.id = ANY (p_ids);
    ELSE
        RAISE EXCEPTION 'DOCUMENT_RELATION_UNKNOWN_ARM|% —— 它不在 document_relation_arms 里,'
                        '而一个拼错的名字与一张真的没有关联的单据在屏幕上分不开', coalesce(p_arm, '(null)');
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.document_relation_arm_pairs(text, uuid[]) IS
    'CHAIN-WALK-COST:一条声明的关联(document_relation_arms)从一组单据走到哪几张,每一行带着来源(src)。INVOKER —— RLS 回答你看得见哪几张;'
    '认不出的 arm 名按名拒(DOCUMENT_RELATION_UNKNOWN_ARM)。document_relation_arm_ids 是它的单张写法。';
REVOKE ALL ON FUNCTION public.document_relation_arm_pairs(text, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.document_relation_arm_pairs(text, uuid[]) TO authenticated, service_role;

-- ── db/functions/document_relation_arm_ids.sql ──
-- db/functions/document_relation_arm_ids.sql
-- SYSTEM-MAP-3(Tim 2026-10-27):一条【声明的】关联(document_relation_arms 的一行)从一张单据走到哪几张。
--   search_related() / search_related_rows() 的 'arm' 分支调它;document_chain_walk() 经 search_related_rows() 间接调它。
--
-- ★ INVOKER,与那两支同一条理由:「你看得见哪几张」由 RLS 自己回答。这里一条权限判据都不写。
-- ★ 认不出的 arm 名【响】(RAISE),不是空集 —— 一个拼错的名字与一张真的没有关联的单据,在屏幕上分不开。
-- ★ 每一支只读它那一条路上的表;日期与状态的判据写在 document_relation_arms 那一行的 reason 里,两边说同一句话。
--
-- ★ CHAIN-WALK-COST(v1.4.80):十条路只写在 document_relation_arm_pairs(arm, ids[]) 里一份;这一支是它的单张写法。
--   单据链条一跳交一整圈来源进那一支,关联页(search_related / search_related_rows)照旧一张一张经这一支问 —— 两边同一份定义。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.document_relation_arm_ids(p_arm text, p_id uuid)
 RETURNS TABLE(id uuid)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    RETURN QUERY SELECT p.id FROM public.document_relation_arm_pairs(p_arm, ARRAY[p_id]) p;
END;
$function$;

COMMENT ON FUNCTION public.document_relation_arm_ids(text, uuid) IS
    'SYSTEM-MAP-3:一条声明的关联(document_relation_arms)从一张单据走到哪几张。INVOKER —— RLS 回答你看得见哪几张;'
    '认不出的 arm 名按名拒(DOCUMENT_RELATION_UNKNOWN_ARM)。';

-- ── db/functions/document_chain_step_admitted.sql ──
-- db/functions/document_chain_step_admitted.sql
-- CHAIN-WALK-COST(v1.4.80,Tim 2026-10-28):document_chain_step_admits 的【一组】写法 —— 这几张宿主单据里,哪几张上这一步存在。
--   四个判据只写在这里一份;document_chain_step_admits(filter, id) 现在是它的单张写法。单据链条一跳拿一整组候选进来问一次:
--   以前每一张候选各问一次(一年体量的一张月结对账单,200 批货各一句,连同各自那一次读规则判断约 80 ms)。
--     payable          一批货有没有应付 —— 它的计价分录在不在(journal_entries.source_type = 'purchase', source_id = 这一批);
--     reservation      一张销售订单有没有预留(sales_order_reservations 经 sales_order_lines);
--     cost_allocation  一次加工有没有成本分摊行(batch_processing_cost_allocations.run_id);
--     payroll_payment  一张分录是不是付薪分录(工资行的 paid_journal_entry_id,或期间的公积金 / 扣款付款分录)。
-- ★ NULL 的判据 = 这一步没有判据 → 全部都算。认不出的判据名【响】。
-- ★ INVOKER:读者读不到那张表 → 一张都不算(那一步对他就是"找不到";单据链条上那一步本来就按权限画「受限」)。
--
-- NOTE: introduced by db/migrations/2026-10-28-chain-walk-cost.sql.

CREATE OR REPLACE FUNCTION public.document_chain_step_admitted(p_filter text, p_ids uuid[])
 RETURNS TABLE(id uuid)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    IF p_filter IS NOT NULL AND p_filter NOT IN ('payable', 'reservation', 'cost_allocation', 'payroll_payment') THEN
        RAISE EXCEPTION 'DOCUMENT_CHAIN_UNKNOWN_FILTER|% —— 单据链条认得的判据只有 payable · reservation · '
                        'cost_allocation · payroll_payment', p_filter;
    END IF;
    IF p_filter IS NULL THEN
        RETURN QUERY SELECT DISTINCT x FROM unnest(p_ids) x WHERE x IS NOT NULL;
    ELSIF p_filter = 'payable' THEN
        RETURN QUERY SELECT DISTINCT e.source_id FROM public.journal_entries e
                      WHERE e.source_type = 'purchase' AND e.source_id = ANY (p_ids);
    ELSIF p_filter = 'reservation' THEN
        RETURN QUERY SELECT DISTINCT l.sales_order_id FROM public.sales_order_reservations r
                       JOIN public.sales_order_lines l ON l.id = r.sales_order_line_id
                      WHERE l.sales_order_id = ANY (p_ids);
    ELSIF p_filter = 'cost_allocation' THEN
        RETURN QUERY SELECT DISTINCT a.run_id FROM public.batch_processing_cost_allocations a WHERE a.run_id = ANY (p_ids);
    ELSE
        RETURN QUERY SELECT pl.paid_journal_entry_id FROM public.payroll_lines pl WHERE pl.paid_journal_entry_id = ANY (p_ids)
                     UNION
                     SELECT x FROM public.payroll_periods pp, unnest(ARRAY[pp.cpf_journal_entry_id, pp.deductions_journal_entry_id]) x
                      WHERE x = ANY (p_ids);
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.document_chain_step_admitted(text, uuid[]) IS
    'CHAIN-WALK-COST:一组宿主单据里,单据链条上住在宿主里的那一步(payable · reservation · cost_allocation · payroll_payment;NULL = 没有判据)'
    '在哪几张上存在。INVOKER。document_chain_step_admits 是它的单张写法。';
REVOKE ALL ON FUNCTION public.document_chain_step_admitted(text, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.document_chain_step_admitted(text, uuid[]) TO authenticated, service_role;

-- ── db/functions/document_chain_step_admits.sql ──
-- db/functions/document_chain_step_admits.sql
-- SYSTEM-MAP-3(Tim 2026-10-27,grilling 第 7 条):单据链条上【没有自己页面的那几步】住在别的单据里 ——
--   这一支答「这张宿主单据上,这一步存在吗」:
--     payable          一批货有没有应付 —— 它的计价分录在不在(journal_entries.source_type = 'purchase', source_id = 这一批);
--     reservation      一张销售订单有没有预留(sales_order_reservations 经 sales_order_lines);
--     cost_allocation  一次加工有没有成本分摊行(batch_processing_cost_allocations.run_id);
--     payroll_payment  一张分录是不是付薪分录(工资行的 paid_journal_entry_id,或期间的公积金 / 扣款付款分录 ——
--                      与 payroll_payment_entry_kind() 同一组判据;那一支收回了 authenticated 的 EXECUTE,所以这里照它写一份
--                      只答"是不是"的读法,按读者自己的身份读)。
--   定价(pricing)不需要判据:每一批货的页面上都有定价那一块。
-- ★ NULL 的判据 = 这一步没有判据 → true。认不出的判据名【响】。p_id 为 NULL 时只校验名字(document_chain_walk 开头用它)。
-- ★ INVOKER:读者读不到那张表 → false(那一步对他就是"找不到";单据链条上那一步本来就按权限画「受限」)。
--
-- ★ CHAIN-WALK-COST(v1.4.80):四个判据只写在 document_chain_step_admitted(filter, ids[]) 里一份;这一支是它的单张写法。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.document_chain_step_admits(p_filter text, p_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    IF p_filter IS NULL THEN
        RETURN true;
    END IF;
    IF p_id IS NULL THEN
        -- 只校验名字(document_chain_walk 开头用它):认不出的判据名照样响
        PERFORM * FROM public.document_chain_step_admitted(p_filter, '{}'::uuid[]);
        RETURN true;
    END IF;
    RETURN EXISTS (SELECT 1 FROM public.document_chain_step_admitted(p_filter, ARRAY[p_id]));
END;
$function$;

COMMENT ON FUNCTION public.document_chain_step_admits(text, uuid) IS
    'SYSTEM-MAP-3:单据链条上一个住在宿主单据里的步骤,在这张宿主单据上存不存在(payable · reservation · '
    'cost_allocation · payroll_payment;NULL = 没有判据)。INVOKER。';

-- ── db/functions/document_detail_hrefs.sql ──
-- db/functions/document_detail_hrefs.sql
-- SYSTEM-MAP-3:document_detail_href() 的一屏版 —— 关联页的表格一次画 20 行,一次往返要齐它们的地址。
-- ★ CHAIN-WALK-COST(v1.4.80):实现搬到这里 —— 地址模板里的占位(化验单的 {inbound_batch_id})对一组 id 只查一次表,
--   document_detail_href(key, id) 是它的单张写法(以前反过来:这一支逐个调那一支,一张月结对账单的链条 200 张化验单各查一次)。
--   结果与以前逐行相同:每一个输入 id 一行、按输入的顺序;占位读不到(那一行看不见、或那一列为空)→ 地址为 NULL。INVOKER。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.document_detail_hrefs(p_key text, p_ids uuid[])
 RETURNS TABLE(id uuid, href text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    d     record;
    v_expr text;
    m     text[];
BEGIN
    SELECT dt.key, dt.table_name, dt.route, dt.link_mode, dt.detail_route INTO d
      FROM public.document_types dt WHERE dt.key = p_key;
    IF d.key IS NULL THEN
        RAISE EXCEPTION 'SEARCH_UNKNOWN_DOCUMENT_TYPE|% —— 它不在 document_types 里', coalesce(p_key, '(null)');
    END IF;
    IF d.detail_route IS NOT NULL THEN
        v_expr := quote_literal(d.detail_route);
        FOR m IN SELECT regexp_matches(d.detail_route, '\{([a-z_]+)\}', 'g') LOOP
            v_expr := format('replace(%s, %L, %s)', v_expr, '{' || m[1] || '}',
                             CASE WHEN m[1] = 'id' THEN 'x.id::text' ELSE format('t.%I::text', m[1]) END);
        END LOOP;
        RETURN QUERY EXECUTE format(
            'SELECT x.id, CASE WHEN x.id IS NULL THEN NULL ELSE %s END'
            '  FROM unnest($1) WITH ORDINALITY AS x(id, n) LEFT JOIN public.%I t ON t.id = x.id ORDER BY x.n',
            v_expr, d.table_name) USING p_ids;
        RETURN;
    END IF;
    RETURN QUERY
    SELECT x.id, CASE WHEN x.id IS NOT NULL AND d.link_mode = 'detail' THEN d.route || '/' || x.id::text END
      FROM unnest(p_ids) WITH ORDINALITY AS x(id, n) ORDER BY x.n;
END;
$function$;

-- ── db/functions/document_detail_href.sql ──
-- db/functions/document_detail_href.sql
-- SYSTEM-MAP-3(Tim 2026-10-27,grilling 第 3 条):一张单据【自己那一页】的地址 —— 一份实现。
--   documentHref()(lib/search/documentHref.ts)答的是「搜索命中点开去哪」:进料批 / 产出批落在带 ?q= 的列表、
--   贷项通知单落在列表、化验单落在一种单据的全表列表。单据链条与关联页的表格要的是【那一张单据的页面】,
--   而那几种的页面地址不是 <route>/<id>:/inbound/<id>/edit · /output/<id>/edit · /finance/credit-notes/<id> ·
--   /inbound/<inbound_batch_id>/assays/<id>。
-- 判据:document_types.detail_route 有值 → 按它填(`{id}` 是这张单据的 id,`{<列>}` 是这一行那一列的值);
--   没有值而 link_mode = 'detail' → <route>/<id>;否则 NULL(这种单据没有逐张的页面)。
--   填不出来(一个占位列在这一行上是 NULL —— 例如一张产出批的化验单没有 inbound_batch_id)→ NULL,不猜。
-- ★ INVOKER:占位列按读者自己的身份读;读不到那一行 → NULL。
-- ★ 读者:document_chain_walk()(单据链条)· document_detail_hrefs()(关联页的表格,一次一屏)。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.
-- ★ CHAIN-WALK-COST(v1.4.80):实现在 document_detail_hrefs(key, ids[]) 里一份;这一支是它的单张写法。

CREATE OR REPLACE FUNCTION public.document_detail_href(p_key text, p_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v text;
BEGIN
    SELECT h.href INTO v FROM public.document_detail_hrefs(p_key, ARRAY[p_id]) h;
    RETURN v;
END;
$function$;

COMMENT ON FUNCTION public.document_detail_href(text, uuid) IS
    'SYSTEM-MAP-3:一张单据自己那一页的地址(detail_route 按占位填 / detail → <route>/<id> / 否则 NULL)。INVOKER。';

-- ── db/functions/document_chain_walk.sql ──
-- db/functions/document_chain_walk.sql
-- SYSTEM-MAP-3(Tim 2026-10-26 裁定 2.4 (12) · 2026-10-27 SYSTEM-MAP-3 裁定):单据详情页上那条上下游链条的【取数】。
--
-- 【入参】p_chain = 一条链的定义,由 lib/chains.ts 原样传进来(那是步骤顺序与名字的唯一出处;
--   fixture 296 里抄着的四份由 scripts/check-chain-bar.mjs 逐字核对):
--     { "steps": [ { "keys": ["<document_types.key>", …], "filter": null | "<document_chain_step_admits 的判据名>" }, … ],
--       "edges": [ [a, b], … ] }          -- 链上【走得通】的步骤对(无向)
--   p_step / p_key / p_id = 读者此刻站在哪一步、哪一种单据、哪一张。
-- 【出参】这条链上每一步找得到的单据:(步骤, 种类, id, 单据号, 标签, 那一页的地址)。当前这一张也在里面。
--
-- ★★【怎么走 —— 从读者站的那一步往外,一圈一圈】★★
--   步骤图上按距离排序(BFS);一步的单据 = 它【不比它离读者更远的那些相邻步骤】上已经找到的单据,经关联图
--   (search_related_rows —— 外键推出来的边 + document_relation_arms 声明的边,与关联页同一份定义)走一跳。
--   ☞ 只往外走、不往回走:从一批货走到加工,再从加工走回"别的货",那是另一条链。
--   ☞ 同一种单据在两步上(进料批 → 定价 → 应付,三步都是这一批):那一跳是【它自己】,不经关联图
--     (关联图上的自指边是作废 / 冲销链,不是"同一张")。
--   ☞ 一步带判据(应付 · 预留 · 成本分摊 · 付薪)= 宿主单据里这一步存在的那几张才算(document_chain_step_admits)。
--     读者站的那一张若不满足它所在那一步的判据(一张不是付薪分录的分录)→ 一行都不返回:这条链不属于这一页。
-- ★ INVOKER:每一跳由 RLS 回答「你看得见哪几张」。读者走不过去的那一步(没有模块闸)在这里就是"找不到" ——
--   而【页面】按权限把那一步画成「受限」,并把只能经过它才到得了的那几步画成「受限 · 只经过 X 才到得了」
--   (Tim Q5:读者打不开的那一步永远是「受限」,不论有没有单据)。所以这里的"没找到"永远不会被画成"还没有"。
-- ★ 每一跳最多 100 行(search_related_rows 的上限);页面一步只画 3 个链接 + "另外 N 个"。
--
-- ★★【CHAIN-WALK-COST(v1.4.80,Tim 2026-10-28)—— 一跳是【一条】集合查询,不是"每一张来源单据各问一次"】★★
--   以前:每一张找到的单据 × 每一种目标单据各调一次 search_related_rows() —— 而那一支每调一次都从 pg_catalog 重新推一遍关联图
--   (约 3.5 ms、9,325 个缓冲区),再造一句动态 SQL、再规划一次。一年体量上,销售那一条 616–681 ms。
--   现在:同一个(目标步骤, 来源种类, 目标种类)整次只问一遍 —— 那一圈里这一种的【全部】来源单据一起交进去(= ANY($1)),
--   边→SQL 的翻译每一对表整次只做一次(v_edge_sql)。翻译与 search_related_rows() 逐字同一份语义:同一张 document_relations、
--   同一条前缀过滤、同一条自指排除、同一个"每一张来源、每一种目标最多 100 行,按单据号倒序"。
--   等价是量出来的:以前那一支与这一支对一份线上数据的拷贝、每一张单据 × 七个角色逐行相同(1,939 / 1,939),
--   对一年体量的种子同样逐行相同(docs/surveys/CHAIN-WALK-COST/readings/)。
--   ☞ 读者看得见哪几张,照旧由 RLS 回答(INVOKER);策略里的权限判断同一刀包成了 (SELECT has_permission(…)),按语句求一次。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.document_chain_walk(p_chain jsonb, p_step integer, p_key text, p_id uuid)
 RETURNS TABLE(step integer, key text, id uuid, code text, label text, href text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_steps  jsonb := p_chain->'steps';
    v_edges  jsonb := p_chain->'edges';
    n        integer;
    dist     integer[];
    v_done   boolean;
    j        integer;
    e        jsonb;
    a        integer;
    b        integer;
    t        text;
    d        record;
    r        record;
    v_code   text;
    v_label  text;
    v_src    integer[];
    f_step   integer[];
    f_key    text[];
    f_id     uuid[];
    f_code   text[];
    f_label  text[];
    v_pass   integer;
    v_added  integer;
    v_live   text[];
    v_has    boolean;
    sk       text;
    v_ids    uuid[];
    v_sql    text;
    v_edge   jsonb := '{}';
    v_filter text;
    ef       text;
    et       record;
    er       record;
    v_parts  text[];
    v_sel    text;
    v_where  text;
    v_rels   jsonb;
    v_nestloop text;
    v_ok     uuid[];
    v_hid    uuid[];
    v_hcode  text[];
    v_hlabel text[];
    i        integer;
    v_seen   jsonb := '{}';
    v_askedj jsonb := '{}';
    v_t0     timestamptz := clock_timestamp();
    v_budget interval;
BEGIN
    -- ── 定义本身先验:一份坏的定义【响】,不是一条空链 ────────────────────────
    IF jsonb_typeof(v_steps) IS DISTINCT FROM 'array' OR jsonb_typeof(v_edges) IS DISTINCT FROM 'array'
       OR jsonb_array_length(v_steps) = 0 THEN
        RAISE EXCEPTION 'DOCUMENT_CHAIN_BAD_DEFINITION|steps 与 edges 必须是非空数组';
    END IF;
    n := jsonb_array_length(v_steps);
    IF p_step IS NULL OR p_step < 0 OR p_step >= n THEN
        RAISE EXCEPTION 'DOCUMENT_CHAIN_BAD_DEFINITION|步骤 % 不在 0..%', coalesce(p_step::text, '(null)'), n - 1;
    END IF;
    FOR j IN 0 .. n - 1 LOOP
        IF jsonb_typeof(v_steps->j->'keys') IS DISTINCT FROM 'array' OR jsonb_array_length(v_steps->j->'keys') = 0 THEN
            RAISE EXCEPTION 'DOCUMENT_CHAIN_BAD_DEFINITION|步骤 % 没有单据种类', j;
        END IF;
        FOR t IN SELECT jsonb_array_elements_text(v_steps->j->'keys') LOOP
            IF NOT EXISTS (SELECT 1 FROM public.document_types dt WHERE dt.key = t) THEN
                RAISE EXCEPTION 'SEARCH_UNKNOWN_DOCUMENT_TYPE|% —— 它不在 document_types 里', t;
            END IF;
        END LOOP;
        PERFORM public.document_chain_step_admits(v_steps->j->>'filter', NULL);
    END LOOP;
    FOR e IN SELECT jsonb_array_elements(v_edges) LOOP
        a := (e->>0)::integer;
        b := (e->>1)::integer;
        IF a IS NULL OR b IS NULL OR a < 0 OR b < 0 OR a >= n OR b >= n OR a = b THEN
            RAISE EXCEPTION 'DOCUMENT_CHAIN_BAD_DEFINITION|边 % 不是两个不同的步骤', e::text;
        END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_steps->p_step->'keys') x WHERE x = p_key) THEN
        RAISE EXCEPTION 'DOCUMENT_CHAIN_KEY_NOT_IN_STEP|% 不在步骤 % 里', coalesce(p_key, '(null)'), p_step;
    END IF;

    -- ── 时间上限(SYSTEM-MAP-3 -fu2,Tim 2026-10-27 23:45 裁定 1)────────────────────────────────
    --   一次走链最多占库 2 秒,到点按名拒(DOCUMENT_CHAIN_WALK_BUDGET)—— 页面上那一格写「这一次没有画出来」,页面其余不受影响。
    --   ★ 为什么不是 `ALTER FUNCTION … SET statement_timeout = '2s'`(裁定的原话):实测【它不管用】——
    --     statement_timeout 的计时器只在【顶层语句】开始时上弦;函数级的 SET 改的是一个这一句已经不再读的值
    --     (本地实测:一支 SET statement_timeout TO '1s' 的函数 pg_sleep(3),3000 ms 跑完、没有被取消)。
    --     所以上限由这一支自己守:每一次关联查询之前看一眼钟。一次关联查询本身是毫秒到几十毫秒,于是越线最多一跳。
    --   上限可由 app.chain_walk_budget_ms 收紧(fixture 296 的 T 臂设成 0 证它真的会拒);不设就是 2000。
    v_budget := make_interval(secs => coalesce(nullif(current_setting('app.chain_walk_budget_ms', true), '')::numeric, 2000) / 1000.0);

    -- ── 读者站的那一张(读不到 → 一行都不返回)────────────────────────────────
    SELECT dt.table_name, dt.label_column INTO d FROM public.document_types dt WHERE dt.key = p_key;
    EXECUTE format('SELECT t.code::text, %s FROM public.%I t WHERE t.id = $1',
                   CASE WHEN d.label_column IS NULL THEN 'NULL::text' ELSE format('t.%I::text', d.label_column) END,
                   d.table_name)
       INTO v_code, v_label USING p_id;
    IF v_code IS NULL OR NOT public.document_chain_step_admits(v_steps->p_step->>'filter', p_id) THEN
        RETURN;
    END IF;
    f_step := ARRAY[p_step];
    f_key := ARRAY[p_key];
    f_id := ARRAY[p_id];
    f_code := ARRAY[v_code];
    f_label := ARRAY[v_label];

    -- ── 步骤图上的距离(BFS)──────────────────────────────────────────────────
    dist := array_fill(-1, ARRAY[n]);
    dist[p_step + 1] := 0;
    LOOP
        v_done := true;
        FOR e IN SELECT jsonb_array_elements(v_edges) LOOP
            a := (e->>0)::integer;
            b := (e->>1)::integer;
            IF dist[a + 1] >= 0 AND dist[b + 1] < 0 THEN
                dist[b + 1] := dist[a + 1] + 1;
                v_done := false;
            ELSIF dist[b + 1] >= 0 AND dist[a + 1] < 0 THEN
                dist[a + 1] := dist[b + 1] + 1;
                v_done := false;
            END IF;
        END LOOP;
        EXIT WHEN v_done;
    END LOOP;

    -- ── 哪几种单据此刻有行(只为一张表挂着好几种单据的那几种问:产出批 13 个前缀、付款两个)───────────
    --   一种一行都看不见的单据,问它的关联是白问 —— 而产出批那一步每一张来源单据都要问 13 遍(线上今天只有 OUT 一种有行)。
    --   按读者自己的身份问(INVOKER):他看不见的那一种,本来就一张都找不到。
    v_live := '{}';
    FOR t IN SELECT DISTINCT x FROM jsonb_array_elements(v_steps) st, jsonb_array_elements_text(st->'keys') x LOOP
        SELECT dt.table_name, dt.prefix,
               (SELECT count(*) > 1 FROM public.document_types d2 WHERE d2.table_name = dt.table_name) AS shared
          INTO d FROM public.document_types dt WHERE dt.key = t;
        IF NOT d.shared THEN
            v_live := v_live || t;
        ELSE
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I x WHERE x.code LIKE %L)', d.table_name, d.prefix || '-%')
               INTO v_has;
            IF v_has THEN v_live := v_live || t; END IF;
        END IF;
    END LOOP;

    -- ── 关联图:这条链上几种单据之间的边,整次只读一遍 ─────────────────────────────────────
    --   document_relations 是一张从 pg_catalog 推出来的视图(Q14:它就是线上,不是一份副本)。它的桥边那一支是外键对外键的自连接,
    --   而 CTE 的行数估计是 1,于是规划器选了嵌套循环(本地一年种子上 30 万次比较、整次约 47 ms);只在这一句上关掉嵌套循环
    --   (散列连接约 12 ms),读完立刻还原成原来的值 —— 这一支别的查询照旧。边的集合与视图逐行相同(它读的就是那张视图)。
    v_nestloop := current_setting('enable_nestloop');
    PERFORM set_config('enable_nestloop', 'off', true);
    SELECT coalesce(jsonb_agg(to_jsonb(dr)), '[]') INTO v_rels
      FROM public.document_relations dr
     WHERE dr.from_table IN (SELECT dt.table_name FROM public.document_types dt WHERE dt.key = ANY (v_live))
       AND dr.to_table IN (SELECT dt.table_name FROM public.document_types dt WHERE dt.key = ANY (v_live));
    PERFORM set_config('enable_nestloop', v_nestloop, true);
    -- 已经在哪一步上的单据(键 = 步骤|id)—— 一个键集,不是每加一行就把整个数组再扫一遍
    SELECT coalesce(jsonb_object_agg(u.st || '|' || u.i, true), '{}') INTO v_seen FROM unnest(f_step, f_id) AS u(st, i);

    -- ── 一圈一圈往外走,直到不再长 ─────────────────────────────────────────────
    --   一步的来源 = 它的相邻步骤里【不比它离读者更远】的那些(同一圈的也算:销售那一条的"预留"与"发货"同在第一圈,
    --   发货要从预留那一侧也找得到)。一圈之内谁先谁后不决定答案:整张图再走一遍,直到这一遍一行都没有加。
    --   上限 n + 1 遍(每一遍至少加一行才会有下一遍,而步骤只有 n 个、行有限)。
    --   ★ CHAIN-WALK-COST:一跳 = 一条集合查询 —— (目标步骤 j, 来源种类 sk, 目标种类 t) 这一组里【还没问过的】全部来源单据一起交进去;
    --     每一张来源单据对每一组整次只问一遍(v_askedj,与 -fu1 同一条:不记的话后一遍把前一遍全部重问一次);
    --     "已经问过"与"已经在这一步上"都是键集(jsonb 的 ?),不是每加一行就重扫一遍的数组 —— 一张月结对账单走出一千多行时,那两次重扫是平方级的。
    FOR v_pass IN 1 .. n + 1 LOOP
        v_added := 0;
        FOR j IN SELECT g.i - 1 FROM generate_subscripts(dist, 1) AS g(i)
                  WHERE dist[g.i] > 0 ORDER BY dist[g.i], g.i LOOP
            v_filter := v_steps->j->>'filter';
            SELECT coalesce(array_agg(DISTINCT x.s), '{}') INTO v_src
              FROM (SELECT CASE WHEN (ed->>0)::integer = j THEN (ed->>1)::integer ELSE (ed->>0)::integer END AS s
                      FROM jsonb_array_elements(v_edges) ed
                     WHERE (ed->>0)::integer = j OR (ed->>1)::integer = j) x
             WHERE dist[x.s + 1] >= 0 AND dist[x.s + 1] <= dist[j + 1];

            FOR t IN SELECT jsonb_array_elements_text(v_steps->j->'keys') LOOP
                CONTINUE WHEN NOT (t = ANY (v_live));
                FOR sk IN SELECT DISTINCT u.k FROM unnest(f_step, f_key) AS u(s, k) WHERE u.s = ANY (v_src) LOOP
                    SELECT array_agg(DISTINCT u.i) INTO v_ids
                      FROM unnest(f_step, f_key, f_id) AS u(s, k, i)
                     WHERE u.s = ANY (v_src) AND u.k = sk
                       AND NOT v_askedj ? (j::text || '|' || sk || '|' || u.i::text || '|' || t);
                    CONTINUE WHEN v_ids IS NULL;
                    IF clock_timestamp() - v_t0 > v_budget THEN
                        RAISE EXCEPTION 'DOCUMENT_CHAIN_WALK_BUDGET|走了 % 毫秒,上限 % 毫秒 —— 这一条链这一次没有画完',
                            round(extract(epoch FROM clock_timestamp() - v_t0) * 1000), round(extract(epoch FROM v_budget) * 1000);
                    END IF;
                    v_askedj := v_askedj || (SELECT jsonb_object_agg(j::text || '|' || sk || '|' || x::text || '|' || t, true) FROM unnest(v_ids) x);

                    -- 同一种单据在两步上 = 它自己(不经关联图)
                    IF sk = t THEN
                        -- 判据整组问一次(document_chain_step_admitted),不是每一张各问一次
                        v_ok := ARRAY(SELECT a.id FROM public.document_chain_step_admitted(v_filter, v_ids) a);
                        FOR r IN SELECT DISTINCT ON (u.i) u.i AS id, u.c AS code, u.l AS label
                                   FROM unnest(f_key, f_id, f_code, f_label) AS u(k, i, c, l)
                                  WHERE u.k = sk AND u.i = ANY (v_ids) AND u.i = ANY (v_ok) LOOP
                            CONTINUE WHEN v_seen ? (j || '|' || r.id);
                            f_step := f_step || j; f_key := f_key || t; f_id := f_id || r.id; v_seen := v_seen || jsonb_build_object(j || '|' || r.id, true);
                            f_code := f_code || r.code; f_label := f_label || r.label;
                            v_added := v_added + 1;
                        END LOOP;
                        CONTINUE;
                    END IF;

                    -- 否则经关联图走一跳:这一对表的边→SQL 整次只翻译一次(与 search_related_rows() 同一份语义)
                    IF NOT v_edge ? (sk || '>' || t) THEN
                        SELECT dt.table_name INTO ef FROM public.document_types dt WHERE dt.key = sk;
                        SELECT dt.table_name, dt.prefix, dt.label_column,
                               (SELECT count(*) > 1 FROM public.document_types d2 WHERE d2.table_name = dt.table_name) AS shared
                          INTO et FROM public.document_types dt WHERE dt.key = t;
                        v_sel := CASE WHEN et.label_column IS NULL THEN 'NULL::text' ELSE format('t.%I::text', et.label_column) END;
                        v_parts := '{}';
                        FOR er IN SELECT x.* FROM jsonb_to_recordset(v_rels) AS x(from_table text, from_column text, via_table text,
                                                                                      via_from_column text, via_to_column text, to_table text,
                                                                                      to_column text, kind text)
                                   WHERE x.from_table = ef AND x.to_table = et.table_name LOOP
                            IF er.kind = 'arm' THEN
                                v_parts := v_parts || format(
                                    'SELECT a.src, t.id, t.code, %s AS label'
                                    ' FROM public.document_relation_arm_pairs(%L, $1) a JOIN public.%I t ON t.id = a.id',
                                    v_sel, er.via_table, er.to_table);
                            ELSIF er.kind = 'bridge' THEN
                                v_parts := v_parts || format(
                                    'SELECT s.id AS src, t.id, t.code, %s AS label FROM public.%I s JOIN public.%I v ON v.%I = s.%I'
                                    ' JOIN public.%I t ON t.%I = v.%I WHERE s.id = ANY ($1)',
                                    v_sel, er.from_table, er.via_table, er.via_from_column, er.from_column,
                                    er.to_table, er.to_column, er.via_to_column);
                            ELSE
                                v_parts := v_parts || format(
                                    'SELECT s.id AS src, t.id, t.code, %s AS label FROM public.%I s JOIN public.%I t ON t.%I = s.%I'
                                    ' WHERE s.id = ANY ($1)',
                                    v_sel, er.from_table, er.to_table, er.to_column, er.from_column);
                            END IF;
                        END LOOP;
                        IF cardinality(v_parts) = 0 THEN
                            v_sql := NULL;      -- 结构上没有边:这一组永远是空的(与 search_related_rows() 的"返回空集"同一条)
                        ELSE
                            v_where := 'TRUE';
                            IF et.shared THEN v_where := v_where || format(' AND u.code LIKE %L', et.prefix || '-%'); END IF;
                            IF et.table_name = ef THEN v_where := v_where || ' AND u.id <> u.src'; END IF;
                            v_sql := format(
                                'SELECT DISTINCT ON (r.id) r.id, r.code, r.label FROM ('
                                ' SELECT d.*, row_number() OVER (PARTITION BY d.src ORDER BY d.code DESC) AS rn FROM ('
                                '  SELECT DISTINCT ON (u.src, u.id) u.src, u.id, u.code, u.label FROM (%s) u WHERE %s ORDER BY u.src, u.id) d) r'
                                ' WHERE r.rn <= 100 ORDER BY r.id',
                                array_to_string(v_parts, ' UNION ALL '), v_where);
                        END IF;
                        v_edge := v_edge || jsonb_build_object(sk || '>' || t, v_sql);
                    END IF;
                    v_sql := v_edge ->> (sk || '>' || t);
                    CONTINUE WHEN v_sql IS NULL;
                    -- 这一跳找到的全部候选先收齐,判据整组问一次,再一行一行加
                    EXECUTE 'SELECT coalesce(array_agg(q.id), ''{}''), coalesce(array_agg(q.code), ''{}''), coalesce(array_agg(q.label), ''{}'') FROM ('
                            || v_sql || ') q'
                       INTO v_hid, v_hcode, v_hlabel USING v_ids;
                    CONTINUE WHEN cardinality(v_hid) = 0;
                    v_ok := CASE WHEN v_filter IS NULL THEN v_hid
                                 ELSE ARRAY(SELECT a.id FROM public.document_chain_step_admitted(v_filter, v_hid) a) END;
                    FOR i IN 1 .. cardinality(v_hid) LOOP
                        CONTINUE WHEN v_seen ? (j || '|' || v_hid[i]) OR NOT (v_hid[i] = ANY (v_ok));
                        f_step := f_step || j; f_key := f_key || t; f_id := f_id || v_hid[i];
                        v_seen := v_seen || jsonb_build_object(j || '|' || v_hid[i], true);
                        f_code := f_code || v_hcode[i]; f_label := f_label || v_hlabel[i];
                        v_added := v_added + 1;
                    END LOOP;
                END LOOP;
            END LOOP;
        END LOOP;
        EXIT WHEN v_added = 0;
    END LOOP;

    -- 地址:每一种单据整组问一次 document_detail_hrefs(化验单的地址要读它那一批 —— 一组只读一次表,不是每一张各读一次)
    RETURN QUERY
    WITH u AS (
        SELECT * FROM unnest(f_step, f_key, f_id, f_code, f_label) AS u(st, k, i, c, l)
    ), h AS (
        SELECT DISTINCT kk.k, x.id, x.href
          FROM (SELECT DISTINCT u.k FROM u) kk
          CROSS JOIN LATERAL public.document_detail_hrefs(kk.k, ARRAY(SELECT DISTINCT u2.i FROM u u2 WHERE u2.k = kk.k)) x
    )
    SELECT u.st, u.k, u.i, u.c, u.l, h.href
      FROM u LEFT JOIN h ON h.k = u.k AND h.id = u.i
     ORDER BY u.st, u.c DESC;
END;
$function$;

COMMENT ON FUNCTION public.document_chain_walk(jsonb, integer, text, uuid) IS
    'SYSTEM-MAP-3:单据链条的取数 —— 从读者站的那一步往外,经关联图(外键边 + 声明的边)一圈一圈走;'
    '同一种单据在两步上是它自己;带判据的步骤只认存在的那几张。INVOKER —— 每一跳由 RLS 回答。';

-- ── db/functions/trail_fk_targets.sql ──
-- db/functions/trail_fk_targets.sql
-- AUDIT-TRAIL-1a(Tim 的 Q12 · Q13 · Q40):一张表里【哪些列指着别的记录】,指着哪张表的哪一列。
--   · 单列外键,读目录(pg_constraint),不靠列名猜;
--   · 外加【没有外键的账号列】:uuid 类型、名字以 _by 结尾或叫 actor_user_id —— 它们记的是登录账号
--     (auth.uid()),指向 'auth.users'。created_by / updated_by 也在此列,由界面按 Q12 隐藏。
-- 解析成人读得懂的名字由 trail_ref_label 做;这里只回答"指着谁"。
-- CHAIN-WALK-COST(v1.4.80):按表的 oid 找(to_regclass('public.<表>'),走目录索引),不按名字连 pg_class 再筛 —— 同一组行
--   (public 里叫这个名字的那一张表),每调一次从约 0.8 ms 降到几十微秒;一页审计记录每一行调它两次。
CREATE OR REPLACE FUNCTION public.trail_fk_targets(p_table text)
 RETURNS TABLE(column_name text, target_table text, target_column text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- CHAIN-WALK-COST:PL/pgSQL 而不是 SQL —— 一支带 SET 子句的 SQL 函数每调一次都重新规划这一串目录连接(约 0.5 ms,查询本身几微秒);
    --   PL/pgSQL 在一个会话里把计划缓存下来。查询逐字未变。
    RETURN QUERY
    SELECT a.attname::text, tc.relname::text, ta.attname::text
      FROM pg_constraint k
      JOIN pg_class c ON c.oid = k.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
      JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
      JOIN pg_class tc ON tc.oid = k.confrelid
      JOIN pg_namespace tn ON tn.oid = tc.relnamespace
      JOIN pg_attribute ta ON ta.attrelid = k.confrelid AND ta.attnum = k.confkey[1]
     WHERE k.conrelid = to_regclass(format('public.%I', p_table)) AND k.contype = 'f' AND cardinality(k.conkey) = 1
       AND tn.nspname = 'public'
    UNION ALL
    SELECT a.attname::text, 'auth.users', 'id'
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
     WHERE a.attrelid = to_regclass(format('public.%I', p_table)) AND a.attnum > 0 AND NOT a.attisdropped
       AND a.atttypid = 'uuid'::regtype
       AND (a.attname ~ '_by$' OR a.attname IN ('actor_user_id', 'user_id'))
       AND NOT EXISTS (SELECT 1 FROM pg_constraint k2
                        WHERE k2.conrelid = c.oid AND k2.contype = 'f' AND k2.conkey = ARRAY[a.attnum]
                          AND k2.confrelid <> 'auth.users'::regclass);
END;
$function$;

-- ── db/functions/trail_current_image.sql ──
-- db/functions/trail_current_image.sql
-- AUDIT-TRAIL-1a:一行【今天】的整份样子 —— 还在就读那一行;已经被硬删,就取 change_log 里它最后一份完整影像
--   (DELETE 的 old,或 INSERT 的 new)。两处都没有 → NULL。第二个返回值说它是不是已经不在了。
-- 给 record_trail 用:判这一行过不过它自己那张表的读规则(Q4)、以及给子行一个"这是哪一行"的上下文(第几行、哪个物料)。
-- 【属主身份】按表名动态读任意一张表;EXECUTE 已从 authenticated 收回。
-- AUDIT-TRAIL-1d-1(M9):trail_log_only_tables() 登记的表(auth.users)不在 public 里 —— 照登记的 schema 去读,
--   并且【只读那一份安全投影】(id · email · created_at · banned_until),绝不 to_jsonb 整行(那会把口令散列与令牌带进上下文)。
--   这种表在 change_log 里没有行影像(它的事件是 record_account_event 写的 ACCOUNT_* 那几种),所以读不到就是 NULL,不回落。
CREATE OR REPLACE FUNCTION public.trail_current_image(p_table text, p_key jsonb, OUT image jsonb, OUT gone boolean)
 RETURNS record
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_where text;
    v_lo    record;
BEGIN
    gone := false;
    SELECT l.* INTO v_lo FROM trail_log_only_tables() l WHERE l.table_name = p_table;
    IF FOUND THEN
        IF p_key IS NULL OR NOT (p_key ? 'id') THEN
            image := NULL;
            RETURN;
        END IF;
        EXECUTE format('SELECT jsonb_build_object(%s) FROM %I.%I t WHERE t.id::text = $1 LIMIT 1',
                       (SELECT string_agg(format('%L, t.%I', c, c), ', ') FROM unnest(v_lo.image_columns) c),
                       v_lo.schema_name, v_lo.rel_name)
           INTO image USING p_key ->> 'id';
        RETURN;
    END IF;
    IF p_key IS NULL OR to_regclass(format('public.%I', p_table)) IS NULL THEN
        image := NULL;
        RETURN;
    END IF;
    -- CHAIN-WALK-COST:键按那一列自己的类型比(未定型的字面量由列定型),不把列转成文字 —— 后者用不上主键索引,每一行一次整表扫。
    --   键都来自这张表自己的主键(或它的影像),是那个类型的规范写法,所以答案逐字不变。
    SELECT string_agg(format('t.%I = %L', k.key, k.value), ' AND ')
      INTO v_where FROM jsonb_each_text(p_key) k;
    BEGIN
        EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE %s LIMIT 1', p_table, v_where) INTO image;
    EXCEPTION WHEN data_exception THEN
        image := NULL;   -- 一个读不成那一列类型的键(页面传来的 'not-a-uuid')= 找不到,与以前文字比较的结局相同(fixture 236 R3)
    END;
    IF image IS NOT NULL THEN
        RETURN;
    END IF;
    SELECT CASE WHEN c.op = 'DELETE' THEN c.old ELSE c.new END INTO image
      FROM change_log c
     WHERE c.table_name = p_table AND c.row_key = p_key AND c.op IN ('INSERT', 'DELETE')
     ORDER BY c.seq DESC
     LIMIT 1;
    gone := image IS NOT NULL;
END;
$function$;

-- ── db/functions/trail_row_visible.sql ──
-- db/functions/trail_row_visible.sql
-- AUDIT-TRAIL-1a(Tim 的 Q4 · Q5):【当前读者】能不能读这一行 —— 按【这一行自己那张表】的读规则,不按父记录的。
--   record_trail 是 SECURITY DEFINER(change_log 对应用角色没有任何授权),而 DEFINER 里做不了 SET ROLE,
--   所以这里把那张表的 SELECT 策略(permissive 的 SELECT 与 ALL,给 authenticated 或 public 的)用 OR 拼起来,
--   对着那一行重新求一次值。这样做是对的,因为实测(AUDIT-TRAIL-0 reader-masking.md §1.6):线上 287 条读策略
--   0 条 restrictive、0 条依赖数据库角色 —— 全部经 has_permission() / current_user_employee() 从登录的 JWT 认人。
--   restrictive 策略若将来出现,在这里用 AND 接上(已经写好)。
--   ★ U1-A(2026-10-05):第一条 restrictive 策略来了 —— journal_lines 的 "amounts: payroll journal lines need data.view_pay"。
--     名字以 "amounts:" 开头的这一类【不】接进来:它们挡的是 API 上的整行(PostgREST 做不了逐行遮列),
--     而审计记录跟【屏幕】走(<表>_masked:行在、金额受限),金额由 change_log_mask_rules 遮。别的 restrictive 照旧 AND。
--   · 表没开 RLS → 看 authenticated 有没有任何一列的 SELECT 权限;
--   · authenticated 连一列都读不了(cod_verification_failures 那种没有读策略的表)→ 看不见;
--   · 这一行已被硬删 → 对它最后一份影像求同一个值(jsonb_populate_record,别名就是表名,于是带表名限定的列引用照样解析)。
--   ☞ 已知边界(reader-masking.md §1.6 已记):策略里 EXISTS 子查询读的别的表,在 DEFINER 里不再过那张表的 RLS。
--     线上两处这种策略的子查询都自己写全了条件,所以结果相同。
-- 【属主身份】EXECUTE 已从 authenticated 收回 —— 否则它就是一支"任意一行你看不看得见"的探针。
-- AUDIT-TRAIL-1d-1(M9):trail_log_only_tables() 登记的表(auth.users)不在 public 里,它的策略这里读不到 ——
--   它的读规则是登记表里【声明的那个码】(action.manage_permissions,与 user_directory 同一个谓词)。
CREATE OR REPLACE FUNCTION public.trail_row_visible(p_table text, p_key jsonb, p_image jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rls   boolean;
    v_perm  text;
    v_restr text;
    v_where text;
    v_ok    boolean;
    v_live  boolean;
    v_code  text;
BEGIN
    SELECT l.read_code INTO v_code FROM trail_log_only_tables() l WHERE l.table_name = p_table;
    IF FOUND THEN
        RETURN p_key IS NOT NULL AND has_permission(v_code);
    END IF;
    SELECT c.relrowsecurity INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
     WHERE c.relname = p_table AND c.relkind = 'r';
    IF NOT FOUND OR p_key IS NULL THEN
        RETURN false;
    END IF;
    IF NOT has_any_column_privilege('authenticated', format('public.%I', p_table), 'SELECT') THEN
        RETURN false;
    END IF;
    IF NOT v_rls THEN
        RETURN true;
    END IF;
    SELECT string_agg('(' || p.qual || ')', ' OR ') INTO v_perm
      FROM pg_policies p
     WHERE p.schemaname = 'public' AND p.tablename = p_table AND p.permissive = 'PERMISSIVE'
       AND p.cmd IN ('SELECT', 'ALL') AND p.roles && ARRAY['authenticated', 'public']::name[]
       AND p.qual IS NOT NULL;
    IF v_perm IS NULL THEN
        RETURN false;
    END IF;
    SELECT string_agg('(' || p.qual || ')', ' AND ') INTO v_restr
      FROM pg_policies p
     WHERE p.schemaname = 'public' AND p.tablename = p_table AND p.permissive = 'RESTRICTIVE'
       AND p.cmd IN ('SELECT', 'ALL') AND p.roles && ARRAY['authenticated', 'public']::name[]
       AND p.qual IS NOT NULL
       -- U1-A:名字以 "amounts:" 开头的 restrictive 策略只是【金额】的门(经 API 藏掉整行,因为 PostgREST 做不了逐行遮列);
       --   审计记录跟屏幕走 —— 那一行在、金额受限,遮蔽由 change_log_mask_rules 给出(journal_lines 的 pay_journal)。
       AND p.policyname NOT LIKE 'amounts:%';
    v_perm := '(' || v_perm || ')' || COALESCE(' AND (' || v_restr || ')', '');

    -- CHAIN-WALK-COST:同 trail_current_image —— 按列自己的类型比,用得上主键索引
    SELECT string_agg(format('%I.%I = %L', p_table, k.key, k.value), ' AND ')
      INTO v_where FROM jsonb_each_text(p_key) k;
    BEGIN
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%1$I %1$I WHERE %2$s)', p_table, v_where) INTO v_live;
    EXCEPTION WHEN data_exception THEN
        v_live := false;   -- 键读不成那一列的类型 = 不是今天的一行(与以前文字比较的结局相同),落到下面按影像判
    END;
    IF v_live THEN
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%1$I %1$I WHERE %2$s AND (%3$s))', p_table, v_where, v_perm)
           INTO v_ok;
        RETURN COALESCE(v_ok, false);
    END IF;
    IF p_image IS NULL THEN
        RETURN false;
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM jsonb_populate_record(NULL::public.%1$I, $1) %1$I WHERE (%2$s))',
                   p_table, v_perm)
       INTO v_ok USING p_image;
    RETURN COALESCE(v_ok, false);
END;
$function$;

-- ── db/functions/trail_ref_label.sql ──
-- db/functions/trail_ref_label.sql
-- AUDIT-TRAIL-1a(Tim 的 Q12 · Q13 · Q40):一个被引用的值 → 屏幕上认得出的名字。数据库解析,界面只负责造句。
--   返回 {"label": …, "gone": bool, "person": {…}}(person 只在 p_table = 'auth.users' 时有):
--   · 单据(document_types 登记的表)→ 单据编号(PO-2026-0010);客户 / 供应商 → 法定名;物料 → 名称;
--     员工 → 称呼名,没有就法定名;批次 → 编号 · 物料名(外加 unit);采购单明细行 → 采购单编号 line N;
--     字典(有 name_en 的表)→ name_en;币种 → 代码;其余依次试 name / legal_name / title / label。
--   · 一个都没有 → label 为 NULL,界面说 "a <thing>"。【绝不回落到 uuid 或内部代码】。
--   · 那一行已经被硬删 → 取 change_log 里它最后一份完整影像,gone = true(界面加 "(since deleted)");
--     连影像都没有(早于变更记录,或从未存在)→ label NULL + gone = true(界面说 "a … that has since been deleted")。
--   · 'auth.users':一个登录账号 → 那个人(trail_actor 同一套答法)。
-- AUDIT-TRAIL-1b-1:
--   · 加工单多带一个 ended(它已经回滚了)—— 批次页上"用在加工 PROC-…"那一条据此加一句灰字
--     "This processing was later rolled back"(旧批次记录的 run_voided,Q5)。
--   · 交接班 → "DD/MM/YYYY · 班次";停机 → "机器编号 · DD/MM/YYYY HH:MM"(新加坡时间)—— 两张表都没有编号或名字,
--     以前只能说 "a handover" / "a downtime"。
-- AUDIT-TRAIL-1b-2:订单 / 报价明细行 → "SO-… line N";港口 → "代码 名称";航段 → "起运港 → 目的港";
--   执照与合规证书 → "种类 · 编号";附件 → 文件名;集装箱单据 → 单据种类 —— 这几张表都没有编号或 name 一类的列。
--   物料多带一个 unit(与批次同一个做法):订单 / 报价明细行的数量据此说成 "10 kg"。
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 的 Q12 · Q33):
--   · 员工 → 走 trail_actor(与"谁做的"同一份答法):不持 module.hr.view 的读者只认得出他自己,别人一律 Restricted ——
--     与 ActorName、与每一页的人名同一条规矩(§9.7 早就说"每一个指着人的值都走同一个函数",而此前这一支直接把名字交了出去)。
--     付款、费用、报销单、付款申请上的 employee_id 都是这一种。匿名化了的人说 "A former employee"(以前是一个空名字)。
--   · 单据(document_types 里 link_mode = 'detail' 的)多带一个 href(详情页的路径)—— 审计记录里"被 JE-… 冲销"那一行
--     是一个链接(Q33),路径来自登记表,界面不拼路由。
-- AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §g · Q14):这几张表没有编号或名字,以前只能说 "a …":
--   · 销售 → "OUT-2026-0186 sale 01/08/2026"(卖的那一批 + 售出日;与 "PO-… line N" 同一种说法),外加 href 指向它的应收页
--     (Q14:销售没有 code 列,所以【不】进 document_types —— 进了,全站搜索会对它拼一句 SELECT code,当场报错;
--      Record 一栏的名字与链接由这里与 trail_row_record 给,与单据同一个形状);
--   · 汇率 → "USD · TT selling rate · 01/08/2026";对账单行 → "BS-… line N";分录行 → "JE-… · 科目";申报格 → "Box 1";
--     对账记录 → "BS-… reconciliation DD/MM/YYYY";折旧 → "FA-… · period ending DD/MM/YYYY"。
-- AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a):这几张也没有编号或名字 ——
--   · 财务设置那一行 → "Finance settings";公司资料那一行 → "Company profile"(两张都是单行表,id = true);
--   · 月结 → "Period ending DD/MM/YYYY";年结 → "Year ending DD/MM/YYYY";
--   · 行内转账 → "Transfer DD/MM/YYYY · Cash at Bank – SGD → Cash at Bank – USD"(两头按科目表的名字说,不说 1000 / 1010)。
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a):
--   · 登录账号('auth.users')多带一个 label —— 认得出的那个人的名字(trail_actor 同一份答法:不持 hr.view 的读者只认得出
--     自己):/settings/change-history 的 Record 一栏(授权、附加账号的家是账号,Q22)读 label,不读 person。认不出就没有名字,
--     界面说 "a login account" —— 【不】回落到邮箱(那是账号的身份数据,不是它的名字)。
--   · 培训记录 → 培训的名字;导入批次 → 文件名(两张表都没有 name / title / label 一类的列)。
-- AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a · Q36):
--   · 假期发放 → "Annual leave 2027"(假别的英文名 + 那一个假期年;那张表没有名字一类的列);
--   · 加班批 → 它的 label("OT 2026-10 #1",照旧),外加 href 指向 /hr/overtime/<id>。加班批没有 code 列,所以它【不】进
--     document_types(全站搜索会对登记的每一张表拼一句 SELECT code —— 销售那一刀记过同一个理由);链接在这里给,与销售同一个形状。
-- AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a · Q10):
--   · 评审 → "Annual review 01/01/2026–31/12/2026"(种类 + 期间;那张表没有名字一类的列 —— 被评审的人【不】进名字:
--     名字要过 ActorName 那一道,而这一句是一个单据的名字,不经 trail_actor);外加 href 指向 /hr/reviews/<id>;
--   · 工资申请 → "PAY-2026-0001 posting request"(label 里那一截原样的种类 "· post #1" 不上屏 —— Q10;种类说成英文);
--   · KPI 条目 → "F1 · Stock accuracy"(参考号 · 标题)。轮次(name)与评分刻度(name_en)走通用的那一支。
-- 【属主身份】按表名动态读;EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.trail_ref_label(p_table text, p_column text, p_value text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_img   jsonb;
    v_gone  boolean := false;
    v_label text;
    v_doc   boolean;
    v_extra text;
    v_type  text;
BEGIN
    IF p_value IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_table = 'auth.users' THEN
        IF p_value !~ '^[0-9a-fA-F-]{36}$' THEN
            RETURN NULL;
        END IF;
        v_img := trail_actor('prelog', p_value::uuid, NULL);
        RETURN jsonb_build_object('person', v_img, 'label', CASE WHEN v_img ->> 'state' = 'person' THEN v_img ->> 'name' END);
    END IF;
    IF to_regclass(format('public.%I', p_table)) IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_table = 'employees' AND p_column = 'id' THEN
        IF p_value !~ '^[0-9a-fA-F-]{36}$' THEN
            RETURN NULL;
        END IF;
        -- label 一并带回(只在认得出名字时):/settings/change-history 的 Record 一栏读 label,不读 person
        v_img := trail_actor('prelog', NULL, p_value::uuid);
        RETURN jsonb_build_object('person', v_img, 'gone', false,
                                  'label', CASE WHEN v_img ->> 'state' = 'person' THEN v_img ->> 'name' END);
    END IF;
    -- CHAIN-WALK-COST:按那一列自己的类型比,不把列转成文字(`t.col::text = $1` 用不上索引,每一个名字一次整表扫)。
    --   值读不成那个类型时什么都对不上 —— 与以前"文字比不上"同一个结局;值都来自那一列自己的影像,所以是它的规范写法,答案逐字不变。
    SELECT format_type(a.atttypid, a.atttypmod) INTO v_type
      FROM pg_attribute a WHERE a.attrelid = format('public.%I', p_table)::regclass AND a.attname = p_column AND NOT a.attisdropped;
    IF v_type IS NULL THEN
        -- 没有这一列:照旧让那一句自己报错(不把一个写错的列名变成"找不到")
        EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.%I::text = $1 LIMIT 1', p_table, p_column)
           INTO v_img USING p_value;
    ELSE
        -- ★ 不用 pg_input_is_valid(值, 变化的类型) 先验:在 PL/pgSQL 缓存的表达式里它记住【第一次】的类型(本地实测:先判一次 uuid,
        --   之后 'USD' 对 text 也判成无效)。改成一个只接数据错误(SQLSTATE 22 类)的子事务:读不成那个类型 = 对不上,与以前同一个结局。
        BEGIN
            EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.%I = $1::%s LIMIT 1', p_table, p_column, v_type)
               INTO v_img USING p_value;
        EXCEPTION WHEN data_exception THEN
            v_img := NULL;
        END;
    END IF;
    IF v_img IS NULL THEN
        v_gone := true;
        SELECT CASE WHEN c.op = 'DELETE' THEN c.old ELSE c.new END INTO v_img
          FROM change_log c
         WHERE c.table_name = p_table AND c.row_key = jsonb_build_object(p_column, p_value)
           AND c.op IN ('INSERT', 'DELETE')
         ORDER BY c.seq DESC LIMIT 1;
        IF v_img IS NULL THEN
            RETURN jsonb_build_object('label', NULL, 'gone', true);
        END IF;
    END IF;
    v_doc := EXISTS (SELECT 1 FROM document_types d WHERE d.table_name = p_table);
    v_label := CASE
        WHEN p_table = 'employees' THEN
            CASE WHEN v_img ->> 'anonymised_at' IS NULL
                 THEN COALESCE(NULLIF(v_img ->> 'preferred_name', ''), v_img ->> 'legal_name') END
        WHEN p_table IN ('suppliers', 'customers') THEN v_img ->> 'legal_name'
        WHEN p_table = 'materials' THEN v_img ->> 'name'
        WHEN p_table = 'currencies' THEN v_img ->> 'code'
        WHEN p_table = 'training_records' THEN v_img ->> 'training_name'
        WHEN p_table = 'import_batches' THEN v_img ->> 'file_name'
        WHEN p_table = 'purchase_order_lines' THEN
            (SELECT po.code FROM purchase_orders po WHERE po.id = CASE WHEN pg_input_is_valid(v_img ->> 'purchase_order_id', 'uuid') THEN (v_img ->> 'purchase_order_id')::uuid END)
            || ' line ' || (v_img ->> 'line_no')
        WHEN v_doc AND v_img ? 'code' THEN v_img ->> 'code'
        WHEN v_img ? 'name_en' THEN v_img ->> 'name_en'
        WHEN v_img ? 'name' THEN v_img ->> 'name'
        WHEN v_img ? 'legal_name' THEN v_img ->> 'legal_name'
        WHEN v_img ? 'title' THEN v_img ->> 'title'
        WHEN v_img ? 'label' THEN v_img ->> 'label'
    END;
    IF p_table = 'shift_handovers' THEN
        v_label := to_char((v_img ->> 'handover_date')::date, 'DD/MM/YYYY')
                   || COALESCE(' · ' || (SELECT s.name_en FROM shifts s WHERE s.code = v_img ->> 'shift_code'), '');
    ELSIF p_table = 'equipment_downtime' THEN
        v_label := COALESCE((SELECT fa.code FROM fixed_assets fa WHERE fa.id = CASE WHEN pg_input_is_valid(v_img ->> 'equipment_id', 'uuid') THEN (v_img ->> 'equipment_id')::uuid END) || ' · ', '')
                   || to_char(((v_img ->> 'started_at')::timestamptz) AT TIME ZONE 'Asia/Singapore', 'DD/MM/YYYY HH24:MI');
    ELSIF p_table IN ('sales_order_lines', 'quote_lines', 'invoice_lines') THEN
        -- AUDIT-TRAIL-1b-2:订单 / 报价的明细行 → "SO-2026-0001 line 1"(与采购单明细同一种说法)
        -- AUDIT-TRAIL-1c-1:发票明细行同一种说法(贷项通知的每一行冲的是发票的哪一行)
        v_label := CASE p_table
            WHEN 'sales_order_lines' THEN (SELECT so.code FROM sales_orders so WHERE so.id = CASE WHEN pg_input_is_valid(v_img ->> 'sales_order_id', 'uuid') THEN (v_img ->> 'sales_order_id')::uuid END)
            WHEN 'invoice_lines' THEN (SELECT i.code FROM invoices i WHERE i.id = CASE WHEN pg_input_is_valid(v_img ->> 'invoice_id', 'uuid') THEN (v_img ->> 'invoice_id')::uuid END)
            ELSE (SELECT q.code FROM quotes q WHERE q.id = CASE WHEN pg_input_is_valid(v_img ->> 'quote_id', 'uuid') THEN (v_img ->> 'quote_id')::uuid END) END
            || ' line ' || (v_img ->> 'line_no');
    ELSIF p_table = 'ports' THEN
        -- 港口 → "SGSIN Singapore"(航段页、货代页上的同一种写法)
        v_label := concat_ws(' ', v_img ->> 'code', v_img ->> 'name');
    ELSIF p_table = 'lanes' THEN
        -- 航段没有名字 → "起运港 → 目的港"(两头各按港口那一句说)
        v_label := COALESCE((SELECT concat_ws(' ', pt.code, pt.name) FROM ports pt WHERE pt.id = CASE WHEN pg_input_is_valid(v_img ->> 'origin_port_id', 'uuid') THEN (v_img ->> 'origin_port_id')::uuid END), '?')
                   || ' → ' ||
                   COALESCE((SELECT concat_ws(' ', pt.code, pt.name) FROM ports pt WHERE pt.id = CASE WHEN pg_input_is_valid(v_img ->> 'destination_port_id', 'uuid') THEN (v_img ->> 'destination_port_id')::uuid END), '?');
    ELSIF p_table IN ('company_compliance', 'supplier_compliance') THEN
        -- 执照 / 证书 → "证书种类 · 编号"
        v_label := concat_ws(' · ', (SELECT ct.name_en FROM certificate_types ct WHERE ct.code = v_img ->> 'cert_type_code'),
                             NULLIF(v_img ->> 'cert_no', ''));
    ELSIF p_table IN ('customer_attachments', 'supplier_attachments') THEN
        v_label := v_img ->> 'file_name';
    ELSIF p_table = 'container_documents' THEN
        v_label := v_img ->> 'document_type';
    ELSIF p_table = 'sales_records' THEN
        v_label := COALESCE((SELECT ob.code FROM output_batches ob WHERE ob.id = CASE WHEN pg_input_is_valid(v_img ->> 'output_batch_id', 'uuid') THEN (v_img ->> 'output_batch_id')::uuid END) || ' sale ', 'Sale ')
                   || to_char((v_img ->> 'sale_date')::date, 'DD/MM/YYYY');
        RETURN jsonb_build_object('label', v_label, 'gone', v_gone)
               || CASE WHEN p_column = 'id' AND NOT v_gone
                       THEN jsonb_build_object('href', '/finance/receivables/' || p_value) ELSE '{}'::jsonb END;
    ELSIF p_table = 'fx_rates' THEN
        v_label := concat_ws(' · ', v_img ->> 'currency',
                             CASE v_img ->> 'rate_type' WHEN 'tt_buy' THEN 'TT buying rate' WHEN 'tt_sell' THEN 'TT selling rate'
                                                        WHEN 'mid' THEN 'Mid rate' END,
                             to_char((v_img ->> 'rate_date')::date, 'DD/MM/YYYY'));
    ELSIF p_table = 'journal_lines' THEN
        -- 对账单的一行匹配到的那一行分录 → "JE-2026-0001 · Cash at Bank – SGD"(分录号 · 科目)
        v_label := concat_ws(' · ', (SELECT je.code FROM journal_entries je WHERE je.id = CASE WHEN pg_input_is_valid(v_img ->> 'entry_id', 'uuid') THEN (v_img ->> 'entry_id')::uuid END),
                             (SELECT a.name_en FROM accounts a WHERE a.id = CASE WHEN pg_input_is_valid(v_img ->> 'account_id', 'uuid') THEN (v_img ->> 'account_id')::uuid END));
    ELSIF p_table = 'bank_statement_lines' THEN
        v_label := (SELECT bs.code FROM bank_statements bs WHERE bs.id = CASE WHEN pg_input_is_valid(v_img ->> 'statement_id', 'uuid') THEN (v_img ->> 'statement_id')::uuid END) || ' line ' || (v_img ->> 'line_no');
    ELSIF p_table = 'gst_return_boxes' THEN
        v_label := 'Box ' || regexp_replace(v_img ->> 'box', '^box', '');
    ELSIF p_table = 'bank_reconciliations' THEN
        v_label := (SELECT bs.code FROM bank_statements bs WHERE bs.id = CASE WHEN pg_input_is_valid(v_img ->> 'statement_id', 'uuid') THEN (v_img ->> 'statement_id')::uuid END)
                   || ' reconciliation ' || to_char(((v_img ->> 'reconciled_at')::timestamptz) AT TIME ZONE 'Asia/Singapore', 'DD/MM/YYYY');
    ELSIF p_table = 'fixed_asset_depreciation' THEN
        v_label := (SELECT fa.code FROM fixed_assets fa WHERE fa.id = CASE WHEN pg_input_is_valid(v_img ->> 'asset_id', 'uuid') THEN (v_img ->> 'asset_id')::uuid END)
                   || ' · period ending ' || to_char((v_img ->> 'period_end')::date, 'DD/MM/YYYY');
    ELSIF p_table = 'finance_settings' THEN
        v_label := 'Finance settings';
    ELSIF p_table = 'company_profile' THEN
        v_label := 'Company profile';
    ELSIF p_table = 'period_closes' THEN
        v_label := 'Period ending ' || to_char((v_img ->> 'period_end')::date, 'DD/MM/YYYY');
    ELSIF p_table = 'year_closes' THEN
        v_label := 'Year ending ' || to_char((v_img ->> 'year_end')::date, 'DD/MM/YYYY');
    ELSIF p_table = 'bank_transfers' THEN
        v_label := 'Transfer ' || to_char((v_img ->> 'transfer_date')::date, 'DD/MM/YYYY') || ' · '
                   || COALESCE((SELECT a.name_en FROM accounts a WHERE a.code = v_img ->> 'from_account'), '?') || ' → '
                   || COALESCE((SELECT a.name_en FROM accounts a WHERE a.code = v_img ->> 'to_account'), '?');
    ELSIF p_table = 'leave_grants' THEN
        v_label := concat_ws(' ', (SELECT lt.name_en FROM leave_types lt WHERE lt.code = v_img ->> 'leave_type_code'), v_img ->> 'leave_year');
    ELSIF p_table = 'overtime_batches' THEN
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
               || CASE WHEN p_column = 'id' AND NOT v_gone
                       THEN jsonb_build_object('href', '/hr/overtime/' || p_value) ELSE '{}'::jsonb END;
    ELSIF p_table = 'performance_reviews' THEN
        v_label := CASE v_img ->> 'review_type' WHEN 'probation' THEN 'Probation review' ELSE 'Annual review' END
                   || ' ' || to_char((v_img ->> 'period_start')::date, 'DD/MM/YYYY') || '–' || to_char((v_img ->> 'period_end')::date, 'DD/MM/YYYY');
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
               || CASE WHEN p_column = 'id' AND NOT v_gone
                       THEN jsonb_build_object('href', '/hr/reviews/' || p_value) ELSE '{}'::jsonb END;
    ELSIF p_table = 'payroll_requests' THEN
        v_label := COALESCE((SELECT pp.code FROM payroll_periods pp WHERE pp.id = CASE WHEN pg_input_is_valid(v_img ->> 'payroll_period_id', 'uuid') THEN (v_img ->> 'payroll_period_id')::uuid END) || ' ', '')
                   || CASE v_img ->> 'kind' WHEN 'reversal' THEN 'unposting request' ELSE 'posting request' END;
    ELSIF p_table = 'process_recipe_versions' THEN
        -- MES-4a(2026-10-07):一个配方版本说成"配方代号 v版本号"(CR-STD v2)—— 它自己没有 code / name 列
        v_label := (SELECT rc.code FROM process_recipes rc WHERE rc.id = CASE WHEN pg_input_is_valid(v_img ->> 'recipe_id', 'uuid') THEN (v_img ->> 'recipe_id')::uuid END) || ' v' || (v_img ->> 'version');
    ELSIF p_table = 'kpi_entries' THEN
        v_label := concat_ws(' · ', NULLIF(v_img ->> 'kpi_ref', ''), NULLIF(v_img ->> 'title', ''));
    ELSIF p_table = 'processing_runs' THEN
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone, 'ended', v_img ->> 'deleted_at' IS NOT NULL);
    END IF;
    IF p_table = 'materials' THEN
        -- AUDIT-TRAIL-1b-2:物料带回它的单位 —— 订单 / 报价的明细行没有单位列,"10"要说成"10 kg"
        --   只在影像里真有单位时才带(一份早于变更记录、只剩名字的影像不说单位 —— 与"名字 + gone"那一形状逐字相同)
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
               || CASE WHEN v_img ->> 'unit' IS NOT NULL THEN jsonb_build_object('unit', v_img ->> 'unit') ELSE '{}'::jsonb END;
    END IF;
    IF p_table IN ('inbound_batches', 'output_batches') THEN
        IF v_img ->> 'material_id' IS NOT NULL THEN
            SELECT m.name INTO v_extra FROM materials m WHERE m.id = CASE WHEN pg_input_is_valid(v_img ->> 'material_id', 'uuid') THEN (v_img ->> 'material_id')::uuid END;
            IF v_extra IS NOT NULL THEN
                v_label := v_label || ' · ' || v_extra;
            END IF;
        END IF;
        -- 批次的数量单位随名字一起带回 —— 加工单的"用了 300"要说成"300 kg",而投入 / 产出行自己没有单位列
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone, 'unit', v_img ->> 'unit');
    END IF;
    RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
           || COALESCE((SELECT jsonb_build_object('href', d.route || '/' || p_value) FROM document_types d
                         WHERE d.table_name = p_table AND d.link_mode = 'detail' AND p_column = 'id' AND NOT v_gone
                         ORDER BY d.key LIMIT 1), '{}'::jsonb);
END;
$function$;

-- ── db/functions/change_log_field.sql ──
-- db/functions/change_log_field.sql
-- HISTORY-1:为遮蔽与任务隐私的判据取【这一行的某个字段】。
--   一次编辑只记了改了的那几列,判据要的字段(employee_id / direction / task_id)常常不在影像里。
--   先后:这条记录自己的 new / old / 主键 → 那一行今天的值 → 同一行更早的记录里最近一次出现的值
--   (那一行已经被删掉时,只剩记录答得出)。三处都没有 → NULL,调用方按【看不见】处理。
-- 【不是 SECURITY DEFINER】它只被 change_log_rows 的判据调用,那时以属主身份跑;
--   EXECUTE 已从 authenticated 收回 —— 它按表名动态读任意一张表。
-- CHAIN-WALK-COST(v1.4.80):今天这一行按键列自己的类型找(走主键索引),不再整行 to_jsonb 再 @>。
CREATE OR REPLACE FUNCTION public.change_log_field(p_table text, p_key jsonb, p_old jsonb, p_new jsonb, p_field text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v text := COALESCE(p_new ->> p_field, p_old ->> p_field, p_key ->> p_field);
BEGIN
    IF v IS NOT NULL OR p_key IS NULL THEN
        RETURN v;
    END IF;
    IF to_regclass(format('public.%I', p_table)) IS NOT NULL THEN
        -- CHAIN-WALK-COST:按键列自己的类型比(走主键索引),不拿整行的 to_jsonb 去 @>(一年 3 万张分录,每调一次整表扫约 20 ms;
        --   一段付薪分录的变更记录对一个看不见工资的读者要调它二十多次)。同一个判据:键里每一列等于那个值。键里有一列这张表已经没有了
        --   → 以前的 @> 对不上,这里也不查(落到下面的变更记录);值读不成那一列的类型 → 对不上(数据错误只在这一句里接住)。
        IF NOT EXISTS (SELECT 1 FROM jsonb_object_keys(p_key) k
                        WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a
                                           WHERE a.attrelid = format('public.%I', p_table)::regclass AND a.attname = k AND NOT a.attisdropped)) THEN
            BEGIN
                EXECUTE format('SELECT to_jsonb(t) ->> %L FROM public.%I t WHERE %s LIMIT 1', p_field, p_table,
                               (SELECT string_agg(format('t.%I = %L', e.key, e.value), ' AND ') FROM jsonb_each_text(p_key) e))
                   INTO v;
            EXCEPTION WHEN data_exception THEN
                v := NULL;
            END;
        END IF;
        IF v IS NOT NULL THEN
            RETURN v;
        END IF;
    END IF;
    SELECT COALESCE(c.new ->> p_field, c.old ->> p_field) INTO v
      FROM change_log c
     WHERE c.table_name = p_table AND c.row_key = p_key
       AND COALESCE(c.new ->> p_field, c.old ->> p_field) IS NOT NULL
     ORDER BY c.seq DESC
     LIMIT 1;
    RETURN v;
END;
$function$;

-- ── db/functions/record_trail.sql ──
-- db/functions/record_trail.sql
-- AUDIT-TRAIL-1a(Tim 的 Q1–Q6 · Q12 · Q13 · Q17 · Q40):一页底部"Audit trail"的【唯一】读法。
--
-- 【页面只说"哪一种记录、哪一条"】p_subject 是 trail_subjects() 里的一个主语,不是表名;p_id 是那条记录的 id。
--   不认识的主语 → TRAIL_SUBJECT_UNKNOWN。页面自己的查看权限码不在身上、或那条根记录过不了它自己那张表的读规则
--   (包括根本不存在)→ TRAIL_NOT_PERMITTED。★ 拒绝一律 RAISE,【绝不返回空列表】—— 空列表读起来是"什么都没发生过"。
--
-- 【哪些行】根行 + trail_subject_members() 登记的子行、孙行、相关行(Q3)。子行是【读的时候】找的(Q6):
--   今天还在的行按外键查;删掉了的、或父键被改过的,从 change_log 的影像里查(两条 GIN 部分索引)。
--   ☞ 为什么不能只按影像里的外键找:一次编辑只记改了的那几列,改一条明细行的单价,那一行记录里没有 purchase_order_id。
--     所以先收齐【这条记录有哪些行的主键】,再按 (表, 主键) 取那些行的全部记录。
--
-- 【每一行再过一次它自己那张表的读规则】(Q4)trail_row_visible。过不了的行照样占一个位置(时间还在),
--   其余一律为空、row_hidden = true —— 界面在"做了什么"与"谁"的位置印 Restricted。
-- 【遮蔽】过得了的行走 change_log_mask_row —— 与 /settings/change-history 同一步、同一份 HISTORY-1 规则,不加规则。
--
-- 【一次操作 = 一笔事务 = 一条记录】(Q2)按 txid 分组,entry_no 从新到旧编号。
-- 【变更记录开始之前】(Q1)trail_prelog_sources() 登记的领域历史与生命周期戳,凡是早于 change_log_began_at() 的,
--   拼成 prelog = true 的行(没有 seq);同一时刻写下的归成一条(同一笔事务的 now() 相同)。它们永远排在所有
--   变更记录之后,界面在两者之间画分界线。change_log 已经记着的(那一行的 INSERT、那一戳的改动)一律不再拼 —— 不会出现两次。
--
-- 【每一行带回】actor(trail_actor)、ctx(这一行今天的样子,已遮蔽 —— 子行的"第几行、哪个物料"从这里取)、
--   refs(trail_refs:每一个指着别处的值 → 名字)。界面把这些造成英文句子(Q40)。
-- 【分页】p_entries 条记录(默认 20,1..500),more 说后面还有没有更旧的。
-- 【SECURITY DEFINER 的理由】change_log 对应用角色没有任何授权(HISTORY-1);读权限在函数体里由上面三道判定。
--
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M1–M6):
--   M1 一页可以认【任一】个码(trail_subjects.view_codes;has_any_permission)。
--   M2 "记录开始之前"的人可以记成员工 id(trail_prelog_sources.by_kind = 'employee')—— 交给 trail_actor 的员工那一格。
--   M3 root_rule = 'page':页面的码就是门,根行不再过它自己那张表的读规则;根行自己的改动照子行的规矩逐行判(Q4)。
--   M4 hop = 'up':从一行往上走到它指着的那一行(批次 → 消耗它的加工单);shown = false 的是【垫脚石】——
--      只用来够到它下面的行,它自己不进审计记录,也不判读规则、不拼"之前"那一段(Q4:只限碰到这条记录的事)。
--   M5 根键按根行【自己的类型】重建(jsonb_build_object(root_key, image -> root_key)):单行设置表的主键是
--      boolean,change_log 里存的是 {"id": true};按文字 'true' 去对,永远对不上 —— 审计记录会【空着而不报错】。
--   M6 root_columns 非空:根行只取这几列(改动取交集,一列都不沾的那次改动整条不算;新增 / 删除的影像只留这几列)。
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 的 Q3 · Q16):
--   M7 hop = 'all'(fk_column 为空):一张【没有外键】的表整张属于一个单行设置主语 —— 那张表今天的每一行,加上 change_log
--      里它的每一行(按 match 过滤)。只在父表就是这个主语的根表时生效(一个单行设置表:M5 的那一种);挂在别处的一行
--      'all' 不展开任何东西。第一个用户是 1c-3 的锁期面板(月结 / 反结的 period_closes 与 finance_settings 之间
--      一个键都没有);本刀先建好,fixture 241 用一个临时主语证它。
--   Q16 op_key:每一行带回它属于哪一次操作 —— 记录开始之后是那笔事务('L' || txid),之前是那一刻('P' || 时刻)。
--      entry_no 只在【一条】记录里排得出先后;一个清单页把几条记录合起来时(ListTrail),同一次操作碰到几条记录就会
--      各出一条 —— 一次批量录汇率是 N 条、一次冻结预测(新一张 + 旧一张作废)是两条。op_key 让它们并成一条。
--      ☞ 返回列多了一列,CREATE OR REPLACE 换不了返回类型 —— 迁移里是 DROP + CREATE(同一笔事务;授权由
--        apply_migration.sh 回放 zzz_function_grants 给回去)。
-- AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 的 Q20):
--   M8 view_codes 为【空数组】:这一个主语没有页面码 —— 根行自己那张表的读规则就是唯一的门(/me 上报销人读自己那几张报销单:
--      expense_claims 的读规则是 module.finance.view 或者【这张单说的就是你】)。只许与 root_rule = 'table' 同用:
--      空的码配 'page' 等于对每一个登录的人敞开,所以那样登记的主语一律 TRAIL_NOT_PERMITTED。NULL 不是"没有码",照旧被拒。
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q2–Q5 —— M9 · M10 · M11 · M12):
--   M9  根表可以是一张【只在变更记录里出现】的表(trail_log_only_tables():auth.users)—— trail_current_image 读它那一份
--       安全投影,trail_row_visible 用登记表里声明的码判;它的"建立"在记录开始之后是一行 ACCOUNT_CREATE,不是 INSERT,
--       所以"记录开始之前"那一段的建立在两者任一存在时都不再拼(否则账号建立会说两次)。
--   M10 成员可以【只取声明的几列】(trail_member_columns(),M6 用在成员上):一次改动一列都不沾 → 不算;沾了 → 只留这几列;
--       之前那一段只拼落在这几列上的戳,不拼那一行的建立。根行的 root_columns 是同一条路(下标 1)。
--   M11 root_rule = 'collection':一个【集合】主语 —— 没有根行;那张表今天的每一行,加上 change_log 里它的每一行,都属于
--       这条记录,每一行各过它自己的读规则(Q4)。p_id 不用。假期表、六本字典、假别、评分刻度(AT-1d Step 0 的 Q4)。
--   M12 root_rule = 'gate:<名字>':根行先过它那张表的读规则('table' 那一道),【再】过 trail_root_gate 点名的那一道 ——
--       比表的规则更窄(/my-reviews 只给审核人,不给被评审的人)。与 M8(没有页面码)同用是允许的:门比 'table' 更窄,
--       不会更宽。
-- CHAIN-WALK-COST(v1.4.80,Tim 2026-10-28 scope C):一页的代价跟着【这一页画出来的那几行】走,不跟着【这条记录的全部成员行】走。
--   ① 成员按外键找时按那一列自己的类型比(以前 `t.col::text = ANY(…)` 用不上索引,一年体量上每个成员一次整表扫);
--   ② "记录开始之前"那一段只在排得进这一页时才拼;③ 每一行的读规则、今天的样子与名字只为这一页画出来的行算一次。
--   编号、more、每一行的内容与以前逐字相同 —— 对线上数据的拷贝与一年体量的种子,七个角色逐行比过(docs/surveys/CHAIN-WALK-COST/readings/)。
CREATE OR REPLACE FUNCTION public.record_trail(p_subject text, p_id text, p_entries integer DEFAULT 20)
 RETURNS TABLE(entry_no integer, prelog boolean, seq bigint, occurred_at timestamp with time zone, table_name text, row_key jsonb, op text, actor jsonb, changed_columns text[], old jsonb, new jsonb, ctx jsonb, refs jsonb, row_hidden boolean, row_restricted boolean, more boolean, op_key text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    s        record;
    m        record;
    p        record;
    r        record;
    v_limit  integer := LEAST(GREATEST(COALESCE(p_entries, 20), 1), 500);
    v_root   jsonb;
    v_img    record;
    v_tabs   text[] := ARRAY[]::text[];
    v_keys   jsonb[] := ARRAY[]::jsonb[];
    v_vis    boolean[] := ARRAY[]::boolean[];
    v_ctx    jsonb[] := ARRAY[]::jsonb[];
    v_crefs  jsonb[] := ARRAY[]::jsonb[];
    v_rr     jsonb;
    v_pids   text[];
    v_pk     text[];
    v_found  jsonb[];
    v_found2 jsonb[];
    v_k      jsonb;
    i        integer;
    v_pseudo jsonb := '[]'::jsonb;
    v_at     timestamptz;
    v_cols   text[];
    v_new    jsonb;
    v_op     text;
    v_mask   jsonb;
    v_began  timestamptz := change_log_began_at();
    v_total  integer;
    v_shown  boolean[] := ARRAY[]::boolean[];
    v_rcols  text[];
    v_fkv    text[];
    v_cimg   record;
    v_icols  jsonb[] := ARRAY[]::jsonb[];
    v_mcols  jsonb;
    v_c      text[];
    v_coll   boolean;
    v_gate   text;
    v_fktype text;
    v_lcount integer;
    v_dec    boolean[];
    v_have   jsonb := '{}';
BEGIN
    SELECT ts.* INTO s FROM trail_subjects() ts WHERE ts.subject = p_subject;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRAIL_SUBJECT_UNKNOWN|%', COALESCE(p_subject, '');
    END IF;
    v_coll := s.root_rule = 'collection';
    v_gate := CASE WHEN s.root_rule LIKE 'gate:%' THEN substr(s.root_rule, 6) END;
    IF cardinality(s.view_codes) = 0 THEN
        -- M8:没有页面码 —— 根行的读规则是门,而那只在 'table'(或比它更窄的 M12 门)时才问
        IF s.root_rule IS DISTINCT FROM 'table' AND v_gate IS NULL THEN
            RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;
        END IF;
    ELSIF NOT has_any_permission(s.view_codes) THEN
        RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;
    END IF;
    v_rcols := s.root_columns;
    IF v_coll THEN
        -- M11:集合 —— 那张表今天的每一行 + change_log 里它的每一行;没有根行,每一行各过它自己的读规则
        v_pk := trail_pk_columns(s.root_table);
        EXECUTE format('SELECT array_agg(jsonb_build_object(%s)) FROM public.%I t',
                       (SELECT string_agg(format('%L, t.%I', c, c), ', ') FROM unnest(v_pk) c), s.root_table)
           INTO v_found;
        SELECT array_agg(DISTINCT c.row_key) INTO v_found2
          FROM change_log c WHERE c.table_name = s.root_table AND c.row_key IS NOT NULL;
        FOR v_k IN SELECT DISTINCT x FROM unnest(COALESCE(v_found, ARRAY[]::jsonb[]) || COALESCE(v_found2, ARRAY[]::jsonb[])) x
                    WHERE x IS NOT NULL LOOP
            v_tabs := array_append(v_tabs, s.root_table);
            v_keys := array_append(v_keys, v_k);
            v_shown := array_append(v_shown, true);
            v_icols := array_append(v_icols, NULL::jsonb);
        END LOOP;
    ELSE
        v_root := jsonb_build_object(s.root_key, p_id);
        SELECT * INTO v_img FROM trail_current_image(s.root_table, v_root);
        IF v_img.image IS NULL
           OR ((s.root_rule = 'table' OR v_gate IS NOT NULL) AND NOT trail_row_visible(s.root_table, v_root, v_img.image))
           OR (v_gate IS NOT NULL AND NOT trail_root_gate(v_gate, s.root_table, v_img.image)) THEN
            RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;
        END IF;
        -- M5:根键按它自己的类型重建(boolean / 数字主键),否则与 change_log 的 row_key 永远对不上
        IF v_img.image ? s.root_key THEN
            v_root := jsonb_build_object(s.root_key, v_img.image -> s.root_key);
        END IF;
        v_tabs := ARRAY[s.root_table];
        v_keys := ARRAY[v_root];
        v_shown := ARRAY[true];
        v_icols := ARRAY[to_jsonb(v_rcols)];
    END IF;

    SELECT coalesce(jsonb_object_agg(u.t || '|' || u.k::text, true), '{}') INTO v_have FROM unnest(v_tabs, v_keys) AS u(t, k);
    -- ① 这条记录有哪些行(按 ord 展开,孙行在父行之后;hop = 'up' 往上走一跳,shown = false 的只作垫脚石)
    FOR m IN SELECT tm.* FROM trail_subject_members() tm WHERE tm.subject = p_subject ORDER BY tm.ord LOOP
        v_found := NULL;
        v_found2 := NULL;
        IF m.hop = 'all' THEN
            -- M7:整张表属于这个单行设置主语(父表必须就是根表)
            CONTINUE WHEN m.parent_table IS DISTINCT FROM s.root_table;
            v_pk := trail_pk_columns(m.table_name);
            EXECUTE format('SELECT array_agg(jsonb_build_object(%s)) FROM public.%I t WHERE to_jsonb(t) @> $1',
                           (SELECT string_agg(format('%L, t.%I', c, c), ', ') FROM unnest(v_pk) c), m.table_name)
               INTO v_found USING m.match;
            SELECT array_agg(DISTINCT c.row_key) INTO v_found2
              FROM change_log c
             WHERE c.table_name = m.table_name AND c.row_key IS NOT NULL AND COALESCE(c.new, c.old) @> m.match;
        ELSIF m.hop = 'up' THEN
            -- 父行今天那份(或它最后一份影像)里的那一列 → 被指着的那一行的 id
            v_fkv := ARRAY[]::text[];
            FOR v_k IN SELECT u.k FROM unnest(v_tabs, v_keys) AS u(t, k) WHERE u.t = m.parent_table LOOP
                SELECT * INTO v_cimg FROM trail_current_image(m.parent_table, v_k);
                IF v_cimg.image ->> m.fk_column IS NOT NULL THEN
                    v_fkv := array_append(v_fkv, v_cimg.image ->> m.fk_column);
                END IF;
            END LOOP;
            CONTINUE WHEN cardinality(v_fkv) = 0;
            SELECT array_agg(DISTINCT jsonb_build_object('id', x.v)) INTO v_found
              FROM unnest(v_fkv) AS x(v)
             WHERE (trail_current_image(m.table_name, jsonb_build_object('id', x.v))).image @> m.match;
        ELSE
            -- MES-4a:父行的键不叫 id 而只有一列(operation_types 的 code)时,用那一列的值 —— 成员按它挂(operation_type_code)。
            --   今天所有带成员的主语,父行键都是 id,所以它们的行为一个字不变;多列键的父行仍然不往下走。
            SELECT array_agg(DISTINCT COALESCE(u.k ->> 'id', (SELECT e.value FROM jsonb_each_text(u.k) e))) INTO v_pids
              FROM unnest(v_tabs, v_keys) AS u(t, k)
             WHERE u.t = m.parent_table AND (u.k ? 'id' OR (SELECT count(*) FROM jsonb_object_keys(u.k)) = 1);
            CONTINUE WHEN v_pids IS NULL;
            v_pk := trail_pk_columns(m.table_name);
            -- CHAIN-WALK-COST:按那一列【自己的类型】比(把父键数组转成它的类型),不把列转成文字 —— `t.col::text = ANY(…)` 用不上索引,
            --   一年体量上每个成员一次整表扫(库存移动 6 万行 88 ms);父键与外键同一个类型,所以转换不会失败,答案逐行不变。
            SELECT format_type(a.atttypid, a.atttypmod) INTO v_fktype
              FROM pg_attribute a WHERE a.attrelid = format('public.%I', m.table_name)::regclass AND a.attname = m.fk_column AND NOT a.attisdropped;
            EXECUTE format('SELECT array_agg(jsonb_build_object(%s)) FROM public.%I t WHERE t.%I = ANY ($1::%s[]) AND to_jsonb(t) @> $2',
                           (SELECT string_agg(format('%L, t.%I', c, c), ', ') FROM unnest(v_pk) c),
                           m.table_name, m.fk_column, v_fktype)
               INTO v_found USING v_pids, m.match;
            IF cardinality(v_pids) <= 20 OR m.match ? m.fk_column THEN
                SELECT array_agg(DISTINCT c.row_key) INTO v_found2
                  FROM unnest(v_pids) AS pid(v)
                  JOIN change_log c ON c.table_name = m.table_name
                                   AND (COALESCE(c.new, c.old) @> (jsonb_build_object(m.fk_column, pid.v) || m.match)
                                        OR (c.op = 'UPDATE' AND c.old @> jsonb_build_object(m.fk_column, pid.v)));
            ELSE
                -- CHAIN-WALK-COST:父行多的时候(一张月结对账单 800 多行)每一个父键一次 GIN 查找要 1 ms 多;改成把这张表的变更记录
                --   按 (table_name, row_key) 索引扫一遍、一次对着全部父键筛 —— 同一个判据:影像里那一列的值等于某一个父键(JSON 字符串),
                --   并且影像包含 m.match;或者是一次 UPDATE、它的旧影像里那一列等于某一个父键。(m.match 自己点了那一列的名时
                --   以前那一句让 match 盖掉父键 —— 那种登记今天 0 条,遇到了就走上面那一支,逐字是以前的判据。)
                SELECT array_agg(DISTINCT c.row_key) INTO v_found2
                  FROM change_log c
                 WHERE c.table_name = m.table_name
                   AND (((COALESCE(c.new, c.old) -> m.fk_column) IN (SELECT to_jsonb(x.v) FROM unnest(v_pids) AS x(v))
                         AND COALESCE(c.new, c.old) @> m.match)
                        OR (c.op = 'UPDATE' AND (c.old -> m.fk_column) IN (SELECT to_jsonb(x.v) FROM unnest(v_pids) AS x(v))));
            END IF;
        END IF;
        -- M10:这一个成员只取声明的几列(NULL = 整行)
        SELECT to_jsonb(mc.columns) INTO v_mcols FROM trail_member_columns() mc WHERE mc.subject = p_subject AND mc.ord = m.ord;
        -- CHAIN-WALK-COST:整组加进来(一张月结对账单八百多行时,逐行 array_append 每一次都把已收的数组整份复制一遍);
        --   顺序仍是那一句 SELECT DISTINCT 给出的顺序,已经收过的(键集 v_have)不再收。
        SELECT coalesce(array_agg(z.x ORDER BY z.o), ARRAY[]::jsonb[]) INTO v_found
          FROM (SELECT d.x, row_number() OVER () AS o
                  FROM (SELECT DISTINCT x FROM unnest(COALESCE(v_found, ARRAY[]::jsonb[]) || COALESCE(v_found2, ARRAY[]::jsonb[])) x
                         WHERE x IS NOT NULL) d) z
         WHERE NOT v_have ? (m.table_name || '|' || z.x::text);
        IF cardinality(v_found) > 0 THEN
            v_have := v_have || (SELECT jsonb_object_agg(m.table_name || '|' || x::text, true) FROM unnest(v_found) x);
            v_tabs := v_tabs || array_fill(m.table_name, ARRAY[cardinality(v_found)]);
            v_keys := v_keys || v_found;
            v_shown := v_shown || array_fill(m.shown, ARRAY[cardinality(v_found)]);
            v_icols := v_icols || array_fill(v_mcols, ARRAY[cardinality(v_found)]);
        END IF;
    END LOOP;

    -- ② "记录开始之前"那一段从哪里拼(Q1)—— CHAIN-WALK-COST:只在它【排得进这一页】时才拼
    --   编号规则不变(下面 ③):记录开始之后的每一条(按 txid)永远排在所有"之前"那一段前面。所以先数前者:超过 v_limit 条时,
    --   "之前"那一段一行都排不进这一页,more 也已经为真 —— 拼它只是白算(一年体量上每一行一次当前影像 + 一次登记表查询)。
    --   ★ 每一行的读规则、今天的样子与名字(v_vis / v_ctx / v_crefs)不在这里算了:挪到 ③ 的输出里,只为【这一页真的画出来的那几行】
    --     算一次(v_dec 记着算过没有)。同一个读法、同一份结果,只是不再为几百行看不见的成员行算。
    SELECT count(DISTINCT c.txid) INTO v_lcount
      FROM unnest(v_tabs, v_keys, v_shown, v_icols) u(t, k, sh, ic)
      JOIN change_log c ON c.table_name = u.t AND c.row_key = u.k
     WHERE u.sh AND (u.ic IS NULL OR jsonb_typeof(u.ic) <> 'array' OR c.op <> 'UPDATE'
                     OR c.changed_columns && ARRAY(SELECT jsonb_array_elements_text(u.ic)));
    v_vis := array_fill(NULL::boolean, ARRAY[cardinality(v_tabs)]);
    v_ctx := array_fill(NULL::jsonb, ARRAY[cardinality(v_tabs)]);
    v_crefs := array_fill(NULL::jsonb, ARRAY[cardinality(v_tabs)]);
    v_dec := array_fill(false, ARRAY[cardinality(v_tabs)]);
    FOR i IN 1 .. cardinality(v_tabs) LOOP
        EXIT WHEN v_lcount > v_limit;
        CONTINUE WHEN NOT v_shown[i];   -- 垫脚石:不拼"之前"(它自己不进这条记录)
        SELECT * INTO v_img FROM trail_current_image(v_tabs[i], v_keys[i]);
        CONTINUE WHEN v_img.image IS NULL OR v_img.gone;
        FOR p IN SELECT ps.* FROM trail_prelog_sources() ps WHERE ps.table_name = v_tabs[i] LOOP
            v_at := NULLIF(v_img.image ->> p.at_column, '')::timestamptz;
            CONTINUE WHEN v_at IS NULL OR v_at >= v_began;
            -- M6 · M10:根行 / 成员只管声明的那几列 —— 别的列上的戳不属于这一块;限了列的成员不拼它那一行的建立
            v_c := CASE WHEN v_icols[i] IS NULL OR jsonb_typeof(v_icols[i]) <> 'array' THEN NULL
                        ELSE ARRAY(SELECT jsonb_array_elements_text(v_icols[i])) END;
            CONTINUE WHEN v_c IS NOT NULL AND ((p.kind = 'stamp' AND NOT (p.at_column = ANY (v_c))) OR (p.kind = 'created' AND i > 1));
            IF p.kind = 'created' THEN
                -- M9:登记的只在变更记录里出现的表,建立那一下记成 ACCOUNT_CREATE(record_account_event),不是 INSERT
                CONTINUE WHEN EXISTS (SELECT 1 FROM change_log c
                                       WHERE c.table_name = v_tabs[i] AND c.row_key = v_keys[i] AND c.op IN ('INSERT', 'ACCOUNT_CREATE'));
                v_op := 'INSERT';
                v_cols := NULL;
                v_new := v_img.image;
            ELSE
                CONTINUE WHEN EXISTS (SELECT 1 FROM change_log c
                                       WHERE c.table_name = v_tabs[i] AND c.row_key = v_keys[i]
                                         AND (p.at_column = ANY (c.changed_columns)
                                              OR (c.op = 'INSERT' AND c.new ->> p.at_column IS NOT NULL)));
                v_op := 'UPDATE';
                v_cols := ARRAY[p.at_column] || COALESCE(ARRAY[p.by_column], ARRAY[]::text[]) || COALESCE(p.extra, ARRAY[]::text[]);
                v_cols := ARRAY(SELECT c FROM unnest(v_cols) c WHERE c IS NOT NULL);
                SELECT jsonb_object_agg(c, v_img.image -> c) INTO v_new FROM unnest(v_cols) c WHERE v_img.image ? c;
            END IF;
            v_pseudo := v_pseudo || jsonb_build_array(jsonb_build_object(
                'i', i, 'at', v_at, 'op', v_op, 'cols', to_jsonb(v_cols), 'new', v_new,
                'account', CASE WHEN p.by_column IS NULL OR p.by_kind = 'employee' THEN NULL ELSE v_img.image -> p.by_column END,
                'employee', CASE WHEN p.by_column IS NOT NULL AND p.by_kind = 'employee' THEN v_img.image -> p.by_column END));
        END LOOP;
    END LOOP;

    -- ③ 变更记录 + 拼回来的那一段,按记录(事务)编号,从新到旧
    -- 记录总数 = 记录开始之后的那几条 + "之前"那一段的几个时刻(与以前那一句 UNION 计数同一个集合:'L' 与 'P' 两种前缀不会相撞)
    SELECT v_lcount + count(DISTINCT x ->> 'at') INTO v_total FROM jsonb_array_elements(v_pseudo) x;

    FOR r IN
        WITH k AS (
            SELECT u.t, u.k, u.ic, u.i::integer AS i FROM unnest(v_tabs, v_keys, v_shown, v_icols) WITH ORDINALITY u(t, k, sh, ic, i) WHERE u.sh),
        allr AS (
            SELECT c.seq AS a_seq, c.occurred_at AS a_at, 'L' || c.txid AS a_g, k.i AS a_i, c.op AS a_op,
                   c.actor_kind AS a_kind, c.actor_account AS a_account, c.actor_employee AS a_employee,
                   c.changed_columns AS a_cols, c.old AS a_old, c.new AS a_new, false AS a_pre
              FROM k JOIN change_log c ON c.table_name = k.t AND c.row_key = k.k
             WHERE k.ic IS NULL OR jsonb_typeof(k.ic) <> 'array' OR c.op <> 'UPDATE'
                OR c.changed_columns && ARRAY(SELECT jsonb_array_elements_text(k.ic))
            UNION ALL
            SELECT NULL::bigint, (x ->> 'at')::timestamptz, 'P' || (x ->> 'at'), (x ->> 'i')::integer, x ->> 'op',
                   'prelog', (x ->> 'account')::uuid, (x ->> 'employee')::uuid,
                   CASE WHEN jsonb_typeof(x -> 'cols') = 'array'
                        THEN ARRAY(SELECT jsonb_array_elements_text(x -> 'cols')) END,
                   NULL::jsonb, x -> 'new', true
              FROM jsonb_array_elements(v_pseudo) x),
        ent AS (
            SELECT a_g AS e_g, bool_or(a_pre) AS e_pre, max(a_seq) AS e_mx, max(a_at) AS e_at FROM allr GROUP BY a_g),
        num AS (
            SELECT e_g, row_number() OVER (ORDER BY e_pre, e_mx DESC NULLS LAST, e_at DESC, e_g)::integer AS e_n FROM ent)
        SELECT allr.*, num.e_n FROM allr JOIN num ON num.e_g = allr.a_g
         WHERE num.e_n <= v_limit
         ORDER BY num.e_n, allr.a_seq NULLS LAST, allr.a_i
    LOOP
        entry_no := r.e_n;
        prelog := r.a_pre;
        seq := r.a_seq;
        occurred_at := r.a_at;
        more := v_total > v_limit;
        op_key := r.a_g;
        IF NOT v_dec[r.a_i] THEN
            -- 这一行第一次出现在这一页上:过它自己那张表的读规则、取今天的样子(遮蔽之后)与名字 —— 与以前 ② 里那一段逐字同一个读法
            i := r.a_i;
            SELECT * INTO v_img FROM trail_current_image(v_tabs[i], v_keys[i]);
            v_vis[i] := (i = 1 AND NOT v_coll AND (s.root_rule = 'table' OR v_gate IS NOT NULL))
                        OR COALESCE(trail_row_visible(v_tabs[i], v_keys[i], v_img.image), false);
            IF v_vis[i] AND v_img.image IS NOT NULL THEN
                v_mask := change_log_mask_row(v_tabs[i], v_keys[i], NULL, v_img.image);
                v_ctx[i] := COALESCE(NULLIF(v_mask -> 'new', 'null'::jsonb), '{}'::jsonb) || jsonb_build_object('$gone', v_img.gone);
                v_crefs[i] := trail_refs(v_tabs[i], NULL, NULL, v_ctx[i]);
            ELSE
                v_ctx[i] := NULL::jsonb;
                v_crefs[i] := '{}'::jsonb;
            END IF;
            v_dec[i] := true;
        END IF;
        IF NOT v_vis[r.a_i] THEN
            table_name := NULL; row_key := NULL; op := NULL; actor := NULL; changed_columns := NULL;
            old := NULL; new := NULL; ctx := NULL; refs := NULL;
            row_hidden := true;
            row_restricted := true;
        ELSE
            table_name := v_tabs[r.a_i];
            row_key := v_keys[r.a_i];
            op := r.a_op;
            actor := trail_actor(r.a_kind, r.a_account, r.a_employee);
            changed_columns := r.a_cols;
            v_mask := change_log_mask_row(v_tabs[r.a_i], v_keys[r.a_i], r.a_old, r.a_new);
            old := NULLIF(v_mask -> 'old', 'null'::jsonb);
            new := NULLIF(v_mask -> 'new', 'null'::jsonb);
            -- M6 · M10:根行 / 限了列的成员只留声明的那几列
            IF v_icols[r.a_i] IS NOT NULL AND jsonb_typeof(v_icols[r.a_i]) = 'array' THEN
                v_c := ARRAY(SELECT jsonb_array_elements_text(v_icols[r.a_i]));
                changed_columns := CASE WHEN r.a_cols IS NULL THEN NULL
                                        ELSE ARRAY(SELECT c FROM unnest(r.a_cols) c WHERE c = ANY (v_c)) END;
                SELECT jsonb_object_agg(e.key, e.value) INTO old FROM jsonb_each(old) e WHERE e.key = ANY (v_c);
                SELECT jsonb_object_agg(e.key, e.value) INTO new FROM jsonb_each(new) e WHERE e.key = ANY (v_c);
            END IF;
            row_restricted := (v_mask ->> 'row_restricted')::boolean;
            ctx := v_ctx[r.a_i];
            -- 这一行今天那份的名字(每个主键只解析一次)+ 这一次记录里新旧值的名字,按列合并
            v_rr := trail_refs(v_tabs[r.a_i], old, new, NULL);
            SELECT COALESCE(jsonb_object_agg(kk, COALESCE(v_crefs[r.a_i] -> kk, '{}'::jsonb) || COALESCE(v_rr -> kk, '{}'::jsonb)),
                            '{}'::jsonb)
              INTO refs
              FROM (SELECT jsonb_object_keys(v_crefs[r.a_i]) AS kk UNION SELECT jsonb_object_keys(v_rr)) z;
            row_hidden := false;
        END IF;
        RETURN NEXT;
    END LOOP;
END;
$function$;

-- ── 自证(同一笔事务里;任一不成立整支回滚)────────────────────────────────────────────
DO $verify$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM pg_proc WHERE proname IN ('document_relation_arm_pairs', 'document_chain_step_admitted')
       AND pronamespace = 'public'::regnamespace AND NOT has_function_privilege('anon', oid, 'EXECUTE')
       AND has_function_privilege('authenticated', oid, 'EXECUTE');
    IF n <> 2 THEN RAISE EXCEPTION 'CHAIN_WALK_COST_VERIFY|两支新函数的执行权应当是 authenticated 有、anon 没有(% / 2)', n; END IF;
    SELECT count(*) INTO n FROM pg_proc p WHERE p.proname = 'document_chain_walk' AND p.prosrc LIKE '%document_relation_arm_pairs%';
    IF n <> 1 THEN RAISE EXCEPTION 'CHAIN_WALK_COST_VERIFY|document_chain_walk 不是新的那一支'; END IF;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
