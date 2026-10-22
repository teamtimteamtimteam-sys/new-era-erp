'use client'

// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-2a(Tim 2026-10-22,TABLE-EXPORT-2 Step 0 Q2)· 一张只读前 N 行的表,【说出来】
// ════════════════════════════════════════════════════════════════════════════
// Tim TABLE-EXPORT-1 Q8:「绝不悄悄截断」。几张列表页只读前 N 行(.limit / .range(0, N-1))而一个字不说 ——
// 屏幕上它与「一共就这么多」一模一样。Q2 的裁定:页面保留 N 行,在表上方写一句
//   「只显示前 N 条,共 M 条 —— 收窄筛选,或导出全部」;导出走一条不带上限的路由,取全部匹配行(上限 50,000)。
//
// ★ `total` 必须是与这一页【同一条筛选】的 count(exact)。它小于等于 `shown` 时本组件什么都不画 ——
//   那时屏幕上就是全体,没有什么要说的。
// ★ `total` 不收 null:调用方用 mustCount 去数,数不出来就让页面失败 —— 一个数不出来的总数不是「没有更多」。
// ════════════════════════════════════════════════════════════════════════════

import { useTranslations } from '@/lib/i18n/client'

// 固定 en-US 的千分位:服务端与浏览器画出同一串字(toLocaleString() 随运行环境变,会让水合对不上)
const COUNT = new Intl.NumberFormat('en-US')

export function RowCapNotice({ shown, total, className }: { shown: number; total: number; className?: string }) {
    const t = useTranslations()
    if (total <= shown) return null
    return (
        <p role="status" data-row-cap-notice=""
            className={'mb-2 text-sm text-amber-800 ' + (className ?? '')}>
            {t('table.export.capNotice', { shown: COUNT.format(shown), total: COUNT.format(total) })}
        </p>
    )
}
