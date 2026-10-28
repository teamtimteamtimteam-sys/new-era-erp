-- db/migrations/2026-10-27-system-map-3-chain-bar.sql
-- SYSTEM-MAP-3(v1.4.79,Tim 2026-10-26 裁定 2.4 (12) 与 2026-10-27 SYSTEM-MAP-3 Q1–Q5):单据详情页上那条上下游链条。
--   ① document_types.detail_route —— 一张单据自己那一页的地址(进料批 · 产出批 · 贷项通知单 · 化验单不是 <route>/<id>);
--      document_detail_href() / document_detail_hrefs() 一份实现。
--   ② 加班批登记成单据种类(Q4):overtime_batches.code = OT-YYYY-MM / OT-YYYY-MM-2 …(generate_overtime_batch_code 触发器);
--      显示名仍是 label;它从此进全局搜索。
--   ③ document_relation_arms + document_relation_arm_ids() —— 外键推不出来的五条关联(付款申请 ↔ 进料批 · 付款 ↔ 对账单 ·
--      考勤 / 加班 / 请假 ↔ 工资),每个方向一行;document_relations 把它们并成 kind = 'arm' 的边,
--      search_related() / search_related_rows() 多一个 'arm' 分支 —— 关联页与单据链条读同一份定义。
--   ④ document_chain_walk() + document_chain_step_admits() + bank_match_lines() —— 单据链条的取数(INVOKER)。
-- 不删任何一行、不改任何既有数据的含义;overtime_batches 的 code 由同一个公式回填(线上 0 行,实测)。
-- 镜像:下面每一段逐字是它标着的那个文件(表的 ALTER 写在这里,镜像是首建写法)。
-- 行为:db/fixtures/296(四条链各一套完整单据,任两步互相找得到;反面对照 + 故障注入)· 100(64 种)· 199(声明的边)。
-- EXECUTE:apply_migration.sh 在本事务里重放 db/views/zzz_function_grants.sql。
BEGIN;

-- ── ① document_types.detail_route ──
ALTER TABLE public.document_types ADD COLUMN detail_route text;
ALTER TABLE public.document_types ADD CONSTRAINT document_types_detail_route_shape CHECK (
        detail_route IS NULL OR (detail_route LIKE '/%' AND detail_route LIKE '%{id}%'));
COMMENT ON COLUMN public.document_types.detail_route IS
    'SYSTEM-MAP-3:一张单据【自己那一页】的地址,当它不是 <route>/<id> 时:{id} 是这张单据的 id,{<列>} 是这一行那一列的值'
    '(化验单 /inbound/{inbound_batch_id}/assays/{id})。由 document_detail_href() 填;NULL = 走 link_mode。'
    '搜索命中的落点不读它(documentHref 照旧);单据链条与关联页的表格读它。';
UPDATE public.document_types SET detail_route = '/inbound/{id}/edit' WHERE key = 'inbound_batch';
UPDATE public.document_types SET detail_route = '/output/{id}/edit' WHERE table_name = 'output_batches';
UPDATE public.document_types SET detail_route = '/finance/credit-notes/{id}' WHERE key = 'credit_note';
UPDATE public.document_types SET detail_route = '/inbound/{inbound_batch_id}/assays/{id}' WHERE key = 'assay_result';

-- ── ② 加班批登记成单据种类 ──
INSERT INTO public.document_types
    (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission)
VALUES
    ('overtime_batch', 'OT', 'overtime_batches', 'gapless', NULL, '/hr/overtime', 'detail', 'label', ARRAY['label']::text[],
     ARRAY['module.hr.view','action.overtime_enter','action.overtime_approve']::text[]);

