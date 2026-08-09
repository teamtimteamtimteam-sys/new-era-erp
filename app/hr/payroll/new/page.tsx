// app/hr/payroll/new/page.tsx
// 新建薪资期间:默认当月,发薪日默认【当月最后一个周五】(手册约定,只是默认值)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import PayrollGrid from '../PayrollGrid'
import { loadGridData } from '../loadGridData'
import { lastFridayOfMonth } from '../../options'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewPayrollPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const now = new Date()
    const year = now.getFullYear()
    const month = now.getMonth() + 1
    const monthStr = `${year}-${String(month).padStart(2, '0')}`

    const { employees, prefill, hasPrefill } = await loadGridData(supabase, {
        beforeMonth: `${monthStr}-01`,
    })

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/hr/payroll" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-4">{t('hr.newPayroll')}</h1>
            <Subnav />
            <PayrollGrid
                employees={employees}
                prefill={prefill}
                hasPrefill={hasPrefill}
                defaults={{
                    period_month: monthStr,
                    payment_date: lastFridayOfMonth(year, month),
                    currency: 'SGD',
                    fx_rate: '', // 汇率每月不同,不给猜测值
                    source_note: '',
                    notes: '',
                }}
            />
        </div>
    )
}
