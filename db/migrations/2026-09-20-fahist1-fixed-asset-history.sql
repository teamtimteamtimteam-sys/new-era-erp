-- db/migrations/2026-09-20-fahist1-fixed-asset-history.sql
-- FA-HIST-1 · 固定资产台账的留痕 —— 这张表【从来就没有过历史】,本刀给它一份
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【它补的是什么】B3 §4 把这个缺口立成了具名条目
-- (`FIXED-ASSETS-PLANNED-DATE-NOT-LOGGED`):`fixed_assets` 的每一次写入 ——
-- 建卡、追加成本、冲销成本、投用、验收、设计划、处置 —— **没有任何地方记得**。
-- 全库其余 11 张表各有一张 `*_history` 影子表;这张没有。本刀按 Tim 的裁定
-- (2026-09-20)建第 12 张。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【开工前重测:委托书与三份文档上的那个「五支写函数」是【错】的】★★
-- ════════════════════════════════════════════════════════════════════════════
-- 线上目录扫描(2026-09-20,`pg_proc.prosrc` 正则 INSERT/UPDATE/DELETE 命中
-- `fixed_assets`)。真集是 **7 支函数 / 8 条写语句 / 0 条 DELETE**:
--
--   ① create_fixed_asset               INSERT      整行诞生
--   ② record_expense(资本【新建】支)   INSERT      整行诞生
--   ③ record_expense(【追加成本】支)   UPDATE      cost_base
--   ④ reverse_expense                  UPDATE      cost_base
--   ⑤ set_asset_in_service             UPDATE      in_service_date
--   ⑥ set_asset_acceptance             UPDATE      acceptance_date
--   ⑦ set_asset_planned_in_service     UPDATE      planned_in_service_date
--   ⑧ dispose_fixed_asset              UPDATE      status / disposal_*
--
-- ⚠ **`depreciate_fixed_assets` 不在其中** —— 它唯一的 INSERT 落在
--   `fixed_asset_depreciation`,一个字节都不写 `fixed_assets`。它在三份文档的
--   名单上白站了。
-- ⚠ **而 `record_expense` / `reverse_expense` 从来【不在】任何一份名单上** ——
--   偏偏这两支动的是【钱】(cost_base)。照委托书那份五支的名单建出来的留痕,
--   会对成本变动全盲。
--
-- ☞ 这正是本刀采用【触发器】而不是【在函数体里逐支写 INSERT】的第一条理由:
--   名单会错,而且已经错了两次;一张表上的触发器不会漏掉第八个写入者。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★【为什么这支触发器【不提任何一个列名】—— 它不是炫技,是一条硬约束】★★★
-- ════════════════════════════════════════════════════════════════════════════
-- `db/fixtures/120` 的 F5(d)① 扫【全库函数体与视图定义】,要求除
-- `set_asset_planned_in_service` 一支之外,**没有任何地方出现
-- `planned_in_service_date` 这个名字**。它守的那句承诺是:
-- **没有一条规则【读】这个计划日去决定任何事。**
--
-- ★ 而它扫的是 `pg_proc WHERE prokind = 'f'` —— **触发器函数的 prokind 正是 'f'**
--   (线上实测:`trg_so_history_header` → prokind=f, rettype=trigger)。
--   所以一支在 INSERT 列表里写出 `old_planned_in_service_date` 的历史触发器,
--   **会当场让 120 变红**。
--
-- ☞ 两条路,Tim 裁定走第二条(2026-09-20):
--   ✗ 给 120 加第二条豁免 —— 那要动一条【已经存在的断言】,而且把那个名字
--     重新放回一个函数体里,再论证为什么这次没关系。B3 §7 已经论证过一次了。
--   ✓ **让触发器根本不提它。** 于是 `db/fixtures/120` 【一个字节都不用改】——
--     这是"最小改动"能取到的最小值:零。
--
-- 【做法】`to_jsonb(OLD)` / `to_jsonb(NEW)` 现算差集,键名在【运行时】拼成
-- `'old_' || k` / `'new_' || k`,再由 `jsonb_populate_record` 落进【真正带类型的】
-- 成对列里。于是:
--   · 表的形状 = `sales_order_history` 那一套(成对的、带类型的列),
--     `task_history` 表注那条"机器读得懂的历史才查得了"一字不让;
--   · 函数的文本里【没有】`fixed_assets` 的 22 个列名中的任何一个
--     (唯一的例外是主键 `id`,它是外键的落点,而它是这张表上唯一一个
--      任何写入都改不动的列)。
--
-- ⚠★【`jsonb_populate_record` 会【静默丢掉】没有对应列的键】★⚠
--   所以本刀在 `db/fixtures/201` 里配了一条【成对齐全】的判据:
--   `fixed_assets` 的每一个列都必须在本表里有 `old_<列>` / `new_<列>` 两列。
--   明天谁给 `fixed_assets` 加第 24 列而忘了这里,那条判据当场红 ——
--   **一次静默丢失换成一次点名的失败**,这是 Tim 的裁定里点名要的那条。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【谁改的:auth.uid(),而"没有人"要【说出口】】
--   `auth.uid()` 读的是会话 GUC(`request.jwt.claims ->> 'sub'`),**不是角色** ——
--   所以 SECURITY DEFINER 的换角色动不了它。全库 11 张留痕里 8 张用
--   `changed_by uuid DEFAULT auth.uid()`,而 `fixed_assets.created_by` 也是这一族
--   (auth 空间),本表照抄。
--   ★ 而 `auth.uid()` 为 NULL 的那一种,**不许留一个沉默的 NULL** —— 它读起来
--     像"不知道是谁",而真相是【一个不经登录的数据库直连会话】,那是一句
--     说得出口的话。于是 `changed_by_kind NOT NULL`,取值 'user' / 'no_session'。
--   ⚠ **不叫 'system'**:线上没有 pg_cron(实测 6 个扩展,没有它),
--     `depreciate_fixed_assets` 又根本不写这张表 —— **没有任何系统写入者**。
--     叫它 'system' 是给一个不存在的主体起名字。
--
-- 【硬删:拦住,而不是记下来】(Tim 裁定 Q3)
--   本表带外键指向 `fixed_assets`(11 张留痕全都带)。于是一次硬删会撞外键,
--   而那句报错既不说是哪张卡、也不说规矩 —— FIN-31 那一条。所以照
--   `guard_purchase_order_no_hard_delete` / `trg_tasks_no_hard_delete` 两处先例,
--   在基表上加一支【自己报名】的 BEFORE DELETE 守卫。
--   ☞ 「覆盖每一次写」在这里取到了更强的那一种:**那一种写被拒绝,而不是被记录。**
--   ⚠ 它拦的是一扇今天就开着的门:`authenticated` 手上【有】表级 DELETE 授权
--     (Supabase 默认),今天挡住它的只是"没有 DELETE 策略"这一件事。
--
-- 【不回填】线上两行是测试数据。**不给它们发明历史。**
--   屏幕的空状态会说清:留痕从本次迁移落地那天起算。
--
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ═══ 1 · 影子表 ═════════════════════════════════════════════════════════════
CREATE TABLE public.fixed_asset_history (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    fixed_asset_id   uuid NOT NULL REFERENCES public.fixed_assets (id),
    -- 【只有两个取值,而这是【量】出来的,不是省事】线上 8 条写语句里,
    -- INSERT 两条、UPDATE 六条、DELETE 零条。触发器不提列名,所以它【分不出】
    -- 也【不该分出】"这是一次投用还是一次设计划" —— 那件事由 changed_columns
    -- 这一列的【数据】回答,不由函数的【文本】回答。
    -- ⚠ 【没有 'deleted'】:硬删被 guard_fixed_assets_no_hard_delete 拦死,
    --    一个任何路径都产不出来的取值,写在 CHECK 清单里就是一句谎。
    change_type      text NOT NULL CHECK (change_type IN ('created','updated')),
    -- 这一次动了哪几列。**这是屏幕的索引**,也是"哪一列被改过几次"的答案。
    changed_columns  text[] NOT NULL,
    changed_at       timestamptz NOT NULL DEFAULT now(),
    changed_by       uuid DEFAULT auth.uid(),
    changed_by_kind  text NOT NULL CHECK (changed_by_kind IN ('user','no_session')),

    -- ═══ 23 对,一个不落 ═══════════════════════════════════════════════════
    -- 【为什么连 id / created_at / created_by 这种永不改动的列也配一对】
    -- 因为"每一列都有一对"是一条【没有例外的】规矩,而一条带例外的规矩需要
    -- 一份豁免名单 —— 而豁免名单会烂(fixture 120 F5(d) 正是为这件事重写过一次)。
    -- ★ 而它顺带买到一样东西:'created' 那一行的 new_* 侧【全部填满】,
    --   于是"这台机器出生时是什么样"单看留痕就答得出来。
    old_id                        uuid,        new_id                        uuid,
    old_code                      text,        new_code                      text,
    old_description               text,        new_description               text,
    old_category                  text,        new_category                  text,
    old_acquisition_date          date,        new_acquisition_date          date,
    old_in_service_date           date,        new_in_service_date           date,
    old_cost_ccy                  numeric,     new_cost_ccy                  numeric,
    old_currency                  text,        new_currency                  text,
    old_fx_rate                   numeric,     new_fx_rate                   numeric,
    old_cost_base                 numeric,     new_cost_base                 numeric,
    old_useful_life_months        integer,     new_useful_life_months        integer,
    old_residual_base             numeric,     new_residual_base             numeric,
    old_depreciation_account_code text,        new_depreciation_account_code text,
    old_status                    text,        new_status                    text,
    old_disposal_date             date,        new_disposal_date             date,
    old_disposal_proceeds_base    numeric,     new_disposal_proceeds_base    numeric,
    old_disposal_journal_id       uuid,        new_disposal_journal_id       uuid,
    old_expense_id                uuid,        new_expense_id                uuid,
    old_notes                     text,        new_notes                     text,
    old_created_at                timestamptz, new_created_at                timestamptz,
    old_created_by                uuid,        new_created_by                uuid,
    old_planned_in_service_date   date,        new_planned_in_service_date   date,
    old_acceptance_date           date,        new_acceptance_date           date
);

