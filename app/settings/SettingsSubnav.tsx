'use client'

// app/settings/SettingsSubnav.tsx
// ════════════════════════════════════════════════════════════════════════════
// UI-1c ①:设置七张子页共用的一条同级导航
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【必须先读:这【不是】把 NAV-CLEANUP-1 删掉的东西加回来】★★
//
// NAV-CLEANUP-1(fcd8322)删掉了十个页内同级导航组件、121 页,其中一个正是
// 【设置自己那一份 Subnav】—— 它当时住在 CONV-6 退休掉的那个三层前缀下,
// 所以这里不写它的旧地址:退休路径闸会抓,而它抓得对(一条退休的路径出现在
// 任何地方都是债,注释也不例外 —— 本刀在自己的注释上被它抓过一次)。
// **它的判据是算出来的,不是看出来的**(docs/nav-registry.md §10.2):
//
//   > 一个目标【被二级菜单 offer 给这个读者】= 它是注册表条目 AND 判据放行
//   > AND 它至少有一个属主模块这个读者进得去。对 11 个 live 角色逐个求。
//   > 一个 Subnav 【被删】,当且仅当它每一个目标都已经被 offer 了。
//
// 设置那一份之所以能安全删除,正是因为 CONV-6 的拍平让它三个目标各自成了注册表
// 条目 —— **那时它们确实全部被顶栏菜单 offer 着**。唯一被保留的
// `app/hr/leave/LeaveSubnav.tsx` 保留的理由也是同一条判据的另一侧:它那五个目标
// 【一个都不在注册表里】,那一行是它们唯一的入口。
//
// ★【UI-1a 把那个前提拿掉了,而没有人发现】★
//   settings 移出 BAR_MODULE_IDS 之后,桌面上再没有任何地方列出那七张子页;
//   头像下拉里只剩一条【算出来的跳转】(settingsHref),指向第一张打得开的。
//   实测(逐条 grep app/ 里全部指向 /settings/* 的 href):
//   **roles / reference / approvals / deleted / import 五张,桌面上点不到**,
//   受影响的是 admin 与 cco 两个人,从 UI-1a 上线那天起。
//
// 所以本文件【不是】一次回退,而是 NAV-CLEANUP-1 自己的判据遇上了改变了的事实:
// 目标不再被 offer 了,那一行于是重新成立。
// ★ 顺带记一件事,它值得单独说 ★:本刀的委托书把
// `app/purchasing/Subnav.tsx` 写成「本刀要复用的、树里已经存在的样板」——
// **那个文件正是 NAV-CLEANUP-1 删掉的十个之一。** 一句曾经为真的话,
// 隔了两刀之后被当成现在仍然为真的来读,而它已经不是了。
// 这与 FIX-2a 那一刀的题目是同一个:**一处缺席不许被读成一个答案。**
//
// ── 这一条与头像下拉那七行【不是】两份清单 ────────────────────────────────
// 两处都来自 lib/modules.ts 的 FUNCTIONS,经 getModuleAccess() 求值,
// **顺序就是数组顺序**(lib/modules.ts:780 写着这一条)。这里不排序、不过滤、
// 不重列一份码 —— 尤其是【不重列码】:七张子页由【四个】不同的判据把门,
// 而其中一个(字典)是 `{ all: [], any: [...] }`,一份手抄的码清单根本表达不了它。
//
// 【进不去的照画成「名字 · 受限」,不省略】D5 / NAV-REG-1 R4,措辞与记号沿用既有
// 那一套(common.restricted + dashboard.restrictedHint + data-module-restricted)。
// ★ 实测的后果照直说:六个人里有四个(gm / operations / finance / warehouse)
//   在这条上看到的是【七格里六格灰】,只有字典亮着。那是 D5 想要的样子 ——
//   Choo Er 因此知道设置底下有七件事,以及哪几件不归她,而不是以为只有一件。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { entryForPath } from '@/lib/navTrail'
import type { NavEntry } from '@/app/components/nav/types'

export default function SettingsSubnav({ entries }: { entries: NavEntry[] }) {
    const pathname = usePathname()
    const t = useTranslations()

    // ★【"我站在哪一条上"只有一份实现】★ lib/navTrail.entryForPath 就是【最长前缀】,
    //   顶栏的二级高亮与面包屑用的都是它。这里再写一遍 `startsWith` 就是第二份 ——
    //   而 NAV-CLEANUP-1 ⑤ 记过那第二份具体错在哪:站在 /inventory/locations 上,
    //   「现况」(/inventory)与「库位」会【同时】亮。
    //   (被它删掉的 app/inventory/Subnav.tsx 反而做对了这件事 —— 正确的实现一直
    //    在树里,只是没长在菜单上。这里让它长回来。)
    const activeHref = entryForPath(pathname)?.href ?? null

    const base = 'whitespace-nowrap rounded px-3 py-1 text-sm'
    return (
        <nav data-nav="settings-subnav" aria-label={t('nav.settings')} className="flex flex-wrap gap-1">
            {entries.map((e) =>
                e.allowed ? (
                    <Link
                        key={e.href}
                        href={e.href}
                        data-menu-row=""
                        aria-current={e.href === activeHref ? 'page' : undefined}
                        className={
                            base + ' ' +
                            (e.href === activeHref
                                ? 'bg-[color:var(--brand-ocean-fill)] text-white'
                                : 'text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]')
                        }
                    >
                        {t(e.key)}
                    </Link>
                ) : (
                    <span
                        key={e.href}
                        data-menu-row=""
                        data-module-restricted="1"
                        title={t('dashboard.restrictedHint')}
                        className={base + ' text-[color:var(--brand-muted-glass)] cursor-default'}
                    >
                        {t(e.key)} · {t('common.restricted')}
                    </span>
                )
            )}
        </nav>
    )
}
