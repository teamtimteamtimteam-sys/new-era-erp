// app/finance/ledger/[account]/page.tsx
// 科目明细:一个报表数字背后的那些分录行。
//
// 【入口就是报表上的那一行】损益表与资产负债表的科目行现在是链接,链接把
// 【科目号】与【那张报表自己的期间】一起带过来。所以这一页永远是从一个具体
// 数字点进来的,而不是一个需要自己挑期间的独立报表。
//
// 【本页不算账】数字全部来自 db 的 account_ledger(...) —— 与损益表、资产负债表、
// 现金流量表同一个形状。而且三者读的是【同一段推导】:
// db/functions/journal_activity_lines.sql(三表连接、刻意不过滤 status、
// 一条符号规则)。理由写在那个文件的抬头。
//
// ── 两个口径,由 mode 一个参数决定 ──────────────────────────────────────────
// 损益表下钻   ?mode=pnl&from=…&to=…   → account_ledger(code, from, to, false)
// 资产负债下钻 ?mode=bs&as_of=…        → account_ledger(code, NULL, as_of, true)
//
// 【为什么是一个 mode 而不是两个开关】年结分录的剔除/包含与日期形状【总是配套的】
// (FIN-23 的刻意不对称)。把它们做成两个独立参数,就等于允许四种组合,其中两种
// 无论如何都对不上任何一张报表 —— 而对不上的那个数字看起来会像报表错了。
//
// ── 并排显示的那两个数,以及它能查出什么 ────────────────────────────────────
// 屏幕上同时显示【本页明细的合计】与【那张报表自己报的数字】。
//
// 【说清楚它不是一个自证的对账】(AGENTS.md / OPS-17:两个数只有能分开动,
// 才算一个对账)。两边共用 journal_activity_lines 的同一列,所以:
//   * 查不出算术错 —— 算术只有一份,不可能各错各的;
//   * 查得出【本页把参数传错了】:期间与报表不一致、mode 传反(于是年结开关反了)、
//     科目号带错。那正是一个下钻页最容易错的地方,也是这两个数唯一能分开动的方式。
// 所以不一致时【说出来】,不悄悄挑一个显示。
//
// 【报表没有这一行 ≠ 报表报了 0】前者是"这张表在这个期间根本不报这个科目"
// (例如拿资产科目去下钻损益表),后者是一个数。混成 0.00 就是把一次问错了的
// 问题显示成一个答案 —— 与 lib/permissions.ts 存在的理由是同一条。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { isYmd } from '@/lib/dateFilter'
import { getBaseCurrency } from '@/lib/currency'
import { formatMoneyBare } from '@/lib/format'
import { resolveSourceHrefs, sourceHrefKey } from '../../sourceLinks'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import LedgerRowsTable, { type LedgerTableRow } from './LedgerRowsTable'

type Counterpart = { code: string; name_en: string; name_zh: string }
type LedgerRow = {
    line_id: string
    entry_id: string
    entry_code: string
    entry_date: string
    entry_memo: string | null
    line_memo: string | null
    entry_status: string
    source_type: string | null
    source_id: string | null
    debit: number
    credit: number
    amount: number
    counterparts: Counterpart[]
}
type Ledger = {
    account: { code: string; name_en: string; name_zh: string; account_type: string }
    period_from: string | null
    period_to: string
    include_year_close: boolean
    rows: LedgerRow[]
    line_count: number
    total: number
}

type PnlRow = { code: string; amount: number }
type Pnl = {
    revenue: { rows: PnlRow[] }
    cogs: { rows: PnlRow[] }
    expense: { rows: PnlRow[] }
}
type BsRow = { code: string; net: number }
type Bs = {
    asset: { rows: BsRow[] }
    liability: { rows: BsRow[] }
    equity: { rows: BsRow[] }
}

