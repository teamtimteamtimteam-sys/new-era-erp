-- db/migrations/2026-09-29-at1a-record-trail.sql
-- AUDIT-TRAIL-1a —— 每一页底部的审计记录:读法、登记表、逐行读规则、名字解析、"记录开始之前"的那一段(v1.4.33)。
-- 由 db/scripts/build_at1a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(AUDIT-TRAIL-0 Q1–Q43,Tim 2026-09-29 全部照建议裁定)
--   ① 新:record_trail(主语, id, 条数) —— 一页一条记录的审计记录。页面只说主语,不说表名;拒绝一律 RAISE
--      (TRAIL_SUBJECT_UNKNOWN / TRAIL_NOT_PERMITTED),绝不返回空列表。
--   ② 新:登记表 trail_subjects / trail_subject_members / trail_prelog_sources(三个主语:采购单、加工单、角色);
--      逐行读规则 trail_row_visible;名字解析 trail_actor / trail_ref_label / trail_refs / trail_row_record;
--      目录助手 trail_pk_columns / trail_fk_targets / trail_current_image;分界 change_log_began_at。
--   ③ 新:change_log_mask_row —— 从 change_log_rows 的循环体抽出来的【唯一】遮蔽步骤,两个读法共用(Q5)。
--   ④ 替换:change_log_rows —— 同一道门(data.view_change_log),加了按事务分页、按区域 / 记录类型 / 单据号筛选,
--      每一行带回人名、所属单据与引用值的名字;遮蔽改走 ③。★ 签名多了四个带默认值的参数、返回多了四列,
--      所以先 DROP 旧签名再 CREATE(同一笔事务);旧页面用具名参数调它,破窗期间照常工作。
--   ⑤ 替换:change_log_filters —— 同一签名,返回的 jsonb 多了 people / has_system / has_removed 三个键。
--   ⑥ 新:change_log_find_records —— 汇总页按单据号或名字找记录(data.view_change_log)。
--   ⑦ change_log 上两条 GIN 部分索引(Q6)【不在本文件里】—— 在第二个文件 2026-09-29-at1a-record-trail-indexes.sql,
--      用 CREATE INDEX CONCURRENTLY 建,见那个文件的抬头。本文件因此不锁任何一张表。
--
-- 【不做什么】(Q42:只增不改)不重绑任何触发器、不改 change_log 的列、不改 17 张历史表、不写任何业务行、
--   不加新权限码、不碰审批开关与名册、不碰 user_roles / role_permissions。批次页的两张旧视图原样留着(Q32)。
--
-- 【破窗】什么都不坏:旧应用读的表、视图、函数签名都还在;change_log_rows 旧的具名参数照收,多出来的列旧页面不读。
--   本文件只建 / 换函数,不锁表 —— 业务写入在事务期间照常(DROP FUNCTION 只挡住同一时刻调 change_log_rows 的
--   汇总页,那一页等到提交)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;
--   change_log 的行数没变(本迁移一行业务数据都不写);每一张在途单据都还有一个【不是它自己当事人】的决定人;
--   新函数的形状对(DEFINER / 收权);并以 tim@(cfo)的身份真的读一次 PO-2026-0010 的审计记录。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1A_PRE|approvals are expected ON';
    END IF;
    IF to_regproc('public.record_trail') IS NOT NULL THEN
        RAISE EXCEPTION 'AT1A_PRE|record_trail already exists';
    END IF;
    IF to_regprocedure('public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer)') IS NULL THEN
        RAISE EXCEPTION 'AT1A_PRE|change_log_rows has not the HISTORY-1 signature';
    END IF;
    IF (SELECT min(occurred_at) FROM change_log) IS DISTINCT FROM '2026-09-28 23:58:11.294246+08'::timestamptz THEN
        RAISE EXCEPTION 'AT1A_PRE|the change log began at % — change_log_began_at() would be wrong', (SELECT min(occurred_at) FROM change_log);
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE at1a_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';
CREATE TEMP TABLE at1a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE at1a_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;

-- ── 1 · 新函数(镜像原样)────────────────────────────────────────────────────

-- db/functions/change_log_began_at.sql
-- AUDIT-TRAIL-1a(Tim 的 Q1):变更记录【开始记】的那一刻 —— 线上 change_log 第 1 行的 occurred_at
--   (HISTORY-1 迁移自己那一笔,2026-09-28 23:58:11 新加坡时间;量法:SELECT min(occurred_at) FROM change_log,以 postgres 读)。
-- 早于它的历史只能从领域历史表与生命周期戳里拼回来(record_trail 的"记录开始之前"那一段,分界线之下);
-- 晚于它的一切都在 change_log 里。它是【声明的】,不是推出来的 —— 推出来的线会在有人补录一行旧数据的那一刻悄悄移动
-- (与 finance_settings.system_start_date 同一条理由,见 AGENTS.md「Entitlement is DERIVED」)。
CREATE OR REPLACE FUNCTION public.change_log_began_at()
 RETURNS timestamp with time zone
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT '2026-09-28 23:58:11.294246+08'::timestamptz;
$function$;

