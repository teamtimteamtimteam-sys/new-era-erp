-- CHASE-1:催收记录 —— 谁催的、什么时候、对方说了什么,以及【他答应了什么】
--
-- 队列里那一条只有一行:「催收记录(谁催的、什么时候、对方说了什么)」。
-- 勘察(docs/phase4-survey.md §7)把它与对账单并成一刀,理由是
-- 「催收记录是对账单开启的那场对话的日志」。STATEMENT-1 先落地了对账单;
-- 这一刀是另一半,而实测下来它【不是】对账单的附属品,理由见下面 §0。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §0 · 三件实测,它们决定了这一刀的形状
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ★【一】催收的主语只能是【客户】,不能是【单据】★
-- 实测(2026-08-27,ar_aging_asof 带 JWT claims):线上 9 行未结应收里
-- **8 行是未开票的销售**(57,079.00 本位币),只有 1 行是发票(364.00)。
-- 而 `sales_records` **一列 `code` 都没有** —— 它的可读标识是【产出批号】,
-- 并且**不唯一**:OUT-2026-0185 与 OUT-2026-0186 各自挂着【两行】未结,
-- 分属两条不同的 sales_record。
--
-- 也就是说:对 99.4% 的欠款金额,「你欠我的那张单据」这句话【说不出口】——
-- 客户手里没有那个号,而我们这边那个号还不是一对一的。
-- 所以催收挂在客户上;单据引用是【可选的一组】,用来记「我们谈的是七月那两船」。
--
-- ★【二】全库【没有任何东西】记录与往来户的一次接触★
-- 逐个查过:`tasks` 是一张独立的待办清单,`task_type` 只有 personal/team,
-- **一列都挂不到客户或单据上**;`notifications` 是事件流;`approval_log` 是决定;
-- `sales_attribution_log` 是"给一笔无主销售认领客户"这一件事;
-- `customer_credit_history` 是限额变更的前后值;`customers.notes` 是一列会被覆盖的自由文本。
-- **没有一张可以扩展的活动表** —— 所以这是新的,不是重复。
--
-- 而 `notifications` 自己的表注释定下了这一刀必须守的规矩:
--   「要接第三个来源,先问它是不是已经有一份持久记录 —— 如果是,
--     通知应当【指向】它而不是【复制】它。」
-- 于是:催收记录是那份【持久记录】,仪表盘那一支【指向】它。
--
-- ★【三】签发档【八张一张不落】都没有"已发送"的概念★
-- 查过 `sent|deliver|emailed|dispatch|recipient`:全库只有采购单的到货日期命中。
-- STATEMENT-1 报告里点名的那个缺口不是对账单独有的,是这套机制共有的。
-- **它在这里闭合,而闭合的方式是【不加列】**(Tim 2026-08-27 裁定):
-- 一份对账单寄没寄出去,答案是"有没有一条催收记录引用了它" ——
-- 加一个 `sent_at` 就是同一件事的第二份记录,而它在第二次寄出的那一刻就错了。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §1 · 不可变,与它的理由
-- ═══════════════════════════════════════════════════════════════════════════
-- 一条催收记录是【一场发生过的对话】。对它的"修改"只有两种:
--   ① 我记错了/打错了 —— 那是更正,走 superseded(留痕,不删);
--   ② 后来又知道了新情况 —— **那是另一场对话**,是新的一条,不是改旧的。
-- 可改会带来一件具体的坏事:客户答应了 6,000 却没付,而那条承诺可以被
-- 事后改掉 —— **唯一一份"他确实答应过"的证据就没有了**。
-- 形状取自 bank_reconciliations / customer_statements(不可变事件行 +
-- superseded_at + 必填理由),不是取自 purchase_orders(可改 + 历史表)。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §2 · 欠款数字【不许自己算】—— 它调的就是对账单那一支函数
-- ═══════════════════════════════════════════════════════════════════════════
-- 催收屏幕上的"他欠多少"与对账单上印的那个数【必须是同一个】,否则同一个客户
-- 会被报出两个数字。这里没有"用同样的方法算一遍",而是【直接调】
-- `customer_statement_data(客户, D, D)` —— 单日窗口,取它的 closing 那一侧。
-- 于是它天然继承了 STATEMENT-1 实测出来的那件事:
--   **勾稽要用【核销额】不是【收款额】**,挂账的钱一张单据都没冲,
--   所以"已收未核销"与"净应收"必须分开报。
-- 一份实现,两个调用方 —— 与 reprice_split / preview_revalue 同一条。
--
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1 · collection_chases —— 一次催收 = 一行不可变的事件
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE public.collection_chases (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code              text NOT NULL UNIQUE,
    customer_id       uuid NOT NULL REFERENCES public.customers (id) ON DELETE RESTRICT,
    -- 【世界上发生的那一天】—— 绝不默认。AGENTS.md 那条:一个决定期间/汇率/金额的
    -- 日期必须必填并按名拒;COALESCE(p_date, CURRENT_DATE) 正是那条规矩要杀掉的东西。
    chased_on         date NOT NULL,
    channel           text NOT NULL
        CHECK (channel IN ('phone', 'email', 'whatsapp', 'in_person', 'letter')),
    -- 【打不通也是一次催收】"我们试过三次都没人接"与"他答应了三次"是两个故事,
    -- 而只记成功接触的系统说不出前一个。
    reached           boolean NOT NULL,
    contacted_person  text,
    summary           text NOT NULL,
    -- ══ 冻结的那一侧:那一天我们【告诉他】他欠多少 ══════════════════════════
    -- 与 customer_statements 同一条理由:六周后回头读这条记录,要看到的是
    -- 【当时谈的那个数】,不是今天的余额 —— 后者是一个从未被讨论过的数字。
    -- 这五个数全部来自 customer_statement_data(客户, chased_on, chased_on)。
    base_currency     text NOT NULL REFERENCES public.currencies (code),
    owed_base         numeric NOT NULL,
    on_account_base   numeric NOT NULL,
    net_due_base      numeric NOT NULL,
    owed_by_currency  jsonb NOT NULL,
    owed_buckets      jsonb NOT NULL,
    chased_by         uuid,
    created_at        timestamptz NOT NULL DEFAULT now(),
    -- 【更正 = 新起一行,旧的标掉,不删】
    superseded_at     timestamptz,
    superseded_by     uuid REFERENCES public.collection_chases (id),
    superseded_reason text,
    CONSTRAINT collection_chases_supersede_shape
        CHECK ((superseded_at IS NULL) = (superseded_by IS NULL)),
    -- 没接触到人,就没有"接触到的是谁"
    CONSTRAINT collection_chases_contact_shape
        CHECK (reached OR contacted_person IS NULL)
);

COMMENT ON TABLE public.collection_chases IS
    'CHASE-1:一次催收 = 一行【不可变】的事件。谁催的(chased_by)、哪一天(chased_on,绝不默认)、走哪条路(channel)、有没有真的联系上人(reached)、接触到谁(contacted_person)、对方说了什么(summary),外加【那一天我们告诉他欠多少】的冻结数字。【为什么冻】六周后回头读这条记录,要看到的是当时谈的那个数,不是今天的余额 —— 与 customer_statements、bank_reconciliations 同一条。【那五个数不是自己算的】它们来自 customer_statement_data(客户, chased_on, chased_on) 的单日窗口,也就是对账单印的那一支函数 —— 一份实现两个调用方,同一个客户不会被报出两个数字。【为什么挂在客户上而不是单据上】实测线上 9 行未结应收里 8 行是未开票的销售,而 sales_records 一列 code 都没有,产出批号还不唯一(OUT-2026-0185/0186 各挂两行)—— 对 99.4% 的金额,"你欠我的那张单据"这句话说不出口。单据引用是可选的一组,在 collection_chase_documents 里。【更正】不改行:新起一行 + 旧行落 superseded_at 与必填理由;可改会让"他确实答应过"这唯一一份证据在他没付之后被抹掉。写入只走 record_collection_chase(SECURITY DEFINER),所以这里只开 SELECT。';

