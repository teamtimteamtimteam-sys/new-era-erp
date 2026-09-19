-- db/migrations/2026-09-19-search5-related-rows-fu1.sql
-- SEARCH-5 · 跟进 1 —— 让【无主语】那一种形状在类型上也说得出口
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【它改的是什么:三个参数多了 DEFAULT NULL。函数体一个字节都没动。】
--
-- ★★【为什么这不是一次"为了让类型过关"的改动 —— 方向正好相反】★★
--   `supabase gen types` 按【有没有 DEFAULT】决定一个函数参数可不可省。
--   主迁移把 `p_key` / `p_id` 写成无默认值的必填参数,于是生成出来的类型是
--   `p_key: string` —— **它说的是「这两个参数永远有值」,而那句话是假的**:
--   这支函数的【无主语】那一种形状(那 5 种 `type_list` 单据的落点),
--   按设计就是两个都不给。
--   ☞ **类型没有错,是 SQL 没有把自己的意思说完整。**
--
--   ⚠ 另一条路是在调用点写一句 `as unknown as …Args` 把 null 塞进去。
--     **本仓库刚为那个形状付过一次账**(BUGFIX-1a:6 句 `as never` 挡住了
--     唯一看得见 `container_no` 这一列根本不存在的那道闸,一条死查询活了 8 天)。
--     一句 cast 关掉的是【整个参数对象】的检查 —— 下一个人把 `p_target_key`
--     拼错,`tsc` 会闭嘴。**所以改 SQL,不改类型。**
--
-- ★★【为什么 `p_target_key` 也跟着拿了默认值,而它【不是】可选的】★★
--   PostgreSQL 要求:带默认值的参数后面不许再有不带默认值的参数。
--   而参数的**顺序不能动** —— 动了就是一次【重载】而不是【替换】,
--   `preflight_migration.py` 会当场拒(FIN-21 那一条)。
--   ☞ 所以三个一起给默认值,而 `p_target_key` 缺席时**函数自己响**:
--     它读不到那一行,`SEARCH_UNKNOWN_DOCUMENT_TYPE|(null)` ——
--     **一次响亮的拒绝,不是一个空集。**
--
-- ★ 这【不是】签名变更:参数的类型与顺序逐字未变。预检应当报「1 替换 · 0 新建」。
-- ★ `CREATE OR REPLACE` 不重置 ACL;apply_migration.sh 仍在同一笔事务里
--   重放 zzz_function_grants.sql 兜底。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 破窗:本支在主迁移那个窗口【之内】,它自己不新开一个。
--   窗口里生产跑的是旧代码,而旧代码一次都不调这支函数 —— **本支零影响。**
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.search_related_rows(
    p_key        text    DEFAULT NULL,
    p_id         uuid    DEFAULT NULL,
    p_target_key text    DEFAULT NULL,
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
    '翻页是 keyset(code < p_after_code),不是 OFFSET;total 在翻页之前算。'
    '★ fu1:三个前导参数带 DEFAULT NULL —— 让【无主语】那一种形状在生成的类型里'
    '也可以省略,而不是在调用点写一句 cast 把整个参数对象的检查关掉。';

COMMIT;