-- db/functions/change_log_mask_row.sql
-- AUDIT-TRAIL-1a(Tim 的 Q5):遮蔽的【唯一一步】—— 从 change_log_rows 的循环体里抽出来,两个读法共用:
--   /settings/change-history 的 change_log_rows,与每一页底部审计记录的 record_trail。
--   规则仍是 HISTORY-1 那一份 change_log_mask_rules();这里【不加任何一条自己的规则】。
-- 返回 {"old": …, "new": …, "row_restricted": bool}(old/new 为 JSON null 表示影像本身就没有)。
--   任务四张表先问 change_log_task_visible();不过 → 整份影像换成受限标记,row_restricted = true。
--   其余逐列问 change_log_rule_visible();看不见的换成 {"$restricted": true},本来就是 null 的留 null。
-- 【不是 SECURITY DEFINER】只在两支 DEFINER 读法的函数体里以属主身份被调用;EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.change_log_mask_row(p_table text, p_key jsonb, p_old jsonb, p_new jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    m        record;
    v_hidden text[] := ARRAY[]::text[];
BEGIN
    IF p_table IN ('tasks', 'task_nodes', 'task_participants', 'task_history')
       AND NOT change_log_task_visible(p_table, p_key, p_old, p_new) THEN
        RETURN jsonb_build_object('old', change_log_restrict(p_old, NULL),
                                  'new', change_log_restrict(p_new, NULL),
                                  'row_restricted', true);
    END IF;
    FOR m IN SELECT mr.column_name AS m_col, mr.rule AS m_rule
               FROM change_log_mask_rules() mr WHERE mr.table_name = p_table LOOP
        IF (COALESCE(p_old -> m.m_col, 'null'::jsonb) <> 'null'::jsonb
            OR COALESCE(p_new -> m.m_col, 'null'::jsonb) <> 'null'::jsonb)
           AND NOT change_log_rule_visible(m.m_rule, p_table, p_key, p_old, p_new) THEN
            v_hidden := v_hidden || m.m_col;
        END IF;
    END LOOP;
    IF cardinality(v_hidden) > 0 THEN
        RETURN jsonb_build_object('old', change_log_restrict(p_old, v_hidden),
                                  'new', change_log_restrict(p_new, v_hidden),
                                  'row_restricted', false);
    END IF;
    RETURN jsonb_build_object('old', p_old, 'new', p_new, 'row_restricted', false);
END;
$function$;

-- db/functions/trail_pk_columns.sql
-- AUDIT-TRAIL-1a:一张 public 表的主键列(按主键里的顺序)。record_trail 用它把一行拼成 change_log.row_key 的形状。
CREATE OR REPLACE FUNCTION public.trail_pk_columns(p_table text)
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT array_agg(a.attname::text ORDER BY k.ord)
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
      CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
     WHERE c.relname = p_table AND i.indisprimary;
$function$;

-- db/functions/trail_fk_targets.sql
-- AUDIT-TRAIL-1a(Tim 的 Q12 · Q13 · Q40):一张表里【哪些列指着别的记录】,指着哪张表的哪一列。
--   · 单列外键,读目录(pg_constraint),不靠列名猜;
--   · 外加【没有外键的账号列】:uuid 类型、名字以 _by 结尾或叫 actor_user_id —— 它们记的是登录账号
--     (auth.uid()),指向 'auth.users'。created_by / updated_by 也在此列,由界面按 Q12 隐藏。
-- 解析成人读得懂的名字由 trail_ref_label 做;这里只回答"指着谁"。
CREATE OR REPLACE FUNCTION public.trail_fk_targets(p_table text)
 RETURNS TABLE(column_name text, target_table text, target_column text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT a.attname::text, tc.relname::text, ta.attname::text
      FROM pg_constraint k
      JOIN pg_class c ON c.oid = k.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
      JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
      JOIN pg_class tc ON tc.oid = k.confrelid
      JOIN pg_namespace tn ON tn.oid = tc.relnamespace
      JOIN pg_attribute ta ON ta.attrelid = k.confrelid AND ta.attnum = k.confkey[1]
     WHERE c.relname = p_table AND k.contype = 'f' AND cardinality(k.conkey) = 1
       AND tn.nspname = 'public'
    UNION ALL
    SELECT a.attname::text, 'auth.users', 'id'
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
     WHERE c.relname = p_table AND a.attnum > 0 AND NOT a.attisdropped
       AND a.atttypid = 'uuid'::regtype
       AND (a.attname ~ '_by$' OR a.attname IN ('actor_user_id', 'user_id'))
       AND NOT EXISTS (SELECT 1 FROM pg_constraint k2
                        WHERE k2.conrelid = c.oid AND k2.contype = 'f' AND k2.conkey = ARRAY[a.attnum]
                          AND k2.confrelid <> 'auth.users'::regclass);
$function$;

-- db/functions/trail_subjects.sql
-- AUDIT-TRAIL-1a(Tim 的 Q5):审计记录的【主语登记表】。页面只说"哪一种记录、哪一条",从不说表名;
--   表名、根键、以及【这一页自己的查看权限码】只住在这里(服务端)。不在这里的主语 → TRAIL_SUBJECT_UNKNOWN。
-- view_code 与页面守卫逐字同一个码:
--   purchase_order → /purchasing/orders/[id] 的 requireModule(MOD.purchasing) = module.purchasing.view
--   processing_run → /operation/processing/[id] 的 requireModule(MOD.processing) = module.processing.view
--   role           → /settings/roles/[id] 的 requireManagePermissions() = action.manage_permissions
-- 【后面几刀加主语】加一行这里、在 trail_subject_members 里登记它的子行与相关行、需要的话在
--   trail_prelog_sources 里登记"记录开始之前"的来源,然后在 lib/trail/ 里补它的措辞 —— 见 docs/change-log.md §9。
CREATE OR REPLACE FUNCTION public.trail_subjects()
 RETURNS TABLE(subject text, view_code text, root_table text, root_key text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('purchase_order', 'module.purchasing.view',    'purchase_orders', 'id'),
        ('processing_run', 'module.processing.view',    'processing_runs', 'id'),
        ('role',           'action.manage_permissions', 'roles',           'id')
    ) AS s(subject, view_code, root_table, root_key);
$function$;

-- db/functions/trail_subject_members.sql
-- AUDIT-TRAIL-1a(Tim 的 Q3 · Q6):一个主语的审计记录【由哪些行组成】—— 根行之外的子行与相关行。
--   每一行说:这张表里 fk_column 等于 parent_table 某一行的 id 的那些行,属于这条记录;match 是额外的固定条件
--   (多态的 approval_log 靠 subject_type 认主)。parent_table 可以是另一张子表(孙行:付款保留金挂在明细行上)。
--   按 ord 依次展开,所以孙行排在它的父行之后。
-- 【子行是在读的时候找出来的】(Q6)—— 不在记录上写父键。找法见 record_trail:今天还在的行按外键查,
--   已经删掉或改过父键的行从 change_log 的影像里查(GIN 索引 idx_change_log_image / idx_change_log_update_old)。
-- 【每一行子行都要再过一次它自己那张表的读规则】(Q4)—— 由 record_trail 调 trail_row_visible 做,不在这里。
CREATE OR REPLACE FUNCTION public.trail_subject_members()
 RETURNS TABLE(subject text, ord integer, table_name text, parent_table text, fk_column text, match jsonb)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        -- 采购单:明细行 · 付款计划 · 保留金 · 条款承诺 · 签发 · 合同条款 · 审批 · 修改史(Tim 的 AT-1a 范围)
        ('purchase_order', 1, 'purchase_order_lines',           'purchase_orders',      'purchase_order_id',      '{}'::jsonb),
        ('purchase_order', 2, 'purchase_order_payment_terms',   'purchase_orders',      'purchase_order_id',      '{}'::jsonb),
        ('purchase_order', 3, 'purchase_order_line_retentions', 'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb),
        ('purchase_order', 4, 'pricing_term_commitments',       'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb),
        ('purchase_order', 5, 'po_issues',                      'purchase_orders',      'purchase_order_id',      '{}'::jsonb),
        ('purchase_order', 6, 'contract_document_terms',        'purchase_orders',      'purchase_order_id',      '{}'::jsonb),
        ('purchase_order', 7, 'approval_log',                   'purchase_orders',      'subject_id',             '{"subject_type": "purchase_order"}'::jsonb),
        ('purchase_order', 8, 'purchase_order_history',         'purchase_orders',      'purchase_order_id',      '{}'::jsonb),
        -- 加工单:投入 · 产出 · 成本条目及其修改史 · 成本分摊 · 损耗
        ('processing_run', 1, 'processing_inputs',                 'processing_runs', 'run_id', '{}'::jsonb),
        ('processing_run', 2, 'processing_outputs',                'processing_runs', 'run_id', '{}'::jsonb),
        ('processing_run', 3, 'processing_cost_entries',           'processing_runs', 'run_id', '{}'::jsonb),
        ('processing_run', 4, 'processing_cost_entry_history',     'processing_runs', 'run_id', '{}'::jsonb),
        ('processing_run', 5, 'batch_processing_cost_allocations', 'processing_runs', 'run_id', '{}'::jsonb),
        ('processing_run', 6, 'processing_run_losses',             'processing_runs', 'run_id', '{}'::jsonb),
        -- 角色:授权(加上 / 拿掉)
        ('role', 1, 'role_permissions', 'roles', 'role_id', '{}'::jsonb)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match);
$function$;

-- db/functions/trail_prelog_sources.sql
-- AUDIT-TRAIL-1a(Tim 的 Q1):变更记录开始【之前】的历史从哪里拼回来 —— 每张表一行或几行。
--   kind = 'created':这一行本身就是一件事(领域历史表的一行、一次签发、一条授权、一张单据的创建)。
--        at_column / by_column 是它发生的时刻与做它的账号;影像取这一行今天的值
--        (历史表只增不改,所以就是当时的值;单据本身则是今天的值 —— 分界线上的说明句替读者说清楚)。
--   kind = 'stamp':一对生命周期戳(关闭、删除、分摊、释放……)。只知道它【之后】是什么,不知道之前 ——
--        所以拼出来的是一次只有"新值"的改动,changed 列 = at/by + extra 列。
--   by_column 为 NULL:这张表当时没有记人 —— 界面说"Not recorded",不猜。
-- 【绝不重复】(Q1)record_trail 只拼 at_column 早于 change_log_began_at() 的,并且 change_log 里已经记着
--   这一行的 INSERT(created)或这一戳的改动(stamp)时一律跳过 —— 同一件事不会出现两次。
-- 【为什么采购单的取消、批准不在 stamp 里】它们各有一行领域历史(purchase_order_history 'cancelled'、approval_log),
--   再拼一次戳就是两次。
CREATE OR REPLACE FUNCTION public.trail_prelog_sources()
 RETURNS TABLE(table_name text, kind text, at_column text, by_column text, extra text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('purchase_orders',                'created', 'created_at',   'created_by',   NULL::text[]),
        ('purchase_orders',                'stamp',   'closed_at',    NULL,           ARRAY['status']),
        ('purchase_orders',                'stamp',   'deleted_at',   'deleted_by',   ARRAY['delete_reason']),
        ('purchase_order_lines',           'created', 'created_at',   'created_by',   NULL),
        ('purchase_order_payment_terms',   'created', 'created_at',   NULL,           NULL),
        ('purchase_order_payment_terms',   'stamp',   'expected_date_set_at', 'expected_date_set_by', ARRAY['expected_date']),
        ('purchase_order_line_retentions', 'created', 'created_at',   'created_by',   NULL),
        ('purchase_order_line_retentions', 'stamp',   'released_at',  'released_by',  ARRAY['released_amount_ccy', 'withheld_amount_ccy', 'withholding_reason']),
        ('pricing_term_commitments',       'created', 'committed_at', 'committed_by', NULL),
        ('po_issues',                      'created', 'issued_at',    'issued_by',    NULL),
        ('contract_document_terms',        'created', 'linked_at',    'linked_by',    NULL),
        ('approval_log',                   'created', 'decided_at',   'actor_user_id', NULL),
        ('purchase_order_history',         'created', 'changed_at',   'changed_by',   NULL),
        ('processing_runs',                'created', 'created_at',   'created_by',   NULL),
        ('processing_runs',                'stamp',   'allocated_at', 'allocated_by', ARRAY['allocation_basis', 'capitalized_cost_base', 'capitalization_entry_id']),
        ('processing_runs',                'stamp',   'deleted_at',   'deleted_by',   ARRAY['status', 'delete_reason']),
        ('processing_inputs',              'created', 'created_at',   NULL,           NULL),
        ('processing_outputs',             'created', 'created_at',   NULL,           NULL),
        ('processing_cost_entry_history',  'created', 'changed_at',   'changed_by',   NULL),
        ('batch_processing_cost_allocations', 'created', 'created_at', 'created_by',  NULL),
        ('processing_run_losses',          'created', 'created_at',   'created_by',   NULL),
        ('roles',                          'created', 'created_at',   'created_by',   NULL),
        ('roles',                          'stamp',   'deleted_at',   NULL,           ARRAY['is_active']),
        ('role_permissions',               'created', 'created_at',   'created_by',   NULL)
    ) AS p(table_name, kind, at_column, by_column, extra);
$function$;

-- db/functions/trail_current_image.sql
-- AUDIT-TRAIL-1a:一行【今天】的整份样子 —— 还在就读那一行;已经被硬删,就取 change_log 里它最后一份完整影像
--   (DELETE 的 old,或 INSERT 的 new)。两处都没有 → NULL。第二个返回值说它是不是已经不在了。
-- 给 record_trail 用:判这一行过不过它自己那张表的读规则(Q4)、以及给子行一个"这是哪一行"的上下文(第几行、哪个物料)。
-- 【属主身份】按表名动态读任意一张表;EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.trail_current_image(p_table text, p_key jsonb, OUT image jsonb, OUT gone boolean)
 RETURNS record
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_where text;
BEGIN
    gone := false;
    IF p_key IS NULL OR to_regclass(format('public.%I', p_table)) IS NULL THEN
        image := NULL;
        RETURN;
    END IF;
    SELECT string_agg(format('t.%I::text = %L', k.key, k.value), ' AND ')
      INTO v_where FROM jsonb_each_text(p_key) k;
    EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE %s LIMIT 1', p_table, v_where) INTO image;
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

-- db/functions/trail_row_visible.sql
-- AUDIT-TRAIL-1a(Tim 的 Q4 · Q5):【当前读者】能不能读这一行 —— 按【这一行自己那张表】的读规则,不按父记录的。
--   record_trail 是 SECURITY DEFINER(change_log 对应用角色没有任何授权),而 DEFINER 里做不了 SET ROLE,
--   所以这里把那张表的 SELECT 策略(permissive 的 SELECT 与 ALL,给 authenticated 或 public 的)用 OR 拼起来,
--   对着那一行重新求一次值。这样做是对的,因为实测(AUDIT-TRAIL-0 reader-masking.md §1.6):线上 287 条读策略
--   0 条 restrictive、0 条依赖数据库角色 —— 全部经 has_permission() / current_user_employee() 从登录的 JWT 认人。
--   restrictive 策略若将来出现,在这里用 AND 接上(已经写好)。
--   · 表没开 RLS → 看 authenticated 有没有任何一列的 SELECT 权限;
--   · authenticated 连一列都读不了(cod_verification_failures 那种没有读策略的表)→ 看不见;
--   · 这一行已被硬删 → 对它最后一份影像求同一个值(jsonb_populate_record,别名就是表名,于是带表名限定的列引用照样解析)。
--   ☞ 已知边界(reader-masking.md §1.6 已记):策略里 EXISTS 子查询读的别的表,在 DEFINER 里不再过那张表的 RLS。
--     线上两处这种策略的子查询都自己写全了条件,所以结果相同。
-- 【属主身份】EXECUTE 已从 authenticated 收回 —— 否则它就是一支"任意一行你看不看得见"的探针。
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
BEGIN
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
       AND p.qual IS NOT NULL;
    v_perm := '(' || v_perm || ')' || COALESCE(' AND (' || v_restr || ')', '');

    SELECT string_agg(format('%I.%I::text = %L', p_table, k.key, k.value), ' AND ')
      INTO v_where FROM jsonb_each_text(p_key) k;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%1$I %1$I WHERE %2$s)', p_table, v_where) INTO v_live;
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

-- db/functions/trail_actor.sql
-- AUDIT-TRAIL-1a(Tim 的 Q14 · Q17 · Q18):"谁做的" —— 一份答法,两个读法共用。返回 {"state": …, "name": …}:
--   person     有一个人:称呼名,没有就用法定名(Q14;与 ActorName 同一个取法)。停用的账号照样印名字,不加任何字(Q17)。
--   anonymised 那个人已经被匿名化 —— 名字被抹掉是设计,界面说 "A former employee"。
--   system     没有登录会话的写:迁移、服务任务、fixture(Q17 · Q18,一律 "System (automatic)")。
--   removed    记下的是一个账号,而账号与人都已经不在了(Q17,"Removed account")。
--   unlinked   账号还在,但写入那一刻它不属于任何人(只有测试账号会这样)。
--   unknown    "记录开始之前"的那一段,当时那张表没有记人(p_kind = 'prelog' 且没有账号)—— 界面说 "Not recorded",不猜。
-- p_kind:change_log.actor_kind('user' / 'no_session'),或 'prelog'(从生命周期戳拼回来的行:只有账号,人按今天的链接认)。
-- 人名取自 employees(已被硬删的,取 change_log 里它最后一份影像)。【属主身份】EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.trail_actor(p_kind text, p_account uuid, p_employee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp jsonb;
    v_id  uuid := p_employee;
BEGIN
    IF p_kind = 'no_session' THEN
        RETURN jsonb_build_object('state', 'system');
    END IF;
    IF v_id IS NULL AND p_kind = 'prelog' AND p_account IS NOT NULL THEN
        v_id := account_person(p_account);
    END IF;
    IF v_id IS NULL THEN
        IF p_account IS NULL THEN
            RETURN jsonb_build_object('state', CASE WHEN p_kind = 'prelog' THEN 'unknown' ELSE 'removed' END);
        END IF;
        RETURN jsonb_build_object('state',
            CASE WHEN EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_account) THEN 'unlinked' ELSE 'removed' END);
    END IF;
    SELECT to_jsonb(e) INTO v_emp FROM employees e WHERE e.id = v_id;
    IF v_emp IS NULL THEN
        SELECT CASE WHEN c.op = 'DELETE' THEN c.old ELSE c.new END INTO v_emp
          FROM change_log c
         WHERE c.table_name = 'employees' AND c.row_key = jsonb_build_object('id', v_id) AND c.op IN ('INSERT', 'DELETE')
         ORDER BY c.seq DESC LIMIT 1;
    END IF;
    IF v_emp IS NULL THEN
        RETURN jsonb_build_object('state', 'removed');
    END IF;
    IF v_emp ->> 'anonymised_at' IS NOT NULL
       OR COALESCE(NULLIF(v_emp ->> 'preferred_name', ''), NULLIF(v_emp ->> 'legal_name', '')) IS NULL THEN
        RETURN jsonb_build_object('state', 'anonymised');
    END IF;
    RETURN jsonb_build_object('state', 'person',
        'name', COALESCE(NULLIF(v_emp ->> 'preferred_name', ''), v_emp ->> 'legal_name'));
END;
$function$;

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
BEGIN
    IF p_value IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_table = 'auth.users' THEN
        IF p_value !~ '^[0-9a-fA-F-]{36}$' THEN
            RETURN NULL;
        END IF;
        RETURN jsonb_build_object('person', trail_actor('prelog', p_value::uuid, NULL));
    END IF;
    IF to_regclass(format('public.%I', p_table)) IS NULL THEN
        RETURN NULL;
    END IF;
    EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.%I::text = $1 LIMIT 1', p_table, p_column)
       INTO v_img USING p_value;
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
        WHEN p_table = 'purchase_order_lines' THEN
            (SELECT po.code FROM purchase_orders po WHERE po.id::text = v_img ->> 'purchase_order_id')
            || ' line ' || (v_img ->> 'line_no')
        WHEN v_doc AND v_img ? 'code' THEN v_img ->> 'code'
        WHEN v_img ? 'name_en' THEN v_img ->> 'name_en'
        WHEN v_img ? 'name' THEN v_img ->> 'name'
        WHEN v_img ? 'legal_name' THEN v_img ->> 'legal_name'
        WHEN v_img ? 'title' THEN v_img ->> 'title'
        WHEN v_img ? 'label' THEN v_img ->> 'label'
    END;
    IF p_table IN ('inbound_batches', 'output_batches') THEN
        IF v_img ->> 'material_id' IS NOT NULL THEN
            SELECT m.name INTO v_extra FROM materials m WHERE m.id::text = v_img ->> 'material_id';
            IF v_extra IS NOT NULL THEN
                v_label := v_label || ' · ' || v_extra;
            END IF;
        END IF;
        -- 批次的数量单位随名字一起带回 —— 加工单的"用了 300"要说成"300 kg",而投入 / 产出行自己没有单位列
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone, 'unit', v_img ->> 'unit');
    END IF;
    RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone);
