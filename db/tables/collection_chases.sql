-- db/tables/collection_chases.sql
-- CHASE-1：一次催收 = 一行不可变的事件（形状取自 bank_reconciliations / customer_statements）。
--
-- NOTE: introduced by db/migrations/2026-08-27-chase1-collection-records.sql.
-- First-run script (plain CREATEs).

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
