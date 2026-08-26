-- BANK-REC(2026-08-26):对账要对的是【余额】,不只是【行】。
-- NOTE: apply with ./db/apply_migration.sh
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这一刀补的那个洞】reconcile_statement 此前只断言一件事:没有未处理的行
-- (LINES_OUTSTANDING)。它从来不比银行的 closing_balance 与那个科目在 period_end
-- 的账面余额。于是"已对账"是【行覆盖率】的旗,不是【余额一致】的旗 ——
-- 一张报表可以在银行与总账各说各话的情况下堂堂正正地变成 reconciled。
--
-- 【差额必须【说得清】,不能只是【被挡住】】合法的差额是真实存在的(未兑现的
-- 支票、在途存款、时点差)。一道只会拒绝、不给出口的闸,人会绕过去 —— 这个仓库
-- 有成文的教训(known-issues「摘掉一条安全状态是一次无痕迹的编辑」:
-- 闸没有出口,人就把那一行删掉直到灯灭)。所以差额有两条路,不是一条:
--   ① 差额为 0 → 直接对账;
--   ② 差额不为 0 → 【逐项说明】,金额相加必须【恰好等于】差额,然后带着差额对账。
-- ★ 说明【不会让两个数字相等】★ 报表照样是 reconciled,而它身上写着
--   "这两个数差 X,原因如下"。抹平差额才是错的。
--
-- 【不设容差,而这句理由要留在原地】容差就是"带阈值的未解释差额",
-- 而上面的第②条已经给了诚实的出口。一分钱的容差是能想到的最小的一种绕法。
-- 将来有人因为一分钱的失败想"把带子放宽一点",请先读这一段。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- ① 账面余额的算法【只有一份】,两个读者共用
--
-- 【为什么不是在 reconcile_statement 里现写一段 sum()】2.2 的要求是复用而不是
-- 再实现一遍总账算术。而系统里已经有一处在算现金余额:
-- bank_reconciliation_status.ledger_balance。**它是错的**(见下面 ④),
-- 所以"复用"的正确做法是把它【提取出来修好】,让视图与新的拒绝读同一份,
-- 而不是把它抄一遍、或者在旁边写第二份对的。
--
-- 【它把"哪些行算数"这件事整个交给 journal_activity_lines】
-- 不过滤 status(冲销的原分录与冲销分录必须【都数】才净成零)、日期上界、
-- 年结开关 —— 三条规矩住在那个函数里,这里一条都不重写。
-- 本函数【只加一件事】:把金额投影到账户本币(amount_ccy),因为对账单的
-- closing_balance 记的就是本币(bank_statements 表头:currency 恒为账户本币)。
-- journal_activity_lines 的 signed_base 是【本位币 SGD】,拿它去比一张 USD
-- 报表的 closing_balance 是两种单位相减。
--
-- 【(NULL, p_as_of, true) 这三个参数不是随手填的】它逐字就是 balance_sheet
-- 的调用:资产负债表式的"截至日"余额。现金是资产负债表科目,所以年结开关为
-- true 与那张表一致 —— 一个科目的"截至 X 日余额"在系统里只能有一个意思。
-- p_as_of 传 NULL = 不设上界(视图的"截至此刻"就走这一支)。
--
-- 【invoker + STABLE + 不带 SET search_path】与 journal_activity_lines 同样是
-- 为了【可内联】。安全性靠 RLS 而不是靠"调不到":它没有调用者检查,但
-- journal_lines / journal_entries 的 SELECT 策略就是 module.finance.view,
-- 直接调它的登录用户走自己那条策略。**因此这里【不】REVOKE** ——
-- bank_reconciliation_status 是 security_invoker 视图,收了 EXECUTE 它就当场坏掉;
-- 而给页面用的是 ⑥ 那支带 require_permission 的 definer 伴生函数。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.bank_book_balance_asof(p_account_code text, p_as_of date)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
    SELECT round(COALESCE(sum(
               CASE WHEN jl.debit > 0 THEN jl.amount_ccy ELSE -jl.amount_ccy END
           ), 0), 2)
    FROM journal_activity_lines(NULL, p_as_of, true) act
    JOIN journal_lines jl ON jl.id = act.line_id
    WHERE act.account_code = p_account_code
      AND jl.currency = bank_native_currency(p_account_code);
