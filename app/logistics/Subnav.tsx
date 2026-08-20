import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'

// LOG-2b:物流三页共用的子导航。集装箱挂在【既有的】Logistics 入口下面,
// 不另建一个顶层模块项、更不铸新权限码 —— 把关仍是 module.purchasing.view。
export default async function LogisticsSubnav() {
    const t = await getTranslations()
    const item = 'text-sm text-blue-700 hover:underline'
    return (
        <nav className="mb-6 flex gap-4 border-b pb-2">
            <Link href="/logistics/forwarders" className={item}>{t('logistics.forwardersTitle')}</Link>
            <Link href="/logistics/containers" className={item}>{t('logistics.containersTitle')}</Link>
            <Link href="/logistics/lanes" className={item}>{t('logistics.lanesTitle')}</Link>
        </nav>
    )
}
