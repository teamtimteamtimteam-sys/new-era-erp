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
    PERFORM forbid_self_approval(v_c.created_by, v_c.employee_id, 'expense_claim');

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