$function$;

COMMENT ON FUNCTION public.bank_book_balance_asof(text, date) IS
'BANK-REC:银行科目在某一截止日的【账面余额,账户本币】。行的取舍全部委托给 journal_activity_lines(不过滤 status —— 冲销两侧都要数);本函数只把金额投影到 amount_ccy。p_as_of 为 NULL = 不设上界。bank_reconciliation_status 与 reconcile_statement 共用它,于是屏幕上那个数与拒绝时用的那个数不可能各错各的。';

-- ─────────────────────────────────────────────────────────────────────────────
-- ② 一次对账 = 一个【事件】,不是对账单上的几个列
--
-- 【为什么是一张表而不是几列】unreconcile_statement 一直都在:重开一张报表、
-- 改完再对一次,是【正常的更正路径】。如果那三个数字挂在 bank_statements 的列上,
-- 第二次对账会【原地覆盖第一次签下的那份】—— 而那正是"更正是一个新事件,
-- 不是一次编辑"要禁止的事(gst_return_boxes 同一条规矩:报出去的那一份不动,
-- 更正走 correct_gst_return)。一行一次事件,历史就自己留下来了。
--
-- 【顺带,队列要的"每月记录"因此是白拿的】银行余额、账面余额、差额、说明 ——
-- 一次对账一行,本来就按报表(=每月)排好,不需要事后拼。
--
-- 【冻下来的理由,与 GST 的完全一样】"我们当时是照着什么对上的"与
-- "今天重算是多少"是两个问题。只留一个重算式,等于宣称它们永远同一个答案;
-- 有人补一张上个月的分录,那句宣称就成了假话,而记录不会告诉任何人它变了。
-- ★ 两者不一致【本身就是要给人看的信息】★ —— 所以详情页把冻结的与实时的
--   【并排】显示、各自标明是哪一个,谁也不替换谁(见 app 侧)。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE public.bank_reconciliations (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    statement_id         uuid NOT NULL REFERENCES public.bank_statements (id) ON DELETE RESTRICT,
    -- 抄下来的三个数(账户本币),外加它们是"截至哪一天"算的
    as_of                date NOT NULL,              -- = 报表的 period_end
    currency             text NOT NULL REFERENCES public.currencies (code),
    bank_closing_balance numeric NOT NULL,
    book_balance         numeric NOT NULL,
    difference           numeric NOT NULL,
    -- 【差额不能被存成与两个余额不一致】否则这一行自己就能自相矛盾。
    CONSTRAINT bank_reconciliations_difference_consistent
        CHECK (difference = book_balance - bank_closing_balance),
    matched_lines        integer NOT NULL CHECK (matched_lines >= 0),
    ignored_lines        integer NOT NULL CHECK (ignored_lines >= 0),
    reconciled_at        timestamptz NOT NULL DEFAULT now(),
    reconciled_by        uuid DEFAULT auth.uid(),
    -- 被 unreconcile 掀掉时落下。**不删行** —— 签过的那一份留着。
    superseded_at        timestamptz,
    superseded_reason    text,
    CONSTRAINT bank_reconciliations_superseded_shape CHECK (
        (superseded_at IS NULL     AND superseded_reason IS NULL)
     OR (superseded_at IS NOT NULL AND btrim(COALESCE(superseded_reason,'')) <> '')
    ),
    created_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_bank_reconciliations_statement ON public.bank_reconciliations (statement_id);
-- 一张报表【同时】只能有一份未被掀掉的对账
CREATE UNIQUE INDEX uq_bank_reconciliations_live
    ON public.bank_reconciliations (statement_id) WHERE superseded_at IS NULL;

-- 【不可改】唯一合法的变更是 superseded_at/reason 从空到有,且只有一次。
-- 与 journal_entries 的 posted→reversed 同一手法。
CREATE OR REPLACE FUNCTION public.guard_bank_reconciliation_immutable()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'RECONCILIATION_IMMUTABLE';
    END IF;
    IF NOT (OLD.superseded_at IS NULL AND NEW.superseded_at IS NOT NULL) THEN
        RAISE EXCEPTION 'RECONCILIATION_IMMUTABLE';
    END IF;
    -- 除这两列外任何列变更 → 拒绝
    IF (NEW.id, NEW.statement_id, NEW.as_of, NEW.currency, NEW.bank_closing_balance,
        NEW.book_balance, NEW.difference, NEW.matched_lines, NEW.ignored_lines,
        NEW.reconciled_at, NEW.reconciled_by, NEW.created_at)
       IS DISTINCT FROM
       (OLD.id, OLD.statement_id, OLD.as_of, OLD.currency, OLD.bank_closing_balance,
        OLD.book_balance, OLD.difference, OLD.matched_lines, OLD.ignored_lines,
        OLD.reconciled_at, OLD.reconciled_by, OLD.created_at) THEN
        RAISE EXCEPTION 'RECONCILIATION_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_bank_reconciliations_immutable
    BEFORE UPDATE OR DELETE ON public.bank_reconciliations
    FOR EACH ROW EXECUTE FUNCTION public.guard_bank_reconciliation_immutable();

ALTER TABLE public.bank_reconciliations ENABLE ROW LEVEL SECURITY;
-- 写入只走 reconcile_statement / unreconcile_statement(SECURITY DEFINER),
-- 所以这里【只开 SELECT】—— 与 gst_return_boxes 同一条。
CREATE POLICY "bank_reconciliations select by permission"
    ON public.bank_reconciliations
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- ─────────────────────────────────────────────────────────────────────────────
-- ③ 差额的逐项说明 —— 挂在【那一次对账】上,不是挂在报表上
--
-- 【为什么金额是带符号的】未兑现的支票:账上已经把钱付掉了,银行还没扣 →
-- 银行余额【高于】账面 → book - bank 为负。在途存款方向相反。带符号的金额
-- 相加恰好等于差额,是这条规矩唯一自然的写法;绝对值加方向枚举会多一个
-- 能填错的地方。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE public.bank_reconciliation_variance_items (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reconciliation_id uuid NOT NULL REFERENCES public.bank_reconciliations (id) ON DELETE RESTRICT,
    item_no           integer NOT NULL CHECK (item_no >= 1),
    -- 【可枚举 → check-i18n 能自己读到这一行】文案键 bank.varianceKind.<kind>
    item_kind         text NOT NULL CHECK (item_kind IN (
                          'unpresented_cheque',   -- 已开出、银行未兑现的支票
                          'deposit_in_transit',   -- 在途存款
                          'bank_charge',          -- 银行扣费,账上还没记
                          'bank_interest',        -- 银行计息,账上还没记
                          'timing',               -- 其它时点差
                          'error_to_correct'      -- 确认是错的,待更正分录
                      )),
    amount            numeric NOT NULL CHECK (amount <> 0),
    note              text NOT NULL CHECK (btrim(note) <> ''),
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    UNIQUE (reconciliation_id, item_no)
);

CREATE INDEX idx_bank_variance_items_recon
    ON public.bank_reconciliation_variance_items (reconciliation_id);

-- 说明属于一个冻结的事件,所以它自己也冻结。
CREATE OR REPLACE FUNCTION public.reject_variance_item_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'VARIANCE_ITEM_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_bank_variance_items_immutable
    BEFORE UPDATE OR DELETE ON public.bank_reconciliation_variance_items
    FOR EACH ROW EXECUTE FUNCTION public.reject_variance_item_mutation();

ALTER TABLE public.bank_reconciliation_variance_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "bank_variance_items select by permission"
    ON public.bank_reconciliation_variance_items
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- ─────────────────────────────────────────────────────────────────────────────
-- ④ 对账总览:【修一个一直在骗人的现金余额】
--
-- ★ 这是一条【本来就在线上的缺陷】,不是这一刀顺手做的整理 ★
-- 原来的 ledger_balance 这样算:
--     JOIN journal_entries e ON e.id = l.entry_id AND e.status = 'posted'
-- 而冲销的形状是:原分录翻成 status='reversed',另发一张【等额反向的 posted
-- 冲销分录】。只留 posted 就是【丢掉原分录、留下冲销分录】,净额刚好错成
-- −原分录。也就是说:**任何一个银行账户,只要它上面有过一笔被冲销的分录,
-- 银行首页显示的现金余额就是错的** —— 不报错,只是小(或大)了一笔。
--
-- journal_activity_lines 这个函数【就是为了禁止这一条而存在的】,它的函数头
-- 把这段推理逐字写着。这是同一个机制在本仓库的第【三】次现身:
--   ① cash_flow_statement(OPS-17,已修)
--   ② f5_return / f5_box_detail(GST-2,已修,函数体里留了注释)
--   ③ 这里(BANK-REC,本刀)
-- 泛化写在 AGENTS.md 与 journal_activity_lines 的函数头里,一句话:
-- **把分录过滤成 status='posted',在【求和】时几乎总是错的,
--   在【判断单张分录还活着没有】时几乎总是对的。**
--
-- 【jl 那条 lateral 为什么【不】跟着改】它数的是"工作台里还剩几条候选分录",
-- 而候选资格由 match_bank_line 定义 —— 那个函数对属于 reversed 分录的行
-- 直接抛 JL_ENTRY_REVERSED。所以它是【单张分录还活着没有】那一类,是对的用法。
-- 两条 lateral 在这个视图里【本来就问着两个不同的问题】,现在各自答对各自那个。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.bank_reconciliation_status
WITH (security_invoker = on) AS
 SELECT b.account_code,
    bank_native_currency(b.account_code) AS currency,
    COALESCE(led.balance, 0::numeric) AS ledger_balance,
    ls.code AS latest_statement_code,
    ls.period_end AS latest_statement_period_end,
    ls.closing_balance AS latest_closing_balance,
    COALESCE(sl.unmatched, 0::bigint) AS unmatched_statement_lines,
    COALESCE(sl.ignored, 0::bigint) AS ignored_statement_lines,
    COALESCE(jl.unmatched_count, 0::bigint) AS unmatched_journal_lines,
    round(COALESCE(jl.unmatched_net, 0::numeric), 2) AS unmatched_journal_amount,
    round(COALESCE(led.balance, 0::numeric) - ls.closing_balance, 2) AS difference
   FROM ( VALUES ('1000'::text), ('1010'::text)) b(account_code)
     -- 【一份算术,两个读者】与 reconcile_statement 的拒绝共用 bank_book_balance_asof。
     -- p_as_of 传 NULL = 截至此刻、不设日期上界(与本视图原来的口径一致)。
     LEFT JOIN LATERAL ( SELECT bank_book_balance_asof(b.account_code, NULL) AS balance) led ON true
     LEFT JOIN LATERAL ( SELECT s.code,
            s.period_end,
            s.closing_balance
           FROM bank_statements s
          WHERE s.bank_account_code = b.account_code AND s.deleted_at IS NULL
          ORDER BY s.period_end DESC, s.created_at DESC
         LIMIT 1) ls ON true
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE l.match_status = 'unmatched'::text) AS unmatched,
            count(*) FILTER (WHERE l.match_status = 'ignored'::text) AS ignored
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE s.bank_account_code = b.account_code AND s.deleted_at IS NULL) sl ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS unmatched_count,
            sum(
                CASE
                    WHEN l.debit > 0::numeric THEN l.amount_ccy
                    ELSE - l.amount_ccy
                END) AS unmatched_net
           FROM journal_lines l
             JOIN accounts a ON a.id = l.account_id AND a.code = b.account_code
             JOIN journal_entries e ON e.id = l.entry_id AND e.status = 'posted'::text
          WHERE l.currency = bank_native_currency(b.account_code) AND NOT (EXISTS ( SELECT 1
                   FROM bank_line_matches m
                  WHERE m.journal_line_id = l.id))) jl ON true;

