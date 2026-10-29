// app/components/nav/DateButton.tsx
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-4(Tim 2026-10-29 第 20 条)· 顶栏头像左边那颗钮:今天的日期,点开日历
// ════════════════════════════════════════════════════════════════════════════
//
// 【它取代了什么】UI-1a 的工具下拉(三个点 + 一张下拉)。单位换算搬进了定价(第 5 条),任务与提醒早在
//   SYSTEM-MAP-1 搬进了工作台,工具名下只剩日历 —— 一张只有一行的下拉不如一颗直接的钮。
//
// 【哪一天】新加坡的营业日(lib/format.ts 的 businessToday()),不是浏览器的、
//   也不是服务器的本地日期。格式是屏幕上的单据日期那一种(formatDate,DD/MM/YYYY,两种语言一样 —— DATE-1 Q16)。
//   ⚠ 这串字只给人看;它【不】喂回给任何日期框或查询(AGENTS.md / formatDate 抬头那条)。
//
// 【每一个宽度都在】抽屉里的「工具」区一并删了,所以这颗钮是日历在 1280 以下的唯一一扇门(滚问第 1 条)。
//   日历的条目判据是恒真({ all: [] }),所以这里没有「受限」那一支。
import Link from 'next/link'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { businessToday } from '@/lib/format'
import { formatDate } from '@/lib/dates'
import { FUNCTIONS } from '@/lib/modules'

const CALENDAR = FUNCTIONS.find((f) => f.href === '/tools/calendar')

export default async function DateButton() {
    if (!CALENDAR) throw new Error('DateButton: /tools/calendar 不在注册表里')
    const t = await getTranslations()
    const today = formatDate(businessToday(), await getLocale())
    const label = `${t(CALENDAR.navKey)} · ${today}`
    return (
        <Link
            href={CALENDAR.href}
            data-nav="date-button"
            aria-label={label}
            title={label}
            className={
                'flex h-8 shrink-0 items-center rounded-full border border-[color:var(--brand-border)] px-2 ' +
                'text-sm tabular-nums text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]'
            }
        >
            {today}
        </Link>
    )
}
