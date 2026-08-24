-- SOD-1:职责分离 —— 一条规矩,两个问法;以及审批开关的两道安全闸
--
-- ═══ 一 · 这一刀关的两条路(实测,2026-08-24)═══
--
-- ① 【过账 + 关账】post_journal_entry 与 close_period 都只判 module.finance.edit。
--    同一个人可以记一笔手工凭证,再把那个期间锁上 —— 而锁上之后没有人能再改它。
-- ② 【建收款人 + 付款给他】finance 角色同时持有 module.suppliers.edit 与
--    module.finance.edit(实测的角色矩阵)。同一个人可以建一家供应商,再付款给它。
--
-- **②【就是】这条控制存在的理由**:它不是一个假设的形状,它是线上角色矩阵里
-- 量出来的一条路。记在 docs/as-built-divergences.md 第 3 条。
--
-- ═══ 二 · 一条规矩,不是两种拼法 ═══
--
-- 规矩只有一句:**做第二步的人,不可以是做过第一步的那个人。**
-- 它的实现只有一份 —— assert_segregated(),一次比较、一处 RAISE。
--
-- 【两个问法不同,而那是【问题】不同,不是【规矩】不同】
--   ① 问的是:"这个期间里,谁记过手工凭证?"—— 一个集合,可能有很多人;
--   ② 问的是:"这家供应商是谁建的?"—— 一个人。
-- 所以有两支取数函数,各自回答自己那一问,而两支都把答案交给同一个 assert_segregated。
-- 把规矩抄两遍会让它们某一天分家;把问题合并会造出一个谁都看不懂的参数。
--
-- 【错误码有两个,而这是【路】不同,不是规矩不同】拒绝必须说出出路,
-- 而两条路的出路不是同一句话("另一个持 module.finance.edit 的人来关账"
-- 与"另一个持 module.finance.edit 的人来付这笔款")。所以 assert_segregated
-- 把错误码当参数收 —— 仍然只有一处 RAISE。
--
-- ═══ 三 · 为什么是触发器(GO-2 的形状,原样继承)═══
--
-- authenticated 对 payments 与 finance_settings 都持有【表级 INSERT/UPDATE 授权】
-- (实测),而 /finance/settings 那个"手动锁"就是一条【直连 UPDATE】——
-- 它不走 close_period。只在函数里判,后门是通的。
-- 触发器函数是 SECURITY DEFINER,理由与 GO-2 逐字相同:闸要读 journal_entries
-- 与 suppliers,而一个【有 edit 没 view】的写入者读到 0 行,闸就会空转 ——
-- 空集不是"没有"。
--
-- ═══ 四 · 这一刀【必须】同时让 created_by 真的落下来,否则控制②永远不会触发 ═══
--
-- 实测:suppliers.created_by **没有 DEFAULT**,而 app/suppliers/new/actions.ts 的
-- INSERT **不传这一列**。于是线上 8 家供应商的 created_by 【全部为 NULL】,
-- 将来新建的也会是 NULL。**一条挂在恒为 NULL 的列上的规矩,是一条永远不会触发
-- 的规矩** —— 本仓库对"报告了却不拦的判词"的处置是修它,不是记下来。
--
-- 【为什么【不是】DEFAULT auth.uid() —— 这一条是测出来的,不是想出来的】
-- suppliers.created_by 有一条 **FOREIGN KEY -> auth.users(id)**。
-- 而 db/fixtures 里有 **89 份**会插 suppliers / customers,并且几乎每一份都先
-- set_config('request.jwt.claims', ...) 成一个【随机 uuid】—— 那个 uuid 在
-- auth.users 里没有行。给这一列加 DEFAULT auth.uid(),那 89 份会当场撞 FK 违反,
-- 门整片变红 —— 而它们与职责分离毫无关系。
--
-- 【所以判据取自【外键自己的条件】】只有当 auth.uid() 确实是一个 auth.users 里
-- 存在的账号时才落笔。这不是一个绕过 FK 的花招,它就是 FK 会接受的那个条件:
--   * 线上每一个真人都在 auth.users 里 -> 每一次真实创建都留下主语,**后门也留**
--     (直连 INSERT 一样过触发器);
--   * fixture 的合成主语不在 auth.users 里 -> 留 NULL,**那是实话**,
--     因为那个 uuid 本来就不是一个账号。
--
-- 【那 8 行【不回填】】FIN-26 的规矩:一份捏造的来历记录比一片空白更坏。
-- 于是控制②【对这 8 家既有供应商不适用】,而这句话必须被读到,
-- 不能藏在"控制已上线"后面 —— 写在 docs/known-issues.md 的 SOD-1-BLIND 条。
--
-- 【那 8 行【不回填】】FIN-26 的规矩:一份捏造的来历记录比一片空白更坏。
-- 于是控制②【对这 8 家既有供应商不适用】,而这句话必须被读到,
-- 不能藏在"控制已上线"后面 —— 写在 docs/known-issues.md 的 SOD-1-BLIND 条。
--
-- ═══ 五 · 审批开关:两道闸,把"开着但没配"这个状态变成【到不了】 ═══
--
-- docs/approvals-scoping.md 记着三个状态,其中"on, policy unset → 拒绝路由"。
-- 那个状态**会把在途单据搁死**:create_purchase_order 会照常生成 pending 的单,
-- 而 approve_purchase_order 撞上 APPROVAL_LEVEL1_ROLE_NOT_SET —— 单子既批不了、
-- 也收不了货。所以这一刀把它做成【到不了】,而不是【到了会拒绝】。
--
-- 【反方向那一半才是真正会搁死人的】关掉开关时,已经 pending 的单会永远停在
-- pending:approve_purchase_order 会抛 APPROVALS_NOT_ENABLED。
-- 所以关闭同样有闸,并且点名还剩几张、是哪几张。
--
-- 【这一刀【不】打开审批】approvals_enabled 保持 false,三个策略列保持 NULL。
-- 开不开是 Tim 的决定;这一刀交付的是"开得安全"这件能力。

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1 · 规矩本身 —— 一次比较,一处 RAISE
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.assert_segregated(
    p_code         text,
    p_first_actors uuid[],
    p_subject      text
) RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_actor uuid := auth.uid();
BEGIN
    -- 【没有主语时不判】auth.uid() 为 NULL 的调用方是迁移、后台作业、service_role ——
    -- 它们本来就绕过 RLS,这里不是一个新洞。但它意味着**以 postgres 跑的 fixture
    -- 不设 claims 就是空转的**(AGENTS.md 反复记过的那种"空洞的臂"),
    -- 所以 db/fixtures/127 每一臂都设 request.jwt.claims。
    IF v_actor IS NULL THEN
        RETURN;
    END IF;

    -- 【空集就是空集,不是"通过"】第一步没有留下主语(例如 created_by 为 NULL)时,
    -- 这条规矩**没有可比的对象**,于是它不适用 —— 而"不适用"与"查过了,没问题"
    -- 不是一回事。这个区别写在 docs/known-issues.md 的 SOD-1-BLIND 条,
    -- 因为它今天对 8 家既有供应商成立。
    IF p_first_actors IS NULL OR cardinality(p_first_actors) = 0 THEN
        RETURN;
    END IF;

    IF v_actor = ANY (p_first_actors) THEN
        RAISE EXCEPTION '%|%', p_code, COALESCE(p_subject, '?');
    END IF;
