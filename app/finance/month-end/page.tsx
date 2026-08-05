// app/finance/month-end/page.tsx
// 月结枢纽(FIN-7):一个月还差什么,按【真实】依赖序排,每步 完成/待办/被挡,
// 被挡的说清被什么挡 —— 而不是点了才报错。这是枢纽,不替代各动作自己的屏幕。
// 真实依赖链(A2):牌价先行(缺牌价挡外币交易与重估)→ 薪资过账 → 发薪(本月)
// → 代扣款汇出 → 应计冲抵(发票到了才冲,记在发票期间)→ 重估(记在月末,
// 必须在锁期之前)→ 锁期。CPF 例外:次月 14 日前汇、凭证记在【次月】,
// 所以锁本月不挡 CPF —— 它挂在下月的账上。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../Subnav'
import { formatMoney } from '@/lib/format'
import { mustCount, mustOne, mustRows } from '@/lib/db-helpers'

function monthRange(m: string): { start: string; end: string } {
    const [y, mo] = m.split('-').map(Number)
    const end = new Date(Date.UTC(y, mo, 0)).toISOString().slice(0, 10)
    return { start: `${m}-01`, end }
}

export default async function MonthEndPage({
    searchParams,
}: {
    searchParams: Promise<{ month?: string }>
}) {
    const sp = await searchParams
    const month = sp.month ?? new Date().toISOString().slice(0, 7)
    const { start, end } = monthRange(month)
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()

    const [gapsRes, periodRes, accrualRes, revalRes, settingsRes, midRes, allocRes] = await Promise.all([
        supabase.from('fx_rate_gaps').select('rate_date, currency, missing_types')
            .gte('rate_date', start).lte('rate_date', end),
        supabase.from('payroll_periods')
            .select('id, code, status, period_month, net_pay_total, employer_cpf_total, employee_cpf_total, other_deductions_total, cpf_paid_at, deductions_paid_at')
            .eq('period_month', start).is('deleted_at', null).maybeSingle(),
        // 遮蔽视图,不是基表:amount_base 在基表上没有 SELECT(perm2b),直接选它 42501
        supabase.from('processing_cost_entries_masked').select('id, cost_type, amount_base, is_estimate')
            .is('deleted_at', null).is('remitted_at', null).is('relieved_at', null)
            .lte('created_at', end + 'T23:59:59Z'),
        supabase.from('journal_entries').select('id, code')
            .eq('source_type', 'revaluation').eq('entry_date', end).eq('status', 'posted'),
        supabase.from('finance_settings').select('locked_before').maybeSingle(),
        supabase.from('fx_rates').select('id').eq('rate_date', end).eq('rate_type', 'mid').is('deleted_at', null),
        // FIN-8:批次成本与成本条目是否还对得上。改了条目,总账会动,批次不会 ——
        // 月结前必须看见,否则存货和销货成本就带着这个差额结账。
        supabase.from('processing_run_allocation_status')
            .select('code, allocated_at, last_cost_change, is_stale, safe_to_reallocate'),
    ])

    // 【每一步的信号都必须真的读到】读不出来就抛,不许把失败渲染成 'done' ——
    // 月结枢纽是最不能说谎的一页:七个信号原本全都 `?? []`,任何一次查询失败
    // 都会让那一步显示"已完成",而它其实从没被检查过。见 lib/db-helpers 政策注释。
    const period = mustOne(periodRes, 'payroll_periods')
    let unpaidLines = 0
    if (period && period.status === 'posted') {
        unpaidLines = mustCount(await supabase.from('payroll_lines')
            .select('id', { count: 'exact', head: true })
            .eq('payroll_period_id', period.id).is('paid_at', null), 'payroll_lines unpaid')
    }
    const gaps = mustRows(gapsRes, 'fx_rate_gaps')
    const accruals = mustRows(accrualRes, 'processing_cost_entries_masked')
    const cpfTotal = period ? Number(period.employer_cpf_total ?? 0) + Number(period.employee_cpf_total ?? 0) : 0
    const revalued = mustRows(revalRes, 'journal_entries revaluation').length > 0
    const midMissing = mustRows(midRes, 'fx_rates mid').length === 0
    // 过期 + 从未分摊却已有成本,都算"批次成本对不上"
    const allocProblems = mustRows(allocRes, 'processing_run_allocation_status')
        .filter((r) => r.is_stale || (!r.allocated_at && r.last_cost_change))
    const settings = mustOne(settingsRes, 'finance_settings')
    const locked = !!settings?.locked_before && settings.locked_before > end

    type Step = { key: string; state: 'done' | 'outstanding' | 'blocked' | 'na'; detail: string; href: string }
    const steps: Step[] = [
        {
            key: 'rates', href: '/finance/fx',
            state: gaps.length === 0 ? 'done' : 'outstanding',
            detail: gaps.length === 0 ? '' : t('finance.monthEnd.gapsDetail', { n: gaps.length }),
        },
        {
            // 走查发现:枢纽早已取到本月期间行,链接却指着列表让人重新找 ——
            // 有期间直达其详情页(过账按钮在那);没有期间直达新建页(下一步就是建)。
            key: 'payrollPosted', href: period ? `/hr/payroll/${period.id}` : '/hr/payroll/new',
            state: !period ? 'na' : period.status === 'posted' ? 'done' : 'outstanding',
            detail: !period ? t('finance.monthEnd.noPeriod') : period.code,
        },
        {
            key: 'employeesPaid', href: '/finance/payroll-payments',
            state: !period ? 'na' : period.status !== 'posted' ? 'blocked'
                 : unpaidLines === 0 ? 'done' : 'outstanding',
            detail: !period ? '' : period.status !== 'posted' ? t('finance.monthEnd.blockedByPosting')
                 : unpaidLines === 0 ? '' : t('finance.monthEnd.unpaidLines', { n: unpaidLines }),
        },
        {
            key: 'cpf', href: '/finance/payroll-payments',
            state: !period || cpfTotal === 0 ? 'na' : period.status !== 'posted' ? 'blocked'
                 : period.cpf_paid_at ? 'done' : 'outstanding',
            detail: !period || cpfTotal === 0 ? '' : period.status !== 'posted' ? t('finance.monthEnd.blockedByPosting')
                 : period.cpf_paid_at ? '' : t('finance.monthEnd.cpfDetail', { amount: formatMoney(cpfTotal), ccy: baseCurrency }),
        },
        {
            key: 'deductions', href: '/finance/payroll-payments',
            state: !period || Number(period.other_deductions_total ?? 0) === 0 ? 'na'
                 : period.status !== 'posted' ? 'blocked'
                 : period.deductions_paid_at ? 'done' : 'outstanding',
            detail: !period ? '' : period.status !== 'posted' ? t('finance.monthEnd.blockedByPosting') : '',
        },
        {
            key: 'accruals', href: '/finance/processing-costs',
            state: accruals.length === 0 ? 'done' : 'outstanding',
            detail: accruals.length === 0 ? '' : t('finance.monthEnd.accrualsDetail', { n: accruals.length }),
        },
        {
            key: 'staleAllocation', href: '/processing',
            state: allocProblems.length === 0 ? 'done' : 'outstanding',
            detail: allocProblems.length === 0 ? ''
                 : t('finance.monthEnd.staleAllocationDetail', { n: allocProblems.length })
                   + ': ' + allocProblems.map((r) => r.code).join(', '),
        },
        {
            key: 'revaluation', href: `/finance/revaluation?date=${end}`,
            state: revalued ? 'done' : midMissing ? 'blocked' : 'outstanding',
            detail: revalued ? '' : midMissing ? t('finance.monthEnd.blockedByMid', { 0: end }) : '',
        },
        {
            key: 'lock', href: '/finance/close',
            state: locked ? 'done' : revalued ? 'outstanding' : 'blocked',
            detail: locked ? '' : revalued ? '' : t('finance.monthEnd.blockedByReval'),
        },
    ]

    const badge: Record<string, string> = {
        done: 'bg-green-100 text-green-800', outstanding: 'bg-amber-100 text-amber-800',
        blocked: 'bg-red-100 text-red-800', na: 'bg-gray-100 text-gray-500',
    }

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.monthEnd.title')}</h1>
            <Subnav />
            <form method="get" className="mb-4">
                <input type="month" name="month" defaultValue={month}
                       className="border border-gray-300 rounded px-2 py-1 text-sm" />
                <button type="submit" className="ml-2 border border-gray-300 rounded px-3 py-1 text-sm">
                    {t('reviews.filter')}
                </button>
            </form>
            <p className="text-xs text-gray-500 mb-4">{t('finance.monthEnd.cpfNote')}</p>
            <table className="w-full border-collapse border border-gray-300 text-sm">
                <tbody>
                    {steps.map((s, i) => (
                        <tr key={s.key}>
                            <td className="border border-gray-300 px-3 py-2 w-8 text-gray-500">{i + 1}</td>
                            <td className="border border-gray-300 px-3 py-2">
                                <Link href={s.href} className="text-blue-600 hover:underline">
                                    {t('finance.monthEnd.step_' + s.key)}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-3 py-2 w-32">
                                <span className={'inline-block rounded px-2 py-0.5 text-xs ' + badge[s.state]}>
                                    {t('finance.monthEnd.state_' + s.state)}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-gray-600">{s.detail}</td>
                        </tr>
                    ))}
                </tbody>
            </table>
        </div>
    )
}
