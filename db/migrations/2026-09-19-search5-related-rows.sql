-- db/migrations/2026-09-19-search5-related-rows.sql
-- SEARCH-5 · 可点击的关联分组 —— 【取行】那一支,以及那 5 种单据的落点
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【这一刀的两件事,而它们【不是】同一个族,所以分开说】
--   ① `search_related_rows()` —— **纯增量**:一支新函数,不改任何现有对象。
--   ② `document_types.link_mode` 加一个取值 `'type_list'`,并把 5 行重新指向 ——
--      ★ **这一半【改了一个既有对象】**(那条 CHECK 约束)与【5 行既有数据】。
--
-- ☞ **所以破窗不是"什么都不会坏"。** 委托书写的是「一个增量函数,什么都没改」,
--   而 Tim 的 W1 把第 ② 件折了进来,**它把这一刀从 A/C/D 族挪到了 B 族的边上**。
--   窗口里【具体什么是坏的】,逐字写在下面「破窗」那一节,不写"良性"两个字。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 一 · `search_related_rows()` —— 与 `search_related()` 同一段边→SQL 翻译
-- ════════════════════════════════════════════════════════════════════════════
--
-- ★★【为什么是兄弟函数,不是给 `search_related()` 加参数】★★(停止闸 Q3)
--   计数那一路今天有调用点在依赖它的签名,而改签名会撞上 `preflight_migration.py`
--   的「重载不是替换」那条拒绝。一支函数两种返回形状,还要在每个调用点上
--   回答"这一次它返回的是哪一种"。
--
-- ★★【为什么【不是】在 TypeScript 里读 document_relations 自己拼查询】★★
--   那是把边→SQL 那段翻译写第二遍,而本仓库为"两份实现在写下来那天一致、
--   之后悄悄分开"付过四次账。**这一支逐字抄的就是 search_related() 里那两个
--   `format()`** —— 同一张视图、同一套占位符、同一条 `shared` 前缀过滤、
--   同一条自指排除。两份文本长得一样【不是】巧合,是判据:
--   `db/fixtures/199` 钉住「同一个 (key,id,target_key),行数 == 计数」。
--
-- ★ INVOKER —— 与 `search_related()` 逐字同一条理由:
--   「你看得见几条」正是 RLS 天生回答的问题。在应用层再判一次就是把同一条
--   规则写第二遍。**DEFINER 只属于 `search_documents_withheld()`**,
--   因为「你**看不见**几条」RLS 按构造答不了。
--
-- ★★【它比 search_related() 多读一列,而那一列【正是遮蔽存在的理由】】★★
--   `search_related()` 只取 `t.id, t.code` 两列;本支还要取 `label_column`。
--   ☞ 实测(2026-09-19,线上现读):39 张单据表里 **6 张对 `authenticated`
--     【没有表级 SELECT】**,只有列级授权(employees · inbound_batches ·
--     invoices · pricing_formulas · processing_runs · purchase_orders)。
--   ☞ 而实测 **31 个有 label_column 的种类,`code` 与 label 两列【全部】
--     对 authenticated 可读**(`has_column_privilege`,0 个缺口)。
--   ⚠ **那是一个【今天】的事实,而今天没有任何东西盯着它。** 一次撤掉某张
--     遮蔽表 label 列授权的改动,会让这一支对那一类单据【当场报错】,
--     而不是少显示一列。所以 fixture 199 的第 ⑤ 臂逐列断言它
--     —— AGENTS.md「给遮蔽表加一列要连授权一起加,否则它是隐形的」的另一半:
--     **给一支共享函数加一列要连授权一起断言,否则它是会爆的。**
--
-- ★ 排序键用 `code`,不用 `created_at`(AGING-1):`created_at DEFAULT now()`
--   记的是**事务**不是行,同一笔事务写进去的两行排不出先后;而 `code` 在每张
--   单据表上唯一。翻页用 keyset(`code < p_after_code`)而不是 `OFFSET` ——
--   取行那一段是 `UNION ALL` + `DISTINCT`,`OFFSET 480` 会把前 480 行算出来再扔掉。
--   ⚠ **理由是【形状】,不是一个读数。这一刀没有量任何毫秒数,也不打算量。**
--
-- ★ `total` 由 `count(*) OVER ()` 在【翻页之前】求出,与 `search_documents()`
--   逐字同一条:一个 `LIMIT n+1` 的写法只答得出"还有没有更多",答不出"还有几条"。
--
-- ★★【两种形状,而第二种是 Tim 的 W1 折进来的】★★
--   · **有主语**(p_key + p_id):「NMC 的产出批」—— 关联分组点开的那一页。
--   · **无主语**(两个都是 NULL):「化验单」—— 那 5 种命中链接的落点。
--   ☞ 两者【共用同一段取数与同一条分页】,差别只有一处:无主语那一臂不走
--     document_relations,它就是那张表自己。
--   ⚠ 只给一个、不给另一个 ⇒ **RAISE**。一次静默的「当成无主语」会把
--     "这个供应商的进料批"画成"全部进料批",而那两句话在屏幕上分不开。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 二 · `link_mode = 'type_list'` —— 那 5 种今天链到【永远 0 行】的单据
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【今天坏成什么样,实测,逐条】(SEARCH-5 停止闸 §4.2,本刀重量确认)
--   assay_result        → /inbound?q=ASY-…        而 /inbound 过滤的是 inbound_batches.code
--   cod                 → /output?q=COD-…         而 /output 过滤的是 output_batches.code
--   traceability_report → /output?q=TRC-…         同上
--   collection_chase    → /sales/customers?q=CHASE-… 而它过滤的是 customers 的五列
--   customer_statement  → /sales/customers?q=STMT-…  同上
--   ☞ 前缀一个都不重叠 ⇒ **结构上匹配不上**,不是"今天恰好没有"。
--     搜到一张化验单、点开,落在一张空列表上,屏幕上写着「没有符合条件的记录」。
--
-- ★ Tim 的裁定(W1):**它们重新指向本刀造的那一页**,而那一页对它们是
--   【无主语】的那一种形状 —— 一次命中点击说的是「化验单」,
--   不是「某某的化验单」。
--
-- ⚠ **顺带,它【收掉】了一处既存的披露**:这 5 种今天把单据号放在 `?q=` 里,
--   改完之后地址里只剩单据种类的 key。**本刀不扩大 URL 披露,反而少了 5 种。**
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★ 破窗 —— 【必填字段,写实情,不写"良性"】
-- ════════════════════════════════════════════════════════════════════════════
--   窗口 = 本迁移提交的时刻 → 部署 state=success 的时刻(由 apply_migration.sh 打点)。
--
--   窗口里生产跑的是【旧代码 + 新库】。逐条:
--   ① `search_related_rows()` —— 旧代码一次都不调它。**零影响。**
--   ② `link_mode` 的 CHECK 放宽 —— 只放宽,不收紧。**零影响。**
--   ③ ★ **那 5 行 `link_mode` 从 `'list_q'` 变成 `'type_list'`,而旧代码
--      【不认识】这个值。** `lib/search/records.ts` 的 `hrefFor()` 是一个
--      switch,`default:` 那一支返回 `row.route`。
--      ☞ **于是窗口期间,搜到这 5 种单据点开,落在【未过滤的】
--        /inbound · /output · /sales/customers 上。**
--      ★ 而这【比今天好】,不是比今天坏:今天落在一张 `?q=` 过滤到
--        **永远 0 行**的列表上;窗口里落在同一张列表的**未过滤**版本,
--        至少屏幕上有东西。**照直说:窗口里这 5 种的落点是错的,
--        而它错的方向与今天相反。**
--   ④ 其余 35 种单据的 link_mode 一个字没动。**零影响。**
--
--   ☞ 所以这不是「什么都不会坏」。它是:**一处已经坏了一周的落点,在窗口里
--     换了一种坏法,然后在部署那一刻被修好。**

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1 · link_mode 多一个取值
-- ════════════════════════════════════════════════════════════════════════════
-- ★ 放宽一条 CHECK:先删后建,同一笔事务里。表上今天 40 行,重扫代价可忽略。
ALTER TABLE public.document_types DROP CONSTRAINT document_types_link_mode_check;
ALTER TABLE public.document_types ADD CONSTRAINT document_types_link_mode_check
    CHECK (link_mode IN ('detail', 'list', 'list_q', 'type_list'));

