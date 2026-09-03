// app/finance/close/page.tsx
// 月结关账:当前锁状态 + 月份选择(最近 12 个月末,已关/早于锁的禁选)+
// 所选月末的预览(分录数、Σ借/Σ贷、平衡指示、当月损益表/截至日资产负债表链接)
// + 关账按钮;下方关账历史(重开的行保留,状态列盖章),活跃行可行内重开。
//
// ★ CONV-4:月结历史表【不属于这一套模板的人口】—— 最后一格挂着
//   ReopenForm,一个真实的、逐行的行内表单(<input type="text"> + 提交)。
//   按【格子里有没有输入控件】这条全仓库统一的判据,它不是只读账簿,
//   与资产台账主表撞上 AssetActions 是同一族发现。月结历史表按兵不动。
//   年结历史表是另一张表,零行内控件,套 CONV-1 模板转换。
//   state 恒为 'ok':这一页没有"整页无内容"这回事,月份选择器总是有得看。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { isYmd } from '@/lib/dateFilter'
import { getBaseCurrency } from '@/lib/currency'
import { formatAmount } from '@/lib/format'
import PeriodPicker, { type PeriodOption } from './PeriodPicker'
import CloseButton from './CloseButton'
import ReopenForm from './ReopenForm'
import YearClosePanel from './YearClosePanel'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import YearCloseHistoryTable, { type YearCloseRow } from './YearCloseHistoryTable'

type CloseRow = {
    id: string
    period_end: string
    closed_at: string
    notes: string | null
    entries_count: number
    total_debits: number
    total_credits: number
    reopened_at: string | null
    reopen_reason: string | null
}

const round2 = (n: number) => Math.round(n * 100) / 100
const ymdUtc = (d: Date) => d.toISOString().slice(0, 10)