END;
$function$;

-- db/functions/trail_refs.sql
-- AUDIT-TRAIL-1a(Tim 的 Q40):一行记录里【每一个指着别处的值】→ 它的名字。形状:
--   {"<列>": {"<原值>": {"label": …, "gone": …} | {"person": {…}}}}
--   扫的是这一行的旧影像、新影像与上下文影像(ctx,这一行今天的样子)里出现的值;受限标记与 null 不解析。
--   哪些列是引用由 trail_fk_targets 回答(目录里的外键 + 没有外键的账号列)。
-- 两个读法(record_trail · change_log_rows)共用。【属主身份】EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.trail_refs(p_table text, p_old jsonb, p_new jsonb, p_ctx jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    f     record;
    v     text;
    v_out jsonb := '{}'::jsonb;
    v_col jsonb;
BEGIN
    FOR f IN SELECT * FROM trail_fk_targets(p_table) LOOP
        v_col := '{}'::jsonb;
        FOR v IN SELECT DISTINCT x.val
                   FROM (SELECT p_old -> f.column_name AS j UNION ALL SELECT p_new -> f.column_name
                         UNION ALL SELECT p_ctx -> f.column_name) s
                   CROSS JOIN LATERAL (SELECT s.j #>> '{}' AS val) x
                  WHERE s.j IS NOT NULL AND jsonb_typeof(s.j) IN ('string', 'number') LOOP
            v_col := v_col || jsonb_build_object(v, trail_ref_label(f.target_table, f.target_column, v));
        END LOOP;
        IF v_col <> '{}'::jsonb THEN
            v_out := v_out || jsonb_build_object(f.column_name, v_col);
        END IF;
    END LOOP;
    RETURN v_out;
END;
$function$;

-- db/functions/trail_row_record.sql
-- AUDIT-TRAIL-1a(Tim 的 Q30):/settings/change-history 的"Record"一栏 —— 一行记录【属于哪一张单据 / 哪一条记录】。
--   先后:① 这张表本身是单据(document_types)→ 它自己;② 它是某个审计记录主语的子行 / 孙行 / 相关行
--   (trail_subject_members)→ 沿父键走到那条根记录;③ 它有一列指着某张单据 → 那张单据;④ 都不是 → 它自己。
--   返回 {"table", "id", "label", "gone", "doc_key", "route", "link_mode"}(后三项只在它是单据时有,界面据此造链接)。
--   外键值从这一次的影像取,取不到再取这一行今天的样子(一次编辑只记改了的那几列)。
-- 【属主身份】EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.trail_row_record(p_table text, p_key jsonb, p_old jsonb, p_new jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_img   jsonb;
    v_cur   record;
    v_table text := p_table;
    v_id    text;
    v_pk    text[];
    m       record;
    f       record;
    v_hops  integer := 0;
    v_lab   jsonb;
    v_dkey  text;
    v_route text;
    v_mode  text;
BEGIN
    IF p_key IS NULL OR to_regclass(format('public.%I', p_table)) IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_cur FROM trail_current_image(p_table, p_key);
    v_img := COALESCE(v_cur.image, '{}'::jsonb) || COALESCE(p_old, '{}'::jsonb) || COALESCE(p_new, '{}'::jsonb);
    v_pk := trail_pk_columns(p_table);
    v_id := CASE WHEN cardinality(v_pk) = 1 THEN p_key ->> v_pk[1] END;

    IF NOT EXISTS (SELECT 1 FROM document_types dt WHERE dt.table_name = p_table)
       AND NOT EXISTS (SELECT 1 FROM trail_subjects() ts WHERE ts.root_table = p_table) THEN
        -- ② 登记过的子行:沿父键往上走,最多三跳
        LOOP
            SELECT tm.* INTO m FROM trail_subject_members() tm WHERE tm.table_name = v_table ORDER BY tm.subject, tm.ord LIMIT 1;
            EXIT WHEN NOT FOUND OR v_hops >= 3 OR v_img ->> m.fk_column IS NULL;
            v_table := m.parent_table;
            v_id := v_img ->> m.fk_column;
            v_hops := v_hops + 1;
            SELECT * INTO v_cur FROM trail_current_image(v_table, jsonb_build_object('id', v_id));
            v_img := COALESCE(v_cur.image, '{}'::jsonb);
        END LOOP;
        -- ③ 没走动:找第一列指着单据的外键
        IF v_hops = 0 THEN
            FOR f IN SELECT ft.* FROM trail_fk_targets(p_table) ft
                      WHERE ft.target_table IN (SELECT dt.table_name FROM document_types dt)
                        AND ft.column_name NOT IN ('created_by', 'updated_by') LOOP
                IF v_img ->> f.column_name IS NOT NULL THEN
                    v_table := f.target_table;
                    v_id := v_img ->> f.column_name;
                    EXIT;
                END IF;
            END LOOP;
        END IF;
    END IF;
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('table', v_table, 'id', NULL, 'label', NULL, 'gone', false);
    END IF;
    v_lab := trail_ref_label(v_table, COALESCE((trail_pk_columns(v_table))[1], 'id'), v_id);
    SELECT dt.key, dt.route, dt.link_mode INTO v_dkey, v_route, v_mode FROM document_types dt WHERE dt.table_name = v_table ORDER BY dt.key LIMIT 1;
    RETURN jsonb_build_object('table', v_table, 'id', v_id,
        'label', v_lab ->> 'label', 'gone', COALESCE((v_lab ->> 'gone')::boolean, false),
        'doc_key', v_dkey, 'route', v_route, 'link_mode', v_mode);
END;
$function$;

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
CREATE OR REPLACE FUNCTION public.record_trail(p_subject text, p_id text, p_entries integer DEFAULT 20)
 RETURNS TABLE(entry_no integer, prelog boolean, seq bigint, occurred_at timestamp with time zone, table_name text, row_key jsonb, op text, actor jsonb, changed_columns text[], old jsonb, new jsonb, ctx jsonb, refs jsonb, row_hidden boolean, row_restricted boolean, more boolean)
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
BEGIN
    SELECT ts.* INTO s FROM trail_subjects() ts WHERE ts.subject = p_subject;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRAIL_SUBJECT_UNKNOWN|%', COALESCE(p_subject, '');
    END IF;
    IF NOT has_permission(s.view_code) THEN
        RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;
    END IF;
    v_root := jsonb_build_object(s.root_key, p_id);
    SELECT * INTO v_img FROM trail_current_image(s.root_table, v_root);
    IF v_img.image IS NULL OR NOT trail_row_visible(s.root_table, v_root, v_img.image) THEN
        RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;
    END IF;
    v_tabs := ARRAY[s.root_table];
    v_keys := ARRAY[v_root];

    -- ① 这条记录有哪些行(按 ord 展开,孙行在父行之后)
    FOR m IN SELECT tm.* FROM trail_subject_members() tm WHERE tm.subject = p_subject ORDER BY tm.ord LOOP
        SELECT array_agg(DISTINCT u.k ->> 'id') INTO v_pids
          FROM unnest(v_tabs, v_keys) AS u(t, k) WHERE u.t = m.parent_table AND u.k ? 'id';
        CONTINUE WHEN v_pids IS NULL;
        v_pk := trail_pk_columns(m.table_name);
        EXECUTE format('SELECT array_agg(jsonb_build_object(%s)) FROM public.%I t WHERE t.%I::text = ANY ($1) AND to_jsonb(t) @> $2',
                       (SELECT string_agg(format('%L, t.%I', c, c), ', ') FROM unnest(v_pk) c),
                       m.table_name, m.fk_column)
           INTO v_found USING v_pids, m.match;
        SELECT array_agg(DISTINCT c.row_key) INTO v_found2
          FROM unnest(v_pids) AS pid(v)
          JOIN change_log c ON c.table_name = m.table_name
                           AND (COALESCE(c.new, c.old) @> (jsonb_build_object(m.fk_column, pid.v) || m.match)
                                OR (c.op = 'UPDATE' AND c.old @> jsonb_build_object(m.fk_column, pid.v)));
        FOR v_k IN SELECT DISTINCT x FROM unnest(COALESCE(v_found, ARRAY[]::jsonb[]) || COALESCE(v_found2, ARRAY[]::jsonb[])) x
                    WHERE x IS NOT NULL LOOP
            IF NOT EXISTS (SELECT 1 FROM unnest(v_tabs, v_keys) u(t, k) WHERE u.t = m.table_name AND u.k = v_k) THEN
                v_tabs := array_append(v_tabs, m.table_name);
                v_keys := array_append(v_keys, v_k);
            END IF;
        END LOOP;
    END LOOP;

    -- ② 每一行:过不过它自己那张表的读规则;今天的样子(遮蔽之后);"记录开始之前"的那一段从哪里拼
    FOR i IN 1 .. cardinality(v_tabs) LOOP
        SELECT * INTO v_img FROM trail_current_image(v_tabs[i], v_keys[i]);
        v_vis := array_append(v_vis, i = 1 OR COALESCE(trail_row_visible(v_tabs[i], v_keys[i], v_img.image), false));
        IF v_vis[i] AND v_img.image IS NOT NULL THEN
            v_mask := change_log_mask_row(v_tabs[i], v_keys[i], NULL, v_img.image);
            v_ctx := array_append(v_ctx, COALESCE(NULLIF(v_mask -> 'new', 'null'::jsonb), '{}'::jsonb)
                                         || jsonb_build_object('$gone', v_img.gone));
            v_crefs := array_append(v_crefs, trail_refs(v_tabs[i], NULL, NULL, v_ctx[i]));
        ELSE
            v_ctx := array_append(v_ctx, NULL::jsonb);
            v_crefs := array_append(v_crefs, '{}'::jsonb);
        END IF;
        CONTINUE WHEN v_img.image IS NULL OR v_img.gone;
        FOR p IN SELECT ps.* FROM trail_prelog_sources() ps WHERE ps.table_name = v_tabs[i] LOOP
            v_at := NULLIF(v_img.image ->> p.at_column, '')::timestamptz;
            CONTINUE WHEN v_at IS NULL OR v_at >= v_began;
            IF p.kind = 'created' THEN
                CONTINUE WHEN EXISTS (SELECT 1 FROM change_log c
                                       WHERE c.table_name = v_tabs[i] AND c.row_key = v_keys[i] AND c.op = 'INSERT');
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
                'account', CASE WHEN p.by_column IS NULL THEN NULL ELSE v_img.image -> p.by_column END));
        END LOOP;
    END LOOP;

    -- ③ 变更记录 + 拼回来的那一段,按记录(事务)编号,从新到旧
    SELECT count(DISTINCT g) INTO v_total FROM (
        SELECT 'L' || c.txid AS g
          FROM unnest(v_tabs, v_keys) u(t, k) JOIN change_log c ON c.table_name = u.t AND c.row_key = u.k
        UNION ALL
        SELECT 'P' || (x ->> 'at') FROM jsonb_array_elements(v_pseudo) x) z;

    FOR r IN
        WITH k AS (
            SELECT u.t, u.k, u.i::integer AS i FROM unnest(v_tabs, v_keys) WITH ORDINALITY u(t, k, i)),
        allr AS (
            SELECT c.seq AS a_seq, c.occurred_at AS a_at, 'L' || c.txid AS a_g, k.i AS a_i, c.op AS a_op,
                   c.actor_kind AS a_kind, c.actor_account AS a_account, c.actor_employee AS a_employee,
                   c.changed_columns AS a_cols, c.old AS a_old, c.new AS a_new, false AS a_pre
              FROM k JOIN change_log c ON c.table_name = k.t AND c.row_key = k.k
            UNION ALL
            SELECT NULL::bigint, (x ->> 'at')::timestamptz, 'P' || (x ->> 'at'), (x ->> 'i')::integer, x ->> 'op',
                   'prelog', (x ->> 'account')::uuid, NULL::uuid,
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

-- db/functions/change_log_find_records.sql
-- AUDIT-TRAIL-1a(Tim 的 Q30):/settings/change-history 的"Record"筛选 —— 按【单据号或名字】找,不再要人输入 uuid。
--   返回找到的那些记录的 id(文本),交给 change_log_rows(p_record_ids => …):
--   · 单据号(document_types 登记的表的 code,大小写不论,整串相等)—— 今天还在的,与已经被删、只剩记录影像的;
--   · 名字(包含即可,大小写不论):供应商 / 客户的法定名、物料名、员工的称呼名与法定名、角色的英文名。
--   最多 50 个。门与 change_log_rows 相同。
CREATE OR REPLACE FUNCTION public.change_log_find_records(p_text text)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_q   text := btrim(COALESCE(p_text, ''));
    v_ids text[] := ARRAY[]::text[];
    v_one text[];
    d     record;
BEGIN
    PERFORM require_permission('data.view_change_log');
    IF length(v_q) < 2 THEN
        RETURN v_ids;
    END IF;
    FOR d IN SELECT DISTINCT dt.table_name FROM document_types dt LOOP
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_attribute a
                                   WHERE a.attrelid = format('public.%I', d.table_name)::regclass
                                     AND a.attname = 'code' AND NOT a.attisdropped);
        EXECUTE format('SELECT array_agg(t.id::text) FROM public.%I t WHERE upper(t.code) = upper($1)', d.table_name)
           INTO v_one USING v_q;
        v_ids := v_ids || COALESCE(v_one, ARRAY[]::text[]);
    END LOOP;
    v_ids := v_ids || COALESCE((SELECT array_agg(DISTINCT c.row_key ->> 'id') FROM change_log c
                                  WHERE COALESCE(c.new, c.old) @> jsonb_build_object('code', upper(v_q))
                                    AND c.row_key ? 'id'), ARRAY[]::text[]);
    v_ids := v_ids || COALESCE((SELECT array_agg(x.id) FROM (
                 SELECT s.id::text AS id FROM suppliers s WHERE s.legal_name ILIKE '%' || v_q || '%'
                 UNION SELECT c.id::text FROM customers c WHERE c.legal_name ILIKE '%' || v_q || '%'
                 UNION SELECT m.id::text FROM materials m WHERE m.name ILIKE '%' || v_q || '%'
                 UNION SELECT e.id::text FROM employees e
                        WHERE e.anonymised_at IS NULL
                          AND (e.legal_name ILIKE '%' || v_q || '%' OR e.preferred_name ILIKE '%' || v_q || '%')
                 UNION SELECT r.id::text FROM roles r WHERE r.name_en ILIKE '%' || v_q || '%') x), ARRAY[]::text[]);
    RETURN (SELECT array_agg(DISTINCT x) FROM (SELECT unnest(v_ids) x LIMIT 50) z);
END;
$function$;

-- ── 2 · 替换:汇总页的两支读法(镜像原样)。change_log_rows 换签名 —— 先 DROP 旧的 ───────

DROP FUNCTION public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer);

