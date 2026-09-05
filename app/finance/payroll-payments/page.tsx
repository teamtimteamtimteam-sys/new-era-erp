// 发薪与汇缴(FIN-7 C1/C2)。逐人勾选付款 —— 转账会失败重发,部分跑批是常态;
// CPF / 代扣款各一键,一期一次,带金额与到期日。
//
// ★ CONV-3(Kind-C):套 ListPage 外壳。恒为 ok —— 「近六个月没有已过账的
// 薪资期间」由 PayPanel 自己说(它不是一个隐藏了出口的空态,这一页在零期间时
// 也没有别的东西可加)。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations } from '@/lib/i18n/server'
import { ListPage } from '@/app/components/ui/list-page'
import PayPanel from './PayPanel'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function PayrollPaymentsPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    // PayPanel 是客户端组件,本位币当 prop 传进去(CCY-1)
    const baseCurrency = await getBaseCurrency()
    // FIX-2a:payroll_periods 与 employees 都挂 module.hr.view,而这一页的守卫是
    // finance.view —— cfo 与 finance 读回零行,于是「本期薪资」整块是空的,
    // 屏幕说的是【这个月没有薪资期间】,对两个要去付薪的人。
    // ★ 两张查名视图的金额列【仍按 data.view_pay 遮】,而 finance 与 cfo
    //   本来就持有它 —— 所以这里一分钱都没有多给,只是不再说那句假话。
    const { data: periods } = await supabase.from('payroll_period_lookup')
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
        ? await supabase.from('employee_lookup').select('id, code, legal_name').in('id', empIds)
        : { data: [] }
    return (
        <ListPage title={t('finance.payrollPay.title')} maxWidth="max-w-5xl" state={{ kind: 'ok' }}>
            <PayPanel periods={(periods ?? []) as never} lines={(lines ?? []) as never} employees={(emps ?? []) as never} baseCurrency={baseCurrency} />
        </ListPage>
    )
}
