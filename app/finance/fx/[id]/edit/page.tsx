// app/finance/fx/[id]/edit/page.tsx
// 编辑牌价页(服务端壳):取行 + 非 SGD 币种选项,表单交给客户端组件。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import EditFxRateForm from './EditFxRateForm'

export default async function EditFxRatePage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const [rateRes, currenciesRes] = await Promise.all([
        supabase
            .from('fx_rates')
            .select('id, currency, rate_type, rate_sgd_per_unit, rate_date, source, notes')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase.from('currencies').select('code').neq('code', 'SGD').order('code'),
    ])

    if (rateRes.error || !rateRes.data) {
        notFound()
    }

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link href="/finance/fx" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">{t('finance.fxPage.editTitle')}</h1>

            <EditFxRateForm
                rate={rateRes.data}
                currencies={(currenciesRes.data ?? []).map((c) => c.code)}
            />
        </div>
    )
}
