-- db/migrations/2026-09-22-apr3-the-claim-the-count-and-the-edit-that-strands.sql
-- ════════════════════════════════════════════════════════════════════════════
-- APR-3:报销单接上引擎 · 盘点接上引擎 · 在途张数的两个问法 · 会搁死单据的策略编辑
-- ════════════════════════════════════════════════════════════════════════════
--
-- ★★★ 审批是【开着】的,而且本刀一刻也不碰那个开关。★★★
-- 迁移末尾的自证 ① 就是这件事;自证 ②③ 钉住"一行留痕都没写、每一条链的
-- 在途张数都没变"。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本刀的形状,以及它为什么【不是】委托书原来那一刀】
-- ════════════════════════════════════════════════════════════════════════════
-- 委托书要的是 payment · expense · expense_claim · pricing_formula · stocktake
-- 五条链。闸轮量下来,其中三条【接不上】,而原因不是接线:
--   · payments / expenses 的 status 只有 ('posted','reversed') —— **没有在途态**,
--     单据一建出来就过账、就落分录。APR-0 §3.2 的第 ③ 格是「提交路径分岔成
--     等人批 / 直接盖章」,而这里【没有可以分岔进去的那一半】。
--     ☞ Tim 的 Q2 裁定:两者移出本刀,先做一次建模改动(付款申请 → 批 → 付)。
--   · pricing_formulas **一个状态列都没有**,而且它是由服务端动作【直插表】
--     写出来的,没有任何一支 RPC。要审批它得先发明一个生命周期 ——
--     那正是 N2 把「装柜」「发运」踢出审批清单时用的同一条判据。
--     ☞ Tim 的 Q3 裁定:移出本刀,记在 docs/approvals.md §3c N2 旁边。
--
-- 于是本刀落地的是:**expense_claim(新枚举,分档)+ stocktake(不分档)**,
-- 外加从 APR-2 挪过来的 APPROVALS_POLICY_WOULD_STRAND、逐链在途、以及
-- 工单那一行 auto_approved。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ 本刀最值钱的一条,而它是【实测推翻委托书】的那一种 ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- 委托书写着:「cfo 不持 module.finance.edit,所以二级在这些链上的交集看起来
-- 是空的」。**后半句是假的,而它假在危险的那一边。**
-- 实测(2026-09-22,以 postgres 读 user_roles / role_permissions / auth.users):
--
--   module.finance.edit 的真持有人:admin · chooer · vince
--   cfo 的真持有人:★ admin@swm-os.test ——【就是那个 admin 账号】
--   ⇒ 二级 ∩ module.finance.edit = 1(admin),**非空**
--
-- ☞ 也就是说:把门写成 module.finance.edit,这道闸【今天会全绿】,
--   而它全绿靠的**只是 docs/approvals.md §0b 记着的那次撞车**(cfo 的唯一真
--   持有人就是 admin 账号)。Tim 已经裁定他会去开一个独立的 CFO 账号、
--   然后把 cfo 从 admin 上收回 —— **那一天二级当场归零**,
--   而那时没有任何东西会说是这一刀造成的。
--
-- ★ 所以门取的是【module.finance.view + data.view_prices】(Tim 的 Q1 裁定):
--   采购单那条链的形状,原样照搬 —— approve_purchase_order 要的正是这两个码,
--   而它【刻意】不要 edit(「一个提得了这张单的人不是一道管控」)。
--   实测:cfo 持这两个码,所以独立 CFO 账号落地之后二级仍然是 1。
--   ⚠ 代价照直说:一个持 view+prices 而不持 edit 的人,经由
--     decide_expense_claim(SECURITY DEFINER)造得出一笔开支 —— 线上是
--     phua 与 sandra。这是裁定,不是疏忽:批的人与做的人本来就该分开。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【一件线上现在就有的事,写下来给读日志的人】
-- ════════════════════════════════════════════════════════════════════════════
-- CLM-2026-0004:submitted,1000.00 本位币,**恰好等于门槛** ——
-- 提单人与主角都是 chooer。本刀提交之后它归【二级】,
-- 而二级今天唯一批得动的人是 admin@swm-os.test。
-- ☞ 在此之前它是 admin 或 vince 谁都批得了(两人都持 module.finance.edit)。
--   **分档把批得动的人从两个收窄到一个** —— 照直记下来,这是裁定的后果。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【对象清单】
-- ════════════════════════════════════════════════════════════════════════════
--   新建 3 支:approval_level_at · expense_claim_amount_base · approval_pending_documents
--   替换 6 支:approval_level_for · approval_chain_gates · record_approval_decision
--              decide_expense_claim · post_stocktake · release_work_order
--              guard_approvals_switch · approvals_readiness   ← 共 8 支替换
--   改 1 张表:approval_log(CHECK 枚举 + 读策略的 CASE + 一处列注释)
--
-- NOTE: 镜像在同一个提交里更新(AGENTS.md)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- ⓪ 先把【本刀之前】的读数钉在事务里 —— 末尾的自证要拿它比
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么是临时表,不是硬编码的数字】硬编码会在 Tim 今晚多走一张单据之后
-- 让这支迁移为一个无害的理由拒绝掉。★ 本刀一条 DML 都没有,所以这几格
-- 【必然】相等 —— 它们防的是【将来有人往这个文件里加一句 DML 而没有人发现】。
CREATE TEMP TABLE apr3_before ON COMMIT DROP AS
SELECT (SELECT approvals_enabled FROM finance_settings LIMIT 1)                        AS enabled,
       (SELECT count(*) FROM approval_log)                                             AS approval_log_rows,
       (SELECT count(*) FROM leave_requests      WHERE status='pending'   AND deleted_at IS NULL) AS leave_pending,
       (SELECT count(*) FROM medical_claims      WHERE status='submitted' AND deleted_at IS NULL) AS claims_pending,
       (SELECT count(*) FROM performance_reviews WHERE status='submitted')             AS reviews_pending,
       (SELECT count(*) FROM purchase_orders     WHERE approval_status='pending' AND deleted_at IS NULL) AS po_pending,
       (SELECT count(*) FROM work_orders         WHERE status='draft')                 AS wo_draft,
       (SELECT count(*) FROM expense_claims      WHERE status='submitted')             AS claim_pending,
       (SELECT count(*) FROM stocktakes          WHERE status='open' AND deleted_at IS NULL) AS stocktake_open;

DO $prologue$
DECLARE b record;
BEGIN
    SELECT * INTO b FROM apr3_before;
    RAISE NOTICE 'APR3_BEFORE enabled=% approval_log=% leave=% medclaims=% reviews=% po_pending=% wo_draft=% expense_claims_submitted=% stocktakes_open=%',
        b.enabled, b.approval_log_rows, b.leave_pending, b.claims_pending,
        b.reviews_pending, b.po_pending, b.wo_draft, b.claim_pending, b.stocktake_open;
    -- 开工闸:审批必须【已经是开的】。本刀每一条推理都建立在这一点上 ——
    -- 不成立就当场停,不要 COMMIT。
    IF b.enabled IS NOT TRUE THEN
        RAISE EXCEPTION 'APR3_PRECONDITION|approvals_enabled is % —— APR-3 假设审批是开着的', b.enabled;
    END IF;
END
$prologue$;


-- ════════════════════════════════════════════════════════════════════════
-- ① approval_log:枚举加一个取值 · 读策略加一支 · 一处列注释收窄
-- ════════════════════════════════════════════════════════════════════════
-- 【四格里的 ① 与 ④】② 在 record_approval_decision 里,③ 在决定函数里。
-- ★ ④ 是唯一一个漏掉也不会有任何东西变红的:写得进、读不出,
--   对每一个人都是 0 行而且不报错 —— WO-1b 在这一格上漏过一次。
ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;
ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check
    CHECK (subject_type IN (
        'leave_request', 'medical_claim', 'performance_review',
        'purchase_order', 'payment', 'expense',
        'pricing_formula', 'stocktake',
        'expense_claim',
        'work_order'));

DROP POLICY "approval_log select by permission" ON public.approval_log;
CREATE POLICY "approval_log select by permission"
    ON public.approval_log
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (
        CASE subject_type
            WHEN 'leave_request'      THEN has_permission('module.hr.view'::text)
            WHEN 'medical_claim'      THEN has_permission('module.hr.view'::text)
            WHEN 'performance_review' THEN has_permission('module.hr.view'::text)
            WHEN 'purchase_order'     THEN has_permission('module.purchasing.view'::text)
            WHEN 'payment'            THEN has_permission('module.finance.view'::text)
            WHEN 'expense'            THEN has_permission('module.finance.view'::text)
            WHEN 'expense_claim'      THEN has_permission('module.finance.view'::text)
            WHEN 'pricing_formula'    THEN has_permission('module.pricing.view'::text)
            WHEN 'stocktake'          THEN has_permission('module.stocktakes.view'::text)
            WHEN 'work_order'         THEN has_permission('module.processing.view'::text)
            ELSE false
        END
    );

COMMENT ON COLUMN public.approval_log.decision IS
'APR-1 建;★ APR-3(Tim 的 Q7)收窄了 auto_approved 的定义。auto_approved = 【单据生下来就是 approved】,没有任何人按过任何东西(create_purchase_order 在审批关着时就是这样)。★ 它【不】包括"一个人按了按钮,而当时审批恰好关着" —— 工单放行此前写的正是后者,note 里逐字写着「没有人做过这个决定」,而旁边就记着是谁。从 APR-3 起 release_work_order 两条分支都写 approved,与 HR 三条链、与盘点过账同一条裁定。⚠ 线上 2026-08-16 那一行 work_order / auto_approved 【没有】被改写(本表只增不改),所以这一列会同时存在两种写法,分界是一个日期不是一条规则。';


-- ════════════════════════════════════════════════════════════════════════
-- db/functions/approval_level_at.sql
-- ════════════════════════════════════════════════════════════════════════
-- db/functions/approval_level_at.sql
-- APR-3(2026-09-22):★【「达到或超过」这个比较号的【唯一】一份定义】★
--
-- 【它为什么被从 approval_level_for 里搬出来,而这不是整理】
-- APR-3 给 guard_approvals_switch 装了 APPROVALS_POLICY_WOULD_STRAND:一次策略
-- 编辑要【拿新的门槛】把每一张在途单据重新分一次档,再问那一档有没有人批得动。
-- 而 guard_approvals_switch 是 BEFORE UPDATE —— 它从 finance_settings 读到的是
-- OLD 那一行。approval_level_for() 自己去读表,所以在那道闸里它答的是【上一版
-- 策略】,并且全绿。这正是 approval_gate_intersections 抬头记着的同一个陷阱,
-- 而那里的处置是【把 NEW 的值当参数传进去】—— 这里照做。
--
-- ★【于是仓库里仍然只有一句 >=】approval_level_for(numeric) 的签名与它的两句
--   按名拒绝(THRESHOLD_NOT_SET / AMOUNT_REQUIRED)一个字都没有变,它只是把
--   那一次比较交给本函数。把比较号抄第二遍才是这一刀会付账的做法:两处 >= 的
--   系统,迟早有一处被改成 >,而它只在【恰好等于门槛】那一个数上现形。
--
-- 【db/fixtures/151 注入④ 的目标跟着搬到这里】那一臂把 >= 换成 > ,断言恰好
--   等于门槛的那一笔当场降级。判据搬了家,注入的目标就得跟着搬 —— 否则它会
--   什么也替换不掉,而 fixture 151 自己抬头里的 C-1 那一段记的正是这件事
--   (real_role_holders → real_role_grants 那一次,旧目标注入什么也没删)。
--
-- 【为什么不是 SECURITY DEFINER】它一个东西都不读:两个入参,一次比较。
--
-- NOTE: introduced by db/migrations/2026-09-22-apr3-the-claim-the-count-and-the-edit-that-strands.sql.

CREATE OR REPLACE FUNCTION public.approval_level_at(p_amount_base numeric, p_threshold numeric)
 RETURNS smallint
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 「1000 及以上归二级」—— Doc 1 的原话是 "and above",所以是 >= 。
    -- ★ 仓库里这个比较【只在这里出现一次】。
    SELECT CASE WHEN p_amount_base >= p_threshold THEN 2 ELSE 1 END::smallint;
$function$;

