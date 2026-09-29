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
-- AUDIT-TRAIL-1a(Tim 的 Q6):每一页底部的审计记录在【读的时候】找一条记录的子行 —— 不在记录上写父键
-- (那要重绑 238 条触发器,HISTORY-1 的演练里写入被挡了约 143 秒)。record_trail 按
--   COALESCE(new, old) @> {"<外键>": "<父 id>"}   找新增 / 删除 / 改了父键的行,
--   old @> {"<外键>": "<父 id>"}(只看编辑)        找父键被改走的行。
-- 两条都是 jsonb_path_ops 的 GIN(只支持 @>,比默认的 jsonb_ops 小)。
CREATE INDEX idx_change_log_image ON public.change_log USING gin (COALESCE(new, old) jsonb_path_ops);
CREATE INDEX idx_change_log_update_old ON public.change_log USING gin (old jsonb_path_ops) WHERE op = 'UPDATE';

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
