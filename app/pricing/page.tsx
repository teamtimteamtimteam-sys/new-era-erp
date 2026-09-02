// app/pricing/page.tsx
// 定价板块首页:三张卡(公式 / 计价器 / 金属行情)。
// 行情卡指向仍在原位的 /metal-prices —— 本切只做归拢,不搬家。
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from './Subnav'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD, FN } from '@/lib/modules'

// 第三张卡直指每日行情录入 —— 这是本板块最高频的动作,不该藏在"行情"卡再点一次按钮之后。
// 行情历史退成卡片下方的一个小链接,仍是一次点击可达。
const CARDS = [
    { href: '/pricing/formulas', titleKey: 'pricing.formulasCard', descKey: 'pricing.formulasDesc' },
    { href: '/pricing/calculator', titleKey: 'pricing.calculatorCard', descKey: 'pricing.calculatorDesc' },
    { href: '/metal-prices/bulk', titleKey: 'pricing.bulkCard', descKey: 'pricing.bulkDesc' },
]

export default async function PricingHubPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.pricing)
    if (denied) return denied

    const t = await getTranslations()

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{t('pricing.hubTitle')}</h1>
            <Subnav />

            <div className="grid gap-4 md:grid-cols-3">
                {CARDS.map((c) => (
                    <Link
                        key={c.href}
                        href={c.href}
                        className="block border border-gray-300 rounded p-5 hover:bg-gray-50"
                    >
                        <h2 className="font-bold mb-1">{t(c.titleKey)}</h2>
                        <p className="text-sm text-gray-600">{t(c.descKey)}</p>
                    </Link>
                ))}
            </div>

            {/* 卡片之外的小链接:行情历史仍然一次点击可达 */}
            <p className="mt-3 text-sm">
                <Link href={FN.metalPrices.href} className="text-gray-500 hover:text-gray-900 hover:underline">
                    {t('pricing.priceHistoryLink')}
                </Link>
            </p>
        </div>
    )
}
