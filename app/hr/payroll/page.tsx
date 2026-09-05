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
import { can } from '@/lib/permissions'
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
    //
    // ★★【FIX-2a(b):Tim 的裁定 —— 过没过账是【财务的事实】,不放宽】★★
    //   journal_entries 挂 module.finance.view,hr 没有它。此前这里读回零行,
    //   而下面那句 `?? '—'` 把它与【这一期还没过账】写成同一个字符:
    //   于是 Sandra 看着一张【已经过账】的薪资期间,读到的是"没有分录"。
    //   Tim 的原话:「过账是财务在总账里做的动作,不是 HR 做的。把状态给 HR,
    //   等于让他们从一个自己不参与的流程里读出一个结论。」
    //   所以【不给】,而屏幕要说出来 —— 那一格写「受限」,不写破折号。
    //   ★ 判据是 journal_entry_id 有没有值,不是"查出来是不是空":
    //     没有 id = 真的还没过账(诚实的破折号);有 id 而读不到 = 扣下了。
    const canReadEntries = await can('module.finance.view')
    const jeIds = periods.map((p) => p.journal_entry_id).filter(Boolean) as string[]
    const { data: jes } = canReadEntries && jeIds.length
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
        // null = 这一期真的没有分录(诚实的破折号);
        // 'restricted' = 有一张分录,而你不能看它。
        journalCode: !p.journal_entry_id
            ? '—'
            : canReadEntries
              ? jeCodeById.get(p.journal_entry_id) ?? '—'
              : 'restricted',
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
