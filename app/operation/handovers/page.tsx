// app/operation/handovers/page.tsx
// PROC-SUPPORT-1(R4):交接班列表 —— ★ 未签收的必须一眼看得出来 ★。
//
// 【这一页第一天会是空的,而空态要说出为什么】线上 work_category = 'shopfloor'
// 的员工数是 0:没有人交班,也没有人接班。空态因此不是一句"暂无数据",而是
// 一句说得清【在等什么】的话 —— 与 output_batch_safety_states 那条"缺失即阻断"
// 同一条:一个说不出原因的空屏幕,读起来像功能坏了。
//
// 【这一页【不】显示"这个班处理了什么"】加工单只有 process_date(一个 date),
// 归不到某一个班次上(G8)。屏幕上因此有一句常驻的话说明这件事 ——
// 不写,下一个人会以为是这一页忘了查。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { can } from '@/lib/permissions'
import { MOD } from '@/lib/modules'
import AcknowledgeButton from './AcknowledgeButton'

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

    return (
        <>
            <div className="p-8 max-w-5xl">
                <div className="flex items-center justify-between mb-1">
                    <h1 className="text-2xl font-semibold">{t('processing.handover.title')}</h1>
                    {canEdit && (
                        <Link href="/operation/handovers/new"
                              className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 text-sm">
                            {t('processing.handover.new')}
                        </Link>
                    )}
                </div>

                {/* ★【G8:这一页答不出"这个班处理了什么",而它必须自己说出来】★ */}
                <p className="text-xs text-gray-500 mb-4">{t('processing.handover.cannotAnswerYet')}</p>

                {unacknowledged > 0 && (
                    <p className="mb-4 text-sm bg-amber-50 border border-amber-200 text-amber-900 px-3 py-2 rounded">
                        {t('processing.handover.unacknowledgedCount', { n: String(unacknowledged) })}
                    </p>
                )}

                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('processing.handover.colDate')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('processing.handover.colShift')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('processing.handover.colFrom')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('processing.handover.colTo')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('processing.handover.colAck')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.id} className={r.acknowledged_at ? '' : 'bg-amber-50'}>
                                <td className="border border-gray-300 px-3 py-2">{r.handover_date}</td>
                                <td className="border border-gray-300 px-3 py-2">{shiftOf(r.shift_code)}</td>
                                <td className="border border-gray-300 px-3 py-2">{nameOf(r.outgoing_employee_id)}</td>
                                <td className="border border-gray-300 px-3 py-2">{nameOf(r.incoming_employee_id)}</td>
                                {/* ★【未签收 vs 已签收:一个【具名的状态】,不是一个空格】★
                                    空格读起来像"这一栏不重要";而未签收的意思是
                                    【下一个班的人还没说他看过这些话】。 */}
                                <td className="border border-gray-300 px-3 py-2">
                                    {r.acknowledged_at ? (
                                        <span className="inline-block px-2 py-0.5 rounded bg-green-100 text-green-800 text-xs">
                                            {t('processing.handover.acknowledgedBy', {
                                                who: nameOf(r.acknowledged_by),
                                                when: new Date(r.acknowledged_at).toLocaleString(dl),
                                            })}
                                        </span>
                                    ) : (
                                        <span className="flex items-center gap-2">
                                            <span className="inline-block px-2 py-0.5 rounded bg-amber-200 text-amber-900 text-xs font-medium">
                                                {t('processing.handover.pending')}
                                            </span>
                                            {canEdit && <AcknowledgeButton handoverId={r.id} />}
                                        </span>
                                    )}
                                </td>
                            </tr>
                        ))}
                        {rows.length === 0 && (
                            <tr><td colSpan={5} className="border border-gray-300 px-3 py-6 text-center text-gray-500">
                                {/* 【空态说出【在等什么】,不说"暂无数据"】 */}
                                {t('processing.handover.emptyNoStaff')}
                            </td></tr>
                        )}
                    </tbody>
                </table>
            </div>
        </>
    )
}
