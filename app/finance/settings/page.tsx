// app/finance/settings/page.tsx
// 财务设置:期间锁(locked_before)。早于锁定日的分录会被拒绝 —— 会产生
// 此类分录的业务操作(计价/销售/过账盘点等)也会被一并阻止。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../Subnav'
import LockForm from './LockForm'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function FinanceSettingsPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const { data, error } = await supabase
        .from('finance_settings')
        .select('locked_before')
        .eq('id', true)
        .single()

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.settingsTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const lockedBefore = data?.locked_before ?? null

    return (
        <div className="p-8 max-w-2xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.settingsTitle')}</h1>

            <Subnav />

            <div className="bg-gray-50 rounded p-4 mb-6 text-sm">
                <span className="text-gray-600 mr-1">{t('finance.lockedBefore')}:</span>
                {lockedBefore ? (
                    <span className="font-mono font-medium">{lockedBefore}</span>
                ) : (
                    <span className="text-gray-400">{t('finance.notSet')}</span>
                )}
            </div>

            <LockForm lockedBefore={lockedBefore} />

            {/* 手动锁是覆盖手段;正常关账走月结页 */}
            <p className="text-sm text-gray-500 mt-4">
                <Link href="/finance/close" className="text-blue-600 hover:underline">
                    {t('finance.useClosePage')}
                </Link>
            </p>

            <p className="text-sm text-gray-500 mt-6">{t('finance.lockExplainer')}</p>
        </div>
    )
}
