// app/hr/payroll/page.tsx
// 薪资期间列表:月份、发薪日、币种、应发合计、实发合计、人数、状态、分录链接。
//
// CONV-5:套 CONV-1 的两文件模板。
// ★ state 恒为 'ok' —— 抬头的「新建薪资期间」住在 ListPage 的 actions 里
//   (状态分支之外),空集由 DataTable 自己的 empty 说。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import PayrollPeriodsTable, { type PayrollPeriodRow } from './PayrollPeriodsTable'

export default async function PayrollListPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const [periodsRes, linesRes] = await Promise.all([
        supabase
            .from('payroll_periods')
            .select('id, code, period_month, payment_date, currency, gross_total, net_pay_total, status, journal_entry_id')
            .is('deleted_at', null)
            .order('period_month', { ascending: false }),
        supabase.from('payroll_lines').select('payroll_period_id'),
    ])

    const periods = mustRows(periodsRes)
    const countByPeriod = new Map<string, number>()
    for (const l of mustRows(linesRes)) {
        countByPeriod.set(l.payroll_period_id, (countByPeriod.get(l.payroll_period_id) ?? 0) + 1)
    }

    // 已过账的期间要能一键跳到那张分录
    const jeIds = periods.map((p) => p.journal_entry_id).filter(Boolean) as string[]
    const { data: jes } = jeIds.length
        ? await supabase.from('journal_entries').select('id, code').in('id', jeIds)
        : { data: [] as { id: string; code: string }[] }
    const jeCodeById = new Map((jes ?? []).map((j) => [j.id, j.code]))

    const tableRows: PayrollPeriodRow[] = periods.map((p) => ({
        id: p.id,
        code: p.code,
        periodMonth: p.period_month ?? '',
        paymentDate: p.payment_date,
        currency: p.currency,
        grossTotal: p.gross_total,
        netPayTotal: p.net_pay_total,
        lineCount: countByPeriod.get(p.id) ?? 0,
        status: p.status,
        journalEntryId: p.journal_entry_id,
        journalCode: p.journal_entry_id ? (jeCodeById.get(p.journal_entry_id) ?? '—') : '—',
    }))

    return (
        <ListPage
            title={t('hr.payrollTitle')}
            maxWidth="max-w-5xl"
            actions={
                <Link href="/hr/payroll/new" className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700">
                    {t('hr.newPayroll')}
                </Link>
            }
            state={{ kind: 'ok' }}
        >
            <p className="text-sm text-gray-600 mb-4">{t('finance.recordCount', { count: periods.length })}</p>
            <PayrollPeriodsTable rows={tableRows} empty={t('hr.payrollEmpty')} />
        </ListPage>
    )
}
