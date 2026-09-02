'use server'

// app/components/nav/dockActions.ts
// 【dock 的写侧】—— 三个动作:加一项、去一项、清空。
//
// ★【dock 只能指向注册表里已有的地址】★(Tim 的 4d:它是快捷层,不是第二套导航)
// 每一个进来的地址都对着 FUNCTIONS 核一遍。**核不上就拒绝** —— 一旦 dock 里能
// 出现顶栏到不了的东西,"这个功能在哪"就有了两个答案。
//
// ★【这里【不】判权限,而那是【故意】的】★
// 一条 dock 项存的是【地址】,不是"你有权进"。可见性【每次渲染重新问注册表】
// (见 Dock.tsx 与 lib/dock.ts)。为什么不在写的时候把没权限的挡掉:
// 一个人今天进得去、明天权限被收走,那一项【必须变成「受限」而不是消失】——
// 消失就分不清"我从来没加过"和"我被收权了"。而如果写侧按权限挡,那就等于宣称
// "存进来的都是能进的",于是渲染侧会有人觉得不必再判 —— 那才是危险的地方。
//
// ★【边界在数据库】★ user_dock 四条 RLS 策略全部锁在 user_id = auth.uid():
// 这些动作改不了别人的 dock,就算这个文件写错了也改不了。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { FUNCTIONS } from '@/lib/modules'
import { DOCK_MAX } from '@/lib/dock'


/**
 * 【会话必须问得出答案,问不出就抛】
 *
 * 判据与 lib/supabase/middleware.ts 的抬头逐字同源(那里有实测的七情形表):
 *   AuthRetryableFetchError → **判断不出**。不许当成"没登录"——
 *       那会让一次网络抖动被读成"这个人没有 dock",于是他排好的一条快捷栏
 *       被默认值悄悄顶掉(读侧),或者一次保存静默失败(写侧)。
 *   其余 error / 无 user   → 确立的否定,按没有会话处理。
 *
 * 【为什么不像 TopNav 那样画一条"说话的"横幅】那是【渲染】路径,它必须给出
 * 一屏东西;这里是【取数与动作】路径,它的正确行为是把错误抛给上面那一层
 * (Next 的错误边界 / 动作的 catch),与 lib/permissions.ts 的 getMyPermissions
 * 同一条:失败就抛,真的没有才是空。
 */
async function requireSessionUserId(): Promise<string> {
    const supabase = await createClient()
    const { data, error } = await supabase.auth.getUser()
    if (error?.name === 'AuthRetryableFetchError') {
        throw new Error(`dock:认证判断不出(${error.name})—— 不按"没有 dock"处理。`)
    }
    if (error || !data.user) throw new Error('dock:没有会话')
    return data.user.id
}

/**
 * 拿这个人存下来的 dock:**内容 + 收起与否**,一次查询两样东西。
 *
 * ★【hrefs 的三态现在【只看这一列】,不再看"行在不在"】★(CHART-0 ④)
 *   null = 从来没动过 · [] = 他清空了 · 非空 = 就这些
 * 迁移把 hrefs 改成了可空并去掉了默认值,理由整段写在
 * db/migrations/2026-09-02-chart0-the-dock-can-be-put-away-….sql:
 * 只要为了记一个 collapsed 就得建行,而那一行原本会拿到 '{}' ——
 * 于是"把 dock 收起来"会被读成"把 dock 清空了",静默吃掉这个人排的那几项。
 *
 * 【collapsed 没有第三态,所以它不可空】没有行 = 没收起来,与 false 是同一件事;
 * 而 hrefs 的"没动过"与"清空了"【不是】同一件事 —— 这正是两列形状不同的理由。
 */
export async function readDock(): Promise<{ hrefs: string[] | null; collapsed: boolean }> {
    const supabase = await createClient()
    const userId = await requireSessionUserId()
    const { data, error } = await supabase
        .from('user_dock')
        .select('hrefs, collapsed')
        .eq('user_id', userId)
        .maybeSingle()
    // 【查询失败不许读成"没有 dock"】—— 与 lib/permissions.ts 抬头同一条:
    // 一次瞬时故障会被画成"这个人从来没动过 dock",于是他自己排好的一条
    // 快捷栏被默认值悄悄顶掉。抛出去,让错误边界说话。
    if (error) throw new Error(`查询失败(user_dock): ${error.code ?? ''} ${error.message}`.trim())
    return {
        hrefs: (data?.hrefs as string[] | null | undefined) ?? null,
        collapsed: Boolean(data?.collapsed),
    }
}

