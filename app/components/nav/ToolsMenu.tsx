'use client'

// app/components/nav/ToolsMenu.tsx
// ════════════════════════════════════════════════════════════════════════════
// UI-1a ④:工具那一格从一级模块变成顶栏右侧的一个圆按钮 + 一张下拉
// ════════════════════════════════════════════════════════════════════════════
//
// 【它画的是【同一套】菜单,不是第二套】面板、滚动、"还有 N 条"、Esc 与点外面关闭
// 全部来自 ./MenuPanel.tsx —— 那些就是一级模块菜单一直在用的实现,本刀把它们
// 从 ModuleBar 内部搬出来给三个调用方共用。**这里没有一行自己的下拉实现。**
//
// ★【一个图标都没有 —— Tim 的裁定】★ 五行纯文字。委托书原话:
//   「NOT a Google-style icon grid. Tim cancelled that.」以及
//   「NO ICONS ANYWHERE IN EITHER DROPDOWN.」复用模块菜单的画法之所以对,
//   一半理由正是**它本来就没有图标**,于是这里不存在任何图标工作。
//
// ★★【进不去的那一条【照画】,不省略 —— 与模块条同一条规则】★★
// 委托书点名:「the row must not silently vanish into a shorter menu that reads
// as "these are all the tools there are"」。这正是 FIX-2a 整刀的题目。
// 所以这里用的是【既有的那一套措辞】:common.restricted + dashboard.restrictedHint
// + data-module-restricted 这个机器标记 —— 与模块菜单里的二级条目逐字相同。
// **同一个意思的第二套说法,就是下一次漂移的种子。**
// 实测口径:定价要 module.pricing.view,任务要 module.tasks.view;
// 日历 / 单位换算 / 提醒是恒真条目(permission: { all: [] }),对谁都进得去。
// 也就是说 warehouse 这样的账号会看到「定价 · 受限」而不是一张四行的菜单。
import Link from 'next/link'
import { useRef, useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { ScrollPanel, menuPanelClass, useMenuDismiss, ROUND_BUTTON_CLASS } from './MenuPanel'
import type { NavEntry } from './types'

export default function ToolsMenu({ entries }: { entries: NavEntry[] }) {
    const t = useTranslations()
    const [open, setOpen] = useState(false)
    const ref = useRef<HTMLDivElement>(null)
    useMenuDismiss(ref, () => setOpen(false))

    const RESTRICTED = t('common.restricted')
    const HINT = t('dashboard.restrictedHint')
    const label = t('nav.tools')

    return (
        <div ref={ref} className="relative" data-nav="tools-menu">
            <button
                type="button"
                aria-expanded={open}
                aria-haspopup="true"
                aria-label={label}
                title={label}
                onClick={() => setOpen(!open)}
                className={ROUND_BUTTON_CLASS}
            >
                {/* ★【为什么是三个点,而不是一个扳手】★
                    Tim 排除了图标集,而一个 32px 的圆里放不下「工具」两个字。
                    三个点是"还有更多东西在这里"的通行记号,而且它【不是一个图标】——
                    三个 CSS 圆点,没有图标库、没有 SVG 字形。
                    ★ 照直说清楚:它读起来是「更多」,不是「工具」。★
                    把"工具"这个词说出来的是 aria-label 与 title(读屏与悬停都拿得到),
                    不是这个形状。要让形状本身说"工具",要么放一个词(圆里放不下),
                    要么放一个图标(被否了)—— 这是一处真实的取舍,记在这里。 */}
                <span aria-hidden className="flex items-center gap-[3px]">
                    <span className="h-[3px] w-[3px] rounded-full bg-current" />
                    <span className="h-[3px] w-[3px] rounded-full bg-current" />
                    <span className="h-[3px] w-[3px] rounded-full bg-current" />
                </span>
            </button>

            {open && (
                <ScrollPanel
                    className={menuPanelClass('right', 'w-56')}
                    role="menu"
                    moreLabel={(n) => t('nav.menuMoreBelow', { n })}
                >
                    {entries.map((e) =>
                        e.allowed ? (
                            <Link
                                key={e.href}
                                href={e.href}
                                data-menu-row=""
                                onClick={() => setOpen(false)}
                                className="block rounded pl-3 pr-3 py-1.5 text-sm text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]"
                            >
                                {t(e.key)}
                            </Link>
                        ) : (
                            <span
                                key={e.href}
                                data-menu-row=""
                                data-module-restricted="1"
                                title={HINT}
                                className="block pl-3 pr-3 py-1.5 text-sm text-[color:var(--brand-muted-glass)] cursor-default"
                            >
                                {t(e.key)} · {RESTRICTED}
                            </span>
                        )
                    )}
                </ScrollPanel>
            )}
        </div>
    )
}