COMMENT ON FUNCTION public.approval_level_at(numeric, numeric) IS
'APR-3:分档那个比较号(>=)的【唯一】定义 —— 给定金额与给定门槛,归哪一级。★ 它被从 approval_level_for 里搬出来,是因为 guard_approvals_switch 是 BEFORE UPDATE:自己去读 finance_settings 读到的是 OLD 那一行,于是 APPROVALS_POLICY_WOULD_STRAND 会拿【上一版门槛】去重新分档并且全绿(与 approval_gate_intersections 抬头记的是同一个陷阱)。approval_level_for(numeric) 的签名与两句按名拒绝一字未改,它只是把比较交给这里 —— 于是仓库里仍然只有一句 >=。db/fixtures/151 注入④ 的目标跟着搬到本函数。';


-- ════════════════════════════════════════════════════════════════════════
-- db/functions/approval_level_for.sql
-- ════════════════════════════════════════════════════════════════════════
-- db/functions/approval_level_for.sql
-- 按【已落库的策略】给一笔本位币金额分档。
--
-- ★ APR-3(2026-09-22):那一次比较搬去了 approval_level_at(numeric, numeric) ——
--   本函数的签名、两句按名拒绝、以及它对调用方的意思【一个字都没有变】,
--   它只是把 >= 交给那支唯一的定义。搬家的理由写在 approval_level_at 的抬头
--   (一句话:BEFORE UPDATE 的闸读不到 NEW 的门槛)。
--   ☞ 本文件里【不再出现】那个比较号,这是有意的 —— db/fixtures/151 注入④
--     的目标因此跟着搬到了 approval_level_at。

CREATE OR REPLACE FUNCTION public.approval_level_for(p_amount_base numeric)
 RETURNS smallint
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_threshold numeric;
BEGIN
    SELECT approval_threshold_base INTO v_threshold FROM finance_settings LIMIT 1;
    IF v_threshold IS NULL THEN
        -- 【没设好的管控不等于可以跳过管控】—— 猜一个级别等于把审批变成装饰
        RAISE EXCEPTION 'APPROVAL_THRESHOLD_NOT_SET';
    END IF;
    IF p_amount_base IS NULL THEN
        RAISE EXCEPTION 'APPROVAL_AMOUNT_REQUIRED';
    END IF;
    -- APR-3:分档的判据只有一份,在 approval_level_at 里。
    RETURN approval_level_at(p_amount_base, v_threshold);
END;
$function$;


-- ════════════════════════════════════════════════════════════════════════
-- db/functions/expense_claim_amount_base.sql
-- ════════════════════════════════════════════════════════════════════════
-- db/functions/expense_claim_amount_base.sql
-- APR-3(2026-09-22):★【一张报销单值多少本位币】的【唯一】一份定义★
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它为什么必须存在】expense_claims 上【没有 fx_rate,也没有 amount_base】——
-- 只有 amount_ccy 与 currency。而 APR-3 有三个地方要同一个数:
--   ① decide_expense_claim 按金额分档(一级还是二级);
--   ② record_approval_decision 把金额【冻结】进 approval_log(那张表的 CHECK 是
--      四列全有或全无,所以它必须拿得到 fx_rate);
--   ③ approval_pending_documents 给在途单据算档次(屏幕、关闭那道闸、以及
--      APPROVALS_POLICY_WOULD_STRAND 都读它)。
-- 三处各算一遍,就是三份会漂开的判据 —— 而漂开之后,屏幕上说的档次与真正
-- 拦人的那一档可以不是同一档,那是一句关于内控的假话。
-- ════════════════════════════════════════════════════════════════════════════
--
-- ★★【取哪一天的牌价 —— spend_date,而不是 posting_date】★★
-- posting_date 是【审批人在做决定的那一刻自己填的一个入参】。拿它去分档,等于
-- 让审批人挑一个能把这张单据放进自己权限范围的日期 —— 一道由被它约束的人
-- 选定参数的闸,不是闸。spend_date 是【提交时就已经固定的事实】,它决定不了
-- 自己归谁批。☞ 代价照直说:分档用的汇率与 record_expense 过账时用的汇率
-- 【可以是两个数】(过账取 posting_date 那天的)。那是两个不同的问题:
-- 一个问"这笔承诺有多大",一个问"账上记多少" —— 不是同一个数,也不该是。
--
-- ★【取哪一种牌价 —— tt_sell,与 record_expense 逐字同源】record_expense 第 191
--   行的理由原样适用:一笔应付的外币开支是我们将来要【向银行买】的外币。
--   这里不另立一条 FX 规矩;THE FX RULE 只有一份。
--
-- ★★【它【不】抛 FX_RATE_MISSING,这是刻意的】查不到牌价时 fx_rate 与
--   amount_base 一起返回 NULL。理由:它的三个调用方里有一个是【列表】
--   (approval_pending_documents)—— 一支因为某一行没牌价就整个炸掉的列表函数,
--   会让屏幕、关闭那道闸、和策略编辑那道闸一起变成"读不到",而那读起来像
--   "没有在途单据"。☞ 要按名拒的那一个调用方(decide_expense_claim)自己去调
--   fx_rate_for(),那句 FX_RATE_MISSING 归它那一份定义所有。
--
-- 【为什么它不是 SECURITY DEFINER】它读 expense_claims 与 fx_rates,而这两张表
--   的 RLS 正是这个问题该有的答案:authenticated 直接调它,只看得见自己看得见
--   的那些单据;从三个 DEFINER 调用方里调它,以属主身份跑,看得见全部。
--   不声明 DEFINER,gate 的 B2 就与它无关,也不用在 check_mirrors 的豁免表里
--   多写一条解释。
--
-- NOTE: introduced by db/migrations/2026-09-22-apr3-the-claim-the-count-and-the-edit-that-strands.sql.

