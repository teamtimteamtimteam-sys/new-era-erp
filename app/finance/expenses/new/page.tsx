// app/finance/expenses/new/page.tsx
// 开支登记页(服务端壳):取 active 的 expense 科目(按编码排序,名称按语言)
// + 在册供应商(挂账开支要选),表单交给客户端组件。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import NewExpenseForm, { type AccountOption, type SupplierOption } from './NewExpenseForm'

export default async function NewExpensePage() {
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const [accountsRes, suppliersRes] = await Promise.all([
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
    ])

    const error = accountsRes.error ?? suppliersRes.error
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

    const accounts: AccountOption[] = (accountsRes.data ?? []).map((a) => ({
        code: a.code,
        name: locale === 'zh' ? a.name_zh : a.name_en,
    }))
    const suppliers: SupplierOption[] = (suppliersRes.data ?? []).map((s) => ({
        id: s.id,
        name: s.legal_name,
    }))

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-4">{t('expense.new')}</h1>
            <Subnav />
            <NewExpenseForm accounts={accounts} suppliers={suppliers} />
        </div>
    )
}