COMMENT ON COLUMN public.collection_chases.reached IS
    '有没有真的联系上人。打不通、留言、邮件石沉大海 —— 都是发生过的催收,都要留痕;"我们试过三次都没人接"与"他答应了三次"是两个完全不同的故事,而只记成功接触的系统说不出前一个。一条 reached=false 的记录不允许有承诺(record_collection_chase 按名拒 PROMISE_REQUIRES_CONTACT)。';

CREATE INDEX idx_collection_chases_customer
    ON public.collection_chases (customer_id, chased_on DESC);

ALTER TABLE public.collection_chases ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是属主权限的函数 ——
-- 与 customer_statements、bank_reconciliations、八张签发档同一条。
CREATE POLICY "collection_chases select by permission" ON public.collection_chases
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- ───────────────────────────────────────────────────────────────────────────
-- 2 · collection_chase_documents —— 「我们谈的是这几张」(可选的一组)
-- ───────────────────────────────────────────────────────────────────────────
-- 形状取自 approval_log / notifications 的 (subject_type, subject_id):
-- 三种主体来自三张不同的表,写三个可空外键会得到三列里两列永远是空。
CREATE TABLE public.collection_chase_documents (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    chase_id     uuid NOT NULL REFERENCES public.collection_chases (id) ON DELETE RESTRICT,
    subject_type text NOT NULL CHECK (subject_type IN ('sales_record', 'invoice', 'statement')),
    subject_id   uuid NOT NULL,
    -- 【把可读标识抄下来】未开票的销售【没有单号】,批号是它唯一可读的东西,
    -- 而批号还会随重新计价改变含义 —— 抄下当时那个,与冻结数字同一条理由。
    subject_code text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (chase_id, subject_type, subject_id)
);

COMMENT ON TABLE public.collection_chase_documents IS
    'CHASE-1:一次催收里【具体谈到的单据】,可选、可多条。形状取自 approval_log / notifications 的 (subject_type, subject_id):三种主体(未开票销售 / 发票 / 对账单)住在三张表里,写三个可空外键只会得到三列里永远有两列是空。subject_code 是当时那个可读标识的【抄件】—— 未开票的销售没有单号,产出批号是它唯一可读的东西而且不唯一,所以抄下来而不是每次去 join 一个会变的东西。★【statement 这一种就是"对账单寄出去了没有"的答案】★ 八张签发档一张都没有"已发送"标志,而这是全库唯一记录"与客户接触过"的地方:一份对账单寄没寄出去 = 有没有一条催收引用了它。刻意【不】给 statement_issues 加 sent_at —— 那会是同一件事的第二份记录,并且在第二次寄出的那一刻就错了。';

CREATE INDEX idx_collection_chase_documents_subject
    ON public.collection_chase_documents (subject_type, subject_id);

CREATE TRIGGER trg_collection_chase_documents_append_only
    BEFORE UPDATE OR DELETE ON public.collection_chase_documents
    FOR EACH ROW EXECUTE FUNCTION public.guard_credit_note_append_only();

ALTER TABLE public.collection_chase_documents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "collection_chase_documents select by permission" ON public.collection_chase_documents
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- ───────────────────────────────────────────────────────────────────────────
-- 3 · collection_promises —— 有牙齿的那一半
-- ───────────────────────────────────────────────────────────────────────────
-- 【为什么它是自己一张表,不是催收行上的两个可空列】
-- 一个承诺有催收记录【没有】的生命周期:它被【做出】,然后被【兑现 / 毁掉 /
-- 重新谈 / 取消】。把它写成催收行上的两列,就得在一条不可变的记录上改状态
-- —— 要么破坏不可变,要么根本没地方说"这个承诺兑现了"。
-- 【一次对话一个承诺】(UNIQUE chase_id):分期付款是几个承诺,它们来自几次对话。
CREATE TABLE public.collection_promises (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    chase_id             uuid NOT NULL UNIQUE REFERENCES public.collection_chases (id) ON DELETE RESTRICT,
    -- 【客户是用某个币种承诺的 —— 那才是事实】
    promised_amount_ccy  numeric NOT NULL CHECK (promised_amount_ccy > 0),
    currency             text NOT NULL REFERENCES public.currencies (code),
    -- ★【本位币等值按【催收当天】折算,不是按承诺日】★
    -- 承诺日在【未来】,那一天的汇率不存在。按承诺日折算 = 每一个承诺都会被
    -- FX_RATE_MISSING 拒掉;而随便取一个就是 THE FX RULE 明令禁止的"编一个汇率"。
    -- 所以口径是:承诺【做出】的那一天的 tt_buy(收款侧,与 record_payment 同侧)。
    fx_rate              numeric NOT NULL CHECK (fx_rate > 0),
    promised_amount_base numeric NOT NULL,
    promised_date        date NOT NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid,
    -- ══ 结局:一个承诺【必须能被了结】,否则仪表盘上那一支永远清不掉 ══════
    outcome              text CHECK (outcome IN ('kept', 'broken', 'renegotiated', 'cancelled')),
    outcome_note         text,
    outcome_recorded_at  timestamptz,
    outcome_recorded_by  uuid,
    CONSTRAINT collection_promises_outcome_shape
        CHECK ((outcome IS NULL) = (outcome_recorded_at IS NULL))
);

COMMENT ON TABLE public.collection_promises IS
    'CHASE-1:客户承诺的【一笔钱 + 一个日子】—— 催收里唯一有牙齿的东西,也是唯一值得报表的东西。【为什么自成一张表】一个承诺有催收记录没有的生命周期:做出 → 兑现/毁掉/重新谈/取消。写成催收行上的两个可空列,就得在一条不可变的记录上改状态 —— 要么破坏不可变,要么根本没地方说"这个承诺兑现了"。【一次对话一个承诺】UNIQUE(chase_id):分期是几个承诺,来自几次对话。【币种】客户是用某个币种承诺的,那才是事实;本位币等值按【催收当天】的 tt_buy 折算 —— 不是按承诺日,因为承诺日在未来、那天的汇率不存在,按它折算等于每个承诺都被 FX_RATE_MISSING 拒掉,而随便取一个正是 THE FX RULE 禁止的编造。【没有自己的 superseded 列】一个承诺活不活着,看它那条催收活不活着 —— 两份状态会各说各话。【结局必须记得下来】一个清不掉的告警会教会人忽略告警,这个仓库为此付过账(hr_alerts.system_start_not_set 曾是一个 hr 角色永远清不掉的假警报)。';

COMMENT ON COLUMN public.collection_promises.outcome IS
    'kept=钱按约到了 · broken=到期没到 · renegotiated=又谈了一次(新的承诺在新的催收里)· cancelled=这个承诺作废(例如单据本身被冲销)。【由人记,不由机器猜】—— 自动按"余额下降了"判兑现,会在一笔无关的付款到账时悄悄把一个没兑现的承诺标成兑现。机器提供的是【证据】(collection_promise_status.received_since_base),判断是人的。记下之后不可改:它是一件关于世界的事实。';

CREATE INDEX idx_collection_promises_open
    ON public.collection_promises (promised_date)
    WHERE outcome IS NULL;

ALTER TABLE public.collection_promises ENABLE ROW LEVEL SECURITY;