-- ── db/functions/generate_overtime_batch_code.sql ──
-- db/functions/generate_overtime_batch_code.sql
-- SYSTEM-MAP-3(Tim 2026-10-27 Q4):加班批登记成单据种类,于是它要一个单据号。
--   形状与"一个月一份、补充的一份带序号"的那几种逐字同一条(管理月报 PACK、合规包 CPK、代扣汇缴 WHT):
--   OT-YYYY-MM(当月第一批)· OT-YYYY-MM-2、-3 …(补充批)。序号就是这张表自己的 seq(一个月内 1, 2, 3 …)。
--   原来的 label(「OT 2026-10 #1」)留着,是显示名。前缀取自 document_types(document_type_prefix),不写字面量。
-- 触发器而不是在 create_overtime_batch 里铸:每一条插进这张表的路(含 fixture 直接插)都得到同一个号。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.generate_overtime_batch_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := document_type_prefix('overtime_batch') || '-' || to_char(NEW.period_month, 'YYYY-MM')
                    || CASE WHEN NEW.seq > 1 THEN '-' || NEW.seq::text ELSE '' END;
    END IF;
    RETURN NEW;
END;
$function$;

ALTER TABLE public.overtime_batches ADD COLUMN code text;
UPDATE public.overtime_batches
   SET code = document_type_prefix('overtime_batch') || '-' || to_char(period_month, 'YYYY-MM')
              || CASE WHEN seq > 1 THEN '-' || seq::text ELSE '' END;
ALTER TABLE public.overtime_batches ALTER COLUMN code SET NOT NULL;
ALTER TABLE public.overtime_batches ADD CONSTRAINT overtime_batches_code_key UNIQUE (code);
CREATE TRIGGER trg_generate_overtime_batch_code
    BEFORE INSERT ON public.overtime_batches
    FOR EACH ROW EXECUTE FUNCTION public.generate_overtime_batch_code();

-- ── ③ db/tables/document_relation_arms.sql ──
-- db/tables/document_relation_arms.sql
-- ════════════════════════════════════════════════════════════════════════════
-- SYSTEM-MAP-3(Tim 2026-10-27,裁定 2.4 (12) 与 SYSTEM-MAP-3 grilling 第 1 条):**外键推不出来的关联,逐条声明**
-- ════════════════════════════════════════════════════════════════════════════
--
-- 关联图由真外键推导(db/views/document_relations.sql)。四条单据链上有五对相邻的单据【没有外键】把它们连起来,
-- 而它们在业务上是同一件事的两步(SYSTEM-MAP-0 §3.1 · docs/surveys/SYSTEM-MAP-3/README.md 那张表):
--   ① 付款申请 ↔ 进料批(应付)—— 申请的核销对象存在 payment_requests.allocations 这个 jsonb 里;
--   ② 付款 ↔ 银行对账单       —— 付款 → 分录 → 分录行 ← 对账匹配 → 对账单行 → 对账单,隔着三张表;
--   ③ 考勤期间 ↔ 工资期间       —— 只共用一个 period_month;
--   ④ 加班批 ↔ 工资期间         —— 同上(只认【已批准】的批:驳回 / 作废 / 冲销的批一个小时都没进工资);
--   ⑤ 请假 ↔ 工资期间           —— 请假的日子落在那个月里(Tim Q3:只认【已批准】的请假;待批与驳回的请假没有工资那一头)。
-- (工资期间 ↔ 付薪分录【不在这里】:它有真外键 —— payroll_lines.paid_journal_entry_id 与 payroll_periods 的
--   cpf_journal_entry_id / deductions_journal_entry_id —— 勘察时当成"多态的 source_id"是一次误判,开工时量出来的。)
--
-- 本表一行 = 一条【有向】边(两个方向各一行),取数在 db/functions/document_relation_arm_ids.sql 里按 arm 的名字分支。
-- 关联图把它们并进来(kind = 'arm'),于是 search_related() / search_related_rows() / document_chain_walk() 与
-- 关联页、单据链条读的是【同一份】定义 —— 没有第二份手写的关系。
--
-- ★ 与 document_relation_exceptions 同一个形状:RLS 开着、SELECT 给 authenticated(document_relations 以视图
--   属主身份读它,而重建库与线上的默认权限不是同一份,所以授权写在这里)、写一条策略都不给、anon 不给。
-- ★ 加一条声明 = 一支迁移 + 本文件 + document_relation_arm_ids() 里那一支 + fixture 296 的那一对。
--
-- 对应迁移:db/migrations/2026-10-27-system-map-3-chain-bar.sql
-- 行为断言:db/fixtures/296-every-adjacent-pair-on-the-four-chains-links-both-ways.sql

CREATE TABLE public.document_relation_arms (
    arm        text PRIMARY KEY,
    from_table text NOT NULL,
    to_table   text NOT NULL,
    reason     text NOT NULL,
    CONSTRAINT document_relation_arms_reason_present CHECK (btrim(reason) <> ''),
    CONSTRAINT document_relation_arms_name_shape CHECK (arm ~ '^[a-z][a-z_]*$'),
    CONSTRAINT document_relation_arms_one_per_direction UNIQUE (from_table, to_table)
);

COMMENT ON TABLE public.document_relation_arms IS
    'SYSTEM-MAP-3:外键推不出来、而单据链上必须有的关联,逐条声明(每个方向一行)。'
    '取数在 document_relation_arm_ids(arm, id);document_relations 把它们并成 kind = ''arm'' 的边。';

ALTER TABLE public.document_relation_arms ENABLE ROW LEVEL SECURITY;

CREATE POLICY document_relation_arms_select ON public.document_relation_arms
    FOR SELECT TO authenticated USING (true);

REVOKE ALL ON public.document_relation_arms FROM anon;
GRANT SELECT ON public.document_relation_arms TO authenticated;

-- ── 种子:5 条关联 × 两个方向 = 10 行 ──────────────────────────────────────────
INSERT INTO public.document_relation_arms (arm, from_table, to_table, reason) VALUES
    ('payment_request_to_inbound_batch', 'payment_requests', 'inbound_batches',
     '付款申请核销的进料批存在 payment_requests.allocations(jsonb)里 —— 没有外键;单据链「应付 → 付款申请」那一对。'),
    ('inbound_batch_to_payment_request', 'inbound_batches', 'payment_requests',
     '上一条的反方向:一批货(它的应付)被哪几张付款申请核销过。'),
    ('payment_to_bank_statement', 'payments', 'bank_statements',
     '一笔付款的分录行被对账单上哪一行匹配了:payments.journal_entry_id → journal_lines ← bank_line_matches → '
     'bank_statement_lines → bank_statements,隔着三张表;单据链「付款 → 银行对账」那一对。'),
    ('bank_statement_to_payment', 'bank_statements', 'payments',
     '上一条的反方向:一张对账单上匹配掉的分录行属于哪几笔付款。'),
    ('attendance_period_to_payroll_period', 'attendance_periods', 'payroll_periods',
     '考勤与工资只共用一个 period_month(都是当月 1 号);工资读的是那个月完成的考勤。'),
    ('payroll_period_to_attendance_period', 'payroll_periods', 'attendance_periods',
     '上一条的反方向。'),
    ('overtime_batch_to_payroll_period', 'overtime_batches', 'payroll_periods',
     '加班批与工资只共用一个 period_month;只认已批准的批 —— 批过的小时数在那个月考勤完成时冻进考勤,再进工资。'),
    ('payroll_period_to_overtime_batch', 'payroll_periods', 'overtime_batches',
     '上一条的反方向(同样只认已批准的批)。'),
    ('leave_request_to_payroll_period', 'leave_requests', 'payroll_periods',
     'Tim SYSTEM-MAP-3 Q3:已批准的请假连到它的日子碰到的每一个月的工资期间;待批与驳回的请假没有工资那一头。'),
    ('payroll_period_to_leave_request', 'payroll_periods', 'leave_requests',
     '上一条的反方向(同样只认已批准的请假)。');

-- 留痕(db/views/zzz_change_log_triggers.sql 里那两行,逐字)
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.document_relation_arms
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('arm');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.document_relation_arms
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── db/functions/document_relation_arm_ids.sql ──
-- db/functions/document_relation_arm_ids.sql
-- SYSTEM-MAP-3(Tim 2026-10-27):一条【声明的】关联(document_relation_arms 的一行)从一张单据走到哪几张。
--   search_related() / search_related_rows() 的 'arm' 分支调它;document_chain_walk() 经 search_related_rows() 间接调它。
--
-- ★ INVOKER,与那两支同一条理由:「你看得见哪几张」由 RLS 自己回答。这里一条权限判据都不写。
-- ★ 认不出的 arm 名【响】(RAISE),不是空集 —— 一个拼错的名字与一张真的没有关联的单据,在屏幕上分不开。
-- ★ 每一支只读它那一条路上的表;日期与状态的判据写在 document_relation_arms 那一行的 reason 里,两边说同一句话。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.document_relation_arm_ids(p_arm text, p_id uuid)
 RETURNS TABLE(id uuid)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    IF p_arm = 'payment_request_to_inbound_batch' THEN
        RETURN QUERY
        SELECT DISTINCT (a->>'inbound_batch_id')::uuid
          FROM public.payment_requests r
          CROSS JOIN LATERAL jsonb_array_elements(r.allocations) a
         WHERE r.id = p_id AND COALESCE(a->>'inbound_batch_id', '') <> '';
    ELSIF p_arm = 'inbound_batch_to_payment_request' THEN
        RETURN QUERY
        SELECT r.id
          FROM public.payment_requests r
         WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(r.allocations) a
                        WHERE a->>'inbound_batch_id' = p_id::text);
    ELSIF p_arm = 'payment_to_bank_statement' THEN
        RETURN QUERY
        SELECT DISTINCT bl.statement_id
          FROM public.payments p
          JOIN public.journal_lines jl ON jl.entry_id = p.journal_entry_id
          JOIN public.bank_line_matches m ON m.journal_line_id = jl.id
          JOIN public.bank_statement_lines bl ON bl.id = m.statement_line_id
         WHERE p.id = p_id;
    ELSIF p_arm = 'bank_statement_to_payment' THEN
        RETURN QUERY
        SELECT DISTINCT p.id
          FROM public.bank_statement_lines bl
          JOIN public.bank_line_matches m ON m.statement_line_id = bl.id
          JOIN public.journal_lines jl ON jl.id = m.journal_line_id
          JOIN public.payments p ON p.journal_entry_id = jl.entry_id
         WHERE bl.statement_id = p_id;
    ELSIF p_arm = 'attendance_period_to_payroll_period' THEN
        RETURN QUERY
        SELECT pp.id
          FROM public.attendance_periods ap
          JOIN public.payroll_periods pp ON pp.period_month = ap.period_month AND pp.deleted_at IS NULL
         WHERE ap.id = p_id;
    ELSIF p_arm = 'payroll_period_to_attendance_period' THEN
        RETURN QUERY
        SELECT ap.id
          FROM public.payroll_periods pp
          JOIN public.attendance_periods ap ON ap.period_month = pp.period_month
         WHERE pp.id = p_id;
    ELSIF p_arm = 'overtime_batch_to_payroll_period' THEN
        RETURN QUERY
        SELECT pp.id
          FROM public.overtime_batches ob
          JOIN public.payroll_periods pp ON pp.period_month = ob.period_month AND pp.deleted_at IS NULL
         WHERE ob.id = p_id AND ob.status = 'approved';
    ELSIF p_arm = 'payroll_period_to_overtime_batch' THEN
        RETURN QUERY
        SELECT ob.id
          FROM public.payroll_periods pp
          JOIN public.overtime_batches ob ON ob.period_month = pp.period_month AND ob.status = 'approved'
         WHERE pp.id = p_id;
    ELSIF p_arm = 'leave_request_to_payroll_period' THEN
        RETURN QUERY
        SELECT pp.id
          FROM public.leave_requests lr
          JOIN public.payroll_periods pp
            ON pp.period_month BETWEEN date_trunc('month', lr.start_date)::date
                                   AND date_trunc('month', lr.end_date)::date
           AND pp.deleted_at IS NULL
         WHERE lr.id = p_id AND lr.status = 'approved' AND lr.deleted_at IS NULL;
    ELSIF p_arm = 'payroll_period_to_leave_request' THEN
        RETURN QUERY
        SELECT lr.id
          FROM public.payroll_periods pp
          JOIN public.leave_requests lr
            ON pp.period_month BETWEEN date_trunc('month', lr.start_date)::date
                                   AND date_trunc('month', lr.end_date)::date
           AND lr.status = 'approved' AND lr.deleted_at IS NULL
         WHERE pp.id = p_id;
    ELSE
        RAISE EXCEPTION 'DOCUMENT_RELATION_UNKNOWN_ARM|% —— 它不在 document_relation_arms 里,'
                        '而一个拼错的名字与一张真的没有关联的单据在屏幕上分不开', coalesce(p_arm, '(null)');
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.document_relation_arm_ids(text, uuid) IS
    'SYSTEM-MAP-3:一条声明的关联(document_relation_arms)从一张单据走到哪几张。INVOKER —— RLS 回答你看得见哪几张;'
    '认不出的 arm 名按名拒(DOCUMENT_RELATION_UNKNOWN_ARM)。';

