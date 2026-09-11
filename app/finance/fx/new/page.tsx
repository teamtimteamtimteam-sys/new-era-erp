// app/finance/fx/new/page.tsx
// 新增牌价页(服务端壳):可选币种 = 非本位币(is_base 取反,不点名;加币种自动跟上)。
import Link from 'next/link'
import { mustRows } from '@/lib/db-helpers'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import NewFxRateForm from './NewFxRateForm'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'

export default async function NewFxRatePage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const canEditGate = await can('module.finance.edit')

    const supabase = await createClient()
    const t = await getTranslations()

    const res = await supabase
        .from('currencies')
        .select('code')
        .eq('is_base', false)
        .order('code')

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link href="/finance/fx" className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="mb-6">{t('finance.fxPage.newTitle')}</h1>

            <NewFxRateForm canEdit={canEditGate} currencies={mustRows(res).map((c) => c.code)} />
        </div>
    )
}