CREATE POLICY "collection_promises select by permission" ON public.collection_promises
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- ───────────────────────────────────────────────────────────────────────────
-- 4 · 取号器(与 next_statement_code / next_credit_note_code 同一惯用法)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_chase_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 自己的一把锁 —— 共用一把会烧掉别人的号,而无缝的意思正是号码之间没有洞。
    PERFORM pg_advisory_xact_lock(hashtext('chase_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
      FROM collection_chases
     WHERE code LIKE 'CHASE-' || v_year::text || '-%';
    RETURN 'CHASE-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

COMMENT ON FUNCTION public.next_chase_code(date) IS
    'CHASE-1:CHASE-YYYY-NNNN,按年重置、无缝。取号惯用法与 next_statement_code / next_credit_note_code 逐字相同,含各自一把 advisory 锁。';

-- ───────────────────────────────────────────────────────────────────────────
-- 5 · customer_collection_context —— 催收屏幕读的那一份【只读】上下文
-- ───────────────────────────────────────────────────────────────────────────
-- ★ 它【不算】欠款,它【调】对账单那一支函数 ★
-- AGENTS.md 那条(这个仓库为它付过四次账):一块要预览一次过账的屏幕
-- 【要问数据库它会是什么】,不许在别处把规则重写一遍。这里更进一步 ——
-- 连"用同样的方法算"都不做,直接调 customer_statement_data 的单日窗口。
CREATE OR REPLACE FUNCTION public.customer_collection_context(
    p_customer_id uuid,
    p_as_of       date DEFAULT CURRENT_DATE
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c    customers%ROWTYPE;
    v_data jsonb;
BEGIN
    PERFORM require_permission('module.finance.view');

    SELECT * INTO v_c FROM customers WHERE id = p_customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'CHASE_DATE_REQUIRED';
    END IF;
    IF p_as_of > CURRENT_DATE THEN
        -- 与 AGING_AS_OF_FUTURE / STATEMENT_PERIOD_FUTURE 同一条:
        -- 一次"发生在未来"的催收不是记录,是计划。
        RAISE EXCEPTION 'CHASE_DATE_FUTURE|%|%', p_as_of::text, CURRENT_DATE::text;
    END IF;

    -- 单日窗口:只取它 closing 那一侧。它因此天然带着 STATEMENT-1 实测出来的
    -- 那个区别 —— 已收未核销的钱不冲任何单据,所以 owed / on_account / net_due
    -- 是三个数,不是一个。
    v_data := customer_statement_data(p_customer_id, p_as_of, p_as_of);

    RETURN jsonb_build_object(
        'customer_id',      p_customer_id,
        'customer_code',    v_data->>'customer_code',
        'customer_name',    v_data->>'customer_name',
        'as_of',            p_as_of,
        'base_currency',    v_data->>'base_currency',
        'owed_base',        (v_data->>'closing_base')::numeric,
        'on_account_base',  (v_data->>'on_account_base')::numeric,
        'net_due_base',     (v_data->>'net_due_base')::numeric,
        'by_currency',      v_data->'by_currency',
        'buckets',          v_data->'buckets',
        'lines',            v_data->'lines',
        -- 【这个客户最近被催过没有】—— 命名的缺席由界面说,这里只给事实
        'last_chased_on',   (SELECT max(chased_on) FROM collection_chases
                              WHERE customer_id = p_customer_id AND superseded_at IS NULL),
        'open_promises',    (SELECT COALESCE(count(*), 0) FROM collection_promises pr
                               JOIN collection_chases ch ON ch.id = pr.chase_id
                              WHERE ch.customer_id = p_customer_id
                                AND ch.superseded_at IS NULL AND pr.outcome IS NULL),
        -- ★【还没了结的承诺，每一个带上它自己的【证据】】★
        -- 证据 = 这个承诺做出【那一天之后】，这个客户身上真的核销掉了多少。
        -- 它【不】替人下判断（一笔无关的付款到账，不该把没兑现的承诺标成兑现），
        -- 它只是让按下 kept / broken 的那个人是在读数字，不是在猜。
        -- 【为什么算在这里而不在视图里】这一支要跑 customer_statement_data，
        -- 而那支函数带 require_permission —— 放进要喂 operations_now 的视图里，
        -- 会让没有 finance 权限的读者【整个仪表盘报错】。这一支只在客户页上跑，
        -- 而记结局的人就站在那一页。
        'promises_open',    COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'promise_id',           pr.id,
                       'chase_id',             ch.id,
                       'chase_code',           ch.code,
                       'chased_on',            ch.chased_on,
                       'promised_amount_ccy',  pr.promised_amount_ccy,
                       'currency',             pr.currency,
                       'promised_amount_base', pr.promised_amount_base,
                       'promised_date',        pr.promised_date,
                       'is_overdue',           pr.promised_date < CURRENT_DATE,
                       'applied_since_base',
                           COALESCE((customer_statement_data(
                               p_customer_id, ch.chased_on, LEAST(CURRENT_DATE, p_as_of)
                           )->>'applied_base')::numeric, 0)
                   ) ORDER BY pr.promised_date)
              FROM collection_promises pr
              JOIN collection_chases   ch ON ch.id = pr.chase_id
             WHERE ch.customer_id = p_customer_id
               AND ch.superseded_at IS NULL
               AND pr.outcome IS NULL
               AND ch.chased_on <= p_as_of), '[]'::jsonb)
    );
END;
$function$;

COMMENT ON FUNCTION public.customer_collection_context(uuid, date) IS
    'CHASE-1:催收屏幕的只读上下文。★【它不算欠款,它调对账单那一支函数】★ —— customer_statement_data(客户, D, D) 的单日窗口,取 closing 那一侧。AGENTS.md 记着这个仓库为"屏幕自己把过账规则重写一遍"付过四次账;这里连"用同样的方法算"都不做。后果是同一个客户在催收屏幕上与在对账单上【不可能】出现两个数字,而且它免费继承了那个实测:已收未核销的钱不冲任何单据,所以 owed / on_account / net_due 是三个数。未来的截至日按名拒(CHASE_DATE_FUTURE)。';

-- ───────────────────────────────────────────────────────────────────────────
-- 6 · collection_promise_status —— 承诺的现状 +【给人看的证据】
-- ───────────────────────────────────────────────────────────────────────────
-- 属主权限(OPS-14 修法 (a)):它横跨 finance 与 customers 两侧,
-- invoker 会让 RLS 把读者无权的那一侧【静默丢掉】—— 而这里行消失意味着
-- "少了一个逾期承诺",不是报错。外层由调用方按 module.finance.view 把关。
CREATE OR REPLACE VIEW public.collection_promise_status
WITH (security_invoker = off) AS
SELECT pr.id                       AS promise_id,
       ch.id                       AS chase_id,
       ch.code                     AS chase_code,
       ch.customer_id,
       cu.code                     AS customer_code,
       cu.legal_name               AS customer_name,
       ch.chased_on,
       ch.channel,
       pr.promised_amount_ccy,
       pr.currency,
       pr.promised_amount_base,
       pr.promised_date,
       pr.outcome,
       pr.outcome_recorded_at,
       -- 【逾期 = 承诺日的【第二天】起】—— 今天到期的承诺今天还没有被辜负。
       -- 不设宽限期:一个没人调的旋钮会让"逾期"在不同时候意思不同。
       (pr.outcome IS NULL AND ch.superseded_at IS NULL
        AND pr.promised_date < CURRENT_DATE)      AS is_overdue,
       (pr.outcome IS NULL AND ch.superseded_at IS NULL) AS is_open,
       ch.superseded_at IS NOT NULL               AS chase_superseded,
       ch.superseded_reason
  FROM collection_promises pr
  JOIN collection_chases   ch ON ch.id = pr.chase_id
  JOIN customers           cu ON cu.id = ch.customer_id;

