// 发薪与汇缴(FIN-7 C1/C2)。逐人勾选付款 —— 转账会失败重发,部分跑批是常态;
// CPF / 代扣款各一键,一期一次,带金额与到期日。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../Subnav'
import PayPanel from './PayPanel'

export default async function PayrollPaymentsPage() {
    const supabase = await createClient()
    const t = await getTranslations()
    const { data: periods } = await supabase.from('payroll_periods')
        .select('id, code, period_month, status, net_pay_total, employer_cpf_total, employee_cpf_total, other_deductions_total, cpf_paid_at, deductions_paid_at')
        .eq('status', 'posted').is('deleted_at', null)
        .order('period_month', { ascending: false }).limit(6)
    const ids = (periods ?? []).map((p) => p.id)
    const { data: lines } = ids.length
        ? await supabase.from('payroll_lines_masked')
            .select('id, payroll_period_id, employee_id, net_pay, paid_at')
            .in('payroll_period_id', ids)
        : { data: [] }
    const empIds = Array.from(new Set((lines ?? []).map((l) => l.employee_id).filter((x): x is string => !!x)))
    const { data: emps } = empIds.length
        ? await supabase.from('employees').select('id, code, legal_name').in('id', empIds)
        : { data: [] }
    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.payrollPay.title')}</h1>
            <Subnav />
            <PayPanel periods={(periods ?? []) as never} lines={(lines ?? []) as never} employees={(emps ?? []) as never} />
        </div>
    )
}
