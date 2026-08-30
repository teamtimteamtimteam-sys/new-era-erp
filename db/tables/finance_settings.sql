-- db/tables/finance_settings.sql
-- Single-row finance settings. locked_before is the period lock: journal
-- entries dated before it are rejected by post_journal_entry (PERIOD_LOCKED).
-- The boolean-true PK enforces the single row.
--
-- GST 三列:公司尚未做 GST 登记,先把字段建好,让"登记"变成改设置而不是改表结构
-- (税金分录本身留给后续切次,见 cut 2a 迁移头注释)。
--
-- NOTE: introduced by db/migrations/2026-07-05-phase3-cut1-finance-foundation.sql;
-- gst_registered / gst_rate_pct / gst_registration_no added by
-- db/migrations/2026-07-31-phase4-cut2a-invoices.sql —— 该切次【漏了同步本镜像】,
-- 2026-07-31 的镜像漂移审计发现后补正(同 journal_entries.sql 的 source_type 一课:
-- 动表的迁移必须在同一提交里更新镜像)。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG —— 下面的种子是"全新安装的默认值",不是线上快照】
-- 界面上可以改(app/finance/settings/actions.ts:24 写 locked_before)。
-- 所以【线上与本文件不一致是正常的,不是漂移】,check_mirrors.py 不把本表与线上比对。
-- 它只保证镜像这一套自己首尾相顾(本文件引用到的码/科目都存在于对应的种子里)。
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE public.finance_settings (
    id                  boolean PRIMARY KEY DEFAULT true CHECK (id),  -- 单行表:PK 恒为 true
    locked_before       date,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          uuid DEFAULT auth.uid(),
    gst_registered      boolean NOT NULL DEFAULT false,
    gst_rate_pct        numeric NOT NULL DEFAULT 0
                        CHECK (gst_rate_pct >= 0 AND gst_rate_pct <= 100),
    gst_registration_no text,
    -- ── HR-5 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 本库开始运营的日期,安装时申报。早于它的年度动作一律拒绝。
    system_start_date date,
    -- ── FIN-23 追加(ALTER 加的列排在末尾)──────────────────────────────────
    -- 财年配置:申报,不推断(新加坡公司自选财年,不得假设 12/31)。
    -- 引导默认 12/31 即 Tim 申报的 FYE —— RUNTIME CONFIG:默认值就是申报值,正确。
    -- first_fy_end 可空:首个财年可长达 18 个月,定了以显式日期为准,留空按循环推。
    fy_end_month integer NOT NULL DEFAULT 12 CHECK (fy_end_month BETWEEN 1 AND 12),
    fy_end_day integer NOT NULL DEFAULT 31 CHECK (fy_end_day BETWEEN 1 AND 31),
    first_fy_end date,
    -- FIN-36:新建加工单时表单【预选】的分摊基准。这是 RUNTIME CONFIG ——
    -- 操作员在设置页上看得见、改得动,与 processing_runs 上那个已被删掉的 schema
    -- 默认值的区别就在这里(FIN-35 的判别法:看得见的默认值不是假设)。
    default_allocation_basis text NOT NULL DEFAULT 'metal_value'
        CHECK (default_allocation_basis IN ('weight','metal_value')),
    -- ── APR-2:审批策略。三个值【全部可空,空 = 引擎拒绝路由】────────────────
    -- A1(一级角色)与 A2(阈值)是 Tim 的决定,不是代码的 —— 候选、含义与线上
    -- 金额分布的证据见 docs/approvals-scoping.md。没设好的管控不等于可以跳过管控。
    approval_level1_role_code text REFERENCES public.roles (code),
    approval_threshold_base   numeric CHECK (approval_threshold_base IS NULL
                                             OR approval_threshold_base > 0),
    -- APR-2c:审批流是否生效。【默认 false 是有意的】—— 四眼规则在只有一个人类
    -- 账号的系统里无法运转,而"没配就拒绝"会把采购整个停掉;空配置与不能用的
    -- 系统是同一个结果。三态见 db/migrations/2026-08-09-apr2c-*.sql 的文件头。
    approvals_enabled boolean NOT NULL DEFAULT false,
    -- ── CHAIN-BUILD-1 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────
    -- 【二级从此也指向一个【角色】】它取代了 approval_level2_user_id(已退役)。
    -- 形状与一级【逐字相同】—— 两级不同形,下一个读的人就得先分辨它们哪里不同。
    approval_level2_role_code text REFERENCES public.roles (code)
);

INSERT INTO public.finance_settings (id, locked_before) VALUES (true, NULL);

CREATE TRIGGER trg_finance_settings_updated_at
    BEFORE UPDATE ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- SOD-1:两道闸。本表在此之前【只有】上面那个 updated_at 触发器,
-- 所以这两个是它的第一道真正的守卫 —— 两个方向都做过故障注入(fixture 127)。
--
-- ① 职责分离:记过手工凭证的人,不得把那个期间锁上。
--    /finance/settings 的"手动锁"是一条【直连 UPDATE】,不经过 close_period,
--    而 authenticated 对本表持表级 UPDATE 授权。只管前进的锁;往回搬不受管。
CREATE TRIGGER trg_finance_settings_sod
    BEFORE UPDATE ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION public.guard_finance_settings_sod();

-- ② 审批开关:开之前策略必须配齐且指向真的人(于是"开着但没配"【到不了】);
--    关之前在途的 pending 单必须清空(否则它们会永远停在 pending)。
CREATE TRIGGER trg_approvals_switch
    BEFORE UPDATE ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION public.guard_approvals_switch();

