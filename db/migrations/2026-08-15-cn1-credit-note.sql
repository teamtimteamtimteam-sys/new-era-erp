-- CN-1(2026-08-15):贷项凭证 —— 一张【编号、可签发】的单据,把客户欠的钱减下来
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这一刀补的是九处停放里那个"以后再说"】
-- sales_records 的表头从 phase 3 起就写着"更正走一个未来的贷项凭证概念,不是编辑";
-- void_invoice 的 INVOICE_SHIPPED_NOT_VOIDABLE、shipments 的不可作废、
-- set_sales_order_status 里 partially_shipped 的无出路、SO-1b 的短装收尾 ——
-- 九个地方都指着同一个不存在的单据。今天它存在了。
--
-- 【范围:只对订单流(kind='order')发票】而这【不是】保守起见,是两条结算路
-- 根本不同:
--   * order 型发票【自己就是应收单据】—— 开票即过账(借 1100 / 贷 2500),
--     核销挂 payment_allocations.invoice_id,开放余额有【一处】推导。
--   * sale 型发票【什么都不过账】(entry_id/fx_rate 按 CHECK 恒为 NULL):
--     它只是把已经存在的 sales_records 装订成一张纸,应收长在那些记录上,
--     而它们【逐列不可变】。给它做贷项凭证要动的是另一套东西。
--   sale 型今天的更正路仍然是 void_invoice(它对 sale 型只是翻个标志位)
--   与 reverse_payment —— 那条路没有被这一刀改动,也没有被这一刀关掉。
--   【实测的量级,记下来免得下一个人以为覆盖面等于价值】线上未结应收
--   sale 支 55,936.00(7 张)、order 支 414.00(1 张)。也就是说这一刀覆盖的是
--   【要走的那条流】,不是【今天的钱】。要覆盖后者是另一次决定(CN-2 之后)。
--
-- 【一张贷项凭证绑一张发票,并以那张发票【当下的】开放余额为上限】
-- 不跨发票、不预留、不产生客户信用余额:超出开放余额的那一半是【退款】,
-- 而退款是另一个概念(见下方停放点)。上限用"当下"求值而不是开票额,
-- 于是"先收了一部分钱、再开贷项凭证"不会把应收推成负数。
--
-- 【两种行 —— 而它们过的账完全不同,这是本刀最要紧的一句】
--   unshipped_cancel  未发的那部分:货【没有】发出去,所以它从来没变成收入,
--                     它还躺在 2500 合同负债里。冲它 → 借 2500。
--                     ※ 收入一个字都不动:短装 12 发 7,收入本来就只有 7 的那份,
--                       借 4000 会把一次【正确的】交付说成少卖了。
--   revenue_reduction 已发的那部分事后减价/质量折让:货交付了、收入认了,
--                     现在少收钱 → 借 4000。
--   两种行都贷 1100(客户少欠这么多)。一张凭证可以同时有两种行。
--
-- 【汇率:抄发票的,不是开屏时现查的】(FIN-27 一族)
-- 1100 是按发票存下来的汇率入的账,2500 与 4000 也是(ship_order 用的就是
-- 【发票的】汇率)。用别的汇率冲,单据币种归零之后本位币还会剩一截残渣 ——
-- 而那截残渣与一笔真的【已实现】汇兑损益在账上长得一模一样,却没有任何钱动过。
-- 已实现汇兑的定义就是"钱真的动了那一刻"(record_payment 把它推去 7100);
-- 贷项凭证不动钱,所以它必须【不产生】已实现汇兑 —— 只有同一个汇率能做到。
-- 未实现那一侧自动保持一致:1100 期末重估读的是单据币种余额,而这条冲销
-- 恰好只动那个余额。
--
-- 【停放,并且说清楚停在哪】
--   ① 已结清发票的退款:CN_INVOICE_FULLY_SETTLED 按名拒。钱已经收进来了,
--      要还回去的是【现金】,那是一张付款单 + 一个客户贷余概念,而这个系统
--      今天没有客户贷余的落脚点(科目表里没有它;未核销收款今天是落在 1100
--      里的一截净贷方,没有单据、没有视图、也没法再拿去核销)。
--   ② 贷项凭证的作废:本刀不做。凭证是只增不改的过账单据,写错了要冲销 ——
--      而冲销一张贷项凭证等于再开一张反向的,那需要"负数金额"或"反向类型",
--      两者都要先回答①的那个问题。所以这里只把门关严:append-only。
--   ③ 改单谓词与短装端到端(SO-1b 那条 SO_AMEND_LINE_INVOICED 之后的路):CN-2。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 单据头 ════════════════════════════════════════════════════════════
CREATE TABLE public.credit_notes (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text NOT NULL UNIQUE,          -- 'CN-YYYY-NNNN',无缝,自己的咨询锁
    -- 【绑一张发票,而且只绑一张】跨发票的抵扣要回答"先抵哪一张",那是核销的
    -- 语义,不是贷项凭证的。NOT NULL:一张不指向任何发票的贷项凭证,就是一个
    -- 没有上限的减记。
    invoice_id  uuid NOT NULL REFERENCES public.invoices (id),
    -- 【理由必填】一张减了客户欠款的单据没有理由,三个月后没有人说得出为什么。
    reason      text NOT NULL,
    -- 【物理事件日,永不默认】(AGENTS.md 的日期规矩)它决定这笔冲销落进哪个
    -- 会计期间;补一个 CURRENT_DATE 会让"留空"比"填对"更容易通过 —— 今天的日期
    -- 永远撞不上 PERIOD_LOCKED,于是填对了反而被拒。
    note_date   date NOT NULL,
    -- 【过账单据:分录先出,再写这一行】所以 NOT NULL —— 与 invoices 的
    -- kind='order' 那一支同形(那里也是 entry_id NOT NULL)。
    entry_id    uuid NOT NULL REFERENCES public.journal_entries (id),
    -- 【币种与汇率是从发票【抄】过来的,不是调用方递进来的】见抬头那一段:
    -- 结算解除按的就是这个基准,用别的会凭空造出一笔已实现汇兑。
    -- 守卫 guard_credit_note_invoice 对着发票逐列核对,抄错了当场拒。
    currency    text NOT NULL REFERENCES public.currencies (code),
    fx_rate     numeric NOT NULL CHECK (fx_rate > 0),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.credit_notes IS
    'CN-1:贷项凭证 —— 发票开出去之后、又不能再作废的时候,把客户欠的钱减下来的那张单据(九处"更正走贷项凭证"停放的就是它)。【只对 kind=''order'' 的发票】:那种发票自己就是应收单据、开票即过账;sale 型什么都不过账,应收长在不可变的 sales_records 上,那是另一套东西,它今天的路仍然是 void_invoice / reverse_payment。一张凭证绑一张发票,总额以那张发票【当下的】开放余额为上限 —— 超出的那一半是【退款】,而退款需要一个这个系统还没有的客户贷余概念(CN_INVOICE_FULLY_SETTLED 按名拒)。币种与汇率【抄发票的】:1100/2500/4000 都是按它入的账,换个汇率冲会在本位币上留下一截与真实已实现汇兑长得一模一样、却没有任何钱动过的残渣。只增不改(CREDIT_NOTE_IMMUTABLE)—— 作废是停放的概念,见迁移抬头。';

COMMENT ON COLUMN public.credit_notes.note_date IS
    'CN-1:这张贷项凭证的【单据日】—— 物理事件日,必填、永不默认。它决定冲销分录落进哪个会计期间,而期间锁与年结闸由 post_journal_entry 对它统一执行(锁住的月份按名拒,不是悄悄挪到今天)。给它一个 CURRENT_DATE 默认值会让【留空】比【填对】更容易通过:今天的日期永远撞不上 PERIOD_LOCKED。';

CREATE INDEX idx_credit_notes_invoice ON public.credit_notes (invoice_id);
CREATE INDEX idx_credit_notes_date    ON public.credit_notes (note_date DESC);

-- ═══ 2 · 单据行 ════════════════════════════════════════════════════════════
CREATE TABLE public.credit_note_lines (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    credit_note_id uuid NOT NULL REFERENCES public.credit_notes (id),
    -- 【指向发票行,不指向订单行】这张凭证冲的是【那张发票上的那一行】——
    -- 上限也是按发票行算的(未释放的负债 / 已释放的收入)。订单行是它背后的
    -- 履约主语,但客户手里那张纸上写的是发票行。
    invoice_line_id uuid NOT NULL REFERENCES public.invoice_lines (id),
    -- 【两种行过的账完全不同 —— 见迁移抬头】
    --   unshipped_cancel  未发的那部分:还躺在 2500 里,从来没变成收入 → 借 2500
    --   revenue_reduction 已发的那部分减价/折让:收入已经认了 → 借 4000
    kind           text NOT NULL CHECK (kind IN ('unshipped_cancel','revenue_reduction')),
    -- 【数量可空,而且这不是偷懒】取消未发的那部分时,数量是一个真事实(少发几件);
    -- 而一次减价/质量折让往往【不对应任何数量】(整批降 2%、一次性折让),
    -- 硬要一个数量就得编一个。金额才是这张单据的主语,所以只有它 NOT NULL。
    qty            numeric CHECK (qty IS NULL OR qty > 0),
    amount         numeric NOT NULL CHECK (amount > 0),
    created_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.credit_note_lines IS
    'CN-1:贷项凭证的行 —— 一行冲【一张发票行】的一部分。kind 决定它过到哪个科目:unshipped_cancel 冲的是【还躺在 2500 里、从来没变成收入】的那部分(货没发出去),revenue_reduction 冲的是【已经交付、收入已认】的那部分(事后减价/质量折让)。两者都贷 1100。把它们合成一种就会让短装去借 4000 —— 那等于把一次正确的交付说成少卖了。qty 可空是有意的:取消未发部分时数量是真事实,而一次整批折让往往不对应任何数量,硬要就得编一个;金额才是主语。只增不改。';

COMMENT ON COLUMN public.credit_note_lines.amount IS
    'CN-1:本行冲减的金额,以【单据币种】计(= 发票的币种,凭证从发票抄过来)。本位币额不存 —— 它是 amount × credit_notes.fx_rate,而那个汇率也是抄来的:存第二份就是给同一个数留两个会漂开的写法(invoice_document_totals 的同一条理由)。';

CREATE INDEX idx_credit_note_lines_note ON public.credit_note_lines (credit_note_id);
CREATE INDEX idx_credit_note_lines_invoice_line ON public.credit_note_lines (invoice_line_id);

-- ═══ 3 · 签发档(形状逐字取自 so_issues)════════════════════════════════════
CREATE TABLE public.cn_issues (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    credit_note_id uuid NOT NULL REFERENCES public.credit_notes (id),
    version        integer NOT NULL CHECK (version >= 1),
    file_path      text NOT NULL,
    sha256         text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at      timestamptz NOT NULL DEFAULT now(),
    issued_by      uuid,
    UNIQUE (credit_note_id, version)
);

COMMENT ON TABLE public.cn_issues IS
    'CN-1:贷项凭证的签发档,形状逐字取自 so_issues / po_issues / shipment_issues(这是第四份,一个字没改)。谁、何时、第几版、哪个对象、字节摘要。【没有"已发送"标志】—— 系统不知道对方收没收到,而一个永远为 false 的标志会被读成"没发出去"。唯一写入口 record_cn_issue();重新签发 = 新的一行,绝不覆盖旧行 —— 客户手里那份是某个具体版本。';

CREATE INDEX idx_cn_issues_note ON public.cn_issues (credit_note_id, version DESC);

-- ═══ 4 · 守卫 ══════════════════════════════════════════════════════════════
-- 只增不改:凭证是过账单据,写错了不能改成对的 —— 那会让分录与单据分家。
CREATE OR REPLACE FUNCTION public.guard_credit_note_append_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【自己报名,不靠外键顺带挡】(FIN-31)—— 一句外键约束名既没说是哪张单据,
    -- 也没说下一步该做什么。
    RAISE EXCEPTION 'CREDIT_NOTE_IMMUTABLE|%', TG_OP;
END;
$function$;

CREATE TRIGGER trg_credit_notes_append_only
    BEFORE UPDATE OR DELETE ON public.credit_notes
    FOR EACH ROW EXECUTE FUNCTION public.guard_credit_note_append_only();

CREATE TRIGGER trg_credit_note_lines_append_only
    BEFORE UPDATE OR DELETE ON public.credit_note_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_credit_note_append_only();

CREATE TRIGGER trg_cn_issues_append_only
    BEFORE UPDATE OR DELETE ON public.cn_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_credit_note_append_only();

-- 【发票的 kind / 币种 / 汇率:由触发器把关,不只写在函数里】
-- CHECK 看不见另一张表(FIN-29 为这条写过一整段:规则跨两张表时约束不够用),
-- 所以这三件事是一个 BEFORE INSERT 守卫。它挡的是【将来某个人换一条路写入】:
-- 今天唯一的写入口是 create_credit_note,但守卫不该依赖"今天只有一个调用方"。
CREATE OR REPLACE FUNCTION public.guard_credit_note_invoice()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inv invoices%ROWTYPE;
BEGIN
    SELECT * INTO v_inv FROM invoices WHERE id = NEW.invoice_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CN_INVOICE_NOT_FOUND|%', COALESCE(NEW.invoice_id::text, '?');
    END IF;
    -- 【只对订单流发票】sale 型什么都不过账,它的应收长在 sales_records 上 ——
    -- 给它开一张贷项凭证会得到一笔冲着【不存在的分录】的分录。
    IF v_inv.kind <> 'order' THEN
        RAISE EXCEPTION 'CN_INVOICE_NOT_ORDER_KIND|%|%', v_inv.code, v_inv.kind;
    END IF;
    IF v_inv.status <> 'issued' THEN
        RAISE EXCEPTION 'CN_INVOICE_VOID|%', v_inv.code;
    END IF;
    -- 【抄过来的必须真的是抄的】见抬头:换个汇率冲会在本位币上留下一截
    -- 与真实已实现汇兑长得一模一样、却没有任何钱动过的残渣。
    IF NEW.currency IS DISTINCT FROM v_inv.currency THEN
        RAISE EXCEPTION 'CN_BASIS_MISMATCH|currency|%|%', v_inv.currency, NEW.currency;
    END IF;
    IF NEW.fx_rate IS DISTINCT FROM v_inv.fx_rate THEN
        RAISE EXCEPTION 'CN_BASIS_MISMATCH|fx_rate|%|%', v_inv.fx_rate, NEW.fx_rate;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_credit_notes_invoice_guard
    BEFORE INSERT ON public.credit_notes
    FOR EACH ROW EXECUTE FUNCTION public.guard_credit_note_invoice();

-- 【行必须属于它冲的那张发票】否则一张凭证可以冲到别人的发票行上,
-- 而上限是按发票行算的 —— 那等于绕过全部三条天花板。
CREATE OR REPLACE FUNCTION public.guard_credit_note_line_belongs()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_note_invoice uuid;
    v_line_invoice uuid;
BEGIN
    SELECT invoice_id INTO v_note_invoice FROM credit_notes WHERE id = NEW.credit_note_id;
    SELECT invoice_id INTO v_line_invoice FROM invoice_lines WHERE id = NEW.invoice_line_id;
    IF v_note_invoice IS DISTINCT FROM v_line_invoice THEN
        RAISE EXCEPTION 'CN_LINE_WRONG_INVOICE|%', COALESCE(NEW.invoice_line_id::text, '?');
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_credit_note_lines_belongs
    BEFORE INSERT ON public.credit_note_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_credit_note_line_belongs();

-- ═══ 5 · RLS —— 它是过账单据,跟着发票自己的那道门 ══════════════════════════
-- 【为什么是 module.finance.*,不是 module.sales.*】开票是财务的动作
-- (create_order_invoice 要 module.finance.edit),而贷项凭证是它的反面 ——
-- 它直接改总账与应收。跟着发票走,不另立一道。
ALTER TABLE public.credit_notes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_note_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cn_issues         ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT 策略,这是刻意的】唯一写入口是 create_credit_note(属主权限,
-- 同一个事务里过账 + 写单头 + 写行)。留着侧门,下一个人照样可以插一张
-- 【没有分录、不受任何天花板约束】的凭证 —— 与 SO-2b 撤掉建单 INSERT 策略
-- 逐字同一条理由。签发档同理(留痕不该有第二个写法)。
CREATE POLICY "credit_notes select by permission" ON public.credit_notes
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));
CREATE POLICY "credit_note_lines select by permission" ON public.credit_note_lines
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));
CREATE POLICY "cn_issues select by permission" ON public.cn_issues
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));