END;
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- 2 · 问法① —— "这个期间里,谁记过手工凭证?"
--
-- 【为什么只算 source_type='manual'】其余每一种 source_type 都是另一个受控动作的
-- 【后果】(一笔付款、一次销售、一次工资过账),它们各自有自己的门。
-- 把它们算进来,等于"凡是引起过任何一笔分录的人都不许关账"——
-- 在一个财务只有一个人的公司里那不是一条控制,那是一把锁死的门。
-- **要防的是那一笔【自由裁量的】调整,然后把期间锁上让它没人再看得见** ——
-- 手工凭证正是那一笔。范围写在这里,而不是留给读的人推断。
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sod_manual_posters_in(p_from date, p_to date)
RETURNS uuid[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(array_agg(DISTINCT je.created_by), '{}'::uuid[])
      FROM journal_entries je
     WHERE je.source_type = 'manual'
       AND je.created_by IS NOT NULL
       AND je.entry_date >= COALESCE(p_from, '-infinity'::date)
       AND je.entry_date <= p_to;
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- 3 · 问法② —— "这家供应商是谁建的?"
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sod_supplier_creator(p_supplier_id uuid)
RETURNS uuid[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN s.created_by IS NULL THEN '{}'::uuid[] ELSE ARRAY[s.created_by] END
      FROM suppliers s
     WHERE s.id = p_supplier_id;
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- 4 · 让 created_by 真的落下来 —— 没有它,控制② 是一条永不触发的规矩
--
-- 【不是 DEFAULT,是触发器,理由见抬头第四节】DEFAULT auth.uid() 会让 89 份
-- 既有 fixture 撞上 suppliers_created_by_fkey。判据取自外键自己的条件:
-- **auth.uid() 是不是一个真的账号。** 是就落笔(真人的每一次创建都留下主语,
-- 直连 INSERT 也一样),不是就留 NULL(那个 uuid 本来就不是账号,NULL 是实话)。
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.stamp_supplier_creator()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.created_by IS NULL
       AND auth.uid() IS NOT NULL
       AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = auth.uid())
    THEN
        NEW.created_by := auth.uid();
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_supplier_creator ON public.suppliers;
CREATE TRIGGER trg_supplier_creator
    BEFORE INSERT ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION public.stamp_supplier_creator();

COMMENT ON COLUMN public.suppliers.created_by IS
    'SOD-1:建这一行的人。【职责分离控制②的主语】—— sod_supplier_creator() 读它,建供应商的人不得对该供应商付款。此前无默认值且 app 的 INSERT 不传它,所以线上 8 行全为 NULL;那 8 行不回填(FIN-26:捏造的来历比空白更坏),控制②对它们不适用,见 docs/known-issues.md 的 SOD-1-BLIND 条。今起由 trg_supplier_creator 落笔,而它只在 auth.uid() 确实是一个 auth.users 账号时落笔 —— 那正是本列外键会接受的条件。';

-- ───────────────────────────────────────────────────────────────────────────
-- 5 · 后门① —— finance_settings.locked_before 的直连 UPDATE
--     (/finance/settings 的"手动锁"走的正是这条,它不经过 close_period)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_finance_settings_sod()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 只管【前进】的锁。解锁与 reopen_period 把锁往回搬,那不隐藏任何东西。
    IF NEW.locked_before IS NULL THEN
        RETURN NEW;
    END IF;
    IF OLD.locked_before IS NOT NULL AND NEW.locked_before <= OLD.locked_before THEN
        RETURN NEW;
    END IF;

    -- 与正门同一个问法、同一份规矩。
    PERFORM assert_segregated(
        'SOD_POST_AND_CLOSE',
        sod_manual_posters_in(OLD.locked_before, NEW.locked_before - 1),
        to_char(NEW.locked_before - 1, 'YYYY-MM-DD'));
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_finance_settings_sod ON public.finance_settings;
CREATE TRIGGER trg_finance_settings_sod
    BEFORE UPDATE ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION public.guard_finance_settings_sod();

-- ───────────────────────────────────────────────────────────────────────────
-- 6 · 后门② —— payments 的直连 INSERT
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_payment_sod()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    -- 范围:【出款】给【供应商】。
    --   · 收款(direction='in')不是"付给收款人",风险形状不同(虚构收入),
    --     不在本刀范围 —— 说出来,而不是让读的人以为查过了;
    --   · 出款给【员工】(报销)由 HR 建档、财务付款,已经跨了两个模块的门,
    --     不是同一个人端到端。
    IF NEW.direction <> 'out' OR NEW.counterparty_type <> 'supplier' THEN
        RETURN NEW;
    END IF;

    -- 【冲销不是付款】reverse_payment 造的镜像行 direction/counterparty 与原单相同,
    -- 所以它会走到这里。冲销是把钱【收回来】的更正动作,拦住它只会把一笔记错的
    -- 付款锁死在账上 —— 而且拦不住任何舞弊。
    -- 由调用方【显式声明】,不由守卫去猜(与 po_status_ctx / close_ctx / alloc_ctx
    -- 同一个惯用法)。
    IF COALESCE(current_setting('evoltrya.payment_reversal_ctx', true), '') = '1' THEN
        RETURN NEW;
    END IF;

    SELECT s.code INTO v_code FROM suppliers s WHERE s.id = NEW.supplier_id;
    PERFORM assert_segregated(
        'SOD_PAYEE_AND_PAY',
        sod_supplier_creator(NEW.supplier_id),
        COALESCE(v_code, NEW.supplier_id::text));
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_payment_sod ON public.payments;
CREATE TRIGGER trg_payment_sod
    BEFORE INSERT ON public.payments
    FOR EACH ROW EXECUTE FUNCTION public.guard_payment_sod();

-- ───────────────────────────────────────────────────────────────────────────
-- 7 · 审批开关的两道闸
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.approvals_readiness()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s        record;
    v_blocking text[] := '{}';
    v_l1_real  integer := 0;
    v_l2_real  boolean := false;
    v_pending  integer := 0;
BEGIN
    SELECT approvals_enabled, approval_level1_role_code, approval_threshold_base,
           approval_level2_user_id
      INTO v_s FROM finance_settings LIMIT 1;

    IF v_s.approval_level1_role_code IS NULL THEN
        v_blocking := v_blocking || 'approval_level1_role_code';
    ELSE
        -- 【数的是【真的登录得了的】持有人】线上有 66 条 user_roles 的 user_id
        -- 在 auth.users 里根本不存在(见 known-issues 的 ACCOUNTS-STALE 条)。
        -- 一个只由幽灵持有的角色,是一个永远不会有人来批的队列。
        SELECT count(*) INTO v_l1_real
          FROM user_roles ur
          JOIN roles r ON r.id = ur.role_id
          JOIN auth.users u ON u.id = ur.user_id
         WHERE r.code = v_s.approval_level1_role_code AND r.is_active;
        IF v_l1_real = 0 THEN
            v_blocking := v_blocking || 'approval_level1_role_has_no_real_holder';
        END IF;
    END IF;

    IF v_s.approval_threshold_base IS NULL THEN
        v_blocking := v_blocking || 'approval_threshold_base';
    END IF;

    IF v_s.approval_level2_user_id IS NULL THEN
        v_blocking := v_blocking || 'approval_level2_user_id';
    ELSE
        SELECT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_s.approval_level2_user_id)
          INTO v_l2_real;
        IF NOT v_l2_real THEN
            v_blocking := v_blocking || 'approval_level2_user_is_not_a_real_account';
        END IF;
    END IF;

    SELECT count(*) INTO v_pending
      FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL;

    RETURN jsonb_build_object(
        'enabled',                 v_s.approvals_enabled,
        'level1_role_code',        v_s.approval_level1_role_code,
        'level1_real_holders',     v_l1_real,
        'threshold_base',          v_s.approval_threshold_base,
        'level2_user_id',          v_s.approval_level2_user_id,
        'level2_user_is_real',     v_l2_real,
        'pending_purchase_orders', v_pending,
        'blocking',                to_jsonb(v_blocking),
        'can_enable',              (NOT v_s.approvals_enabled AND cardinality(v_blocking) = 0),
        'can_disable',             (v_s.approvals_enabled AND v_pending = 0)
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.guard_approvals_switch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_missing text[] := '{}';
    v_holders integer;
    v_pending integer;
    v_codes   text;
BEGIN
    -- ── 开:三个策略值必须齐,而且必须【指向真的人】 ──
    IF NEW.approvals_enabled AND NOT OLD.approvals_enabled THEN
        IF NEW.approval_level1_role_code IS NULL THEN
            v_missing := v_missing || 'approval_level1_role_code';
        END IF;
        IF NEW.approval_threshold_base IS NULL THEN
            v_missing := v_missing || 'approval_threshold_base';
        END IF;
        IF NEW.approval_level2_user_id IS NULL THEN
            v_missing := v_missing || 'approval_level2_user_id';
        END IF;
        IF cardinality(v_missing) > 0 THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_INCOMPLETE|%', array_to_string(v_missing, ', ');
        END IF;

        SELECT count(*) INTO v_holders
          FROM user_roles ur JOIN roles r ON r.id = ur.role_id
          JOIN auth.users u ON u.id = ur.user_id
         WHERE r.code = NEW.approval_level1_role_code AND r.is_active;
        IF v_holders = 0 THEN
            RAISE EXCEPTION 'APPROVALS_LEVEL1_ROLE_UNHELD|%', NEW.approval_level1_role_code;
        END IF;

        IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = NEW.approval_level2_user_id) THEN
            RAISE EXCEPTION 'APPROVALS_LEVEL2_USER_UNKNOWN|%', NEW.approval_level2_user_id;
        END IF;
    END IF;

    -- ── 关:在途的 pending 单会被永远搁死,所以先点名 ──
    IF OLD.approvals_enabled AND NOT NEW.approvals_enabled THEN
        SELECT count(*), string_agg(code, ', ' ORDER BY code)
          INTO v_pending, v_codes
          FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL;
        IF COALESCE(v_pending, 0) > 0 THEN
            RAISE EXCEPTION 'APPROVALS_CANNOT_DISABLE_WITH_PENDING|%|%', v_pending, v_codes;
        END IF;
    END IF;

    -- ── 开着的时候不许把策略值抽走 ──
    IF NEW.approvals_enabled THEN
        IF NEW.approval_level1_role_code IS NULL AND OLD.approval_level1_role_code IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_level1_role_code';
        END IF;
        IF NEW.approval_threshold_base IS NULL AND OLD.approval_threshold_base IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_threshold_base';
        END IF;
        IF NEW.approval_level2_user_id IS NULL AND OLD.approval_level2_user_id IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_level2_user_id';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_approvals_switch ON public.finance_settings;
