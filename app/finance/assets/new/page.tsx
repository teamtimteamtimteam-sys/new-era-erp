// app/finance/assets/new/page.tsx
// EQP-1c-b(P1):登记一台机器(服务端壳)。
// 这张表单【不过账】—— 它建的是一张主数据卡,成本随后经开支单落上来。
import { getTranslations } from '@/lib/i18n/server'
import NewAssetForm from './NewAssetForm'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewAssetPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const t = await getTranslations()

    return (
        <div className="p-6">
            <h1 className="text-2xl font-semibold mb-1">{t('assets.new.title')}</h1>
            <p className="text-sm text-gray-600 mb-6">{t('assets.new.subtitle')}</p>
            <NewAssetForm />
        </div>
    )
}
