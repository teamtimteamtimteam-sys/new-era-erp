-- ════════════════════════════════════════════════════════════════════════════
-- fixture 103 —— 【一条桥被作废,不等于那一组关系消失】(SEARCH-4 · §3.3)
-- ════════════════════════════════════════════════════════════════════════════
--
-- ★★ 这是本刀最容易安静出错的那一格,而它已经被量出来过一次 ★★
--   `expense_claims ↔ expenses` 经 `finance_attachments` 的那条桥**是假的**
--   (`num_nonnulls(sales_record_id, inbound_batch_id, payment_id, expense_id,
--     claim_id) = 1` —— 同一行上永远只有一个),
--   而它经 `expense_claims.expense_id` 的那条**直接外键是真的**。
--   ☞ **一支把整组关系一起删掉的筛子,会在这里安静地删掉一条真关系,
--     而没有任何东西会红。** 所以判据必须作用在【边】上,不能作用在【对】上,
--     而这份 fixture 就是那句话的看守。
--
-- 六臂:
--   A  假桥真的被作废:`inbound_batches ↔ output_batches` 不在图里
--      (它俩的关系走 processing_runs,两跳,裁定 ② 不许)。
--   B  ★ 而 `expense_claims ↔ expenses` **照样在图里** —— 靠那条直接外键。
--   C  两种 XOR 写法都认:`(a IS NULL) <> (b IS NULL)` 那两张表
--      (inventory_movements · stocktake_lines)真的被解析到了。
--      只认 num_nonnulls 的解析器会把它们整组放过去,而那正好是 A 臂那一组。
--   D  非单据表不当端点:图里的每一个端点都在 document_types 里。
--   E  操作人不是关系,而【作废/冲销链是】:指向 employees 的 `*_by` 不在图里,
--      而 `journal_entries.reversed_by`(指向同一张单据表)在图里。
--      ★ 两者都以 `_by` 结尾 —— 判据里的「指向 employees」是承重的那一半。
--   F  覆盖断言:边数与端点数各有下界,数出 0 就是判据失效。
BEGIN;

DO $fixture$
DECLARE
    v_n bigint;
BEGIN
    -- ── F · 覆盖断言先跑 ────────────────────────────────────────────────────
    SELECT count(*) INTO v_n FROM document_relations;
    IF v_n < 50 THEN
        RAISE EXCEPTION 'FIXTURE 103 失败:document_relations 只数出 % 条边 —— '
                        '关系图是推导出来的,它空了就是推导断了,不是"没有关联"', v_n;
    END IF;

    -- ── A · 假桥真的被作废 ──────────────────────────────────────────────────
    SELECT count(*) INTO v_n FROM document_relations
     WHERE (from_table, to_table) IN (('inbound_batches','output_batches'),
                                      ('output_batches','inbound_batches'));
    IF v_n > 0 THEN
        RAISE EXCEPTION 'FIXTURE 103 失败:inbound_batches ↔ output_batches 还在图里(% 条边)—— '
                        'inventory_movements / stocktake_lines 的 XOR 写成 '
                        '(a IS NULL) <> (b IS NULL),只认 num_nonnulls 的解析器会把它放过去', v_n;
    END IF;

    -- ── B · ★ 而真关系没有被连坐 ────────────────────────────────────────────
    SELECT count(*) INTO v_n FROM document_relations
     WHERE from_table = 'expense_claims' AND to_table = 'expenses' AND kind = 'out';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 103 失败:expense_claims → expenses 的【直接外键】边数出 %,期待 1 —— '
                        '它经 finance_attachments 的那条桥是假的(XOR 作废),'
                        '而 expense_claims.expense_id 这条是真的。'
                        '数出 0 就说明筛子作用在【对】上而不是【边】上,'
                        '于是它安静地删掉了一条真关系', v_n;
    END IF;

    -- ── C · 两种 XOR 写法都解析到了 ─────────────────────────────────────────
    SELECT count(*) INTO v_n
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
     WHERE c.contype = 'c' AND n.nspname = 'public'
       AND pg_get_constraintdef(c.oid) ~ '\([a-z_]+ IS NULL\) <> \([a-z_]+ IS NULL\)';
    IF v_n < 2 THEN
        RAISE EXCEPTION 'FIXTURE 103 失败:`(a IS NULL) <> (b IS NULL)` 形的 CHECK 只数出 %,期待至少 2 —— '
                        '这两条若不在了,A 臂就是空转', v_n;
    END IF;

    -- ── D · 端点必须是登记过的单据表 ────────────────────────────────────────
    SELECT count(*) INTO v_n FROM document_relations r
     WHERE r.from_table NOT IN (SELECT table_name FROM document_types)
        OR r.to_table   NOT IN (SELECT table_name FROM document_types);
    IF v_n > 0 THEN
        RAISE EXCEPTION 'FIXTURE 103 失败:% 条边的端点不是登记过的单据表 —— '
                        '查找表会挂到每一张发票上,行表会挂到每一张采购单上,'
                        '而那是这张单据自己的内脏,不是它的关联记录', v_n;
    END IF;

    -- ── E · 操作人不是关系,而作废/冲销链是 ─────────────────────────────────
    SELECT count(*) INTO v_n FROM document_relations
     WHERE (to_table = 'employees' AND to_column ~ '(_by|user_id)$' AND kind = 'in')
        OR (via_table IS NOT NULL
            AND (via_from_column ~ '(_by|user_id)$' OR via_to_column ~ '(_by|user_id)$')
            AND (from_table = 'employees' OR to_table = 'employees'));
    IF v_n > 0 THEN
        RAISE EXCEPTION 'FIXTURE 103 失败:% 条【操作人】边混进了关系图 —— '
                        '265 个 *_by / user_id 列指向的是谁动的手,不是一条关联单据(Q5)', v_n;
    END IF;

    SELECT count(*) INTO v_n FROM document_relations
     WHERE from_table = 'journal_entries' AND to_table = 'journal_entries'
       AND (from_column = 'reversed_by' OR to_column = 'reversed_by');
    IF v_n < 1 THEN
        RAISE EXCEPTION 'FIXTURE 103 失败:journal_entries.reversed_by 不在图里 —— '
                        '它也以 _by 结尾,但它指向【同一张单据表】,是冲销链,要显示(Q4)。'
                        '判据里的「指向 employees」那一半掉了,E 臂的两面就塌成一面';
    END IF;

    -- ── 反面对照:例外表真的在起作用 ────────────────────────────────────────
    -- ★ 没有这一格,「6 条例外」可能只是 6 行没人读的字。
    SELECT count(*) INTO v_n FROM document_relations
     WHERE (from_table = 'containers' AND from_column = 'forwarder_id')
        OR (to_table = 'containers' AND to_column = 'forwarder_id');
    IF v_n > 0 THEN
        RAISE EXCEPTION 'FIXTURE 103 失败:containers.forwarder_id 还在图里(% 条)—— '
                        'LOG-1b:货代不进供应商名单,页面已经裁过一次相反的话(Q10)', v_n;
    END IF;

    RAISE NOTICE 'FIXTURE 103 全部通过:% 条边 / % 张单据表参与;'
                 '假桥被作废而真关系没有被连坐,两种 XOR 写法都认,'
                 '操作人出局而冲销链留下。',
                 (SELECT count(*) FROM document_relations),
                 (SELECT count(DISTINCT from_table) FROM document_relations);
END
$fixture$;

ROLLBACK;
