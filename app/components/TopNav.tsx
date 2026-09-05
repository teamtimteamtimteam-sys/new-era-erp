// app/components/TopNav.tsx
// 【应用外壳的服务端一半】—— 判权限,然后把结果交给客户端组件画。
//
// ════════════════════════════════════════════════════════════════════════════
// UI-1a(2026-09-05)· 顶栏从【两行】合成【一行】
// ════════════════════════════════════════════════════════════════════════════
// 【它此前是两行,而委托书没说这件事】上面一行是字标 + 邮箱 + 铃铛 + 我的评估 +
// 我的档案 + 语言 + 登出;下面一行是 <ModuleBar>。本刀把它们合成一行:
//     字标 · 七个模块 · 弹性空白 · 搜索外壳 · 工具按钮 · 头像按钮
//
// 【右侧那六样东西去哪了】全部收进头像下拉(app/components/nav/AvatarMenu.tsx):
//   邮箱 → 菜单第一项的身份块;铃铛 → 「通知」那一行 + 头像上的徽标;
//   我的评估 / 我的档案 / 语言 / 登出 → 各自一行。
//   ★ 顺带修好一个 CONV-6 记过的缺口 ★:/my-reviews 从前是 `lg:inline`,
//     而抽屉是 `sm:hidden` —— **640px ≤ 宽 < 1024px 这一段里它两头都够不着**。
//     菜单不按宽度藏条目,那个缺口因此【结构性地】没了,不是被补上了。
//
// 【NotificationBell.tsx 删了,它的查询搬进 lib/notifications.ts】理由是委托书那条
// 「One source, two renderings — do not compute it twice」:未读数要出现在头像徽标
// 与菜单行尾两个地方,而让两处各渲染一次组件就是查两次。现在顶栏调一次,传下去。
//
// ════════════════════════════════════════════════════════════════════════════
// IA-BUILD-1(2026-09-02):九个一级模块 + 二级(财务三级)+ 个人 dock
// ════════════════════════════════════════════════════════════════════════════
// 【这里【不过滤】】(Tim 的 D5 / NAV-REG-1 R4):拿到的是【全部】九个模块与它们
// 名下的全部二级条目,每个带 allowed;进不去的由 ModuleBar 画成一条【具名的限制】
// 而不是消失。★ UI-1a ⑦(b) 之后那条限制不再写「· 受限」后缀,但它仍然是具名的:
//   灰字 + title 提示 + data-module-restricted 记号,点开是逐条写着「· 受限」的二级。
//   理由与实测的宽度写在 ModuleBar 那一段。
//
// ★【七与九的区别【只在渲染】】★ 这里仍然取九条,过滤发生在 ModuleBar 里:
//   桌面那一行与手机抽屉都按 BAR_MODULE_IDS 画七条,而工具与设置各自成为
//   一张下拉(桌面)或抽屉里一个具名的区(手机)—— UI-1c ②。
//   **不要在这里过滤** —— 那会让 /tools/* 与 /settings/* 的面包屑与活动模块判定
//   一起失效,理由整段写在 BAR_MODULE_IDS 的抬头。
//
// 【一级的可进性是【推导】的,不是读一个字段】见 lib/moduleAccess.ts:
// 一个模块进得去 ⟺ 它名下有任何一条二级进得去。**M6 因此自动成立** ——
// 只有盘点权限的人进得去库存,因为盘点就在库存名下。
//
// 【dock 不在这个文件里】CHART-0 ④ 把它搬到了 app/components/nav/DockRail.tsx。
import Link from 'next/link'
import { cookies } from 'next/headers'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import ModuleBar from './nav/ModuleBar'
import ToolsMenu from './nav/ToolsMenu'
import AvatarMenu from './nav/AvatarMenu'
import SearchShell from './nav/SearchShell'
import { getModuleAccess } from '@/lib/moduleAccess'
import { getUnreadCount } from '@/lib/notifications'
import { SETTINGS_MODULE_ID, TOOLS_MODULE_ID } from '@/lib/modules'
import { AVATAR_BUCKET, AVATAR_VERSION_COOKIE, avatarObjectName } from '@/lib/avatar'
import type { NavModule } from './nav/types'

