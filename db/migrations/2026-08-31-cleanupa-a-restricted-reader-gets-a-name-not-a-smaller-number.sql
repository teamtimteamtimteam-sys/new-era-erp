-- CLEANUP-A(2026-08-31):看不见的人必须被【告知】,而不是拿到一个更小的数字。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本刀的判据 —— 它纠正了委托书里的一条,而那一条会让修复原样复发】
--
-- 委托书说:这一族的解法按【返回类型】分岔 —— 有返回值的返回 NULL,
-- RETURNS void 的改成 RAISE。**返回类型是错的判据。** 本刀六个对象里
-- 【一个 void 都没有】,而其中三个照那条规矩改,会把缺陷原样装回去。
--
-- ★【正确的判据:这支函数的 NULL 是不是【已经有主】了?】★
--   NULL 已经有主,意思是它已经在表达一个【合法状态】:
--     · inbound_batch_landed_unit_cost → NULL 是「这批货真的没有金额」,
--       而 inbound_batch_valuation.unpriced 就【定义为】landed_unit_cost IS NULL;
--     · resolve_review_reviewer      → NULL 是「解析不出评估人」,
--       hr_alerts 的 review_no_reviewer 一支专门等着它;
--     · previewLeaveDays(前端)      → null 是「两头日期还没填全」,
--       LeaveForm 把它印成「—」。
--   对这三个,让"无权限"也返回 NULL,等于**把拒绝伪装成一个合法答案** ——
--   它会渲染成那个合法状态,于是没有任何人、任何时候会看见它。
--   **这与"返回 0"是同一个缺陷,只是换了一件衣服。所以它们必须 RAISE。**
--
--   NULL 没有主的(bank_book_balance_asof、attendance_unpaid_days —— 两支都
--   COALESCE(…, 0),今天根本产生不出 NULL),NULL 才是可用的"受限"信号。
--
-- 【为什么把它写在这里而不是只写在提交信息里】这条判据已经在一份委托书里
-- 被写错过一次,而写错的方式是"看起来对"。它现在也写进 AGENTS.md。
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【实测的错数字 —— 每一个都是拿真角色跑出来的,不是推出来的】
--   bank_book_balance_asof('1010')   finance −29,753.70 → operations 0.00
--   bank_reconciliation_status       同上,而且它给出【两行假零】,不是空列表
--   attendance_unpaid_days           hr 2.00 → operations 0(= 多发一天工资)
--   resolve_review_reviewer          hr 得到经理 → operations NULL
--   inbound_batch_landed_unit_cost   今天靠"没授权给 authenticated"活着
--
-- 【委托书里另外四条前提,实测不成立,一并记下】
--   · 无薪假是 2.00 天不是 3.00 —— 8/10–8/12 跨了一个周末;
--   · sale_settlement_compute 的盲区【今天复现不了】:它早就有按名拒绝的闸,
--     且线上 contract_document_terms 零行、4 张化验单全在进料侧。本刀仍然补上
--     第二道闸,理由是【角色改一次就会重新打开它】,不是"线上现在错着";
--   · resolve_review_reviewer 今天对谁都返回 NULL —— 全库一个部门、没有经理,
--     与权限无关;
--   · 认不到人的授权是 21 条,不是 11 条。
--
-- 【一条实测出来的镜像失败,它决定了两个白名单】
--   leave_requests 有一条 "select own rows" 策略,于是**一个零权限的员工今天
--   正确地读到自己的 2.00 天**。若把白名单只写成 module.hr.view,这条合法的路
--   会被本刀新打断 —— 那正是 R2 说的反方向失败。所以白名单带 OR 本人。
--   (而每一个持 *.edit 的角色是否也持对应的 *.view,是【查过的】不是假设的:
--    admin/gm/hr 三个 hr.edit 持有者全都持 hr.view,所以两个 DEFINER 调用方
--    open_review_cycle / open_probation_review / complete_attendance_period
--    一个都不会被新的判据拦住。)
--
-- 【白名单,逐角色】见 docs/permission-blindness-cleanup.md 的表。
--
-- NOTE: 本迁移不改任何表结构,只改函数与视图,外加删掉 21 行认不到人的授权。

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 一 · inbound_batch_landed_unit_cost —— R3:授权不是控制
-- ════════════════════════════════════════════════════════════════════════════
-- 【今天它为什么"安全"】它是 SECURITY DEFINER、直接读 inbound_batches.unit_price、
-- 绕过价格遮蔽,而且【自己不问调用者是谁】。今天没有人能调它,唯一的理由是
-- zzz_function_grants.sql 把 EXECUTE 从 authenticated 收走了。
-- **那是一条授权,不是一道检查。** 授权是可以被下一支迁移顺手加回来的,
-- 而检查不会。R3 要的就是这件事。
--
-- 【白名单:data.view_prices OR module.stocktakes.edit,逐条有理由】
--   · data.view_prices —— 落地单位成本【就是一个价格】。这是主判据。
--   · module.stocktakes.edit —— post_stocktake 与注销触发器要用这个数【算钱】,
--     而它算出来的数不给操作员看,是过账进总账的。**实测:持 stocktakes.edit 的
--     四个角色里,operations 与 warehouse 都【没有】data.view_prices** ——
--     只写第一条,盘点与注销当场对这两个角色坏掉,而它们正是真的在做盘点的人。
--     这就是 R2 的"太窄"那一半,量出来的,不是想出来的。
--   · 【为什么不加 module.inventory.view】加了它,价格遮蔽就等于没有:
--     一个只有 inventory.view 的读者会拿到原始价格。遮蔽住在
--     inbound_batch_valuation_rows 里是对的,本支不该把它拆掉。
--
-- 【为什么是 RAISE 而不是 NULL】见抬头:NULL 在这支函数里【已经有主】——
-- 它是"这批货真的没有金额",而 inbound_batch_valuation.unpriced 就定义为
-- landed_unit_cost IS NULL。让无权限也返回 NULL,屏幕上会显示【每一批货都没有价】,
-- 而那是一句会被信的假话。
CREATE OR REPLACE FUNCTION public.inbound_batch_landed_unit_cost(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cost numeric;
BEGIN
    IF NOT (has_permission('data.view_prices'::text)
            OR has_permission('module.stocktakes.edit'::text)) THEN
        RAISE EXCEPTION 'LANDED_COST_PERMISSION_DENIED|%', 'data.view_prices'
          USING HINT = '落地单位成本【是一个价格】—— 要看它得有 data.view_prices,'
                       '或者正走在盘点/注销那条路上(module.stocktakes.edit)。'
                       '这不是"这批货没有金额",是权限:两者在这支函数里必须分得开。';
    END IF;

    -- ── 以下算术一个字未动(PROC-COST-1/2 的口径)──────────────────────────
    -- 【分母是 quantity】与 allocate_processing_costs 材料成本表达式逐字相同,
    -- 于是消耗与注销互补、净得零。
    -- 【读的是 _all 那一对,不是带判据的那一对】计值不许取决于谁按的按钮。
    -- 【什么时候是 NULL】采购价没定过【而且】两项资本化都为零 —— 那是一批
    -- 真正"没有金额"的货。**这就是本支的 NULL 已经有主的意思。**
    SELECT CASE
        WHEN ib.unit_price IS NULL
         AND batch_freight_base_all(ib.id) + batch_processing_cost_base_all(ib.id) = 0
        THEN NULL
        ELSE COALESCE(ib.unit_price, 0)
             + CASE WHEN ib.quantity > 0
                    THEN (batch_freight_base_all(ib.id)
                          + batch_processing_cost_base_all(ib.id)) / ib.quantity
                    ELSE 0 END
    END
    INTO v_cost
    FROM inbound_batches ib
    WHERE ib.id = p_inbound_batch_id;

    RETURN v_cost;
END
$function$;

COMMENT ON FUNCTION public.inbound_batch_landed_unit_cost(uuid) IS
    'CLEANUP-A:落地单位成本 = 采购价 + 运费 + 已资本化加工成本。【自带权限判据】'
    'data.view_prices OR module.stocktakes.edit —— 后者是因为 post_stocktake 与注销'
    '触发器要拿它算过账的钱,而实测持 stocktakes.edit 的 operations / warehouse 都没有'
    'data.view_prices(R2 的"太窄"那一半)。【拒绝用 RAISE 不用 NULL】本支的 NULL 已经'
    '有主:它是"这批货真的没有金额",inbound_batch_valuation.unpriced 就定义为它 IS NULL;'
    '让无权限也返回 NULL,屏幕会说"每一批都没有价"。R3:此前它的安全性只靠"没授权给'
    'authenticated",而授权不是控制。';

-- ── companion:【有没有价】是事实,不是价 ───────────────────────────────────
-- 【为什么要有它】上面那支现在会拒绝一个只有 module.inventory.view 的读者,
-- 而 inbound_batch_valuation 的 unpriced 一列【本来就该给这种读者看】——
-- INV-VAL-1 明写着"有没有价是事实,不是价,所以不遮蔽"。
-- 从前那句话成立,靠的是"那支函数恰好不拒绝任何人";现在它拒绝了,
-- 于是那句话需要一个自己的入口才能继续成立。**这支函数就是把那句话变成可执行的。**
-- 它只回答布尔,不透出任何金额,所以 module.inventory.view 是够的。
CREATE OR REPLACE FUNCTION public.inbound_batch_has_landed_cost(p_inbound_batch_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_has boolean;
BEGIN
    IF NOT has_permission('module.inventory.view'::text) THEN
        RAISE EXCEPTION 'LANDED_COST_FACT_PERMISSION_DENIED|%', 'module.inventory.view'
          USING HINT = '"这批货有没有价"是一条库存事实 —— 要有库存模块的查看权限。'
                       '它不透出金额,所以不要 data.view_prices。';
    END IF;

    -- 与 inbound_batch_landed_unit_cost 的 NULL 判据【逐字互补】:
    -- has_landed_cost = NOT (landed_unit_cost IS NULL)。两处若漂开,unpriced 就会说谎。
    SELECT NOT (ib.unit_price IS NULL
                AND batch_freight_base_all(ib.id) + batch_processing_cost_base_all(ib.id) = 0)
      INTO v_has
      FROM inbound_batches ib
     WHERE ib.id = p_inbound_batch_id;

    RETURN v_has;
END
$function$;

COMMENT ON FUNCTION public.inbound_batch_has_landed_cost(uuid) IS
    'CLEANUP-A:「这批进料有没有落地成本」—— 一条布尔事实,不透出金额,判据 module.inventory.view。'
    '存在的理由:inbound_batch_landed_unit_cost 现在会拒绝没有 data.view_prices 的读者,'
    '而 inbound_batch_valuation.unpriced 这一列本来就该给这种读者看(INV-VAL-1:'
    '"有没有价是事实,不是价")。判据与那支函数的 NULL 条件逐字互补,漂开则 unpriced 说谎。';

-- ── 取数体改用 companion 算 unpriced ──────────────────────────────────────
-- 【只改了一处】第三次调用(unpriced 那一列)从"调价格函数再判 IS NULL"
-- 改成"问那条布尔事实"。前两次调用仍在 v_prices 分支里,遮蔽逻辑一个字没动。
CREATE OR REPLACE FUNCTION public.inbound_batch_valuation_rows()
 RETURNS TABLE(id uuid, code text, material_id uuid, supplier_id uuid, unit text, quantity numeric, remaining_qty numeric, arrival_date date, stage text, landed_unit_cost numeric, landed_value_base numeric, unpriced boolean, aging_days integer, aging_bucket text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_prices boolean;
BEGIN
    -- 【definer 必须自己问调用者是谁】—— 授权不是控制。
    PERFORM require_permission('module.inventory.view');
    v_prices := has_permission('data.view_prices');

    RETURN QUERY
    SELECT ib.id, ib.code, ib.material_id, ib.supplier_id, ib.unit,
           ib.quantity, ib.remaining_qty, ib.arrival_date, ib.stage,
           -- 价格遮蔽:没有 data.view_prices 的读者得 NULL,【不是 0】
           CASE WHEN v_prices THEN inbound_batch_landed_unit_cost(ib.id)
                ELSE NULL::numeric END,
           CASE WHEN v_prices
                THEN round(COALESCE(ib.remaining_qty * inbound_batch_landed_unit_cost(ib.id), 0), 2)
                ELSE NULL::numeric END,
           -- 【不遮蔽】有没有价是事实,不是价 —— CLEANUP-A 起走那条布尔事实,
           -- 因为价格函数现在会拒绝没有 data.view_prices 的读者。
           NOT inbound_batch_has_landed_cost(ib.id),
           (CURRENT_DATE - ib.arrival_date)::integer,
           aging_bucket((CURRENT_DATE - ib.arrival_date)::integer)
      FROM inbound_batches ib
     WHERE ib.deleted_at IS NULL;
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 二 · bank_book_balance_asof —— 实测 −29,753.70 → 0.00
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么它会错】它是 invoker,读 journal_activity_lines,而 journal_lines /
-- journal_entries 的 SELECT 策略是 has_permission('module.finance.view')。
-- 读不到行 → sum() 得 NULL → COALESCE(…, 0) → **0.00**。
-- 一个没有财务查看权的人问"1010 账上有多少钱",系统回答"零",而真值是 −29,753.70。
--
-- 【NULL 在这支函数里没有主,所以 NULL 就是"受限"】今天它【产生不出】NULL
-- (COALESCE 兜底),于是 NULL 是一个空着的、可以用来表达"我不能回答你"的值。
-- 这与第一节那支函数的分岔正在这里:那一支的 NULL 有主,这一支没有。
--
-- 【白名单:module.finance.view,只此一条】
--   · module.finance.view —— 它与两张底表的 RLS 策略【逐字相同】。判据与策略
--     一致,是本支【保持 SECURITY INVOKER】的理由:不需要属主权限去读任何
--     合法读者读不到的东西,那就不要拿。(PROC-COST-1 fu2 那一族用 DEFINER,
--     是因为它们的判据比 RLS 宽 —— 形状不同,不要照抄。)
--   · 【为什么不加 module.finance.edit】没有任何角色持 edit 而不持 view(查过)。
--     加上它只会让白名单看起来更周全,而不改变任何一个人的可见性 —— 那是 R2
--     说的"太宽的检查是戏"。
CREATE OR REPLACE FUNCTION public.bank_book_balance_asof(p_account_code text, p_as_of date)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
    -- 【判据在最外层,而不是塞进 WHERE】塞进 WHERE 会让"无权限"重新变成
    -- "零行",于是又是 COALESCE(…, 0) → 0.00,原样复发。
    -- 外层 CASE 没有 ELSE:不满足判据时整支函数是 NULL,而不是一个数。
    SELECT CASE WHEN has_permission('module.finance.view'::text) THEN (
        SELECT round(COALESCE(sum(
                   CASE WHEN jl.debit > 0 THEN jl.amount_ccy ELSE -jl.amount_ccy END
               ), 0), 2)
        FROM journal_activity_lines(NULL, p_as_of, true) act
        JOIN journal_lines jl ON jl.id = act.line_id
        WHERE act.account_code = p_account_code
          AND jl.currency = bank_native_currency(p_account_code)
    ) END;
$function$;

COMMENT ON FUNCTION public.bank_book_balance_asof(text, date) IS
    'CLEANUP-A:某银行科目截至某日的账面原币净额。【自带 module.finance.view 判据,'
    '无权限返回 NULL 而不是 0.00】实测:finance 读者得 −29,753.70,operations 读者从前得 0.00 —— '
    '一个不报错、只是更小的数字。NULL 在本支没有主(从前 COALESCE 兜底,产生不出 NULL),'
    '所以 NULL 可以用来表达"受限"。保持 SECURITY INVOKER:判据与 journal_lines / '
    'journal_entries 的 RLS 策略逐字相同,不需要属主权限。';

-- ════════════════════════════════════════════════════════════════════════════
-- 三 · attendance_unpaid_days —— 实测 2.00 → 0,而它的后果是【多发工资】
-- ════════════════════════════════════════════════════════════════════════════
-- ★【旧行为的后果,一句话】★ 这个数是工资的【扣减项】。读成 0 = 无薪假一天都没请
-- = **那个月的工资照全额发出去**。不是一张看错的报表,是一笔付错的钱,
-- 而且付出去之后没有任何东西会响。
--
-- 【NULL 没有主,所以 NULL 就是"受限"】(与 bank_book_balance_asof 同一形状)
--
-- 【白名单:module.hr.view OR 本人,逐条有理由】
--   · module.hr.view —— leave_requests 的第一条 SELECT 策略。
--   · **OR 本人** —— leave_requests 还有第二条策略 "select own rows"
--     (employee_id = current_user_employee())。**实测:一个零权限的员工今天
--     正确地读到自己的 2.00 天。** 只写 module.hr.view 会把这条合法的路
--     【新打断】—— 那就是 R2 说的反方向失败:一个拦住合法业务的火警。
--     这一条是量出来的,不是想出来的。
--   · 【complete_attendance_period 会不会被拦】不会,而这是【查过的】:
--     它 require module.hr.edit,而 admin / gm / hr 三个 hr.edit 持有者
--     全都持有 module.hr.view。
CREATE OR REPLACE FUNCTION public.attendance_unpaid_days(p_employee_id uuid, p_month date)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN has_permission('module.hr.view'::text)
                  OR p_employee_id = current_user_employee() THEN (
        SELECT COALESCE(round(sum(
            calculate_leave_days(
                GREATEST(lr.start_date, date_trunc('month', p_month)::date),
                LEAST(lr.end_date, (date_trunc('month', p_month) + interval '1 month - 1 day')::date),
                -- 只有裁剪之后仍然是原端点时,半天标记才成立
                lr.start_half_day AND lr.start_date >= date_trunc('month', p_month)::date,
                lr.end_half_day   AND lr.end_date   <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
            )), 2), 0)
          FROM leave_requests lr
         WHERE lr.employee_id = p_employee_id
           AND lr.leave_type_code = 'unpaid'
           AND lr.status = 'approved'
           AND lr.deleted_at IS NULL
           AND lr.start_date <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
           AND lr.end_date   >= date_trunc('month', p_month)::date
    ) END;
$function$;

COMMENT ON FUNCTION public.attendance_unpaid_days(uuid, date) IS
    'CLEANUP-A:某员工某月的无薪假天数。【自带判据 module.hr.view OR 本人,无权限返回 NULL 不是 0】'
    '★旧行为的后果是【多发工资】★ —— 这个数是工资的扣减项,读成 0 就等于那个月全额发出去,'
    '而且不会有任何东西报错。实测 hr 读者 2.00 / operations 读者 0。判据里的"OR 本人"不是'
    '客气:leave_requests 有一条 select own rows 策略,实测一个零权限员工今天正确读到自己的 2.00,'
    '只写 module.hr.view 会新打断这条合法的路(R2 的反方向失败)。';

-- ════════════════════════════════════════════════════════════════════════════
-- 四 · resolve_review_reviewer —— NULL 已经有主,所以只能 RAISE
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么不能返回 NULL】本支的 NULL 是【一句有内容的话】:"解析不出评估人",
-- 而 hr_alerts 的 review_no_reviewer 一支专门等着它。让无权限也返回 NULL,
-- 那条告警就会对一个【其实有经理的人】响,而真正的原因(读的人没有 HR 权限)
-- 永远不会出现在任何屏幕上。**这就是"把拒绝伪装成合法答案"。**
--
-- 【本支今天为什么对谁都返回 NULL —— 与权限无关】全库只有一个部门,而且它
-- 没有经理。所以委托书里"一个 uuid → NULL"那条实测,是构造出来的,不是线上的。
-- 记在这里,免得后来的人把线上的 NULL 读成本刀没修好。
--
-- 【白名单:module.hr.view,只此一条】
--   · module.hr.view —— departments 的 SELECT 策略就是它(employees 另有一条
--     "select own row",但只有 employees 那一半;三级解析必须读 departments)。
--   · 【本人读自己】拿到的是【按名拒绝】,不是 NULL。从前他拿到 NULL ——
--     一个**错误答案**;现在拿到一句**说明**。R1 要的正是这个方向,
--     所以这不是丢了一个功能。
--   · 【两个 DEFINER 调用方不会被拦】open_review_cycle / open_probation_review
--     都 require module.hr.edit,而三个 hr.edit 持有者全持 hr.view(查过)。
CREATE OR REPLACE FUNCTION public.resolve_review_reviewer(p_employee_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_reviewer uuid;
BEGIN
    IF NOT has_permission('module.hr.view'::text) THEN
        RAISE EXCEPTION 'REVIEWER_RESOLUTION_PERMISSION_DENIED|%', 'module.hr.view'
          USING HINT = '「谁评估这个人」要读部门与上级部门 —— 那要 HR 模块的查看权限。'
                       '这【不是】"解析不出评估人"(那件事本支用 NULL 表示,'
                       'hr_alerts 的 review_no_reviewer 专门等着它),所以不能返回 NULL。';
    END IF;

    -- 【三级解析】部门经理 → 本人就是部门经理时取【上级部门】的经理 → 再不行 NULL。
    -- 每一级都排除"解析到本人":自己不能评自己。
    -- NULL 【不是】被忽略 —— hr_alerts 的 review_no_reviewer 一支会把它顶出来。
    SELECT COALESCE(
               NULLIF(d.manager_employee_id, e.id),
               NULLIF(pd.manager_employee_id, e.id)
           )
      INTO v_reviewer
      FROM employees e
      LEFT JOIN departments d  ON d.id = e.department_id
      LEFT JOIN departments pd ON pd.id = d.parent_department_id
     WHERE e.id = p_employee_id;

    RETURN v_reviewer;
END
$function$;

COMMENT ON FUNCTION public.resolve_review_reviewer(uuid) IS
    'CLEANUP-A:「谁评估这个人」的唯一一处定义 —— 部门经理 → 上级部门经理 → NULL,每一级排除本人。'
    '两个调用方:open_review_cycle 与 open_probation_review。【无权限时 RAISE,不返回 NULL】'
    '因为本支的 NULL 已经有主:它是"解析不出评估人",hr_alerts 的 review_no_reviewer 专门等着它;'
    '让无权限也返回 NULL,那条告警会对一个其实有经理的人响,而真正的原因永远不上屏。'
    '判据 module.hr.view(departments 的 SELECT 策略)。本人读自己现在得到按名拒绝而不是 NULL —— '
    '从错误答案换成一句说明,是 R1 被满足,不是丢了功能。';

-- ════════════════════════════════════════════════════════════════════════════
-- 五 · sale_settlement_compute —— 闸问的和身体读的不是同一条权限
-- ════════════════════════════════════════════════════════════════════════════
-- (整支函数逐字重贴,唯一的改动是权限检查那里多了第二道闸;理由写在那一段。)
CREATE OR REPLACE FUNCTION public.sale_settlement_compute(p_sales_order_id uuid, p_output_batch_id uuid, p_assay_result_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- SETTLE-1:一次销售最终结算的**算法** —— 四条条款是**同一条公式**里的四项。
--
-- ★★【一处实现,两个调用者】★★ 本支只**算**,不写;record_sale_settlement 调它
--   再落一行。本仓库为"两份实现在写下来那天一致、之后悄悄分开"付过**四次**账
--   (AGENTS.md 那条预览规则),所以预览与落库读的是同一段算术。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【公式(index-pricing-spec §3),四条条款各占一项】
--     (结算重量 × 含量 × 计价系数) × 计价期均价      ← 重量基准 / PRICE-1 的条款
--   − 精炼费(按【含金属】吨数)                       ← contract_refining_charges
--   − 惩罚(按【结算重量】吨数,超阈值部分)           ← contract_penalty_elements
--   而"用谁的化验"决定了上面的**含量**从哪一行来       ← result_party / settling_party
--
-- ★★【为什么湿基与干基结算出【不同的钱】】★★
--   含金属是**不变量**(换算对了的话,湿基算与干基算得到同一个含量),
--   所以**金属价值与精炼费不随基准变**。变的是**惩罚** ——
--   它按**结算重量**收,而水是随货一起进来的。
--   于是同一批货按湿基结算比按干基**多罚**,而那是对的。
--   **这也正是 GO-3 那个"钱的错误"之所以是钱的错误。**
--
-- 拒绝(全部按名,全部双语):
--   SETTLEMENT_PERMISSION_DENIED|<code>        没有权限(而不是让 RLS 报成"数据缺了")
--   SO_NOT_FOUND / OUTPUT_BATCH_NOT_FOUND / ASSAY_NOT_FOUND
--   SETTLEMENT_NO_CONTRACT_TERMS|<so>          这张单没挂合同,没有可依据的冻结条款
--   SETTLEMENT_TERMS_NOT_SET|<contract>        挂了合同,但那份合同没有结算口径
--   ASSAY_NOT_FOR_BATCH|<assay>|<batch>        选的化验不是这个批次的
--   ★ ASSAY_WEIGHT_BASIS_NOT_STATED|<assay>    化验没说按哪种重量报 ← 本刀最要紧的那条
--   ASSAY_PARTY_NOT_THE_SETTLING_PARTY|…       选的化验不是合同约定的那一方(仲裁除外)
--   RESULTS_IN_DISPUTE|…                       两方结果不一致,而没有声明容差
--   RESULTS_EXCEED_SPLITTING_LIMIT|…           不一致超过了声明的容差 → 该走仲裁
--   SETTLEMENT_MOISTURE_NOT_STATED|<assay>     要换算基准却没有水分
--   SETTLEMENT_PAYABLE_NOT_STATED|<metal>      没有计价系数(PRICE-1 的条款)
--   SETTLEMENT_BASE_EVENT_DATE_UNKNOWN|<event> 基准事件的日期在卖方向还记不下来
--   REFINING_CHARGE_NOT_FILED|<contract>|<metal>   声明了按金属收,却没填那一行
--   PENALTY_ELEMENTS_NOT_FILED|<contract>          声明了按元素罚,却一行都没填
DECLARE
    v_st        jsonb;     -- 冻结的结算口径
    v_pricing   jsonb;     -- 冻结的计价条款(PRICE-1)
    v_terms     record;
    v_batch     record;
    v_assay     record;
    v_basis     text;
    v_gross     numeric;
    v_moist     numeric;
    v_swt       numeric;   -- 结算重量
    v_other     record;
    v_lim       numeric;
    v_maxdiff   numeric;
    v_el        jsonb;
    v_ccode     text;
    v_pt_event  text;
    v_pt_months integer;
    v_pt_index  text;
    v_metal     text;
    v_content   numeric;
    v_content_s numeric;
    v_contained numeric;
    v_payable   numeric;
    v_pay_kg    numeric;
    v_price     numeric;
    v_qp        record;
    v_rc        numeric;
    v_base_date date;
    v_lines     jsonb := '[]'::jsonb;
    v_pens      jsonb := '[]'::jsonb;
    v_mv        numeric := 0;
    v_rcs       numeric := 0;
    v_pen       numeric := 0;
    v_thr       numeric;
    v_rate      numeric;
    v_over      numeric;
    v_amt       numeric;
BEGIN
    IF p_sales_order_id IS NULL OR p_output_batch_id IS NULL OR p_assay_result_id IS NULL THEN
        RAISE EXCEPTION 'SETTLEMENT_ARGUMENTS_REQUIRED';
    END IF;
    -- 【权限按名拒,不让 RLS 把行藏起来报成"数据缺了"】PRICE-1 的 fu1 是这一课,
    -- 这里一开始就写上,而不是等 fixture 再抓一次。
    IF NOT has_permission('module.customers.view'::text) THEN
        RAISE EXCEPTION 'SETTLEMENT_PERMISSION_DENIED|%', 'module.customers.view'
          USING HINT = '看得见销售结算要有客户模块的查看权限 —— 这不是数据缺失,是权限';
    END IF;
    -- ★【第二道闸(CLEANUP-A)—— 它今天【拦不到任何人】,而那正是它的理由】★
    -- 上面那道闸问的是 module.customers.view,而本支接下来要读的是
    -- output_batches / assay_results / assay_result_metals —— 这三张的 RLS
    -- 策略问的都是 module.output.view。**闸问的和身体读的不是同一条权限。**
    -- 本支是 SECURITY INVOKER,所以一个只有 customers.view 的读者会走过第一道闸,
    -- 然后【读到零行化验金属】,而金属循环一次都不执行 → metal_value = 0、
    -- refining_charge = 0 → **amount_usd 结算成 0.00,附一张空的 breakdown**。
    -- 那是一个不报错的、可以被当成"这批货不值钱"的数字。
    --
    -- 【实测:今天线上没有任何角色能走到那一步,而这不是不修的理由】
    -- 持 customers.view 的五个角色(admin/auditor/finance/gm/sales)【全部】
    -- 也持 output.view,所以今天这条路复现不了;线上 contract_document_terms
    -- 还是零行,4 张化验单全在进料侧,函数在金属循环之前就按名拒了。
    -- **但这道闸关的不是"现在错着",是"角色改一次就会无声地重新打开它"** ——
    -- 而重新打开的那一天,没有任何东西会响。所以它现在就该在这里。
    -- 【fixture 会构造一个只有 customers.view 的读者来钉住它;那不是线上缺陷的证据。】
    IF NOT has_permission('module.output.view'::text) THEN
        RAISE EXCEPTION 'SETTLEMENT_PERMISSION_DENIED|%', 'module.output.view'
          USING HINT = '结算要读产出批次与它的化验结果 —— 那要产出模块的查看权限。'
                       '没有它,化验金属会读成零行,而结算金额会算成 0.00:'
                       '一个不报错、看起来像"这批货不值钱"的数字。';
    END IF;

    -- ── 冻结的条款副本(【抄】,不回查合同现在怎么写)────────────────────────
    SELECT * INTO v_terms FROM contract_document_terms WHERE sales_order_id = p_sales_order_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SETTLEMENT_NO_CONTRACT_TERMS|%', p_sales_order_id
          USING HINT = '这张销售单没有挂在任何合同之下 —— 结算口径是合同条款,没有合同就没有口径';
    END IF;
    v_st := v_terms.settlement_terms;
    v_pricing := v_terms.pricing_terms;
    v_ccode := v_terms.contract_code;
    IF v_st IS NULL OR jsonb_typeof(v_st) <> 'object' OR v_st = '{}'::jsonb THEN
        RAISE EXCEPTION 'SETTLEMENT_TERMS_NOT_SET|%', v_ccode
          USING HINT = '这份合同没有结算口径(重量基准 / 谁的化验说了算 / 精炼费与惩罚的口径)—— 先在合同上写明,再重新挂接';
    END IF;

    SELECT * INTO v_batch FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'OUTPUT_BATCH_NOT_FOUND|%', p_output_batch_id; END IF;
    SELECT * INTO v_assay FROM assay_results WHERE id = p_assay_result_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', p_assay_result_id; END IF;
    IF v_assay.output_batch_id IS DISTINCT FROM p_output_batch_id THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOR_BATCH|%|%', v_assay.code, v_batch.code;
    END IF;

    -- ── ★ 化验必须说出它按哪种重量报 ★ ─────────────────────────────────────
    -- GO-3:一张按干基出的化验单被乘在湿重上,含金属被**高估**,而没有任何东西会响。
    -- **留空 = 没有人说过**,而不是"按惯例是干基" —— 所以这里拒,不猜。
    IF v_assay.weight_basis IS NULL THEN
        RAISE EXCEPTION 'ASSAY_WEIGHT_BASIS_NOT_STATED|%', v_assay.code
          USING HINT = '这份化验没有说明它按湿基还是干基报 —— 而两者会结算出不同的金额,所以不能猜';
    END IF;

    -- ── 谁的化验说了算 ────────────────────────────────────────────────────
    -- 仲裁结果【总是】可以结算:它是那条升级路径的终点。
    IF v_assay.result_party <> 'umpire'
       AND v_assay.result_party IS DISTINCT FROM (v_st->>'settling_party') THEN
        RAISE EXCEPTION 'ASSAY_PARTY_NOT_THE_SETTLING_PARTY|%|%|%',
            v_assay.code, v_assay.result_party, (v_st->>'settling_party');
    END IF;

    -- ── 两方结果不一致时,【系统不自己选】────────────────────────────────
    -- ★ 让系统按容差自动选,等于让系统**决定谁的数字是钱**;而容差为空时,
    --   它还得**编一个默认值**才做得到那件事。所以:指出,不选。
    IF v_assay.result_party <> 'umpire' THEN
        SELECT a.code, a.id INTO v_other
          FROM assay_results a
         WHERE a.output_batch_id = p_output_batch_id AND a.deleted_at IS NULL
           AND a.id <> p_assay_result_id
           AND a.result_party IN ('ours', 'counterparty')
           AND a.result_party <> v_assay.result_party
         ORDER BY a.assay_date DESC LIMIT 1;
        IF FOUND THEN
            v_lim := (v_st->>'splitting_limit_pct')::numeric;
            -- 逐元素比,取最大差
            SELECT max(abs(x.content_pct - y.content_pct)) INTO v_maxdiff
              FROM assay_result_metals x JOIN assay_result_metals y
                ON y.metal = x.metal AND y.assay_result_id = v_other.id
             WHERE x.assay_result_id = p_assay_result_id;
            IF v_maxdiff IS NOT NULL AND v_maxdiff > 0 THEN
                IF v_lim IS NULL THEN
                    RAISE EXCEPTION 'RESULTS_IN_DISPUTE|%|%|%', v_assay.code, v_other.code, v_maxdiff
                      USING HINT = '两方的化验结果不一致,而这份合同没有声明容差 —— 要么在合同里写明容差,要么记录一份仲裁结果并按它结算;系统不会替你选哪一方的数字是钱';
                ELSIF v_maxdiff > v_lim THEN
                    RAISE EXCEPTION 'RESULTS_EXCEED_SPLITTING_LIMIT|%|%|%|%', v_assay.code, v_other.code, v_maxdiff, v_lim
                      USING HINT = '两方结果的差距超过了合同声明的容差 —— 按合同该送第三方复检,并用仲裁结果结算';
                END IF;
            END IF;
        END IF;
    END IF;

    -- ── 重量基准:换算,或按名拒 ──────────────────────────────────────────
    v_basis := v_st->>'sale_weight_basis';
    v_gross := v_batch.quantity;
    v_moist := v_assay.moisture_pct;
    IF v_assay.weight_basis <> v_basis AND v_moist IS NULL THEN
        RAISE EXCEPTION 'SETTLEMENT_MOISTURE_NOT_STATED|%', v_assay.code
          USING HINT = '化验按一种基准报、合同按另一种结算,换算要用水分 —— 而这份化验没有水分,所以算不了';
    END IF;
    v_swt := CASE WHEN v_basis = 'as_received' THEN v_gross
                  ELSE round(v_gross * (1 - COALESCE(v_moist, 0) / 100.0), 4) END;

    -- ── 逐金属:含量 → 应付量 → 计价期均价 → 金额;并扣精炼费 ────────────
    FOR v_metal, v_content IN
        SELECT m.metal, m.content_pct FROM assay_result_metals m
         WHERE m.assay_result_id = p_assay_result_id ORDER BY m.metal
    LOOP
        -- 把含量换算到【结算基准】上。含金属因此是不变量 —— 见抬头。
        v_content_s := CASE
            WHEN v_assay.weight_basis = v_basis THEN v_content
            WHEN v_assay.weight_basis = 'dry' AND v_basis = 'as_received'
                THEN v_content * (1 - v_moist / 100.0)
            ELSE v_content / (1 - v_moist / 100.0) END;
        v_contained := round(v_swt * v_content_s / 100.0, 4);

        SELECT (e->>'payable_pct')::numeric INTO v_payable
          FROM jsonb_array_elements(COALESCE(v_pricing, '[]'::jsonb)) e
         WHERE e->>'metal' = v_metal;
        IF v_payable IS NULL THEN
            RAISE EXCEPTION 'SETTLEMENT_PAYABLE_NOT_STATED|%', v_metal
              USING HINT = '计价系数是一条合同条款(PRICE-1 的 contract_pricing_terms)—— 没有它就不知道买方按含量的多大比例付钱';
        END IF;
        v_pay_kg := round(v_contained * v_payable / 100.0, 4);

        -- 计价期均价 —— **调 PRICE-1 那一支,不另写一份**(两份实现会悄悄分开)
        SELECT e->>'base_event', (e->>'qp_months')::int, e->>'index_code'
          INTO v_pt_event, v_pt_months, v_pt_index
          FROM jsonb_array_elements(v_pricing) e WHERE e->>'metal' = v_metal;
        -- 【卖方向今天只记得下"化验完成"这一个事件日期】发货日与到货日在这一侧
        -- 还没有落点,所以按它们定基准月的合同**按名拒**,而不是拿一个别的日期顶替。
        v_base_date := CASE WHEN v_pt_event = 'assay_complete' THEN v_assay.assay_date END;
        IF v_base_date IS NULL THEN
            RAISE EXCEPTION 'SETTLEMENT_BASE_EVENT_DATE_UNKNOWN|%', COALESCE(v_pt_event, '(none)')
              USING HINT = '卖方向今天记得下来的事件日期只有【化验完成】—— 发货日与到货日还没有落点,所以按它们定基准月的合同结算不了';
        END IF;
        SELECT qp.qp_from, qp.qp_to INTO v_qp FROM quotational_period(v_base_date, v_pt_months) qp;
        v_price := (index_period_average(v_pt_index, v_metal, v_qp.qp_from, v_qp.qp_to)
                    ->>'avg_usd_per_tonne')::numeric;
        v_mv := v_mv + round(v_pay_kg / 1000.0 * v_price, 2);

        -- 精炼费:按【含金属】吨数 —— 所以它**不随基准变**
        v_rc := 0;
        IF v_st->>'refining_charge_basis' = 'per_metal' THEN
            SELECT (e->>'usd_per_tonne_of_metal')::numeric INTO v_rc
              FROM jsonb_array_elements(COALESCE(v_st->'refining_charges', '[]'::jsonb)) e
             WHERE e->>'metal' = v_metal;
            IF v_rc IS NULL THEN
                RAISE EXCEPTION 'REFINING_CHARGE_NOT_FILED|%|%', v_ccode, v_metal
                  USING HINT = '这份合同声明了按金属收精炼费,却没有填这一种金属的费率 —— 【声明了有】与【填了多少】是两件事,而只有后者算得出钱';
            END IF;
            v_rcs := v_rcs + round(v_contained / 1000.0 * v_rc, 2);
        END IF;

        v_lines := v_lines || jsonb_build_object(
            'metal', v_metal, 'content_pct_assay', v_content,
            'content_pct_settlement', round(v_content_s, 6),
            'contained_kg', v_contained, 'payable_pct', v_payable,
            'payable_kg', v_pay_kg, 'price_usd_per_tonne', v_price,
            'qp_from', v_qp.qp_from, 'qp_to', v_qp.qp_to,
            'refining_charge_usd_per_tonne_of_metal', v_rc);
    END LOOP;

    -- ── 惩罚:按【结算重量】吨数 —— 所以它**随基准变** ────────────────────
    IF v_st->>'penalty_basis' = 'per_element' THEN
        IF COALESCE(jsonb_array_length(v_st->'penalty_elements'), 0) = 0 THEN
            RAISE EXCEPTION 'PENALTY_ELEMENTS_NOT_FILED|%', v_ccode
              USING HINT = '这份合同声明了按元素罚,却一条惩罚条款都没有填 —— 【声明了有】与【填了哪些】是两件事';
        END IF;
        FOR v_el IN SELECT e FROM jsonb_array_elements(v_st->'penalty_elements') e LOOP
            v_thr  := (v_el->>'threshold_pct')::numeric;
            v_rate := (v_el->>'usd_per_tonne_per_pct_over')::numeric;
            SELECT m.content_pct INTO v_content FROM assay_result_metals m
             WHERE m.assay_result_id = p_assay_result_id AND m.metal = v_el->>'substance';
            IF v_content IS NULL THEN CONTINUE; END IF;   -- 这份化验没测这个元素
            v_content_s := CASE
                WHEN v_assay.weight_basis = v_basis THEN v_content
                WHEN v_assay.weight_basis = 'dry' AND v_basis = 'as_received'
                    THEN v_content * (1 - v_moist / 100.0)
                ELSE v_content / (1 - v_moist / 100.0) END;
            v_over := v_content_s - v_thr;
            IF v_over > 0 THEN
                v_pen := v_pen + round(v_swt / 1000.0 * v_over * v_rate, 2);
                v_pens := v_pens || jsonb_build_object(
                    'substance', v_el->>'substance', 'threshold_pct', v_thr,
                    'content_pct_settlement', round(v_content_s, 6),
                    'pct_over', round(v_over, 6), 'rate', v_rate);
            END IF;
        END LOOP;
    END IF;

    v_amt := round(v_mv - v_rcs - v_pen, 2);
    RETURN jsonb_build_object(
        'sales_order_id', p_sales_order_id, 'output_batch_id', p_output_batch_id,
        'assay_result_id', p_assay_result_id, 'assay_code', v_assay.code,
        'settling_party_used', v_assay.result_party,
        'weight_basis_used', v_basis,
        'assay_weight_basis', v_assay.weight_basis,
        'gross_weight_kg', v_gross, 'moisture_pct', v_moist,
        'settlement_weight_kg', v_swt,
        'metal_value_usd', v_mv, 'refining_charge_usd', v_rcs,
        'penalty_usd', v_pen, 'amount_usd', v_amt,
        'breakdown', jsonb_build_object('metals', v_lines, 'penalties', v_pens),
        'terms_snapshot', v_st);
END
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 六 · journal_activity_lines 【上面那一层】 —— 本刀最坏的一处
-- ════════════════════════════════════════════════════════════════════════════
-- ★【函数本身是对的,改的是它上面那一层。被改的对象是 public.bank_reconciliation_status。】★
--   journal_activity_lines 自己带着一段解释,说明它"直接调用是安全的,靠的是 RLS":
--   它是 invoker,底表策略就是 module.finance.view,调它的人拿不到比 PostgREST
--   直查更多的东西。**那段话是对的,本刀一个字没动它。**
--
-- ★【为什么这一处比 R1 描述的形状还坏】★ R1 说的是"更小的数字"或"空列表"。
--   这张视图两样都不是 —— 它**照样返回两行**('1000' 与 '1010' 是 VALUES 里
--   硬写的),每一行的 ledger_balance 都是 **0.00**。实测:operations 读者拿到
--   两行,余额 0.00、未匹配净额 0.00,而真值是 −29,753.70。
--   **一个空列表还看得出"我什么都没拿到";两行假零看起来就是答案本身。**
--
-- ★【而且它会把上面第二节的修复原样吃掉】★ 旧视图写着
--   COALESCE(led.balance, 0::numeric)。bank_book_balance_asof 现在对无权限的
--   读者返回 NULL —— 而这个 COALESCE 会把那个 NULL **变回 0.00**。
--   **两处分开看都"修好了",合起来仍然说谎。** 所以 fixture 必须把
--   【修好的函数穿过修好的视图】一起钉住,而不是各钉各的。
--
-- 【视图不能 RAISE,所以照 INV-VAL-1-fu6 四天前的先例:壳 + DEFINER 取数体】
-- 取数体自己 require_permission,于是无权限的读者拿到的是**一句按名的拒绝**,
-- 不是两行零。
CREATE OR REPLACE FUNCTION public.bank_reconciliation_rows()
 RETURNS TABLE(account_code text, currency text, ledger_balance numeric,
               latest_statement_code text, latest_statement_period_end date,
               latest_closing_balance numeric, unmatched_statement_lines bigint,
               ignored_statement_lines bigint, unmatched_journal_lines bigint,
               unmatched_journal_amount numeric, difference numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【definer 必须自己问调用者是谁】—— 授权不是控制。
    PERFORM require_permission('module.finance.view');

    RETURN QUERY
    SELECT b.account_code,
        bank_native_currency(b.account_code),
        -- 【COALESCE(…, 0) 拿掉了,这是本节的要点之一】bank_book_balance_asof
        -- 对没有 finance.view 的读者返回 NULL,而那个 COALESCE 会把它变回 0.00。
        -- 现在:走到这里的人一定有 finance.view(上面那道闸),所以它不会是 NULL;
        -- 万一将来又是了,屏幕上会出现一个空格,而不是一个假的零。
        led.balance,
        ls.code, ls.period_end, ls.closing_balance,
        COALESCE(sl.unmatched, 0::bigint),
        COALESCE(sl.ignored, 0::bigint),
        COALESCE(jl.unmatched_count, 0::bigint),
        round(COALESCE(jl.unmatched_net, 0::numeric), 2),
        -- 未导入过报表时 difference 为 NULL —— 既有行为,一个字没松。
        round(led.balance - ls.closing_balance, 2)
       FROM ( VALUES ('1000'::text), ('1010'::text)) b(account_code)
         LEFT JOIN LATERAL ( SELECT bank_book_balance_asof(b.account_code, NULL::date) AS balance) led ON true
         LEFT JOIN LATERAL ( SELECT s.code, s.period_end, s.closing_balance
               FROM bank_statements s
              WHERE s.bank_account_code = b.account_code AND s.deleted_at IS NULL
              ORDER BY s.period_end DESC, s.created_at DESC
             LIMIT 1) ls ON true
         LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE l.match_status = 'unmatched'::text) AS unmatched,
                count(*) FILTER (WHERE l.match_status = 'ignored'::text) AS ignored
               FROM bank_statement_lines l
                 JOIN bank_statements s ON s.id = l.statement_id
              WHERE s.bank_account_code = b.account_code AND s.deleted_at IS NULL) sl ON true
         -- 【这条 lateral 的 posted 过滤【没有】跟着改,而那是对的】它数的是
         -- "工作台里还剩几条候选分录",候选资格由 match_bank_line 定义,而那支函数
         -- 对 reversed 分录的行直接抛 JL_ENTRY_REVERSED。这是"判断单张分录还活着没有",
         -- posted 就是它的正确判据 —— 见 journal_activity_lines 抬头那条判据。
         LEFT JOIN LATERAL ( SELECT count(*) AS unmatched_count,
                sum(CASE WHEN l.debit > 0::numeric THEN l.amount_ccy ELSE - l.amount_ccy END) AS unmatched_net
               FROM journal_lines l
                 JOIN accounts a ON a.id = l.account_id AND a.code = b.account_code
                 JOIN journal_entries e ON e.id = l.entry_id AND e.status = 'posted'::text
              WHERE l.currency = bank_native_currency(b.account_code) AND NOT (EXISTS ( SELECT 1
                       FROM bank_line_matches m
                      WHERE m.journal_line_id = l.id))) jl ON true;
END;
$function$;

COMMENT ON FUNCTION public.bank_reconciliation_rows() IS
    'CLEANUP-A:bank_reconciliation_status 的取数体。存在的理由:视图【不能 RAISE】,'
    '所以一张 security_invoker 视图对无权限读者只能给出更小的数字或空列表 —— 而这一张给的是'
    '**两行假零**(账户码是 VALUES 里硬写的,行不会消失),实测 operations 读者见 0.00 而真值 −29,753.70。'
    '照 INV-VAL-1-fu6 的先例改成壳 + DEFINER 取数体,取数体自己 require_permission('
    'module.finance.view),于是无权限得到按名拒绝。另:旧视图的 COALESCE(led.balance, 0) 会把'
    'bank_book_balance_asof 新返回的 NULL 变回 0.00 —— 两处分开看都"修好了",合起来仍然说谎,'
    '所以那个 COALESCE 在这里被拿掉。';

CREATE OR REPLACE VIEW public.bank_reconciliation_status
WITH (security_invoker = on) AS
 SELECT r.account_code, r.currency, r.ledger_balance,
        r.latest_statement_code, r.latest_statement_period_end, r.latest_closing_balance,
        r.unmatched_statement_lines, r.ignored_statement_lines,
        r.unmatched_journal_lines, r.unmatched_journal_amount, r.difference
   FROM bank_reconciliation_rows() r;

COMMENT ON VIEW public.bank_reconciliation_status IS
    '银行对账总览:每个银行账户一行。CLEANUP-A 起它只是 bank_reconciliation_rows() 的一层壳 —— '
    '视图不能 RAISE,而这张视图对无权限读者从前给出【两行假零】(比空列表更坏:空列表还看得出'
    '"我什么都没拿到")。取数体按 module.finance.view 按名拒绝。对账恒等式与两条 lateral 的语义'
    '一个字没动,见取数体里的注释。';

-- ── 同族的另一张:bank_reconciliation_record ────────────────────────────────
-- 【它不在委托书点名的六个里,做它的理由写在这里】它是上面那张的同胞,同样
-- security_invoker、同样消费 bank_book_balance_asof(而且拿它做减法:
-- book_balance_drift = 现在重算的 − 当时冻结的)。无权限读者今天拿到的是
-- **空列表** —— R1 明写着"NEVER AN EMPTY LIST"。修好一张、留下另一张,
-- 正是"两处分开看都好、合起来仍然说谎"的同一个形状,所以一起做。
CREATE OR REPLACE FUNCTION public.bank_reconciliation_record_rows()
 RETURNS TABLE(reconciliation_id uuid, statement_id uuid, statement_code text,
               bank_account_code text, period_start date, period_end date, currency text,
               bank_closing_balance numeric, book_balance numeric, difference numeric,
               matched_lines integer, ignored_lines integer,
               reconciled_at timestamptz, reconciled_by uuid,
               superseded_at timestamptz, superseded_reason text, is_current boolean,
               book_balance_now numeric, book_balance_drift numeric, variance_item_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');

    RETURN QUERY
    SELECT r.id, s.id, s.code, s.bank_account_code, s.period_start, s.period_end,
        r.currency, r.bank_closing_balance, r.book_balance, r.difference,
        r.matched_lines, r.ignored_lines, r.reconciled_at, r.reconciled_by,
        r.superseded_at, r.superseded_reason, r.superseded_at IS NULL,
        -- 【冻结的 vs 现在重算的,并排,谁也不替换谁】—— BANK-REC 的规矩,没动。
        bank_book_balance_asof(s.bank_account_code, s.period_end),
        round(bank_book_balance_asof(s.bank_account_code, s.period_end) - r.book_balance, 2),
        COALESCE(vi.item_count, 0::bigint)
       FROM bank_reconciliations r
         JOIN bank_statements s ON s.id = r.statement_id
         LEFT JOIN LATERAL ( SELECT count(*) AS item_count
               FROM bank_reconciliation_variance_items v
              WHERE v.reconciliation_id = r.id) vi ON true;
END;
$function$;

COMMENT ON FUNCTION public.bank_reconciliation_record_rows() IS
    'CLEANUP-A:bank_reconciliation_record 的取数体,判据 module.finance.view。'
    '它不在委托书点名的六个里 —— 一起做的理由:它是 bank_reconciliation_status 的同胞,'
    '同样消费 bank_book_balance_asof 并拿它做减法(book_balance_drift),而无权限读者从前拿到'
    '**空列表**,R1 明写着 NEVER AN EMPTY LIST。修一张留一张,就是"两处分开看都好、'
    '合起来仍然说谎"的同一个形状。';

CREATE OR REPLACE VIEW public.bank_reconciliation_record
WITH (security_invoker = on) AS
 SELECT r.reconciliation_id, r.statement_id, r.statement_code, r.bank_account_code,
        r.period_start, r.period_end, r.currency, r.bank_closing_balance, r.book_balance,
        r.difference, r.matched_lines, r.ignored_lines, r.reconciled_at, r.reconciled_by,
        r.superseded_at, r.superseded_reason, r.is_current, r.book_balance_now,
        r.book_balance_drift, r.variance_item_count
   FROM bank_reconciliation_record_rows() r;

COMMENT ON VIEW public.bank_reconciliation_record IS
    '每月的对账记录 —— 事后读得到的那一份。冻结的(bank_closing_balance / book_balance / difference)'
    '与现在重算的(book_balance_now / book_balance_drift)并排,谁也不替换谁。CLEANUP-A 起它是'
    'bank_reconciliation_record_rows() 的一层壳,按 module.finance.view 按名拒绝 —— 从前无权限'
    '读者拿到的是空列表。';

-- ════════════════════════════════════════════════════════════════════════════
-- 七 · attendance_period_status —— 第三节那支函数【必须】连它一起改
-- ════════════════════════════════════════════════════════════════════════════
-- ★【它是那个会被 NULL 毒到的算术调用方,而毒法是最安静的一种】★
--   它写着 round(COALESCE(sum(… attendance_unpaid_days(…) …), 0), 2)。
--   **sum() 会把 NULL 直接跳过。** 于是第三节让 attendance_unpaid_days 对无权限
--   读者返回 NULL 之后,这里不会变成 NULL,也不会报错 —— 它会把那些员工
--   **整个从月合计里悄悄抽走**,剩下的照常求和。少了几个人的无薪假,
--   月合计只是"小一点"。这正是 R2 点名的 PROC-COST-2 那个形状(750.00 → 0.00),
--   一模一样。
--
-- ★【而它今天【本来就】在漏一件更坏的事】★ 这张视图是 security_invoker = off,
--   也就是【以属主身份读、RLS 完全不生效】,而它 GRANT 给了 authenticated。
--   实测:任何一个登录用户,不管有没有 module.hr.view,都读得到全公司的
--   考勤与无薪假。视图自己的注释写着"调用方按 module.hr.view 把关" ——
--   **那又是一条"授权/调用方不是控制"**(R3 同一条)。
--   invoker = off 当初是对的(OPS-14 修法 (a):invoker 会让读者无权的那一侧
--   静默丢行,而行消失在这里意味着"这个月没有工资"),**错的是没有人在这一层问权限**。
--
-- 【所以:同一个壳 + DEFINER 取数体】取数体 require module.hr.view,
-- 于是 ① 走到 sum() 的人一定持 hr.view → attendance_unpaid_days 的判据必然通过
-- → 一个 NULL 都产生不出来,合计不可能被抽走;② 没有 hr.view 的人拿到
-- 按名拒绝,而不是"全公司的考勤"或"小一点的合计"。
CREATE OR REPLACE FUNCTION public.attendance_period_status_rows()
 RETURNS TABLE(period_id uuid, code text, period_month date, status text,
               opened_at timestamptz, completed_at timestamptz, reopened_at timestamptz,
               reopen_reason text, line_count integer, unrecorded_count integer,
               ot_normal_hours numeric, ot_rest_day_hours numeric,
               ot_public_holiday_hours numeric, unpaid_days numeric, payroll_posted boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【这一层此前【没有人】问权限,而视图注释把这件事记在"调用方"头上】
    PERFORM require_permission('module.hr.view');

    RETURN QUERY
    SELECT ap.id, ap.code, ap.period_month, ap.status,
        ap.opened_at, ap.completed_at, ap.reopened_at, ap.reopen_reason,
        count(al.id)::integer,
        count(al.id) FILTER (WHERE al.recorded_at IS NULL)::integer,
        round(COALESCE(sum(al.ot_normal_hours), 0::numeric), 2),
        round(COALESCE(sum(al.ot_rest_day_hours), 0::numeric), 2),
        round(COALESCE(sum(al.ot_public_holiday_hours), 0::numeric), 2),
        -- ★【已完成的读冻下来的,还开着的读此刻的】★ 两者是不同的问题,没动。
        -- 【sum() 跳过 NULL】—— 走到这里的人一定持 module.hr.view(上面那道闸),
        -- 所以 attendance_unpaid_days 不会返回 NULL,合计不会被悄悄抽走。
        round(COALESCE(sum(
            CASE
                WHEN ap.status = 'complete'::text THEN al.unpaid_days
                ELSE attendance_unpaid_days(al.employee_id, ap.period_month)
            END), 0::numeric), 2),
        (EXISTS ( SELECT 1
               FROM payroll_periods pp
              WHERE pp.deleted_at IS NULL AND pp.status = 'posted'::text
                AND date_trunc('month'::text, pp.period_month::timestamp with time zone)::date = ap.period_month))
       FROM attendance_periods ap
         LEFT JOIN attendance_lines al ON al.period_id = ap.id
      GROUP BY ap.id;
END;
$function$;

COMMENT ON FUNCTION public.attendance_period_status_rows() IS
    'CLEANUP-A:attendance_period_status 的取数体,判据 module.hr.view。两个理由,都要紧:'
    '① 它是 attendance_unpaid_days 的【算术调用方】,而 sum() 会跳过 NULL —— 没有这道闸,'
    '第三节的修复会让无权限读者的月合计把那些员工悄悄抽走(R2 点名的 PROC-COST-2 形状);'
    '② 视图是 security_invoker = off(以属主身份读、RLS 不生效)且 GRANT 给 authenticated,'
    '实测任何登录用户都读得到全公司考勤 —— 视图注释把把关记在"调用方"头上,而那是'
    '"调用方不是控制"。invoker = off 当初是对的(OPS-14 修法 (a)),错的是没有人在这一层问权限。';

-- 【壳仍然是 security_invoker = off】保持 OPS-14 修法 (a) 的那半个理由不变:
-- 跨 hr 与 finance 的行不该因为读者无权的某一侧而静默消失。把关现在在取数体里。
CREATE OR REPLACE VIEW public.attendance_period_status
WITH (security_invoker = off) AS
 SELECT r.period_id, r.code, r.period_month, r.status, r.opened_at, r.completed_at,
        r.reopened_at, r.reopen_reason, r.line_count, r.unrecorded_count,
        r.ot_normal_hours, r.ot_rest_day_hours, r.ot_public_holiday_hours,
        r.unpaid_days, r.payroll_posted
   FROM attendance_period_status_rows() r;

COMMENT ON VIEW public.attendance_period_status IS
    'ATTEND-1:每个考勤月一行 —— 铺了几行、还有几行没人记、三类加班工时合计、无薪假天数,'
    '以及那个月的工资过账了没有。★【已完成的读冻下来的,还开着的读此刻的】★ 两者是不同的问题。'
    'CLEANUP-A 起它是 attendance_period_status_rows() 的一层壳,把关(module.hr.view)搬进取数体 —— '
    '此前这一层【没有人问权限】,而视图是 security_invoker = off、GRANT 给 authenticated,'
    '于是任何登录用户都读得到全公司考勤;注释把把关记在"调用方"头上,那是"调用方不是控制"。';

-- ════════════════════════════════════════════════════════════════════════════
-- 八 · 21 条【认不到人】的 admin 授权 —— 删掉
-- ════════════════════════════════════════════════════════════════════════════
-- 【判据:auth.users 里【真的】没有这一行】而不是"这个人登不进来"。
-- 两者是完全不同的事实,ACCOUNTS-CLEAN(2026-08-24)就是按这条判据做的:
--   · 认不到人的 → 删(它们让 user_roles 说假话:"admin 有 N 个持有人"这个数字
--     会被权限屏与审批开关的前置条件读到,而它是错的);
--   · 真人但登不进来 → 一个字都不动。**Choo Er Teh(chef1949@126.com,
--     EMP-2026-0001,持 finance)就是这条的活例子:她的 auth 行【在】,
--     只是邮箱从未验证。她不在本次清单里,而且【按判据】不可能在。**
--   · 已经置了 revoked_at 的走查账号(5 条,2026-08-24)→ 也不动:
--     revoked_at 是这套 schema 自己的"撤销",它留下了"授权存在过、又被撤了"这件事。
--
-- 【为什么是 DELETE 而不是 revoked_at】同 ACCOUNTS-CLEAN:revoked_at 记的是
-- "有人撤销了某个人的权限",而这些行背后【没有人】。给一个不存在的人记一笔
-- 撤销史,是在记一件没发生过的事(FIN-26 那条规矩)。
--
-- 【复发史 —— 这不是清扫,这是第三次清扫】ACCOUNTS-CLEAN 在 2026-08-24 删掉
-- **66** 条,user_roles 从 73 行降到 7 行。此后又长回来:**8 条(08-26)+
-- 13 条(08-31,今天,00:20–19:43)= 21 条**。诊断见
-- docs/permission-blindness-cleanup.md 的「幽灵授权」一节 —— 结论是
-- **结构上没有任何东西把"账号"和"它的权限"绑在一起**(user_roles.user_id
-- 【没有】指向 auth.users 的外键,而 employees.user_id 有),而每一处拆对的代码
-- 都把两半写成两次【各自可失败、且其中一半不检查返回码】的 HTTP 调用。
-- 本刀同时改掉那三处不检查的调用,并让 check-scratch-rows.mjs 从此报得出这件事。
--
-- 【为什么不加外键】fixtures 用 gen_random_uuid() 造 user_roles 行(约二十支),
-- 加外键会当场把它们全部打死。所以结构上的绑定这条路是【关着的】,
-- 检测与修好那三处调用才是可走的路。
DELETE FROM public.user_roles ur
 WHERE NOT EXISTS (SELECT 1 FROM auth.users au WHERE au.id = ur.user_id);

COMMIT;
