'use client'

// METAL-1:录入之前的异常提示。【提醒,不拦截】
//
// 3 倍的真实行情是可能的,拒收它是错的 —— 而系统【无法分辨】哪一种是哪一种,
// 与证书处置按类型分(CMP-1)是同一条理由。所以这里把【两个数字都摆出来】
// (要录的这个、拿来比的那个、以及它是哪一天的),让人自己判断,再确认保存。
//
// 【为什么不禁钮】禁钮是给"服务端保证会拒"的动作用的(CMP-2 / SAL-B6 的规矩)。
// 这里服务端【不会拒】,禁钮反而会把一个合法的录入变成一堵没有出口的墙。
import { useTranslations } from '@/lib/i18n/client'
import type { AnomalyVerdict } from './anomaly'

export default function AnomalyWarning({ items }: { items: AnomalyVerdict[] }) {
    const t = useTranslations()
    if (items.length === 0) return null

    return (
        <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded space-y-2">
            <p className="font-medium">{t('metalPrices.anomaly.title')}</p>
            <ul className="text-sm space-y-1">
                {items.map((v) => (
                    <li key={v.metal}>
                        {t('metalPrices.anomaly.line', {
                            metal: t('metals.' + v.metal),
                            price: v.price_usd_per_tonne,
                            change: v.change_pct ?? 0,
                            refPrice: v.reference_price ?? 0,
                            refDate: v.reference_date ?? '',
                            threshold: v.threshold_pct,
                        })}
                        {/* 参照是【更晚】的一条时说出来 —— 补录进历史中间的那一行,
                            "上一条"在它后面,不讲清楚会让人以为读错了日期 */}
                        {v.reference_side === 'later' && (
                            <span className="ml-1 text-amber-700">
                                {t('metalPrices.anomaly.laterSide')}
                            </span>
                        )}
                    </li>
                ))}
            </ul>
            <p className="text-sm">{t('metalPrices.anomaly.hint')}</p>
        </div>
    )
}
