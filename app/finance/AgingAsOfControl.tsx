'use client'

// app/finance/AgingAsOfControl.tsx
// 账龄两页共用的截至日控件 + 导出入口。样式与行为端口自 BsToolbar。
//
// 【两页共用一个控件,不是各写一个】它决定的是 URL 上那一个 as_of,
// 而那个 as_of 同时喂给页面与导出 —— 三处必须是同一个日期。
//
// 【未来日期在这里就【拦住】,而服务端【另外】还会拒】
// 与本仓库对"决定期间的日期"那条两道闸的规矩同形:控件不给出一个服务端
// 保证会拒的动作(max=今天),而 ap_aging_asof / ar_aging_asof 各自独立地
// 抛 AGING_AS_OF_FUTURE —— 绕开界面也过不去。少了后一半,这里只是装饰。
//
// 【"今天"取库那一侧的今天】max 与"回到今天"用的都是服务端传下来的 today
// (报表自己报的 today 字段),不是浏览器的 new Date():浏览器可能在别的时区,
// 而这套系统的今天是新加坡的今天(db/fixtures/15)。
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

export default function AgingAsOfControl({
    asOf,
    today,
    exportHref,
}: {
    asOf: string
    today: string
    exportHref: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    function go(value: string) {
        const params = new URLSearchParams(searchParams.toString())
        if (!value || value === today) params.delete('as_of')
        else params.set('as_of', value)
        const qs = params.toString()
        router.push(qs ? `${pathname}?${qs}` : pathname)
    }

    return (
        <div className="mb-4 flex flex-wrap items-center gap-3">
            <label className="text-sm text-gray-600">
                {t('finance.asOf')}{' '}
                <input
                    type="date"
                    value={asOf}
                    max={today}
                    onChange={(e) => go(e.target.value)}
                    className="rounded border border-gray-300 bg-white px-3 py-2"
                />
            </label>
            {asOf !== today && (
                <Button variant="secondary"
                    type="button"
                    onClick={() => go(today)}
                >
                    {t('finance.agingAsOf.backToToday')}
                </Button>
            )}
            <a
                href={exportHref}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
            >
                {t('finance.agingAsOf.exportCsv')}
            </a>
        </div>
    )
}