CREATE TRIGGER trg_approvals_switch
    BEFORE UPDATE ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION public.guard_approvals_switch();

-- ───────────────────────────────────────────────────────────────────────────
-- 8 · reverse_payment 声明【这是一次冲销】
--
-- 【为什么正门不再各自调一次规矩】GO-2 的形状是"正门本来就有闸,再给后门补一道,
-- 两道调用同一份实现"。这里的正门【本来没有闸】,而触发器同时盖住了正门与后门 ——
-- close_period 与 record_payment 写的就是这两张表。再在函数体里加一次调用,
-- 是同一条规矩的第二次调用,行为一字不差,却多一处将来会分家的地方。
-- **所以这一刀只有一个执行点。** 代价说清楚:close_period 的拒绝发生在它算完
-- 试算平衡【之后】,人多等一会儿 —— 那不是正确性,是时序。
--
-- 唯一要改的函数是 reverse_payment:它必须【说出】自己在冲销。
-- 【用完立刻清掉】set_config(..., true) 是【事务】局部,不是语句局部 ——
-- 只设不清,同一事务里后面任何一笔直连 INSERT 都会畅通无阻(APR-2c fu2 实测过)。
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reverse_payment(p_payment_id uuid, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        payments%ROWTYPE;
    v_mirror_id   uuid := gen_random_uuid();
    v_mirror_code text;
    v_je          jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_orig FROM payments WHERE id = p_payment_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_NOT_FOUND|%', p_payment_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_payment IS NOT NULL THEN
        RAISE EXCEPTION 'PAYMENT_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, CURRENT_DATE, 'Payment reversal ' || v_orig.code);

    -- 镜像收付款单(现金退回),挂冲销分录,不带核销行
    v_mirror_code := fin_next_payment_code(CASE WHEN v_orig.direction = 'in' THEN 'RCPT' ELSE 'PMT' END, CURRENT_DATE);

    -- SOD-1:告诉 guard_payment_sod 这是一次【冲销】,不是一次付款。
    PERFORM set_config('evoltrya.payment_reversal_ctx', '1', true);
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          amount_ccy, currency, fx_rate, amount_base, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, v_orig.direction, v_orig.counterparty_type,
            v_orig.customer_id, v_orig.supplier_id,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_base,
            v_orig.bank_account_code, CURRENT_DATE,
            'REVERSAL: ' || v_orig.code || COALESCE(' — ' || p_memo, ''),
            (v_je->>'reversal_id')::uuid, auth.uid());
    -- 【立刻清掉】—— 事务局部,不清就一直开着。
    PERFORM set_config('evoltrya.payment_reversal_ctx', '', true);

    UPDATE payments
    SET status = 'reversed', reversed_by_payment = v_mirror_id
    WHERE id = p_payment_id;

    RETURN jsonb_build_object(
        'reversal_payment_id', v_mirror_id,
        'code', v_mirror_code,
        'journal_code', v_je->>'code'
    );
END;
$function$;

COMMIT;