COMMENT ON VIEW public.collection_promise_status IS
    'CHASE-1：每个承诺一行 —— 它是什么、逾期了没有、它那条催收还活着没有。【逾期从承诺日的第二天起】今天到期的承诺今天还没有被辜负；不设宽限期，一个没人调的旋钮会让“逾期”在不同时候意思不同。属主权限（security_invoker = off）：它横跨 finance 与 customers，invoker 会让 RLS 把读者无权的那一侧静默丢掉，而这里行消失意味着“少了一个逾期承诺”而不是报错（OPS-14 修法 (a)）。★【它刻意只有纯 SQL，一个函数都不调】★ 两个理由，都是实测出来的：① 属主权限【替不了函数的 EXECUTE】（AGENTS.md 记过三次），而 customer_statement_data 里有 require_permission —— 在这张要喂 operations_now 的视图里调它，会让【没有 finance 权限的读者整个仪表盘报错】，而不是少看见一支；② 它每行要跑两次 ar_aging_asof，那是对账页的活，不上人人都开的首页（OPS-16 为同一件事把两笔贵读数按界限住）。【那么证据在哪儿】承诺做出之后真的核销了多少，由 customer_collection_context 在客户页上算 —— 记结局的人就站在那一页。';

-- ───────────────────────────────────────────────────────────────────────────
-- 7 · record_collection_chase —— 唯一的写入口
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_collection_chase(
    p_customer_id      uuid,
    p_chased_on        date,
    p_channel          text,
    p_reached          boolean,
    p_summary          text,
    p_contacted_person text DEFAULT NULL,
    p_documents        jsonb DEFAULT '[]'::jsonb,
    p_promise          jsonb DEFAULT NULL,
    p_supersedes       uuid DEFAULT NULL,
    p_supersede_reason text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c         customers%ROWTYPE;
    v_old       collection_chases%ROWTYPE;
    v_ctx       jsonb;
    v_code      text;
    v_id        uuid;
    v_promise_id uuid;
    v_doc       jsonb;
    v_ok        boolean;
    v_subj_code text;
    v_amt       numeric;
    v_ccy       text;
    v_date      date;
    v_rate      numeric;
    v_out_id    uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_c FROM customers WHERE id = p_customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;

    -- 【日期必填,绝不默认】AGENTS.md:COALESCE(p_date, CURRENT_DATE) 会奖励留空 ——
    -- 填对的那一天可能撞上期间锁而报错,留空的反而滑进开着的月份。
    IF p_chased_on IS NULL THEN
        RAISE EXCEPTION 'CHASE_DATE_REQUIRED';
    END IF;
    IF p_chased_on > CURRENT_DATE THEN
        RAISE EXCEPTION 'CHASE_DATE_FUTURE|%|%', p_chased_on::text, CURRENT_DATE::text;
    END IF;
    IF p_channel IS NULL OR p_channel NOT IN ('phone','email','whatsapp','in_person','letter') THEN
        RAISE EXCEPTION 'CHASE_CHANNEL_INVALID|%', COALESCE(p_channel, '?');
    END IF;
    IF p_reached IS NULL THEN
        RAISE EXCEPTION 'CHASE_REACHED_REQUIRED';
    END IF;
    IF p_summary IS NULL OR btrim(p_summary) = '' THEN
        -- 【对方说了什么,是这条记录存在的理由】一条没有内容的催收记录
        -- 只是一个时间戳,而队列那一条要的正是"对方说了什么"。
        RAISE EXCEPTION 'CHASE_SUMMARY_REQUIRED';
    END IF;
    IF NOT p_reached AND p_contacted_person IS NOT NULL AND btrim(p_contacted_person) <> '' THEN
        RAISE EXCEPTION 'CHASE_CONTACT_WITHOUT_REACH|%', p_contacted_person;
    END IF;

    -- ══ 更正:旧的那一条要还活着,而且理由必填 ══════════════════════════════
    IF p_supersedes IS NOT NULL THEN
        SELECT * INTO v_old FROM collection_chases WHERE id = p_supersedes;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'CHASE_NOT_FOUND|%', p_supersedes::text;
        END IF;
        IF v_old.superseded_at IS NOT NULL THEN
            RAISE EXCEPTION 'CHASE_ALREADY_SUPERSEDED|%|%', v_old.code, v_old.superseded_at::date::text;
        END IF;
        IF p_supersede_reason IS NULL OR btrim(p_supersede_reason) = '' THEN
            RAISE EXCEPTION 'CHASE_SUPERSEDE_REASON_REQUIRED|%', v_old.code;
        END IF;
        -- ★【已经记下结局的承诺,不许被一次"更正"抹掉】★
        -- 一个结局是【关于世界的事实】(钱到了,或者没到)。改正一句记错的话
        -- 不该连带擦掉那件事实 —— 那正是"可改"最坏的那一面。
        SELECT pr.id INTO v_out_id FROM collection_promises pr
         WHERE pr.chase_id = p_supersedes AND pr.outcome IS NOT NULL;
        IF FOUND THEN
            RAISE EXCEPTION 'CHASE_SUPERSEDE_OUTCOME_RECORDED|%|%',
                v_old.code, (SELECT outcome FROM collection_promises WHERE id = v_out_id);
        END IF;
    END IF;

    -- ══ 冻结那一天的欠款 —— 【调对账单那一支函数,不自己算】═══════════════
    v_ctx  := customer_collection_context(p_customer_id, p_chased_on);
    v_code := next_chase_code(p_chased_on);

    INSERT INTO collection_chases (
        code, customer_id, chased_on, channel, reached, contacted_person, summary,
        base_currency, owed_base, on_account_base, net_due_base,
        owed_by_currency, owed_buckets, chased_by)
    VALUES (
        v_code, p_customer_id, p_chased_on, p_channel, p_reached,
        NULLIF(btrim(COALESCE(p_contacted_person, '')), ''), btrim(p_summary),
        v_ctx->>'base_currency',
        (v_ctx->>'owed_base')::numeric,
        (v_ctx->>'on_account_base')::numeric,
        (v_ctx->>'net_due_base')::numeric,
        v_ctx->'by_currency', v_ctx->'buckets', auth.uid())
    RETURNING id INTO v_id;

    -- ══ 谈到的单据(可选的一组)══════════════════════════════════════════
    FOR v_doc IN SELECT * FROM jsonb_array_elements(COALESCE(p_documents, '[]'::jsonb))
    LOOP
        -- 【引用的东西必须存在,而且必须是【这个客户的】】—— 否则一条催收会
        -- 声称谈过一张别人家的单据,而那是一句没人会去核对的假话。
        v_ok := false; v_subj_code := NULL;
        IF v_doc->>'subject_type' = 'sales_record' THEN
            SELECT true, ob.code INTO v_ok, v_subj_code
              FROM sales_records sr JOIN output_batches ob ON ob.id = sr.output_batch_id
             WHERE sr.id = (v_doc->>'subject_id')::uuid AND sr.customer_id = p_customer_id;
        ELSIF v_doc->>'subject_type' = 'invoice' THEN
            SELECT true, i.code INTO v_ok, v_subj_code
              FROM invoices i WHERE i.id = (v_doc->>'subject_id')::uuid
               AND i.customer_id = p_customer_id;
        ELSIF v_doc->>'subject_type' = 'statement' THEN
            SELECT true, s.code INTO v_ok, v_subj_code
              FROM customer_statements s WHERE s.id = (v_doc->>'subject_id')::uuid
               AND s.customer_id = p_customer_id;
        ELSE
            RAISE EXCEPTION 'CHASE_DOCUMENT_KIND_UNKNOWN|%', COALESCE(v_doc->>'subject_type', '?');
        END IF;
        IF NOT COALESCE(v_ok, false) THEN
            RAISE EXCEPTION 'CHASE_DOCUMENT_NOT_THIS_CUSTOMER|%|%',
                v_doc->>'subject_type', COALESCE(v_doc->>'subject_id', '?');
        END IF;
        INSERT INTO collection_chase_documents (chase_id, subject_type, subject_id, subject_code)
        VALUES (v_id, v_doc->>'subject_type', (v_doc->>'subject_id')::uuid, v_subj_code);
    END LOOP;

    -- ══ 承诺(可选,而它是有牙齿的那一半)═══════════════════════════════
    IF p_promise IS NOT NULL AND p_promise <> 'null'::jsonb THEN
        -- 【没联系上人,就不可能有承诺】一条 reached=false 的记录带着承诺,
        -- 说的是"没人接电话,但他答应了付款"—— 那不是一件可能发生的事。
        IF NOT p_reached THEN
            RAISE EXCEPTION 'PROMISE_REQUIRES_CONTACT';
        END IF;
        v_amt  := NULLIF(p_promise->>'amount', '')::numeric;
        v_ccy  := NULLIF(p_promise->>'currency', '');
        v_date := NULLIF(p_promise->>'promised_date', '')::date;
        IF v_amt IS NULL THEN
            RAISE EXCEPTION 'PROMISE_AMOUNT_REQUIRED';
        END IF;
        IF v_amt <= 0 THEN
            RAISE EXCEPTION 'PROMISE_AMOUNT_INVALID|%', v_amt::text;
        END IF;
        IF v_date IS NULL THEN
            RAISE EXCEPTION 'PROMISE_DATE_REQUIRED';
        END IF;
        IF v_date < p_chased_on THEN
            -- 一个"承诺在通话之前付款"的日子,不是承诺,是打错的字
            RAISE EXCEPTION 'PROMISE_DATE_BEFORE_CHASE|%|%', v_date::text, p_chased_on::text;
        END IF;
        IF v_ccy IS NULL OR NOT EXISTS (SELECT 1 FROM currencies WHERE code = v_ccy) THEN
            RAISE EXCEPTION 'PROMISE_CURRENCY_UNKNOWN|%', COALESCE(v_ccy, '?');
        END IF;
        -- ★【按【催收当天】折算,不是按承诺日】★ 承诺日在未来,那天的汇率不存在;
        -- 按它折算 = 每一个承诺都被 FX_RATE_MISSING 拒掉,而随便取一个正是
        -- THE FX RULE 明令禁止的编造。tt_buy —— 客户付给我们,是一笔收款(与
        -- record_payment 同侧;一笔收款按卖出价折算,每一次都是错的)。
        v_rate := fx_rate_for(v_ccy, p_chased_on, 'tt_buy');
        INSERT INTO collection_promises (
            chase_id, promised_amount_ccy, currency, fx_rate, promised_amount_base,
            promised_date, created_by)
        VALUES (v_id, v_amt, v_ccy, v_rate, round(v_amt * v_rate, 2), v_date, auth.uid())
        RETURNING id INTO v_promise_id;
    END IF;

    -- 更正:旧行落标记(【不删】)
    IF p_supersedes IS NOT NULL THEN
        UPDATE collection_chases
           SET superseded_at = now(), superseded_by = v_id,
               superseded_reason = btrim(p_supersede_reason)
         WHERE id = p_supersedes;
    END IF;

    RETURN jsonb_build_object(
        'chase_id', v_id, 'code', v_code,
        'promise_id', v_promise_id,
        'owed_base', (v_ctx->>'owed_base')::numeric,
        'superseded', p_supersedes);
END;
$function$;

COMMENT ON FUNCTION public.record_collection_chase(uuid, date, text, boolean, text, text, jsonb, jsonb, uuid, text) IS
    'CHASE-1:催收记录的唯一写入口(表上没有 INSERT 策略)。【日期必填、不许默认】—— 一个记录"世界上哪一天发生了什么"的日期,给它 CURRENT_DATE 默认值就是奖励留空。【欠款不自己算】走 customer_collection_context → customer_statement_data,与对账单同一支函数。【承诺要么不给、要么给全】金额/币种/日期任一缺失都按名拒;承诺日早于通话日是打错的字,不是承诺。【本位币等值按催收当天的 tt_buy】承诺日在未来、那天没有汇率;tt_buy 因为客户付给我们是一笔收款。【没联系上人就不可能有承诺】reached=false 带承诺 = "没人接电话但他答应了付款",按名拒。【更正】新起一行 + 旧行落 superseded;而旧行上那个承诺【已经记了结局】时按名拒 —— 结局是关于世界的事实,改正一句记错的话不该连带擦掉它。';

-- ───────────────────────────────────────────────────────────────────────────
-- 8 · record_promise_outcome —— 让那一支【清得掉】
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_promise_outcome(
    p_promise_id uuid,
    p_outcome    text,
    p_note       text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p collection_promises%ROWTYPE;
    v_ch collection_chases%ROWTYPE;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_p FROM collection_promises WHERE id = p_promise_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PROMISE_NOT_FOUND|%', COALESCE(p_promise_id::text, '?');
    END IF;
    IF v_p.outcome IS NOT NULL THEN
        -- 结局记下之后不可改 —— 它与催收记录本身同一条:一件发生过的事。
        RAISE EXCEPTION 'PROMISE_OUTCOME_ALREADY_RECORDED|%|%',
            v_p.outcome, v_p.outcome_recorded_at::date::text;
    END IF;
    IF p_outcome IS NULL OR p_outcome NOT IN ('kept','broken','renegotiated','cancelled') THEN
        RAISE EXCEPTION 'PROMISE_OUTCOME_INVALID|%', COALESCE(p_outcome, '?');
    END IF;
    SELECT * INTO v_ch FROM collection_chases WHERE id = v_p.chase_id;
    IF v_ch.superseded_at IS NOT NULL THEN
        -- 一条被取代的催收上的承诺已经不成立了,给它记结局是在给一件
        -- 已经作废的东西下判断。
        RAISE EXCEPTION 'PROMISE_CHASE_SUPERSEDED|%', v_ch.code;
    END IF;

    UPDATE collection_promises
       SET outcome = p_outcome,
           outcome_note = NULLIF(btrim(COALESCE(p_note, '')), ''),
           outcome_recorded_at = now(),
           outcome_recorded_by = auth.uid()
     WHERE id = p_promise_id;

    RETURN jsonb_build_object('promise_id', p_promise_id, 'outcome', p_outcome,
                              'chase_code', v_ch.code);
END;
$function$;

COMMENT ON FUNCTION public.record_promise_outcome(uuid, text, text) IS
    'CHASE-1:给一个承诺记下结局 —— ★这支函数存在的全部理由,是让仪表盘上那一支【清得掉】★。一个没人清得掉的告警会教会人忽略告警,而这个仓库为此付过账:hr_alerts 的 system_start_not_set 曾经是一个 hr 角色【永远】清不掉的假警报(它读不到那张表,于是条件恒真)。【由人记,不由机器猜】自动按"余额下降了"判兑现,会在一笔无关付款到账时把没兑现的承诺悄悄标成兑现;机器出证据(customer_collection_context.promises_open[].applied_since_base),判断是人的。【记下之后不可改】它是一件关于世界的事实,与催收记录本身同一条。';

-- ───────────────────────────────────────────────────────────────────────────
-- 9 · operations_now —— 第 31 支:【到期没兑现的承诺】
-- ───────────────────────────────────────────────────────────────────────────
-- 【为什么承诺要上仪表盘】一个记下来却没有人被提醒的承诺,就是表里的一条备注。
-- 【为什么它清得掉】谓词是 outcome IS NULL —— record_promise_outcome 一记结局,
-- 这一行就消失。AGENTS.md 记着 hr_alerts.system_start_not_set 曾是一个 hr 角色
-- 【永远】清不掉的假警报;一个清不掉的告警会教会人忽略告警。
-- 【整支视图重放一遍】CREATE OR REPLACE VIEW 不能只加一支 UNION,列名列型顺序
-- 不变所以是合法的替换。本视图【没有 reloptions】(实测 pg_class.reloptions 为空,
-- 默认属主权限),所以不存在 AGENTS.md 记的那个"viewdef 不吐 WITH(...)"的陷阱。
-- 【新支不需要动 arm_permission_widen / arm_permission_any】两支对未知 item_type
-- 都返回 NULL,而外层 `has_permission(permission) OR has_any_permission(NULL)`
-- 正是既有 ar_over_90 那一支依赖的形状。

CREATE OR REPLACE VIEW public.operations_now AS
 SELECT item_type,
    permission,
    arm_permission_any(item_type) AS permission_any,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM ( SELECT 'awaiting_assay'::text AS item_type,
            'module.inbound.view'::text AS permission,
            g.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            g.batch_code AS item_code,
            array_to_string(g.missing_metals, ', '::text) AS subject,
            g.arrival_date AS item_date
           FROM batch_required_assay_gaps g
          WHERE g.sampleable
        UNION ALL
         SELECT 'assay_unapplied'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.latest_assay_code AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.has_unapplied_assay
        UNION ALL
         SELECT 'batch_unpriced'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.pricing_status = 'unpriced'::text
        UNION ALL
         SELECT 'allocation_stale'::text AS item_type,
            'module.processing.view'::text AS permission,
            s.run_id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            NULL::text AS subject,
            s.last_cost_change::date AS item_date
           FROM processing_run_allocation_status s
          WHERE s.is_stale OR s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL
        UNION ALL
         SELECT 'po_awaiting_receipt'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.id AS item_id,
            NULL::text AS doc_kind,
            po.code AS item_code,
            po.status AS subject,
            po.order_date AS item_date
           FROM purchase_orders po
          WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
        UNION ALL
         SELECT 'stocktake_open'::text AS item_type,
            'module.stocktakes.view'::text AS permission,
            st.id AS item_id,
            NULL::text AS doc_kind,
            st.code AS item_code,
            NULL::text AS subject,
            st.started_at::date AS item_date
           FROM stocktakes st
          WHERE st.deleted_at IS NULL AND st.status = 'open'::text
        UNION ALL
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_1.id AS item_id,
            NULL::text AS doc_kind,
            s_1.code AS item_code,
            (ct.name_en || ' — '::text) || s_1.legal_name AS subject,
            sc.valid_until AS item_date
           FROM supplier_compliance sc
             JOIN certificate_types ct ON ct.code = sc.cert_type_code
             JOIN suppliers s_1 ON s_1.id = sc.supplier_id
          WHERE sc.deleted_at IS NULL AND s_1.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND sc.valid_until IS NOT NULL AND sc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'qualification_missing'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_2.id AS item_id,
            NULL::text AS doc_kind,
            s_2.code AS item_code,
            s_2.legal_name AS subject,
            s_2.created_at::date AS item_date
           FROM suppliers s_2
          WHERE s_2.deleted_at IS NULL AND s_2.supplies_goods AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
                   FROM supplier_compliance sc2
                  WHERE sc2.supplier_id = s_2.id AND sc2.deleted_at IS NULL))
        UNION ALL
         SELECT 'credit_over_limit'::text AS item_type,
            'module.customers.view'::text AS permission,
            c_1.id AS item_id,
            NULL::text AS doc_kind,
            c_1.code AS item_code,
            c_1.legal_name AS subject,
            COALESCE(( SELECT min(sr.sale_date) AS min
                   FROM sales_records sr
                  WHERE sr.customer_id = c_1.id), CURRENT_DATE) AS item_date
           FROM customers c_1
          WHERE c_1.deleted_at IS NULL AND c_1.credit_limit_base IS NOT NULL AND customer_ar_exposure_visible(c_1.id) >= c_1.credit_limit_base
        UNION ALL
         SELECT 'output_unsold_aging'::text AS item_type,
            'module.output.view'::text AS permission,
            ob.id AS item_id,
            NULL::text AS doc_kind,
            ob.code AS item_code,
            ob.state AS subject,
            COALESCE(ob.output_date, ob.created_at::date) AS item_date
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0::numeric AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
        UNION ALL
         SELECT 'safety_stock_below'::text AS item_type,
            'module.inventory.view'::text AS permission,
            msa.material_id AS item_id,
            NULL::text AS doc_kind,
            msa.code AS item_code,
            (((((trim_scale(msa.available_qty)::text || ' / '::text) || trim_scale(msa.safety_stock_qty)::text) || ' '::text) || COALESCE(msa.unit, ''::text)) || ' — short '::text) || trim_scale(msa.safety_stock_qty - msa.available_qty)::text AS subject,
            COALESCE(msa.last_movement_date, CURRENT_DATE) AS item_date
           FROM material_stock_available msa
          WHERE msa.safety_stock_qty IS NOT NULL AND msa.available_qty < msa.safety_stock_qty
        UNION ALL
         SELECT 'leave_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            lr.id AS item_id,
            NULL::text AS doc_kind,
            lr.code AS item_code,
            e.legal_name AS subject,
            lr.created_at::date AS item_date
           FROM leave_requests lr
             JOIN employees e ON e.id = lr.employee_id
          WHERE lr.status = 'pending'::text AND lr.deleted_at IS NULL
        UNION ALL
         SELECT 'claim_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            mc.id AS item_id,
            NULL::text AS doc_kind,
            mc.code AS item_code,
            e.legal_name AS subject,
            mc.created_at::date AS item_date
           FROM medical_claims mc
             JOIN employees e ON e.id = mc.employee_id
          WHERE mc.status = 'submitted'::text AND mc.deleted_at IS NULL
        UNION ALL
         SELECT 'review_submitted'::text AS item_type,
            'module.hr.view'::text AS permission,
            r.id AS item_id,
            NULL::text AS doc_kind,
            e.code AS item_code,
            e.legal_name AS subject,
            COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
          WHERE r.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            i.invoice_id AS item_id,
            NULL::text AS doc_kind,
            i.code AS item_code,
            i.customer_name AS subject,
            i.due_date AS item_date
           FROM invoice_status i
          WHERE i.overdue
        UNION ALL
         SELECT 'ar_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            COALESCE(ar.sales_record_id, ar.invoice_id) AS item_id,
            ar.doc_kind,
            ar.doc_code AS item_code,
            ar.customer_name AS subject,
            ar.sale_date AS item_date
           FROM ar_open_items ar
          WHERE ar.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'ap_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ap.doc_id AS item_id,
            ap.doc_kind,
            ap.doc_code AS item_code,
            ap.supplier_name AS subject,
            ap.doc_date AS item_date
           FROM ap_open_items ap
          WHERE ap.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'fx_rate_gap'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            g.currency AS item_code,
            array_to_string(g.missing_types, ', '::text) AS subject,
            g.rate_date AS item_date
           FROM fx_rate_gaps g
          WHERE g.rate_date >= (CURRENT_DATE - 45)
        UNION ALL
         SELECT 'bank_unmatched'::text AS item_type,
            'module.finance.view'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.bank_account_code AS item_code,
            s.code AS subject,
            l.line_date AS item_date
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE l.match_status = 'unmatched'::text AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'margin_cost_not_allocated'::text AS item_type,
            'data.view_prices'::text AS permission,
            bm.run_id AS item_id,
            NULL::text AS doc_kind,
            bm.batch_code AS item_code,
            bm.material_name AS subject,
            ob.output_date AS item_date
           FROM batch_margin bm
             JOIN output_batches ob ON ob.id = bm.output_batch_id
          WHERE bm.margin_status = 'no_unit_cost'::text
        UNION ALL
         SELECT 'metal_quote_stale'::text AS item_type,
            'module.pricing.view'::text AS permission,
            mp.latest_id AS item_id,
            NULL::text AS doc_kind,
            mp.metal AS item_code,
            mp.latest_price::text AS subject,
            mp.max_date AS item_date
           FROM ( SELECT p.metal,
                    max(p.price_date) AS max_date,
                    (array_agg(p.id ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_id,
                    (array_agg(p.price_usd_per_tonne ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_price
                   FROM metal_prices p
                  WHERE p.deleted_at IS NULL
                  GROUP BY p.metal) mp
          WHERE (CURRENT_DATE - mp.max_date) > (( SELECT ps.metal_quote_stale_days
                   FROM pricing_settings ps
                 LIMIT 1))
        UNION ALL
         SELECT 'orders_unfulfilled'::text AS item_type,
            'module.sales.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            so.status AS subject,
            so.order_date AS item_date
           FROM sales_orders so
          WHERE so.deleted_at IS NULL AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))        UNION ALL
-- ── EXEC-3a:工单逾期 ──────────────────────────────────────────────────────
-- 【排产日为空【永远不是】逾期】—— 空的意思是"没排期",而不是"排在过去"。
-- 一个 COALESCE(scheduled_date, CURRENT_DATE) 会把没排期的全部报成今天到期,
-- COALESCE(..., 'infinity') 会把它们全部漏掉 —— 两个方向都错,所以这里
-- 显式 IS NOT NULL(WO-1c 记在 arm inventory 里的那条)。
--
-- 【"放行了三个月、从没排过期"该不该有别的支管】—— 仍然是一个【开着的问题】,
-- 记在 arm inventory 里。这一支不假装回答它:它只报"排了期而且过了期"的。
         SELECT 'work_order_overdue'::text AS item_type,
            'module.processing.view'::text AS permission,
            w.id AS item_id,
            NULL::text AS doc_kind,
            w.code AS item_code,
            w.scheduled_date::text AS subject,
            w.scheduled_date AS item_date
           FROM work_orders w
          WHERE w.status = 'released'::text
            AND w.scheduled_date IS NOT NULL
            AND w.scheduled_date < CURRENT_DATE
        UNION ALL
-- ── EXEC-3a:工单差异超阈 ──────────────────────────────────────────────────
-- 【两种坏消息,两个阈值,两种触发时机】—— WO-1c 在 arm inventory 里留的那个
-- 问题("投入超耗与产出短交是否用同一个阈值")的答案是【不是】,所以
-- processing_settings 有两列,而这一支有两条腿:
--
--   * 投入超耗:吃掉的比计划多出 t_in% 以上。**开着的单和收了工的单都报** ——
--     超耗在它发生的那一刻就是可处理的事(料已经下去了,要么改计划、要么查为什么)。
--   * 产出短交:产出比预期少 t_out% 以上。**只报收了工的单** —— 在收工之前,
--     "少"只是"还没做完",把它报出来等于每天提醒一件正在进行的事。
--
-- 【没记录预期的行永远不报】has_plan = false 意味着没人估过,而不是估了零。
-- 一个把它当零的实现会让每一次产出都成为"短交 100%"—— 这正是 WO-1a 让
-- 预期产出行可选、WO-1b 让视图返回 NULL 的全部理由,在这里必须一路守住。
--
-- 阈值现读 processing_settings,不写死(与 metal_quote_stale 同一条)。
         SELECT 'work_order_variance_beyond'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.work_order_id AS item_id,
            NULL::text AS doc_kind,
            f.work_order_code AS item_code,
            CASE WHEN f.side = 'input'::text
                 THEN 'input overrun · ' || COALESCE(f.material_code, '?') || ' · '
                      || trim_scale(f.actual_qty)::text || ' / ' || trim_scale(f.planned_or_expected_qty)::text
                 ELSE 'output shortfall · ' || COALESCE(f.material_code, '?') || ' · '
                      || trim_scale(f.actual_qty)::text || ' / ' || trim_scale(f.planned_or_expected_qty)::text
            END AS subject,
            COALESCE(w2.scheduled_date, w2.created_at::date) AS item_date
           FROM work_order_fulfilment f
             JOIN work_orders w2 ON w2.id = f.work_order_id
          WHERE f.has_plan
            AND f.planned_or_expected_qty > 0::numeric
            AND (
                 (f.side = 'input'::text
                  AND w2.status = ANY (ARRAY['released'::text, 'closed'::text])
                  AND f.actual_qty > f.planned_or_expected_qty
                      * (1::numeric + (SELECT ps.wo_input_overrun_pct FROM processing_settings ps LIMIT 1) / 100::numeric))
              OR (f.side = 'output'::text
                  AND w2.status = 'closed'::text
                  AND f.actual_qty < f.planned_or_expected_qty
                      * (1::numeric - (SELECT ps.wo_output_shortfall_pct FROM processing_settings ps LIMIT 1) / 100::numeric))
            )
        UNION ALL
-- ═══ LOG-5a:物流的四支 ═══════════════════════════════════════════════════
-- 【四支全部排除已软删的箱子】(c.deleted_at IS NULL,逐支各写一次)。
-- 【三个阈值 2 / 14 / 7 都是写死的(v1,Tim 定)】。要把它们变成可调的那一天,
-- 现成的先例是 certificate_types.warn_lead_days —— 一张 RUNTIME CONFIG 表,
-- 每一类自带提前期【和】后果(block/warn/ignore),"加一种是编辑一行,不是跑一次迁移"。
-- 在那之前,写死的数字至少是【看得见】的:它就在这里,不在某个配置项里。

-- ── 1 · 免柜期将尽 / 已超 ────────────────────────────────────────────────
-- 【锚点是"最后被【录入】的那条 arrived"】(LOG-5d 改)—— ORDER BY
-- recorded_at DESC, id DESC。**此前是 event_date DESC,那是错的**:
-- 里程碑只增不改,更正的写法是再记一条;而一条把日期改【早】的更正,
-- 在 event_date 排序下【永远排不到前面】,于是它一次都不会生效。
-- (线上实例 CTR-2026-0009:先录 arrived 08-16,再录一条更正 08-14 ——
--  所有读者仍然锚在 08-16。改晚的更正碰巧生效,改早的永远不生效。)
-- 【屏幕那一侧算的是同一件事,必须同刀改】页面为了显示剩余天数自己算了一遍
-- (app/logistics/containers/[id]/ContainerFreightPanel.tsx),口径一旦与这里分岔,
-- 屏幕写着"剩余 1 天"而看板一声不吭,且没有任何东西会报错。两处注释互相点名。
-- 【id DESC 是破平局的】recorded_at 默认 now() = 事务时刻,同一事务里插两条会一样;
-- uuid 比大小没有"更晚"的含义,但它是【确定的】—— 不确定比排错更坏。
-- 【这条规则只管"同一种里程碑里哪一条算数"】。跨类型的"现在走到哪一步"是另一个
-- 问题,仍按 event_date 排(container_overview.latest_milestone)—— 那里若改成
-- recorded_at,今天补录一条 booked 就会让箱子"退回"已订舱。
-- 【报价里 free_days 为 NULL 的箱子一支都不响】NULL = "这份报价没有写免柜期",
-- 与 0 =「零个免费天」是两件不同的事,而把前者当成后者会让每一个到港的箱子
-- 从第一天起就报警 —— 那是喊狼来了,而喊狼来了的告警等于没有告警。
         SELECT 'free_time_expiring'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            ((q.free_days - (CURRENT_DATE - arr.event_date))::text || ' left of '::text
              || q.free_days::text) || COALESCE(' — '::text || f.legal_name, ''::text) AS subject,
            arr.event_date AS item_date
           FROM containers c
             LEFT JOIN suppliers f ON f.id = c.forwarder_id
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'arrived'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) arr ON true
             JOIN forwarder_rate_quotes q
               ON q.supplier_id = c.forwarder_id AND q.lane_id = c.lane_id
              AND q.deleted_at IS NULL
              AND c.departure_date >= q.valid_from AND c.departure_date <= q.valid_to
          WHERE c.deleted_at IS NULL
            AND q.free_days IS NOT NULL
            AND (q.free_days - (CURRENT_DATE - arr.event_date)) <= 2
        UNION ALL
-- ── 2 · 走了很久,没人说到了 ─────────────────────────────────────────────
-- 【这一支是上一支的保命companion】免柜期那一支只在【有 arrived】时才可能响;
-- 一个没人录到港的箱子,在那一支里【永远安静】,而安静与"没问题"在屏幕上
-- 长得一模一样(METAL-1 的 no_reference 那一课)。所以这一支专门说:
-- 开走 14 天了,而没有任何人说过它到了。
         SELECT 'container_no_arrival'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            dep.event_date::text AS subject,
            dep.event_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'departed'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) dep ON true
          WHERE c.deleted_at IS NULL
            AND (CURRENT_DATE - dep.event_date) >= 14
            AND NOT (EXISTS ( SELECT 1 FROM container_milestones m2
                               WHERE m2.container_id = c.id AND m2.milestone = 'arrived'::text))
        UNION ALL
-- ── 3 · 说好的到港日过了,而它还没到 ─────────────────────────────────────
-- 【expected_arrival_date 为 NULL 时这一支不响】,而那是一条【已知的局限】,
-- 不是一个疏漏:与 work_order_overdue 逐字同形(它也只报"排了期而且过了期"的,
-- 并在视图里明写"放行了三个月、从没排过期该不该有别的支管"仍是开着的问题)。
-- 同一个问题在这里原样成立:一个从来没人填过 ETA 的箱子,是"没问题",
-- 还是最该被问的那一个?这一支不假装回答它。
         SELECT 'container_eta_overdue'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            c.expected_arrival_date::text AS subject,
            c.expected_arrival_date AS item_date
           FROM containers c
          WHERE c.deleted_at IS NULL
            AND c.expected_arrival_date IS NOT NULL
            AND c.expected_arrival_date < CURRENT_DATE
            AND NOT (EXISTS ( SELECT 1 FROM container_milestones m3
                               WHERE m3.container_id = c.id AND m3.milestone = 'arrived'::text))
        UNION ALL
-- ── 4 · 开走了,单据还欠着 ───────────────────────────────────────────────
-- 【锚在 departure_date】—— 它是箱子上唯一 NOT NULL 的世界侧日期,所以一定算得出来。
-- 【代价照直写】:有些单据(订舱确认、装箱单)本该在开航【之前】就到,
-- 以开航日为零点会让它们永远不迟。这一支因此不是"所有该到的单据"的告警,
-- 是"开航之后还欠着"的告警 —— 名字与它测的东西一致。
-- 【从没实例化过清单的箱子一支都不响】:pending 数为 0,这里就没有行。
-- 那种"空"与"都收齐了"在库里长得一样,而把它们分开是 5b 的事(屏幕上说清哪一种空)。
         SELECT 'container_documents_late'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            p.n::text || ' pending'::text AS subject,
            c.departure_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT count(*) AS n
                   FROM container_documents d
                  WHERE d.container_id = c.id AND d.status = 'pending'::text) p ON true
          WHERE c.deleted_at IS NULL
            AND p.n > 0
            AND (CURRENT_DATE - c.departure_date) >= 7
        UNION ALL