-- ── db/functions/search_related.sql ──
-- db/functions/search_related.sql
-- SEARCH-4 · 迁移 A。关系图在 db/views/document_relations.sql;
-- 行为断言在 db/fixtures/103-a-voided-bridge-does-not-void-a-real-relation.sql。

-- ★★ INVOKER,而这一条【不是随手抄的】(Q13)★★
--   关联计数要回答的是「**你**看得见几条」,而那正是 RLS 天生回答的问题。
--   DEFINER 只属于 search_documents_withheld() —— 「你**看不见**几条」RLS 按构造
--   答不了,所以那一支必须借身份。**两支函数,两种身份,不要合并。**
--   ☞ 推论:一类关联整类被模块闸扣下时,这里数出 0,那一组就不出现 —— 顶层
--     那一次 search_documents_withheld() 已经把"这一类你能不能看"说过一遍了,
--     这里不再报第二个数(两个数不一样,读起来像矛盾)。
--
-- ★ 每条命中【最多】几组:15(journal_entries,含它自己的冲销自指边)。
--   一组一支相关子查询,5 条命中 ⇒ 最坏 75 支。今天 320 行,规划器一律 Seq Scan。
--   **不报毫秒数** —— 迁移 B 的 84 条索引是为将来的体量建的,不为今天的读数。

