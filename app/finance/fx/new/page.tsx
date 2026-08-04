// app/finance/fx/new/page.tsx
// 新增牌价页(服务端壳):可选币种 = 非本位币(is_base 取反,不点名;加币种自动跟上)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import NewFxRateForm from './NewFxRateForm'

export default async function NewFxRatePage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const { data } = await supabase
        .from('currencies')
        .select('code')
        .eq('is_base', false)
        .order('code')

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link href="/finance/fx" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">{t('finance.fxPage.newTitle')}</h1>

            <NewFxRateForm currencies={(data ?? []).map((c) => c.code)} />
        </div>
    )
}
