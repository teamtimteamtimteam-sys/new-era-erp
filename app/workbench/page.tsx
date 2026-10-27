// app/workbench/page.tsx
// SYSTEM-MAP-2(Tim 2026-10-26 裁定 2.4 (9),2026-10-27 Q1–Q7):工作台 › 待办 —— 在等【你】动手的每一件事,一张清单。
//   【只列在等你的】数据是 waiting_for_me()(db/functions/waiting_for_me.sql):你批得了的每一种审批(库里判 —— CFO 级只认真的
//     cfo 角色持有人、四眼、1,000 的分档、自批例外,一条都没有在这一页另写)、已批准等你付的付款申请(Tim Q4 c)、
//     你的任务、你要写的考核与你要做的自评、你没读过的通知。盘点不在这里(Q4 a,它留在提醒页)。
//   【每一行】是什么 · 谁提的 · 等了多久 · 链到做决定的那一页(lib/workbench.ts todoHref)。
//   【批量】只在那一种今天已经能批量决定的地方(凭证 · 仓库 · 条款 · 资产处置:批准与驳回;一般报销 · 过磅草稿:只驳回),
//     走那一种自己的单项动作、一次一项(TABLE-FEATURES-3 的 BulkDecisionBar)—— 别的行链出去。
//   【门】恒真(工作台每个登录的人都有):这一页不挡人,清单本身就是按读者裁的。没有一件 → 说出来。
//   首页那个数读的是同一条查询的行数(waiting_for_me_count)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { formatDate } from '@/lib/dates'
import { businessToday } from '@/lib/format'
import { todoHref, bulkMode, daysWaited, isTodoType, type WaitingRow } from '@/lib/workbench'
import WorkbenchTable, { type TodoRow } from './WorkbenchTable'

type Actor = { state?: string; name?: string | null } | null

export default async function WorkbenchPage() {
    const denied = await requireFunction(FN.todo)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const rows = mustRows(await supabase.rpc('waiting_for_me'), 'waiting_for_me') as unknown as WaitingRow[]
    const today = businessToday()

    const who = (a: Actor): { text: string; restricted: boolean } => {
        switch (a?.state) {
            case 'person': return { text: a.name ?? t('workbench.who.unknown'), restricted: false }
            case 'portal': return { text: t('workbench.who.portal', { name: a.name ?? '' }), restricted: false }
            case 'system': return { text: t('workbench.who.system'), restricted: false }
            case 'restricted': return { text: t('common.restricted'), restricted: true }
            case 'removed': return { text: t('workbench.who.removed'), restricted: false }
            default: return { text: t('workbench.who.unknown'), restricted: false }
        }
    }

    const todo: TodoRow[] = rows.map((r) => {
        const raised = who(r.raised_by as Actor)
        const waited = daysWaited(r.waiting_since, today)
        return {
            key: `${r.item_type}-${r.item_id}`,
            id: r.item_id,
            type: isTodoType(r.item_type) ? r.item_type : null,
            rawType: r.item_type,
            parentId: r.parent_id,
            code: r.code ?? '—',
            // 通知那一行:subject 是 event_type(机器词),它的那句话要 payload 才拼得出 —— 这里只说「一条没读的通知」,全文在通知页
            subject: r.item_type === 'notification' ? '' : (r.subject ?? ''),
            href: todoHref(r),
            raisedBy: raised.text,
            raisedRestricted: raised.restricted,
            waited,
            since: r.waiting_since,
            sinceText: r.waiting_since ? formatDate(r.waiting_since, locale) : '—',
            due: r.due_date ? formatDate(r.due_date, locale) : null,
            bulk: bulkMode(r.item_type),
        }
    }).sort((a, b) => (b.waited ?? -1) - (a.waited ?? -1) || a.key.localeCompare(b.key))

    return (
        <ListPage title={t('workbench.title')} intro={t('workbench.intro')}
            state={todo.length === 0 ? { kind: 'empty', noRows: t('workbench.empty') } : { kind: 'ok' }}>
            <WorkbenchTable rows={todo} />
        </ListPage>
    )
}