-- db/functions/change_log_rows.sql
-- HISTORY-1(Tim 的 Q10 · Q26 · Q6):变更记录的【唯一】全局读法。/settings/change-history 读它。
-- AUDIT-TRAIL-1a(Tim 的 Q5 · Q30 · Q31 · Q40):仍是这一支、仍是这一道门;加了读法,没有放宽。
--
-- 【门】data.view_change_log(只授 admin 与 cfo,不捆进任何别的角色)。没有它 → PERMISSION_DENIED。
-- 【遮蔽】逐行走 change_log_mask_row —— 与每一页底部的审计记录(record_trail)【同一步】(Q5),规则仍是
--   HISTORY-1 的 change_log_mask_rules():读者在源屏幕上看不见的值换成 {"$restricted": true},本来就是 null 的留 null;
--   任务四张表先问 change_log_task_visible(),不过 → 整份影像受限(row_restricted = true)。
-- 【筛选】日期(按库时区 Asia/Singapore,to 含当天)· 表(p_table 一张,或 p_tables 一组 —— "Area"与"Record type")·
--   记录(p_record:主键里任一值等于它;p_record_ids:主键里任一值在这一组里 —— 按单据号或名字找到的,见
--   change_log_find_records)· 人(账号 id 或员工 id 任一相等)· 只看无会话的写 · 只看"Removed account"的写。
-- 【分页】按 seq 倒序,键集分页(p_before)。p_by_entry = false:每页 p_limit 行(HISTORY-1 的原样);
--   p_by_entry = true:每页 p_limit 笔【事务】(一次操作一条,Q2),返回这些事务里符合筛选的全部行,
--   p_before 比的是一笔事务里最大的 seq。
-- 【每一行多带回】txid · actor(trail_actor:人名 / System (automatic) / Removed account …)·
--   belongs_to(trail_row_record:这一行属于哪张单据 / 哪条记录)· refs(trail_refs:每个引用值 → 名字)。
--   任务隐私受限的行不带 belongs_to 与 refs —— 任务标题本身就是被藏起来的东西。
-- 【它仍然列出每一次写入】(Q31):系统的、冒烟的、账号事件的,一行不少。
-- 【SECURITY DEFINER 的理由】change_log 对应用角色没有任何授权;读 auth.users 取邮箱与账号是否还在。
CREATE OR REPLACE FUNCTION public.change_log_rows(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_table text DEFAULT NULL::text, p_record text DEFAULT NULL::text, p_actor uuid DEFAULT NULL::uuid, p_no_session boolean DEFAULT false, p_before bigint DEFAULT NULL::bigint, p_limit integer DEFAULT 50, p_tables text[] DEFAULT NULL::text[], p_removed_account boolean DEFAULT false, p_by_entry boolean DEFAULT false, p_record_ids text[] DEFAULT NULL::text[])
 RETURNS TABLE(seq bigint, occurred_at timestamp with time zone, table_name text, row_key jsonb, op text, actor_account uuid, actor_email text, actor_employee uuid, actor_employee_code text, actor_employee_name text, actor_kind text, db_role text, changed_columns text[], old jsonb, new jsonb, redacted_at timestamp with time zone, row_restricted boolean, txid bigint, actor jsonb, belongs_to jsonb, refs jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    r        record;
    v_mask   jsonb;
    v_limit  integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
    v_txids  bigint[];
BEGIN
    PERFORM require_permission('data.view_change_log');

    IF COALESCE(p_by_entry, false) THEN
        SELECT array_agg(g.g_tx ORDER BY g.g_mx DESC) INTO v_txids FROM (
            SELECT c.txid AS g_tx, max(c.seq) AS g_mx
              FROM change_log c
             WHERE (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
               AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
               AND (p_table IS NULL OR c.table_name = p_table)
               AND (p_tables IS NULL OR c.table_name = ANY (p_tables))
               AND (p_record IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = p_record))
               AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = ANY (p_record_ids)))
               AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
               AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
               AND (NOT COALESCE(p_removed_account, false)
                    OR (c.actor_kind = 'user' AND c.actor_employee IS NULL
                        AND NOT EXISTS (SELECT 1 FROM auth.users u2 WHERE u2.id = c.actor_account)))
             GROUP BY c.txid
            HAVING p_before IS NULL OR max(c.seq) < p_before
             ORDER BY max(c.seq) DESC
             LIMIT v_limit) g;
        IF v_txids IS NULL THEN
            RETURN;
        END IF;
    END IF;

    FOR r IN
        SELECT c.seq AS c_seq, c.occurred_at AS c_at, c.table_name AS c_table, c.row_key AS c_key,
               c.op AS c_op, c.actor_account AS c_account, u.email::text AS c_email,
               c.actor_employee AS c_employee, e.code AS c_emp_code,
               COALESCE(e.preferred_name, e.legal_name) AS c_emp_name,
               c.actor_kind AS c_kind, c.db_role AS c_role, c.changed_columns AS c_cols,
               c.old AS c_old, c.new AS c_new, c.redacted_at AS c_redacted, c.txid AS c_tx
          FROM change_log c
          LEFT JOIN auth.users u ON u.id = c.actor_account
          LEFT JOIN employees e ON e.id = c.actor_employee
         WHERE (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
           AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
           AND (p_table IS NULL OR c.table_name = p_table)
           AND (p_tables IS NULL OR c.table_name = ANY (p_tables))
           AND (p_record IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = p_record))
           AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = ANY (p_record_ids)))
           AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
           AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
           AND (NOT COALESCE(p_removed_account, false)
                OR (c.actor_kind = 'user' AND c.actor_employee IS NULL AND u.id IS NULL))
           AND (CASE WHEN COALESCE(p_by_entry, false) THEN c.txid = ANY (v_txids)
                     ELSE (p_before IS NULL OR c.seq < p_before) END)
         ORDER BY c.seq DESC
         LIMIT CASE WHEN COALESCE(p_by_entry, false) THEN NULL ELSE v_limit END
    LOOP
        seq := r.c_seq;
        occurred_at := r.c_at;
        table_name := r.c_table;
        row_key := r.c_key;
        op := r.c_op;
        actor_account := r.c_account;
        actor_email := r.c_email;
        actor_employee := r.c_employee;
        actor_employee_code := r.c_emp_code;
        actor_employee_name := r.c_emp_name;
        actor_kind := r.c_kind;
        db_role := r.c_role;
        changed_columns := r.c_cols;
        redacted_at := r.c_redacted;
        txid := r.c_tx;
        actor := trail_actor(r.c_kind, r.c_account, r.c_employee);

        v_mask := change_log_mask_row(r.c_table, r.c_key, r.c_old, r.c_new);
        old := NULLIF(v_mask -> 'old', 'null'::jsonb);
        new := NULLIF(v_mask -> 'new', 'null'::jsonb);
        row_restricted := (v_mask ->> 'row_restricted')::boolean;
        IF row_restricted OR r.c_table = 'auth.users' THEN
            belongs_to := NULL;
            refs := '{}'::jsonb;
        ELSE
            belongs_to := trail_row_record(r.c_table, r.c_key, old, new);
            refs := trail_refs(r.c_table, old, new, r.c_key);
        END IF;
        RETURN NEXT;
    END LOOP;
