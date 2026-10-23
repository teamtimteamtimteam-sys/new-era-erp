// lib/notifications.ts
// ════════════════════════════════════════════════════════════════════════════
// UI-1a ⑤:未读数【只算一次】,画两次
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么它从组件里搬出来了】UI-1a 之前,这段查询住在 app/components/NotificationBell.tsx
// 里,而那个组件自己既取数又渲染。本刀要求同一个数出现在【两个地方】——
// 头像按钮右上角的徽标,与头像菜单里「通知」那一行的行尾。
// **让两处各调一次组件,就是同一个数被查两次** —— 两次查询之间通知表可以变,
// 于是徽标写着 3、行尾写着 2,而屏幕上没有任何东西说这两个数不是同一个数。
// 委托书那一条写的是「One source, two renderings — do not compute it twice」。
// 所以取数在这里,渲染在别处;顶栏调它【一次】,把结果传下去。
//
// ★【三态原样保住,一个字没改】★(NTF-1 定的,理由值得再写一遍)
//   null 的意思是【不知道】,0 的意思是【没有通知】。**这两件事在屏幕上必须
//   长得不一样** —— 否则一次权限错误会被读成一个干净的收件箱。
//   这正是 lib/permissions.ts 存在的全部理由,也是 FIX-2a 整刀的题目:
//   **一次缺席不许被渲染成一个答案。**
//   所以这里 catch 之后写的是 null,不是 0,而调用方必须把 null 画成"!"而不是"0"。
import { createClient } from '@/lib/supabase/server'
import { mustCount } from '@/lib/db-helpers'

// ★ TABLE-EXPORT-2b-2(Tim 2026-10-23,TABLE-EXPORT-2b Q6 · 2b-2 Step 0 Q3):未读数是一个【精确】的数。
//   从前顶栏只看最新的 10 条(BELL_LIMIT),/notifications 只看最新的 50 条 —— 两处各数各的截断,
//   于是最新的 10 条都读过、更早的还有 3 条没读时,徽标说 0、那一页说 3(或者都说少了)。
//   现在两处读同一个函数、同一个数:未读 = 【看得见的通知】的条数 − 【我读过、而且仍看得见的】那几条。
//   两次 count(exact, head),不搬任何一行:
//     · notifications 的读策略按 subject_type 问权限码 —— count 数的就是"这个人看得见的";
//     · notification_reads 只读得到自己的行(select own),内嵌 `notifications!inner` 把"读过、但已经看不见"的那几条挡在外面
//       (否则一条看不见了的已读会被减掉,未读数偏小)。外键 notification_reads.notification_id → notifications(id)。
//   徽标仍然只印到「9+」(unreadBadge)—— 变的是那个数准了,不是印法。

type Client = Awaited<ReturnType<typeof createClient>>

/** 精确的未读数。**读失败就抛** —— 调用方决定失败怎么画(页面:失败;顶栏:null →「!」)。 */
export async function countUnread(supabase: Client, userId: string): Promise<number> {
    const [visibleRes, readRes] = await Promise.all([
        supabase.from('notifications').select('id', { count: 'exact', head: true }),
        supabase.from('notification_reads').select('notification_id, notifications!inner ( id )', { count: 'exact', head: true })
            .eq('user_id', userId),
    ])
    const visible = mustCount(visibleRes, 'notifications count')
    const read = mustCount(readRes, 'notification_reads count')
    return Math.max(0, visible - read)
}

/**
 * 这个人有多少条未读。
 *
 * ★【它【不】自己调 auth.getUser() —— 调用方把 id 传进来】★
 * 【为什么这一点要写下来】第一版是自己调 getUser() 的(从 NotificationBell 原样
 * 搬过来),而 `scripts/check-auth-error-swallowing.mjs` 当场把它拦下了:
 * 那种写法**丢掉 error**,于是「认证够不着」与「这个人没登录」走同一条分支 ——
 * 正是本仓库那条规矩(参考实现在 lib/supabase/middleware.ts 抬头)。
 *
 * **而正确的修法不是把 error 接住,是根本不该问第二遍。** 顶栏在它自己那一半
 * 已经拿到了 user,并且**已经把三态分好了**(判断不出 → 画一条会说话的导航条;
 * 确立的否定 → 不画)。这里再问一次 getUser(),是把一个已经答过的问题
 * 重新问一遍,还得把那套三态判断抄第二份 —— **两份判断迟早各错一次。**
 * 顺带省掉每一页一次 auth 往返。
 *
 * @param userId 顶栏已经确认过的那个人。
 * @returns 数字 = 未读条数(0 表示确实没有);**null = 没问出来**,不是 0。
 */
export async function getUnreadCount(userId: string): Promise<number | null> {
    const supabase = await createClient()

    // 【读失败绝不冒出去】顶栏在每一页上,一次读不到通知不该把整站变成错误页。
    // 但它也【绝不退化成 0】—— 见抬头。
    try {
        return await countUnread(supabase, userId)
    } catch {
        return null // ← 【不知道】,与 0 是两回事
    }
}

/** 徽标上印的那个串。**null 印「!」,不印「0」** —— 见抬头的三态。 */
export function unreadBadge(unread: number | null): string {
    return unread === null ? '!' : unread > 9 ? '9+' : String(unread)
}

/** 徽标画不画。0 不画(没有通知就没有红点),null 要画(不知道也得说出来)。 */
export function showUnreadBadge(unread: number | null): boolean {
    return unread === null || unread > 0
}
