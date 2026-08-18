// app/finance/expenses/new/page.tsx
// 开支登记页(服务端壳):取 active 的 expense 科目(按编码排序,名称按语言)
// + 在册供应商(挂账开支要选),表单交给客户端组件。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import NewExpenseForm, { type AccountOption, type SupplierOption } from './NewExpenseForm'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewExpensePage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()
    const locale = await getLocale()

    const [accountsRes, suppliersRes, employeesRes] = await Promise.all([
        supabase
            .from('accounts')
            .select('code, name_en, name_zh')
            .eq('account_type', 'expense')
            .eq('is_active', true)
            .order('code'),
        supabase
            .from('suppliers')
            .select('id, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        // PAYEE-1b:未付费用的往来对象可以是员工(报销)。
        // 【读 employees_masked】它是遮蔽视图,门是 module.hr.view —— 没有 HR
        // 权限的财务读者会读到 0 行,而那时下拉里会显示"名单为空"那句话。
        // 那句话在这里【略微不准】(真相是"你看不到"而不是"没有人"),
        // 但两者的下一步是同一句:去人事模块。留一条已知项,不假装它准。
        supabase
            .from('employees_masked')
            .select('id, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
    ])

    const error = accountsRes.error ?? suppliersRes.error ?? employeesRes.error
    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('expense.new')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const accounts: AccountOption[] = (mustRows(accountsRes)).map((a) => ({
        code: a.code,
        name: locale === 'zh' ? a.name_zh : a.name_en,
    }))
    const suppliers: SupplierOption[] = (mustRows(suppliersRes)).map((s) => ({
        id: s.id,
        name: s.legal_name,
    }))
    const employees: SupplierOption[] = (mustRows(employeesRes) as { id: string; legal_name: string }[])
        .map((e) => ({ id: e.id, name: e.legal_name }))

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-4">{t('expense.new')}</h1>
            <Subnav />
            <NewExpenseForm
                baseCurrency={baseCurrency} accounts={accounts} suppliers={suppliers}
                employees={employees} />
        </div>
    )
}