CREATE OR REPLACE FUNCTION public.expense_claim_amount_base(p_claim_id uuid)
 RETURNS TABLE(amount_ccy numeric, currency text, fx_rate numeric, amount_base numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT c.amount_ccy,
           c.currency,
           r.rate,
           CASE WHEN r.rate IS NULL THEN NULL ELSE round(c.amount_ccy * r.rate, 2) END
      FROM expense_claims c
      LEFT JOIN LATERAL fx_rate_asof(c.currency, c.spend_date, 'tt_sell') r ON true
     WHERE c.id = p_claim_id;
$function$;

COMMENT ON FUNCTION public.expense_claim_amount_base(uuid) IS
'APR-3:一张报销单值多少本位币 —— 【唯一】一份定义,三个调用方(decide_expense_claim 分档 · record_approval_decision 冻结金额 · approval_pending_documents 列在途)。expense_claims 上没有 fx_rate 也没有 amount_base,所以这个数必须算,而算三遍就是三份会漂开的判据。★ 取 spend_date 的 tt_sell:posting_date 是审批人做决定时自己填的入参,拿它分档等于让审批人挑一个把单据放进自己权限范围的日期;tt_sell 的理由与 record_expense 第 191 行逐字同源(应付外币是将来要向银行买的)。★ 查不到牌价时 fx_rate 与 amount_base 一起为 NULL、【不抛】—— 一支会炸的列表函数会让屏幕与两道闸一起读成"没有在途单据";要按名拒的 decide_expense_claim 自己去调 fx_rate_for()。';


-- ════════════════════════════════════════════════════════════════════════
-- db/functions/approval_pending_documents.sql
-- ════════════════════════════════════════════════════════════════════════
-- db/functions/approval_pending_documents.sql
-- APR-3(2026-09-22):★【哪些单据正在等人批】—— 一份判据,三个读它的人★
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【Tim 的 Q6 裁定,以及它为什么不是"把那个数放宽一点"】
-- ════════════════════════════════════════════════════════════════════════════
-- APR-2 之前,"在途张数"这个数【只数采购单】,而且它同时干两件事:
--   (a) 印在 /settings/approvals 上给人看;
--   (b) 喂 can_disable,并由 guard_approvals_switch 另外数【一遍】来按名拒。
-- APR-3 要把 (a) 放宽到每一条接上引擎的链。★ 而把 (b) 一起放宽会当场出事:
-- 线上今天有一张 submitted 的报销单(CLM-2026-0004),于是审批【一提交就再也
-- 关不掉】—— 一个没有人要求过的、永久的新约束。
--
-- ★★ 两个数长得一样,问的不是同一件事:
--     (a) 问「有多少单据在等人批」        —— 每一条链都该被数进去
--     (b) 问「关掉审批会让哪些单据批不动」 —— 只有一部分链会
--   ☞ 判别的那一句话,写下来给下一刀用:
--     **这条链的决定函数,在审批【关着】的时候还跑不跑得动?**
--       · 跑不动 → 这条链的在途单据 blocks_disable = true
--         (采购单:approve_purchase_order 开头就 RAISE APPROVALS_NOT_ENABLED,
--          而那张单是审批开着时才会生成 pending 的 —— 关掉就没人能推动它)
--       · 跑得动 → false
--         (报销单:submitted 是【员工交了一张单】,与审批开关无关;
--          decide_expense_claim 开着关着都做得了决定,只有【分档】那一步是
--          条件性的。所以关掉审批不会搁死它,只会让它不再分档。)
--
-- ★【盘点【不在】本表里】Tim 的 Q4 裁定:open 的意思是"正在点",不是"在等人批"。
--   盘点没有 open 与 posted 之间那一格。把 5 张 open 数成在途,会让屏幕说出
--   一句假话,并且(如果 (b) 也数它)把审批锁死在开着的状态。
-- ★【工单也不在】它没有"等人批"的队列:draft 是还没写完,release 就是决定本身。
--
-- 【为什么返回逐行,而不是几个计数】三个调用方要的东西不一样:
--   · approvals_readiness  要逐链的计数(屏幕上分开显示)
--   · guard_approvals_switch 的关闭那一支 要单据【编号】(拒绝要点名)
--   · APPROVALS_POLICY_WOULD_STRAND 要每一张单的【金额】(它要拿新门槛重新分档)
--   返回计数就答不了后两个,于是又会多出两份判据 —— 这正是 real_role_holders
--   当年返回集合而不是计数的同一条理由,逐字。
--
-- 【amount_base 可以是 NULL,而 NULL 不读成零】报销单的本位币金额要查牌价
--   (expense_claim_amount_base),查不到就是 NULL = 【这一张分不了档】。
--   ☞ 读到 NULL 的人该怎么办,由读它的人裁:APPROVALS_POLICY_WOULD_STRAND
--     按 Tim 的 N4(「不明金额的安全方向是往上」)把它当二级判。
--
-- 【为什么是 SECURITY DEFINER】它横跨采购与财务两个模块的表,而它的三个调用方
--   里两个是【属主身份跑的触发器】(属主没有 claims,加一道门会在每一次写策略的
--   路上抛权限错),第三个 approvals_readiness 自己开头就查 action.manage_permissions。
--   EXECUTE 已从 authenticated 收回(db/views/zzz_function_grants.sql)——
--   与 real_role_holders / approval_gate_intersections 逐字同源同理由。
--
-- NOTE: introduced by db/migrations/2026-09-22-apr3-the-claim-the-count-and-the-edit-that-strands.sql.

CREATE OR REPLACE FUNCTION public.approval_pending_documents()
 RETURNS TABLE(subject_type text, doc_id uuid, code text, amount_base numeric, blocks_disable boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 采购单:审批开着时才生成 pending,而 approve_purchase_order 在审批关着时
    -- 按名拒(APPROVALS_NOT_ENABLED)—— 关掉审批,这些单据就没有人推得动。
    SELECT 'purchase_order'::text, po.id, po.code,
           round(po.estimated_total_ccy * po.fx_rate, 2),
           true
      FROM purchase_orders po
     WHERE po.approval_status = 'pending' AND po.deleted_at IS NULL
    UNION ALL
    -- 报销单:submitted 是员工交了一张单,与审批开关无关;decide_expense_claim
    -- 开着关着都做得了决定(只有分档那一步是条件性的)。所以它【不】挡关闭。
    SELECT 'expense_claim'::text, c.id, c.code, b.amount_base, false
      FROM expense_claims c
      LEFT JOIN LATERAL expense_claim_amount_base(c.id) b ON true
     WHERE c.status = 'submitted'
$function$;

COMMENT ON FUNCTION public.approval_pending_documents() IS
'APR-3(Tim 的 Q6):哪些单据正在等人批 —— 逐行,一份判据三个读它的人(屏幕的逐链计数 · 关闭那道闸要的编号 · APPROVALS_POLICY_WOULD_STRAND 要的金额)。★ blocks_disable 把两个长得一样的数分开:「有多少在等人批」每条链都算,「关掉审批会搁死谁」只有一部分链算。判别的那一句话:这条链的决定函数在审批关着时还跑不跑得动 —— 跑不动才 true。今天只有采购单 true(approve_purchase_order 开头就 RAISE APPROVALS_NOT_ENABLED);报销单 false。★ 盘点不在本表里(Tim 的 Q4:open 是"正在点",不是"在等人批"),工单也不在(它没有等人批的队列)。amount_base 为 NULL = 这一张分不了档,不读成零。';


-- ════════════════════════════════════════════════════════════════════════
-- db/functions/approval_chain_gates.sql
-- ════════════════════════════════════════════════════════════════════════
-- db/functions/approval_chain_gates.sql
-- APR-2:【哪些链接上了 require_approver_for,以及那条链自己的门是什么】
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ 它存在的理由,是一个【实测出来的、当时活在线上的】死锁 ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- `require_approver_for(N)` 问的是「你在不在第 N 级那个【角色】里」。
-- 而每一支决定函数【另外】问一句「你持不持有本模块的那个【权限码】」。
-- ★ 在 APR-2 之前,【没有任何东西断言这两个集合有交集】。
--
-- 实测(2026-09-22,以 postgres 读 user_roles / role_permissions / auth.users 基表,
-- 以及 require_approver_for 自己的答案):
--
--   一级 = finance = chooer@evoltrya.test  —— 他【不】持 module.processing.edit
--   二级 = cfo     = admin@swm-os.test
--
--   | 链           | 模块门                              | 持有人                  | ∩ 一级 |
--   |--------------|-------------------------------------|-------------------------|--------|
--   | 采购单       | purchasing.view + data.view_prices  | admin chooer phua sandra vince | chooer ✓ |
--   | ★ 工单       | processing.edit                     | admin phua sandra vince | ★ 空   |
--
-- ☞ 也就是说:**审批一打开,线上就没有任何人放行得了一张工单** ——
--   而 WO-1b 把那一行 require_approver_for(1) 写下去的时候,三道闸全绿。
--   今天 work_orders 里 draft = 0,所以没有单据卡住;下一张就再也放行不了。
--   ★ APR-2 的处置是把工单从这台引擎的【路由】那一半摘下来(Tim 的 Q1 裁定:
--     按角色分级只管【带钱的单据】),于是 APR-2 结束时本表只剩采购单两支。
-- ★ APR-3(2026-09-22)加进报销单两行 —— 本仓库第二条接上按角色分级的链。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这是一张手写的名册,所以它必须被核对,不能被相信】
-- ════════════════════════════════════════════════════════════════════════════
-- 一张与代码分开维护的清单,迟早与代码漂开,而漂开的那一刻它仍然全绿。
-- 所以 db/fixtures/203 有一条【目录派生】的断言:
--     SELECT proname FROM pg_proc WHERE prosrc LIKE '%require_approver_for%'
-- 那个集合必须与本函数的 action_function 列【逐字相等】。
-- ☞ 加一条链接上 require_approver_for,就要在这里加一行,否则 fixture 当场变红。
--
-- 【为什么门是一个数组,不是一个码】approve_purchase_order 要【两个】:
-- module.purchasing.view(进得了模块)+ data.view_prices(看得见他要批的那个数,
-- R4)。而 reject_purchase_order 只要前一个 —— 驳回不需要看见金额。
-- **两支函数的门不一样,所以它们各占一行,不合并。**
--
-- 【为什么不是 SECURITY DEFINER】它是一张常量表,不读任何东西。
--
-- NOTE: introduced by db/migrations/2026-09-22-apr2-self-approval-and-the-approver-that-nobody-is.sql.

CREATE OR REPLACE FUNCTION public.approval_chain_gates()
 RETURNS TABLE(subject_type text, action_function text, level smallint, gate_permissions text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT v.subject_type, v.action_function, v.level, v.gate_permissions
      FROM (VALUES
        ('purchase_order'::text, 'approve_purchase_order'::text, 1::smallint,
            ARRAY['module.purchasing.view', 'data.view_prices']::text[]),
        ('purchase_order'::text, 'approve_purchase_order'::text, 2::smallint,
            ARRAY['module.purchasing.view', 'data.view_prices']::text[]),
        -- 驳回【不】要 data.view_prices —— 它仍然按金额分级(所以两级都在),
        -- 而它不显示那个金额。门窄一格,所以它自己一行。
        ('purchase_order'::text, 'reject_purchase_order'::text, 1::smallint,
            ARRAY['module.purchasing.view']::text[]),
        ('purchase_order'::text, 'reject_purchase_order'::text, 2::smallint,
            ARRAY['module.purchasing.view']::text[]),
        -- ★★ APR-3(Tim 的 Q1):报销单。门是【module.finance.view + data.view_prices】,
        --    【不是】module.finance.edit —— 采购单那条链的形状,原样照搬。
        --    两条理由,都在 docs/approvals.md §0 与 §5 里已经成立:
        --    ① 批的人不该是提得了这张单的人(edit 就是提单的那个码);
        --    ② R4:批的人必须看得见他批的那个数,而这条链【按金额分档】。
        --    ★ 实测的第三条,也是决定性的那条:cfo 持 module.finance.view 与
        --      data.view_prices,【不持】module.finance.edit。写成 edit 的话,
        --      今天二级之所以还有一个人,靠的只是 cfo 的唯一真持有人就是 admin
        --      账号(§0b 记着的那次撞车)—— Tim 一拿到独立的 CFO 账号、把 cfo
        --      从 admin 上收回,二级当场归零,而那一天没有任何东西会说是这一刀
        --      造成的。写成 view + prices,那一天它仍然是 1。
        --    【approve 与 reject 不分两行】与采购单不同:本链两支分支【都】分档
        --    (驳回也落一行带 level 的留痕),所以两边都要看得见金额,门一样宽。
        ('expense_claim'::text, 'decide_expense_claim'::text, 1::smallint,
            ARRAY['module.finance.view', 'data.view_prices']::text[]),
        ('expense_claim'::text, 'decide_expense_claim'::text, 2::smallint,
            ARRAY['module.finance.view', 'data.view_prices']::text[])
      ) AS v(subject_type, action_function, level, gate_permissions)
$function$;

COMMENT ON FUNCTION public.approval_chain_gates() IS
'APR-2(APR-3 加进报销单两行):接上了 require_approver_for 的链,以及每一支动作【自己的】模块门(可能是几个码的合取)。★ 它存在是因为 WO-1b 实测在线上造出过一个死锁:一级审批角色 finance 的唯一真持有人不持 module.processing.edit,于是审批一开,工单谁都放行不了,而三道闸全绿。这张名册是手写的,所以 db/fixtures/203 有一条目录派生的断言钉住它与 pg_proc 里真正调用 require_approver_for 的那组函数逐字相等 —— 加一条链就要在这里加一行。★ APR-3 的报销单两行取的门是 module.finance.view + data.view_prices,【不是】module.finance.edit —— 写成 edit 的话,今天二级还有一个人靠的只是 cfo 的唯一真持有人就是 admin 账号(§0b 那次撞车),而独立 CFO 账号一落地它就归零。';


-- ════════════════════════════════════════════════════════════════════════
-- db/functions/record_approval_decision.sql
-- ════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.record_approval_decision(p_subject_type text, p_subject_id uuid, p_decision text, p_level smallint DEFAULT NULL::smallint, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_ccy  text;
    v_amt  numeric;
    v_rate numeric;
    v_base numeric;
    v_ok   boolean := false;
    v_id   uuid;
    v_base_ccy text;
BEGIN
    SELECT code INTO v_base_ccy FROM currencies WHERE is_base;

    -- 【外键没了,这一段就是它的替代】主体必须真的存在,并且顺手把编号与金额
    -- 冻结下来。不存在 → 点名拒绝,而不是插一行指向空气的留痕。
    CASE p_subject_type
        WHEN 'leave_request' THEN
            -- 请假没有金额:天数不是钱,不塞进币种列
            SELECT true, r.code INTO v_ok, v_code
              FROM leave_requests r WHERE r.id = p_subject_id;
        WHEN 'medical_claim' THEN
            -- amount_sgd 已经是本位币口径(列名是 FIN-0 之前留下的字面量,不是新的判断)
            SELECT true, c.code, c.amount_sgd, v_base_ccy, 1, c.amount_sgd
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM medical_claims c WHERE c.id = p_subject_id;
        WHEN 'performance_review' THEN
            SELECT true, e.code INTO v_ok, v_code
              FROM performance_reviews r JOIN employees e ON e.id = r.employee_id
             WHERE r.id = p_subject_id;
        WHEN 'purchase_order' THEN
            -- 【用单据自己存的汇率】(决定 3)—— 审批档次因此不会随行情事后漂移
            SELECT true, po.code, po.estimated_total_ccy, po.currency, po.fx_rate,
                   round(po.estimated_total_ccy * po.fx_rate, 2)
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM purchase_orders po WHERE po.id = p_subject_id;
        WHEN 'payment' THEN
            SELECT true, p.code, p.amount_ccy, p.currency, p.fx_rate, p.amount_base
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM payments p WHERE p.id = p_subject_id;
        WHEN 'expense' THEN
            SELECT true, e.code, e.amount_ccy, e.currency, e.fx_rate, e.amount_base
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM expenses e WHERE e.id = p_subject_id;
        WHEN 'expense_claim' THEN
            -- ★ APR-3:报销单。expense_claims 上【没有 fx_rate,也没有 amount_base】,
            -- 所以这四列要算 —— 而算它的判据只有一份(expense_claim_amount_base),
            -- 与 decide_expense_claim 分档、approval_pending_documents 列在途读的是
            -- 同一支。三处各算一遍就是三份会漂开的数,而"屏幕上说的档次"与"真正
            -- 拦人的那一档"漂开,是一句关于内控的假话。
            -- 【牌价查不到时四列一起留空,而不是塞一个数进去】approval_log 的
            -- amount_shape 约束要的就是"全有或全无";留空的意思是【这一张当时
            -- 分不了档】,而那是真的。要按名拒的那一支是 decide_expense_claim。
            SELECT true, c.code, b.amount_ccy, b.currency, b.fx_rate, b.amount_base
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM expense_claims c
              LEFT JOIN LATERAL expense_claim_amount_base(c.id) b ON true
             WHERE c.id = p_subject_id;
            IF v_rate IS NULL THEN
                v_amt := NULL; v_ccy := NULL; v_base := NULL;
            END IF;
        WHEN 'pricing_formula' THEN
            SELECT true, f.code INTO v_ok, v_code
              FROM pricing_formulas f WHERE f.id = p_subject_id;
        WHEN 'stocktake' THEN
            SELECT true, s.code INTO v_ok, v_code
              FROM stocktakes s WHERE s.id = p_subject_id;
        WHEN 'work_order' THEN
            -- WO-1b:工单【没有金额】—— 它是一份要做什么的计划,不是一笔钱。
            -- 与 leave_request / performance_review / stocktake 同一类:
            -- 只冻结编号,金额那四列留空,而不是塞一个 0 进去
            -- (0 会让它在按金额筛的报表里排到最前面,那是一句假话)。
            SELECT true, w.code INTO v_ok, v_code
              FROM work_orders w WHERE w.id = p_subject_id;
        ELSE
            RAISE EXCEPTION 'APPROVAL_SUBJECT_TYPE_UNKNOWN|%', p_subject_type;
    END CASE;

    IF NOT COALESCE(v_ok, false) THEN
        RAISE EXCEPTION 'APPROVAL_SUBJECT_NOT_FOUND|%|%', p_subject_type, p_subject_id;
    END IF;

    INSERT INTO approval_log (subject_type, subject_id, subject_code, decision, level,
                              actor_user_id, note, amount_ccy, currency, fx_rate, amount_base)
    VALUES (p_subject_type, p_subject_id, v_code, p_decision, p_level,
            auth.uid(), p_note, v_amt, v_ccy, v_rate, v_base)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$function$

;


-- ════════════════════════════════════════════════════════════════════════
-- db/functions/decide_expense_claim.sql
-- ════════════════════════════════════════════════════════════════════════
-- db/functions/decide_expense_claim.sql
-- 报销单的决定路径。CLAIM-1 建的;★ APR-3(2026-09-22)把它接上审批引擎。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ APR-3 在这支函数上改了三件事,每一件都是 Tim 的一条裁定 ★★★
-- ════════════════════════════════════════════════════════════════════════════
--
-- ① 【门从 module.finance.edit 换成 module.finance.view + data.view_prices】(Q1)
--    采购单那条链的形状,原样照搬 —— approve_purchase_order 要的正是这两个码,
--    而它【刻意】不要 edit:「一个提得了这张单的人不是一道管控」。
--    ★ 而决定性的理由是实测出来的:cfo 持 module.finance.view 与 data.view_prices,
--      【不持】module.finance.edit。写成 edit,今天二级之所以还有一个人批得动,
--      靠的只是 cfo 的唯一真持有人就是 admin 账号(docs/approvals.md §0b 记着的
--      那次撞车);Tim 一拿到独立的 CFO 账号、把 cfo 从 admin 上收回,
--      二级当场归零,approval_gate_intersections 会在【那一天】才变红,
--      而那时没有任何东西会说是这一刀造成的。
--    ⚠【代价照直说,因为它是真的】本函数是 SECURITY DEFINER,批准那一支会
--      调 record_expense 建一张开支单。于是一个持 view + prices 而【不持】
--      module.finance.edit 的人,经由这条路造得出一笔开支 —— 线上是 phua 与
--      sandra 两个人。这是 Tim 的裁定,不是疏忽:批的人与做的人本来就该分开,
--      而"做"这一步是引擎代他做的,不是他自己去写那张表。
--
-- ② 【四眼换成全库唯一的那一份判据】(Q5)
--    此前这里调的是 assert_segregated('EXPENSE_CLAIM_SELF_APPROVAL', …) ——
--    两条腿(受益人 + 提报人)其实是对的,但它是四眼的【第二份定义】,
--    而 APR-2 §3d 的全部论证就是"一条写成两遍的规矩,第三条链会漏掉它"。
--    ★ 而它同时在屏幕上说错过一句话:两条腿共用一句
--      「报销 X 是你提的,所以批它的不能是你」—— 当拒绝是因为【你就是那张单
--      说的那个人】时,那句话是假的,并且把人指去修错的东西。
--      APR-2 把这一句拆成两句,正是为了这个;这里接上那两句。
--    ☞ assert_segregated 本身【留着】,它还有三个正当的调用方
--      (guard_payment_sod · guard_finance_settings_sod · sod_supplier_creator)。
--
-- ③ 【接上分档与留痕】(本刀的主体)
--    approvals_enabled() 为真时按金额分档并 require_approver_for(级别);
--    两条分支【都】落一行 approval_log。
--    ★【永远不写 auto_approved】Tim 对 HR 三条链的裁定逐字适用:
--      开着还是关着,做决定的都是一个人。审批关着时写的是 approved/rejected、
--      level 为 NULL —— 不是"系统盖的章"。
--    ★【驳回也分档,所以驳回也要看得见金额】与采购单不同:那里 reject 单独一支
--      函数、门窄一格(不显示金额)。这里是一支函数两条分支,两边都落带 level
--      的留痕,所以两边都得先知道这是几级的单 —— 门一样宽,registry 里那两行
--      因此是同一个 gate_permissions。
--
-- 【金额从哪来】expense_claims 上没有 fx_rate 也没有 amount_base,所以那个数要算,
--   而判据只有一份:expense_claim_amount_base()(spend_date 的 tt_sell,理由见
--   那个文件的抬头 —— 一句话:posting_date 是审批人自己填的入参,拿它分档等于
--   让审批人挑自己的权限)。查不到牌价时它返回 NULL,由【这里】按名拒:
--   那句 FX_RATE_MISSING 归 fx_rate_for() 那一份定义所有,本函数不复述它。

CREATE OR REPLACE FUNCTION public.decide_expense_claim(p_claim_id uuid, p_approve boolean, p_account_code text DEFAULT NULL::text, p_tax_code text DEFAULT NULL::text, p_posting_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c        expense_claims%ROWTYPE;
    v_emp      employees%ROWTYPE;
    v_has_att  boolean;
    v_exp      jsonb;
    v_date     date;
    v_base     numeric;
    v_level    smallint;
    v_appr_on  boolean := approvals_enabled();
BEGIN
    -- ① APR-3(Q1):门是【看得见财务 + 看得见金额】,不是【改得了财务】。
    --    两个码分两句,与 approve_purchase_order 同形 —— 拒绝要说清缺的是哪一个。
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_c FROM expense_claims WHERE id = p_claim_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_FOUND|%', COALESCE(p_claim_id::text, '?');
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;
    SELECT * INTO v_emp FROM employees WHERE id = v_c.employee_id;

    -- ══ ★② 四眼:全库【唯一】一份判据,两条腿 ★ ════════════════════════════
    -- 【为什么这道闸必须在这里】SOD-1 的 guard_payment_sod 明确豁免了付给员工的
    -- 款,理由是"由 HR 建档、财务付款,已经跨了两个模块的门"。那句话在写下的
    -- 那天是对的 —— 而 CLAIM-1 开出了一条新路:**员工自己发起**。发起人现在
    -- 就是受益人,那个论证对新路不成立。「换了推导来源,闸就要跟着搬」。
    -- 【两条腿各是谁】raiser = 提这张单的人(代人录入时不是员工本人);
    -- subject = 这张单【说的是谁】,也就是拿到这笔钱的那位员工。
    -- 顺序是定的:raiser 先判(APR-2 §3.5)。
    PERFORM forbid_self_approval(v_c.created_by, v_c.employee_id);

    -- ══ ★③ 分档 ★ ════════════════════════════════════════════════════════
    -- 【只在审批开着时问这一句】关着的时候,分档是一个没有意义的动作:
    -- 没有哪一级在生效,而 require_approver_for 会拿一条没有人在执行的策略
    -- 去拒绝一个本来做得了决定的人。这与 HR 三条链的形状一致 ——
    -- ☞ 也正因为如此,一张 submitted 的报销单【不挡】审批关闭
    --   (approval_pending_documents 的 blocks_disable = false,理由写在那里)。
    IF v_appr_on THEN
        SELECT b.amount_base INTO v_base FROM expense_claim_amount_base(p_claim_id) b;
        IF v_base IS NULL THEN
            -- 【那句话归 fx_rate_for 所有,这里只是把它请出来】——
            -- 自己拼一句 FX_RATE_MISSING 就是这条 FX 规矩的第二份定义。
            PERFORM fx_rate_for(v_c.currency, v_c.spend_date, 'tt_sell');
            -- 上面必定抛;真走到这里说明牌价其实查得到而上一步算出了 NULL,
            -- 那是一个【不该发生】的状态,按名拒而不是继续往下走。
            RAISE EXCEPTION 'EXPENSE_CLAIM_AMOUNT_BASE_UNRESOLVED|%', v_c.code;
        END IF;
        v_level := approval_level_for(v_base);
        PERFORM require_approver_for(v_level);
    END IF;

    -- ══ 驳回 ══════════════════════════════════════════════════════════════
    IF NOT p_approve THEN
        -- 【按名拒,而不是让 CHECK 抛约束原文】fixture 90 立的那条
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_REJECT_REASON_REQUIRED|%', v_c.code;
        END IF;
        UPDATE expense_claims
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_claim_id;
        -- ★ 驳回【也】留痕 —— APR-1 建这张表的第一条理由就是"驳回 → 重提 →
        --   批准之后,驳回那一次不留痕迹"。报销单此前正是那个形状:
        --   decision_notes 会被下一次决定覆盖掉。
        PERFORM record_approval_decision('expense_claim', p_claim_id, 'rejected',
                                         v_level, btrim(p_notes));
        RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'rejected',
                                  'level', v_level);
    END IF;

    -- ══ 批准 ══════════════════════════════════════════════════════════════
    IF p_account_code IS NULL OR btrim(p_account_code) = '' THEN
        -- 会计口径由审批人给 —— 没有科目就没法记账,而猜一个科目比拒绝坏
        RAISE EXCEPTION 'EXPENSE_CLAIM_ACCOUNT_REQUIRED|%', v_c.code;
    END IF;

    -- ★【GST 开着时,税码是【必给】的 —— 而且只能由审批人给】★
    -- 实测:resolve_tax_code 接受 override 或【往来对象的默认税码】,两者皆空就
    -- 按名拒(TAX_CODE_REQUIRED)。而 employees **没有 default_tax_code 这一列** ——
    -- 员工这一侧【永远】解析不出默认值。所以报销这条路上,税码只能显式给。
    -- 【为什么在这里先拒一次,而不是让 resolve_tax_code 去拒】它的提示语是
    -- 「给这个往来对象设一个默认税码,或在这张单据上指定一个」—— 对员工来说
    -- 前半句是【做不到的事】,于是那句话有一半是错的指路。这里按名拒并说清楚
    -- 要做的判断:进项税可抵是 TX,不可抵是 BL,而那是一个财务判断。
    -- 【这不是把税的规矩重写一遍】有效性、侧别、是否停用仍然全归 resolve_tax_code;
    -- 这里只声明一个【这条路特有的前提】:员工没有默认值,所以 override 必填。
    IF (SELECT gst_registered FROM finance_settings) AND
       COALESCE(btrim(COALESCE(p_tax_code, '')), '') = '' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_TAX_CODE_REQUIRED|%', v_c.code;
    END IF;

    -- ★【凭据:要么有附件,要么有一句说得出为什么没有】★
    -- 【为什么查在这一步而不是提交那一步】提交那一刻申请还不存在,附件挂不上去;
    -- 而凭据真正起作用的时刻,正是有人要据它做决定的时刻。
    -- 【为什么留了一条例外的路】一条没有例外出口的规矩会被绕过 ——
    -- 这里绕过的走法是"让财务当成一笔普通费用直接录进去",而那会把整条
    -- 报销记录一起丢掉。所以:允许没有收据,但要求把【为什么】说出来,
    -- 并且让审批人看见自己批的是哪一种。
    SELECT EXISTS (SELECT 1 FROM finance_attachments
                    WHERE claim_id = p_claim_id AND deleted_at IS NULL) INTO v_has_att;
    IF NOT v_has_att AND COALESCE(btrim(v_c.no_receipt_reason), '') = '' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NO_EVIDENCE|%', v_c.code;
    END IF;

    -- 入账日:默认花钱那天;期间关了账时由审批人显式给
    v_date := COALESCE(p_posting_date, v_c.spend_date);

    -- 【成本与欠款在这里同时落地】unpaid = 一笔挂在这名员工头上的应付,
    -- 它会立刻出现在 ap_open_items 里带着他自己的名字(PAYEE-1a)。
    -- 汇率传 NULL:由 record_expense 按【那一天】自己查牌价 —— 一条 FX 规矩,
    -- 查不到就按名拒(FX_RATE_MISSING),报销不是它的例外。
    -- ⚠ APR-3 照直说:这里过账取的是 v_date 那天的牌价,而上面分档取的是
    --   spend_date 那天的 —— 两个日期不同时,两个数可以不一样。那是两个不同的
    --   问题(这笔承诺有多大 / 账上记多少),理由写在 expense_claim_amount_base。
    -- ★★【这张开支单【不】另外走一次审批】它是引擎在一个人已经批准之后代他
    --   记的账,不是一份新提交的单据 —— 与 N5 对系统生成凭证的裁定逐字同源。
    --   expense 这个 subject_type 在 APR-3 里【没有】接上引擎(Tim 的 Q2 裁定:
    --   payments / expenses 没有在途态,要先做一次建模改动),所以今天这一格
    --   不需要任何豁免机制;那条路开工时,豁免要写成一个【显式入参】,不是 GUC
    --   (Tim 的 Q9),理由记在 docs/forward-queue.md。
    v_exp := record_expense(
        p_expense_date   := v_date,
        p_account_code   := btrim(p_account_code),
        p_amount         := v_c.amount_ccy,
        p_currency       := v_c.currency,
        p_fx_rate        := NULL,
        p_payment_status := 'unpaid',
        p_bank_account   := NULL,
        p_supplier_id    := NULL,
        p_employee_id    := v_c.employee_id,
        p_payee_name     := v_emp.legal_name,
        p_notes          := format('Expense claim %s (%s) — %s', v_c.code, v_emp.code, v_c.description),
        p_tax_code       := NULLIF(btrim(COALESCE(p_tax_code, '')), ''));

    UPDATE expense_claims
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           account_code = btrim(p_account_code),
           tax_code = NULLIF(btrim(COALESCE(p_tax_code, '')), ''),
           posting_date = v_date,
           expense_id = (v_exp->>'expense_id')::uuid
     WHERE id = p_claim_id;

    PERFORM record_approval_decision('expense_claim', p_claim_id, 'approved',
                                     v_level, NULLIF(btrim(COALESCE(p_notes, '')), ''));

    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'approved',
                              'expense_id', v_exp->>'expense_id', 'posting_date', v_date,
                              'level', v_level);
END;
$function$;


-- ════════════════════════════════════════════════════════════════════════
-- db/functions/post_stocktake.sql
-- ════════════════════════════════════════════════════════════════════════
-- db/functions/post_stocktake.sql
-- 盘点过账。cut 2a 建的;★ APR-3(2026-09-22)把它接上审批引擎。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★ APR-3 在这里加了两样,而【没有】加第三样 ★★(Tim 的 Q4 裁定)
-- ════════════════════════════════════════════════════════════════════════════
-- 加的:① 四眼(只有 raiser 那条腿 —— 一次盘点【不是关于某个人的】,
--          与工单同形,第二个入参传 NULL,而 NULL 一律不匹配);
--        ② 一行 approval_log 留痕。
--
-- ★【没有加按角色分级,而这是一条裁定,不是遗漏】盘点【没有金额】——
--   stocktakes 表上一个金额列都没有(id/code/status/notes/时间戳/人)。
--   按 Tim 修订后的 N7:按角色分级只管带钱的单据;不带钱的,谁能批仍由它
--   自己的模块权限说了算,这里就是 module.stocktakes.edit。
--   ☞ 所以本函数【不】调 require_approver_for,也因此【不】进
--     approval_chain_gates() 那张名册 —— fixture 203 的 E 臂把名册与
--     「prosrc 里真的调了它的那组函数」钉成逐字相等,加错一行当场红。
--
-- ★【留痕永远写 approved,永远不写 auto_approved】过账是一个人按下去的动作,
--   开着还是关着都是。这与 HR 三条链、以及 APR-3 同时修好的工单放行,
--   是同一条裁定(Tim 的 Q7)。level 恒为 NULL —— 写一个级别就是声称有过
--   一次按级别的授权,而这条链没有。
--
-- ⚠★【它对线上 5 张 open 的盘点是有后果的,照直说】线上 ST-2026-0082…0086
--   五张都是 admin@swm-os.test 建的,于是从本刀起 **admin 自己过不了这五张**。
--   过得了的是另外五个持 module.stocktakes.edit 的人(chooer · fusheng ·
--   phua · sandra · vince)。这是四眼原则要的效果,不是一次回归。
--
-- ★【open 不算"在途待批"】approval_pending_documents() 里【没有】盘点 ——
--   open 的意思是"正在点",不是"在等人批";盘点在点完与过账之间没有那一格。
--   把 5 张 open 数成在途,会让屏幕说一句假话。理由写在那个函数的抬头。

CREATE OR REPLACE FUNCTION public.post_stocktake(p_stocktake_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user           uuid := auth.uid();
    v_st             record;
    v_line           record;
    v_code           text;
    v_current        numeric;
    v_deleted        timestamptz;
    v_delta          numeric;
    v_lines_total    integer := 0;
    v_lines_adjusted integer := 0;
    v_total_delta    numeric := 0;
    v_value          numeric;
    v_inv_acct       text;
    v_amt            numeric;
    v_je_lines       jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('module.stocktakes.edit');
    SELECT id, code, status, deleted_at, created_by INTO v_st
    FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_st.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', p_stocktake_id;
    END IF;
    IF v_st.status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_st.status;
    END IF;

    -- ★ APR-3:四眼。判据只有一份定义,两条腿的顺序也只在那里定。
    -- 第二个入参是 NULL —— 一次盘点是关于一批货的,不是关于某个人的,
    -- 所以它没有"这张单说的是谁"那条腿;而 NULL 一律不匹配。
    PERFORM forbid_self_approval(v_st.created_by, NULL::uuid);

    FOR v_line IN SELECT * FROM stocktake_lines WHERE stocktake_id = p_stocktake_id
    LOOP
        v_lines_total := v_lines_total + 1;

        IF v_line.inbound_batch_id IS NOT NULL THEN
            SELECT code, remaining_qty, deleted_at INTO v_code, v_current, v_deleted
            FROM inbound_batches WHERE id = v_line.inbound_batch_id FOR UPDATE;
            -- ════════════════════════════════════════════════════════════════
            -- PROC-COST-2 · R1:【盘点计值 = 落地成本,与注销同一支函数】
            -- 改之前这里取的是 unit_price(上一行的 SELECT 列表里),于是一批
            -- 落地 900 的货盘成 0 只解除 500,**400 留在 1200 上**(线上实测)。
            --
            -- ★【两个方向都改,而这是让修复安全的那一半】★
            -- 下面 v_value 同时喂给盘盈(借库存)与盘亏(贷库存)两支。只改盘亏
            -- 的实现会让一次"点少了、再点回来"**永久销毁**运费与加工成本 ——
            -- 那批料一克都没离开过厂房。**一次修复造出来的新缺陷,比被修的更坏。**
            -- fixture 的 D 臂钉的就是这一条:100 → 50 → 100,1200 必须回到起点。
            --
            -- 【读的是 landed_unit_cost,不是带判据的读取器】计值不许取决于
            -- 谁按的按钮 —— 见本刀迁移抬头第四节。
            -- 【FOR UPDATE 之后单独取】把函数调用留在 FOR UPDATE 的目标列表里
            -- 会让人以为它也被锁保护;它不是,它是一次独立的读。分两行写。
            -- ════════════════════════════════════════════════════════════════
            v_value := inbound_batch_landed_unit_cost_all(v_line.inbound_batch_id);
            v_inv_acct := '1200';
        ELSE
            SELECT ob.code, ob.remaining_qty, ob.deleted_at, po.unit_cost_base
            INTO v_code, v_current, v_deleted, v_value
            FROM output_batches ob
            LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
            WHERE ob.id = v_line.output_batch_id
            FOR UPDATE OF ob;
            v_inv_acct := '1220';
        END IF;

        IF v_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'BATCH_DELETED|%', v_code;
        END IF;

        v_delta := v_line.counted_qty - v_current;
        IF v_delta <> 0 THEN
            IF v_line.inbound_batch_id IS NOT NULL THEN
                -- ════════════════════════════════════════════════════════════
                -- FIN-32-fu1:业务日 = 过账日(CURRENT_DATE),而这是【查过之后】
                -- 的结论,不是"没有更好的来源"那种含糊话。
                -- stocktakes 上确实有个 started_at,名字听起来像盘点日 —— 它不是:
                -- 它是 timestamptz NOT NULL DEFAULT now(),【全代码库没有任何一处
                -- 写过它】,而线上每一行的 started_at 与 created_at 【逐微秒相等】
                -- (实测 3/3,最大差 0.000000 秒)。它是建单时间戳,不是盘点日期。
                -- 所以周一盘、周二过账,这里记的仍是周二 —— 而这是【诚实的】:
                -- 系统里根本没有人告诉过它周一。
                -- 真要记录盘点当天,得先有一个【盘点日字段让人填】(Phase 2 的
                -- 盘点单),那时这里改成读它 —— 与注销读 deleted_at 同一条规矩:
                -- 日期要来自记录,而记录得先存在。
                -- ════════════════════════════════════════════════════════════
                INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.inbound_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE inbound_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.inbound_batch_id;
            ELSE
                INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.output_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE output_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.output_batch_id;
            END IF;
            v_lines_adjusted := v_lines_adjusted + 1;
            v_total_delta := v_total_delta + v_delta;

            -- cut 2a:有单值的差异行,成对累积分录行(盘盈:借库存 贷 5200;盘亏反向)。
            -- 无值(未计价进料 / 无成本产出)只调量不入账。
            -- PROC-COST-2:v_value 现在是【单位落地成本】,两支共用它 —— 见上。
            IF v_value IS NOT NULL THEN
                v_amt := round(abs(v_delta) * v_value, 2);
                IF v_amt <> 0 THEN
                    IF v_delta > 0 THEN
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', '5200',     'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt);
                    ELSE
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', '5200',     'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt);
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;

    UPDATE stocktakes
    SET status = 'posted', posted_at = now(), updated_by = v_user, updated_at = now()
    WHERE id = p_stocktake_id;

    -- cut 2a:一张分录覆盖全部有值差异行(每行自成一对,天然自平)
    IF jsonb_array_length(v_je_lines) >= 2 THEN
        PERFORM post_journal_entry(
            CURRENT_DATE,
            'Stocktake ' || v_st.code,
            'stocktake', p_stocktake_id,
            v_je_lines);
    END IF;

    -- ★ APR-3:留痕。恒 approved、level 恒 NULL(理由在文件抬头)。
    PERFORM record_approval_decision('stocktake', p_stocktake_id, 'approved', NULL::smallint,
        format('盘点过账:%s 行有差异,合计 %s', v_lines_adjusted, v_total_delta));

    RETURN jsonb_build_object(
        'stocktake_id', p_stocktake_id,
        'code', v_st.code,
        'lines_total', v_lines_total,
        'lines_adjusted', v_lines_adjusted,
        'total_delta', v_total_delta
    );
END;
$function$;


-- ════════════════════════════════════════════════════════════════════════
-- db/functions/release_work_order.sql
-- ════════════════════════════════════════════════════════════════════════
-- db/functions/release_work_order.sql
-- 放行一张工单。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ APR-2(2026-09-22):这里【曾经】有一句按级别授权的检查,而它是一把锁 ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- WO-1b 的推理只错了一步,而那一步没有任何东西在看:它选了"层级 1",
-- 却没有问【第一级那个角色的人,持不持有 module.processing.edit】。
-- 实测(2026-09-22,以 postgres 读 user_roles / role_permissions / auth.users 基表,
-- 外加 require_approver_for 自己逐人给出的答案):
--     一级 = finance,唯一真持有人 chooer@evoltrya.test
--     module.processing.edit 的持有人 = admin · phua · sandra · vince
--     ★ 交集 = 空
-- 于是 Tim 在 2026-09-22 12:25:06 打开审批的那一刻起,
-- **线上没有任何人放行得了一张工单** —— 而屏幕上出现的是
-- 「APPROVAL_NOT_AUTHORISED|1|finance」,一句听起来像"你级别不够"、
-- 实际上对每一个人都成立的话。当时 work_orders 的 draft = 0,所以没有单据卡住;
-- 下一张就再也放行不了。**WO-1b 写下那一行时,三道闸全绿。**
--
-- ★ Tim 的裁定(Q1,2026-09-22)——【修订】了他自己早前那条"没有金额的单据
--   一律走一级":**按角色分级只管【带钱的单据】。** 不带钱的单据,谁能批仍由
--   它自己的模块权限说了算。工单没有金额,所以它回到 module.processing.edit。
-- ☞ 代价照直说:**工单少了一道名义上的一级闸,而那道闸【谁都过不去】。**
--   换来的是这条链重新走得通。真要给工单一个独立的审批人,那是一次建模改动
--   (给它自己的审批角色),不是把那一句放回来。登记在 docs/forward-queue.md。
-- ★ 而【下一次不会再靠人看出来】:approval_gate_intersections() 逐条断言
--   "这条链真的有人批得动",guard_approvals_switch 在【开】的那一刻按名拒。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ⚠★【为什么这一整段写在函数体【外面】】★⚠
-- ════════════════════════════════════════════════════════════════════════════
-- db/fixtures/203 的 P 臂与本刀迁移的自证 ⑥ 都断言
--     pg_proc.prosrc NOT LIKE '%require_approver_for%'
-- —— 而 **prosrc 里是带注释的**。第一版把这段解释写在 BEGIN 之后,
-- 于是那条断言被【这段解释自己】点亮,fixture 当场红。
-- ☞ 这就是 AGENTS.md「一句注释可以污染将来对它自己的计数」那一条,
--   而本刀在同一天里撞了它两次(另一次在 app/finance/financeErrorCodes.ts:
--   注释里一个带引号的码被 check-i18n 的 tsSet 当成了真的码)。
-- **要解释一件"这里【没有】什么"的事,就不要在它旁边写出那个名字。**
--
-- NOTE: introduced by db/migrations/2026-08-16-wo1b-*.sql;
-- 按级别授权那一句由 db/migrations/2026-09-22-apr2-self-approval-and-the-approver-that-nobody-is.sql 摘除。

CREATE OR REPLACE FUNCTION public.release_work_order(p_work_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_wo      work_orders%ROWTYPE;
    v_appr_on boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status <> 'draft' THEN
        RAISE EXCEPTION 'WO_NOT_DRAFT|%|%', v_wo.code, v_wo.status;
    END IF;

    -- ★ APR-2:四眼。判据只有一份定义(forbid_self_approval)。
    -- 【只有一条腿】—— 工单没有"这张单说的是谁"(它说的是一批料,不是一个人),
    -- 所以第二个参数是 NULL,而 NULL 一律不匹配。不硬塞一个主语进去。
    PERFORM forbid_self_approval(v_wo.created_by, NULL::uuid);

    -- 【放行是那个要有人负责的动作】(WO-1b)Doc 2 点名要"who approved the work
    -- order"。可审批的是放行 —— 不是新建(草稿谁都可以写),也不是收工(事后记录)。
    --
    -- ★ APR-2:谁能放行,由 module.processing.edit 说了算 —— 本函数【不】按角色
    --   分级。工单没有金额,而按角色分级只管带钱的单据(Tim 的 Q1 裁定)。
    --   ☞ 这里原先有一句按级别授权的检查,而它在线上是一把【谁都过不去】的锁。
    --     整段来龙去脉写在本文件的抬头 —— **刻意写在函数体外面**,
    --     见抬头最后一段说明为什么。

    UPDATE work_orders
       SET status = 'released', updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, changed_by)
    VALUES (p_work_order_id, 'released', v_user);

    -- 【留痕要说实话】—— 而 APR-3(Tim 的 Q7)把"实话"这一句本身改了。
    -- ★ 两条分支现在写的是【同一个决定值】:放行是一个人按下去的动作,
    --   审批开着还是关着都是;开关只改变"有没有一道按级别的授权",
    --   不改变"有没有人做过这个决定"。
    -- ★ 层级恒 NULL,不写 1。此前写的是 1,而那是一句【假记录】——
    --   这条路上【没有跑过任何一级授权检查】(上面那一段说明了为什么),
    --   于是 level = 1 会让留痕声称发生过一件没有发生的事。
    --   与 HR 三条链同形:它们也一律 NULL(approval_log 的 level 列注释)。
    PERFORM record_approval_decision('work_order', p_work_order_id, 'approved', NULL::smallint,
        CASE WHEN v_appr_on THEN NULL
             ELSE '审批流未启用(finance_settings.approvals_enabled = false)—— 没有按级别的授权步骤,而放行是这个人按下去的' END);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'status', 'released', 'approvals_enabled', v_appr_on);
END;
$function$

;


-- ════════════════════════════════════════════════════════════════════════
-- db/functions/guard_approvals_switch.sql
-- ════════════════════════════════════════════════════════════════════════
-- db/functions/guard_approvals_switch.sql
-- ════════════════════════════════════════════════════════════════════════
-- db/functions/guard_approvals_switch.sql
-- SOD-1:审批开关的两道闸 —— 把"开着但没配"变成一个【到不了】的状态。
--
-- docs/approvals-scoping.md 记着三个状态,其中"on, policy unset → 拒绝路由"。
-- 那个状态会把在途单据搁死:create_purchase_order 照常生成 pending 的单,
-- 而 approve_purchase_order 撞上 APPROVAL_LEVEL1_ROLE_NOT_SET —— 批不了也收不了货。
-- 所以这里做成【到不了】,而不是【到了会拒绝】。
--
-- 【反方向那一半才是真正会搁死人的】关掉开关时,已经 pending 的单会永远停在
-- pending(approve_purchase_order 抛 APPROVALS_NOT_ENABLED)。所以关闭同样有闸,
-- 并且【点名】还剩几张、是哪几张 —— 拒绝要给出路,不是给一堵墙。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql.

CREATE OR REPLACE FUNCTION public.guard_approvals_switch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_missing text[] := '{}';
    v_pending integer;
    v_codes   text;
    v_lvl     integer;
    v_role    text;
    v_total   integer;
    v_real    integer;
    v_gap     record;
    v_doc     record;
    v_thr     numeric;
BEGIN
    -- ── 开:策略必须齐,两级都必须【有人批】而且【看得见金额】 ──
    IF NEW.approvals_enabled AND NOT OLD.approvals_enabled THEN
        IF NEW.approval_level1_role_code IS NULL THEN
            v_missing := v_missing || 'approval_level1_role_code'::text;
        END IF;
        IF NEW.approval_threshold_base IS NULL THEN
            v_missing := v_missing || 'approval_threshold_base'::text;
        END IF;
        IF NEW.approval_level2_role_code IS NULL THEN
            v_missing := v_missing || 'approval_level2_role_code'::text;
        END IF;
        IF cardinality(v_missing) > 0 THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_INCOMPLETE|%', array_to_string(v_missing, ', ');
        END IF;

        -- 两级走【同一段】判断 —— 两级不同形正是上一版留下的问题。
        FOR v_lvl IN 1..2 LOOP
            v_role := CASE v_lvl WHEN 1 THEN NEW.approval_level1_role_code
                                 ELSE NEW.approval_level2_role_code END;

            SELECT count(*) INTO v_real FROM real_role_holders(v_role);

            IF v_real = 0 THEN
                -- 【分辨两种零】总数是从 user_roles 上数的(未撤销的授权),
                -- 与 real 的差,正好就是"有人持有,但他登录不了"。
                SELECT count(*) INTO v_total
                  FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                 WHERE r.code = v_role AND r.is_active AND ur.revoked_at IS NULL;

                IF v_total > 0 THEN
                    -- ★ 3c 的中间态:角色【有人】,但那个人【登录不了】。
                    --   报成"没有持有人"会把人送去再授一次权,而那不会改变任何事。
                    RAISE EXCEPTION 'APPROVALS_LEVEL%_HOLDER_CANNOT_SIGN_IN|%|%', v_lvl, v_role, v_total;
                ELSE
                    RAISE EXCEPTION 'APPROVALS_LEVEL%_ROLE_UNHELD|%', v_lvl, v_role;
                END IF;
            END IF;

            -- R4/4b:看不见金额的角色批不了它该批的东西 —— 同一时刻、同一理由。
            IF NOT role_can_see_amounts(v_role) THEN
                RAISE EXCEPTION 'APPROVALS_LEVEL%_ROLE_CANNOT_SEE_AMOUNTS|%', v_lvl, v_role;
            END IF;
        END LOOP;

        -- ════════════════════════════════════════════════════════════════════
        -- ★★★ APR-2:每一条接上引擎的链,都必须【真的有人批得动】 ★★★
        -- ════════════════════════════════════════════════════════════════════
        -- 上面那一段问的是"这一级的角色有没有真人、看不看得见金额" ——
        -- 两个都是【关于角色的】问题。而它们全部为真时,这条链仍然可以是死的:
        -- 一个持有那个角色的人,可能根本进不了那张单据所在的模块。
        -- ★ 这不是假设:WO-1b 就是这么在线上造出一把锁的,而当时三道闸全绿
        --   (逐项实测写在 db/functions/approval_chain_gates.sql 的抬头)。
        --
        -- ★★ 传的是 NEW 的两个角色码,【不能】让它自己去读表:本触发器是
        --    BEFORE UPDATE,而策略四列是一起写的 —— 读表读到的是 OLD,
        --    于是这道闸会去判上一版策略,并且全绿。
        --
        -- 【为什么是拒绝,不是忠告】与本函数抬头那句话同一条:把"开着但没人批"
        -- 做成一个【到不了】的状态,而不是【到了才发现】。后者的代价是一批
        -- 永远停在 pending 的单据,而开关此时已经关不掉了(下面那道闸)。
        FOR v_gap IN
            SELECT i.action_function, i.level, i.role_code,
                   array_to_string(i.gate_permissions, '+') AS perms
              FROM approval_gate_intersections(NEW.approval_level1_role_code,
                                               NEW.approval_level2_role_code) i
             WHERE i.approvers = 0
             ORDER BY i.action_function, i.level
             LIMIT 1
        LOOP
            RAISE EXCEPTION 'APPROVALS_CHAIN_HAS_NO_APPROVER|%|%|%|%',
                v_gap.action_function, v_gap.level, v_gap.role_code, v_gap.perms;
        END LOOP;
    END IF;

    -- ── 关:会被永远搁死的在途单据,先点名 ──
    -- ★★ APR-3(Tim 的 Q6):判据从"数采购单"换成 approval_pending_documents()
    --    里 blocks_disable 为真的那些 —— 而今天这两件事【算出同一个数】。
    --    换它不是为了换出一个新数字,是为了让这道闸与屏幕读【同一支函数】:
    --    APR-3 把屏幕上的在途张数放宽到了每一条链,而这道闸【没有】跟着放宽,
    --    两个数从此不同。它们必须出自同一个定义,否则下一个读代码的人无从
    --    知道哪一个才是拦人的那个。
    -- ★【为什么不是"每一条链都算"】那会当场把审批锁死在开着的状态:线上今天
    --    有一张 submitted 的报销单,而一张 submitted 的报销单在审批关着时
    --    【照样批得了】(decide_expense_claim 只有分档那一步是条件性的)。
    --    判别的那一句话写在 approval_pending_documents 的抬头,
    --    下一刀接一条链时照它回答一次:**这条链的决定函数,在审批关着的时候
    --    还跑不跑得动?**
    IF OLD.approvals_enabled AND NOT NEW.approvals_enabled THEN
        SELECT count(*)::integer, string_agg(d.code, ', ' ORDER BY d.code)
          INTO v_pending, v_codes
          FROM approval_pending_documents() d
         WHERE d.blocks_disable;
        IF COALESCE(v_pending, 0) > 0 THEN
            RAISE EXCEPTION 'APPROVALS_CANNOT_DISABLE_WITH_PENDING|%|%', v_pending, v_codes;
        END IF;
    END IF;

    -- ── 开着的时候不许把策略值抽走 ──
    -- ★★ APR-3 把这一段【提到 WOULD_STRAND 之前】,而这不是排版:
    --   抽走门槛(NEW 为 NULL)时,下面那一段会拿一个 NULL 门槛去重新分档,
    --   于是每一张在途单据都被当成二级判 —— 二级碰巧没有人批得动时,
    --   它会抛出 WOULD_STRAND,而**这次编辑真正的毛病是"你不能在开着的时候
    --   把这个值抽走"**。☞ 一条更含糊的拒绝盖住一条更准的拒绝,
    --   在屏幕上就是一句指错路的话。**结构上就不合法的那一种,先拒。**
    IF NEW.approvals_enabled THEN
        IF NEW.approval_level1_role_code IS NULL AND OLD.approval_level1_role_code IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_level1_role_code';
        END IF;
        IF NEW.approval_threshold_base IS NULL AND OLD.approval_threshold_base IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_threshold_base';
        END IF;
        IF NEW.approval_level2_role_code IS NULL AND OLD.approval_level2_role_code IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_level2_role_code';
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★★ APR-3:APPROVALS_POLICY_WOULD_STRAND —— 一条【定向】拒绝 ★★★
    -- ════════════════════════════════════════════════════════════════════════
    -- Tim 的 N8 裁定:**不做一刀切的锁。** 最需要改策略的时刻,正是某条链配错了、
    -- 单据卡住的时刻;锁住它会把一个救得回来的状态变成一个救不回来的状态,
    -- 而那正是本函数抬头那句「拒绝要给出路,不是给一堵墙」。
    --
    -- ★【它判的是什么】审批【开着】,而这次编辑动了角色或门槛:拿【新策略】
    --   把每一张在途单据重新分一次档,再问那一档那条链有没有人批得动。
    --   有一张落在没人批得动的档上 → 按名拒,并【点出那张单、那一级、那个角色】。
    --   其余一律放行 —— 包括"把某一级换成一个更窄的角色"这种一般性的改动,
    --   只要今天在途的这些单据都还有人批。
    --
    -- ★★【为什么必须拿 NEW 的门槛,而不是让 approval_level_for 自己去读表】
    --   本触发器是 BEFORE UPDATE:读 finance_settings 读到的是 OLD 那一行。
    --   于是"重新分档"会拿【旧门槛】去分,并且全绿 —— 与上面那道
    --   APPROVALS_CHAIN_HAS_NO_APPROVER 传 NEW 角色码是逐字同一个陷阱。
    --   分档那个比较号只有一份定义(approval_level_at),这里传参用它。
    --
    -- ★【金额分不出来的那一张,按二级判】Tim 的 N4 原话:「不明金额的安全方向
    --   是往上」。一张查不到牌价的报销单分不了档,这里不放它过去,也不发明
    --   一个新规矩 —— 复用那一条。今天线上没有这样的单据。
    --
    -- ★【它不重复定义"谁批得动"】那一句仍然只有 approval_gate_intersections()
    --   一份实现,这里只是按 (subject_type, level) 去查它的答案。
    IF NEW.approvals_enabled AND OLD.approvals_enabled
       AND (NEW.approval_level1_role_code IS DISTINCT FROM OLD.approval_level1_role_code
         OR NEW.approval_level2_role_code IS DISTINCT FROM OLD.approval_level2_role_code
         OR NEW.approval_threshold_base   IS DISTINCT FROM OLD.approval_threshold_base) THEN
        v_thr := NEW.approval_threshold_base;
        FOR v_doc IN
            SELECT d.subject_type, d.code,
                   CASE WHEN d.amount_base IS NULL OR v_thr IS NULL
                        THEN 2::smallint
                        ELSE approval_level_at(d.amount_base, v_thr) END AS lvl
              FROM approval_pending_documents() d
             ORDER BY d.subject_type, d.code
        LOOP
            FOR v_gap IN
                SELECT i.action_function, i.role_code,
                       array_to_string(i.gate_permissions, '+') AS perms
                  FROM approval_gate_intersections(NEW.approval_level1_role_code,
                                                   NEW.approval_level2_role_code) i
                 WHERE i.subject_type = v_doc.subject_type
                   AND i.level = v_doc.lvl
                   AND i.approvers = 0
                 ORDER BY i.action_function
                 LIMIT 1
            LOOP
                RAISE EXCEPTION 'APPROVALS_POLICY_WOULD_STRAND|%|%|%|%|%',
                    v_doc.code, v_doc.lvl, v_gap.role_code, v_gap.action_function, v_gap.perms;
            END LOOP;
        END LOOP;
    END IF;

    RETURN NEW;
END;
$function$;


-- ════════════════════════════════════════════════════════════════════════
-- db/functions/approvals_readiness.sql
-- ════════════════════════════════════════════════════════════════════════
-- db/functions/approvals_readiness.sql
-- SOD-1:审批开关【能不能开】,以及开不了的话缺哪几样 —— 屏幕与闸读同一份判据。
-- 一个屏幕上说"可以开"、闸却拒绝的系统,比两者都拒绝更坏(fixture 127 C8 钉这一条)。
--
-- 【数的是【真的登录得了的】持有人】线上有 66 条 user_roles 的 user_id 在
-- auth.users 里根本不存在(docs/known-issues.md 的 ACCOUNTS-STALE 条)。
-- 一个只由幽灵持有的角色,是一个永远不会有人来批的队列。
--
-- 【它答不了的那一件,不假装答得了】"是否存在第二个真人",本函数【不判】——
-- 线上五个 test.local 走查账号都持 admin,任何按账号数的判据都会因为它们而通过,
-- 也就是为了错的理由通过。那一条留在 docs/fresh-install-checklist.md 里由人判断。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql;
-- 内检的权限码由 db/migrations/2026-09-22-apr1-the-approvals-switch-gets-a-door.sql
-- 从 module.finance.view 换成 action.manage_permissions(APR-0 的 N6)。
--
-- 【fu2:一个【非阻塞】的忠告字段 level1_holders_who_cannot_raise】
-- 独立复测量到:`finance` 角色自己就持 module.purchasing.edit,于是被裁定的
-- 一级审批角色里,"结构上提不了单"的持有人是 **0** 个。
-- **它报告,不拦** —— 做成拒绝会让 Tim 自己裁定的策略开不起来,
-- 而一道拦住既定决定的闸是一道会被绕过去的闸。留给 Tim 的三选一写在
-- db/migrations/2026-08-24-sod1-fu2-*.sql 的抬头。
--
-- 【fu2 同时补上了调用者检查】gate 的 B2 抓到它是 SECURITY DEFINER 且无检查而可调用。
-- 它【要】被 /finance/settings 调用,所以走的是"加检查"这一半,不是"收权限"那一半
-- (另外三支内层函数走的是后者,见 db/views/zzz_function_grants.sql)。

CREATE OR REPLACE FUNCTION public.approvals_readiness()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s          record;
    v_blocking   text[] := '{}';
    v_l1_total   integer := 0;  v_l1_real integer := 0;
    v_l2_total   integer := 0;  v_l2_real integer := 0;
    v_l1_norais  integer := 0;
    v_l1_sees    boolean := false;
    v_l2_sees    boolean := false;
    v_pending    integer := 0;
    v_blocking_p integer := 0;
    v_pendchains jsonb   := '[]'::jsonb;
    v_chains     jsonb   := '[]'::jsonb;
    v_deadchains integer := 0;
BEGIN
    -- ★ APR-1(N6):此前这里要求 module.finance.view,而 /settings/approvals
    --   那一页的闸是 action.manage_permissions —— **两个码守同一块屏幕**。
    --   今天 admin 与 cco 两个码都持有,所以看不出问题;哪一天有人持前者而不持
    --   后者,那一页会渲染成 readError,而那读起来像"读不到",不像"你没权限"。
    --   这支函数的抬头自己就写着"屏幕与闸读同一份判据"。
    PERFORM require_permission('action.manage_permissions');

    SELECT approvals_enabled, approval_level1_role_code, approval_threshold_base,
           approval_level2_role_code
      INTO v_s FROM finance_settings LIMIT 1;

    -- ── 一级 ──
    IF v_s.approval_level1_role_code IS NULL THEN
        v_blocking := v_blocking || 'approval_level1_role_code'::text;
    ELSE
        SELECT count(*) INTO v_l1_real FROM real_role_holders(v_s.approval_level1_role_code);
        SELECT count(*) INTO v_l1_total
          FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE r.code = v_s.approval_level1_role_code AND r.is_active AND ur.revoked_at IS NULL;
        v_l1_sees := role_can_see_amounts(v_s.approval_level1_role_code);

        IF v_l1_real = 0 AND v_l1_total > 0 THEN
            v_blocking := v_blocking || 'approval_level1_holder_cannot_sign_in'::text;
        ELSIF v_l1_real = 0 THEN
            v_blocking := v_blocking || 'approval_level1_role_has_no_real_holder'::text;
        END IF;
        IF NOT v_l1_sees THEN
            v_blocking := v_blocking || 'approval_level1_role_cannot_see_amounts'::text;
        END IF;

        -- 【报告,不拦】这个角色的持有人里,有几个是【提不了采购单】的(SOD-1 fu2)。
        SELECT count(*) INTO v_l1_norais
          FROM real_role_holders(v_s.approval_level1_role_code) h
         WHERE NOT EXISTS (
            SELECT 1 FROM user_roles ur2
              JOIN roles r2 ON r2.id = ur2.role_id
              JOIN role_permissions rp ON rp.role_id = r2.id
             WHERE ur2.user_id = h.user_id AND r2.is_active AND ur2.revoked_at IS NULL
               AND rp.permission_code = 'module.purchasing.edit');
    END IF;

    IF v_s.approval_threshold_base IS NULL THEN
        v_blocking := v_blocking || 'approval_threshold_base'::text;
    END IF;

    -- ── 二级:与一级【同等对待】,这正是本刀要的 ──
    IF v_s.approval_level2_role_code IS NULL THEN
        v_blocking := v_blocking || 'approval_level2_role_code'::text;
    ELSE
        SELECT count(*) INTO v_l2_real FROM real_role_holders(v_s.approval_level2_role_code);
        SELECT count(*) INTO v_l2_total
          FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE r.code = v_s.approval_level2_role_code AND r.is_active AND ur.revoked_at IS NULL;
        v_l2_sees := role_can_see_amounts(v_s.approval_level2_role_code);

        IF v_l2_real = 0 AND v_l2_total > 0 THEN
            v_blocking := v_blocking || 'approval_level2_holder_cannot_sign_in'::text;
        ELSIF v_l2_real = 0 THEN
            v_blocking := v_blocking || 'approval_level2_role_has_no_real_holder'::text;
        END IF;
        IF NOT v_l2_sees THEN
            v_blocking := v_blocking || 'approval_level2_role_cannot_see_amounts'::text;
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★ APR-3(Tim 的 Q6):在途张数放宽到【每一条接上引擎的链】,
    --    而 can_disable 仍然只看【关掉之后会批不动的那些】 ★★
    -- ════════════════════════════════════════════════════════════════════════
    -- 两个数长得一样,问的不是同一件事,所以它们是两个字段 ——
    -- 而【两个都出自同一支函数】(approval_pending_documents),于是屏幕与闸
    -- 不可能各读一份判据。那一句判别写在那个函数的抬头,下一刀照它回答一次:
    --   **这条链的决定函数,在审批关着的时候还跑不跑得动?**
    --
    -- ★【为什么不把 can_disable 一起放宽】线上今天有一张 submitted 的报销单,
    --   而报销在审批关着时照常批得了 —— 把它算进去会让审批从此【关不掉】,
    --   一个没有人要求过的新约束,而且它看起来会像一个 bug。
    --
    -- ⚠【pending_purchase_orders 这个字段名保留】它喂的是屏幕上那一句
    --   「关掉会怎样」,而那句话说的正是采购单。改名要连着文案一起改,
    --   而本刀没有理由动它 —— 它今天仍然逐字等于 blocks_disable 的那个数,
    --   因为今天只有采购单 blocks_disable。
    SELECT count(*) FILTER (WHERE d.subject_type = 'purchase_order'),
           count(*) FILTER (WHERE d.blocks_disable)
      INTO v_pending, v_blocking_p
      FROM approval_pending_documents() d;

    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'subject_type'), '[]'::jsonb)
      INTO v_pendchains
      FROM (
        SELECT jsonb_build_object(
                   'subject_type',    d.subject_type,
                   'pending',         count(*),
                   'blocks_disable',  bool_or(d.blocks_disable),
                   -- 分不出档的那些单独报出来,不混进计数里读成零
                   'amount_unknown',  count(*) FILTER (WHERE d.amount_base IS NULL)) AS x
          FROM approval_pending_documents() d
         GROUP BY d.subject_type
      ) g;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★ APR-2:屏幕上也要看得见「这条链真的有人批得动吗」 ★★
    -- ════════════════════════════════════════════════════════════════════════
    -- 本函数的抬头写着"屏幕与闸读同一份判据"。APR-2 给 guard_approvals_switch
    -- 加了一道新闸(链的模块门 ∩ 那一级的角色持有人 = 空 → 按名拒),
    -- ★ 所以那道闸【必须】同时出现在这里 —— 否则就又是一块说"可以开"、
    --   而闸会拒绝的屏幕,也就是本函数存在的全部理由的反面。
    --
    -- ⚠ 这里【不】传参,读的是已经落库的那两个角色码 —— 面板说的是
    --   "以现在这条策略,能不能开"。闸那一侧传的是 NEW(它判的是正要写下去的
    --   那条策略),两者的差别写在 approval_gate_intersections 的抬头。
    -- ★★ 只在【两级角色都已经设好】时才问这个问题 —— 而这不是为了少说一句话,
    --    是为了与闸【同序】:guard_approvals_switch 先抛 APPROVALS_POLICY_INCOMPLETE,
    --    根本走不到这道新闸。策略整个没设时,role_code 是 NULL,求交必然全 0,
    --    于是 blocking 会多出第四条 —— 一句【真的、但重复的】话,
    --    它说的还是上面那三条已经说过的事,而它会把"策略没设"与
    --    "策略设好了却没有人批得动"这两种完全不同的状态搅在一起。
    IF v_s.approval_level1_role_code IS NOT NULL
       AND v_s.approval_level2_role_code IS NOT NULL THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'subject_type',     i.subject_type,
                   'action_function',  i.action_function,
                   'level',            i.level,
                   'role_code',        i.role_code,
                   'gate_permissions', to_jsonb(i.gate_permissions),
                   'approvers',        i.approvers)
                   ORDER BY i.subject_type, i.action_function, i.level), '[]'::jsonb),
               count(*) FILTER (WHERE i.approvers = 0)
          INTO v_chains, v_deadchains
          FROM approval_gate_intersections() i;

        IF v_deadchains > 0 THEN
            v_blocking := v_blocking || 'approval_chain_has_no_approver'::text;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'enabled',                 v_s.approvals_enabled,
        'level1_role_code',        v_s.approval_level1_role_code,
        'level1_holders_total',    v_l1_total,
        'level1_real_holders',     v_l1_real,
        'level1_can_see_amounts',  v_l1_sees,
        'level1_holders_who_cannot_raise', v_l1_norais,
        'threshold_base',          v_s.approval_threshold_base,
        'level2_role_code',        v_s.approval_level2_role_code,
        'level2_holders_total',    v_l2_total,
        'level2_real_holders',     v_l2_real,
        'level2_can_see_amounts',  v_l2_sees,
        'pending_purchase_orders', v_pending,
        -- ★ APR-3:逐链的在途张数(屏幕用),与【会挡住关闭的】那个数(闸用)。
        --   两个都从 approval_pending_documents() 来 —— 一份判据,两个问题。
        'pending_by_chain',        v_pendchains,
        'pending_blocking_disable', v_blocking_p,
        -- ★ APR-2:逐条给出"这条链有几个人批得动",而不是一个布尔 ——
        --   与两级持有人给两个数、不给一个布尔是同一条理由:
        --   要分开的是"哪一条链死了、死在哪一级、缺的是哪个码"。
        'chain_gates',             v_chains,
        'chains_without_approver', v_deadchains,
        'blocking',                to_jsonb(v_blocking),
        'can_enable',              (NOT v_s.approvals_enabled AND cardinality(v_blocking) = 0),
        -- ★ APR-3:判据换成【会被搁死的那些】,与 guard_approvals_switch 的
        --   关闭那一支逐字同源(它读的是同一支函数的同一个过滤条件)。
        'can_disable',             (v_s.approvals_enabled AND v_blocking_p = 0),
        -- 跟着数字走的那句话,不只躺在文档里(与 PARTY-1 的处置同形)
        'no_deputy_by_decision',   true);