-- ③ GST-3:注册开关的两个方向。
--    开 → 登记号必须在册(IRAS 要求税务发票印它,而发票 PDF 在号码为空时
--         那一行【整条消失】—— 不是拒绝出票,是安静地不印)。
--    关 → 两条拒绝、两个【不同】的理由:带税码的费用单关掉之后冲销不了
--         (机械事实);在册的带税发票冲销得了,但会留下"账上报着供应额、
--         公司却说那一季未注册"的矛盾状态(判断)。
--    【为什么闸在库上而不是在 server action 上】开关今天就是由 SQL 翻的,
--    而 module.finance.edit 经 RLS 直接授予 UPDATE —— 只住在 action 里的闸
--    恰好挡不住会用它的那批人。与上面 ② 同一个落点、同一个理由。
CREATE TRIGGER trg_gst_switch
    BEFORE UPDATE OF gst_registered, gst_registration_no ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION public.guard_gst_switch();

ALTER TABLE public.finance_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "finance_settings select by permission"
    ON public.finance_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "finance_settings insert by permission"
    ON public.finance_settings
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "finance_settings update by permission"
    ON public.finance_settings
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "finance_settings delete by permission"
    ON public.finance_settings
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'::text));

COMMENT ON COLUMN public.finance_settings.system_start_date IS
    '本库自哪一天起持有【完整】记录 —— 不是安装日、也不一定是切换日。若切换前的交易会被补录进来,取【最早那笔真实交易】的日期。所有年度性守卫(年末结转、医疗额度)以它为界:早于它的期间,本库的数据不完整,任何据此推算的余额或额度都是凭空的。取错不会报错,只会让守卫站错位置。';

COMMENT ON COLUMN public.finance_settings.fy_end_month IS
    '财年末的月份(FIN-23,申报值 —— 新加坡公司自选财年,不得假设 12/31)。与 fy_end_day 一起推导每个财年末;首年可被 first_fy_end 覆盖。';
COMMENT ON COLUMN public.finance_settings.fy_end_day IS
    '财年末的日(FIN-23)。短月自动收敛到月末(2/30 → 2/28)。';
COMMENT ON COLUMN public.finance_settings.first_fy_end IS
    '首个财年末(FIN-23,可空)。新加坡首个财年可长达 18 个月 —— 留空按循环对推;定了以此为准。只影响第一次年结。';

COMMENT ON COLUMN public.finance_settings.default_allocation_basis IS
    '新建加工单时表单【预选】的分摊基准(FIN-36)。这是一个 RUNTIME CONFIG:操作员在设置页上看得见、改得动 —— 与 processing_runs 上那个已被删掉的 schema 默认值的区别就在这里,后者谁也看不见。真正记录"这一单用了什么"的仍然是 processing_runs.allocation_basis,由表单显式送上来。';

COMMENT ON COLUMN public.finance_settings.approval_level1_role_code IS
    '一级审批【角色】码。★【没有代理人、没有升级、没有破窗 —— 这是一条裁定,不是一处遗漏】★(R2,CHAIN-BUILD-1 2026-08-30):某一级的持有人不在,这一级的单据就【停着】,而且系统会把这件事【说出来】(就绪面板的三种状态),但**绝不绕过去**。互为代理被考虑过并否决了 —— 两个互为代理的人会让金额门槛失去意义。加第二个审批人是【分工】,不是【互为代理】。理由与写法见 docs/approvals.md。';

COMMENT ON COLUMN public.finance_settings.approval_threshold_base IS
    '二级审批的门槛,以【本位币】计(_base 后缀是本仓库表达币种的既定写法,同 amount_base/total_base)。达到或超过它就要具名审批人批。【空 = 未配置,引擎拒绝路由】—— 与 SYSTEM_START_NOT_SET 同一条规矩:没设好的管控不等于可以跳过管控。取值的证据(线上采购与进料的实际金额分布对 10k/25k/50k 的命中率)见 docs/approvals-scoping.md §A2。';

COMMENT ON COLUMN public.finance_settings.approval_level2_role_code IS
    'CHAIN-BUILD-1(R1):二级审批【角色】码。★它取代了 approval_level2_user_id★ —— 两列各能指定一个审批人,就是"谁可以批"的两份定义,而那是本仓库最老的漂移形状。旧列在线上是 NULL,所以本刀直接退役它,不留兼容期。**没有代理人、没有升级**(R2):这一级的人不在,这一级的单据就停着,那是裁定过的,不是漏掉的。';

COMMENT ON COLUMN public.finance_settings.approvals_enabled IS
    '审批流是否生效(APR-2c)。【默认 false,这是有意的】:四眼规则在只有一个人类账号的系统里无法运转,而"没配就拒绝"会把采购整个停掉 —— 空配置与不能用的系统是同一个结果。三种状态:off = 审批有意不生效,采购单直接建成 confirmed/approved 且【界面明说】;on 但策略为空 = 拒绝路由(启用却无策略是配置错误);on 且策略齐备 = 引擎照常跑。打开它的前置条件写在 docs/fresh-install-checklist.md:至少两个人类账号,且持 finance 的人不是提单人。';

COMMENT ON COLUMN public.finance_settings.gst_rate_pct IS
    'GST-2 起【已死】,GST-3 标注:**没有任何代码再读这一列**(db/ 与 app/ 各 0 处引用)。税率不再是一个标量 —— 它按生效期间挂在 tax_rates 上,由 tax_rate_for(code, date) 按【单据自己那一天】解析,因为一张 2022 年的发票永远是 7%,而一个标量表达不了这件事(那正是 GST-1 点名的原始错误)。**改这一列不会改变任何一张单据的税。** 留着它而不 DROP,是因为删它要动表镜像、生成类型与一圈 fixture,而那属于另一刀;这句注释是替代品,不是借口。';
