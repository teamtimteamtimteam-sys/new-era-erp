-- db/migrations/2026-09-28-history1-change-log.sql
-- HISTORY-1 —— 通用变更记录、保护与变更记录页(v1.4.32)。docs/change-log.md 是这一刀的说明书。
-- 由 db/scripts/build_history1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(HISTORY-0 勘察 + HISTORY-1 Step 0,Tim 2026-09-28 全部裁定)
--   ① change_log:一张只增不改的通用记录。238 张表各两条触发器(行级 + TRUNCATE),四张豁免带理由。
--      一行记:账号 + 【写入时冻住】的员工 · 无会话 + 数据库角色 · 编辑只记改了的列(前后)· 新增/删除整行 ·
--      seq 定先后 · clock_timestamp() 定时刻 · row_key 按主键列名。
--   ② 没有任何直接授权。读只走 change_log_rows()(新码 data.view_change_log,只授 admin 与 cfo),
--      按源屏幕逐列遮蔽(change_log_mask_rules,26 张表),任务四张表按 can_view_task 整行遮。
--   ③ 保护:change_log 拒 UPDATE / DELETE / TRUNCATE(唯一放行的是匿名化涂抹的那个形状);
--      task_history 与 work_order_history 补上只增不改守卫;17 张历史表全部补上 TRUNCATE 守卫;
--      purchase_order_history 的价格列按 data.view_purchase_prices 遮(新视图 purchase_order_history_masked)。
--   ④ set_role_permissions 只动有差别的码;anonymise_employee 清 greeting_name 并涂抹记录;
--      export_my_personal_data 加 my_record_changes;record_account_event 记账号的建 / 停用 / 启用 / 回滚删除;
--      user_directory 加 disabled 一列。
--
-- 【破窗】唯一会坏的是 /purchasing/orders/[id]:旧代码直读 purchase_order_history 的价格列,
--   收回之后 42501,直到新代码部署(Tim 的 Q11 接受)。其余全部是新增。
--
-- 【审批是开着的】文末自证在同一笔事务里断言:开关仍开;在途单据一张不少一张不多;每一张在途单据都还有
--   一个【不是它自己当事人】的决定人;除 permissions(+1)与 role_permissions(+2:admin、cfo)之外,
--   【每一张表的每一行】指纹不变;覆盖与遮蔽两道检查零缺口;本迁移自己的写入已经落进记录。
--   断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提 ────────────────────────────────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'H1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.change_log') IS NOT NULL THEN
        RAISE EXCEPTION 'H1_PRE|change_log already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code = 'data.view_change_log') THEN
        RAISE EXCEPTION 'H1_PRE|data.view_change_log already exists';
    END IF;
    IF (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'r') <> 241 THEN
        RAISE EXCEPTION 'H1_PRE|expected 241 public tables before this migration';
    END IF;
END;
$pre$;