END;
$function$;

COMMENT ON FUNCTION public.approvals_readiness() IS
'SOD-1,CHAIN-BUILD-1 改写(2026-08-30):审批开关能不能开,以及开不了缺哪几样 —— 屏幕与闸读同一份判据。★两级【同等对待】★:各返回 holders_total(未撤销的授权数)与 real_holders(真的登录得了的),**两个数而不是一个数加一个布尔**,因为要分开的是三种状态:没人持有 / 有人持有但登录不了 / 有能干活的人 —— 中间那一种若报成"没有持有人",操作的人会去再授一次权,而那个角色已经授过了。持有人判据只有一处定义(real_role_holders)。另报每一级的 can_see_amounts(R4)。**没有代理人、没有升级**:某一级没人就停在那一级,这是裁定,不是遗漏(no_deputy_by_decision 跟着返回值走)。';


-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ 自证 —— 每一条都是【这支迁移自己】跑出来的,不是事后另一个会话读的 ★★★
-- ════════════════════════════════════════════════════════════════════════════
DO $proof$
DECLARE
    b          record;
    v_enabled  boolean;
    v_log      bigint;
    v_leave    bigint; v_mc bigint; v_rev bigint; v_po bigint; v_wo bigint;
    v_clm      bigint; v_st bigint;
    v_registry text[]; v_catalog text[];
    v_rows     integer; v_dead integer;
    v_perms    text[];
    v_src      text;
    v_n        integer;
    v_pend     integer; v_block integer;
