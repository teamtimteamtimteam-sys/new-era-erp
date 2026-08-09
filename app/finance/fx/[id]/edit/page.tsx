// app/finance/fx/[id]/edit/page.tsx
// 编辑牌价页(服务端壳):取行 + 非 SGD 币种选项,表单交给客户端组件。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import EditFxRateForm from './EditFxRateForm'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function EditFxRatePage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

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
        supabase.from('currencies').select('code').eq('is_base', false).order('code'),
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
                currencies={(mustRows(currenciesRes)).map((c) => c.code)}
            />
        </div>
    )
}
