// app/hr/payroll/[id]/edit/page.tsx
// 编辑草稿期间:明细预填【本期已录的数字】(不是上一期),月份锁定 ——
// 换月份等于换一张单,应该另建。已过账的期间不可编辑,直接退回详情页。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { notFound, redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import PayrollGrid from '../../PayrollGrid'
import { loadGridData } from '../../loadGridData'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { formatDate, formatMonth, toYearMonth } from '@/lib/dates'
import { getLocale } from '@/lib/i18n/server'

export default async function EditPayrollPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const locale = await getLocale()
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: period, error } = await supabase
        .from('payroll_periods_masked')
        .select('id, code, period_month, payment_date, currency, fx_rate, source_note, notes, status')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !period) {
        notFound()
    }
    // 已过账 = 只读;要改先撤销过账
    if (period.status === 'posted') {
        redirect(`/hr/payroll/${id}`)
    }

    const { employees, prefill, hasPrefill } = await loadGridData(supabase, { currentPeriodId: id })

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href={`/hr/payroll/${id}`} className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="mb-4">
                {t('hr.payrollDetailTitle')}
                <span className="ml-3 text-sm text-[color:var(--brand-muted-text)]">
                    {formatMonth(period.period_month, locale)}
                </span>
            </h1>
            <PayrollGrid
                employees={employees}
                prefill={prefill}
                hasPrefill={hasPrefill}
                monthLocked
                defaults={{
                    // ★ TABLE-EXPORT-2a(Tim 2026-10-22 Q9):PayrollGrid 要的是 'YYYY-MM'(月份框的值,也是 actions.ts 校验的形状)。
                    //   从前这里给的是 formatMonth 的显示用的字:中文「2026年9月」月份框读不出来 → 空 → 保存被 PERIOD_MONTH_INVALID 拒;
                    //   英文「Sep 2026」只是碰巧被 new Date 读对了。
                    period_month: toYearMonth(period.period_month),
                    payment_date: formatDate(period.payment_date, locale) ?? '',
                    currency: period.currency ?? await getBaseCurrency(),
                    fx_rate: String(period.fx_rate ?? ''),
                    source_note: period.source_note ?? '',
                    notes: period.notes ?? '',
                }}
            />
        </div>
    )
}