export default async function ClosePage({
    searchParams,
}: {
    searchParams: Promise<{ period?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    // 「借方/贷方/净结果」这些标签都不写币种 —— 金额自己带(CCY-1)
    const baseCurrency = await getBaseCurrency()

    const [settingsRes, closesRes, yearPreviewRes, yearClosesRes] = await Promise.all([
        supabase.from('finance_settings').select('locked_before').eq('id', true).single(),
        supabase
            .from('period_closes')
            .select('id, period_end, closed_at, notes, entries_count, total_debits, total_credits, reopened_at, reopen_reason')
            .order('closed_at', { ascending: false }),
        // FIN-23:年结预览 —— 与 close_financial_year 同一份算术(硬前置也从这里读)
        supabase.rpc('preview_close_financial_year'),
        supabase.from('year_closes')
            .select('id, year_end, net_result, closed_at, reopened_at, reopen_reason')
            .order('closed_at', { ascending: false }),
    ])

    const error = settingsRes.error ?? closesRes.error ?? yearPreviewRes.error ?? yearClosesRes.error
    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.closeTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const lockedBefore = settingsRes.data?.locked_before ?? null
    const closes = (mustRows(closesRes)) as CloseRow[]
    const activeCloses = new Set(closes.filter((c) => !c.reopened_at).map((c) => c.period_end))

    // 最近 12 个月末;已有活跃关账、早于期间锁、【或该月还没过完】的禁选。
    // 【为什么禁未来月末】i=0 是【本月】月末:今天 8-05 时它是 8-31。它既没被
    // 关过也不早于锁,于是成了默认选中项 —— 打开页面就是"关掉这个还没过完的月",
    // 而关账会把 8-31 之前(即整个 8 月)全锁上,并不好撤。关账是月结之后的事,
    // 月还没结完就不该出现在候选里。
    const now = new Date()
    const y = now.getUTCFullYear()
    const m = now.getUTCMonth()
    const todayYmd = ymdUtc(now)
    const options: PeriodOption[] = []
    for (let i = 0; i < 12; i++) {
        const periodEnd = ymdUtc(new Date(Date.UTC(y, m - i + 1, 0)))
        options.push({
            value: periodEnd,
            disabled:
                periodEnd > todayYmd
                || activeCloses.has(periodEnd)
                || (lockedBefore !== null && periodEnd < lockedBefore),
        })
    }

    // 选中月末:URL 优先(须在列表内),否则最近的可选项
    const requested = (sp.period ?? '').trim()
    const selected =
        isYmd(requested) && options.some((o) => o.value === requested)
            ? requested
            : options.find((o) => !o.disabled)?.value ?? ''
    const selectedDisabled = options.find((o) => o.value === selected)?.disabled ?? true

    // 预览:截至所选月末的分录数 + Σ借/Σ贷(与 close_period 同口径)
    let preview: { count: number; debits: number; credits: number } | null = null
    if (selected) {
        // 【这一格是关账的确认依据,读不出来必须报错】原本 error 被吞掉,rows 读成
        // 空集 → 借贷都是 0 → 0 === 0 → 绿色「✓ 已平」,就悬在关账按钮正上方。
        // 也就是说:那个对勾恰恰是【失败本身】画出来的。验不了就不能画勾。
        const linesRes = await supabase
            .from('journal_lines')
            .select('entry_id, debit, credit, journal_entries!inner(entry_date)')
            .lte('journal_entries.entry_date', selected)
        const rows = mustRows(linesRes, 'journal_lines close preview')
        preview = {
            count: new Set(rows.map((l) => l.entry_id)).size,
            debits: round2(rows.reduce((s, l) => s + l.debit, 0)),
            credits: round2(rows.reduce((s, l) => s + l.credit, 0)),
        }
    }

    const monthStart = selected ? selected.slice(0, 8) + '01' : ''

    // ── FIN-23:年结状态 ──────────────────────────────────────────────────────
    type YearPreview = {
        year_end: string
        expected_year_end: string
        already_closed: boolean
        net_result: number
        final_period_closed: boolean
        trial_balanced: boolean
        revaluation_level: boolean
        depreciation_level: boolean
        draft_payroll_count: number
        open_accrual_count: number
    }
    const yp = mustOne(yearPreviewRes, 'preview_close_financial_year') as unknown as YearPreview | null
    type YearCloseQueryRow = {
        id: string; year_end: string; net_result: number
        closed_at: string; reopened_at: string | null; reopen_reason: string | null
    }
    const yearCloses = mustRows(yearClosesRes) as YearCloseQueryRow[]
    const hardChecks: { key: string; ok: boolean }[] = yp ? [
        { key: 'finalPeriod', ok: yp.final_period_closed },
        { key: 'trialBalance', ok: yp.trial_balanced },
        { key: 'revaluation', ok: yp.revaluation_level },
        { key: 'depreciation', ok: yp.depreciation_level },
    ] : []
    const canCloseYear = hardChecks.length > 0 && hardChecks.every((c) => c.ok)

    const yearCloseRows: YearCloseRow[] = yearCloses.map((c) => ({
        id: c.id,
        yearEnd: c.year_end,
        netResult: c.net_result,
        baseCurrency,
        reopened: !!c.reopened_at,
        reopenReason: c.reopen_reason,
    }))

    return (
        <ListPage title={t('finance.closeTitle')} maxWidth="max-w-5xl" state={{ kind: 'ok' }}>
            {/* 当前锁状态 */}
            <div className="bg-gray-50 rounded p-4 mb-6 text-sm">
                <span className="text-gray-600 mr-1">{t('finance.lockedBefore')}:</span>
                {lockedBefore ? (
                    <span className="font-mono font-medium">{lockedBefore}</span>
                ) : (
                    <span className="text-gray-400">{t('finance.notSet')}</span>
                )}
            </div>

            {/* 月份选择 + 预览 + 关账 */}
            <div className="border border-gray-300 rounded p-4 mb-8 space-y-4">
                <PeriodPicker options={options} selected={selected} />

                {selected && preview && (
                    <>
                        <div className="bg-gray-50 rounded p-4 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                            <div>
                                <span className="text-gray-600 mr-1">{t('finance.entriesCount')}:</span>
                                <span className="font-mono font-medium">{preview.count}</span>
                            </div>
                            <div>
                                <span className="text-gray-600 mr-1">{t('finance.colDebits')}:</span>
                                <span className="font-mono font-medium">{formatAmount(preview.debits, baseCurrency)}</span>
                            </div>
                            <div>
                                <span className="text-gray-600 mr-1">{t('finance.colCredits')}:</span>
                                <span className="font-mono font-medium">{formatAmount(preview.credits, baseCurrency)}</span>
                            </div>
                            <span
                                className={
                                    'px-2 py-1 rounded text-xs ' +
                                    (preview.count === 0
                                        ? 'bg-gray-100 text-gray-700'
                                        : preview.debits === preview.credits
                                        ? 'bg-green-100 text-green-800'
                                        : 'bg-red-100 text-red-800')
                                }
                            >
                                {preview.count === 0
                                    ? t('finance.balanceIndicator.nothingToCheck')
                                    : preview.debits === preview.credits
                                    ? '✓ ' + t('finance.balanceIndicator.balanced')
                                    : t('finance.balanceIndicator.unbalanced')}
                            </span>
                        </div>

                        <div className="flex flex-wrap gap-4 text-sm">
                            <Link
                                href={`/finance/pnl?date_from=${monthStart}&date_to=${selected}`}
                                className="text-blue-600 hover:underline"
                            >
                                {t('finance.viewPnl')}
                            </Link>
                            <Link
                                href={`/finance/balance-sheet?as_of=${selected}`}
                                className="text-blue-600 hover:underline"
                            >
                                {t('finance.viewBs')}
                            </Link>
                        </div>

                        {!selectedDisabled && <CloseButton periodEnd={selected} />}
                    </>
                )}
            </div>

            {/* 关账历史 */}
            <h2 className="text-lg font-semibold mb-3">{t('finance.closeHistory')}</h2>
            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colPeriodEnd')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colClosedAt')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.entriesCount')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colDebits')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colCredits')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colStatus')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left" />
                    </tr>
                </thead>
                <tbody>
                    {closes.map((c) => (
                        <tr key={c.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">{c.period_end}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {c.closed_at.slice(0, 16).replace('T', ' ')}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {c.entries_count}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {formatAmount(c.total_debits, baseCurrency)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {formatAmount(c.total_credits, baseCurrency)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span
                                    className={
                                        'px-2 py-1 rounded text-xs ' +
                                        (c.reopened_at
                                            ? 'bg-amber-100 text-amber-800'
                                            : 'bg-green-100 text-green-800')
                                    }
                                >
                                    {c.reopened_at
                                        ? t('finance.closeStatus.reopened')
                                        : t('finance.closeStatus.active')}
                                </span>
                                {c.reopen_reason && (
                                    <p className="text-xs text-gray-500 mt-1">{c.reopen_reason}</p>
                                )}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                {!c.reopened_at && <ReopenForm periodEnd={c.period_end} />}
                            </td>
                        </tr>
                    ))}
                    {closes.length === 0 && (
                        <tr>
                            <td colSpan={7} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('finance.closeHistoryEmpty')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>

            {/* ── FIN-23:年结 ─────────────────────────────────────────────── */}
            <h2 className="text-lg font-semibold mt-8 mb-3">{t('finance.yearClose.title')}</h2>
            {yp && (
                <div className="bg-gray-50 rounded p-4 mb-4 space-y-3 text-sm">
                    <div className="flex flex-wrap gap-x-8 gap-y-1">
                        <div>
                            <span className="text-gray-600 mr-1">{t('finance.yearClose.nextYearEnd')}:</span>
                            <span className="font-mono">{yp.expected_year_end}</span>
                        </div>
                        <div>
                            <span className="text-gray-600 mr-1">{t('finance.yearClose.netResult')}:</span>
                            <span className="font-mono font-medium">{formatAmount(yp.net_result, baseCurrency)}</span>
                        </div>
                    </div>
                    {/* 硬前置四灯:任一红 → 按钮禁用(服务端仍点名拒,界面不提供必拒的动作)*/}
                    <div className="flex flex-wrap gap-2">
                        {hardChecks.map((c) => (
                            <span key={c.key} className={'px-2 py-1 rounded text-xs ' +
                                (c.ok ? 'bg-green-100 text-green-800' : 'bg-red-100 text-red-800')}>
                                {c.ok ? '✓' : '✗'} {t('finance.yearClose.check_' + c.key)}
                            </span>
                        ))}
                        {/* 软警告:只亮黄,不拦(年末应计是正常会计;草稿薪资是可见的选择)*/}
                        {yp.draft_payroll_count > 0 && (
                            <span className="px-2 py-1 rounded text-xs bg-amber-100 text-amber-800">
                                {t('finance.yearClose.warnDraftPayroll', { n: yp.draft_payroll_count })}
                            </span>
                        )}
                        {yp.open_accrual_count > 0 && (
                            <span className="px-2 py-1 rounded text-xs bg-amber-100 text-amber-800">
                                {t('finance.yearClose.warnOpenAccruals', { n: yp.open_accrual_count })}
                            </span>
                        )}
                    </div>
                    <YearClosePanel yearEnd={yp.expected_year_end} canClose={canCloseYear}
                                    alreadyClosed={yp.already_closed} />
                </div>
            )}
            {yearCloseRows.length > 0 && (
                <div className="max-w-[36rem]">
                    <YearCloseHistoryTable rows={yearCloseRows} />
                </div>
            )}
        </ListPage>
    )
}
