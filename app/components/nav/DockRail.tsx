// app/components/nav/DockRail.tsx
// 【dock 的服务端一半】—— 判会话、取权限、取存下来的那一行,然后交给 Dock 画。
//
// ★【为什么它从 TopNav 里搬了出来】★(CHART-0 ④)
// 桌面上 dock 现在是【内容左边的一条竖栏】,也就是说它必须与页面主体是
// 同一个 flex 行里的两个兄弟。挂在 TopNav 里做不到这件事 —— 那里它只能
// 排在顶栏下面,而"排在顶栏下面"正是 Tim 要修掉的那个观感(读起来像第三层菜单)。
// 所以取数搬到这里,布局在 app/layout.tsx 里拼。
//
// 【多的这一次查询是 0 次】getMyPermissions 有 React cache,顶栏已经问过;
// readDock 本来就只有一处调用者,只是从 TopNav 换成了这里。
import { createClient } from '@/lib/supabase/server'
import { getMyPermissions } from '@/lib/permissions'
import { resolveDock } from '@/lib/dock'
import { readDock } from './dockActions'
import Dock from './Dock'
import type { DockEntry } from './types'

export default async function DockRail() {
    // ★【error 必须接住,而且必须【分类】—— 哪怕两条分支画的东西一样】★
    // 判据与 lib/supabase/middleware.ts 的抬头逐字同源(那里有实测的七情形表),
    // 与 TopNav 用的是同一套:
    //     AuthRetryableFetchError → **判断不出**
    //     其余 error / 无 user     → 确立的否定
    //
    // 【两条分支都返回 null,而那【不是】把它们混为一谈】
    // 认证判断不出的时候,顶栏【已经】画了一条说明用的横幅(TopNav 那段)。
    // 这里再画一条"快捷栏读不出来"只会给同一件事添第二个说法,而"同一个意思
    // 的第二套说法就是下一次漂移的种子"是这个仓库写在 ModuleBar 抬头上的规矩。
    // 所以这里的正确行为是【闭嘴,让顶栏去说】—— 但闭嘴必须是【判断之后】的
    // 选择,不能是【丢掉判断】的结果。差别在于:哪天顶栏那条横幅改了措辞或
    // 挪了位置,这里有一个具名的分支等着被改,而不是一个 catch {} 里的沉默。
    const supabase = await createClient()
    let user = null
    let authError: unknown = null
    try {
        const res = await supabase.auth.getUser()
        user = res.data.user
        authError = res.error
    } catch (e) {
        authError = e
    }

    // 【判断不出】—— 顶栏的横幅负责说话,这里不画第二条。
    if (!user && (authError as { name?: string } | null)?.name === 'AuthRetryableFetchError') {
        return null
    }
    // 【确立的否定】—— 本来就没有 dock 可言(登录页连外壳都不套)。
    if (!user) return null

    const perms = await getMyPermissions()
    const stored = await readDock()
    // 【三态在服务端就算完】见 lib/dock.ts 的 resolveDock:
    // hrefs 为 null = 从没动过(画默认)· 空数组 = 本人清空了 · 非空 = 画这些。
    const dock = resolveDock(stored.hrefs, perms)
    const items: DockEntry[] = dock.items.map((i) => ({ href: i.href, key: i.navKey, state: i.state }))

    return <Dock items={items} isDefault={dock.isDefault} collapsed={stored.collapsed} />
}
