-- db/migrations/2026-10-29-chain-walk-cost-fu1.sql
-- CHAIN-WALK-COST -fu1(同一个破窗之内,不新开一个;破窗起点仍是 2026-10-28 23:11:30 CST):document_chain_walk 回到【按对】读关联图。
--   线上一位一位的七角色证明(2026-10-29 00:16 起)量到:新走链在线上有一块每次约 0.8 秒的固定开销 —— 一张只有一行的柜子页 859 ms(以前 29.6 ms),
--   两次 DOCUMENT_CHAIN_WALK_BUDGET 拒绝(admin · 请假、cfo · 工单),而库那一侧的信号都正常。新走链唯一一块【每次都做、旧走链没有】的事,
--   是整次把这条链上全部表之间的边用一句 IN 筛出来(document_relations 是 pg_catalog 推出来的视图;按一对等值筛时规划器把桥边 / XOR 解析那几支整个剪掉,
--   用 IN 时它们照算;那一句还关掉了嵌套循环)。本地以今晚的线上数据冷连接量:请假 26.9 → 11.2 ms · 对账单 24.5 → 10.3 ms(旧走链 12.8 · 10.9)。
--   本迁移只换这一支函数(签名不变):每一对表的边按需【等值】读一次、整次记住,不再关嵌套循环。结果逐行不变(线上数据拷贝 1,939 / 1,939)。
-- 镜像:db/functions/document_chain_walk.sql,下面逐字是它。
BEGIN;

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

    -- ── 关联图:每一对表的边按需读一次、整次记住(v_edge)──────────────────────────────────
    --   ★ CHAIN-WALK-COST -fu1(2026-10-29):以前这里整次把这条链上所有表之间的边一次读出来(本地 12–19 ms),线上实测那一句是走链最贵的一块 ——
    --     一张只有一行的柜子页走链 859 ms(以前 29.6 ms),两次 2 秒上限拒绝。document_relations 是一张从 pg_catalog 推出来的视图,
    --     按【一对】表等值筛的时候规划器把用不到的那几支(桥边、XOR 解析)整个剪掉;用 IN 一次筛全部时它们照算。所以回到按对读(线上一直便宜的那一种),
    --     每一对整次只读一次。
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
                        FOR er IN SELECT * FROM public.document_relations dr WHERE dr.from_table = ef AND dr.to_table = et.table_name LOOP
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

DO $verify$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'document_chain_walk' AND prosrc NOT LIKE '%enable_nestloop%'
                                          AND prosrc LIKE '%document_relation_arm_pairs%') THEN
        RAISE EXCEPTION 'CHAIN_WALK_COST_FU1_VERIFY|document_chain_walk 不是 -fu1 那一支';
    END IF;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