CREATE OR REPLACE FUNCTION public.search_related(p_key text, p_id uuid)
 RETURNS TABLE(target_key text, target_table text, route text, link_mode text, n bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_table  text;
    v_rows   jsonb := '[]'::jsonb;
    r        record;
    e        record;
    parts    text[];
    v_where  text;
    v_n      bigint;
BEGIN
    IF p_key IS NULL OR p_id IS NULL THEN
        RETURN;
    END IF;

    SELECT d.table_name INTO v_table FROM public.document_types d WHERE d.key = p_key;
    IF v_table IS NULL THEN
        -- 与 document_type_prefix() 同一条:读不到就响,不要静默返回空。
        -- 一个"这张单据没有关联记录"的空态,和一个拼错的 key,在屏幕上长得一模一样。
        RAISE EXCEPTION 'SEARCH_UNKNOWN_DOCUMENT_TYPE|% —— 它不在 document_types 里,'
                        '而一次拼错的 key 与一张真的没有关联的单据在屏幕上分不开', p_key;
    END IF;

    FOR r IN
        SELECT d.key, d.table_name, d.route, d.link_mode, d.prefix,
               (SELECT count(*) > 1 FROM public.document_types d2
                 WHERE d2.table_name = d.table_name) AS shared
          FROM public.document_types d
         WHERE EXISTS (SELECT 1 FROM public.document_relations dr
                        WHERE dr.from_table = v_table AND dr.to_table = d.table_name)
         ORDER BY d.key
    LOOP
        parts := '{}';
        FOR e IN
            SELECT * FROM public.document_relations dr
             WHERE dr.from_table = v_table AND dr.to_table = r.table_name
        LOOP
            IF e.kind = 'arm' THEN
                -- SYSTEM-MAP-3:一条【声明的】关系(没有外键可推)—— 走 document_relation_arm_ids(),
                --   via_table 是那一支的名字。与 search_related_rows() 逐字同一段。
                parts := parts || format(
                    'SELECT t.id, t.code FROM public.document_relation_arm_ids(%L, $1) a '
                    ' JOIN public.%I t ON t.id = a.id',
                    e.via_table, e.to_table);
            ELSIF e.kind = 'bridge' THEN
                parts := parts || format(
                    'SELECT t.id, t.code FROM public.%I v JOIN public.%I t ON t.%I = v.%I '
                    ' WHERE v.%I = (SELECT s.%I FROM public.%I s WHERE s.id = $1)',
                    e.via_table, e.to_table, e.to_column, e.via_to_column,
                    e.via_from_column, e.from_column, e.from_table);
            ELSE
                -- 出边与入边在这里是【同一个形状】:出边的 from_column 是本表那一列,
                -- 入边的 from_column 是被指向的那一列(几乎总是 id)。
                parts := parts || format(
                    'SELECT t.id, t.code FROM public.%I t '
                    ' WHERE t.%I = (SELECT s.%I FROM public.%I s WHERE s.id = $1)',
                    e.to_table, e.to_column, e.from_column, e.from_table);
            END IF;
        END LOOP;

        CONTINUE WHEN cardinality(parts) = 0;

        v_where := 'TRUE';
        -- 一张表两个前缀(payments = RCPT + PMT):不加前缀过滤,同一条关联会在
        -- 两种单据下各数一次。与 search_documents_sql() 逐字同一条理由。
        IF r.shared THEN
            v_where := v_where || format(' AND u.code LIKE %L', r.prefix || '-%');
        END IF;
        -- 自指关系不把自己算成自己的关联记录。
        IF r.table_name = v_table THEN
            v_where := v_where || ' AND u.id <> $1';
        END IF;

        EXECUTE format(
            'SELECT count(*) FROM (SELECT DISTINCT u.id FROM (%s) u (id, code) WHERE %s) z',
            array_to_string(parts, E'\nUNION ALL\n'), v_where)
          INTO v_n USING p_id;

        -- 0 组不返回:「这张单据没有关联记录」由应用层画,而不是画 39 行 0。
        CONTINUE WHEN v_n = 0;

        v_rows := v_rows || jsonb_build_object(
            'target_key', r.key, 'target_table', r.table_name,
            'route', r.route, 'link_mode', r.link_mode, 'n', v_n);
    END LOOP;

    RETURN QUERY
    SELECT x->>'target_key', x->>'target_table', x->>'route', x->>'link_mode',
           (x->>'n')::bigint
      FROM jsonb_array_elements(v_rows) x
     ORDER BY (x->>'n')::bigint DESC, x->>'target_key';
END;
$function$;

COMMENT ON FUNCTION public.search_related(text, uuid) IS
    'SEARCH-4:一条命中带出来的关联记录,**按目标单据种类分组,每组一个计数**。'
    'INVOKER —— 数的是"你看得见几条"(Q13)。行不取回来:一个分组行答得出'
    '"这个供应商现在什么情况",而 11 行批号答不出。';

-- ★ EXECUTE 的授权【不写在这里】:db/views/zzz_function_grants.sql 是那一条的
--   唯一出处(先 REVOKE FROM PUBLIC, anon，再 GRANT ON ALL FUNCTIONS TO
--   authenticated, service_role)。在这里再写一遍就是第二份真相 ——
--   而 search_documents / search_recents 四支的镜像里也都没有它。
--   ⚠ 迁移那一侧【显式写了】:一支刚建出来的函数拿的是默认权限，
--     而「默认多半是对的」正是本刀在 document_relations 上刚栽过的那一跮。

-- ── db/functions/search_related_rows.sql ──
-- db/functions/search_related_rows.sql
-- SEARCH-5 · 迁移 2026-09-19(+ -fu1:三个前导参数带 DEFAULT NULL,
--            让【无主语】那一种形状在生成的类型里也省得掉)。
-- 关系图在 db/views/document_relations.sql;
-- 行为断言在 db/fixtures/199-rows-and-counts-are-one-visibility-and-the-negative-control-proves-it.sql。

-- ★★ INVOKER —— 与 search_related() 逐字同一条理由 ★★
--   这一支答的是「你看得见【哪几行】」,而它的兄弟答「你看得见【几行】」。
--   两个问题必须是同一个答案,而那个答案 RLS 天生就会给。
--   ☞ 所以这里不许出现 SECURITY DEFINER —— fixture 199 的「前提二」逐条查它,
--     任何一支变成 DEFINER,整支 fixture 当场作废并按名喊出来。
--
-- ★★【为什么它和 search_related() 长得几乎一样,而那【不是】重复】★★
--   边→SQL 那段翻译只有【一份语义】,而它在两支函数里各写了一遍文本。
--   本仓库为"两份实现在写下来那天一致、之后悄悄分开"付过四次账,所以这里
--   **不靠长得像**:fixture 199 A 臂钉住「同一个 (key,id,target_key),
--   行数 == 计数 == total」,C 臂是它的反面对照(换一个看不见的会话,
--   两个数必须【一起】变 0)。⚠ 没有 C 臂,A 臂可能只是两支都返回了全部 ——
--   而 fixture 以 postgres 跑、rolbypassrls=t,那一格按构造是绿的(fixture 26 那一课)。
--
-- ★ 它比 search_related() 多读一列:`label_column`。而 39 张单据表里 **6 张**
--   对 authenticated 【没有表级 SELECT】,只有列级授权(employees ·
--   inbound_batches · invoices · pricing_formulas · processing_runs ·
--   purchase_orders,2026-09-19 线上实测)。今天 31 个有 label 的种类
--   两列全都读得到(0 个缺口),而**今天没有别的东西盯着它** ——
--   所以 fixture 199 的 F 臂逐列断言它:那不是"少显示一列",
--   是那一类单据的关联页【整页报错】。
--
-- ★ 两种形状:给主语 = 「NMC 的产出批」;不给主语 = 「化验单」
--   (那 5 种 link_mode='type_list' 单据的落点)。**只给一半 ⇒ RAISE**。
--
-- ★ 今天一个分组最大 11 行(supplier → inbound_batch),>20 行的分组 0 个;
--   而结构上无界的有向表对 140/178。**分页不是可选项,只是它今天一次都不会触发。**
--   ⚠ 不报毫秒数 —— 这是第五刀拒绝,而前四刀都是对的。

CREATE OR REPLACE FUNCTION public.search_related_rows(p_key text DEFAULT NULL::text, p_id uuid DEFAULT NULL::uuid, p_target_key text DEFAULT NULL::text, p_limit integer DEFAULT 20, p_after_code text DEFAULT NULL::text)
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
            IF e.kind = 'arm' THEN
                -- SYSTEM-MAP-3:一条【声明的】关系(没有外键可推)—— 走 document_relation_arm_ids(),
                --   via_table 是那一支的名字。与 search_related() 逐字同一段。
                parts := parts || format(
                    'SELECT t.id, t.code, %s FROM public.document_relation_arm_ids(%L, $1) a '
                    ' JOIN public.%I t ON t.id = a.id',
                    v_sel, e.via_table, e.to_table);
            ELSIF e.kind = 'bridge' THEN
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
$function$
;

COMMENT ON FUNCTION public.search_related_rows(text, uuid, text, integer, text) IS
    'SEARCH-5:一个关联分组【自己那几行】。与 search_related() 同一段边→SQL 翻译、'
    '同一张 document_relations、同一条前缀过滤、同一条自指排除,而且同为 INVOKER —— '
    '「你看得见几条」与「你看得见哪几条」必须是同一个答案(db/fixtures/199 钉住它)。'
    '两种形状:给主语 = 「NMC 的产出批」;不给主语 = 「化验单」(那 5 种 type_list 的落点)。'
    '翻页是 keyset(code < p_after_code),不是 OFFSET;total 在翻页之前算。';

-- ★ EXECUTE 的授权【不写在这里】:db/views/zzz_function_grants.sql 是那一条的
--   唯一出处(先 REVOKE FROM PUBLIC, anon,再 GRANT ON ALL FUNCTIONS TO
--   authenticated, service_role)。与 search_related 五支的镜像里都没有它,同形。
--   ⚠ 迁移那一侧【显式写了】:一支刚建出来的函数拿的是 PostgreSQL 的默认权限
--     (PUBLIC 可执行),而重建那一路才跑 zzz_function_grants.sql,线上不跑。

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

CREATE OR REPLACE FUNCTION public.document_detail_href(p_key text, p_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    d     record;
    v     text;
    m     text[];
    v_val text;
BEGIN
    SELECT dt.key, dt.table_name, dt.route, dt.link_mode, dt.detail_route INTO d
      FROM public.document_types dt WHERE dt.key = p_key;
    IF d.key IS NULL THEN
        RAISE EXCEPTION 'SEARCH_UNKNOWN_DOCUMENT_TYPE|% —— 它不在 document_types 里', coalesce(p_key, '(null)');
    END IF;
    IF p_id IS NULL THEN
        RETURN NULL;
    END IF;
    IF d.detail_route IS NOT NULL THEN
        v := d.detail_route;
        FOR m IN SELECT regexp_matches(d.detail_route, '\{([a-z_]+)\}', 'g') LOOP
            IF m[1] = 'id' THEN
                v_val := p_id::text;
            ELSE
                EXECUTE format('SELECT t.%I::text FROM public.%I t WHERE t.id = $1', m[1], d.table_name)
                   INTO v_val USING p_id;
            END IF;
            IF v_val IS NULL THEN
                RETURN NULL;
            END IF;
            v := replace(v, '{' || m[1] || '}', v_val);
        END LOOP;
        RETURN v;
    END IF;
    IF d.link_mode = 'detail' THEN
        RETURN d.route || '/' || p_id::text;
    END IF;
    RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.document_detail_href(text, uuid) IS
    'SYSTEM-MAP-3:一张单据自己那一页的地址(detail_route 按占位填 / detail → <route>/<id> / 否则 NULL)。INVOKER。';

-- ── db/functions/document_detail_hrefs.sql ──
-- db/functions/document_detail_hrefs.sql
-- SYSTEM-MAP-3:document_detail_href() 的一屏版 —— 关联页的表格一次画 20 行,一次往返要齐它们的地址。
--   同一份实现(逐个调 document_detail_href),不是第二份。INVOKER。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.document_detail_hrefs(p_key text, p_ids uuid[])
 RETURNS TABLE(id uuid, href text)
 LANGUAGE sql
 STABLE
AS $function$
    SELECT x.id, public.document_detail_href(p_key, x.id)
      FROM unnest(p_ids) AS x(id)
$function$;

COMMENT ON FUNCTION public.document_detail_hrefs(text, uuid[]) IS
    'SYSTEM-MAP-3:一批单据各自那一页的地址(逐个调 document_detail_href)。INVOKER。';

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
    IF p_filter NOT IN ('payable', 'reservation', 'cost_allocation', 'payroll_payment') THEN
        RAISE EXCEPTION 'DOCUMENT_CHAIN_UNKNOWN_FILTER|% —— 单据链条认得的判据只有 payable · reservation · '
                        'cost_allocation · payroll_payment', p_filter;
    END IF;
    IF p_id IS NULL THEN
        RETURN true;
    END IF;
    IF p_filter = 'payable' THEN
        RETURN EXISTS (SELECT 1 FROM public.journal_entries e
                        WHERE e.source_type = 'purchase' AND e.source_id = p_id);
    ELSIF p_filter = 'reservation' THEN
        RETURN EXISTS (SELECT 1 FROM public.sales_order_reservations r
                         JOIN public.sales_order_lines l ON l.id = r.sales_order_line_id
                        WHERE l.sales_order_id = p_id);
    ELSIF p_filter = 'cost_allocation' THEN
        RETURN EXISTS (SELECT 1 FROM public.batch_processing_cost_allocations a WHERE a.run_id = p_id);
    END IF;
    RETURN EXISTS (SELECT 1 FROM public.payroll_lines pl WHERE pl.paid_journal_entry_id = p_id)
        OR EXISTS (SELECT 1 FROM public.payroll_periods pp
                    WHERE pp.cpf_journal_entry_id = p_id OR pp.deductions_journal_entry_id = p_id);
END;
$function$;

COMMENT ON FUNCTION public.document_chain_step_admits(text, uuid) IS
    'SYSTEM-MAP-3:单据链条上一个住在宿主单据里的步骤,在这张宿主单据上存不存在(payable · reservation · '
    'cost_allocation · payroll_payment;NULL = 没有判据)。INVOKER。';

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
--   步骤图上按距离排序(BFS);一步的单据 = 它【离读者更近的那些相邻步骤】上已经找到的单据,经关联图
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

    -- ── 一圈一圈往外走 ───────────────────────────────────────────────────────
    FOR j IN SELECT g.i - 1 FROM generate_subscripts(dist, 1) AS g(i)
              WHERE dist[g.i] > 0 ORDER BY dist[g.i], g.i LOOP
        -- 离读者更近的相邻步骤
        SELECT coalesce(array_agg(DISTINCT x.s), '{}') INTO v_src
          FROM (SELECT CASE WHEN (ed->>0)::integer = j THEN (ed->>1)::integer ELSE (ed->>0)::integer END AS s
                  FROM jsonb_array_elements(v_edges) ed
                 WHERE (ed->>0)::integer = j OR (ed->>1)::integer = j) x
         WHERE dist[x.s + 1] >= 0 AND dist[x.s + 1] < dist[j + 1];

        FOR r IN
            SELECT DISTINCT ON (x.id) x.k, x.id, x.code, x.label
              FROM unnest(f_step, f_key, f_id, f_code, f_label) AS s(sstep, skey, sid, scode, slabel)
              CROSS JOIN LATERAL jsonb_array_elements_text(v_steps->j->'keys') AS tk(tkey)
              CROSS JOIN LATERAL (
                    SELECT tk.tkey AS k, s.sid AS id, s.scode AS code, s.slabel AS label
                     WHERE s.skey = tk.tkey
                    UNION ALL
                    SELECT tk.tkey, q.id, q.code, q.label
                      FROM public.search_related_rows(s.skey, s.sid, tk.tkey, 100, NULL) q
                     WHERE s.skey <> tk.tkey
              ) x
             WHERE s.sstep = ANY (v_src)
             ORDER BY x.id, x.k
        LOOP
            IF public.document_chain_step_admits(v_steps->j->>'filter', r.id) THEN
                f_step := f_step || j;
                f_key := f_key || r.k;
                f_id := f_id || r.id;
                f_code := f_code || r.code;
                f_label := f_label || r.label;
            END IF;
        END LOOP;
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

-- ── db/functions/bank_match_lines.sql ──
-- db/functions/bank_match_lines.sql
-- SYSTEM-MAP-3(Tim 2026-10-27,grilling 第 7 条):单据链条上「银行对账」那一步链到【匹配上的那一行】——
--   对账单页上那一行带着 id="line-<对账单行 id>",<HashTarget> 把它滚进视野并标亮。
--   这一支答:这几笔付款,各自被哪一张对账单的哪一行匹配了。路与 document_relation_arm_ids 的
--   payment_to_bank_statement 那一支逐字同一条(付款 → 分录行 ← 匹配 → 对账单行)。INVOKER。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.bank_match_lines(p_payment_ids uuid[])
 RETURNS TABLE(payment_id uuid, statement_id uuid, line_id uuid)
 LANGUAGE sql
 STABLE
AS $function$
    SELECT DISTINCT p.id, bl.statement_id, bl.id
      FROM public.payments p
      JOIN public.journal_lines jl ON jl.entry_id = p.journal_entry_id
      JOIN public.bank_line_matches m ON m.journal_line_id = jl.id
      JOIN public.bank_statement_lines bl ON bl.id = m.statement_line_id
     WHERE p.id = ANY (p_payment_ids)
$function$;

COMMENT ON FUNCTION public.bank_match_lines(uuid[]) IS
    'SYSTEM-MAP-3:这几笔付款各自被哪一张对账单的哪一行匹配了(单据链条「银行对账」那一步的锚点)。INVOKER。';

-- ── db/views/document_relations.sql ──
-- db/views/document_relations.sql
-- ════════════════════════════════════════════════════════════════════════════
-- SEARCH-4(2026-09-13):关联图 —— **从真外键推导,不是一份手写的副本**
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【为什么是视图,不是表】(Q14)一张物化的关系表就是裁定 ③ 点名要杀的那份手写
-- 副本:它在写下来那天与线上一致,之后悄悄分开。这张视图 SELECT 自 pg_constraint
-- —— **它按定义不可能与线上不一致,因为它就是线上**。新表带上真外键的那一刻,
-- 它自动进入关联搜索,一行代码都不用改。
--   实测(SET LOCAL ROLE authenticated 的回滚事务里):authenticated 读得到
--   pg_constraint(397 条)、document_types(40 行)、pg_get_constraintdef。
--
-- ── 形状,一句话(SEARCH-4 §2 的裁定)────────────────────────────────────────
--   **节点只能是 document_types 登记的 39 张表;非单据表只能当边,不能当端点。**
--   一跳 = 单据 →(0 或 1 张非单据表)→ 单据。
--   ☞ 这一句按构造同时消掉两种噪音:查找表不是单据(一张发票不会"关联"到一行
--     SGD),行表不是单据(PO 不会"关联" 4 条 purchase_order_lines —— 那是它
--     自己的内脏)。**不需要一张"不要显示这些表"的名单。**
--
-- ── 四条筛子,三条推导、一条声明 ────────────────────────────────────────────
--   ① 端点必须登记          —— 推导(document_types)
--   ② XOR 型 CHECK 作废假桥 —— 推导。两种写法都认:
--        `num_nonnulls(a,b,…) = 1` / `<= 1`,以及 `(a IS NULL) <> (b IS NULL)`。
--        ★ 只认 num_nonnulls 的解析器会把 inventory_movements / stocktake_lines
--          整组放过去,而那正好是 inbound_batches ↔ output_batches 这组假关联。
--        实测 19 条 XOR 型 CHECK,分布 19 张表,作废 24 条桥边 / 净减 14 组关系。
--   ③ 操作人列不是关系      —— 推导(Q5)。指向 employees 的 `*_by` / `user_id`。
--        ★ 判据里的「指向 employees」是承重的:`superseded_by` / `reversed_by`
--          也以 _by 结尾,而它们指向【同一张单据表】,是作废/冲销链,要显示。
--        实测:去掉 15 条噪音边,**一组关系都没少**(employees ↔ tasks 经
--        task_participants(employee_id, task_id) 照样在)。
--   ④ document_relation_exceptions —— 声明,逐条带理由,**键是边不是对**。
--
-- ⚠ 本视图【不含】多态列(subject_type/source_id 那 4 对)—— Q11 裁定不进这一刀,
--   「类型串 → 表名」那张映射立案为一条声明,不是一个黑箱。
--
-- 对应迁移:db/migrations/2026-09-13-search4a-document-relations.sql
-- 读它的:  db/functions/search_related.sql

CREATE OR REPLACE VIEW public.document_relations AS
WITH doc AS (
    SELECT DISTINCT table_name FROM public.document_types
),
fk AS (
    -- 单列外键,public → public。多列外键不参与:一条关联边要能写成一个等值
    -- 条件,而多列的写不成 —— 今天 public 里一条这样的跨单据外键都没有。
    SELECT st.relname::text  AS src,
           sa.attname::text  AS srccol,
           tt.relname::text  AS tgt,
           ta.attname::text  AS tgtcol
      FROM pg_constraint c
      JOIN pg_class     st ON st.oid = c.conrelid
      JOIN pg_namespace sn ON sn.oid = st.relnamespace
      JOIN pg_class     tt ON tt.oid = c.confrelid
      JOIN pg_namespace tn ON tn.oid = tt.relnamespace
      JOIN pg_attribute sa ON sa.attrelid = c.conrelid  AND sa.attnum = c.conkey[1]
      JOIN pg_attribute ta ON ta.attrelid = c.confrelid AND ta.attnum = c.confkey[1]
     WHERE c.contype = 'f'
       AND sn.nspname = 'public' AND tn.nspname = 'public'
       AND array_length(c.conkey, 1) = 1
),
-- ③ 操作人列:指向 employees 的 `*_by` / `user_id`
actor AS (
    SELECT src, srccol FROM fk
     WHERE tgt = 'employees' AND srccol ~ '(_by|user_id)$'
),
-- ② XOR 型 CHECK 的两种写法
checkdef AS (
    SELECT t.relname::text AS tbl, pg_get_constraintdef(c.oid) AS def
      FROM pg_constraint c
      JOIN pg_class     t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
     WHERE c.contype = 'c' AND n.nspname = 'public'
),
xor_cols AS (
    SELECT tbl, btrim(unnest(string_to_array(cols, ','))) AS col
      FROM (
        SELECT tbl, (regexp_match(def, 'num_nonnulls\(([^)]*)\)\s*(?:=|<=)\s*1'))[1] AS cols
          FROM checkdef WHERE def ~ 'num_nonnulls\([^)]*\)\s*(?:=|<=)\s*1'
        UNION ALL
        SELECT tbl, (regexp_match(def, '\(([a-z_]+) IS NULL\) <> \(([a-z_]+) IS NULL\)'))[1] || ',' ||
                    (regexp_match(def, '\(([a-z_]+) IS NULL\) <> \(([a-z_]+) IS NULL\)'))[2]
          FROM checkdef WHERE def ~ '\([a-z_]+ IS NULL\) <> \([a-z_]+ IS NULL\)'
      ) s
),
xor_pair AS (
    SELECT DISTINCT a.tbl, a.col AS c1, b.col AS c2
      FROM xor_cols a JOIN xor_cols b ON a.tbl = b.tbl AND a.col <> b.col
),
edges AS (
    -- 出边:这张单据的一列指着对方 —— 按构造最多 1 条
    SELECT f.src AS from_table, f.srccol AS from_column,
           NULL::text AS via_table, NULL::text AS via_from_column, NULL::text AS via_to_column,
           f.tgt AS to_table, f.tgtcol AS to_column,
           'out'::text AS kind,
           f.src AS owner_table, f.srccol AS owner_column_a, ''::text AS owner_column_b
      FROM fk f
     WHERE f.src IN (SELECT table_name FROM doc)
       AND f.tgt IN (SELECT table_name FROM doc)
       AND (f.src, f.srccol) NOT IN (SELECT src, srccol FROM actor)

    UNION ALL

    -- 入边:对方的一列指着这张单据 —— 按构造是【一叠】
    SELECT f.tgt, f.tgtcol,
           NULL::text, NULL::text, NULL::text,
           f.src, f.srccol,
           'in'::text,
           f.src, f.srccol, ''::text
      FROM fk f
     WHERE f.src IN (SELECT table_name FROM doc)
       AND f.tgt IN (SELECT table_name FROM doc)
       AND (f.src, f.srccol) NOT IN (SELECT src, srccol FROM actor)

    UNION ALL

    -- 桥边:一张非单据表同时指着两张单据 —— 36 组关系【只】存在于这里
    SELECT f1.tgt, f1.tgtcol,
           f1.src, f1.srccol, f2.srccol,
           f2.tgt, f2.tgtcol,
           'bridge'::text,
           f1.src, least(f1.srccol, f2.srccol), greatest(f1.srccol, f2.srccol)
      FROM fk f1
      JOIN fk f2 ON f2.src = f1.src AND f2.srccol <> f1.srccol
     WHERE f1.src NOT IN (SELECT table_name FROM doc)
       AND f1.tgt IN (SELECT table_name FROM doc)
       AND f2.tgt IN (SELECT table_name FROM doc)
       AND (f1.src, f1.srccol) NOT IN (SELECT src, srccol FROM actor)
       AND (f2.src, f2.srccol) NOT IN (SELECT src, srccol FROM actor)
       AND NOT EXISTS (
             SELECT 1 FROM xor_pair x
              WHERE x.tbl = f1.src AND x.c1 = f1.srccol AND x.c2 = f2.srccol)

    UNION ALL

    -- ★ SYSTEM-MAP-3(Tim 2026-10-27):【声明的】边 —— 外键推不出来、而单据链上必须有的那几条
    --   (付款申请 ↔ 进料批走 jsonb · 付款 ↔ 对账单隔着三张表 · 考勤 / 加班 / 请假 ↔ 工资只共用一个月份)。
    --   一条声明 = document_relation_arms 的一行,取数是 document_relation_arm_ids(<arm>, id);
    --   via_table 装的是那一支的名字(search_related / search_related_rows 的 'arm' 分支读它)。
    --   键照旧是【边】:owner_table = 'document_relation_arms'、column_a = 那一支的名字 —— 例外表一样够得着它。
    SELECT a.from_table, 'id'::text,
           a.arm, NULL::text, NULL::text,
           a.to_table, 'id'::text,
           'arm'::text,
           'document_relation_arms'::text, a.arm, ''::text
      FROM public.document_relation_arms a
     WHERE a.from_table IN (SELECT table_name FROM doc)
       AND a.to_table IN (SELECT table_name FROM doc)
)
SELECT e.from_table, e.from_column,
       e.via_table, e.via_from_column, e.via_to_column,
       e.to_table, e.to_column,
       e.kind,
       e.owner_table, e.owner_column_a, e.owner_column_b
  FROM edges e
 WHERE NOT EXISTS (
         SELECT 1 FROM public.document_relation_exceptions x
          WHERE x.owner_table   = e.owner_table
            AND x.column_a      = e.owner_column_a
            AND x.column_b      = e.owner_column_b);

COMMENT ON VIEW public.document_relations IS
    'SEARCH-4:单据↔单据的关联图,由 pg_constraint 现算。'
    '节点 = document_types 登记的表;非单据表只当边。XOR 型 CHECK 作废假桥;'
    '指向 employees 的 *_by / user_id 是操作人不是关系;其余裁定在 '
    'document_relation_exceptions 里逐条带理由。';


-- ★★【REVOKE,而它【必须住在镜像里】—— 这一条是门当场抓到的】★★
--   db/gate.py --offline 第一次跑就红了:fixture 196 的 B1 报
--   「匿名请求从 337 个关系里读到了行:document_relations(254)」。
--   ☞ 线上实测 anon **拿不到**这张视图(`pg_default_acl` 里 postgres 在 public
--     上的默认权限不含 anon);而**重建出来的那个库里它拿得到** —— 两处的
--     默认权限不是同一份。**一个只在线上成立的收口不是收口。**
--   ☞ 而 collection_promise_status.sql 早就把这一课写下来了,逐字可抄:
--     「一条只住在迁移里的 REVOKE,重建出来的库【是开着的】。」
--   ⚠ 视图没有 RLS —— 两张例外表有策略挡着,这张【只有 GRANT 这一层】。
REVOKE ALL ON public.document_relations FROM anon;
GRANT SELECT ON public.document_relations TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
