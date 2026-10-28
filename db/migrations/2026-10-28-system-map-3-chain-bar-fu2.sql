-- db/migrations/2026-10-28-system-map-3-chain-bar-fu2.sql
-- SYSTEM-MAP-3 -fu2(同一个破窗之内,不新开一个;Tim 2026-10-27 23:45 裁定 1):document_chain_walk() 一次最多占库 2 秒。
--   ★ 裁定的原话是「function-level SET statement_timeout = '2s'」—— 实测它【不管用】:statement_timeout 只在顶层语句开始时上弦,
--     函数级 SET 改的是这一句已经不再读的值(本地:SET statement_timeout TO '1s' 的函数 pg_sleep(3) 跑满 3000 ms、未被取消)。
--     所以上限由函数自己守:每一次关联查询之前看钟,过了 2 秒按名拒 DOCUMENT_CHAIN_WALK_BUDGET(app.chain_walk_budget_ms 可收紧;
--     fixture 296 T 臂设成 0 证它会拒)。签名与返回形状不变。只改一支函数 —— 没有新的备份:19:50 那一份早于三支迁移。
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
    v_len    integer;
    i        integer;
    v_sig    text;
    v_asked  text[] := '{}';
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

    -- ── 一圈一圈往外走,直到不再长 ─────────────────────────────────────────────
    --   一步的来源 = 它的相邻步骤里【不比它离读者更远】的那些(同一圈的也算:销售那一条的"预留"与"发货"同在第一圈,
    --   发货要从预留那一侧也找得到)。一圈之内谁先谁后不决定答案:整张图再走一遍,直到这一遍一行都没有加。
    --   上限 n + 1 遍(每一遍至少加一行才会有下一遍,而步骤只有 n 个、行有限)。
    --   ★ 每一组(目标步骤, 来源单据, 目标种类)整次只问一遍(v_asked)—— 后一遍只问新长出来的那几张(SYSTEM-MAP-3 实测:
    --     不记的话第二遍把第一遍全部重问一次,七个读者并行时撞上 authenticated 的 8 秒语句上限)。
    FOR v_pass IN 1 .. n + 1 LOOP
        v_added := 0;
        FOR j IN SELECT g.i - 1 FROM generate_subscripts(dist, 1) AS g(i)
                  WHERE dist[g.i] > 0 ORDER BY dist[g.i], g.i LOOP
            SELECT coalesce(array_agg(DISTINCT x.s), '{}') INTO v_src
              FROM (SELECT CASE WHEN (ed->>0)::integer = j THEN (ed->>1)::integer ELSE (ed->>0)::integer END AS s
                      FROM jsonb_array_elements(v_edges) ed
                     WHERE (ed->>0)::integer = j OR (ed->>1)::integer = j) x
             WHERE dist[x.s + 1] >= 0 AND dist[x.s + 1] <= dist[j + 1];

            FOR t IN SELECT jsonb_array_elements_text(v_steps->j->'keys') LOOP
                CONTINUE WHEN NOT (t = ANY (v_live));
                v_len := cardinality(f_step);
                FOR i IN 1 .. v_len LOOP
                    CONTINUE WHEN NOT (f_step[i] = ANY (v_src));
                    IF clock_timestamp() - v_t0 > v_budget THEN
                        RAISE EXCEPTION 'DOCUMENT_CHAIN_WALK_BUDGET|走了 % 毫秒,上限 % 毫秒 —— 这一条链这一次没有画完',
                            round(extract(epoch FROM clock_timestamp() - v_t0) * 1000), round(extract(epoch FROM v_budget) * 1000);
                    END IF;
                    -- 键带上目标步骤:同一种单据在几步上(进料批 → 定价 → 应付),每一步各问一次
                    v_sig := j::text || '|' || f_key[i] || '|' || f_id[i]::text || '|' || t;
                    CONTINUE WHEN v_sig = ANY (v_asked);
                    v_asked := v_asked || v_sig;
                    -- 同一种单据在两步上 = 它自己(不经关联图);否则经关联图走一跳
                    FOR r IN
                        SELECT f_id[i] AS id, f_code[i] AS code, f_label[i] AS label WHERE f_key[i] = t
                    LOOP
                        CONTINUE WHEN EXISTS (SELECT 1 FROM unnest(f_step, f_id) AS h(hs, hi) WHERE h.hs = j AND h.hi = r.id);
                        IF public.document_chain_step_admits(v_steps->j->>'filter', r.id) THEN
                            f_step := f_step || j; f_key := f_key || t; f_id := f_id || r.id;
                            f_code := f_code || r.code; f_label := f_label || r.label;
                            v_added := v_added + 1;
                        END IF;
                    END LOOP;
                    CONTINUE WHEN f_key[i] = t;
                    FOR r IN
                        SELECT q.id, q.code, q.label FROM public.search_related_rows(f_key[i], f_id[i], t, 100, NULL) q
                    LOOP
                        CONTINUE WHEN EXISTS (SELECT 1 FROM unnest(f_step, f_id) AS h(hs, hi) WHERE h.hs = j AND h.hi = r.id);
                        IF public.document_chain_step_admits(v_steps->j->>'filter', r.id) THEN
                            f_step := f_step || j; f_key := f_key || t; f_id := f_id || r.id;
                            f_code := f_code || r.code; f_label := f_label || r.label;
                            v_added := v_added + 1;
                        END IF;
                    END LOOP;
                END LOOP;
            END LOOP;
        END LOOP;
        EXIT WHEN v_added = 0;
    END LOOP;

    RETURN QUERY
    SELECT u.st, u.k, u.i, u.c, u.l, public.document_detail_href(u.k, u.i)
      FROM unnest(f_step, f_key, f_id, f_code, f_label) AS u(st, k, i, c, l)
     ORDER BY u.st, u.c DESC;
END;
$function$;

COMMENT ON FUNCTION public.document_chain_walk(jsonb, integer, text, uuid) IS
    'SYSTEM-MAP-3:单据链条的取数 —— 从读者站的那一步往外,经关联图(外键边 + 声明的边)一圈一圈走;'
    '同一种单据在两步上是它自己;带判据的步骤只认存在的那几张。INVOKER —— 每一跳由 RLS 回答。';

NOTIFY pgrst, 'reload schema';

COMMIT;
