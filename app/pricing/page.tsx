// app/pricing/page.tsx
// 定价板块首页:三张卡(公式 / 计价器 / 金属行情)。
// 行情卡指向仍在原位的 /metal-prices —— 本切只做归拢,不搬家。
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from './Subnav'

const CARDS = [
    { href: '/pricing/formulas', titleKey: 'pricing.formulasCard', descKey: 'pricing.formulasDesc' },
    { href: '/pricing/calculator', titleKey: 'pricing.calculatorCard', descKey: 'pricing.calculatorDesc' },
    { href: '/metal-prices', titleKey: 'pricing.pricesCard', descKey: 'pricing.pricesDesc' },
]

export default async function PricingHubPage() {
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
        </div>
    )
}
