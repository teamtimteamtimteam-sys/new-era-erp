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
import Subnav from '../../Subnav'
import { resolveSourceHrefs, sourceHrefKey } from '../../sourceLinks'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

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

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{title}</h1>

            <Subnav />

            <div className="mb-4">
                <p className="text-lg">
                    <span className="font-mono">{led.account.code}</span>{' '}
                    <span className="font-semibold">{accountName}</span>{' '}
                    <span className="text-gray-500 text-sm">
                        ({t('finance.accountType.' + led.account.account_type)})
                    </span>
                </p>
                <p className="text-sm text-gray-600">{rangeLabel}</p>
                <Link href={backHref} className="text-sm text-blue-600 hover:underline">
                    {t(mode === 'pnl' ? 'finance.ledgerBackPnl' : 'finance.ledgerBackBs')}
                </Link>
            </div>

            {/* ── 两个数并排 ─────────────────────────────────────────────────
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

            {led.line_count === 0 ? (
                // 【具名的空状态】—— 不是一张空表让人猜是没数据还是没加载出来。
                <div className="bg-gray-50 border border-gray-300 text-gray-700 px-4 py-6 rounded">
                    {t('finance.ledgerEmpty')}
                </div>
            ) : (
                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">
                                {t('finance.colDate')}
                            </th>
                            <th className="border border-gray-300 px-3 py-2 text-left">
                                {t('finance.ledgerColEntry')}
                            </th>
                            <th className="border border-gray-300 px-3 py-2 text-left">
                                {t('finance.colSource')}
                            </th>
                            <th className="border border-gray-300 px-3 py-2 text-left">
                                {t('finance.ledgerColCounterpart')}
                            </th>
                            <th className="border border-gray-300 px-3 py-2 text-left">
                                {t('finance.colMemo')}
                            </th>
                            <th className="border border-gray-300 px-3 py-2 text-right">
                                {t('finance.colAmount', { ccy: baseCurrency })}
                            </th>
                        </tr>
                    </thead>
                    <tbody>
                        {led.rows.map((r) => {
                            const href = hrefs.get(sourceHrefKey(r))
                            const label = r.source_type ? t('finance.source.' + r.source_type) : '—'
                            return (
                                <tr key={r.line_id}>
                                    <td className="border border-gray-300 px-3 py-2 whitespace-nowrap">
                                        {r.entry_date}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 font-mono text-sm">
                                        <Link
                                            href={`/finance/journal/${r.entry_id}`}
                                            className="text-blue-600 hover:underline"
                                        >
                                            {r.entry_code}
                                        </Link>
                                        {/* 被冲销的原分录仍然在这里,而且【必须】在
                                            (见 journal_activity_lines 抬头)。
                                            标出来,免得读的人以为是重复行。 */}
                                        {r.entry_status === 'reversed' && (
                                            <span className="ml-2 text-xs text-amber-700">
                                                {t('finance.ledgerReversed')}
                                            </span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-sm">
                                        {href ? (
                                            <Link href={href} className="text-blue-600 hover:underline">
                                                {label}
                                            </Link>
                                        ) : (
                                            label
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-sm">
                                        {r.counterparts.length === 0
                                            ? '—'
                                            : r.counterparts.map((c) => (
                                                  <span key={c.code} className="mr-2 whitespace-nowrap">
                                                      <span className="font-mono">{c.code}</span>{' '}
                                                      {cpName(c)}
                                                  </span>
                                              ))}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-sm text-gray-600">
                                        {r.line_memo || r.entry_memo || '—'}
                                    </td>
                                    <td
                                        className={
                                            'border border-gray-300 px-3 py-2 text-right font-mono text-sm ' +
                                            (r.amount < 0 ? 'text-red-600' : '')
                                        }
                                    >
                                        {formatMoneyBare(r.amount, '列头 金额 ({ccy}) —— 已带本位币')}
                                    </td>
                                </tr>
                            )
                        })}
                    </tbody>
                    <tfoot>
                        <tr className="bg-gray-100 font-bold">
                            <td colSpan={5} className="border border-gray-300 px-3 py-2">
                                {t('finance.ledgerOwnTotal')}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                {formatMoneyBare(led.total, '列头 金额 ({ccy}) —— 已带本位币')}
                            </td>
                        </tr>
                    </tfoot>
                </table>
            )}

            <p className="text-sm text-gray-500 mt-4">{t('finance.ledgerNote')}</p>
        </div>
    )
}