-- ── EQP-2c · 保养到期,以及【将到期】——【两支,不是一支带等级】────────────
-- operations_now 的列契约里没有"严重程度"这一列,所以唯一在结构上分得开的
-- 办法就是两个 item_type。与 qualification_expiring / qualification_missing、
-- container_no_arrival / container_eta_overdue 同形。
-- 【两支互斥】已到期的不再出现在"将到期"里(is_approaching 自己带 NOT is_due)
-- —— 否则同一件事被数两遍,那正是 fixture 30 那句话要抓的东西。
-- 【提前量是【数据】】lead_kg / lead_days 在 equipment_service_intervals 的行上,
-- 视图现读;fixture 111 F6 在同一笔事务里两个方向都验过。
-- 【item_id 是机器,不是间隔行】判据是 LINKS-1 那一条:门牌指向【承载补救动作】
-- 的那张页面所对应的行。补救动作是"给这台机器记一次保养",而它发生在机器那一页
-- (/finance/assets/[id],EQP-1c-b 建的)—— 间隔行今天没有自己的页面。
-- 与 bank_unmatched / margin_cost_not_allocated 取父行是同一条规矩。
-- 【item_date 是基线日】= 上一次那一种保养,没有就是取得日。于是
-- days_waiting 读出来就是"距上一次保养多少天",【正好就是两个量度里的天数那一个】,
-- 不是第三个数。
-- 【未监控的机器一支都不响,而那是一个具名状态不是零】判据 s.monitored ——
-- 理由整段写在 equipment_service_status 的视图注释里,这里不复述。
-- 【已处置的机器不收】一件"去保养它"的待办,对一台已经不在的机器没有意义。
-- 【牌子在 EQP-2d】本刀落的是这两支的【行】;首页那两块牌子在 2d。
         SELECT 'equipment_service_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess.equipment_code AS item_code,
            (ess.service_kind || ' — '::text) || ess.equipment_description AS subject,
            ess.baseline_date AS item_date
           FROM equipment_service_status ess
          WHERE ess.monitored AND ess.disposition = 'warn'::text AND ess.equipment_status <> 'disposed'::text AND ess.is_due
        UNION ALL
         SELECT 'equipment_service_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess_1.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess_1.equipment_code AS item_code,
            (ess_1.service_kind || ' — '::text) || ess_1.equipment_description AS subject,
            ess_1.baseline_date AS item_date
           FROM equipment_service_status ess_1
          WHERE ess_1.monitored AND ess_1.disposition = 'warn'::text AND ess_1.equipment_status <> 'disposed'::text AND ess_1.is_approaching
        UNION ALL
        -- ★【CHASE-1:到期没兑现的承诺】★ 这一支是这一刀存在的理由的一半 ——
        -- 一个记下来却没有人被提醒的承诺,就是表里的一条备注。
        -- 【它清得掉】:record_promise_outcome 记下结局,这一行就消失
        -- (谓词是 outcome IS NULL AND NOT superseded AND promised_date < 今天)。
        -- 一个清不掉的告警会教会人忽略告警,而这个仓库为此付过账。
        -- 【逾期从承诺日的第二天起】今天到期的承诺今天还没有被辜负。
         SELECT 'promise_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            ps.promise_id AS item_id,
            NULL::text AS doc_kind,
            ps.chase_code AS item_code,
            ps.customer_name AS subject,
            ps.promised_date AS item_date
           FROM collection_promise_status ps
          WHERE ps.is_overdue
) a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type)))
    AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));

GRANT SELECT ON public.operations_now TO authenticated;

COMMIT;
