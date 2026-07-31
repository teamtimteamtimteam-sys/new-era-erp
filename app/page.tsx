import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'

const SECTIONS = [
    {
        titleKey: 'home.sectionMasterData',
        cards: [
            { href: '/suppliers', titleKey: 'home.suppliersTitle', descKey: 'home.suppliersDesc' },
            { href: '/customers', titleKey: 'home.customersTitle', descKey: 'home.customersDesc' },
            { href: '/materials', titleKey: 'home.materialsTitle', descKey: 'home.materialsDesc' },
            { href: '/pricing', titleKey: 'home.pricingTitle', descKey: 'home.pricingDesc' },
        ],
    },
    {
        titleKey: 'home.sectionOperations',
        cards: [
            // 采购在收货之前 —— 流程顺序:下单 → 收货 → 加工
            { href: '/purchasing', titleKey: 'home.purchasingTitle', descKey: 'home.purchasingDesc' },
            { href: '/inbound', titleKey: 'home.inboundTitle', descKey: 'home.inboundDesc' },
            { href: '/output', titleKey: 'home.outputTitle', descKey: 'home.outputDesc' },
            { href: '/processing', titleKey: 'home.processingTitle', descKey: 'home.processingDesc' },
            { href: '/stocktakes', titleKey: 'home.stocktakesTitle', descKey: 'home.stocktakesDesc' },
        ],
    },
    {
        titleKey: 'home.sectionReports',
        cards: [
            { href: '/inventory', titleKey: 'home.inventoryTitle', descKey: 'home.inventoryDesc' },
            { href: '/finance', titleKey: 'home.financeTitle', descKey: 'home.financeDesc' },
        ],
    },
]

export default async function Home() {
    const t = await getTranslations()
    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-2">Evoltrya OS</h1>
            <p className="text-gray-600 mb-8">{t('home.subtitle')}</p>

            {SECTIONS.map((section) => (
                <div key={section.titleKey} className="mb-8">
                    <h2 className="text-lg font-semibold mb-4">{t(section.titleKey)}</h2>
                    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
                        {section.cards.map((card) => (
                            <Link
                                key={card.href}
                                href={card.href}
                                className="border border-gray-300 rounded-lg p-6 hover:bg-gray-50 hover:border-gray-400 transition block"
                            >
                                <h3 className="font-semibold text-lg mb-1">{t(card.titleKey)}</h3>
                                <p className="text-sm text-gray-600">{t(card.descKey)}</p>
                            </Link>
                        ))}
                    </div>
                </div>
            ))}
        </div>
    )
}