END;
$function$;

-- db/functions/change_log_filters.sql
-- HISTORY-1:/settings/change-history 下拉的选项。门与 change_log_rows 相同。
--   tables —— 挂着记录触发器的表 + 'auth.users'(账号事件)。AUDIT-TRAIL-1a 起界面不再印它们,而是按
--             lib/trail/tables.ts 翻成英文的"Area"与"Record type";这里仍给出那张闭合的名单,界面拿它对账。
--   actors —— 记录里出现过的每一个账号(HISTORY-1 的形状,旧页面在破窗期间还读它)。
--   people —— AUDIT-TRAIL-1a(Tim 的 Q14 · Q30):"Who"下拉按【人】列,名字是称呼名、没有就法定名;
--             外加两项:有没有无会话的写("System (automatic)")、有没有账号与人都已不在的写("Removed account")。
CREATE OR REPLACE FUNCTION public.change_log_filters()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('data.view_change_log');
    RETURN jsonb_build_object(
        'tables', (SELECT COALESCE(jsonb_agg(x.t ORDER BY x.t), '[]'::jsonb) FROM (
                      SELECT c.relname::text AS t
                        FROM pg_trigger tg
                        JOIN pg_class c ON c.oid = tg.tgrelid
                        JOIN pg_namespace n ON n.oid = c.relnamespace
                       WHERE n.nspname = 'public' AND tg.tgname = 'zzz_change_log'
                      UNION SELECT 'auth.users') x),
        'actors', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                          'account', a.actor_account, 'email', u.email::text,
                          'employee_code', e.code, 'employee_name', COALESCE(e.preferred_name, e.legal_name))
                        ORDER BY u.email::text NULLS LAST, a.actor_account), '[]'::jsonb)
                     FROM (SELECT DISTINCT ON (cl.actor_account) cl.actor_account, cl.actor_employee
                             FROM change_log cl
                            WHERE cl.actor_account IS NOT NULL
                            ORDER BY cl.actor_account, cl.seq DESC) a
                     LEFT JOIN auth.users u ON u.id = a.actor_account
                     LEFT JOIN employees e ON e.id = a.actor_employee),
        'people', (SELECT COALESCE(jsonb_agg(jsonb_build_object('employee', p.actor_employee, 'actor', p.who)
                        ORDER BY p.who ->> 'name' NULLS LAST, p.actor_employee), '[]'::jsonb)
                     FROM (SELECT DISTINCT cl.actor_employee,
                                  trail_actor('user', NULL, cl.actor_employee) AS who
                             FROM change_log cl WHERE cl.actor_employee IS NOT NULL) p),
        'has_system', EXISTS (SELECT 1 FROM change_log cl WHERE cl.actor_kind = 'no_session'),
        'has_removed', EXISTS (SELECT 1 FROM change_log cl
                                WHERE cl.actor_kind = 'user' AND cl.actor_employee IS NULL
                                  AND NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = cl.actor_account)));