COMMENT ON COLUMN public.document_types.link_mode IS
    'SEARCH-2b/SEARCH-5:一条命中点开去哪。四种,由 scripts/check-search-registry.mjs 核对。'
    '  detail    → <route>/<id>'
    '  list      → <route>'
    '  list_q    → <route>?q=<code>(那一页真的读 q,而且列的【就是这张表】)'
    '  type_list → /documents/<key> —— ★ SEARCH-5:登记路由上那张列表【不列这张表】'
    '              的那些种类。它们此前是 list_q,而 ?q= 指着别的表的 code,'
    '              前缀不重叠 ⇒ 结构上永远 0 行。';

-- ★ 那 5 种:逐条点名,不写一条 WHERE link_mode='list_q' AND … 的聪明写法 ——
--   一条按性质选行的 UPDATE,会在下一次某种单据碰巧满足那个性质时顺手改掉它。
UPDATE public.document_types SET link_mode = 'type_list'
 WHERE key IN ('assay_result', 'cod', 'traceability_report',
               'collection_chase', 'customer_statement');

-- ★ 覆盖断言:改了几行,当场数出来。一次改到 4 行或 6 行都必须响。
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM public.document_types WHERE link_mode = 'type_list';
    IF n <> 5 THEN
        RAISE EXCEPTION 'SEARCH5_LINK_MODE|改完之后 type_list 有 % 行,应当是 5 行 —— '
                        '一次改多了或改少了的迁移,与一次改对了的迁移在退出码上一样', n;
    END IF;
    -- 其余三种一个都不许被顺手改掉。
    SELECT count(*) INTO n FROM public.document_types WHERE link_mode = 'list_q';
    IF n <> 4 THEN
        RAISE EXCEPTION 'SEARCH5_LINK_MODE|list_q 剩 % 行,应当是 4 行'
                        '(inbound_batch · material · output_batch · supplier)', n;
    END IF;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 2 · search_related_rows()
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.search_related_rows(
    p_key        text,
    p_id         uuid,
    p_target_key text,
    p_limit      integer DEFAULT 20,
    p_after_code text    DEFAULT NULL)
 RETURNS TABLE(id uuid, code text, label text, total bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_table   text;
    v_target  record;
    e         record;
    parts     text[] := '{}';
    v_sel     text;
    v_where   text;
    v_after   text;
BEGIN
    -- ★【半个主语 = RAISE】一次静默的「当成无主语」会把「这个供应商的进料批」
    --   画成「全部进料批」,而那两句话在屏幕上分不开。
    IF (p_key IS NULL) <> (p_id IS NULL) THEN
        RAISE EXCEPTION 'SEARCH_RELATED_HALF_SUBJECT|p_key=% p_id=% —— '
                        '主语要么两个都给(有主语),要么两个都不给(无主语);'
                        '只给一个会把一份【全表列表】画成一份【某个主语的列表】',
                        coalesce(p_key, '(null)'), coalesce(p_id::text, '(null)');
    END IF;

    -- ★ 上限【响亮地】拒,不悄悄夹到范围里 —— 一次静默的截断与一次干净的读数,
    --   在屏幕上长得一模一样(本刀 §2 那次 44 行被丢掉的量具就是这么来的)。
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
        RAISE EXCEPTION 'SEARCH_RELATED_BAD_LIMIT|p_limit=% —— 只接受 1..100;'
                        '房子的 PAGE_SIZE 是 20(树里 17 处全是 20)',
                        coalesce(p_limit::text, '(null)');
    END IF;

    -- ── 目标单据种类 ────────────────────────────────────────────────────────
    SELECT d.key, d.table_name, d.prefix, d.label_column,
           (SELECT count(*) > 1 FROM public.document_types d2
             WHERE d2.table_name = d.table_name) AS shared
      INTO v_target
      FROM public.document_types d
     WHERE d.key = p_target_key;
    IF v_target.key IS NULL THEN
        -- 与 search_related() / document_type_prefix() 同一条:读不到就响。
        -- 一个"这张单据没有关联记录"的空态,和一个拼错的 key,在屏幕上分不开。
        RAISE EXCEPTION 'SEARCH_UNKNOWN_DOCUMENT_TYPE|% —— 它不在 document_types 里,'
                        '而一次拼错的 key 与一张真的没有关联的单据在屏幕上分不开',
                        coalesce(p_target_key, '(null)');
    END IF;

    -- ★ 9 种单据没有 label_column(登记表的事实,不是缺陷)——
    --   对它们只画单据号,**不拿别的东西顶上**(records.ts 的 toHit 同一条规矩)。
    v_sel := CASE WHEN v_target.label_column IS NULL
                  THEN 'NULL::text'
                  ELSE format('t.%I::text', v_target.label_column) END;

    IF p_key IS NOT NULL THEN
        -- ── 有主语:边→SQL,逐字与 search_related() 同一段 ──────────────────
        SELECT d.table_name INTO v_table
          FROM public.document_types d WHERE d.key = p_key;
        IF v_table IS NULL THEN
            RAISE EXCEPTION 'SEARCH_UNKNOWN_DOCUMENT_TYPE|% —— 它不在 document_types 里,'
                            '而一次拼错的 key 与一张真的没有关联的单据在屏幕上分不开', p_key;
        END IF;

        FOR e IN
            SELECT * FROM public.document_relations dr
             WHERE dr.from_table = v_table AND dr.to_table = v_target.table_name
        LOOP
            IF e.kind = 'bridge' THEN
                parts := parts || format(
                    'SELECT t.id, t.code, %s FROM public.%I v JOIN public.%I t ON t.%I = v.%I '
                    ' WHERE v.%I = (SELECT s.%I FROM public.%I s WHERE s.id = $1)',
                    v_sel, e.via_table, e.to_table, e.to_column, e.via_to_column,
                    e.via_from_column, e.from_column, e.from_table);
            ELSE
                -- 出边与入边在这里是【同一个形状】:出边的 from_column 是本表那一列,
                -- 入边的 from_column 是被指向的那一列(几乎总是 id)。
                parts := parts || format(
                    'SELECT t.id, t.code, %s FROM public.%I t '
                    ' WHERE t.%I = (SELECT s.%I FROM public.%I s WHERE s.id = $1)',
                    v_sel, e.to_table, e.to_column, e.from_column, e.from_table);
            END IF;
        END LOOP;

        -- ★ 结构上没有边 ⇒ 返回空集,**而这不是"今天没有行"**。
        --   两者的区别由调用方问 document_relations 分辨(它只要一句 EXISTS,
        --   不是第二份边→SQL 翻译),并且屏幕上是两句不同的话(停止闸 §4.6)。
        IF cardinality(parts) = 0 THEN RETURN; END IF;
    ELSE
        -- ── 无主语:那张表自己 ────────────────────────────────────────────
        -- ★ `WHERE $1 IS NULL` 不是凑数:它让这一臂也**真的用上** $1,
        --   于是两种形状走同一条 EXECUTE … USING,没有第二条路可以悄悄分叉。
        --   (半个主语在上面已经 RAISE 过,所以走到这里 p_id 必然是 NULL。)
        parts := parts || format(
            'SELECT t.id, t.code, %s FROM public.%I t WHERE $1 IS NULL',
            v_sel, v_target.table_name);
    END IF;

    v_where := 'TRUE';
    -- 一张表两个前缀(payments = RCPT + PMT):不加前缀过滤,同一条关联会在
    -- 两种单据下各数一次。与 search_related() / search_documents_sql() 同一条理由。
    IF v_target.shared THEN
        v_where := v_where || format(' AND u.code LIKE %L', v_target.prefix || '-%');
    END IF;
    -- 自指关系不把自己算成自己的关联记录。
    IF p_key IS NOT NULL AND v_target.table_name = v_table THEN
        v_where := v_where || ' AND u.id <> $1';
    END IF;

    -- ★ keyset:`code < $after`。**它在计数【之后】才生效** —— 否则第二页会
    --   报一个比第一页小的 total,而那读起来像"记录在减少"。
    v_after := CASE WHEN p_after_code IS NULL THEN 'TRUE'
                    ELSE format('c.code < %L', p_after_code) END;

    RETURN QUERY EXECUTE format(
        'WITH src AS ('
        '  SELECT DISTINCT ON (u.id) u.id, u.code, u.label'
        '    FROM (%s) u (id, code, label)'
        '   WHERE %s'
        '   ORDER BY u.id'
        '), counted AS ('
        '  SELECT s.id, s.code, s.label, count(*) OVER () AS total FROM src s'
        ') '
        'SELECT c.id, c.code, c.label, c.total FROM counted c'
        ' WHERE %s ORDER BY c.code DESC LIMIT %s',
        array_to_string(parts, E'\nUNION ALL\n'), v_where, v_after, p_limit)
      USING p_id;
END;
$function$;

COMMENT ON FUNCTION public.search_related_rows(text, uuid, text, integer, text) IS
    'SEARCH-5:一个关联分组【自己那几行】。与 search_related() 同一段边→SQL 翻译、'
    '同一张 document_relations、同一条前缀过滤、同一条自指排除,而且同为 INVOKER —— '
    '「你看得见几条」与「你看得见哪几条」必须是同一个答案(db/fixtures/199 钉住它)。'
    '两种形状:给主语 = 「NMC 的产出批」;不给主语 = 「化验单」(那 5 种 type_list 的落点)。'
    '翻页是 keyset(code < p_after_code),不是 OFFSET;total 在翻页之前算。';

-- ★ EXECUTE 的授权:`db/views/zzz_function_grants.sql` 是【重建】那一路的唯一出处,
--   而**线上不跑它** —— 一支刚建出来的函数拿的是 PostgreSQL 的默认(PUBLIC 可执行)。
--   所以迁移这一侧必须显式写,与 search_related() 那一支逐字同形。
REVOKE EXECUTE ON FUNCTION public.search_related_rows(text, uuid, text, integer, text)
    FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.search_related_rows(text, uuid, text, integer, text)
    TO authenticated, service_role;

COMMIT;