-- ─────────────────────────────────────────────────────────────────────────────
-- ⑤ 每月的对账记录 —— 【事后读得到】,不是只在对账那一刻断言过
--
-- 队列要的是「每月:银行余额、账面余额、差额、说明」。一次对账一行,
-- 报表本来就是按月的,所以这张视图就是那份记录本身。
-- 【冻结的那一份】三个数字照抄自 bank_reconciliations;
-- 【今天重算是多少】由 bank_book_balance_asof 现算 —— 两者【并列】,
-- 谁也不替换谁,不一致本身就是要给人看的信息。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.bank_reconciliation_record
WITH (security_invoker = on) AS
 SELECT r.id AS reconciliation_id,
    s.id AS statement_id,
    s.code AS statement_code,
    s.bank_account_code,
    s.period_start,
    s.period_end,
    r.currency,
    -- 冻结的那一份(当时签下的)
    r.bank_closing_balance,
    r.book_balance,
    r.difference,
    r.matched_lines,
    r.ignored_lines,
    r.reconciled_at,
    r.reconciled_by,
    r.superseded_at,
    r.superseded_reason,
    (r.superseded_at IS NULL) AS is_current,
    -- 今天重算的账面余额,以及它与当时那一份的偏移
    bank_book_balance_asof(s.bank_account_code, s.period_end) AS book_balance_now,
    round(bank_book_balance_asof(s.bank_account_code, s.period_end) - r.book_balance, 2) AS book_balance_drift,
    COALESCE(vi.item_count, 0::bigint) AS variance_item_count
   FROM bank_reconciliations r
     JOIN bank_statements s ON s.id = r.statement_id
     LEFT JOIN LATERAL ( SELECT count(*) AS item_count
           FROM bank_reconciliation_variance_items v
          WHERE v.reconciliation_id = r.id) vi ON true;

