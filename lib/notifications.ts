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
import { mustRows } from '@/lib/db-helpers'

// 【有界】只看最新的 10 条。顶栏出现在【每一页】上,所以它必须有界
// (同 operations_now 那条"人人都开的页面上不许无界扫描")。
// 代价说清楚:超过 10 条未读时徽标显示「9+」,它回答的是"有没有、多不多",
// 不是"精确几条" —— 精确的数字在 /notifications 那一页上。
export const BELL_LIMIT = 10

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
        const rows = mustRows(
            await supabase
                .from('notifications')
                .select('id')
                .order('occurred_at', { ascending: false })
                .limit(BELL_LIMIT),
            'notifications'
        )
        if (rows.length === 0) return 0
        const readRows = mustRows(
            await supabase
                .from('notification_reads')
                .select('notification_id')
                .eq('user_id', userId)
                .in('notification_id', rows.map((r) => r.id)),
            'notification_reads'
        )
        const read = new Set(readRows.map((r) => r.notification_id))
        return rows.filter((r) => !read.has(r.id)).length
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
