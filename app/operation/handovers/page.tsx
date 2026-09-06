// app/operation/handovers/page.tsx
// PROC-SUPPORT-1(R4):交接班列表 —— ★ 未签收的必须一眼看得出来 ★。
//
// CONV-5:套 CONV-1 的两文件模板。
// ★ state 恒为 'ok',而且这一页是【为什么】那条判据存在的一个干净例子:
//   抬头第二段写着"这一页第一天会是空的,而空态要说出为什么"。那句
//   cannotAnswerYet(G8:答不出"这个班处理了什么")必须在【空态下也出现】——
//   它走 notices 槽,画在状态分支之前;而"在等什么"那句空态话由 DataTable
//   自己的 empty 说(emptyNoStaff),不是一句"暂无数据"。
//
// 【这一页第一天会是空的,而空态要说出为什么】线上 work_category = 'shopfloor'
// 的员工数是 0:没有人交班,也没有人接班。空态因此不是一句"暂无数据",而是
// 一句说得清【在等什么】的话 —— 与 output_batch_safety_states 那条"缺失即阻断"
// 同一条:一个说不出原因的空屏幕,读起来像功能坏了。
//
// 【这一页【不】显示"这个班处理了什么"】加工单只有 process_date(一个 date),
// 归不到某一个班次上(G8)。屏幕上因此有一句常驻的话说明这件事 ——
// 不写,下一个人会以为是这一页忘了查。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { can } from '@/lib/permissions'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import HandoversTable, { type HandoverRow } from './HandoversTable'

export default async function HandoversPage() {
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const dl = locale === 'zh' ? 'zh-CN' : 'en-US'
    const supabase = await createClient()
    const canEdit = await can('module.processing.edit')

    const rows = mustRows(
        await supabase.from('shift_handovers')
            .select('id, shift_code, handover_date, outgoing_employee_id, incoming_employee_id, notes, submitted_at, acknowledged_at, acknowledged_by')
            .order('handover_date', { ascending: false }),
        'shift_handovers') as {
            id: string; shift_code: string; handover_date: string
            outgoing_employee_id: string; incoming_employee_id: string
            notes: string | null; submitted_at: string
            acknowledged_at: string | null; acknowledged_by: string | null }[]

    // 【名字走 handover_people,不走 employees】employees 的行策略要 module.hr.view,
    // 而这一页的使用者是车间技师。直读 employees 会让每一格名字静默地空掉。
    const people = mustRows(
        await supabase.from('handover_people').select('id, code, preferred_name'),
        'handover_people') as { id: string; code: string; preferred_name: string | null }[]
    const nameOf = (id: string | null) => {
        if (!id) return '—'
        const p = people.find((x) => x.id === id)
        return p ? (p.preferred_name ?? p.code) : '—'
    }

    const shifts = mustRows(
        await supabase.from('shifts').select('code, name_en, name_zh, starts_at, ends_at').order('sort_order'),
        'shifts') as { code: string; name_en: string; name_zh: string
                       starts_at: string | null; ends_at: string | null }[]
    const shiftOf = (code: string) => {
        const sft = shifts.find((x) => x.code === code)
        if (!sft) return code
        const name = locale === 'zh' ? sft.name_zh : sft.name_en
        // ★【时刻没人说过就说"没人说过",不要显示成 00:00】★
        return sft.starts_at && sft.ends_at
            ? `${name} ${sft.starts_at.slice(0, 5)}–${sft.ends_at.slice(0, 5)}`
            : `${name}(${t('processing.handover.hoursUnstated')})`
    }

    const unacknowledged = rows.filter((r) => !r.acknowledged_at).length

    const tableRows: HandoverRow[] = rows.map((r) => ({
        id: r.id,
        handoverDate: r.handover_date,
        shiftLabel: shiftOf(r.shift_code),
        fromName: nameOf(r.outgoing_employee_id),
        toName: nameOf(r.incoming_employee_id),
        acknowledged: Boolean(r.acknowledged_at),
        // 时刻按 locale 格式化在服务端做完 —— dl 不过 RSC 边界
        acknowledgedLabel: r.acknowledged_at
            ? t('processing.handover.acknowledgedBy', {
                  who: nameOf(r.acknowledged_by),
                  when: new Date(r.acknowledged_at).toLocaleString(dl),
              })
            : null,
    }))

    return (
        <ListPage
            title={t('processing.handover.title')}
            maxWidth="max-w-5xl"
            actions={
                canEdit ? (
                    <Button asChild>
                        <Link href="/operation/handovers/new">{t('processing.handover.new')}</Link>
                    </Button>
                ) : undefined
            }
            notices={
                <>
                    {/* ★【G8:这一页答不出"这个班处理了什么",而它必须自己说出来】★ */}
                    <p className="text-xs text-gray-500 mb-4">{t('processing.handover.cannotAnswerYet')}</p>
                    {unacknowledged > 0 && (
                        <p className="mb-4 text-sm bg-amber-50 border border-amber-200 text-amber-900 px-3 py-2 rounded">
                            {t('processing.handover.unacknowledgedCount', { n: String(unacknowledged) })}
                        </p>
                    )}
                </>
            }
            state={{ kind: 'ok' }}
        >
            {/* 【空态说出【在等什么】,不说"暂无数据"】 */}
            <HandoversTable rows={tableRows} empty={t('processing.handover.emptyNoStaff')} canEdit={canEdit} />
        </ListPage>
    )
}