COMMENT ON TABLE public.fixed_asset_history IS
    'FA-HIST-1:固定资产台账的变更留痕,只增不改(形状取自 sales_order_history —— 成对的、带类型的列)。
【写入口只有一个:基表上的 AFTER 触发器 trg_fixed_assets_history】。不在 7 支写函数里逐支写 INSERT —— 那份名单在三份文档上错过两次(把不写这张表的 depreciate_fixed_assets 算了进去,又漏掉了动 cost_base 的 record_expense / reverse_expense)。一张表上的触发器不会漏掉第八个写入者。
★【那支触发器【不提任何一个列名】,而这是一条硬约束,不是风格】fixtures/120 的 F5(d)① 扫全库函数体,要求 planned_in_service_date 这个名字只许出现在一支具名函数里;触发器函数的 prokind 也是 f,照样被扫。于是本刀让触发器用 to_jsonb 现算差集、运行时拼出 old_/new_ 键名,再由 jsonb_populate_record 落进带类型的列 —— fixtures/120 因此【一个字节都没改】。
⚠ jsonb_populate_record 会静默丢掉没有对应列的键,所以 fixtures/201 配了一条「成对齐全」判据:fixed_assets 的每一列都必须在本表有 old_/new_ 两列。加第 24 列而忘了这里,那条判据当场红。
【不回填】本表落地之前的改动没有记录,那不是「没有改过」—— 屏幕的空状态照直说这一句。';