export default async function AccountLedgerPage({
    params,
    searchParams,
}: {
    params: Promise<{ account: string }>
    searchParams: Promise<{ mode?: string; from?: string; to?: string; as_of?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    // 门与它服务的两张报表【同一道】:能看见那个数字的人就能看见它背后的行。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const { account } = await params
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const baseCurrency = await getBaseCurrency()

    const accountCode = decodeURIComponent(account)

    // 【mode 默认 bs、as_of 默认今天 —— 这是一个读查询,不是一次过账】
    // AGENTS.md 明确把「p_as_of 读查询」列在正当默认里,而资产负债表页面本身
    // 也是这么默认的。会毒害期间的那条规矩管的是【会过账的日期】。
    const mode = sp.mode === 'pnl' ? 'pnl' : 'bs'
    const asOf = isYmd(sp.as_of ?? '') ? (sp.as_of as string) : new Date().toISOString().slice(0, 10)
    const pnlTo = isYmd(sp.to ?? '') ? (sp.to as string) : asOf
    const pnlFrom = isYmd(sp.from ?? '') ? (sp.from as string) : pnlTo

    const from = mode === 'pnl' ? pnlFrom : null
    const to = mode === 'pnl' ? pnlTo : asOf

    const [ledgerRes, stmtRes] = await Promise.all([
        supabase.rpc('account_ledger', {
            p_account_code: accountCode,
            // 【为什么这里有个断言】supabase 的类型生成器把每个【没有默认值】的
            // 参数一律标成非空,而 p_from = NULL 恰恰【是】这个函数契约的一部分:
            // 它就是"累计口径,不设起点"的表达方式。改函数签名去迁就生成器
            // (给中间参数塞默认值、或调换参数顺序)会让签名不再说人话,
            // 所以断言留在这里,理由也留在这里。
            p_from: from as unknown as string,
            p_to: to,
            // 【开关与 mode 配套,不是第三个参数】见抬头。
            p_include_year_close: mode === 'bs',
        }),
        mode === 'pnl'
            ? supabase.rpc('pnl_statement', { p_from: pnlFrom, p_to: pnlTo })
            : supabase.rpc('balance_sheet', { p_as_of: asOf }),
    ])

    const title = t('finance.ledgerTitle')

    // 【失败必须失败】—— 不 ?? 成空表。一张"本期间无分录"的空表与一次被吞掉的
    // 权限错在屏幕上长得一模一样,而后者会让人相信这个科目真的没有动过。
    if (ledgerRes.error || stmtRes.error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{title}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">
                        {JSON.stringify(ledgerRes.error ?? stmtRes.error, null, 2)}
                    </pre>
                </div>
            </div>
        )
    }

    const led = ledgerRes.data as unknown as Ledger

    // 报表自己报的那个数字。【找不到 = 这张表在这个期间不报这个科目】,不是 0。
    let figure: number | null = null
    if (mode === 'pnl') {
        const pnl = stmtRes.data as unknown as Pnl
        const hit = [...pnl.revenue.rows, ...pnl.cogs.rows, ...pnl.expense.rows].find(
            (r) => r.code === led.account.code
        )
        figure = hit ? hit.amount : null
    } else {
        const bs = stmtRes.data as unknown as Bs
        const hit = [...bs.asset.rows, ...bs.liability.rows, ...bs.equity.rows].find(
            (r) => r.code === led.account.code
        )
        figure = hit ? hit.net : null
    }

    // 明细为空且报表也不报这一行 —— 两者一致,是那个具名的空状态,不是对不上。
    const emptyAndConsistent = led.line_count === 0 && figure === null
    const tiesOut = emptyAndConsistent || (figure !== null && figure === led.total)

    const hrefs = await resolveSourceHrefs(supabase, led.rows)

    const accountName = locale === 'zh' ? led.account.name_zh : led.account.name_en
    const cpName = (c: Counterpart) => (locale === 'zh' ? c.name_zh : c.name_en)

    // 【区间要如实标】资产负债表的下钻是【累计】的:起点不设界,不是"这个月"。
    // 把它标成一个区间就是在说一件没发生的事。
    const rangeLabel =
        mode === 'pnl'
            ? t('finance.ledgerRangePeriod', { from: pnlFrom, to: pnlTo })
            : t('finance.ledgerRangeCumulative', { asOf })

    const backHref =
        mode === 'pnl'
            ? `/finance/pnl?date_from=${pnlFrom}&date_to=${pnlTo}`
            : `/finance/balance-sheet?as_of=${asOf}`


    // ★【行数据在服务端压平】locale、来源链接解析、金额格式都只有服务端知道。
    const tableRows: LedgerTableRow[] = led.rows.map((r) => ({
        id: r.line_id,
        entryDate: r.entry_date,
        entryCode: r.entry_code,
        entryHref: `/finance/journal/${r.entry_id}`,
        reversed: r.entry_status === 'reversed',
        sourceLabel: r.source_type ? t('finance.source.' + r.source_type) : '—',
        sourceHref: hrefs.get(sourceHrefKey(r)) ?? null,
        counterparts: r.counterparts.map((c) => ({ code: c.code, name: cpName(c) })),
        memo: r.line_memo || r.entry_memo || '—',
        amountText: formatMoneyBare(r.amount, '列头 金额 ({ccy}) —— 已带本位币'),
        negative: r.amount < 0,
    }))

    // ★ 合计行是【数据】,不是 <tfoot> —— CONV-4 §⑨-3 定的型,CONV-8 §⑧ 复核保留。
    //   转换前它 colSpan={5} 顶到金额左边;现在落在【分录号】那一列。
    //   ★ 放【分录号】而不是【摘要】是刻意的:摘要不是 priority 列,
    //     标签落在那里会在 390px 上整个消失,于是合计行只剩一个没有主语的数字。
    if (tableRows.length > 0) {
        tableRows.push({
            id: '__total__',
            entryDate: '',
            entryCode: t('finance.ledgerOwnTotal'),
            entryHref: null,
            reversed: false,
            sourceLabel: '',
            sourceHref: null,
            counterparts: [],
            memo: '',
            amountText: formatMoneyBare(led.total, '列头 金额 ({ccy}) —— 已带本位币'),
            negative: false,
            isTotal: true,
        })
    }

    return (
        <ListPage
            title={title}
            // ★★ 详情页恒为 ok —— 而这一页尤其不能用 empty 分支:
            //    「明细为空」与「报表不报这一行」是两件必须并排说出来的事,
            //    它们住在下面 notices 的那两个方框里。用 empty 会把它们一起吃掉。
            state={{ kind: 'ok' }}
            notices={
                <>
                    <div className="mb-4">
                        <p className="text-lg">
                            <span className="font-mono">{led.account.code}</span>{' '}
                            <span className="font-semibold">{accountName}</span>{' '}
                            <span className="text-gray-500 text-sm">
                                ({t('finance.accountType.' + led.account.account_type)})
                            </span>
                        </p>
                        <p className="text-sm text-gray-600">{rangeLabel}</p>
                        {/* 【返回链接留在标题【下面】】这一页转换前就是这样 ——
                            它不在 <h1> 之上,所以【不】用 breadcrumb 槽:
                            用了会把它挪上去,那是一次没人要求的版式改动。 */}
                        <Link href={backHref} className="text-sm text-blue-600 hover:underline">
                            {t(mode === 'pnl' ? 'finance.ledgerBackPnl' : 'finance.ledgerBackBs')}
                        </Link>
                    </div>

                    {/* ── 两个数并排 ─────────────────────────────────────────
                        左:本页明细的合计。右:那张报表自己报的数字。
                        不一致时【说出来】—— 见抬头关于这个对账能查出什么。 */}
                    <div className="mb-4 grid grid-cols-1 sm:grid-cols-2 gap-3 max-w-2xl">
                        <div className="border border-gray-300 rounded px-4 py-3">
                            <p className="text-xs text-gray-500">{t('finance.ledgerOwnTotal')}</p>
                            <p className="font-mono text-lg">
                                {formatMoneyBare(led.total, '本块抬头下方一行写明本位币')} {baseCurrency}
                            </p>
                        </div>
                        <div className="border border-gray-300 rounded px-4 py-3">
                            <p className="text-xs text-gray-500">
                                {t(mode === 'pnl' ? 'finance.ledgerPnlFigure' : 'finance.ledgerBsFigure')}
                            </p>
                            <p className="font-mono text-lg">
                                {figure === null ? (
                                    // 【报表不报这一行】—— 不写 0.00。见抬头。
                                    <span className="text-gray-500 text-base">
                                        {t('finance.ledgerFigureAbsent')}
                                    </span>
                                ) : (
                                    <>
                                        {formatMoneyBare(figure, '本块抬头下方一行写明本位币')} {baseCurrency}
                                    </>
                                )}
                            </p>
                        </div>
                    </div>

                    {!tiesOut && (
                        <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                            <p className="font-bold">{t('finance.ledgerMismatch')}</p>
                            <p className="text-sm mt-1">{t('finance.ledgerMismatchHint')}</p>
                        </div>
                    )}
                </>
            }
        >
            {/* 【具名的空状态】现在由表自己说(DataTable 的 empty)——
                与 CONV-8 §⑤ 的推论一致:空的只可能是子表,那句话归那张表。 */}
            <LedgerRowsTable
                rows={tableRows}
                amountHeader={t('finance.colAmount', { ccy: baseCurrency })}
                empty={t('finance.ledgerEmpty')}
            />

            <p className="text-sm text-gray-500 mt-4">{t('finance.ledgerNote')}</p>
        </ListPage>
    )
}