END;
$function$;

-- ── 3 · 内层函数收权(与 db/views/zzz_function_grants.sql 同一段;apply_migration.sh 之后还会整份重放)──
REVOKE EXECUTE ON FUNCTION public.change_log_began_at() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.change_log_began_at() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.change_log_mask_row(text, jsonb, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.change_log_mask_row(text, jsonb, jsonb, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.trail_pk_columns(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trail_pk_columns(text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.trail_fk_targets(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trail_fk_targets(text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.trail_subjects() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trail_subjects() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.trail_subject_members() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trail_subject_members() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.trail_prelog_sources() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trail_prelog_sources() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.trail_current_image(text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trail_current_image(text, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.trail_row_visible(text, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trail_row_visible(text, jsonb, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.trail_actor(text, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trail_actor(text, uuid, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.trail_ref_label(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trail_ref_label(text, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.trail_refs(text, jsonb, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trail_refs(text, jsonb, jsonb, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.trail_row_record(text, jsonb, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trail_row_record(text, jsonb, jsonb, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_trail(text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_trail(text, text, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.change_log_find_records(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.change_log_find_records(text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer, text[], boolean, boolean, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer, text[], boolean, boolean, text[]) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.change_log_mask_row(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_current_image(text, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_ref_label(text, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_refs(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_row_record(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_row_visible(text, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_actor(text, uuid, uuid) FROM authenticated;

-- ── 4 · 自证 ─────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.at1a_pending_decider_check(p_after boolean DEFAULT true)
 RETURNS TABLE(k text, doc text, raiser text, subject text, deciders int, decider_names text)
 LANGUAGE sql STABLE
AS $f$
WITH fs AS (SELECT approval_level1_role_code AS l1, approval_level2_role_code AS l2 FROM public.finance_settings),
real_perm AS (
    SELECT DISTINCT rp.permission_code, rg.user_id
      FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     CROSS JOIN LATERAL public.real_role_grants(r.code) rg),
people AS (SELECT DISTINCT user_id FROM real_perm),
holds AS (SELECT user_id, array_agg(permission_code) AS codes FROM real_perm GROUP BY user_id),
items AS (
    -- 报销单:分档链,直接问 approval_deciders
    SELECT 'expense_claim'::text AS k, c.code::text AS doc, c.created_by AS raiser, c.employee_id AS subj,
           d.user_id AS u
      FROM public.expense_claims c CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim',
                 public.approval_level_for((SELECT b.amount_base FROM public.expense_claim_amount_base(c.id) b)),
                 c.created_by, c.employee_id, fs.l1, fs.l2) d ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- 采购单:分档链;金额档位按更严的二级问(一级的资格 ⊇ 二级,R1)
    SELECT 'purchase_order', p.code, p.created_by, NULL,
           d.user_id
      FROM public.purchase_orders p CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('purchase_order', 'approve_purchase_order', 2::smallint,
                 p.created_by, NULL, fs.l1, fs.l2) d ON true
     WHERE p.approval_status = 'pending' AND p.deleted_at IS NULL
    UNION ALL
    -- 请假:decide_leave_request 的门(之前 module.hr.edit,之后 action.decide_hr_requests)
    --       + 余额函数要 module.hr.view(或本人)+ 四眼(R2 之后覆盖请假)
    SELECT 'leave_request', l.code, l.created_by, l.employee_id, h.user_id
      FROM public.leave_requests l CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = l.employee_id)
                       AND (public.self_leg(l.created_by, l.employee_id, h.user_id) = 'none'
                            OR (p_after AND public.self_approval_exception('leave_request', l.employee_id, h.user_id, fs.l2)))
     WHERE l.status = 'pending' AND l.deleted_at IS NULL
    UNION ALL
    SELECT 'medical_claim_submitted', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = m.employee_id)
                       AND (public.self_leg(m.created_by, m.employee_id, h.user_id) = 'none'
                            OR public.self_approval_exception('medical_claim', m.employee_id, h.user_id, fs.l2))
     WHERE m.status = 'submitted' AND m.deleted_at IS NULL
    UNION ALL
    -- 已批未付的医疗申报:pay_medical_claim 只要 module.finance.edit,没有自付检查(量过,Tim 的矩阵允许)
    SELECT 'medical_claim_approved (pay)', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m
      LEFT JOIN holds h ON 'module.finance.edit' = ANY (h.codes)
     WHERE m.status = 'approved' AND m.deleted_at IS NULL
    UNION ALL
    SELECT 'performance_review', r.id::text, r.submitted_by, r.employee_id, h.user_id
      FROM public.performance_reviews r
      LEFT JOIN holds h ON (CASE WHEN p_after THEN public.review_approval_code(r.submitted_by, r.employee_id)
                                 ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND public.self_leg(r.submitted_by, r.employee_id, h.user_id) = 'none'
     WHERE r.status = 'submitted'
    UNION ALL
    SELECT 'work_order', w.code, w.created_by, NULL, h.user_id
      FROM public.work_orders w
      -- ROLE-1 Batch 3b:下达归 action.wo_release;建单人不算(按人认)
      LEFT JOIN holds h ON 'action.wo_release' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      -- ROLE-1 Batch 3a:过账归 action.stocktake_post;开单人与录过数的每一个人都不算(按人认)
      LEFT JOIN holds h ON 'action.stocktake_post' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.stocktake_counts c
                                        WHERE c.stocktake_id = s.id
                                          AND public.self_leg(c.counted_by, NULL, h.user_id) <> 'none')
     WHERE s.status = 'open' AND s.deleted_at IS NULL
    UNION ALL
    -- ★ APR-7(grilling Q9):每一条申请链 —— 付款、工资、收货定价、贷项 / 作废、发货放行、手工凭证、仓库申请。
    --   它们在 approval_pending_documents 里带 fixed_level;决定人按 approval_deciders 问(与提交时的
    --   assert_other_decider 同一份判据),门取 approval_chain_gates 里那一行。APR-5b / APR-6 的自证只问了
    --   "这条链此刻有没有人",没有逐张问 —— 这一支补上。
    SELECT pd.subject_type, pd.code, pd.raiser_user_id, pd.subject_employee_id, d.user_id
      FROM public.approval_pending_documents() pd
      JOIN public.approval_chain_gates() g ON g.subject_type = pd.subject_type AND g.level = pd.fixed_level
     CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders(pd.subject_type, g.action_function, pd.fixed_level,
                 pd.raiser_user_id, pd.subject_employee_id, fs.l1, fs.l2) d ON true
     WHERE pd.fixed_level IS NOT NULL AND pd.subject_type NOT IN ('expense_claim', 'purchase_order')
    UNION ALL
    -- ★ APR-9:调薪申请按人路由(pay_decision_code),不在 approval_chain_gates 里 —— 问 salary_change_deciders,
    --   与 submit_salary_change_request 的"别人批得动吗"同一份判据。
    SELECT 'salary_change_request', q.label, q.created_by, q.employee_id, d.user_id
      FROM public.salary_change_requests q
      LEFT JOIN LATERAL public.salary_change_deciders(q.created_by, q.employee_id) d ON true
     WHERE q.status = 'submitted'
)
SELECT i.k, i.doc,
       (SELECT email::text FROM auth.users WHERE id = i.raiser),
       (SELECT legal_name FROM public.employees WHERE id = i.subj),
       count(DISTINCT COALESCE(public.account_person(i.u)::text, i.u::text))::int,
       string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = i.u), ' ')
  FROM items i
 GROUP BY i.k, i.doc, i.raiser, i.subj
 ORDER BY 1, 2
$f$;

CREATE TEMP TABLE at1a_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    v_po   uuid;
    v_j    jsonb;
    k      text;
    f      text;
BEGIN
    -- ① 授权一行没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM at1a_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM at1a_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1A_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1A_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 一行没多(本迁移不写业务数据)
    IF EXISTS ((SELECT b.k, b.id FROM at1a_pending_before b EXCEPT SELECT a.k, a.id FROM at1a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM at1a_pending_after a EXCEPT SELECT b.k, b.id FROM at1a_pending_before b)) THEN
        RAISE EXCEPTION 'AT1A_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(n, mx)::text FROM at1a_log_before) IS DISTINCT FROM (SELECT row(count(*), max(seq))::text FROM change_log) THEN
        RAISE EXCEPTION 'AT1A_PROOF|change_log moved: % → %', (SELECT row(n, mx)::text FROM at1a_log_before),
            (SELECT row(count(*), max(seq))::text FROM change_log);
    END IF;

    -- ④ 形状:两支读法是 DEFINER、authenticated 调得到;内层函数调不到(索引在第二个文件里,不在这里断言)
    FOREACH f IN ARRAY ARRAY['public.record_trail(text, text, integer)',
                             'public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer, text[], boolean, boolean, text[])',
                             'public.change_log_find_records(text)', 'public.change_log_filters()'] LOOP
        IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure) THEN
            RAISE EXCEPTION 'AT1A_PROOF|% must be SECURITY DEFINER', f;
        END IF;
        IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1A_PROOF|authenticated cannot execute %', f;
        END IF;
    END LOOP;
    FOREACH f IN ARRAY ARRAY['public.change_log_mask_row(text, jsonb, jsonb, jsonb)', 'public.trail_current_image(text, jsonb)',
                             'public.trail_ref_label(text, text, text)', 'public.trail_refs(text, jsonb, jsonb, jsonb)',
                             'public.trail_row_record(text, jsonb, jsonb, jsonb)', 'public.trail_row_visible(text, jsonb, jsonb)',
                             'public.trail_actor(text, uuid, uuid)'] LOOP
        IF has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1A_PROOF|authenticated can execute the inner function %', f;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
         WHERE p.proname = 'change_log_rows') <> 1 THEN
        RAISE EXCEPTION 'AT1A_PROOF|change_log_rows has more than one signature';
    END IF;

    -- ⑤ 真的读一次:以 tim@(cfo)的身份读 PO-2026-0010 —— 读得到、带着"记录开始之前"的那一段;不认识的主语按名拒
    SELECT id INTO v_po FROM purchase_orders WHERE code = 'PO-2026-0010';
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT jsonb_agg(to_jsonb(r)) INTO v_j FROM record_trail('purchase_order', v_po::text, 50) r;
    BEGIN
        PERFORM * FROM record_trail('purchase_orders', v_po::text);
        v_bad := 'no error';
    EXCEPTION WHEN OTHERS THEN
        v_bad := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    IF v_j IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'prelog')::boolean) THEN
        RAISE EXCEPTION 'AT1A_PROOF|tim@ should read PO-2026-0010''s trail with its pre-log history, got %', v_j;
    END IF;
    IF v_bad NOT LIKE 'TRAIL_SUBJECT_UNKNOWN|%' THEN
        RAISE EXCEPTION 'AT1A_PROOF|an unknown subject should raise TRAIL_SUBJECT_UNKNOWN, got %', v_bad;
    END IF;
    RAISE NOTICE 'AT1A PO-2026-0010 trail rows for tim@: % (pre-log rows: %)', jsonb_array_length(v_j),
        (SELECT count(*) FROM jsonb_array_elements(v_j) e WHERE (e ->> 'prelog')::boolean);

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.at1a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'AT1A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.at1a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'AT1A_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.at1a_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.at1a_pending_decider_check(boolean);

COMMIT;
