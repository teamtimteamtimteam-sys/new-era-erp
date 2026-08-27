// app/finance/AgingAsOfNotice.tsx
// 账龄两页共用的【说出来】那一块:过去时点的横幅、金额口径、以及缺席的数目。
//
// ★【为什么是横幅而不是一行小字】★ 一页悄悄显示着一个历史数字,与一条读起来
// 像当前值的过期记录是同一种谎 —— 而这一页上那个数会被人抄进邮件、抄进会议纪要。
// 分量取自本仓库已有的重估横幅:一个过去的时点与一张过期的牌价是同一类问题。
// 截至日是今天时,整块【不出现】—— 今天没有什么要声明的。
//
// 【缺席要报数】那一天还没有价的批次不进这份账龄(它当时确实还不是一笔可计量
// 应付)。但"没有这一行"与"本来就没有这笔钱"在屏幕上长得一模一样,
// 所以缺席必须说得出数目 —— 这是本仓库「命名的缺席,绝不是空白」那一条。
// 没有 data.view_prices 时这个数是 null,那不是"零张"而是"你看不到这一栏",
// 于是它诚实地不显示,而不是显示成 0。
import { getTranslations } from '@/lib/i18n/server'
import type { AmountBasis } from './agingAsOf'

export default async function AgingAsOfNotice({
    asOf,
    today,
    isPast,
    beforeSystemStart,
    systemStartDate,
    amountBasis,
    unpricedExcluded,
}: {
    asOf: string
    today: string
    isPast: boolean
    beforeSystemStart: boolean
    systemStartDate: string | null
    amountBasis: AmountBasis
    unpricedExcluded: number | null
}) {
    const t = await getTranslations()
    if (!isPast) return null

    return (
        <div className="mb-6 rounded border border-amber-400 bg-amber-50 px-4 py-3 text-sm text-amber-900">
            <p className="font-bold">
                {t('finance.agingAsOf.pastBanner', { date: asOf, today })}
            </p>
            <p className="mt-1">{t('finance.agingAsOf.basis.' + amountBasis)}</p>
            {unpricedExcluded !== null && unpricedExcluded > 0 && (
                <p className="mt-1">
                    {t('finance.agingAsOf.unpricedExcluded', { n: String(unpricedExcluded) })}
                </p>
            )}
            {beforeSystemStart && systemStartDate && (
                <p className="mt-1 font-medium">
                    {t('finance.agingAsOf.beforeSystemStart', { date: systemStartDate })}
                </p>
            )}
        </div>
    )
}
