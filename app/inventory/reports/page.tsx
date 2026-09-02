// RPT-1:报表中心的入口。四张【只读】报表,都在库存域内。
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

const CARDS = [
    { href: '/inventory/reports/snapshot', titleKey: 'reports.snapshot.title', descKey: 'reports.snapshot.desc' },
    { href: '/inventory/reports/violations', titleKey: 'reports.violations.title', descKey: 'reports.violations.desc' },
    { href: '/inventory/reports/safety', titleKey: 'reports.safety.title', descKey: 'reports.safety.desc' },
    { href: '/inventory/reports/ledger', titleKey: 'reports.ledger.title', descKey: 'reports.ledger.desc' },
]

export default async function ReportsIndexPage() {
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied
    const t = await getTranslations()

    return (
        <>
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-2">{t('reports.title')}</h1>
                <p className="text-sm text-gray-500 mb-6">{t('reports.intro')}</p>
                <div className="grid gap-4 sm:grid-cols-2 max-w-4xl">
                    {CARDS.map((c) => (
                        <Link key={c.href} href={c.href}
                              className="block border border-gray-300 rounded p-4 hover:bg-gray-50">
                            <div className="font-medium mb-1">{t(c.titleKey)}</div>
                            <div className="text-sm text-gray-500">{t(c.descKey)}</div>
                        </Link>
                    ))}
                </div>
            </div>
        </>
    )
}
