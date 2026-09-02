// app/components/TopNav.tsx
// 【应用外壳的服务端一半】—— 判权限、取 dock,然后把结果交给三个客户端组件画。
//
// ════════════════════════════════════════════════════════════════════════════
// IA-BUILD-1(2026-09-02):九个一级模块 + 二级(财务三级)+ 个人 dock
// ════════════════════════════════════════════════════════════════════════════
// 【这里【不过滤】】(Tim 的 D5 / NAV-REG-1 R4):拿到的是【全部】九个模块与它们
// 名下的全部二级条目,每个带 allowed;进不去的由 ModuleBar 画成「· 受限」而不是消失。
//
// 【一级的可进性是【推导】的,不是读一个字段】见 lib/moduleAccess.ts:
// 一个模块进得去 ⟺ 它名下有任何一条二级进得去。**M6 因此自动成立** ——
// 只有盘点权限的人进得去库存,因为盘点就在库存名下。
//
// 【dock 的三态在服务端就算完】见 lib/dock.ts 的 resolveDock:
// 没有行 = 从没动过(画默认)· 空数组 = 本人清空了 · 非空 = 画这些。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { logout } from '@/app/logout/actions'
import { getTranslations } from '@/lib/i18n/server'
import LanguageSwitcher from './LanguageSwitcher'
import NotificationBell from './NotificationBell'
import ModuleBar from './nav/ModuleBar'
import Dock from './nav/Dock'
import { getModuleAccess } from '@/lib/moduleAccess'
import { getMyPermissions } from '@/lib/permissions'
import { resolveDock } from '@/lib/dock'
import { readDock } from './nav/dockActions'
import type { NavModule, DockEntry } from './nav/types'

export default async function TopNav() {
    const supabase = await createClient()
    // 【error 必须接住 —— 一条空着的导航条是同一句谎的另一件衣服】(SESSION-1,2026-08-23)
    //
    // 此前这里是 `const { data: { user } } = await getUser()` 然后 `if (!user) return null`。
    // `getUser()` 失败时 user 也是 null,于是**认证够不着的那一刻,整条导航条凭空消失**,
    // 而页面主体照常渲染 —— 屏幕上"这个系统没有你能用的东西"与"刚才没问到答案"
    // 长得一模一样。判据与 lib/supabase/middleware.ts 逐字同源:
    // `AuthRetryableFetchError` = 判断不出;其余 = 确立的否定。
    let user = null
    let authError: unknown = null
    try {
        const res = await supabase.auth.getUser()
        user = res.data.user
        authError = res.error
    } catch (e) {
        authError = e
    }

    const t = await getTranslations()

    // 【判断不出】—— 画一条【说话的】导航条,不是不画。
    if (!user && (authError as { name?: string } | null)?.name === 'AuthRetryableFetchError') {
        return (
            <header className="nav-glass sticky top-0 z-50 border-b border-[color:var(--brand-border)]" data-auth-indeterminate="1">
                <div className="px-6 py-3 flex items-center gap-4">
                    <Link href="/" className="font-bold text-lg text-[color:var(--brand-text)]">
                        EVoltrya OS
                    </Link>
                    <span className="text-sm bg-amber-50 border border-amber-300 text-amber-900 px-2 py-1 rounded">
                        <span className="font-medium">{t('common.navUnavailable')}</span>{' '}
                        <span className="hidden sm:inline">{t('common.navUnavailableHint')}</span>
                    </span>
                </div>
            </header>
        )
    }

    // 【确立的否定】—— 不画导航条。登录页本来就没有导航,其余路径中间件早就重定向掉了。
    if (!user) return null

    const perms = await getMyPermissions()
    const access = await getModuleAccess()
    const modules: NavModule[] = access.map(({ module, allowed, entries, groups }) => ({
        id: module.id,
        key: module.navKey,
        allowed,
        entries: entries.map(({ fn, allowed: a }) => ({ href: fn.href, key: fn.navKey, allowed: a })),
        groups: groups.map((g) => ({
            key: g.key,
            entries: g.entries.map(({ fn, allowed: a }) => ({ href: fn.href, key: fn.navKey, allowed: a })),
        })),
    }))

    const dock = resolveDock(await readDock(), perms)
    const dockItems: DockEntry[] = dock.items.map((i) => ({ href: i.href, key: i.navKey, state: i.state }))

    return (
        <>
            {/* ★ R2:磨砂【只给浮动层】—— 顶栏、dock、下拉、抽屉。表格永远不磨砂。
                理由与实测的对比度写在 app/globals.css 的 .nav-glass 抬头。 */}
            <header className="nav-glass sticky top-0 z-50 border-b border-[color:var(--brand-border)]">
                {/* 【390px 上这一行必须放得下】实测过一次溢出:右侧那一组宽 265.75px,
                    右边缘落在 396.45 —— 视口只有 390,于是【整个文档】横向滚动 6.45px。
                    修法不是把字缩小了事,是把手机上不必须的那几项挪进抽屉:
                    /my-reviews 与 /me 在 <sm 时移到抽屉底部的「关于你」一段
                    (**它们没有消失,只是换了地方** —— 4d 那条对外壳自己也成立)。 */}
                <div className="px-4 sm:px-6 py-2.5 flex items-center justify-between gap-2 sm:gap-3">
                    <Link href="/" className="font-bold text-base sm:text-lg text-[color:var(--brand-text)] shrink-0">
                        EVoltrya OS
                    </Link>
                    <div className="flex min-w-0 items-center gap-2 sm:gap-3">
                        <span className="text-sm text-[color:var(--brand-muted-glass)] hidden md:inline">
                            {user.email}
                        </span>
                        {/* NTF-1:铃铛在【关于你】这一区(语言、退出),不在模块条里 ——
                            收件箱不是一个模块,它是这个人自己的东西。
                            【U4–U7 留在模块之外】/me、/my-reviews、通知、登录族与工作台首页
                            都不进九个模块 —— 勘察 C10 的理由,Tim 已确认照办。 */}
                        <NotificationBell />
                        <Link href="/my-reviews" className="hidden text-sm text-[color:var(--brand-muted-glass)] hover:text-[color:var(--brand-text)] lg:inline">
                            {t('nav.myReviews')}
                        </Link>
                        <Link href="/me" className="hidden text-sm text-[color:var(--brand-muted-glass)] hover:text-[color:var(--brand-text)] sm:inline">
                            {t('nav.me')}
                        </Link>
                        <LanguageSwitcher />
                        <form action={logout}>
                            <button
                                type="submit"
                                className="text-sm border border-[color:var(--brand-border)] px-3 py-1 rounded hover:bg-[color:var(--brand-accent)] text-[color:var(--brand-text)]"
                            >
                                {t('nav.logout')}
                            </button>
                        </form>
                    </div>
                </div>
                <ModuleBar modules={modules} />
            </header>
            <Dock items={dockItems} isDefault={dock.isDefault} />
        </>
    )
}