-- ═══ 6 · 取号:自己的咨询锁 ════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.next_credit_note_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁,而不是跟发票共用 'invoice_code_<year>'】两种单据各自
    -- 连号:CN-2026-0001 与 INV-2026-0001 是两个序列。共用一把锁会让贷项凭证
    -- 烧掉发票的号(反过来也一样),而无缝的意思正是"号码之间没有洞"。
    PERFORM pg_advisory_xact_lock(hashtext('credit_note_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM credit_notes
    WHERE code LIKE 'CN-' || v_year::text || '-%';
    RETURN 'CN-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ═══ 7 · 分录的来源类型 ════════════════════════════════════════════════════
-- 【现金流量表侧想过了,与 'invoice' / 'shipment' 逐字同一条】贷项凭证的分录
-- 碰的是 2500 / 4000 / 1100,一个 is_cash 科目都不碰 —— cash_flow_statement
-- 只看【碰了现金的】分录,所以它进不了那张表,连归类分支都走不到。真正的现金
-- 在收款那一步,走既有的 ELSE 'operating'。
ALTER TABLE public.journal_entries DROP CONSTRAINT journal_entries_source_type_check;
ALTER TABLE public.journal_entries ADD CONSTRAINT journal_entries_source_type_check
    CHECK (source_type = ANY (ARRAY['manual','purchase','sale','processing_cost','allocation',
        'stocktake','writeoff','payment','fx','expense','prepayment','payroll','transfer',
        'revaluation','depreciation','asset_disposal','year_close','freight','invoice','shipment',
        'credit_note']));

-- ═══ 8 · 开放余额:【一处推导】现在要减掉贷项凭证 ═══════════════════════════
-- 【为什么劈成两张视图,而不是在原来那张上改】原来那张带着 open_ccy > 0 的过滤,
-- 因为它的两个消费方问的都是"还欠着的有哪些"。而 create_credit_note 的天花板
-- 要问的是【这张发票现在还剩多少】—— 那个答案可以是 0,而 0 在一张过滤掉
-- 非正数的视图里表现为【没有行】。
-- 把"没有行"读成 0 正是这个仓库反复修的那条毛病(失败/空集不分)。所以:
--   order_invoice_balance_all  不过滤,算术只写这一遍,凭证的天花板读它
--   order_invoice_open_all     = 上面那张 WHERE open_ccy > 0,两个老消费方一字未动
-- 两张视图,一处算术。
CREATE VIEW public.order_invoice_balance_all WITH (security_invoker = off) AS
 SELECT i.id AS invoice_id,
    i.code,
    i.customer_id,
    i.issue_date,
    i.due_date,
    i.currency,
    i.fx_rate,
    l.amount_ccy,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_ccy,
    -- 【减掉贷项凭证】收了钱是"结清",开了贷项凭证是"不再欠" —— 对"还剩多少"
    -- 这个问题它们是同一个方向,所以在这里合并;但两者【分列】报出去,
    -- 因为它们在客户那里是两件完全不同的事(付过 vs 不用付了)。
    round(l.amount_ccy - COALESCE(s.settled, 0::numeric) - COALESCE(cn.credited, 0::numeric), 2) AS open_ccy,
    round((l.amount_ccy - COALESCE(s.settled, 0::numeric) - COALESCE(cn.credited, 0::numeric)) * i.fx_rate, 2) AS open_base,
    round(COALESCE(cn.credited, 0::numeric), 2) AS credited_ccy,
    round(COALESCE(cn.credited, 0::numeric) * i.fx_rate, 2) AS credited_base
   FROM invoices i
     JOIN LATERAL ( SELECT COALESCE(sum(il.amount_ccy), 0::numeric) AS amount_ccy
           FROM invoice_lines il
          WHERE il.invoice_id = i.id) l ON true
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.invoice_id = i.id) s ON true
     LEFT JOIN LATERAL ( SELECT sum(cl.amount) AS credited
           FROM credit_note_lines cl
             JOIN credit_notes c ON c.id = cl.credit_note_id
          WHERE c.invoice_id = i.id) cn ON true
  WHERE i.kind = 'order'::text AND i.status = 'issued'::text;

COMMENT ON VIEW public.order_invoice_balance_all IS
    'CN-1:订单流发票的余额 ——【应收、敞口与贷项凭证天花板共同的那一处算术】,不带任何过滤。open_ccy = Σ 明细行 − Σ 已结(posted 收款的核销)− Σ 已贷记(本发票的贷项凭证行)。三个消费方:order_invoice_open_all(它就是本视图 WHERE open_ccy > 0,老的两个消费方因此一字未动)、create_credit_note 的天花板、invoice_status 的贷记列。【为什么不带过滤】天花板要问"现在还剩多少",而那个答案可以是 0 —— 在一张过滤掉非正数的视图里 0 表现为【没有行】,把"没有行"读成 0 正是本仓库反复修的那条毛病。【客户端读不到】:REVOKE SELECT —— 它不带 has_permission 的门。';

REVOKE SELECT ON public.order_invoice_balance_all FROM authenticated, anon;

-- 老的那张:同样的列序 + 末尾两列,于是 CREATE OR REPLACE 够用,
-- ar_open_items 与 operations_now 都不必重建(它们依赖着它)。
CREATE OR REPLACE VIEW public.order_invoice_open_all WITH (security_invoker = off) AS
 SELECT b.invoice_id,
    b.code,
    b.customer_id,
    b.issue_date,
    b.due_date,
    b.currency,
    b.fx_rate,
    b.amount_ccy,
    b.settled_ccy,
    b.open_ccy,
    b.open_base,
    b.credited_ccy,
    b.credited_base
   FROM order_invoice_balance_all b
  WHERE b.open_ccy > 0::numeric;

COMMENT ON VIEW public.order_invoice_open_all IS
    'SO-3a:订单流发票的开放余额 —— 应收账龄第二支与信用敞口第二项共同的那一个数。【CN-1 起它自己不再做算术】:算术在 order_invoice_balance_all 里(那里还减掉了贷项凭证),本视图只是它的 WHERE open_ccy > 0。劈成两张是因为天花板要问"现在还剩多少",而那个答案可以是 0 —— 在带过滤的视图里 0 表现为没有行,而把"没有行"读成 0 正是本仓库反复修的那条毛病。两个老消费方(ar_open_items 第二支、customer_ar_exposure_base 第二项)因此一字未动。【客户端读不到】:REVOKE SELECT。';

-- ═══ 9 · 账龄:把【已贷记】单列出来,否则那一行自己加不起来 ═════════════════
-- 【为什么必须加这两列】账龄页印的是 金额 / 已结 / 未结 三个数。贷项凭证
-- 只让 open 变小,而 settled 一个字不动 —— 于是 金额 − 已结 ≠ 未结,读的人
-- 会以为页面算错了。把它单列出来,三个数重新加得起来,而且它说的是一件
-- 与"收过钱"完全不同的事:这一截【不用付了】。
CREATE OR REPLACE VIEW public.ar_open_items WITH (security_invoker = off) AS
 SELECT sr.id AS sales_record_id,
    ob.code AS doc_code,
    sr.customer_id,
    c.legal_name AS customer_name,
    sr.sale_date,
    sr.amount_base,
    sr.currency,
    round(sr.quantity * sr.unit_price, 2) AS amount_ccy,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_ccy,
    round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric), 2) AS open_ccy,
    round((sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric)) * sr.fx_rate, 2) AS open_base,
    CURRENT_DATE - sr.sale_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - sr.sale_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket,
    inv.invoice_id,
    inv.invoice_code,
    'sale'::text AS doc_kind,
    round(COALESCE(s.settled, 0::numeric) * sr.fx_rate, 2) AS settled_base,
    -- 【第一支恒为 0,而这是一句断言而不是占位】贷项凭证只绑 kind='order' 的
    -- 发票(guard_credit_note_invoice 按名拒),而第一支是 sale 型那条路。
    -- 写 0 而不是 NULL:这里的 0 是"确实没有",不是"不知道"。
    0::numeric AS credited_ccy,
    0::numeric AS credited_base
   FROM sales_records_masked sr
     JOIN output_batches ob ON ob.id = sr.output_batch_id
     LEFT JOIN customers c ON c.id = sr.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.sales_record_id = sr.id) s ON true
     LEFT JOIN LATERAL ( SELECT i.id AS invoice_id,
            i.code AS invoice_code
           FROM invoice_lines_masked il
             JOIN invoices_masked i ON i.id = il.invoice_id
          WHERE il.sales_record_id = sr.id AND NOT il.invoice_voided
         LIMIT 1) inv ON true
  WHERE round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric), 2) > 0::numeric
    AND sr.sales_order_line_id IS NULL
    AND has_permission('module.finance.view'::text)