CREATE TEMP TABLE h1_pending_before ON COMMIT DROP AS
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
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted'
UNION ALL SELECT 'overtime_batch', id FROM overtime_batches WHERE status = 'submitted';
CREATE TEMP TABLE h1_fp_before (table_name text PRIMARY KEY, digest text) ON COMMIT DROP;
CREATE TEMP TABLE h1_fp_after (table_name text PRIMARY KEY, digest text) ON COMMIT DROP;
DO $fp$
DECLARE t text; h text;
BEGIN
    FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname <> 'change_log' ORDER BY 1 LOOP
        EXECUTE format('SELECT md5(COALESCE(string_agg(x.r, E''\n'' ORDER BY x.r), '''')) FROM (SELECT row(t.*)::text AS r FROM public.%I t) x', t) INTO h;
        INSERT INTO h1_fp_before (table_name, digest) VALUES (t, h);
    END LOOP;
END;
$fp$;

CREATE TEMP TABLE h1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 记录表与它的守卫 ───────────────────────────────────────────────────

-- db/functions/change_log_redactable_columns.sql
-- HISTORY-1:匿名化时 change_log 里【允许被涂成 null】的列 —— 按源表。
-- 名单与 anonymise_employee 清掉的列【逐字同一份】(外加 greeting_name,Tim 的 Q9);
-- 两边任何一边加列,另一边要在同一个提交里跟上 —— fixture 234 的涂抹那一臂钉着这份对应。
CREATE OR REPLACE FUNCTION public.change_log_redactable_columns(p_table text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_table
        WHEN 'employees' THEN ARRAY[
            'legal_name', 'preferred_name', 'first_name', 'last_name', 'greeting_name',
            'identity_no', 'work_email', 'work_phone', 'work_pass_no', 'work_pass_type',
            'work_pass_issue_date', 'work_pass_expiry_date', 'residency_status',
            'monthly_salary', 'notes', 'separation_notes', 'position_id', 'user_id']
        WHEN 'employment_history' THEN ARRAY['old_monthly_salary', 'new_monthly_salary', 'notes']
        ELSE ARRAY[]::text[]
    END;
$function$;

-- db/functions/change_log_redaction_ok.sql
-- HISTORY-1:一次涂抹对【一份影像】(old 或 new)做的改动,是不是只有"把允许的列改成 null"。
-- 键集合必须一模一样(不许删键、不许加键);每一个值变了的键都必须在允许名单里、且新值是 JSON null。
CREATE OR REPLACE FUNCTION public.change_log_redaction_ok(p_table text, p_before jsonb, p_after jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
        WHEN p_before IS NULL OR p_after IS NULL THEN p_before IS NULL AND p_after IS NULL
        ELSE COALESCE((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p_before) k), ARRAY[]::text[])
           = COALESCE((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p_after) k), ARRAY[]::text[])
         AND NOT EXISTS (
             SELECT 1 FROM jsonb_each(p_after) a
              WHERE a.value IS DISTINCT FROM p_before -> a.key
                AND NOT (a.value = 'null'::jsonb AND a.key = ANY (change_log_redactable_columns(p_table))))
    END;
$function$;

-- db/functions/change_log_null_keys.sql
-- HISTORY-1:把一份影像里【点名的那些键】改成 JSON null,其余原样;键集合不变。
-- 涂抹(change_log_redact_employee)用它 —— 只做 change_log_redaction_ok 放行的那一件事。
CREATE OR REPLACE FUNCTION public.change_log_null_keys(p_img jsonb, p_keys text[])
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN p_img IS NULL THEN NULL
        ELSE COALESCE((SELECT jsonb_object_agg(e.key, CASE WHEN e.key = ANY (p_keys) THEN 'null'::jsonb ELSE e.value END)
                         FROM jsonb_each(p_img) e), '{}'::jsonb)
    END;
$function$;

-- db/functions/guard_change_log_append_only.sql
-- HISTORY-1:change_log 的只增不改守卫。BEFORE UPDATE/DELETE(行级)与 BEFORE TRUNCATE(语句级)共用。
--
-- 【唯一放行的形状】匿名化涂抹(Tim 的 Q11):redacted_at 从空变成有值,且
--   ① 除 old / new / redacted_at 之外的【每一列】逐字不变 —— 比的是整行的 jsonb 去掉这三列,
--     所以本表以后加的列自动落在"不许改"那一边(与 reject_employment_history_mutation 的抬头同一条);
--   ② old 与 new 各自只许把【允许涂抹的列】(change_log_redactable_columns)改成 null,
--     键集合不许增减(change_log_redaction_ok)。
-- 其余一切 UPDATE、每一次 DELETE、每一次 TRUNCATE 都抛 CHANGE_LOG_IMMUTABLE。
-- 【判据按形状,不按会话标记】一个会话标记谁都设得了;一个形状只有涂抹那一种写得出来。
CREATE OR REPLACE FUNCTION public.guard_change_log_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF OLD.redacted_at IS NULL AND NEW.redacted_at IS NOT NULL
           AND (to_jsonb(NEW) - 'old' - 'new' - 'redacted_at') = (to_jsonb(OLD) - 'old' - 'new' - 'redacted_at')
           AND change_log_redaction_ok(OLD.table_name, OLD.old, NEW.old)
           AND change_log_redaction_ok(OLD.table_name, OLD.new, NEW.new)
        THEN
            RETURN NEW;
        END IF;
    END IF;
    RAISE EXCEPTION 'CHANGE_LOG_IMMUTABLE|%', TG_OP;
END;
$function$;

-- db/tables/change_log.sql
-- HISTORY-1(2026-09-28):一份【通用、只增不改】的变更记录 —— 每一张业务表的每一次写入都落一行。
--
-- NOTE: introduced by db/migrations/2026-09-28-history1-change-log.sql. First-run script (plain CREATEs).
--
-- 【它补的是哪一块】HISTORY-0(docs/surveys/HISTORY-0.md)量到:241 张表里 35 张改了不留任何痕迹,
--   116 张只记"最后一个改的人"而不记改之前是什么,69 张可以被登录用户硬删而不留下被删的那一行,
--   15 支函数"整批删掉再整批插回"。原来那 17 张领域历史表【留着】(Tim 的 Q3)—— 它们记的是
--   【意义】(理由、级别、事件名),本表记的是【事实】(哪一行、哪几列、从什么变成什么、谁)。
--
-- 【一行记什么】(Tim 的 Q6–Q9)
--   · actor_account  = auth.uid()                     —— 哪一个登录账号
--   · actor_employee = account_person(auth.uid())     —— 哪一个人,【写入那一刻】冻住
--     (tim@ 与 admin@ 是同一个人的两个账号;链接日后改了,这一行说的仍是当时那个人)
--   · actor_kind     = 'user' | 'no_session'          —— 没有登录会话的写(迁移、fixture、服务角色)
--   · db_role        = 当时的数据库角色(authenticated / service_role / postgres)。
--     ★ 【不能是 current_user】—— 写入它的是 SECURITY DEFINER 触发器函数,那里面 current_user
--       永远是属主。读的是 `role` 这个设置(PostgREST 用 SET ROLE 切过去),没有就回落 session_user。
--   · 编辑:changed_columns + old/new【只含改了的那几列】;新增:new 是整行;删除:old 是整行。
--     改了等于没改的 UPDATE 不写行。
--   · seq 是先后的裁决者(AGING-1:now() 在同一笔事务里并列);occurred_at 取 clock_timestamp()。
--   · row_key:那一行的主键,按列名存成 jsonb。241 张表里 19 张是复合主键、43 张是非 uuid 的单列主键,
--     所以不能是一个 uuid 列。主键列名由迁移生成时写进触发器参数(TG_ARGV),不在每一行上查目录。
--
-- 【谁能读,谁能改】(Tim 的 Q10、Q11、Q13)
--   · 没有任何直接授权 —— anon / authenticated / service_role 对本表一个权限都没有。
--     读只走 change_log_rows(),它要 data.view_change_log,并按源屏幕的规矩遮蔽。
--   · UPDATE 只有一种形状放行:匿名化的那一次涂抹(change_log_redact_employee),
--     判据按【改动的形状】认,不按会话标记认 —— 与 reject_employment_history_mutation 同一个做法。
--     DELETE 与 TRUNCATE 一律拒。
--   · ★ 已知限制(docs/known-issues.md HISTORY1-OWNER-BYPASS):属主(postgres)可以关掉触发器、
--     或设 session_replication_role = replica。本表对每一个【应用角色】是只增不改的,对属主不是。
--     防属主篡改(哈希链 / 库外导出)是登记在案的后续一刀(Tim 的 Q14)。

CREATE TABLE public.change_log (
    seq             bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
    txid            bigint NOT NULL DEFAULT txid_current(),
    table_name      text NOT NULL,
    row_key         jsonb,
    op              text NOT NULL CHECK (op IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE',
                        'ACCOUNT_CREATE', 'ACCOUNT_DELETE', 'ACCOUNT_DISABLE', 'ACCOUNT_DISABLE_FAILED',
                        'ACCOUNT_ENABLE', 'ACCOUNT_ENABLE_FAILED')),
    actor_account   uuid,
    actor_employee  uuid,
    actor_kind      text NOT NULL CHECK (actor_kind IN ('user', 'no_session')),
    db_role         text NOT NULL,
    changed_columns text[],
    old             jsonb,
    new             jsonb,
    redacted_at     timestamptz
);

COMMENT ON TABLE public.change_log IS
    'HISTORY-1:通用只增不改变更记录。每张业务表(除 change_log_exclusions() 列出的四张)一条 AFTER ROW 触发器 + 一条 AFTER TRUNCATE 语句触发器写入。没有任何直接授权;读走 change_log_rows()(data.view_change_log,按源屏幕遮蔽)。唯一放行的 UPDATE 是匿名化涂抹(change_log_redact_employee)。见 docs/change-log.md。';
COMMENT ON COLUMN public.change_log.row_key IS
    '那一行的主键,按列名存成 jsonb(复合主键就是多个键)。TRUNCATE 行为 NULL;账号事件是 {"id": <auth 用户 id>}。';
COMMENT ON COLUMN public.change_log.db_role IS
    '写入时的数据库角色:current_setting(''role''),为 none 时取 session_user。不是 current_user —— 触发器函数是 SECURITY DEFINER,那里面 current_user 恒为属主。';

CREATE INDEX idx_change_log_occurred ON public.change_log (occurred_at DESC);
CREATE INDEX idx_change_log_table_key ON public.change_log (table_name, row_key);
CREATE INDEX idx_change_log_actor ON public.change_log (actor_account);
CREATE INDEX idx_change_log_actor_employee ON public.change_log (actor_employee);

-- 【没有任何直接授权】平台的默认权限会把新表授给 anon / authenticated / service_role,
-- 这里全部收回。RLS 打开且没有一条策略 —— 双保险:哪天有人误授了一句 SELECT,仍然零行。
REVOKE ALL ON public.change_log FROM PUBLIC, anon, authenticated, service_role;
ALTER TABLE public.change_log ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER trg_change_log_append_only
    BEFORE UPDATE OR DELETE ON public.change_log
    FOR EACH ROW EXECUTE FUNCTION public.guard_change_log_append_only();

CREATE TRIGGER trg_change_log_no_truncate
    BEFORE TRUNCATE ON public.change_log
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_change_log_append_only();

-- ── 2 · 写入函数与豁免名单(绑定在 §7,见那里的理由)──────────────────────────

-- db/functions/change_log_capture.sql
-- HISTORY-1:通用变更记录的【唯一】写入函数。238 张表各一条 AFTER ROW 触发器(zzz_change_log)
-- 与一条 AFTER TRUNCATE 语句触发器(zzz_change_log_truncate)调它;绑定清单在
-- db/views/zzz_change_log_triggers.sql(生成的,见 db/scripts/gen_change_log_bindings.py)。
--
-- 【函数体里没有一个列名】与 trg_fixed_assets_history 同一个做法(fixture 120 F5(d) 钉着):
--   一张表以后加了列,这里不用改,加的那一列自动进记录。
-- 【主键从触发器参数来】TG_ARGV 是主键列名 —— 生成绑定时从目录读一次,不在每一行上查。
-- 【actor】账号 = auth.uid();人 = account_person(账号),【此刻】冻住;没有会话 = 'no_session'。
-- 【db_role】★ 不能写 current_user:本函数是 SECURITY DEFINER,里面的 current_user 恒为属主。
--   `role` 设置记着 PostgREST 切过去的那个角色(authenticated / service_role),实测它穿得过
--   SECURITY DEFINER;没有切过(迁移、fixture 以超级用户跑)时它是 'none',回落 session_user。
-- 【SECURITY DEFINER 的理由】change_log 对任何应用角色都没有 INSERT 权限 —— 写只能以属主身份。
CREATE OR REPLACE FUNCTION public.change_log_capture()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_uid  uuid := auth.uid();
    v_role text := COALESCE(NULLIF(current_setting('role', true), 'none'), session_user::text);
    v_img  jsonb;
    v_old  jsonb;
    v_new  jsonb;
    v_cols text[];
    v_key  jsonb := '{}'::jsonb;
    i      integer;
BEGIN
    IF TG_LEVEL = 'STATEMENT' THEN
        -- TRUNCATE:一句话清空整张表,行级触发器不响。记下【发生过】;被清掉的行本身不在这里
        -- (docs/change-log.md 照直写着这一条限制)。
        INSERT INTO change_log (table_name, row_key, op, actor_account, actor_employee, actor_kind, db_role)
        VALUES (TG_TABLE_NAME, NULL, 'TRUNCATE', v_uid, account_person(v_uid),
                CASE WHEN v_uid IS NULL THEN 'no_session' ELSE 'user' END, v_role);
        RETURN NULL;
    END IF;

    IF TG_OP = 'INSERT' THEN
        v_img := to_jsonb(NEW);
        v_new := v_img;
    ELSIF TG_OP = 'DELETE' THEN
        v_img := to_jsonb(OLD);
        v_old := v_img;
    ELSE
        v_img := to_jsonb(NEW);
        v_old := to_jsonb(OLD);
        SELECT array_agg(n.key ORDER BY n.key) INTO v_cols
          FROM jsonb_each(v_img) n
         WHERE v_old -> n.key IS DISTINCT FROM n.value;
        IF v_cols IS NULL THEN
            RETURN NULL;          -- 改了等于没改:不写行
        END IF;
        SELECT jsonb_object_agg(k, v_old -> k), jsonb_object_agg(k, v_img -> k)
          INTO v_old, v_new
          FROM unnest(v_cols) k;
    END IF;

    FOR i IN 0 .. TG_NARGS - 1 LOOP
        v_key := v_key || jsonb_build_object(TG_ARGV[i], v_img -> TG_ARGV[i]);
    END LOOP;

    INSERT INTO change_log (table_name, row_key, op, actor_account, actor_employee, actor_kind,
                            db_role, changed_columns, old, new)
    VALUES (TG_TABLE_NAME, v_key, TG_OP, v_uid, account_person(v_uid),
            CASE WHEN v_uid IS NULL THEN 'no_session' ELSE 'user' END,
            v_role, v_cols, v_old, v_new);
    RETURN NULL;
END;
$function$;

-- db/functions/change_log_exclusions.sql
-- HISTORY-1(Tim 的 Q5):不挂变更记录触发器的表 —— 【唯一】的一份名单,每一条带理由。
--
-- 三处读它,所以它只能有一份:
--   · change_log_coverage_gaps() —— gate 的 changelog 那一行(线上 + 重建)与 fixture 234;
--   · scripts/check-change-log-coverage.mjs —— 构建里的静态检查,从本文件的 VALUES 里读;
--   · db/scripts/gen_change_log_bindings.py —— 生成绑定清单时跳过这几张。
-- ★ 规矩(docs/change-log.md):新建的每一张 public 表,要么在 db/views/zzz_change_log_triggers.sql
--   里有两条绑定,要么在这里有一行带理由的豁免。两者都没有,构建与 gate 都会红。
CREATE OR REPLACE FUNCTION public.change_log_exclusions()
 RETURNS TABLE(table_name text, reason text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    VALUES
        ('change_log'::text, 'The change log itself; a trigger on it would record its own writes.'::text),
        ('festival_doodles', 'Home-screen holiday artwork; screen decoration with no business meaning.'),
        ('home_greetings', 'Home-screen greeting text; screen decoration with no business meaning.'),
        ('notification_reads', 'Per-viewer "seen" marks on notifications; screen state with no business meaning.');
$function$;

-- ── 3 · 17 张历史表:TRUNCATE 守卫;task_history / work_order_history 的只增不改守卫 ──

-- db/functions/guard_history_no_truncate.sql
-- HISTORY-1(Tim 的 Q19):17 张领域历史表的 TRUNCATE 守卫。
-- 它们此前各有一条 BEFORE UPDATE/DELETE 的只增不改守卫(task_history 与 work_order_history 连那条都没有,
-- 见 Q18),但【没有一张】挡得住 TRUNCATE —— 行级触发器对 TRUNCATE 不响,而平台默认把 TRUNCATE
-- 授给了 authenticated。一个语句级 BEFORE TRUNCATE 触发器补上这一格。
CREATE OR REPLACE FUNCTION public.guard_history_no_truncate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'HISTORY_TRUNCATE_FORBIDDEN|%', TG_TABLE_NAME;
END;
$function$;

-- db/functions/guard_task_history_append_only.sql
-- HISTORY-1(Tim 的 Q18):task_history 此前是 17 张历史表里两张【没有】只增不改守卫的之一
-- (HISTORY-0 §A.3:pg_stat 记着 n_tup_upd = 2、n_tup_del = 6)。现在与另外 15 张同一个形状。
CREATE OR REPLACE FUNCTION public.guard_task_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'TASK_HISTORY_IMMUTABLE|%', TG_OP;
END;
$function$;

-- db/functions/guard_work_order_history_append_only.sql
-- HISTORY-1(Tim 的 Q18):work_order_history 此前没有只增不改守卫。现在与另外 15 张同一个形状。
CREATE OR REPLACE FUNCTION public.guard_work_order_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'WORK_ORDER_HISTORY_IMMUTABLE|%', TG_OP;
END;
$function$;

-- ── 4 · purchase_order_history 的价格列遮蔽(Q20)───────────────────────────
REVOKE SELECT ON public.purchase_order_history FROM authenticated, anon;
GRANT SELECT (id, purchase_order_id, purchase_order_line_id, line_no, change_type,
              old_order_date, new_order_date, old_expected_delivery_date, new_expected_delivery_date,
              old_incoterm, new_incoterm, old_terms_text, new_terms_text, old_notes, new_notes,
              old_quantity, new_quantity, old_unit, new_unit, amend_reason, changed_at, changed_by,
              old_delivery_location, new_delivery_location, old_price_status, new_price_status,
              payment_term_seq)
    ON public.purchase_order_history TO authenticated;

-- db/views/purchase_order_history_masked.sql
-- HISTORY-1(Tim 的 Q20,2026-09-28):purchase_order_history 的遮蔽伴生视图。
--   每一列都在;采购价格那几列按 data.view_purchase_prices 置空 —— 与 purchase_order_lines_masked /
--   purchase_orders_masked / purchase_order_payment_terms_masked 同一个码、同一个形状。
--   整期付款快照(old/new_payment_term)整份遮:里面有 fixed_amount_ccy。
-- 【属主权限,不是 SECURITY INVOKER】理由与其余 _masked 视图逐字相同(见 purchase_order_payment_terms_masked
--   的抬头):基表的敏感列已收回,invoker 视图会 42501。行谓词原样写回视图体:
--     WHERE has_permission('module.purchasing.view')  —— 与基表那条 SELECT 策略是同一个布尔量。
-- /purchasing/orders/[id] 的编辑史读这张视图。
--
-- NOTE: introduced by db/migrations/2026-09-28-history1-change-log.sql.

CREATE VIEW public.purchase_order_history_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_id,
    purchase_order_line_id,
    line_no,
    change_type,
    old_order_date,
    new_order_date,
    old_expected_delivery_date,
    new_expected_delivery_date,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN old_fx_rate
            ELSE NULL::numeric
        END AS old_fx_rate,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN new_fx_rate
            ELSE NULL::numeric
        END AS new_fx_rate,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN old_estimated_total_ccy
            ELSE NULL::numeric
        END AS old_estimated_total_ccy,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN new_estimated_total_ccy
            ELSE NULL::numeric
        END AS new_estimated_total_ccy,
    old_incoterm,
    new_incoterm,
    old_terms_text,
    new_terms_text,
    old_notes,
    new_notes,
    old_quantity,
    new_quantity,
    old_unit,
    new_unit,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN old_estimated_unit_price
            ELSE NULL::numeric
        END AS old_estimated_unit_price,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN new_estimated_unit_price
            ELSE NULL::numeric
        END AS new_estimated_unit_price,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN old_estimated_amount_ccy
            ELSE NULL::numeric
        END AS old_estimated_amount_ccy,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN new_estimated_amount_ccy
            ELSE NULL::numeric
        END AS new_estimated_amount_ccy,
    amend_reason,
    changed_at,
    changed_by,
    old_delivery_location,
    new_delivery_location,
    old_price_status,
    new_price_status,
    payment_term_seq,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN old_payment_term
            ELSE NULL::jsonb
        END AS old_payment_term,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN new_payment_term
            ELSE NULL::jsonb
        END AS new_payment_term
   FROM purchase_order_history
  WHERE has_permission('module.purchasing.view'::text);

GRANT SELECT ON public.purchase_order_history_masked TO authenticated;

-- ── 5 · 读法、遮蔽、覆盖检查、账号事件与三支改过的函数 ───────────────────────

-- db/functions/change_log_mask_rules.sql
-- HISTORY-1(Tim 的 Q10 · Q7 · Q20):change_log_rows() 的遮蔽规则 —— 【一份】名单,一列一行。
--
-- 【来源】逐条抄自每一张 <表>_masked 视图里那句 CASE WHEN … THEN <列> ELSE NULL END(以 postgres
--   读 pg_get_viewdef,2026-09-28),外加本刀新建的 purchase_order_history_masked。
--   "源屏幕怎么遮,记录就怎么遮" —— 屏幕读的就是这些视图。
-- 【规则的写法】
--   code:<码>                    持这个码才看得见
--   code_or_self:<码>:<列>       持码,或那一行的 <列> 就是读者自己的员工 id(视图里的 OR id = current_user_employee())
--   pft:direction                pricing_formula_terms_visible(这一行的 direction)
--   pft:formula_id               pricing_formula_terms_visible(这一行所属公式的 direction)
--   pft3                         pricing_formula_history_masked 那三段:公式当前方向 ∧ old_direction ∧ new_direction
-- 【它会不会和视图漂开】会 —— 所以有一道闸:change_log_mask_gaps() 拿目录里【真的被遮的列】
--   (_masked 视图里 CASE … END AS <基表的列>)与本名单逐列对,缺一条或多一条都报;
--   gate 的 changemask 那一行在线上与重建两侧各问一次,fixture 234 里注入"删掉一条"必须变红。
CREATE OR REPLACE FUNCTION public.change_log_mask_rules()
 RETURNS TABLE(table_name text, column_name text, rule text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    VALUES
        ('company_profile'::text, 'bank_name'::text, 'code:data.view_banking'::text),
        ('company_profile', 'bank_account_name', 'code:data.view_banking'),
        ('company_profile', 'bank_account_no', 'code:data.view_banking'),
        ('company_profile', 'bank_swift', 'code:data.view_banking'),
        ('company_profile', 'bank_address', 'code:data.view_banking'),
        ('employees', 'work_email', 'code_or_self:data.view_identity:id'),
        ('employees', 'work_phone', 'code_or_self:data.view_identity:id'),
        ('employees', 'identity_no', 'code_or_self:data.view_identity:id'),
        ('employees', 'work_pass_no', 'code_or_self:data.view_identity:id'),
        ('employees', 'monthly_salary', 'code_or_self:data.view_pay:id'),
        ('employment_history', 'old_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('employment_history', 'new_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('inbound_batches', 'unit_price', 'code:data.view_purchase_prices'),
        ('invoice_lines', 'unit_price', 'code:data.view_prices'),
        ('invoice_lines', 'amount_base', 'code:data.view_prices'),
        ('invoice_lines', 'amount_ccy', 'code:data.view_prices'),
        ('invoice_lines', 'tax_base', 'code:data.view_prices'),
        ('invoices', 'subtotal_base', 'code:data.view_prices'),
        ('invoices', 'tax_base', 'code:data.view_prices'),
        ('invoices', 'total_base', 'code:data.view_prices'),
        ('invoices', 'fx_rate', 'code:data.view_prices'),
        ('payment_term_template_lines', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('payroll_lines', 'gross_pay', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'employer_cpf', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'employee_cpf', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'other_deductions', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'net_pay', 'code_or_self:data.view_pay:employee_id'),
        ('performance_reviews', 'new_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('prepayment_applications', 'amount_base', 'code:data.view_purchase_prices'),
        ('prepayment_applications', 'amount_ccy', 'code:data.view_purchase_prices'),
        ('price_history', 'old_unit_price', 'code:data.view_purchase_prices'),
        ('price_history', 'new_unit_price', 'code:data.view_purchase_prices'),
        ('price_history', 'original_price', 'code:data.view_purchase_prices'),
        ('price_history', 'fx_rate', 'code:data.view_purchase_prices'),
        ('pricing_formula_history', 'old_payable_pct', 'pft3'),
        ('pricing_formula_history', 'new_payable_pct', 'pft3'),
        ('pricing_formula_history', 'old_treatment_charge_usd_per_tonne', 'pft3'),
        ('pricing_formula_history', 'new_treatment_charge_usd_per_tonne', 'pft3'),
        ('pricing_formula_history', 'old_flat_discount_pct', 'pft3'),
        ('pricing_formula_history', 'new_flat_discount_pct', 'pft3'),
        ('pricing_formula_metals', 'payable_pct', 'pft:formula_id'),
        ('pricing_formulas', 'treatment_charge_usd_per_tonne', 'pft:direction'),
        ('pricing_formulas', 'flat_discount_pct', 'pft:direction'),
        ('pricing_term_commitment_metals', 'payable_pct', 'code:data.view_purchase_prices'),
        ('pricing_term_commitments', 'treatment_charge_usd_per_tonne', 'code:data.view_purchase_prices'),
        ('pricing_term_commitments', 'flat_discount_pct', 'code:data.view_purchase_prices'),
        ('processing_cost_entries', 'amount_base', 'code:data.view_prices'),
        ('processing_cost_entry_history', 'old_amount_base', 'code:data.view_prices'),
        ('processing_cost_entry_history', 'new_amount_base', 'code:data.view_prices'),
        ('processing_outputs', 'allocated_cost_base', 'code:data.view_prices'),
        ('processing_outputs', 'unit_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'material_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'process_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'total_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'capitalized_cost_base', 'code:data.view_prices'),
        ('purchase_order_history', 'old_fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_payment_term', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_payment_term', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'released_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'withheld_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'price_provenance', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'tax_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_payment_terms', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'tax_total_ccy', 'code:data.view_purchase_prices'),
        ('sales_records', 'unit_price', 'code:data.view_prices'),
        ('sales_records', 'fx_rate', 'code:data.view_prices'),
        ('sales_records', 'amount_base', 'code:data.view_prices'),
        ('sales_records', 'price_provenance', 'code:data.view_prices');
$function$;

-- db/functions/change_log_field.sql
-- HISTORY-1:为遮蔽与任务隐私的判据取【这一行的某个字段】。
--   一次编辑只记了改了的那几列,判据要的字段(employee_id / direction / task_id)常常不在影像里。
--   先后:这条记录自己的 new / old / 主键 → 那一行今天的值 → 同一行更早的记录里最近一次出现的值
--   (那一行已经被删掉时,只剩记录答得出)。三处都没有 → NULL,调用方按【看不见】处理。
-- 【不是 SECURITY DEFINER】它只被 change_log_rows 的判据调用,那时以属主身份跑;
--   EXECUTE 已从 authenticated 收回 —— 它按表名动态读任意一张表。
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
        EXECUTE format('SELECT to_jsonb(t) ->> %L FROM public.%I t WHERE to_jsonb(t) @> $1 LIMIT 1', p_field, p_table)
           INTO v USING p_key;
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

-- db/functions/change_log_rule_visible.sql
-- HISTORY-1:一条遮蔽规则(change_log_mask_rules)对【当前读者】、就【这一行记录】成不成立。
-- 与 _masked 视图里那句 CASE WHEN 逐条同一个判据;认不出的规则按【看不见】答(关着失败)。
CREATE OR REPLACE FUNCTION public.change_log_rule_visible(p_rule text, p_table text, p_key jsonb, p_old jsonb, p_new jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_part text[] := string_to_array(p_rule, ':');
    v_fid  text;
BEGIN
    IF v_part[1] = 'code' THEN
        RETURN has_permission(v_part[2]);
    ELSIF v_part[1] = 'code_or_self' THEN
        RETURN has_permission(v_part[2])
            OR COALESCE(change_log_field(p_table, p_key, p_old, p_new, v_part[3]) = current_user_employee()::text, false);
    ELSIF p_rule = 'pft:direction' THEN
        RETURN pricing_formula_terms_visible(change_log_field(p_table, p_key, p_old, p_new, 'direction'));
    ELSIF p_rule IN ('pft:formula_id', 'pft3') THEN
        v_fid := change_log_field(p_table, p_key, p_old, p_new, 'formula_id');
        IF NOT pricing_formula_terms_visible(
               change_log_field('pricing_formulas', jsonb_build_object('id', v_fid), NULL, NULL, 'direction')) THEN
            RETURN false;
        END IF;
        IF p_rule = 'pft:formula_id' THEN
            RETURN true;
        END IF;
        RETURN pricing_formula_terms_visible(COALESCE(change_log_field(p_table, p_key, p_old, p_new, 'old_direction'), 'both'))
           AND pricing_formula_terms_visible(COALESCE(change_log_field(p_table, p_key, p_old, p_new, 'new_direction'), 'both'));
    END IF;
    RETURN false;
END;
$function$;

-- db/functions/change_log_task_visible.sql
-- HISTORY-1(Tim 的 Q6):任务四张表(tasks · task_nodes · task_participants · task_history)的记录,
-- 按 can_view_task 判【整行】看不看得见。个人任务是私的 —— admin 与 cfo 都不持 module.tasks.view_all,
-- 只遮列会把任务屏幕刻意不给的标题与描述整段交给他们。
-- 任务还在 → 直接问 can_view_task;任务已经不在了 → 用它最后一份记录里的 task_type / owner_id,
-- 按 can_view_task 同一个判据答;连任务 id 都找不到 → 只有 view_all 看得见。
CREATE OR REPLACE FUNCTION public.change_log_task_visible(p_table text, p_key jsonb, p_old jsonb, p_new jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_task text := CASE WHEN p_table = 'tasks' THEN p_key ->> 'id'
                        ELSE change_log_field(p_table, p_key, p_old, p_new, 'task_id') END;
    v_k    jsonb;
BEGIN
    IF v_task IS NULL THEN
        RETURN has_permission('module.tasks.view_all');
    END IF;
    IF EXISTS (SELECT 1 FROM tasks t WHERE t.id = v_task::uuid) THEN
        RETURN can_view_task(v_task::uuid);
    END IF;
    v_k := jsonb_build_object('id', v_task);
    RETURN has_permission('module.tasks.view')
       AND (   has_permission('module.tasks.view_all')
            OR change_log_field('tasks', v_k, NULL, NULL, 'task_type') = 'team'
            OR COALESCE(change_log_field('tasks', v_k, NULL, NULL, 'owner_id') = current_user_employee()::text, false));
END;
$function$;

-- db/functions/change_log_restrict.sql
-- HISTORY-1:把一份影像里【读者看不见的值】换成受限标记 {"$restricted": true}。
--   p_keys 为 NULL = 整份影像(任务隐私那一支);否则只换点名的那几列。
-- ★ 值本来就是 JSON null 的【不换】—— 「受限」与「本来就空」是两件事(lib/permissions.ts 抬头那一条),
--   屏幕上前者画「受限」,后者留白。
CREATE OR REPLACE FUNCTION public.change_log_restrict(p_img jsonb, p_keys text[])
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN p_img IS NULL THEN NULL
        ELSE COALESCE((SELECT jsonb_object_agg(e.key,
                    CASE WHEN (p_keys IS NULL OR e.key = ANY (p_keys)) AND e.value <> 'null'::jsonb
                         THEN '{"$restricted": true}'::jsonb ELSE e.value END)
                 FROM jsonb_each(p_img) e), '{}'::jsonb)
    END;
$function$;

-- db/functions/change_log_rows.sql
-- HISTORY-1(Tim 的 Q10 · Q26 · Q6):变更记录的【唯一】读法。/settings/change-history 读它。
--
-- 【门】data.view_change_log(只授 admin 与 cfo,不捆进任何别的角色)。没有它 → PERMISSION_DENIED。
-- 【遮蔽】每一行按 change_log_mask_rules() 逐列问 change_log_rule_visible():读者在源屏幕上
--   看不见的值,这里换成 {"$restricted": true};本来就是 null 的留 null(见 change_log_restrict)。
-- 【任务隐私】任务四张表的记录先问 change_log_task_visible();不过 → 整份 old / new 换成受限标记,
--   只留时间、谁、表、主键、动作与改了哪几列的列名(row_restricted = true)。
-- 【筛选】日期(按库时区 Asia/Singapore,to 含当天)· 表 · 记录(主键里任一值等于它)·
--   人(账号 id 或员工 id 任一相等)· 只看无会话的写。
-- 【分页】按 seq 倒序,键集分页(p_before = 上一页最后一行的 seq),每页 1..200,默认 50。
-- 【SECURITY DEFINER 的理由】change_log 对应用角色没有任何授权;读 auth.users 取邮箱。
CREATE OR REPLACE FUNCTION public.change_log_rows(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_table text DEFAULT NULL::text, p_record text DEFAULT NULL::text, p_actor uuid DEFAULT NULL::uuid, p_no_session boolean DEFAULT false, p_before bigint DEFAULT NULL::bigint, p_limit integer DEFAULT 50)
 RETURNS TABLE(seq bigint, occurred_at timestamp with time zone, table_name text, row_key jsonb, op text, actor_account uuid, actor_email text, actor_employee uuid, actor_employee_code text, actor_employee_name text, actor_kind text, db_role text, changed_columns text[], old jsonb, new jsonb, redacted_at timestamp with time zone, row_restricted boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    r        record;
    m        record;
    v_hidden text[];
    v_limit  integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
    PERFORM require_permission('data.view_change_log');

    FOR r IN
        SELECT c.seq AS c_seq, c.occurred_at AS c_at, c.table_name AS c_table, c.row_key AS c_key,
               c.op AS c_op, c.actor_account AS c_account, u.email::text AS c_email,
               c.actor_employee AS c_employee, e.code AS c_emp_code,
               COALESCE(e.preferred_name, e.legal_name) AS c_emp_name,
               c.actor_kind AS c_kind, c.db_role AS c_role, c.changed_columns AS c_cols,
               c.old AS c_old, c.new AS c_new, c.redacted_at AS c_redacted
          FROM change_log c
          LEFT JOIN auth.users u ON u.id = c.actor_account
          LEFT JOIN employees e ON e.id = c.actor_employee
         WHERE (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
           AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
           AND (p_table IS NULL OR c.table_name = p_table)
           AND (p_record IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = p_record))
           AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
           AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
           AND (p_before IS NULL OR c.seq < p_before)
         ORDER BY c.seq DESC
         LIMIT v_limit
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
        old := r.c_old;
        new := r.c_new;
        row_restricted := false;

        IF r.c_table IN ('tasks', 'task_nodes', 'task_participants', 'task_history')
           AND NOT change_log_task_visible(r.c_table, r.c_key, r.c_old, r.c_new) THEN
            old := change_log_restrict(r.c_old, NULL);
            new := change_log_restrict(r.c_new, NULL);
            row_restricted := true;
        ELSE
            v_hidden := ARRAY[]::text[];
            FOR m IN SELECT mr.column_name AS m_col, mr.rule AS m_rule
                       FROM change_log_mask_rules() mr WHERE mr.table_name = r.c_table LOOP
                IF (COALESCE(r.c_old -> m.m_col, 'null'::jsonb) <> 'null'::jsonb
                    OR COALESCE(r.c_new -> m.m_col, 'null'::jsonb) <> 'null'::jsonb)
                   AND NOT change_log_rule_visible(m.m_rule, r.c_table, r.c_key, r.c_old, r.c_new) THEN
                    v_hidden := v_hidden || m.m_col;
                END IF;
            END LOOP;
            IF cardinality(v_hidden) > 0 THEN
                old := change_log_restrict(r.c_old, v_hidden);
                new := change_log_restrict(r.c_new, v_hidden);
            END IF;
        END IF;
        RETURN NEXT;
    END LOOP;
END;
$function$;

-- db/functions/change_log_filters.sql
-- HISTORY-1:/settings/change-history 两个下拉的选项 —— 表(挂着记录触发器的表 + 'auth.users' 账号事件)
-- 与人(记录里出现过的每一个账号,带邮箱与它最近一次记下的员工)。门与 change_log_rows 相同。
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
                     LEFT JOIN employees e ON e.id = a.actor_employee));
END;
$function$;

-- db/functions/change_log_mask_gaps.sql
-- HISTORY-1(Tim 的 Q7):遮蔽规则名单与目录对不对得上。
--   目录这一侧 = 每张 <表>_masked 视图里 `CASE … END AS <列>`、而 <列> 是那张基表【真的列】的那些
--   (派生列如 purchase_orders.gross_total_ccy、employees 的年假余额不算 —— 它们不在基表里,记录里也没有)。
--   名单这一侧 = change_log_mask_rules()。
--   缺一条(missing_rule)= 记录会把屏幕遮着的值交出去;多一条(stale_rule)= 名单在描述一件已经不存在的事。
-- 【零必须是测量】同时报它看了几张表、几列 —— gate 在看见的表少于 20 张时判失败,
--   一个什么都没看见的检查不许报"干净"。
-- 【不是 SECURITY DEFINER】只读目录与一份常量名单。
CREATE OR REPLACE FUNCTION public.change_log_mask_gaps()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH views AS (
        SELECT left(v.relname::text, -7) AS base, pg_get_viewdef(v.oid) AS def
          FROM pg_class v
          JOIN pg_namespace n ON n.oid = v.relnamespace
         WHERE n.nspname = 'public' AND v.relkind = 'v' AND v.relname::text LIKE '%\_masked'
    ), hidden AS (
        SELECT DISTINCT w.base AS table_name, m[1] AS column_name
          FROM views w, regexp_matches(w.def, 'END AS (\w+)', 'g') m
         WHERE EXISTS (SELECT 1 FROM pg_attribute a
                         JOIN pg_class t ON t.oid = a.attrelid
                         JOIN pg_namespace tn ON tn.oid = t.relnamespace
                        WHERE tn.nspname = 'public' AND t.relkind = 'r' AND t.relname::text = w.base
                          AND a.attname::text = m[1] AND a.attnum > 0 AND NOT a.attisdropped)
    ), rules AS (
        SELECT r.table_name, r.column_name FROM change_log_mask_rules() r
    )
    SELECT jsonb_build_object(
        'examined_tables', (SELECT count(DISTINCT h.table_name) FROM hidden h),
        'examined_columns', (SELECT count(*) FROM hidden h),
        'gaps', COALESCE((SELECT jsonb_agg(g.x ORDER BY g.x) FROM (
                    SELECT format('missing_rule:%s.%s', h.table_name, h.column_name) AS x FROM hidden h
                     WHERE NOT EXISTS (SELECT 1 FROM rules r WHERE r.table_name = h.table_name AND r.column_name = h.column_name)
                    UNION ALL
                    SELECT format('stale_rule:%s.%s', r.table_name, r.column_name) FROM rules r
                     WHERE NOT EXISTS (SELECT 1 FROM hidden h WHERE h.table_name = r.table_name AND h.column_name = r.column_name)
                ) g), '[]'::jsonb));
$function$;

-- db/functions/change_log_coverage_gaps.sql
-- HISTORY-1(Tim 的 Q4 · Q12):每一张 public 表是不是【要么被记录、要么在豁免名单上带着理由】。
--   被记录 = 两条【启用着的】触发器都在,都指向 change_log_capture():
--     zzz_change_log          AFTER INSERT OR UPDATE OR DELETE FOR EACH ROW  (tgtype 29)
--     zzz_change_log_truncate AFTER TRUNCATE FOR EACH STATEMENT              (tgtype 32)
--   缺口三种:unbound(没绑也没豁免)· excluded_but_bound(豁免了却绑着)·
--   excluded_unknown(豁免名单点了一张不存在的表 —— 名单在描述一件已经不存在的事)。
-- 【零必须是测量】报它看了几张表;gate 少于 200 张判失败。
-- 【不是 SECURITY DEFINER】只读目录。
CREATE OR REPLACE FUNCTION public.change_log_coverage_gaps()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH t AS (
        SELECT c.oid, c.relname::text AS table_name
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
    ), b AS (
        SELECT t.table_name,
               EXISTS (SELECT 1 FROM pg_trigger tg
                        WHERE tg.tgrelid = t.oid AND tg.tgname = 'zzz_change_log' AND NOT tg.tgisinternal
                          AND tg.tgenabled <> 'D' AND tg.tgtype = 29
                          AND tg.tgfoid = 'public.change_log_capture()'::regprocedure) AS has_row,
               EXISTS (SELECT 1 FROM pg_trigger tg
                        WHERE tg.tgrelid = t.oid AND tg.tgname = 'zzz_change_log_truncate' AND NOT tg.tgisinternal
                          AND tg.tgenabled <> 'D' AND tg.tgtype = 32
                          AND tg.tgfoid = 'public.change_log_capture()'::regprocedure) AS has_trunc,
               EXISTS (SELECT 1 FROM change_log_exclusions() x WHERE x.table_name = t.table_name) AS excluded
          FROM t
    )
    SELECT jsonb_build_object(
        'examined', (SELECT count(*) FROM b),
        'bound', (SELECT count(*) FROM b WHERE b.has_row AND b.has_trunc),
        'excluded', (SELECT count(*) FROM b WHERE b.excluded),
        'gaps', COALESCE((SELECT jsonb_agg(g.x ORDER BY g.x) FROM (
                    SELECT format('unbound:%s', b.table_name) AS x FROM b
                     WHERE NOT b.excluded AND NOT (b.has_row AND b.has_trunc)
                    UNION ALL
                    SELECT format('excluded_but_bound:%s', b.table_name) FROM b
                     WHERE b.excluded AND (b.has_row OR b.has_trunc)
                    UNION ALL
                    SELECT format('excluded_unknown:%s', x.table_name) FROM change_log_exclusions() x
                     WHERE NOT EXISTS (SELECT 1 FROM t WHERE t.table_name = x.table_name)
                ) g), '[]'::jsonb));
$function$;

-- db/functions/change_log_redact_employee.sql
-- HISTORY-1(Tim 的 Q11 · Q9):匿名化时涂抹 change_log 里关于这个人的个人字段 ——
-- change_log 【唯一】能被改的那条路。
--
-- 【谁调它】只有 anonymise_employee,在它自己那两句 UPDATE【之后】、同一笔事务里。
--   ★ 顺序是承重的:anonymise_employee 那句 UPDATE employees 本身就会被 change_log_capture
--     记一行,而那一行的 old 里装着【匿名化之前的每一个个人字段】。涂抹必须在它之后跑,
--     才涂得到它(fixture 234 的涂抹那一臂专门钉这一格)。
-- 【涂什么】employees 上这个人那一行的全部记录 + employment_history 上属于他的那些行的全部记录,
--   只涂 change_log_redactable_columns() 名单上的列(改成 JSON null),盖 redacted_at。
--   别的表只按 employee_id 引用他 —— 与 anonymise_employee 的范围逐字相同,不多不少。
-- 【证明别的都没动】不靠本函数自证:change_log 上的守卫(guard_change_log_append_only)
--   逐行核对这一句 UPDATE 的形状,多改一个键、多动一列,整句被拒。
-- 【为什么自己也查权限】它是 SECURITY DEFINER;EXECUTE 虽已从 authenticated 收回,
--   调用方 anonymise_employee 的持码人查得过这一道,多一道不多。
CREATE OR REPLACE FUNCTION public.change_log_redact_employee(p_employee_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_hist text[];
    v_n    integer;
BEGIN
    PERFORM require_permission('action.anonymise_employee');
    IF p_employee_id IS NULL THEN
        RAISE EXCEPTION 'PDPA_EMPLOYEE_NOT_FOUND';
    END IF;

    SELECT COALESCE(array_agg(h.id::text), ARRAY[]::text[]) INTO v_hist
      FROM employment_history h WHERE h.employee_id = p_employee_id;

    UPDATE change_log c
       SET old = change_log_null_keys(c.old, change_log_redactable_columns(c.table_name)),
           new = change_log_null_keys(c.new, change_log_redactable_columns(c.table_name)),
           redacted_at = clock_timestamp()
     WHERE c.redacted_at IS NULL
       AND (   (c.table_name = 'employees' AND c.row_key ->> 'id' = p_employee_id::text)
            OR (c.table_name = 'employment_history' AND c.row_key ->> 'id' = ANY (v_hist)));
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$function$;

-- db/functions/record_account_event.sql
-- HISTORY-1(Tim 的 Q22 · Q23 · Q2 · Q3):登录账号的生命周期写进 change_log(table_name = 'auth.users')。
--
-- 【为什么由应用调、而不是触发器】auth 架构不是我们的(平台的),在它上面挂触发器不是本仓库能做的事;
--   auth.audit_log_entries 实测 0 行。所以 /settings/accounts 的服务端动作在调 auth 之前 / 之后,
--   用【调用者自己的会话】调本函数 —— 于是 actor 是那个按按钮的人,而不是服务角色。
-- 【事件】
--   ACCOUNT_CREATE          建好之后立刻记(关联与授角色之前 —— 那两步失败时要回滚的正是它)
--   ACCOUNT_DELETE          只剩一种:建到一半失败的回滚(reason = create_rolled_back)。
--                           判据:那个账号必须【已经不在】auth.users 里 —— 先删,后记。
--   ACCOUNT_DISABLE         先记后封(见下);这里做全部检查:
--                             不许停用自己(CANNOT_DISABLE_SELF)· 已停用(ACCOUNT_ALREADY_DISABLED)·
--                             最后一个真的管理员(LAST_ADMIN_PROTECTED,判据与 guard_last_admin 同一份:
--                             real_role_grants 的四条 × 在册启用的 is_system 角色,排除这个账号)
--   ACCOUNT_ENABLE          未停用(ACCOUNT_NOT_DISABLED)
--   ACCOUNT_*_FAILED        auth 那一步失败了:照实记一行,屏幕报错。不做状态检查。
-- 【先记后封,不是先封后记】两步不在一笔事务里。先封后记,记失败时就有一个【没有记录】的停用 ——
--   正是这一刀要消灭的东西;先记后封,封失败时有一行 *_FAILED 把前一行说清楚。
CREATE OR REPLACE FUNCTION public.record_account_event(p_user_id uuid, p_event text, p_detail jsonb DEFAULT '{}'::jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_uid   uuid := auth.uid();
    v_email text;
    v_ban   timestamptz;
    v_found boolean;
    v_seq   bigint;
BEGIN
    PERFORM require_permission('action.manage_permissions');

    IF p_event NOT IN ('ACCOUNT_CREATE', 'ACCOUNT_DELETE', 'ACCOUNT_DISABLE', 'ACCOUNT_DISABLE_FAILED',
                       'ACCOUNT_ENABLE', 'ACCOUNT_ENABLE_FAILED') THEN
        RAISE EXCEPTION 'ACCOUNT_EVENT_UNKNOWN|%', p_event;
    END IF;
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_FOUND';
    END IF;

    SELECT u.email::text, u.banned_until INTO v_email, v_ban FROM auth.users u WHERE u.id = p_user_id;
    v_found := FOUND;

    IF p_event = 'ACCOUNT_DELETE' THEN
        IF v_found THEN
            RAISE EXCEPTION 'ACCOUNT_STILL_EXISTS';
        END IF;
    ELSIF NOT v_found THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_FOUND';
    END IF;

    IF p_event = 'ACCOUNT_DISABLE' THEN
        IF p_user_id = v_uid THEN
            RAISE EXCEPTION 'CANNOT_DISABLE_SELF';
        END IF;
        IF v_ban IS NOT NULL AND v_ban > now() THEN
            RAISE EXCEPTION 'ACCOUNT_ALREADY_DISABLED';
        END IF;
        IF NOT EXISTS (
            SELECT 1
              FROM roles r
             CROSS JOIN LATERAL real_role_grants(r.code) g
             WHERE r.is_system AND r.is_active AND r.deleted_at IS NULL
               AND g.user_id <> p_user_id
        ) THEN
            RAISE EXCEPTION 'LAST_ADMIN_PROTECTED';
        END IF;
    ELSIF p_event = 'ACCOUNT_ENABLE' THEN
        IF v_ban IS NULL OR v_ban <= now() THEN
            RAISE EXCEPTION 'ACCOUNT_NOT_DISABLED';
        END IF;
    END IF;

    INSERT INTO change_log (table_name, row_key, op, actor_account, actor_employee, actor_kind, db_role, new)
    VALUES ('auth.users', jsonb_build_object('id', p_user_id), p_event, v_uid, account_person(v_uid),
            CASE WHEN v_uid IS NULL THEN 'no_session' ELSE 'user' END,
            COALESCE(NULLIF(current_setting('role', true), 'none'), session_user::text),
            jsonb_build_object('email', COALESCE(v_email, p_detail ->> 'email')) || COALESCE(p_detail, '{}'::jsonb) - 'email')
    RETURNING seq INTO v_seq;
    RETURN v_seq;
END;
$function$;

-- db/functions/set_role_permissions.sql
-- 整体替换一个角色的授权。要 action.manage_permissions。
--
-- 【edit 蕴含 view 的强制在这里,不只在界面】。2b 的 fixture 量过:只授 edit 不授 view 时
-- PostgREST 的 INSERT ... RETURNING 会 42501,整条写入路径断掉 —— 那是坏配置,不是审美问题。
-- 界面挡不住 RPC 直调,所以守卫必须在数据库里。
--
-- NOTE: introduced by db/migrations/2026-08-02-perm3-banking-and-directory.sql;
--       diff-aware since db/migrations/2026-09-28-history1-change-log.sql (HISTORY-1, Tim's Q16).

CREATE OR REPLACE FUNCTION public.set_role_permissions(p_role_id uuid, p_permission_codes text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_codes   text[] := COALESCE(p_permission_codes, ARRAY[]::text[]);
    v_role    record;
    v_missing text;
    v_bad     text;
    v_added   integer;
    v_removed integer;
BEGIN
    PERFORM require_permission('action.manage_permissions');

    SELECT id, code, is_system INTO v_role
    FROM roles WHERE id = p_role_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ROLE_NOT_FOUND';
    END IF;

    -- 未知权限码直接拒绝(目录是迁移级的,界面不该能凭空造码)
    SELECT c INTO v_bad
    FROM unnest(v_codes) c
    WHERE NOT EXISTS (SELECT 1 FROM permissions p WHERE p.code = c)
    LIMIT 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'PERMISSION_NOT_FOUND|%', v_bad;
    END IF;

    -- 【核心守卫】每一个 module.<m>.edit 都必须有对应的 module.<m>.view 同行
    SELECT split_part(c, '.', 2) INTO v_missing
    FROM unnest(v_codes) c
    WHERE c LIKE 'module.%.edit'
      AND NOT ('module.' || split_part(c, '.', 2) || '.view') = ANY (v_codes)
    LIMIT 1;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'EDIT_REQUIRES_VIEW|%', v_missing;
    END IF;

    -- 系统角色不可被摘掉管理权限 —— 否则一次保存就能把权限系统本身锁死
    IF v_role.is_system AND NOT ('action.manage_permissions' = ANY (v_codes)) THEN
        RAISE EXCEPTION 'SYSTEM_ROLE_PROTECTED';
    END IF;

    -- ★ HISTORY-1(Tim 的 Q16):只动【有差别】的码。此前整批删掉再整批插回,于是每一次保存
    --   都把一个角色的每一行重写一遍,旧的码单从库里读不回来,而通用变更记录会把一次保存
    --   记成 N 删 + N 插,埋掉真正变了的那一个。现在:删掉不再要的,插进新要的,留着的一行不碰
    --   (它的 created_at / created_by 仍是当初授它的那一次 —— 比每次重写更真)。
    --   入参里重复的码被 DISTINCT + ON CONFLICT 吸收(此前会撞主键)。
    DELETE FROM role_permissions
     WHERE role_id = p_role_id AND permission_code <> ALL (v_codes);
    GET DIAGNOSTICS v_removed = ROW_COUNT;
    INSERT INTO role_permissions (role_id, permission_code, created_by)
    SELECT DISTINCT p_role_id, c, auth.uid() FROM unnest(v_codes) c
    ON CONFLICT (role_id, permission_code) DO NOTHING;
    GET DIAGNOSTICS v_added = ROW_COUNT;

    RETURN jsonb_build_object(
        'role_id', v_role.id,
        'code', v_role.code,
        'permission_count', (SELECT count(DISTINCT c) FROM unnest(v_codes) c),
        'added', v_added,
        'removed', v_removed
    );
END;
$function$;

-- db/functions/anonymise_employee.sql
-- PDPA 的"目的结束后不再保留":把一名【已离职且保留期已满】的员工就地匿名化 ——
-- 覆盖身份列,行留着。与 Doc 2 原则 7 的调和见 docs/as-built-divergences.md 第 2 条;
-- 范围、待决项与那条法律问题见 docs/pdpa.md。
--
-- 【四条按名拒绝】PDPA_RETENTION_PERIOD_NOT_SET(最要紧的一条:保留期是法律问题,
-- 这支函数不用默认值替人回答;而 2026-08-24 的裁定让它成为【今天唯一走得到】的
-- 那一条 —— 其余三条在这条裁定之下永远到不了)· PDPA_EMPLOYEE_NOT_SEPARATED
-- · PDPA_RETENTION_NOT_ELAPSED · PDPA_ALREADY_ANONYMISED。证据在 db/fixtures/126。
--
-- ★★ 【这支函数将不会被使用 —— 而这是一个决定,不是一件没做完的活】(Tim,2026-08-24)★★
-- 本函数存在、正确、有 fixture 覆盖,而在 Tim 2026-08-24 的裁定之下【将不会被使用】:
--   **员工个人数据无限期保留。没有保留期,而且不会有。**
-- 它因 hr_settings.personal_data_retention_months 为 NULL 而按名拒绝
-- (PDPA_RETENTION_PERIOD_NOT_SET),而在这条裁定之下那一列【保持 NULL】。
-- 它是一件【建好了、刻意休眠】的机制,不是没做完的活。
--
-- 【不要删掉它,不要放宽这条拒绝,不要设一个期限。】那句拒绝正是这次休眠诚实的地方 ——
-- 路是关着的,而且它说得出自己为什么关着。裁定哪天改口,把那一列设上就是全部的改动。
-- 裁定本身、它没有 settle 掉的东西(保留限制仍是 PDPA 的义务,无限期保留是公司
-- 采取的立场,不是本系统给出的豁免)、以及待决清单里它从 OPEN 变成 DECIDED 的那一行,
-- 都在 docs/pdpa.md 第二节与第五节。
--
-- 【它动两张表】employees 的身份列,与 employment_history 的薪资两列 + 备注。
-- 后者是【不可变】的表 —— 匿名化是它唯一的 UPDATE 例外,而那条例外由行的形状定义
-- (见 db/tables/employment_history.sql 里的 reject_employment_history_mutation)。
--
-- NOTE: introduced by db/migrations/2026-08-24-pdpa1-anonymise-and-subject-access.sql;
--       fixed by db/migrations/2026-08-24-pdpa1-fu-the-immutable-log-gets-one-named-exception.sql
--       (第一版在真实数据上必崩:履历不可变,而它有一句 UPDATE)。
-- ★ HISTORY-1(2026-09-28,db/migrations/2026-09-28-history1-change-log.sql):greeting_name 一并清掉;
--   末尾调 change_log_redact_employee 涂掉通用变更记录里的个人字段。
-- ★ NAME-1(2026-09-28,db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql):
--   first_name / last_name 与 preferred_name 一起清成 NULL —— 它们就是身份列。

CREATE OR REPLACE FUNCTION public.anonymise_employee(p_employee_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_months int;
    v_emp    employees%ROWTYPE;
    v_due    date;
BEGIN
    PERFORM require_permission('action.anonymise_employee');

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'PDPA_REASON_REQUIRED';
    END IF;

    -- 【没有保留期就【拒绝】,不走任何默认】默认值 = 一次法律表态。
    SELECT personal_data_retention_months INTO v_months FROM hr_settings LIMIT 1;
    IF v_months IS NULL THEN
        RAISE EXCEPTION 'PDPA_RETENTION_PERIOD_NOT_SET';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PDPA_EMPLOYEE_NOT_FOUND';
    END IF;
    IF v_emp.anonymised_at IS NOT NULL THEN
        RAISE EXCEPTION 'PDPA_ALREADY_ANONYMISED|%', v_emp.anonymised_at::date;
    END IF;
    -- 【在职的人不许匿名化】目的还没有结束 —— 那不是合规,那是把在用的数据毁掉。
    IF v_emp.separation_date IS NULL THEN
        RAISE EXCEPTION 'PDPA_EMPLOYEE_NOT_SEPARATED|%', v_emp.code;
    END IF;
    v_due := (v_emp.separation_date + make_interval(months => v_months))::date;
    IF v_due > CURRENT_DATE THEN
        RAISE EXCEPTION 'PDPA_RETENTION_NOT_ELAPSED|%|%', v_emp.code, v_due;
    END IF;

    -- 【覆盖身份列;结构性的列留着】
    -- 留下的那些(编号、雇佣类型、工种、入离职日、部门)**不指向一个人** ——
    -- 它们是让总账、历史与统计还读得懂所必需的,而原则 7 要的正是这个。
    UPDATE employees SET
        legal_name           = 'ANONYMISED ' || code,
        preferred_name       = NULL,
        first_name           = NULL,
        last_name            = NULL,
        -- HISTORY-1(Tim 的 Q9):称呼名也是名字 —— 此前漏了它。
        greeting_name        = NULL,
        identity_no          = NULL,
        work_email           = NULL,
        work_phone           = NULL,
        work_pass_no         = NULL,
        work_pass_type       = NULL,
        work_pass_issue_date = NULL,
        work_pass_expiry_date= NULL,
        residency_status     = NULL,
        monthly_salary       = NULL,
        notes                = NULL,
        separation_notes     = NULL,
        -- KPI-1:employees.job_title 已删,清的是【职位指针】。
        -- 【为什么职位也要清】职位本身是主数据、不是个人数据,但"这一行的人
        -- 曾经担任 CFO"仍然是一条关于那个人的事实 —— 匿名化要断掉的正是这种关联。
        -- **employment_history 上那一行不动**(那是不可变的履历,见 fixture 126)。
        position_id          = NULL,
        user_id              = NULL,          -- 与登录账号解绑
        anonymised_at        = now(),
        anonymised_by        = auth.uid()
    WHERE id = p_employee_id;

    -- 薪资历史也是个人数据。**其余每一张表都只按 employee_id 引用他**,
    -- 身份列一旦从这一行拿掉,那些行就不再指向一个可识别的人(化名化)。
    -- 【anonymised_at 必须一起写】—— 它是不可变守卫认得出这个形状的凭据,
    -- 也是 salary_change 行有权不说新薪资的凭据。少了它,这句 UPDATE 会被守卫
    -- 拒掉,而那正是 fixture 126 抓到的那一幕。
    UPDATE employment_history
       SET old_monthly_salary = NULL,
           new_monthly_salary = NULL,
           notes              = NULL,
           anonymised_at      = now()
     WHERE employee_id = p_employee_id
       AND anonymised_at IS NULL;

    -- ★ HISTORY-1(Tim 的 Q11):通用变更记录里关于这个人的个人字段一并涂掉。
    --   【必须在上面两句之后】—— 那两句本身就被 change_log_capture 记了行,
    --   而 employees 那一行的 old 里装着匿名化之前的每一个个人字段。
    PERFORM change_log_redact_employee(p_employee_id);

    RETURN jsonb_build_object(
        'employee_code', v_emp.code, 'anonymised_at', now(),
        'retention_months', v_months, 'due_since', v_due, 'reason', p_reason);
END;
$function$;

-- db/functions/export_my_personal_data.sql
-- PDPA 的当事人查阅:把【关于调用者自己】的个人数据导成一份 jsonb。
-- **没有参数** —— 它拿不到别人的。SECURITY DEFINER 只用来越过列级遮蔽,
-- 不用来放宽主语(遮蔽保护的是"别人看不到",不是"他自己看不到")。
--
-- 【不含绩效评估的正文】PDPA 对评价性用途(evaluative purpose)有豁免,而它怎么
-- 适用是一个【法律判断】。所以只给存在性与时间,并在返回的 note 里【对当事人说出来】——
-- 一次沉默的省略与一次说明了的排除不是一回事。
-- 【范围只到员工】往来户联系人的个人数据在库里,而这条路不通向它们。两条都记在
-- docs/pdpa.md,本文件不复述。
--
-- ★ HISTORY-1(2026-09-28):加 my_record_changes —— 通用变更记录里自己那一行的改动(见函数体注释)。
-- ★ NAME-1(2026-09-28):first_name / last_name 跟着 legal_name 一起导出 —— 它们同样是关于这个人的个人数据。
--
-- NOTE: introduced by db/migrations/2026-08-24-pdpa1-anonymise-and-subject-access.sql;
--       NAME-1 by db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql.

CREATE OR REPLACE FUNCTION public.export_my_personal_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_emp employees%ROWTYPE;
    v_account_keys text[] := ARRAY['user_id', 'created_by', 'updated_by', 'anonymised_by'];
BEGIN
    -- 【它只导出【调用者自己】的数据】—— 没有参数,拿不到别人的。
    -- ★ APR-ROUTE-1 Batch B(R3):经 current_user_employee() 认人 —— 一个人的
    --   第二个账号导出的也是【他自己】的数据,而不是一句"没有员工档案"。
    SELECT * INTO v_emp FROM employees WHERE id = current_user_employee() AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PDPA_NO_EMPLOYEE_RECORD';
    END IF;

    RETURN jsonb_build_object(
        'generated_at', now(),
        'about', jsonb_build_object(
            'employee_code', v_emp.code, 'legal_name', v_emp.legal_name,
            'first_name', v_emp.first_name, 'last_name', v_emp.last_name,
            'preferred_name', v_emp.preferred_name, 'identity_no', v_emp.identity_no,
            'work_email', v_emp.work_email, 'work_phone', v_emp.work_phone,
            'residency_status', v_emp.residency_status,
            'work_pass', jsonb_build_object('type', v_emp.work_pass_type, 'number', v_emp.work_pass_no,
                'issued', v_emp.work_pass_issue_date, 'expires', v_emp.work_pass_expiry_date),
            'employment', jsonb_build_object('type', v_emp.employment_type,
                'category', v_emp.work_category, 'status', v_emp.employment_status,
                'job_title', (SELECT p.title FROM positions p WHERE p.id = v_emp.position_id), 'hire_date', v_emp.hire_date,
                'confirmation_date', v_emp.confirmation_date,
                'separation_date', v_emp.separation_date, 'separation_type', v_emp.separation_type),
            'monthly_salary', v_emp.monthly_salary),
        'employment_history', COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.effective_date)
            FROM employment_history h WHERE h.employee_id = v_emp.id), '[]'::jsonb),
        'leave_requests', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.created_at)
            FROM leave_requests l WHERE l.employee_id = v_emp.id), '[]'::jsonb),
        'medical_claims', COALESCE((SELECT jsonb_agg(to_jsonb(m) ORDER BY m.created_at)
            FROM medical_claims m WHERE m.employee_id = v_emp.id), '[]'::jsonb),
        'payroll_lines', COALESCE((SELECT jsonb_agg(to_jsonb(pl) ORDER BY pl.created_at)
            FROM payroll_lines pl WHERE pl.employee_id = v_emp.id), '[]'::jsonb),
        -- 【绩效评估的【正文】刻意不在这里,而这是一个【法律】问题不是设计问题】
        -- PDPA 对"评价性用途"(evaluative purpose)有豁免,而这一份导出要不要
        -- 包含评估的书面结论,取决于那条豁免怎么适用 —— 那不是我能裁的。
        -- 所以这里只给【存在性与时间】,正文留白,并在 docs/pdpa.md 里点名为待决。
        'performance_reviews_metadata_only', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'review_type', r.review_type, 'period_start', r.period_start,
                'period_end', r.period_end, 'status', r.status) ORDER BY r.period_start)
            FROM performance_reviews r WHERE r.employee_id = v_emp.id), '[]'::jsonb),
        -- ★ HISTORY-1(Tim 的 Q12 · Q10):通用变更记录里【自己那一行 employees】的每一次改动 ——
        --   时间、动作、改了哪几列、改前改后;谁改的只给【员工姓名】,不给账号 id 也不给邮箱。
        --   影像里指向登录账号的键(user_id / created_by / updated_by / anonymised_by)一并拿掉。
        'my_record_changes', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'at', c.occurred_at,
                'operation', c.op,
                'changed_fields', to_jsonb(ARRAY(
                    SELECT k FROM unnest(COALESCE(c.changed_columns,
                        ARRAY(SELECT jsonb_object_keys(COALESCE(c.new, c.old, '{}'::jsonb))))) k
                     WHERE k <> ALL (v_account_keys) ORDER BY k)),
                'before', c.old - v_account_keys,
                'after', c.new - v_account_keys,
                'changed_by', (SELECT COALESCE(a.preferred_name, a.legal_name) FROM employees a WHERE a.id = c.actor_employee))
              ORDER BY c.seq)
            FROM change_log c
           WHERE c.table_name = 'employees' AND c.row_key ->> 'id' = v_emp.id::text), '[]'::jsonb),
        'note', 'Performance review content is deliberately excluded pending a legal view on the PDPA evaluative-purpose exemption. See docs/pdpa.md.');
END;
$function$;

-- ── 6 · user_directory 加 disabled(末列)─────────────────────────────────
CREATE OR REPLACE VIEW public.user_directory WITH (security_invoker = off) AS
 SELECT u.id AS user_id,
    u.email::text AS email,
    u.created_at,
    u.last_sign_in_at,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('role_id', r.id, 'code', r.code, 'name_en', r.name_en, 'name_zh', r.name_zh) ORDER BY r.sort_order, r.code) AS jsonb_agg
           FROM user_roles ur
             JOIN roles r ON r.id = ur.role_id
          WHERE ur.user_id = u.id AND ur.revoked_at IS NULL AND r.deleted_at IS NULL), '[]'::jsonb) AS roles,
        CASE
            WHEN ep.id IS NOT NULL THEN 'primary'::text
            WHEN ea.employee_id IS NOT NULL THEN 'additional'::text
            ELSE NULL::text
        END AS account_kind,
    (u.banned_until IS NOT NULL AND u.banned_until > now()) AS disabled
   FROM auth.users u
     LEFT JOIN employees ep ON ep.user_id = u.id AND ep.deleted_at IS NULL
     LEFT JOIN employee_accounts ea ON ea.user_id = u.id
     LEFT JOIN employees e ON e.id = COALESCE(ep.id, ea.employee_id) AND e.deleted_at IS NULL
  WHERE has_permission('action.manage_permissions'::text);

-- ── 7 · 238 张表的绑定 + 19 条历史表守卫:【一次往返】、放在尽量晚的地方 ─────────────
-- 【为什么包在一个 DO 里】CREATE TRIGGER 在那张表上拿 SHARE ROW EXCLUSIVE 锁,挡住写(读不挡),
--   而锁一直持到 COMMIT。第一次对着线上的干跑(整笔回滚)逐句发 ~500 条,用了 626 s ——
--   几乎全是逐句的网络往返;那段时间里 238 张表的写都会排队。包成一个 DO = 一次往返。
-- 【为什么放在这么后面】锁从这里开始算:前面的函数、视图、授权都先做完,
--   后面只剩新码的三次写(要被记下来,所以必须在绑定之后)、自证与授权兜底。
-- DO 里是字面的 CREATE TRIGGER(不是 EXECUTE 拼出来的),与镜像 db/views/zzz_change_log_triggers.sql 逐字同源。
DO $bind$
BEGIN

    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.accounts
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.accounts
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.approval_log
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.approval_log
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.assay_result_metals
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('assay_result_id', 'metal');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.assay_result_metals
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.assay_results
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.assay_results
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.asset_disposal_requests
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.asset_disposal_requests
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.attendance_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.attendance_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.attendance_periods
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.attendance_periods
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.bank_import_profiles
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.bank_import_profiles
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.bank_line_matches
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.bank_line_matches
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.bank_reconciliation_variance_items
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.bank_reconciliation_variance_items
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.bank_reconciliations
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.bank_reconciliations
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.bank_statement_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.bank_statement_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.bank_statements
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.bank_statements
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.bank_transfers
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.bank_transfers
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.batch_processing_cost_allocations
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.batch_processing_cost_allocations
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.battery_chemistries
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.battery_chemistries
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.cash_forecast_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.cash_forecast_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.cash_forecasts
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.cash_forecasts
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.certificate_types
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.certificate_types
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.certificates_of_destruction
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.certificates_of_destruction
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.cn_issues
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.cn_issues
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.cod_issues
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.cod_issues
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.cod_verification_failures
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.cod_verification_failures
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.collection_chase_documents
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.collection_chase_documents
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.collection_chases
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.collection_chases
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.collection_promises
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.collection_promises
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.commission_agreements
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.commission_agreements
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.company_compliance
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.company_compliance
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.company_profile
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.company_profile
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.container_documents
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.container_documents
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.container_milestones
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.container_milestones
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.containers
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.containers
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.contract_document_terms
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.contract_document_terms
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.contract_grade_specs
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.contract_grade_specs
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.contract_insurance_obligations
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.contract_insurance_obligations
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.contract_penalty_elements
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.contract_penalty_elements
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.contract_pricing_terms
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.contract_pricing_terms
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.contract_refining_charges
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.contract_refining_charges
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.contract_settlement_terms
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.contract_settlement_terms
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.contract_volume_commitments
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.contract_volume_commitments
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.contracts
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.contracts
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.counterparty_contacts
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.counterparty_contacts
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.credit_note_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.credit_note_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.credit_notes
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.credit_notes
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.currencies
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.currencies
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.customer_attachments
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.customer_attachments
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.customer_credit_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.customer_credit_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.customer_statements
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.customer_statements
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.customers
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.customers
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.deep_discharge_judgements
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.deep_discharge_judgements
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.departments
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.departments
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.document_relation_exceptions
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('owner_table', 'column_a', 'column_b');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.document_relation_exceptions
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.document_type_exceptions
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('table_name');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.document_type_exceptions
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.document_types
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('key');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.document_types
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.employee_account_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.employee_account_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.employee_accounts
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('user_id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.employee_accounts
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.employees
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.employees
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.employment_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.employment_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.equipment_downtime
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.equipment_downtime
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.equipment_maintenance
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.equipment_maintenance
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.equipment_service_intervals
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.equipment_service_intervals
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.expense_claims
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.expense_claims
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.expenses
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.expenses
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.finance_attachments
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.finance_attachments
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.finance_settings
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.finance_settings
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.finance_settings_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.finance_settings_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.fixed_asset_cost_entries
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.fixed_asset_cost_entries
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.fixed_asset_depreciation
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.fixed_asset_depreciation
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.fixed_asset_depreciation_anchors
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.fixed_asset_depreciation_anchors
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.fixed_asset_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.fixed_asset_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.fixed_assets
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.fixed_assets
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.forwarder_details
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('supplier_id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.forwarder_details
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.forwarder_rate_quotes
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.forwarder_rate_quotes
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.freight_allocations
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.freight_allocations
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.freight_documents
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.freight_documents
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.fx_rate_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.fx_rate_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.fx_rates
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.fx_rates
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.gst_filing_requests
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.gst_filing_requests
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.gst_periods
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.gst_periods
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.gst_return_boxes
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.gst_return_boxes
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.handover_item_types
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.handover_item_types
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.hr_settings
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.hr_settings
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.import_batches
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.import_batches
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.inbound_batch_metals
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('inbound_batch_id', 'metal');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.inbound_batch_metals
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.inbound_batch_safety_states
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('inbound_batch_id', 'safety_state_code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.inbound_batch_safety_states
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.inbound_batches
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.inbound_batches
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.inbound_chemistry_certainties
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.inbound_chemistry_certainties
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.inbound_safety_states
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.inbound_safety_states
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.inbound_source_reasons
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.inbound_source_reasons
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.index_market_calendar
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('index_code', 'calendar_date');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.index_market_calendar
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.inventory_movements
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.inventory_movements
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.invoice_issues
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.invoice_issues
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.invoice_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.invoice_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.invoice_requests
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.invoice_requests
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.invoices
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.invoices
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.journal_entries
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.journal_entries
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.journal_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.journal_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.journal_requests
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.journal_requests
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.kpi_cycles
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.kpi_cycles
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.kpi_entries
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.kpi_entries
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.kpi_organisation
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.kpi_organisation
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.kpi_position_templates
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.kpi_position_templates
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.kpi_score_rubric
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('score');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.kpi_score_rubric
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.kpi_template_org_links
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('template_id', 'org_code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.kpi_template_org_links
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.laboratories
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.laboratories
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.lane_document_requirements
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.lane_document_requirements
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.lanes
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.lanes
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.leave_accrual_rates
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.leave_accrual_rates
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.leave_consumption
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.leave_consumption
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.leave_grants
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.leave_grants
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.leave_requests
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.leave_requests
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.leave_types
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.leave_types
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.list_ledger_residue
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('side', 'doc_code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.list_ledger_residue
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.loss_categories
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.loss_categories
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.loss_metal_fates
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.loss_metal_fates
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.maintenance_settings
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.maintenance_settings
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.management_packs
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.management_packs
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.material_attachments
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.material_attachments
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.material_forms
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.material_forms
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.material_kinds
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.material_kinds
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.material_required_metals
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('material_id', 'metal');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.material_required_metals
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.material_size_formats
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.material_size_formats
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.material_sources
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.material_sources
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.materials
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.materials
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.medical_claims
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.medical_claims
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.metal_price_indices
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.metal_price_indices
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.metal_prices
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.metal_prices
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.notifications
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.notifications
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.operation_kinds
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.operation_kinds
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.operation_type_input_forms
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('operation_type_code', 'form_code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.operation_type_input_forms
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.operation_type_output_forms
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('operation_type_code', 'form_code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.operation_type_output_forms
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.operation_type_safety_states
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('operation_type_code', 'safety_state_code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.operation_type_safety_states
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.operation_types
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.operation_types
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.output_batch_metals
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('output_batch_id', 'metal');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.output_batch_metals
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.output_batch_purposes
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.output_batch_purposes
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.output_batch_safety_states
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('output_batch_id', 'safety_state_code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.output_batch_safety_states
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.output_batch_states
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.output_batch_states
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.output_batches
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.output_batches
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.overtime_batches
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.overtime_batches
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.overtime_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.overtime_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.payment_allocations
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.payment_allocations
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.payment_event_owners
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('trigger_event');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.payment_event_owners
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.payment_requests
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.payment_requests
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.payment_term_template_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.payment_term_template_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.payment_term_templates
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.payment_term_templates
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.payment_trigger_events
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.payment_trigger_events
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.payments
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.payments
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.payroll_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.payroll_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.payroll_periods
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.payroll_periods
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.payroll_requests
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.payroll_requests
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.performance_reviews
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.performance_reviews
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.period_closes
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.period_closes
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.permissions
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.permissions
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.po_issues
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.po_issues
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.ports
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.ports
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.positions
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.positions
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.prepayment_applications
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.prepayment_applications
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.price_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.price_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.pricing_formula_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.pricing_formula_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.pricing_formula_metals
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('formula_id', 'metal');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.pricing_formula_metals
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.pricing_formulas
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.pricing_formulas
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.pricing_settings
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.pricing_settings
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.pricing_term_commitment_metals
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('commitment_id', 'metal');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.pricing_term_commitment_metals
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.pricing_term_commitments
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.pricing_term_commitments
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.processing_cost_entries
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.processing_cost_entries
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.processing_cost_entry_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.processing_cost_entry_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.processing_inputs
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.processing_inputs
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.processing_outputs
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.processing_outputs
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.processing_run_losses
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('run_id', 'loss_category_code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.processing_run_losses
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.processing_runs
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.processing_runs
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.processing_settings
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.processing_settings
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.public_holidays
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.public_holidays
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.purchase_order_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.purchase_order_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.purchase_order_line_retentions
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.purchase_order_line_retentions
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.purchase_order_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.purchase_order_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.purchase_order_payment_terms
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.purchase_order_payment_terms
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.purchase_orders
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.purchase_orders
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.qt_issues
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.qt_issues
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.quote_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.quote_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.quote_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.quote_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.quotes
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.quotes
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.receipt_price_requests
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.receipt_price_requests
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.receiving_settings
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.receiving_settings
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.review_cycles
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.review_cycles
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.review_goals
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.review_goals
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.review_rating_scale
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.review_rating_scale
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.role_permissions
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('role_id', 'permission_code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.role_permissions
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.roles
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.roles
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.salary_change_requests
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.salary_change_requests
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.sales_attribution_log
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.sales_attribution_log
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.sales_order_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.sales_order_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.sales_order_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.sales_order_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.sales_order_reservations
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.sales_order_reservations
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.sales_orders
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.sales_orders
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.sales_record_movements
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.sales_record_movements
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.sales_records
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.sales_records
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.sales_settlements
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.sales_settlements
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.shift_handover_equipment_refs
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('handover_id', 'downtime_id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.shift_handover_equipment_refs
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.shift_handover_items
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.shift_handover_items
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.shift_handovers
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.shift_handovers
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.shifts
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.shifts
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.shipment_issues
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.shipment_issues
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.shipment_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.shipment_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.shipments
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.shipments
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.shipping_release_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.shipping_release_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.shipping_releases
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.shipping_releases
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.so_issues
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.so_issues
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.statement_issues
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.statement_issues
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.stocktake_counts
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.stocktake_counts
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.stocktake_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.stocktake_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.stocktakes
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.stocktakes
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.storage_location_allowed_classes
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.storage_location_allowed_classes
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.storage_locations
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.storage_locations
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.substances
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.substances
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.supplier_attachments
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.supplier_attachments
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.supplier_compliance
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.supplier_compliance
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.supplier_status_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.supplier_status_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.suppliers
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.suppliers
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.task_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.task_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.task_nodes
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.task_nodes
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.task_participants
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.task_participants
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.tasks
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.tasks
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.tax_codes
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.tax_codes
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.tax_rates
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.tax_rates
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.terms_requests
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.terms_requests
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.traceability_report_issues
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.traceability_report_issues
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.training_records
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.training_records
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.user_roles
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.user_roles
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.warehouse_requests
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.warehouse_requests
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.waste_classifications
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.waste_classifications
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.wht_natures
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.wht_natures
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.wht_rates
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.wht_rates
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.wht_remittances
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.wht_remittances
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.work_order_expected_outputs
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.work_order_expected_outputs
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.work_order_history
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.work_order_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.work_order_lines
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.work_order_lines
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.work_orders
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.work_orders
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.year_closes
        FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
    CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.year_closes
        FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
    CREATE TRIGGER trg_task_history_append_only
        BEFORE UPDATE OR DELETE ON public.task_history
        FOR EACH ROW EXECUTE FUNCTION public.guard_task_history_append_only();
    CREATE TRIGGER trg_work_order_history_append_only
        BEFORE UPDATE OR DELETE ON public.work_order_history
        FOR EACH ROW EXECUTE FUNCTION public.guard_work_order_history_append_only();
    CREATE TRIGGER trg_approval_log_no_truncate
        BEFORE TRUNCATE ON public.approval_log
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_customer_credit_history_no_truncate
        BEFORE TRUNCATE ON public.customer_credit_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_employee_account_history_no_truncate
        BEFORE TRUNCATE ON public.employee_account_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_employment_history_no_truncate
        BEFORE TRUNCATE ON public.employment_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_finance_settings_history_no_truncate
        BEFORE TRUNCATE ON public.finance_settings_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_fixed_asset_history_no_truncate
        BEFORE TRUNCATE ON public.fixed_asset_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_fx_rate_history_no_truncate
        BEFORE TRUNCATE ON public.fx_rate_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_price_history_no_truncate
        BEFORE TRUNCATE ON public.price_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_pricing_formula_history_no_truncate
        BEFORE TRUNCATE ON public.pricing_formula_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_processing_cost_entry_history_no_truncate
        BEFORE TRUNCATE ON public.processing_cost_entry_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_purchase_order_history_no_truncate
        BEFORE TRUNCATE ON public.purchase_order_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_quote_history_no_truncate
        BEFORE TRUNCATE ON public.quote_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_sales_attribution_log_no_truncate
        BEFORE TRUNCATE ON public.sales_attribution_log
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_sales_order_history_no_truncate
        BEFORE TRUNCATE ON public.sales_order_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_supplier_status_history_no_truncate
        BEFORE TRUNCATE ON public.supplier_status_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_task_history_no_truncate
        BEFORE TRUNCATE ON public.task_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
    CREATE TRIGGER trg_work_order_history_no_truncate
        BEFORE TRUNCATE ON public.work_order_history
        FOR EACH STATEMENT EXECUTE FUNCTION public.guard_history_no_truncate();
END;
$bind$;

-- ── 8 · 新码 data.view_change_log:只授 admin 与 cfo(Q1)────────────────────
INSERT INTO permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('data.view_change_log', 'data', 'View change history', '查看变更记录', 'The system-wide change history: every insert, edit and delete, who made it and what it was before. Masked values follow the same data codes as the source screens.', '全系统变更记录:每一次新增、修改与删除 —— 谁做的、改之前是什么。受遮蔽的值跟源屏幕问同一批数据码。', 280);
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, 'data.view_change_log' FROM roles r WHERE r.code IN ('admin', 'cfo')
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 9 · 自证 ────────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.h1_pending_decider_check(p_after boolean DEFAULT true)
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
    UNION ALL
    -- ★ OVERTIME-1:加班批 —— 门 action.overtime_approve;提交人不算,批里任何一个员工也不算(按人认)
    SELECT 'overtime_batch', b.label, b.submitted_by, NULL, h.user_id
      FROM public.overtime_batches b
      LEFT JOIN holds h ON 'action.overtime_approve' = ANY (h.codes)
                       AND public.self_leg(b.submitted_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.overtime_lines l
                                        WHERE l.batch_id = b.id AND l.voided_at IS NULL
                                          AND public.self_leg(NULL, l.employee_id, h.user_id) <> 'none')
     WHERE b.status = 'submitted'
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

CREATE TEMP TABLE h1_pending_after ON COMMIT DROP AS
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
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted'
UNION ALL SELECT 'overtime_batch', id FROM overtime_batches WHERE status = 'submitted';
DO $fp$
DECLARE t text; h text;
BEGIN
    FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname <> 'change_log' ORDER BY 1 LOOP
        EXECUTE format('SELECT md5(COALESCE(string_agg(x.r, E''\n'' ORDER BY x.r), '''')) FROM (SELECT row(t.*)::text AS r FROM public.%I t) x', t) INTO h;
        INSERT INTO h1_fp_after (table_name, digest) VALUES (t, h);
    END LOOP;