-- ─────────────────────────────────────────────────────────────────────────────
-- ⑥ 拒绝本身
--
-- 【签名多了一个参数,而它带着 DEFAULT】老调用者(还没重新部署的那一版页面)
-- 打过来时,拿到的必须是【一句话】,不是 "function does not exist"。
-- FIN-10 的先例,以及设备那一刀 X1 在窗口期里打断过一个线上按钮,
-- 都是同一件事。带 DEFAULT 的追加参数让旧调用继续可解析,而它会走
-- "没有给说明" 这一支 —— 差额为 0 就照常对账,差额不为 0 就被 BALANCE_DISAGREES
-- 挡住并说清两个数字。**那正是这一刀想要的行为**,所以窗口期里也是安全的。
--
-- 【说明与事件在同一笔事务里写】"一次对账,它的说明没存上"必须不是一个
-- 到得了的状态。所以说明不是先挂在报表上再誊过来,也不是另一支要先调的函数 ——
-- 它就是这次调用的参数。
-- ─────────────────────────────────────────────────────────────────────────────
-- 【先 DROP 旧签名,否则是【多了一个重载】而不是替换】
-- 加一个带 DEFAULT 的参数不会覆盖 reconcile_statement(uuid):PostgreSQL 按参数表
-- 区分函数,两个会同时存在,而 PostgREST 用具名参数打过来的
-- reconcile_statement(p_statement_id => …) 会当场变成【二义】而不是走新的那个。
-- DROP 之后再建,旧调用点(窗口期里还没换掉的那一版页面)照样解析得到新函数 ——
-- 那正是上面说的"旧调用者拿到一句话而不是 function does not exist"能成立的前提。
DROP FUNCTION IF EXISTS public.reconcile_statement(uuid);

