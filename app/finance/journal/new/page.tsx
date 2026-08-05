// app/finance/journal/new/page.tsx
// 手工分录页(服务端壳):取活跃科目(语言侧名字这里解析好),表单交给客户端组件。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import NewEntryForm, { type AccountOption } from './NewEntryForm'

export default async function NewEntryPage() {
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const { data, error } = await supabase
        .from('accounts')
        .select('code, name_en, name_zh, account_type')
        .eq('is_active', true)
        .order('code')

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.newEntryTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const accounts: AccountOption[] = (data ?? []).map((a) => ({
        code: a.code,
        name: locale === 'zh' ? a.name_zh : a.name_en,
        account_type: a.account_type,
    }))

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.newEntryTitle')}</h1>
            <Subnav />
            <NewEntryForm accounts={accounts} baseCurrency={await getBaseCurrency()} />
        </div>
    )
}
