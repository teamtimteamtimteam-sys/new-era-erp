// NTF-1:通知中心。
//
// 【这一页显示的是"你有权限看见的那些"】—— RLS 按 subject_type 分派到那个模块的
// 权限码,所以两个人打开这一页会看见不同的行。页面把这句话【写出来】:
// 一个安静的收件箱可能意味着"没有事发生",也可能意味着"发生的事不归你看",
// 而这两件事在屏幕上长得一模一样(moduleGuard 的老病)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { subjectHref, eventParams, type NotificationRow } from './notificationTypes'
import MarkReadButtons from './MarkReadButtons'

// 有界:一页 50 条。更早的属于报表中心那一刀,不属于收件箱。
const PAGE_LIMIT = 50

export default async function NotificationsPage() {
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'
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
    const unreadCount = rows.filter((r) => !read.has(r.id)).length

    return (
        <div className="p-8 max-w-4xl">
            <div className="flex items-center justify-between mb-2">
                <h1 className="text-2xl font-bold">{t('notifications.title')}</h1>
                {unreadCount > 0 && <MarkReadButtons />}
            </div>

            {/* 【缺席不是零】—— 这一页只显示你有权限看见的那些 */}
            <p className="text-xs text-gray-500 mb-6">{t('notifications.permissionNote')}</p>

            {rows.length === 0 ? (
                <p className="text-gray-500">{t('notifications.empty')}</p>
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
                                        <p className="text-xs text-gray-500 mt-1">
                                            {new Date(r.occurred_at).toLocaleString(dateLocale)}
                                            {href && r.subject_code && (
                                                <>
                                                    {' · '}
                                                    <Link href={href} className="text-blue-600 hover:underline font-mono">
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