END;
$fp$;

DO $proof$
DECLARE
    v_bad text;
    v_j   jsonb;
    v_n   int;
BEGIN
    -- ① 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'H1_PROOF|approvals switched off';
    END IF;
    -- ② 在途单据一张不少、一张不多
    IF EXISTS ((SELECT b.k, b.id FROM h1_pending_before b EXCEPT SELECT a.k, a.id FROM h1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM h1_pending_after a EXCEPT SELECT b.k, b.id FROM h1_pending_before b)) THEN
        RAISE EXCEPTION 'H1_PROOF|a pending document changed state';
    END IF;
    -- ③ 每一张在途单据都还有一个不是它自己当事人的决定人
    SELECT string_agg(k || ':' || doc, ', ') INTO v_bad FROM pg_temp.h1_pending_decider_check(true) WHERE deciders = 0;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'H1_PROOF|pending document(s) with no eligible decider: %', v_bad; END IF;
    -- ④ 每一张表的每一行:只有 permissions 与 role_permissions 变了
    SELECT string_agg(b.table_name, ', ' ORDER BY b.table_name) INTO v_bad
      FROM h1_fp_before b JOIN h1_fp_after a USING (table_name)
     WHERE a.digest IS DISTINCT FROM b.digest AND b.table_name NOT IN ('permissions', 'role_permissions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'H1_PROOF|rows changed in: %', v_bad; END IF;
    IF (SELECT count(*) FROM h1_fp_before) <> 241 OR (SELECT count(*) FROM h1_fp_after) <> 241 THEN
        RAISE EXCEPTION 'H1_PROOF|fingerprint did not cover 241 tables';
    END IF;
    -- ⑤ 授权:恰好多了 admin 与 cfo 的 data.view_change_log 两行,别的一行不差
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM h1_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM h1_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS DISTINCT FROM 'admin:data.view_change_log, cfo:data.view_change_log' THEN
        RAISE EXCEPTION 'H1_PROOF|unexpected grant change: %', v_bad;
    END IF;
    -- ⑥ 覆盖:238 张绑定,4 张豁免,零缺口
    v_j := change_log_coverage_gaps();
    IF (v_j ->> 'examined')::int <> 242 OR (v_j ->> 'bound')::int <> 238 OR (v_j ->> 'excluded')::int <> 4
       OR jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'H1_PROOF|coverage: %', v_j;
    END IF;
    -- ⑦ 遮蔽名单与目录零缺口(26 张表)
    v_j := change_log_mask_gaps();
    IF (v_j ->> 'examined_tables')::int <> 26 OR jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'H1_PROOF|mask rules: %', v_j;
    END IF;
    -- ⑧ 本迁移自己的三次写(1 个码 + 2 条授权)已经记进去了,记成无会话 + postgres
    SELECT count(*) INTO v_n FROM change_log
     WHERE actor_kind = 'no_session' AND actor_account IS NULL AND op = 'INSERT'
       AND table_name IN ('permissions', 'role_permissions');
    IF v_n <> 3 THEN RAISE EXCEPTION 'H1_PROOF|expected 3 logged migration writes, got %', v_n; END IF;
    IF (SELECT count(*) FROM change_log) <> 3 THEN
        RAISE EXCEPTION 'H1_PROOF|change_log should hold exactly the migration''s own 3 rows';
    END IF;
    -- ⑨ 没有直接授权;价格列收回;新视图在
    IF has_table_privilege('authenticated', 'public.change_log', 'SELECT')
       OR has_table_privilege('authenticated', 'public.change_log', 'UPDATE')
       OR has_table_privilege('authenticated', 'public.change_log', 'DELETE')
       OR has_table_privilege('authenticated', 'public.change_log', 'TRUNCATE')
       OR has_table_privilege('service_role', 'public.change_log', 'SELECT')
       OR has_table_privilege('anon', 'public.change_log', 'SELECT') THEN
        RAISE EXCEPTION 'H1_PROOF|change_log has a direct grant';
    END IF;
    IF has_column_privilege('authenticated', 'public.purchase_order_history', 'new_estimated_unit_price', 'SELECT')
       OR NOT has_column_privilege('authenticated', 'public.purchase_order_history', 'amend_reason', 'SELECT') THEN
        RAISE EXCEPTION 'H1_PROOF|purchase_order_history column grants are not the masked shape';
    END IF;
    -- ⑩ 7 个真账号都没被停用
    IF EXISTS (SELECT 1 FROM auth.users WHERE banned_until > now()) THEN
        RAISE EXCEPTION 'H1_PROOF|an account is disabled';
    END IF;
END;
$proof$;

COMMIT;