BEGIN
    SELECT * INTO b FROM apr3_before;

    -- ① 审批开关一刻也没有被碰过 ------------------------------------------
    SELECT approvals_enabled INTO v_enabled FROM finance_settings LIMIT 1;
    IF v_enabled IS DISTINCT FROM b.enabled THEN
        RAISE EXCEPTION 'APR3_PROOF_1|approvals_enabled 变了:% -> %', b.enabled, v_enabled;
    END IF;

    -- ② 一行留痕都没有写 ---------------------------------------------------
    SELECT count(*) INTO v_log FROM approval_log;
    IF v_log <> b.approval_log_rows THEN
        RAISE EXCEPTION 'APR3_PROOF_2|approval_log 行数变了:% -> %', b.approval_log_rows, v_log;
    END IF;

    -- ③ 每一条链的在途张数都没有变(★ 本刀新接的两条也数进来)--------------
    SELECT count(*) INTO v_leave FROM leave_requests      WHERE status='pending'   AND deleted_at IS NULL;
    SELECT count(*) INTO v_mc    FROM medical_claims      WHERE status='submitted' AND deleted_at IS NULL;
    SELECT count(*) INTO v_rev   FROM performance_reviews WHERE status='submitted';
    SELECT count(*) INTO v_po    FROM purchase_orders     WHERE approval_status='pending' AND deleted_at IS NULL;
    SELECT count(*) INTO v_wo    FROM work_orders         WHERE status='draft';
    SELECT count(*) INTO v_clm   FROM expense_claims      WHERE status='submitted';
    SELECT count(*) INTO v_st    FROM stocktakes          WHERE status='open' AND deleted_at IS NULL;
    IF (v_leave, v_mc, v_rev, v_po, v_wo, v_clm, v_st)
       IS DISTINCT FROM (b.leave_pending, b.claims_pending, b.reviews_pending,
                         b.po_pending, b.wo_draft, b.claim_pending, b.stocktake_open) THEN
        RAISE EXCEPTION 'APR3_PROOF_3|在途张数变了:leave %->% medclaims %->% reviews %->% po %->% wo %->% claims %->% stocktakes %->%',
            b.leave_pending, v_leave, b.claims_pending, v_mc, b.reviews_pending, v_rev,
            b.po_pending, v_po, b.wo_draft, v_wo, b.claim_pending, v_clm, b.stocktake_open, v_st;
    END IF;

    -- ④ ★ 名册 vs 目录:逐字相等(APR-2 立的那条,本刀继承)-----------------
    SELECT array_agg(DISTINCT action_function ORDER BY action_function)
      INTO v_registry FROM approval_chain_gates();
    SELECT array_agg(DISTINCT p.proname::text ORDER BY p.proname::text)
      INTO v_catalog
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prosrc LIKE '%require_approver_for%'
       AND p.proname <> 'require_approver_for';
    IF v_registry IS DISTINCT FROM v_catalog THEN
        RAISE EXCEPTION 'APR3_PROOF_4|名册与目录对不上:名册=% 目录=%', v_registry, v_catalog;
    END IF;
    IF coalesce(cardinality(v_registry), 0) = 0 THEN
        RAISE EXCEPTION 'APR3_PROOF_4|名册是空的 —— 一条都没有接上引擎,这不对';
    END IF;
    -- ★ 而且报销单【确实】进去了 —— 上面那条比对在两边都漏掉它时照样通过
    IF NOT ('decide_expense_claim' = ANY(v_registry)) THEN
        RAISE EXCEPTION 'APR3_PROOF_4|decide_expense_claim 不在名册里 —— 本刀的主体没有接上';
    END IF;

    -- ⑤ ★★ 报销那条链的门是 view+prices,【不是】edit ------------------------
    -- 这一条是本刀最值钱的一格:写成 edit 的话今天照样全绿,
    -- 而 Tim 一拿到独立的 CFO 账号,二级当场归零。
    FOR v_n IN 1..2 LOOP
        SELECT gate_permissions INTO v_perms FROM approval_chain_gates()
         WHERE subject_type = 'expense_claim' AND level = v_n::smallint;
        IF v_perms IS NULL THEN
            RAISE EXCEPTION 'APR3_PROOF_5|报销链第 % 级不在名册里', v_n;
        END IF;
        IF NOT ('module.finance.view' = ANY(v_perms) AND 'data.view_prices' = ANY(v_perms)) THEN
            RAISE EXCEPTION 'APR3_PROOF_5|报销链第 % 级的门应当是 view+prices,实得 %', v_n, v_perms;
        END IF;
        IF 'module.finance.edit' = ANY(v_perms) THEN
            RAISE EXCEPTION 'APR3_PROOF_5|★ 报销链第 % 级的门写了 module.finance.edit —— 它今天会全绿,而独立 CFO 账号一落地就归零', v_n;
        END IF;
    END LOOP;

    -- ⑥ 每一条接上引擎的链,都真的有人批得动 --------------------------------
    SELECT count(*)::integer, count(*) FILTER (WHERE approvers = 0)::integer
      INTO v_rows, v_dead FROM approval_gate_intersections();
    IF v_rows = 0 THEN
        RAISE EXCEPTION 'APR3_PROOF_6|求交一行都没有 —— 一个瞎掉的判据与一棵干净的树都打印 0';
    END IF;
    IF v_dead > 0 THEN
        RAISE EXCEPTION 'APR3_PROOF_6|有 % 条链没有人批得动 —— 审批从此关掉就开不回来', v_dead;
    END IF;

    -- ⑦ 三支决定函数都接上了那支唯一的四眼判据 ------------------------------
    FOR v_src IN
        SELECT p.proname::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname='public'
           AND p.proname IN ('decide_expense_claim','post_stocktake')
           AND p.prosrc NOT LIKE '%forbid_self_approval%'
    LOOP
        RAISE EXCEPTION 'APR3_PROOF_7|% 没有调 forbid_self_approval', v_src;
    END LOOP;

    -- ⑧ ★ 工单那一行 auto_approved 真的没有了 —— 读的是【目录】,不是这个文件
    SELECT p.prosrc INTO v_src
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname='public' AND p.proname='release_work_order';
    IF v_src LIKE '%auto_approved%' THEN
        RAISE EXCEPTION 'APR3_PROOF_8|release_work_order 里还在写 auto_approved —— 而放行是一个人按下去的';
    END IF;

    -- ⑨ ★★ 在途:两个问法算出两个数,而它们出自【同一支函数】-----------------
    -- open 的盘点【不许】被数成在途(Tim 的 Q4);报销【在】里面而不挡关闭。
    SELECT count(*)::integer, count(*) FILTER (WHERE blocks_disable)::integer
      INTO v_pend, v_block FROM approval_pending_documents();
    SELECT count(*) INTO v_n FROM approval_pending_documents() WHERE subject_type='stocktake';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'APR3_PROOF_9|open 的盘点被数成了在途待批(% 张)—— open 是"正在点",不是"在等人批"', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM approval_pending_documents()
     WHERE subject_type='expense_claim' AND blocks_disable;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'APR3_PROOF_9|报销单被标成"会挡住关闭"(% 张)—— 它在审批关着时照常批得了,标上去会让审批从此关不掉', v_n;
    END IF;
    -- 在途那个数必须【真的数到了东西】,否则上面两条都是空转
    IF v_pend = 0 THEN
        RAISE EXCEPTION 'APR3_PROOF_9|在途一张都没有数到 —— 线上此刻至少有一张 submitted 的报销单,这说明判据瞎了';
    END IF;

    -- ⑩ ★ 分档那个比较号仍然只有一份定义,而【产品入口】的答案没有变 --------
    -- 搬家搬错了的话,这三个数里"恰好等于门槛"那一个会当场变。
    IF approval_level_for(999.99::numeric)  <> 1
       OR approval_level_for(1000.00::numeric) <> 2
       OR approval_level_for(1000.01::numeric) <> 2 THEN
        RAISE EXCEPTION 'APR3_PROOF_10|分档搬家之后答案变了:999.99->% 1000.00->% 1000.01->%',
            approval_level_for(999.99::numeric), approval_level_for(1000.00::numeric), approval_level_for(1000.01::numeric);
    END IF;
    -- ★ 而且 approval_level_for 的函数体里【不再】有那个比较号(它搬走了)——
    --   少了这一条,一份"两处都写着 >=" 的实现会让上面那三个数照样通过。
    SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname='approval_level_at';
    IF v_src NOT LIKE '%>=%' THEN
        RAISE EXCEPTION 'APR3_PROOF_10|approval_level_at 里没有那个比较号 —— 判据没有搬过来';
    END IF;
    -- ★★ 承重的那一半:它在 approval_level_for 里【不再】出现。
    --   少了这一条,一份"两处各写一遍 >=" 的实现会让上面每一条都通过 ——
    --   而两处 >= 的系统,迟早有一处被改成 >,且只在恰好等于门槛那一个数上现形。
    SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname='approval_level_for';
    IF v_src LIKE '%>=%' THEN
        RAISE EXCEPTION 'APR3_PROOF_10|approval_level_for 里还有那个比较号 —— 仓库里于是有两份分档判据';
    END IF;

    RAISE NOTICE 'APR3_AFTER  enabled=% approval_log=% leave=% medclaims=% reviews=% po_pending=% wo_draft=% expense_claims_submitted=% stocktakes_open=% | chains=% dead=% pending=% blocking_disable=%',
        v_enabled, v_log, v_leave, v_mc, v_rev, v_po, v_wo, v_clm, v_st,
        v_rows, v_dead, v_pend, v_block;
    RAISE NOTICE 'APR3 自证十条全过。';
END
$proof$;

COMMIT;