/**
 * 落盘 dock 的【内容】。先读再写(不是原子的,但一条 dock 只有它的主人在改)。
 *
 * ★【只写 hrefs,不写 collapsed】★ upsert 的 ON CONFLICT 只更新这里列出的列,
 * 所以改内容不会顺手把这个人收起/展开的选择重置掉 —— 两件事正交。
 * 反过来 setDockCollapsed 也只写 collapsed,不碰 hrefs。
 */
async function writeDock(hrefs: string[]): Promise<void> {
    const supabase = await createClient()
    const userId = await requireSessionUserId()
    const { error } = await supabase
        .from('user_dock')
        .upsert({ user_id: userId, hrefs, updated_at: new Date().toISOString() }, { onConflict: 'user_id' })
    if (error) throw new Error(`写入失败(user_dock): ${error.code ?? ''} ${error.message}`.trim())
    // 外壳在每一页上,所以整棵树都要重画。
    revalidatePath('/', 'layout')
}

/**
 * ★【收起 / 展开,而它【跟着人走】】★(CHART-0 ④,Tim 的 ★ 条)
 * 存进库里而不是 cookie/localStorage,理由与 dock 的内容逐字相同:
 * 一个人在手机上和在桌面上是同一个人,他把 dock 收起来是【他的】选择,
 * 不是【这台机器的】选择。
 *
 * 【新建的那一行 hrefs 会是 NULL,而那正是要的】迁移去掉了 hrefs 的
 * NOT NULL 与 DEFAULT,所以一个从没动过内容、只是把 dock 收起来的人,
 * 他的 hrefs 仍然是 NULL = "从来没动过" → 照旧画按权限的默认。
 * 迁移之前这里会写出 '{}' = "他清空了" —— 那是一个会吃掉 dock 的缺陷。
 */
export async function setDockCollapsed(collapsed: boolean): Promise<void> {
    const supabase = await createClient()
    const userId = await requireSessionUserId()
    const { error } = await supabase
        .from('user_dock')
        .upsert({ user_id: userId, collapsed, updated_at: new Date().toISOString() }, { onConflict: 'user_id' })
    if (error) throw new Error(`写入失败(user_dock.collapsed): ${error.code ?? ''} ${error.message}`.trim())
    revalidatePath('/', 'layout')
}

export async function addToDock(href: string): Promise<void> {
    // 【核对注册表】—— 4d 的那道门。
    if (!FUNCTIONS.some((f) => f.href === href)) {
        throw new Error(`dock:${href} 不在注册表里 —— dock 是快捷层,不是第二套导航。`)
    }
    const { defaultDock } = await import('@/lib/dock')
    const { getMyPermissions } = await import('@/lib/permissions')
    const current = (await readDock()).hrefs ?? defaultDock(await getMyPermissions())
    if (current.includes(href)) return
    if (current.length >= DOCK_MAX) {
        throw new Error(`dock:最多 ${DOCK_MAX} 项 —— 先去掉一项。`)
    }
    await writeDock([...current, href])
}

export async function removeFromDock(href: string): Promise<void> {
    const { defaultDock } = await import('@/lib/dock')
    const { getMyPermissions } = await import('@/lib/permissions')
    // 【从默认里去掉一项,等于从此有了自己的一份】—— 存下来的那一刻,
    // "从来没动过"就变成了"这是我排的",默认值不会再回来盖住它。
    const current = (await readDock()).hrefs ?? defaultDock(await getMyPermissions())
    await writeDock(current.filter((h) => h !== href))
}

/** 清空。**它与"从来没动过"不是一回事** —— 落一行空数组,默认值不会补回来。 */
export async function clearDock(): Promise<void> {
    await writeDock([])
}

/**
 * 恢复成默认:把 hrefs 置回 NULL,于是又回到"从来没动过"那一态。
 *
 * ★【此前是 DELETE 整行,而那会连带抹掉 collapsed】★(CHART-0 ④)
 * "把 dock 的内容恢复默认"与"我不想看见这条栏"是两件事。删整行会让前者
 * 顺手撤销后者 —— 一个人点了「恢复默认」,结果收起来的 dock 自己弹了出来,
 * 而屏幕上没有任何东西说过会这样。改成只清 hrefs,collapsed 原样留着。
 */
export async function resetDock(): Promise<void> {
    const supabase = await createClient()
    const userId = await requireSessionUserId()
    const { error } = await supabase
        .from('user_dock')
        .update({ hrefs: null, updated_at: new Date().toISOString() })
        .eq('user_id', userId)
    if (error) throw new Error(`重置失败(user_dock): ${error.code ?? ''} ${error.message}`.trim())
    revalidatePath('/', 'layout')
}