UNION ALL
 SELECT NULL::uuid AS sales_record_id,
    o.code AS doc_code,
    o.customer_id,
    c.legal_name AS customer_name,
    o.issue_date AS sale_date,
    round(o.amount_ccy * o.fx_rate, 2) AS amount_base,
    o.currency,
    o.amount_ccy,
    o.settled_ccy,
    o.open_ccy,
    o.open_base,
    CURRENT_DATE - o.issue_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - o.issue_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - o.issue_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - o.issue_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket,
    o.invoice_id,
    o.code AS invoice_code,
    'invoice'::text AS doc_kind,
    round(o.settled_ccy * o.fx_rate, 2) AS settled_base,
    o.credited_ccy,
    o.credited_base
   FROM order_invoice_open_all o
     LEFT JOIN customers c ON c.id = o.customer_id
  WHERE has_permission('module.finance.view'::text) AND has_permission('data.view_prices'::text);

-- ═══ 10 · 发票状态:已贷记单列,而【标签不动】═══════════════════════════════
-- 【payment_state 的三个值一个都没新增,这是一个有意的克制】
-- 一张被全额贷记、一分钱没收的发票,按现在的判据会读成 'paid' —— 那句话是
-- 假的(没有人付过钱)。但"settled_by_credit"是一个【新的业务标签】,而这份
-- 单据的状态该怎么说给客户听,不是可以在实现里顺手定下来的事。
-- 所以这一刀只做两件不需要那个决定的事:把已贷记【单列】出来,让页面能说出
-- "付了 X、贷记了 Y";以及让 open_base 把它减掉(那是算术,不是措辞)。
-- 标签的问题原样报给 Tim,见切次报告。
CREATE OR REPLACE VIEW public.invoice_status WITH (security_invoker = off) AS
 SELECT i.id AS invoice_id,
    i.code,
    i.customer_id,
    c.legal_name AS customer_name,
    i.issue_date,
    i.due_date,
    i.currency,
    i.total_base,
    round(COALESCE(s.settled, 0::numeric) + COALESCE(sd.settled, 0::numeric), 2) AS settled_base,
    round(i.total_base - COALESCE(s.settled, 0::numeric) - COALESCE(sd.settled, 0::numeric)
          - COALESCE(b.credited_base, 0::numeric), 2) AS open_base,
    GREATEST(CURRENT_DATE - i.due_date, 0) AS days_overdue,
        CASE
            WHEN round(i.total_base - COALESCE(s.settled, 0::numeric) - COALESCE(sd.settled, 0::numeric)
                       - COALESCE(b.credited_base, 0::numeric), 2) <= 0::numeric THEN 'paid'::text
            WHEN COALESCE(s.settled, 0::numeric) + COALESCE(sd.settled, 0::numeric)
                 + COALESCE(b.credited_base, 0::numeric) > 0::numeric THEN 'partial'::text
            ELSE 'unpaid'::text
        END AS payment_state,
    CURRENT_DATE > i.due_date AND round(i.total_base - COALESCE(s.settled, 0::numeric)
        - COALESCE(sd.settled, 0::numeric) - COALESCE(b.credited_base, 0::numeric), 2) > 0::numeric AS overdue,
    i.kind,
    -- 【已贷记,单列,而且两种钱都给】sale 型恒为 0(贷项凭证只绑 order 型),
    -- 而这里的 0 是"确实没有"而不是"不知道"。数字来自 order_invoice_balance_all
    -- —— 与天花板、与账龄读的是同一处算术。
    -- 【为什么这张全本位币的视图上多一个单据币种的列】发票详情页面向客户,
    -- 印的是【单据币种】那三个数(INV-1:拿本位币的数去标单据币种,线上两张
    -- 已发出的发票各多报过 1,440 / 336 USD)。那一页自己减出 open,如果它再
    -- 自己去 sum 一遍贷项凭证行,这个数就有了第四份实现。给它一个列,
    -- 它就仍然是在【问】而不是在【算】。
    COALESCE(b.credited_ccy, 0::numeric) AS credited_ccy,
    COALESCE(b.credited_base, 0::numeric) AS credited_base
   FROM invoices_masked i
     JOIN customers c ON c.id = i.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled
           FROM invoice_lines_masked il
             JOIN payment_allocations pa ON pa.sales_record_id = il.sales_record_id
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE il.invoice_id = i.id) s ON true
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.invoice_id = i.id) sd ON true
     LEFT JOIN order_invoice_balance_all b ON b.invoice_id = i.id
  WHERE i.status <> 'void'::text AND has_permission('module.finance.view'::text);