COMMENT ON COLUMN public.fixed_asset_history.change_type IS
    'FA-HIST-1:只有 created / updated 两个取值,而这是【量】出来的。触发器不提列名(见表注),所以它分不出也不该分出「这是投用还是设计划」—— 那件事由 changed_columns 的【数据】回答,不由函数的【文本】回答。★ 若由文本回答,就等于让一条规则去【读】那个计划日来决定一行历史长什么样,而那正是 fixtures/120 守的那句承诺要拦的形状。⚠ 没有 deleted:硬删被 guard_fixed_assets_no_hard_delete 拦死,一个任何路径都产不出来的取值写进 CHECK 就是一句谎。';

COMMENT ON COLUMN public.fixed_asset_history.changed_columns IS
    'FA-HIST-1:这一次动了哪几列(列名本身,按字母序)。**屏幕据此决定渲染哪几对**,所以它不是冗余:46 列里哪一对有内容,靠读这一列一次答完,而不是在 TS 里比 46 个 NULL。它也是「哪一列被改过几次」的答案。
【created 那一行是全部 23 个列名】—— 整行是新的,这是实话;屏幕对 created 另画一种(出生快照),不画 23 行 diff。
【永不为空】一次什么都没改的 UPDATE 不写行(见触发器),所以空数组在本表里不存在。';

