// NTF-1:通知中心。
//
// 【这一页显示的是"你有权限看见的那些"】—— RLS 按 subject_type 分派到那个模块的
// 权限码,所以两个人打开这一页会看见不同的行。页面把这句话【写出来】:
// 一个安静的收件箱可能意味着"没有事发生",也可能意味着"发生的事不归你看",
// 而这两件事在屏幕上长得一模一样(moduleGuard 的老病)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { countUnread } from '@/lib/notifications'
import { RowCapNotice } from '@/app/components/ui/row-cap-notice'
import { subjectHref, eventParams, type NotificationRow } from './notificationTypes'
import MarkReadButtons from './MarkReadButtons'
import { formatAuditStamp } from '@/lib/dates'
import { requireNotFloorDisplay } from '@/app/components/moduleGuard'

// 有界:一页 50 条。更早的属于报表中心那一刀,不属于收件箱。TABLE-EXPORT-2b-2:超过 50 条时 RowCapNotice 说出「前 50 条,共 M 条」。
const PAGE_LIMIT = 50

export default async function NotificationsPage() {
    // MES-8b-2:这一页不要任何码,所以一块车间大屏的会话(软导航不重画根布局)要在这里被拒、指回 /display。
    const floorRefusal = await requireNotFloorDisplay()
    if (floorRefusal) return floorRefusal
    const t = await getTranslations()
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    // 【mustRows,不是 ?? []】一次失败的查询不是一个空收件箱。
    const rows = mustRows(
        await supabase
            .from('notifications')
            .select('id, occurred_at, event_type, subject_type, subject_id, subject_code, payload')
            .order('occurred_at', { ascending: false })
            .limit(PAGE_LIMIT),
        'notifications'
    ) as NotificationRow[]

    const readRows =
        rows.length === 0
            ? []
            : mustRows(
                  await supabase
                      .from('notification_reads')
                      .select('notification_id')
                      .eq('user_id', user?.id ?? '')
                      .in('notification_id', rows.map((r) => r.id)),
                  'notification_reads'
              )
    const read = new Set(readRows.map((r) => r.notification_id))
    // ★ TABLE-EXPORT-2b-2(Tim 2026-10-23 TABLE-EXPORT-2b Q2 · Q6):未读数是精确的 —— 与顶栏徽标同一个函数(lib/notifications.ts),
    //   不再只数这一页读到的 50 条;一页之外还有多少条,RowCapNotice 说出来(只说,不导出 —— 与 change-history 同一种处置)。
    const [unreadCount, total] = await Promise.all([
        user ? countUnread(supabase, user.id) : 0, // 中间件已经把没登录的人挡在外面;没有 user 就没有"我读过的"
        supabase.from('notifications').select('id', { count: 'exact', head: true }).then((r) => mustCount(r, 'notifications count')),
    ])

    return (
        <div className="p-8 max-w-4xl">
            <div className="flex items-center justify-between mb-2">
                <h1 className="">
                    {t('notifications.title')}
                    <span className="ml-3 text-sm font-normal text-[color:var(--brand-muted-text)]" data-unread-count={unreadCount}>
                        {t('notifications.unreadCount', { n: unreadCount })}
                    </span>
                </h1>
                {unreadCount > 0 && <MarkReadButtons />}
            </div>

            {/* 【缺席不是零】—— 这一页只显示你有权限看见的那些 */}
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-6">{t('notifications.permissionNote')}</p>

            <RowCapNotice shown={rows.length} total={total} />
            {rows.length === 0 ? (
                <p className="text-[color:var(--brand-muted-text)]">{t('notifications.empty')}</p>
            ) : (
                <ul className="space-y-2">
                    {rows.map((r) => {
                        const isUnread = !read.has(r.id)
                        const href = subjectHref(r)
                        return (
                            <li
                                key={r.id}
                                className={
                                    'border rounded px-4 py-3 ' +
                                    (isUnread
                                        ? 'border-amber-400 bg-amber-50'
                                        : 'border-gray-200 bg-white')
                                }
                            >
                                <div className="flex items-start justify-between gap-4">
                                    <div>
                                        {/* 【永远是句子,不是码】—— IOD-1b 的教训 */}
                                        <p className={isUnread ? 'text-sm font-medium' : 'text-sm text-gray-600'}>
                                            {t('notifications.event.' + r.event_type, eventParams(r))}
                                        </p>
                                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
                                            {formatAuditStamp(r.occurred_at)}
                                            {href && r.subject_code && (
                                                <>
                                                    {' · '}
                                                    <Link href={href} className="hover:underline app-link app-link-inline">
                                                        {r.subject_code}
                                                    </Link>
                                                </>
                                            )}
                                        </p>
                                    </div>
                                    {isUnread && <MarkReadButtons id={r.id} />}
                                </div>
                            </li>
                        )
                    })}
                </ul>
            )}
        </div>
    )
}