/**
 * 字标。
 *
 * ★【accessible name 靠 <img alt>,【不是】靠 SVG 里那个 aria-label】★
 *   evoltrya-os-black.svg 自己带着 role="img" aria-label="EVoltrya OS",而
 *   **通过 <img src> 引用时,文件内部的那些属性一律不暴露给辅助技术** ——
 *   浏览器把它当一张图片,可访问名只能来自 alt。所以 alt 必须写在这里。
 *   (内联 <svg> 才会用到文件里那个 aria-label,而内联要把 27KB 塞进每一页的 HTML。)
 *
 * ★【高度 25.5px 是量出来的,不是挑出来的】★ 判据是 Tim 的裁定:**与它替换掉的
 *   那行字【顶齐大写高度】**。实测(UI-1a 探针):字标 SVG 里那个大写 E 占
 *   viewBox 高度的 50.43%,而原来那行 `font-bold text-lg` 的大写高度是 12.88px。
 *   12.88 / 0.5043 = 25.5px,于是宽度按 4.524:1 落在 115.5px。
 *   ★ 它比原来那行字的行盒(28px)【更矮】,所以顶栏的高度不会变 —— 这是委托书
 *     点名要保住的一条。
 *
 * ★【黑白是裁定,不是省事】★ Tim 排除了彩色字标:球体的细线在 20–24px 上会糊成
 *   一团,而一个彩色标记会与右边两个圆按钮抢眼。**不许上色,不许加 hover 变色。**
 */