COMMENT ON COLUMN public.fixed_asset_history.changed_by IS
    'FA-HIST-1:auth.uid() —— 登录账号(auth 空间),与 fixed_assets.created_by 同一族,也与全库 11 张留痕里的 8 张同一族。
【SECURITY DEFINER 动不了它】auth.uid() 读的是会话 GUC(request.jwt.claims ->> ''sub''),不是 current_user;DEFINER 换的是角色。sales_order_history 就是靠这一条工作的(它的 changed_by DEFAULT auth.uid(),唯一写入者是 SECURITY DEFINER 触发器)。
【它可以是 NULL,而那一种【有名字】】见 changed_by_kind —— 一个沉默的 NULL 读起来像「不知道是谁」,而真相是一句说得出口的话。';

COMMENT ON COLUMN public.fixed_asset_history.changed_by_kind IS
    'FA-HIST-1:这一行的「谁」属于哪一种。''user'' = 有登录会话(changed_by 是那个账号);''no_session'' = auth.uid() 为 NULL,也就是【一个不经登录的数据库直连会话】(psql / Management API / 迁移)。
★★【为什么不叫 ''system''】★★ 线上【没有任何系统写入者】:pg_cron 不在这个库里(实测 6 个扩展),而唯一一支作业形状的函数 depreciate_fixed_assets 根本不写 fixed_assets(它只写 fixed_asset_depreciation)。叫它 ''system'' 是给一个不存在的主体起名字,而那个名字会在三个月后被读成「例行作业改的,不用查」。
【它 NOT NULL,而 changed_by 可空】—— 这正是这一列存在的全部理由:缺席必须被【命名】,不许由一个 NULL 去暗示。';

COMMENT ON COLUMN public.fixed_asset_history.old_id IS
    'FA-HIST-1:【它永远等于 new_id,而它仍然在】。本表的规矩是「fixed_assets 的每一列都有一对」,没有例外 —— 一条带例外的规矩需要一份豁免名单,而豁免名单会烂(fixtures/120 F5(d) 为这件事重写过一次)。fixtures/201 的「成对齐全」判据也因此不必带例外。';

CREATE INDEX idx_fixed_asset_history_asset
    ON public.fixed_asset_history (fixed_asset_id, changed_at DESC);

-- ═══ 2 · 只增不改的守卫 ═════════════════════════════════════════════════════
-- 【自己报名,不靠外键顺带挡】—— FIN-31 那一条,与 guard_sales_order_history_append_only 同形。
CREATE OR REPLACE FUNCTION public.guard_fixed_asset_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'FA_HISTORY_IMMUTABLE';
END;
$function$;

CREATE TRIGGER trg_fixed_asset_history_append_only
    BEFORE UPDATE OR DELETE ON public.fixed_asset_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_fixed_asset_history_append_only();

-- ═══ 3 · 捕获 —— ★ 这支函数【不提 fixed_assets 的任何列名】(id 除外,见抬头)═══
CREATE OR REPLACE FUNCTION public.trg_fixed_assets_history()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    -- INSERT 时把"改动前"当成空对象 —— 于是每一列都算变了,'created' 那一行的
    -- new_* 侧全部填满(出生快照)。这一句是 change_type 之外唯一分 INSERT/UPDATE 的地方。
    v_old     jsonb  := CASE WHEN TG_OP = 'INSERT' THEN '{}'::jsonb ELSE to_jsonb(OLD) END;
    v_new     jsonb  := to_jsonb(NEW);
    v_payload jsonb  := '{}'::jsonb;
    v_cols    text[] := ARRAY[]::text[];
    k         text;
