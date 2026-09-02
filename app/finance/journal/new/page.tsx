// app/finance/journal/new/page.tsx
// 手工分录页(服务端壳):取活跃科目(语言侧名字这里解析好),表单交给客户端组件。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import NewEntryForm, { type AccountOption } from './NewEntryForm'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewEntryPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const res = await supabase
        .from('accounts')
        .select('code, name_en, name_zh, account_type')
        .eq('is_active', true)
        .order('code')

    if (res.error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.newEntryTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(res.error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const accounts: AccountOption[] = mustRows(res).map((a) => ({
        code: a.code,
        name: locale === 'zh' ? a.name_zh : a.name_en,
        account_type: a.account_type,
    }))

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.newEntryTitle')}</h1>
            <NewEntryForm accounts={accounts} baseCurrency={await getBaseCurrency()} />
        </div>
    )
}