-- ═══ 11 · 开凭证 ═══════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.create_credit_note(p_invoice_id uuid, p_note_date date, p_reason text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_inv      invoices%ROWTYPE;
    v_cn_id    uuid := gen_random_uuid();
    v_code     text;
    v_open     numeric;
    v_el       jsonb;
    v_line_id  uuid;
    v_kind     text;
    v_amount   numeric;
    v_total    numeric := 0;
    v_a_total  numeric := 0;
    v_b_total  numeric := 0;
    v_grp      record;
    v_shipped  numeric;
    v_released numeric;
    v_ceiling  numeric;
    v_prior    numeric;
    v_je       jsonb;
    v_jlines   jsonb;
    v_n        int;
BEGIN
    -- 【为什么是 module.finance.edit】它直接改总账与应收 —— 与
    -- create_order_invoice(开票)同一道门。开票认下债,这张把债减回去。
    PERFORM require_permission('module.finance.edit');

    -- 【单据日必填,永不默认】它决定冲销落进哪个期间。补一个 CURRENT_DATE
    -- 会让留空比填对更容易通过:今天的日期永远撞不上 PERIOD_LOCKED。
    IF p_note_date IS NULL THEN
        RAISE EXCEPTION 'CN_NOTE_DATE_REQUIRED';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'CN_REASON_REQUIRED';
    END IF;

    SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CN_INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    -- 【这两条守卫【也】在触发器上】这里再问一遍,是为了在算任何天花板之前
    -- 就给出正确的名字 —— 触发器要到 INSERT 那一刻才说话,而那时人已经
    -- 填完整张表单了(CMP-2:禁用与说明要在动作之前)。
    IF v_inv.kind <> 'order' THEN
        RAISE EXCEPTION 'CN_INVOICE_NOT_ORDER_KIND|%|%', v_inv.code, v_inv.kind;
    END IF;
    IF v_inv.status <> 'issued' THEN
        RAISE EXCEPTION 'CN_INVOICE_VOID|%', v_inv.code;
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'CN_NO_LINES|%', v_inv.code;
    END IF;

    -- ── 天花板 ①:整张凭证 ≤ 这张发票【当下的】开放余额 ─────────────────────
    -- 读的是那一处不带过滤的算术(order_invoice_balance_all)。带过滤的那张
    -- 在 open = 0 时【没有行】,而把"没有行"读成 0 正是本仓库反复修的毛病 ——
    -- 这里要的恰恰是那个 0,并且要为它给出一个【专门的名字】。
    SELECT open_ccy INTO v_open FROM order_invoice_balance_all WHERE invoice_id = p_invoice_id;
    IF v_open IS NULL THEN
        -- issued + order 型必有一行(上面两条已经排除了别的情形)。走到这里
        -- 说明视图的前提变了 —— 当场炸,不要把它当成 0(那会让天花板消失)。
        RAISE EXCEPTION 'CN_BALANCE_MISSING|%', v_inv.code;
    END IF;
    IF v_open <= 0 THEN
        -- 【已经结清的发票不能再贷记】要还的是【现金】,那是一张付款单加一个
        -- 客户贷余概念,而这个系统今天没有客户贷余的落脚点。按名拒,
        -- 而不是让应收变成负数(那会在账龄上凭空消失、在敞口里悄悄抵扣)。
        RAISE EXCEPTION 'CN_INVOICE_FULLY_SETTLED|%', v_inv.code;
    END IF;

    -- ── 逐行校验 ────────────────────────────────────────────────────────────
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_line_id := NULLIF(v_el->>'invoice_line_id', '')::uuid;
        v_kind    := v_el->>'kind';
        v_amount  := NULLIF(v_el->>'amount', '')::numeric;

        IF v_line_id IS NULL THEN
            RAISE EXCEPTION 'CN_LINE_INVALID|%|%', COALESCE(v_el->>'line_no', '?'), 'invoice_line_id';
        END IF;
        IF v_kind IS NULL OR v_kind NOT IN ('unshipped_cancel','revenue_reduction') THEN
            RAISE EXCEPTION 'CN_LINE_INVALID|%|%', COALESCE(v_el->>'line_no', '?'), 'kind';
        END IF;
        IF v_amount IS NULL OR v_amount <= 0 THEN
            RAISE EXCEPTION 'CN_LINE_INVALID|%|%', COALESCE(v_el->>'line_no', '?'), 'amount';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM invoice_lines WHERE id = v_line_id AND invoice_id = p_invoice_id) THEN
            RAISE EXCEPTION 'CN_LINE_WRONG_INVOICE|%', v_line_id;
        END IF;

        v_total := v_total + v_amount;
        IF v_kind = 'unshipped_cancel' THEN v_a_total := v_a_total + v_amount;
        ELSE                                v_b_total := v_b_total + v_amount; END IF;
    END LOOP;

    IF round(v_total, 2) > round(v_open, 2) THEN
        RAISE EXCEPTION 'CN_EXCEEDS_OPEN|%|%', round(v_total, 2), round(v_open, 2);
    END IF;

    -- ── 天花板 ② / ③:逐【发票行 × 类型】────────────────────────────────────
    -- 【按分组算,不是逐条算】一张凭证可以在同一发票行上放两条同类型的行,
    -- 逐条检查会让两条各自"没超"、合起来超掉。分组之后再与【历史】相加。
    FOR v_grp IN
        SELECT (e->>'invoice_line_id')::uuid AS line_id,
               e->>'kind' AS kind,
               sum((e->>'amount')::numeric) AS want
        FROM jsonb_array_elements(p_lines) e
        GROUP BY 1, 2
    LOOP
        -- 这一行【已发】多少 —— 读 shipment_lines(货真的离开台账的记录,
        -- 与 line_spoken_for 同一个理由)。
        -- 【为什么可以拿发票行的单价去乘】SO-1b 起,坐在在册发票上的订单行
        -- 数量与单价【整个冻住】(SO_AMEND_LINE_INVOICED),所以发票行的单价
        -- 与发货当时用的那个是同一个数。这一条是本段算术的前提,不是巧合。
        SELECT COALESCE(sum(sl.qty), 0) INTO v_shipped
          FROM shipment_lines sl
          JOIN invoice_lines il ON il.sales_order_line_id = sl.sales_order_line_id
         WHERE il.id = v_grp.line_id;
        SELECT round(v_shipped * il.unit_price, 2) INTO v_released
          FROM invoice_lines il WHERE il.id = v_grp.line_id;

        -- 这一行同类型的【历史】贷记额
        SELECT COALESCE(sum(cl.amount), 0) INTO v_prior
          FROM credit_note_lines cl
         WHERE cl.invoice_line_id = v_grp.line_id AND cl.kind = v_grp.kind;

        IF v_grp.kind = 'unshipped_cancel' THEN
            -- 未释放的负债 = 这一行开票额 − 已释放进收入的部分
            SELECT round(il.amount_ccy - v_released, 2) INTO v_ceiling
              FROM invoice_lines il WHERE il.id = v_grp.line_id;
            v_ceiling := round(v_ceiling - v_prior, 2);
            IF round(v_grp.want, 2) > v_ceiling THEN
                RAISE EXCEPTION 'CN_EXCEEDS_UNRELEASED|%|%|%',
                    (SELECT line_no FROM invoice_lines WHERE id = v_grp.line_id),
                    round(v_grp.want, 2), v_ceiling;
            END IF;
        ELSE
            v_ceiling := round(v_released - v_prior, 2);
            IF round(v_grp.want, 2) > v_ceiling THEN
                RAISE EXCEPTION 'CN_EXCEEDS_RELEASED|%|%|%',
                    (SELECT line_no FROM invoice_lines WHERE id = v_grp.line_id),
                    round(v_grp.want, 2), v_ceiling;
            END IF;
        END IF;
    END LOOP;

    -- ── 过账:一张分录 ──────────────────────────────────────────────────────
    -- 【借 2500 未释放的那部分 / 借 4000 已释放的那部分 / 贷 1100 合计】
    -- 单据币种,按【发票存下来的】汇率 —— 见迁移抬头:换个汇率会凭空造出
    -- 一笔看起来完全正常的已实现汇兑,而没有任何钱动过。
    -- 【0 金额的腿一条都不发】post_journal_entry 的 amount_ccy > 0 会拒,
    -- 而且一条 0 的腿在分录上读起来像"这一段发生了但金额为零"。
    v_code := next_credit_note_code(p_note_date);
    v_jlines := '[]'::jsonb;
    IF v_a_total > 0 THEN
        v_jlines := v_jlines || jsonb_build_object('account_code', '2500', 'side', 'debit',
            'currency', v_inv.currency, 'amount_ccy', round(v_a_total, 2), 'fx_rate', v_inv.fx_rate,
            'line_memo', 'unshipped cancelled');
    END IF;
    IF v_b_total > 0 THEN
        v_jlines := v_jlines || jsonb_build_object('account_code', '4000', 'side', 'debit',
            'currency', v_inv.currency, 'amount_ccy', round(v_b_total, 2), 'fx_rate', v_inv.fx_rate,
            'line_memo', 'revenue reduction');
    END IF;
    v_jlines := v_jlines || jsonb_build_object('account_code', '1100', 'side', 'credit',
        'currency', v_inv.currency, 'amount_ccy', round(v_total, 2), 'fx_rate', v_inv.fx_rate);

    v_je := post_journal_entry(
        p_note_date,
        'Credit note ' || v_code || ' · ' || v_inv.code,
        'credit_note', v_cn_id,
        v_jlines);

    -- 【先过账再写单头】entry_id 因此可以是 NOT NULL,不需要"先写空、再回填"
    -- 那种单向放宽(与 create_order_invoice 逐字同一个顺序)。
    INSERT INTO credit_notes (id, code, invoice_id, reason, note_date, entry_id,
                              currency, fx_rate, created_by)
    VALUES (v_cn_id, v_code, p_invoice_id, btrim(p_reason), p_note_date,
            (v_je->>'entry_id')::uuid, v_inv.currency, v_inv.fx_rate, v_user);

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO credit_note_lines (credit_note_id, invoice_line_id, kind, qty, amount)
        VALUES (v_cn_id,
                (v_el->>'invoice_line_id')::uuid,
                v_el->>'kind',
                NULLIF(v_el->>'qty', '')::numeric,
                (v_el->>'amount')::numeric);
    END LOOP;

    -- 【断言,不是假设】行的条数必须等于递进来的条数。将来有人给上面那个循环
    -- 加一个提前 CONTINUE,这里当场炸,而不是留下一张【分录按全部行算过、
    -- 明细却少了几条】的凭证 —— 那种凭证的总额与它自己的行对不上。
    SELECT count(*) INTO v_n FROM credit_note_lines WHERE credit_note_id = v_cn_id;
    IF v_n <> jsonb_array_length(p_lines) THEN
        RAISE EXCEPTION 'CN_LINES_LOST|%|%', jsonb_array_length(p_lines), v_n;
    END IF;

    -- 【订单历史也记一笔】看订单的人问"这张单后来减过账没有",那个问题的答案
    -- 不该要求他先去翻发票列表(与 'invoiced' / 'invoice_voided' 同一条)。
    IF v_inv.sales_order_id IS NOT NULL THEN
        INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
        VALUES (v_inv.sales_order_id, 'credit_noted',
                v_code || ' · ' || v_inv.currency || ' ' || trim_scale(round(v_total, 2))::text
                || ' · ' || btrim(p_reason), v_user);
    END IF;

    RETURN jsonb_build_object(
        'credit_note_id', v_cn_id,
        'code', v_code,
        'invoice_code', v_inv.code,
        'note_date', p_note_date,
        'currency', v_inv.currency,
        'fx_rate', v_inv.fx_rate,
        'total_ccy', round(v_total, 2),
        'total_base', round(round(v_total, 2) * v_inv.fx_rate, 2),
        'unshipped_cancel_ccy', round(v_a_total, 2),
        'revenue_reduction_ccy', round(v_b_total, 2),
        'line_count', v_n,
        'open_ccy_after', round(v_open - v_total, 2),
        'journal_code', v_je->>'code');