BEGIN
    -- 差集。**键名在运行时拼**,所以这个函数体里没有出现过任何一个列名 ——
    -- 那正是 fixtures/120 不用改的原因(见迁移抬头)。
    FOR k IN SELECT key FROM jsonb_each(v_new) ORDER BY key LOOP
        IF v_old -> k IS DISTINCT FROM v_new -> k THEN
            v_cols    := v_cols || k;
            v_payload := v_payload
                || jsonb_build_object('old_' || k, v_old -> k, 'new_' || k, v_new -> k);
        END IF;
    END LOOP;

    -- 【什么都没改的 UPDATE 不留行】与 trg_so_history_header 那一句同一条理由:
    -- 一行"什么都没变"的历史会把真正的修改淹掉。而这里的判据是【差集】,
    -- 不是任何一个具名的列 —— 所以它没有把那条规矩换成一份列名清单。
    IF cardinality(v_cols) = 0 THEN
        RETURN NULL;
    END IF;

    -- jsonb_populate_record 把运行时拼出来的键落进【真正带类型的】成对列。
    -- ⚠ 它会静默丢掉没有对应列的键 —— fixtures/201 的「成对齐全」判据守这一头。
    INSERT INTO fixed_asset_history
    SELECT (jsonb_populate_record(NULL::fixed_asset_history, v_payload || jsonb_build_object(
        'id',              gen_random_uuid(),
        'fixed_asset_id',  NEW.id,
        'change_type',     CASE WHEN TG_OP = 'INSERT' THEN 'created' ELSE 'updated' END,
        'changed_columns', to_jsonb(v_cols),
        'changed_at',      now(),
        'changed_by',      auth.uid(),
        'changed_by_kind', CASE WHEN auth.uid() IS NULL THEN 'no_session' ELSE 'user' END
    ))).*;

    RETURN NULL;   -- AFTER 触发器,返回值不作数
END;
$function$;

CREATE TRIGGER trg_fixed_assets_history
    AFTER INSERT OR UPDATE ON public.fixed_assets
    FOR EACH ROW EXECUTE FUNCTION public.trg_fixed_assets_history();

-- ═══ 4 · 硬删:拦住,而不是记下来(Tim 裁定 Q3)═════════════════════════════
CREATE OR REPLACE FUNCTION public.guard_fixed_assets_no_hard_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 【自己报名】—— 同 guard_purchase_order_no_hard_delete。靠 fixed_asset_history
    -- 的外键顺带挡下来的那句报错,既不说是哪张卡、也不说规矩;而一张【还没有过
    -- 任何改动】的卡它根本不拦(那时影子表里一行都没有)。
    -- 处置一台机器走 dispose_fixed_asset,它留下 status/disposal_date 与一笔分录。
    RAISE EXCEPTION 'FIXED_ASSET_NO_HARD_DELETE|%', OLD.code;
END;
$function$;

CREATE TRIGGER trg_fixed_assets_no_hard_delete
    BEFORE DELETE ON public.fixed_assets
    FOR EACH ROW EXECUTE FUNCTION public.guard_fixed_assets_no_hard_delete();

-- ═══ 5 · RLS ════════════════════════════════════════════════════════════════
ALTER TABLE public.fixed_asset_history ENABLE ROW LEVEL SECURITY;

-- 留痕【没有 INSERT/UPDATE/DELETE 策略】:唯一写入口是属主权限的触发器
-- (同 sales_order_history / approval_log:留痕不该有第二个写法)。
-- ★ 读的门与基表【同一个】—— fixed_assets 的策略也是 module.finance.view。
--   两道门取同一个权限码,于是"这里零行"在屏幕上就真的只有一个意思。
CREATE POLICY "fixed_asset_history select by permission" ON public.fixed_asset_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- 【anon 授权基线】新表会拿到 Supabase 的默认表级授权(与其余 11 张留痕一样 ——
-- 它们全在 db/anon-grants-baseline.tsv 里)。RLS 挡住 anon:本表唯一的策略
-- 是 `TO authenticated`。基线那一行是【刻意加的】,理由就是这一句。
-- ════════════════════════════════════════════════════════════════════════════