function Wordmark() {
    return (
        // eslint-disable-next-line @next/next/no-img-element
        <img
            src="/brand/evoltrya-os-black.svg"
            alt="EVoltrya OS"
            width={116}
            height={26}
            className="h-[25.5px] w-auto"
        />
    )
}

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
            <header className="sticky top-0 z-50 border-b border-[color:var(--brand-border)]" data-auth-indeterminate="1">
                {/* 玻璃画在子元素上,不画在 <header> 上 —— 见 globals.css 的 .nav-glass-underlay。 */}
                <div className="nav-glass-underlay" aria-hidden="true" />
                <div className="px-4 sm:px-6 py-2.5 flex items-center gap-4">
                    <Link href="/" className="shrink-0">
                        <Wordmark />
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

    // ── 工具下拉的五行。**同一份注册表,同一个 allowed** ──────────────────
    // 五条:任务 · 日历 · 单位换算 · 提醒 · 定价(工具的三级分组今天没有住户,
    // 所以它本来就画成平铺的五条 —— 见 lib/modules.ts 的 TOOLS_GROUPS 抬头)。
    const toolsEntries =
        modules.find((m) => m.id === TOOLS_MODULE_ID)?.entries ?? []

    // ── 设置下拉的【七行】。**同一份注册表,同一个 allowed** ─────────────
    //
    // ★★【UI-1c ①:这里此前算的是 `settingsHref` —— 一条跳转,不是一张菜单】★★
    // 【为什么换】UI-1a 把 settings 移出 BAR_MODULE_IDS 之后,桌面上再没有任何
    //   地方列出那七张子页,于是整个桌面对设置只剩那一条跳转。逐条 grep 过
    //   app/ 里全部指向 /settings/* 的 href:**roles / reference / approvals /
    //   deleted / import 五张在桌面上点不到**,而受影响的是 admin 与 cco 两个人。
    //   完整推理与 NAV-CLEANUP-1 判据的关系写在 AvatarMenu 的 settingsEntries 抬头。
    // ★【那个"算第一张打得开的"于是【整段退休】】★ 它是为一条跳转服务的;
    //   给出全部七条之后没有任何东西需要挑一张 —— 一个没有读者的机制不留着。
    //   Choo Er 的那条永远拒绝的链接也随之不存在:她看到的是七行,其中六行写着
    //   「· 受限」,那正是 D5 要的样子。
    const settingsEntries =
        modules.find((m) => m.id === SETTINGS_MODULE_ID)?.entries ?? []

    // ── 身份 ────────────────────────────────────────────────────────────────
    // 【没有员工档案的账号 name 是 null】—— 那不是错误,是"HR 还没建档"。
    // AvatarMenu 于是【不画名字那一行】,只画邮箱;头像取邮箱首字母。
    // 编一个占位名就是把一处缺席画成一个答案(Tim 的裁定,UI-1a Q7)。
    let name: string | null = null
    try {
        const { data } = await supabase.from('my_profile').select('preferred_name, legal_name').limit(1)
        const p = data?.[0]
        name = (p?.preferred_name || p?.legal_name) ?? null
    } catch {
        name = null
    }

    // ── 头像(UI-1d)────────────────────────────────────────────────────────
    //
    // ★★【这里【不】问"这个人有没有头像"】★★
    //   getPublicUrl() 是一个【纯字符串拼接】,不发请求 —— 它只是把桶名与对象名
    //   拼成公开地址。对象在不在,由浏览器取图那一下自己回答:取到就画,
    //   404 就由 AvatarImage 的 onError 回落成首字母。
    //
    //   反过来的写法(服务端先 list/HEAD 一下再决定画什么)会给【每一页、
    //   每一个人、每一次加载】加一趟往返 —— 为一件装饰品。而且它并不更可靠:
    //   问完之后到浏览器真正取图之间,对象照样可以消失,回落那条路无论如何都得在。
    //   **既然回落必须存在,那次询问就没有读者。**
    //
    // 【?v= 那个尾巴只挂给刚换过头像的那个浏览器】cookie 由 uploadAvatar /
    //   removeAvatar 写下,活 120 秒(> 对象 60 秒的 max-age)然后自己消失。
    //   没有它时大家取的是同一个规范地址,缓存正常工作;有它时本人立刻看到新图 ——
    //   而"立刻"正是换了头像的人唯一在意的那一秒。完整理由在 lib/avatar.ts。
    const avatarVersion = (await cookies()).get(AVATAR_VERSION_COOKIE)?.value ?? null
    const avatarBase = supabase.storage
        .from(AVATAR_BUCKET)
        .getPublicUrl(avatarObjectName(user.id)).data.publicUrl
    const avatarUrl = avatarVersion
        ? `${avatarBase}?v=${encodeURIComponent(avatarVersion)}`
        : avatarBase

    // ★【未读数在这里【只算一次】】★ 头像徽标与菜单行尾画的是同一个值。
    // 【user.id 传进去,不让它自己再问一遍 auth】理由写在 getUnreadCount 的抬头:
    // 顶栏这一半已经把「判断不出 / 确立的否定 / 已登录」三态分好了,
    // 再问一遍就得把那套判断抄第二份。
    const unread = await getUnreadCount(user.id)

    return (
        <>
            {/* ★ R2:磨砂【只给浮动层】—— 顶栏、dock、下拉、抽屉。表格永远不磨砂。
                理由与实测的对比度写在 app/globals.css 的 .nav-glass 抬头。

                ★【CHART-0 ①:顶栏自己【不】带 .nav-glass,玻璃由子元素画】★
                带 backdrop-filter 的元素会做两件顺带的事,而这两件都咬到了这里:
                  ① 它成为一个 Backdrop Root —— 挂在它底下的下拉/抽屉,
                     backdrop-filter 的滤镜源就只剩顶栏内部,于是【一帧都没生效】;
                  ② 它成为 fixed 后代的【包含块】—— 手机抽屉的 `fixed inset-0`
                     于是对齐顶栏而不是视口,实测在 390×844 上只有 94px 高。
                把玻璃挪到一个 absolute inset-0 的子元素上,两件事同时消失,
                而顶栏看上去逐像素不变。实测见 globals.css 的那一段。 */}
            <header className="sticky top-0 z-50 border-b border-[color:var(--brand-border)]">
                <div className="nav-glass-underlay" aria-hidden="true" />
                {/* ★【一行。实测放得下,所以搜索框【不】折叠】★
                    UI-1a 探针,六个角色 × 1280/1440(worst case = warehouse/operations):
                      字标 115.5 + 七条模块 528.7 + 搜索 200 + 两个圆按钮 32×2
                      + 内距与间隙 → 1280 上余 276px,1440 上余 436px。
                    委托书为"放不下"准备了一个折叠成放大镜的形态;**实测放得下,
                    所以那个形态没有造** —— 一个没有触发条件的机制比没有更糟
                    (Tim 的裁定)。宽度表在报告里,将来加第八个模块时照它重算。 */}
                <div className="px-4 sm:px-6 py-2.5 flex items-center gap-2 sm:gap-3">
                    <Link href="/" className="shrink-0" data-nav="wordmark">
                        <Wordmark />
                    </Link>

                    {/* 桌面:七条模块;手机:一个菜单按钮 + 一张全高抽屉
                        (七条模块 + 工具区 + 设置区 —— UI-1c ②)。 */}
                    <ModuleBar modules={modules} />

                    {/* 【弹性空白在这里】ml-auto 把右边这一组推到底,
                        而模块条与它之间那段空白就是"可伸缩的那一段"。 */}
                    <div className="ml-auto flex shrink-0 items-center gap-2">
                        <SearchShell />
                        {/* 工具下拉是桌面的门;**手机走抽屉里的「工具」区**。
                            在这里给手机再造一个工具下拉,就是造第二扇通向同一处的门。 */}
                        <div className="hidden sm:block">
                            <ToolsMenu entries={toolsEntries} />
                        </div>
                        {/* 头像菜单【所有宽度都在】—— 它接住了从前平铺在顶栏上的
                            通知、语言与登出,手机上那三样从前也是可见的。 */}
                        <AvatarMenu
                            name={name}
                            email={user.email ?? ''}
                            unread={unread}
                            settingsEntries={settingsEntries}
                            avatarUrl={avatarUrl}
                        />
                    </div>
                </div>
            </header>
        </>
    )
}
