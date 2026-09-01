'use client'

// app/processing/handovers/new/NewHandoverForm.tsx
// PROC-SUPPORT-1(R4/R5):交班的人填的那一屏。
//
// ★【这一屏刻意【没有】"这个班处理了什么"那一栏】★
// 加工单只有 process_date(一个 date),全库在本刀之前没有任何时刻维度,
// 所以一张加工单归不到某一个班次上 —— 那是阶段 7 的 G8。
// 一个自由文本框会收下一个猜测,而那个猜测将来会与加工单算出来的数打架,
// **而人们读到的那一份会是错的那一份**。缺席看得见,不一致看不见。
// 屏幕上有一句常驻的话说明这件事,免得下一个人以为是这一屏忘了做。
//
// ★【也【没有】事故那一栏】★ 它属于那本尚未建的 WSH 事故与未遂事件登记簿。
// NEA 的"立即通报 + 两个工作日内书面报告"只能有一个载体。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { submitShiftHandover } from '../actions'

export default function NewHandoverForm({ shifts, people, itemTypes, downtime }: {
    shifts: { code: string; label: string }[]
    people: { id: string; label: string }[]
    itemTypes: { code: string; label: string; required: boolean }[]
    downtime: { id: string; label: string }[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)

    const [shiftCode, setShiftCode] = useState('')
    // 【日期不预填今天】世界侧日期不给默认值(与 FIN-10 同一条)——
    // 一个预填的日期会让"没人选过"看起来像"有人选了今天"。
    const [date, setDate] = useState('')
    const [outgoing, setOutgoing] = useState('')
    const [incoming, setIncoming] = useState('')
    const [notes, setNotes] = useState('')
    const [items, setItems] = useState<Record<string, string>>({})
    const [refs, setRefs] = useState<string[]>([])

    const submit = () => startTransition(async () => {
        setError(null)
        const res = await submitShiftHandover({
            shift_code: shiftCode,
            handover_date: date,
            outgoing_employee_id: outgoing,
            incoming_employee_id: incoming,
            notes,
            items: itemTypes.map((it) => ({ item_type_code: it.code, body: items[it.code] ?? '' })),
            downtime_ids: refs,
        })
        if (res.error) setError(res.error)
        else router.push('/processing/handovers')
    })

    return (
        <div className="p-8 max-w-3xl space-y-5">
            <h1 className="text-2xl font-semibold">{t('processing.handover.newTitle')}</h1>

            {/* ★ 这一屏答不出什么,自己说出来 ★ */}
            <p className="text-xs text-gray-500">{t('processing.handover.cannotAnswerYet')}</p>
            <p className="text-xs text-gray-500">{t('processing.handover.incidentsElsewhere')}</p>

            {people.length === 0 && (
                <p className="text-sm bg-amber-50 border border-amber-200 text-amber-900 px-3 py-2 rounded">
                    {t('processing.handover.emptyNoStaff')}
                </p>
            )}

            <div className="grid grid-cols-2 gap-4">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('processing.handover.colShift')} <span className="text-red-600">*</span>
                    </label>
                    <select value={shiftCode} onChange={(e) => setShiftCode(e.target.value)}
                            className="w-full border border-gray-300 px-3 py-2 rounded">
                        <option value="">{t('common.select')}</option>
                        {shifts.map((s) => <option key={s.code} value={s.code}>{s.label}</option>)}
                    </select>
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('processing.handover.colDate')} <span className="text-red-600">*</span>
                    </label>
                    <input type="date" value={date} onChange={(e) => setDate(e.target.value)}
                           className="w-full border border-gray-300 px-3 py-2 rounded" />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('processing.handover.colFrom')} <span className="text-red-600">*</span>
                    </label>
                    <select value={outgoing} onChange={(e) => setOutgoing(e.target.value)}
                            className="w-full border border-gray-300 px-3 py-2 rounded">
                        <option value="">{t('common.select')}</option>
                        {people.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
                    </select>
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('processing.handover.colTo')} <span className="text-red-600">*</span>
                    </label>
                    <select value={incoming} onChange={(e) => setIncoming(e.target.value)}
                            className="w-full border border-gray-300 px-3 py-2 rounded">
                        <option value="">{t('common.select')}</option>
                        {people.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
                    </select>
                </div>
            </div>

            {/* 【内容是【行】—— 这一段整个由字典驱动】加第七类内容 = 字典加一行,
                这一屏一个字都不用改。 */}
            <div>
                <h2 className="font-medium mb-2">{t('processing.handover.itemsTitle')}</h2>
                {itemTypes.map((it) => (
                    <div key={it.code} className="mb-3">
                        <label className="block text-sm mb-1">
                            {it.label}{it.required && <span className="text-red-600"> *</span>}
                        </label>
                        <textarea rows={2} value={items[it.code] ?? ''}
                                  onChange={(e) => setItems({ ...items, [it.code]: e.target.value })}
                                  className="w-full border border-gray-300 px-3 py-2 rounded" />
                    </div>
                ))}
            </div>

            {/* R5:设备状态是【引用】,不是复述 —— 勾的是 equipment_downtime 的行。 */}
            <div>
                <h2 className="font-medium mb-1">{t('processing.handover.equipmentTitle')}</h2>
                <p className="text-xs text-gray-500 mb-2">{t('processing.handover.equipmentReference')}</p>
                {downtime.length === 0
                    ? <p className="text-sm text-gray-500">{t('processing.handover.noDowntime')}</p>
                    : downtime.map((d) => (
                        <label key={d.id} className="flex items-center gap-2 text-sm mb-1">
                            <input type="checkbox" checked={refs.includes(d.id)}
                                   onChange={(e) => setRefs(e.target.checked
                                       ? [...refs, d.id]
                                       : refs.filter((x) => x !== d.id))} />
                            {d.label}
                        </label>
                    ))}
            </div>

            <div>
                <label className="block text-sm font-medium mb-1">{t('processing.handover.notes')}</label>
                <textarea rows={2} value={notes} onChange={(e) => setNotes(e.target.value)}
                          className="w-full border border-gray-300 px-3 py-2 rounded" />
            </div>

            {error && <p className="text-sm text-red-700">{error}</p>}

            <button type="button" onClick={submit} disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400">
                {isPending ? t('common.saving') : t('processing.handover.submit')}
            </button>
        </div>
    )
}
