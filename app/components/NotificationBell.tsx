// NTF-1:TopNav 上的铃铛。
//
// 【它住在"关于你"那一区,不在 NavLinks 里】—— NavLinks 是模块导航(你能进哪些
// 模块),而收件箱不是一个模块,它是这个人自己的东西,与语言切换、退出登录同一区。
//
// 【读失败绝不画成 0】TopNav 出现在每一页上,所以这里【不让异常冒出去】——
// 一次读不到通知不该把整站每一页都变成错误页。但它也【绝不退化成 0】:
// 0 的意思是"没有通知",而读不到的意思是"不知道"。两者在屏幕上必须长得不一样,
// 否则一次权限错误会被读成一个干净的收件箱(lib/permissions.ts 存在的全部理由)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'

// 【有界】只看最新的 10 条。首页与每一页都要付这次查询的钱,所以它必须有界
// (同 operations_now 那条"人人都开的页面上不许无界扫描")。
// 代价说清楚:超过 10 条未读时徽标显示「9+」,它回答的是"有没有、多不多",
// 不是"精确几条" —— 精确的数字在 /notifications 那一页上。
const BELL_LIMIT = 10

export default async function NotificationBell() {
    const t = await getTranslations()
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()
    if (!user) return null

    let unread: number | null = null
    try {
        const rows = mustRows(
            await supabase
                .from('notifications')
                .select('id')
                .order('occurred_at', { ascending: false })
                .limit(BELL_LIMIT),
            'notifications'
        )
        if (rows.length > 0) {
            const readRows = mustRows(
                await supabase
                    .from('notification_reads')
                    .select('notification_id')
                    .eq('user_id', user.id)
                    .in('notification_id', rows.map((r) => r.id)),
                'notification_reads'
            )
            const read = new Set(readRows.map((r) => r.notification_id))
            unread = rows.filter((r) => !read.has(r.id)).length
        } else {
            unread = 0
        }
    } catch {
        unread = null   // ← 【不知道】,与 0 是两回事
    }

    const badge = unread === null ? '!' : unread > 9 ? '9+' : String(unread)
    const show = unread === null || unread > 0

    return (
        <Link
            href="/notifications"
            className="relative text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50"
            title={unread === null ? t('notifications.bellError') : t('notifications.bellLabel')}
        >
            {t('notifications.bell')}
            {show && (
                <span
                    className={
                        'absolute -top-2 -right-2 min-w-[1.25rem] px-1 rounded-full text-xs text-white text-center ' +
                        (unread === null ? 'bg-gray-500' : 'bg-red-600')
                    }
                >
                    {badge}
                </span>
            )}
        </Link>
    )
}
