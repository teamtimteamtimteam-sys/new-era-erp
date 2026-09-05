'use client'

// app/components/nav/AvatarMenu.tsx
// ════════════════════════════════════════════════════════════════════════════
// UI-1a ⑤:头像按钮 + 「关于你」那一整区,从顶栏散落的五件东西收成一张下拉
// ════════════════════════════════════════════════════════════════════════════
//
// 【它收走了什么】UI-1a 之前,顶栏右侧平铺着:邮箱、通知铃、我的评估、我的档案、
// 语言按钮、登出 —— 六样东西,而其中两样(/my-reviews 是 lg:inline、/me 是
// sm:inline)在某些宽度上【根本不画】。CONV-6 的抬头点名过那个缺口:
// **640px ≤ 宽 < 1024px 这一段里,/my-reviews 顶栏上没有、抽屉里也到不了。**
// 收进一张下拉之后那个缺口【结构性地消失了】—— 菜单不按宽度藏条目。
//
// 【面板是共用的那一套】./MenuPanel.tsx,与一级模块菜单、工具下拉同一份实现。
// ★ 一个图标都没有 ★(Tim 的裁定)。
//
// ★★【未读数【一个来源,两处渲染】】★★(委托书点名:do not compute it twice)
//   取数在 lib/notifications.ts:getUnreadCount(),顶栏调【一次】,把结果当 prop
//   传进来。这里把同一个 `unread` 画两遍:头像右上角的徽标,与「通知」那一行的行尾。
//   **两处各查一次的话,两次查询之间通知表可以变** —— 徽标写 3、行尾写 2,
//   而屏幕上没有任何东西说这两个数本该是同一个数。
//
//   ★【三态在这里也必须活着】★ unread === null 的意思是【没问出来】,不是 0。
//     徽标印「!」不印「0」,行尾印「!」不印「0」,而且底色不同(灰 vs 红)。
//     一次读失败被画成一个干净的收件箱,正是 FIX-2a 那一刀的形状。
import Link from 'next/link'
import { useCallback, useRef, useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { logout } from '@/app/logout/actions'
import LanguageSwitcher from '../LanguageSwitcher'
import {
    ScrollPanel, menuPanelClass, useMenuDismiss, ROUND_BUTTON_CLASS, MenuEntryRow,
} from './MenuPanel'
import type { NavEntry } from './types'

export type AvatarMenuProps = {
    /** preferred_name ?? legal_name。**没有员工档案的账号是 null** —— 见下面。 */
    name: string | null
    email: string
    /** null = 没问出来,与 0 是两回事。 */
    unread: number | null
    /**
     * ★★【UI-1c ①:这里此前是 `settingsHref: string | null` —— 一条【跳转】】★★
     *
     * 【它是什么】服务端按注册表算出「这个人打得开的第一张子页」,菜单里那一行
     *   指向它。UI-1a 造它是对的:写死 /settings/accounts 会给 Choo Er 一条永远
     *   拒绝的链接(她没有 action.manage_permissions)。
     *
     * ★【但它掩盖了一处【实测出来的】回归,而那才是本刀 Step 1 的由来】★
     *   UI-1a 把 settings 移出 BAR_MODULE_IDS 之后,桌面上【再没有任何地方】
     *   列出设置底下那七张子页:模块条不画它,工具下拉只装工具,面包屑只在深路由上。
     *   于是整个桌面对设置只剩这【一条跳转】。逐条 grep 过 app/ 里所有指向
     *   /settings/* 的 href,结论是:
     *     · accounts     —— 这一行(admin / cco);
     *     · dictionaries —— 四条来自物料与化验表单的就地链接 + 其余四人的这一行;
     *     · roles / reference / approvals / deleted / import
     *       —— **五张子页在桌面上点不到**(/settings/roles 只被它自己的
     *          new 与 [id] 两页链着,而那两页要先站在 roles 上才到得了)。
     *   实测受影响的是 Tim(admin)与 Sandra(cco)两个人,从 UI-1a 上线那天起。
     *
     * ★【为什么修法是【七条】而不是【换一条更好的跳转】】★
     *   NAV-CLEANUP-1 ⑥ 删掉十个页内同级导航组件时,判据是算出来的:
     *   「一个目标被菜单 offer 给这个读者 = 它是注册表条目 AND 判据放行 AND
     *     至少一个属主模块他进得去」,对 11 个 live 角色逐个求;
     *   拍平之前设置那一份 Subnav(它住在 CONV-6 退休掉的那个三层前缀下,
     *   所以这里不写它的旧地址 —— 退休路径闸会抓)之所以可以安全删除,
     *   正是因为那时它那三个目标【全部被菜单 offer 了】。**UI-1a 把那个前提拿掉了。**
     *   所以这不是推翻 NAV-CLEANUP-1,是它自己的判据遇上了改变了的事实。
     *   工具早就是七条里的五条一次给全(ToolsMenu),设置本就该对称。
     *
     * 【它现在是什么】设置名下的【全部七条】,各带 allowed —— 与工具下拉、
     * 手机抽屉拿到的是同一个数组里的同一批对象(TopNav 只算一次)。
     * 一张都打不开的人看到的是七行「· 受限」,不是一处缺席。
     */
    settingsEntries: NavEntry[]
}

/**
 * 【头像里印什么】(Tim 的裁定,UI-1a Q7)
 *   有名字 → 取首字母,最多两个(「Sandra Yap」→「SY」)。
 *   没名字 → **邮箱的第一个字符**,并且菜单里【不画名字那一行】,只画邮箱。
 *
 * ★【为什么不能编一个占位名】★ 一个还没被 HR 建档的新人,账号是真的、邮箱是真的,
 *   名字是【还没有】。印「User」或者「—」就是把一处缺席画成一个答案 ——
 *   而"这个账号还没连上员工档案"是一件他应该看得出来的事。省掉那一行,
 *   剩下的邮箱就是他此刻【真实】的身份。
 */
function initialsOf(name: string | null, email: string): string {
    if (name) {
        const parts = name.trim().split(/\s+/).filter(Boolean)
        if (parts.length > 0) {
            return parts.slice(0, 2).map((w) => [...w][0]).join('').toUpperCase()
        }
    }
    return ([...email][0] ?? '?').toUpperCase()
}

export default function AvatarMenu({ name, email, unread, settingsEntries }: AvatarMenuProps) {
    const t = useTranslations()
    const [open, setOpen] = useState(false)
    // 【设置那一区默认收着】菜单打开时先看到的仍然是那四条属于【你自己】的东西;
    // 设置是七条系统配置,展开是一次刻意的动作 —— 与手机抽屉里模块行的 +/− 同一个交互。
    const [settingsOpen, setSettingsOpen] = useState(false)
    const ref = useRef<HTMLDivElement>(null)
    // 关菜单时把设置那一区一并收起 —— 否则下次打开它记着上一次的展开状态,
    // 而那个状态与【这一次】要做什么没有关系。
    const closeMenu = useCallback(() => { setOpen(false); setSettingsOpen(false) }, [])
    useMenuDismiss(ref, closeMenu)

    const initials = initialsOf(name, email)
    // 【徽标口径与从前的铃铛逐字相同】>9 印 9+;null 印 !;0 不画。
    const badge = unread === null ? '!' : unread > 9 ? '9+' : String(unread)
    const showBadge = unread === null || unread > 0
    const unknown = unread === null

    const row =
        'flex items-center justify-between rounded px-3 py-1.5 text-sm text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)]'

    return (
        <div ref={ref} className="relative" data-nav="avatar-menu">
            <button
                type="button"
                aria-expanded={open}
                aria-haspopup="true"
                aria-label={t('nav.accountMenu')}
                title={t('nav.accountMenu')}
                onClick={() => (open ? closeMenu() : setOpen(true))}
                className={ROUND_BUTTON_CLASS}
            >
                {/* 【默认头像:淡灰的首字母】—— 上传是 UI-1c 的 Step 5,而 Tim 把它
                    单独切成了 v1.3.3(它是唯一要开破窗的一步:一个存储桶 + 一条策略)。
                    它必须看起来【是有意这样】,不是一张坏掉的图:所以是排版,
                    不是一个占位图形。 */}
                <span aria-hidden className="text-xs font-medium text-[color:var(--brand-muted-glass)]">
                    {initials}
                </span>
                {showBadge && (
                    <span
                        data-nav="unread-badge"
                        aria-hidden
                        className={
                            'absolute -top-1 -right-1 min-w-[1.1rem] rounded-full px-1 text-[10px] leading-4 text-white text-center ' +
                            (unknown ? 'bg-gray-500' : 'bg-red-600')
                        }
                    >
                        {badge}
                    </span>
                )}
            </button>

            {open && (
                <ScrollPanel
                    className={menuPanelClass('right', 'w-64')}
                    role="menu"
                    moreLabel={(n) => t('nav.menuMoreBelow', { n })}
                >
                    {/* ① 身份。**与其余条目分开** —— 它不是一个去处,是一句"你是谁"。 */}
                    <div
                        data-menu-row=""
                        data-nav="identity"
                        className="border-b border-[color:var(--brand-border)] px-3 pb-2 pt-1.5"
                    >
                        {/* 没有员工档案时【这一行不画】—— 见 initialsOf 的抬头。 */}
                        {name && (
                            <p className="truncate text-sm font-semibold text-[color:var(--brand-text)]">{name}</p>
                        )}
                        <p className="truncate text-xs text-[color:var(--brand-muted-glass)]">{email}</p>
                    </div>

                    {/* ② 通知 —— 未读数在行尾。**与徽标同一个 `unread`。** */}
                    <Link
                        href="/notifications"
                        data-menu-row=""
                        onClick={closeMenu}
                        className={row}
                        title={unknown ? t('notifications.bellError') : t('notifications.bellLabel')}
                    >
                        <span>{t('notifications.bell')}</span>
                        {showBadge && (
                            <span
                                data-nav="unread-row"
                                className={
                                    'ml-3 min-w-[1.25rem] rounded-full px-1.5 text-[11px] leading-5 text-white text-center ' +
                                    (unknown ? 'bg-gray-500' : 'bg-red-600')
                                }
                            >
                                {badge}
                            </span>
                        )}
                    </Link>

                    {/* ③ 我的评估。**不需要权限码** —— 这一页靠 performance_reviews 的
                        "select as reviewer" 策略与 current_user_employee(),一个 module.*
                        都不看(见 app/my-reviews/page.tsx 抬头)。没有员工档案的人打开它,
                        拿到的是那一页【自己】渲染的具名拒绝(ListPage 的 restricted 分支),
                        不是一张白页 —— 所以这里【不】替它判断,也【不】把它藏起来。 */}
                    <Link href="/my-reviews" data-menu-row="" onClick={closeMenu} className={row}>
                        <span>{t('nav.myReviews')}</span>
                    </Link>

                    {/* ④ 我的档案 */}
                    <Link href="/me" data-menu-row="" onClick={closeMenu} className={row}>
                        <span>{t('nav.me')}</span>
                    </Link>

                    {/* ⑤ 设置 —— 【七条】,不是一条跳转。理由整段写在 settingsEntries
                        那个 prop 的抬头(它修的是 UI-1a 留下的一处桌面回归:
                        五张子页在桌面上点不到)。
                        ★ 进不去的照画成「名字 · 受限」★ —— 与模块菜单、工具下拉
                          共用 MenuEntryRow,连那个看不见的机器标记一起。
                        ★ 一张都打不开的人看到的是【七行受限】★,不是一行受限,
                          也不是一处缺席:他因此知道设置底下有七件事,以及哪几件不归他。 */}
                    <div className="border-t border-[color:var(--brand-border)] pt-1 mt-1">
                        <button
                            type="button"
                            data-menu-row=""
                            data-nav="settings-toggle"
                            aria-expanded={settingsOpen}
                            onClick={() => setSettingsOpen(!settingsOpen)}
                            className={row + ' w-full text-left'}
                        >
                            <span>{t('nav.settings')}</span>
                            <span aria-hidden className="ml-3 text-[color:var(--brand-muted-glass)]">
                                {settingsOpen ? '−' : '+'}
                            </span>
                        </button>
                        {settingsOpen && (
                            <div data-nav="settings-submenu">
                                {settingsEntries.map((e) => (
                                    <MenuEntryRow key={e.href} entry={e} onNavigate={closeMenu} />
                                ))}
                            </div>
                        )}
                    </div>

                    {/* ⑥ 中/EN —— 滑块。机制没变,只有控件变了(见 LanguageSwitcher)。 */}
                    <div data-menu-row="" className="border-t border-[color:var(--brand-border)] pt-1 mt-1">
                        <LanguageSwitcher />
                    </div>

                    {/* ⑦ 登出 */}
                    <form action={logout} data-menu-row="">
                        <button type="submit" className={row + ' w-full text-left'}>
                            <span>{t('nav.logout')}</span>
                        </button>
                    </form>
                </ScrollPanel>
            )}
        </div>
    )
}