END;
$function$;

COMMENT ON FUNCTION public.create_credit_note(uuid, date, text, jsonb) IS
    'CN-1:开一张贷项凭证 —— 唯一写入口(credit_notes 没有 INSERT 策略)。三条天花板各自按名拒并报出数字:整张 ≤ 发票【当下的】开放余额(CN_EXCEEDS_OPEN;已结清 → CN_INVOICE_FULLY_SETTLED,退款是停放的概念)、unshipped_cancel 行 ≤ 该发票行未释放的负债(CN_EXCEEDS_UNRELEASED)、revenue_reduction 行 ≤ 该行已释放的收入减去历史贷记(CN_EXCEEDS_RELEASED)。天花板按【发票行 × 类型】分组算,因为一张凭证可以在同一行上放两条同类型的行。过账一张分录:借 2500(未发的那部分,它从来没变成收入)/ 借 4000(已发的那部分减价)/ 贷 1100,单据币种、按发票存下来的汇率 —— 换个汇率会凭空造出一笔看起来完全正常的已实现汇兑而没有任何钱动过。';

-- ═══ 12 · 签发 ═════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.record_cn_issue(p_credit_note_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cn   credit_notes%ROWTYPE;
    v_next integer;
BEGIN
    -- 【签发要 finance.edit,与开票同一道门】签发出去的是一份对外单据。
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_cn FROM credit_notes WHERE id = p_credit_note_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CN_NOT_FOUND|%', COALESCE(p_credit_note_id::text, '?');
    END IF;

    -- 【没有"草稿"这一档,所以没有对应的拒绝】凭证一出生就已经过账了
    -- (先过账再写单头),不存在"还不是承诺"的中间态 —— 与销售订单不同。
    PERFORM pg_advisory_xact_lock(hashtext('cn_issue_' || p_credit_note_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next FROM cn_issues WHERE credit_note_id = p_credit_note_id;

    INSERT INTO cn_issues (credit_note_id, version, file_path, sha256, issued_by)
    VALUES (p_credit_note_id, v_next, p_file_path, p_sha256, auth.uid());

    RETURN jsonb_build_object('version', v_next);
END;
$function$;

-- ═══ 13 · 订单历史的新类型 ═════════════════════════════════════════════════
ALTER TABLE public.sales_order_history
    DROP CONSTRAINT IF EXISTS sales_order_history_change_type_check;
ALTER TABLE public.sales_order_history
    ADD CONSTRAINT sales_order_history_change_type_check CHECK (change_type IN
        ('created','confirmed','closed','cancelled','line_added','line_changed','line_removed','issued',
         'reserved','released','invoiced','invoice_voided','shipped',
         'header_update','line_update','line_add','line_remove',
         -- CN-1:开了一张贷项凭证。看订单的人问"这张单后来减过账没有",
         -- 那个问题的答案不该要求他先去翻发票列表。
         'credit_noted'));

-- ═══ 14 · 桶 + 它的两条门(【同一支迁移里】—— SO-1 那次桶先建门后补,
--          签发当场 500,是手走才发现的;SO-3b 起就不再重演)════════════════
INSERT INTO storage.buckets (id, name, public)
VALUES ('cn-documents', 'cn-documents', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "authenticated read cn-documents"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'cn-documents'::text);

CREATE POLICY "authenticated upload cn-documents"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'cn-documents'::text);

COMMIT;