CREATE OR REPLACE FUNCTION public.reconcile_statement(p_statement_id uuid, p_variance_items jsonb DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_stmt        record;
    v_outstanding integer;
    v_matched     integer;
    v_ignored     integer;
    v_book        numeric;
    v_diff        numeric;
    v_items       jsonb;
    v_item        jsonb;
    v_idx         integer := 0;
    v_explained   numeric := 0;
    v_recon_id    uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_stmt FROM bank_statements
    WHERE id = p_statement_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STATEMENT_NOT_FOUND|%', p_statement_id;
    END IF;
    IF v_stmt.status <> 'open' THEN
        RAISE EXCEPTION 'STATEMENT_ALREADY_RECONCILED|%', v_stmt.code;
    END IF;

    SELECT count(*) FILTER (WHERE match_status = 'unmatched'),
           count(*) FILTER (WHERE match_status = 'matched'),
           count(*) FILTER (WHERE match_status = 'ignored')
    INTO v_outstanding, v_matched, v_ignored
    FROM bank_statement_lines
    WHERE statement_id = p_statement_id;

    -- 【第一道:行覆盖率】这一条本来就有,顺序不动 —— 行还没处理完时,
    -- 余额差额几乎必然也对不上,先报那个会把人指向错误的方向。
    IF v_outstanding > 0 THEN
        RAISE EXCEPTION 'LINES_OUTSTANDING|%', v_outstanding;
    END IF;

    -- 【第二道:余额一致 —— 本刀补的就是它】
    -- 账面余额从 bank_book_balance_asof 来,与银行首页那个数【同一份算术】。
    v_book := bank_book_balance_asof(v_stmt.bank_account_code, v_stmt.period_end);
    v_diff := round(v_book - v_stmt.closing_balance, 2);

    v_items := CASE WHEN p_variance_items IS NULL THEN '[]'::jsonb ELSE p_variance_items END;
    IF jsonb_typeof(v_items) <> 'array' THEN
        RAISE EXCEPTION 'VARIANCE_ITEMS_INVALID';
    END IF;

    IF jsonb_array_length(v_items) = 0 THEN
        -- 【没有说明】那么两个数字必须自己相等。**不设容差** ——
        -- 容差就是"带阈值的未解释差额",而下面那一支已经给了诚实的出口。
        IF v_diff <> 0 THEN
            RAISE EXCEPTION 'BALANCE_DISAGREES|%|%|%',
                v_stmt.closing_balance, v_book, v_diff;
        END IF;
    ELSE
        -- 【有说明,却没有差额】说明是用来解释差额的;没有差额就没有要解释的东西。
        -- 放行等于允许一份自相矛盾的记录。
        IF v_diff = 0 THEN
            RAISE EXCEPTION 'VARIANCE_NOT_APPLICABLE';
        END IF;

        FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
            v_idx := v_idx + 1;
            IF COALESCE(v_item->>'amount', '') !~ '^-?[0-9]+(\.[0-9]+)?$'
               OR (v_item->>'amount')::numeric = 0 THEN
                RAISE EXCEPTION 'VARIANCE_AMOUNT_INVALID|%', v_idx;
            END IF;
            IF btrim(COALESCE(v_item->>'note', '')) = '' THEN
                RAISE EXCEPTION 'VARIANCE_NOTE_REQUIRED|%', v_idx;
            END IF;
            IF COALESCE(v_item->>'kind', '') NOT IN ('unpresented_cheque', 'deposit_in_transit',
                    'bank_charge', 'bank_interest', 'timing', 'error_to_correct') THEN
                RAISE EXCEPTION 'VARIANCE_KIND_INVALID|%', COALESCE(v_item->>'kind', '');
            END IF;
            v_explained := v_explained + round((v_item->>'amount')::numeric, 2);
        END LOOP;

        -- 【逐项金额必须【恰好】等于差额】否则"这是原因"就只是一句放在差额旁边的
        -- 注解,而不是对差额的【交代】—— 金额那一栏会退化成装饰。
        IF round(v_explained, 2) <> v_diff THEN
            RAISE EXCEPTION 'VARIANCE_UNEXPLAINED|%|%', v_diff, round(v_explained, 2);
        END IF;
    END IF;

    -- ★【说明【不】把两个数字抹平】★ book_balance 与 bank_closing_balance 原样抄下,
    --   difference 原样留着。报表是 reconciled,而它身上写着差多少、为什么。
    INSERT INTO bank_reconciliations (
        statement_id, as_of, currency, bank_closing_balance, book_balance, difference,
        matched_lines, ignored_lines)
    VALUES (p_statement_id, v_stmt.period_end, v_stmt.currency,
            v_stmt.closing_balance, v_book, v_diff, v_matched, v_ignored)
    RETURNING id INTO v_recon_id;

    IF jsonb_array_length(v_items) > 0 THEN
        INSERT INTO bank_reconciliation_variance_items (
            reconciliation_id, item_no, item_kind, amount, note)
        SELECT v_recon_id,
               ordinality::integer,
               it->>'kind',
               round((it->>'amount')::numeric, 2),
               btrim(it->>'note')
        FROM jsonb_array_elements(v_items) WITH ORDINALITY AS e(it, ordinality);
    END IF;

    UPDATE bank_statements
    SET status = 'reconciled', reconciled_at = now(), reconciled_by = auth.uid()
    WHERE id = p_statement_id;

    RETURN jsonb_build_object(
        'statement_id', p_statement_id,
        'reconciliation_id', v_recon_id,
        'code', v_stmt.code,
        'matched_lines', v_matched,
        'ignored_lines', v_ignored,
        'closing_balance', v_stmt.closing_balance,
        'book_balance', v_book,
        'difference', v_diff,
        'variance_items', jsonb_array_length(v_items)
    );
END;
$function$;

-- 【重开报表 = 掀掉那一份对账记录,但【不删它】】签过的那一份留着,
-- 只落一个 superseded_at + 理由。再对一次是【一个新事件、一行新记录】,
-- 与 gst_return_boxes / correct_gst_return 同一条规矩。
CREATE OR REPLACE FUNCTION public.unreconcile_statement(p_statement_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_stmt record;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_stmt FROM bank_statements
    WHERE id = p_statement_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STATEMENT_NOT_FOUND|%', p_statement_id;
    END IF;
    IF v_stmt.status <> 'reconciled' THEN
        RAISE EXCEPTION 'STATEMENT_NOT_RECONCILED|%', v_stmt.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    UPDATE bank_reconciliations
    SET superseded_at = now(), superseded_reason = btrim(p_reason)
    WHERE statement_id = p_statement_id AND superseded_at IS NULL;

    UPDATE bank_statements
    SET status = 'open',
        reconciled_at = NULL,
        reconciled_by = NULL,
        notes = COALESCE(notes || E'\n', '') || 'UNRECONCILED ' || now()::text || ': ' || btrim(p_reason)
    WHERE id = p_statement_id;
END;
$function$;

-- 【给屏幕的伴生函数 —— 屏幕不自己算】
-- AGENTS.md:「预览一笔过账的屏幕要【问数据库】它会是什么」。差额必须在人
-- 按下按钮【之前】就看得见(销售单信用提示的先例),而那个数字必须与拒绝时
-- 用的那个【同一份算术】,否则两处会各自漂移,而人信的是看得见的那一处。
-- 【为什么要这一层 definer 外壳】bank_book_balance_asof 是 invoker、靠 RLS,
-- 没有权限的人直接调它会拿到 0.00 —— 一个【看起来像答案的空集】。
-- 这一层先 require_permission,于是没有权限得到的是拒绝,不是一个假的零。
CREATE OR REPLACE FUNCTION public.preview_reconcile_statement(p_statement_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_stmt        record;
    v_book        numeric;
    v_outstanding integer;
BEGIN
    PERFORM require_permission('module.finance.view');
    SELECT * INTO v_stmt FROM bank_statements
    WHERE id = p_statement_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STATEMENT_NOT_FOUND|%', p_statement_id;
    END IF;

    v_book := bank_book_balance_asof(v_stmt.bank_account_code, v_stmt.period_end);

    SELECT count(*) FILTER (WHERE match_status = 'unmatched')
    INTO v_outstanding
    FROM bank_statement_lines WHERE statement_id = p_statement_id;

    RETURN jsonb_build_object(
        'statement_id', p_statement_id,
        'code', v_stmt.code,
        'currency', v_stmt.currency,
        'as_of', v_stmt.period_end,
        'bank_closing_balance', v_stmt.closing_balance,
        'book_balance', v_book,
        'difference', round(v_book - v_stmt.closing_balance, 2),
        'outstanding_lines', v_outstanding
    );
END;
$function$;

COMMIT;
