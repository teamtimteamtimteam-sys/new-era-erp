'use client'

// WO-1c:新建工单的表单。
//
// 【三处 why-line,而它们都是这一族反复付过学费的那几条】
//   * 排产日【可空、且不给默认值】—— 它与加工日/开票日不是同一种日期:那些决定
//     汇率与期间(FIN-10),这一个决定不了钱。但同样不默认:一个补出来的今天会把
//     "谁也没排过期"伪装成"排在今天"。空就是"没排"。
//   * 预期产出【整段可以不填】—— 没有行 = 没人估过,不是估了零。表单因此
//     【不预置任何一行】:预置一行等于替人做了一个"这里应该有个数"的判断,
//     而这个库里今天没有任何东西能推出那个数(没有 BOM、投料侧化验来源全空)。
//   * 计划按【物料】写,不按批次 —— 排计划的时候批次往往还不存在。
import { useState, useTransition } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { createWorkOrder } from '../actions'

type Material = { id: string; code: string; name: string }
const LINE_SLOTS = 5
const EXPECTED_SLOTS = 3

export default function NewWorkOrderForm({ materials }: { materials: Material[] }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [scheduled, setScheduled] = useState('')
    const [lines, setLines] = useState(
        Array.from({ length: LINE_SLOTS }, () => ({ material_id: '', planned_qty: '' })))
    const [expected, setExpected] = useState(
        Array.from({ length: EXPECTED_SLOTS }, () => ({ material_id: '', expected_qty: '' })))
    const [notes, setNotes] = useState('')

    const filledLines = lines.filter((l) => l.material_id && l.planned_qty.trim() !== '')
    // 【禁用条件与服务端的 WO_NO_LINES 是同一件事】—— 服务端仍然独立拒空,
    // 界面这一道不是保护(AGENTS.md 的两道闸)。
    const blocked = filledLines.length === 0

    function submit() {
        setError('')
        startTransition(async () => {
            const res = await createWorkOrder({
                lines: filledLines.map((l) => ({
                    material_id: l.material_id, planned_qty: Number(l.planned_qty),
                })),
                expected: expected
                    .filter((e) => e.material_id && e.expected_qty.trim() !== '')
                    .map((e) => ({ material_id: e.material_id, expected_qty: Number(e.expected_qty) })),
                scheduled_date: scheduled.trim() === '' ? null : scheduled,
                notes: notes.trim() === '' ? null : notes,
            })
            if (res?.error) setError(res.error)
        })
    }

    return (
        <div className="p-8 max-w-3xl">
            <div className="mb-6">
                <Link href="/processing/orders" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-6">{t('processing.wo.newTitle')}</h1>

            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {error}
                </div>
            )}

            <div className="space-y-5">
                <div>
                    <label className="block text-sm font-medium mb-1">{t('processing.wo.form.scheduled')}</label>
                    <input type="date" value={scheduled} onChange={(e) => setScheduled(e.target.value)}
                           className="border border-gray-300 px-3 py-2 rounded" />
                    <p className="text-xs text-gray-500 mt-1">{t('processing.wo.form.scheduledWhy')}</p>
                </div>

                <div>
                    <h2 className="font-medium mb-1">{t('processing.wo.form.lines')}</h2>
                    <p className="text-xs text-gray-500 mb-2">{t('processing.wo.form.linesWhy')}</p>
                    <table className="w-full border-collapse border border-gray-300 text-sm">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-2 py-2 text-left">{t('processing.wo.colMaterial')}</th>
                                <th className="border border-gray-300 px-2 py-2 text-right">{t('processing.wo.colPlanned')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {lines.map((l, i) => (
                                <tr key={i}>
                                    <td className="border border-gray-300 px-2 py-2">
                                        <select value={l.material_id} className="w-full border border-gray-300 px-2 py-1 rounded"
                                                onChange={(e) => setLines(lines.map((x, j) =>
                                                    j === i ? { ...x, material_id: e.target.value } : x))}>
                                            <option value="">{t('processing.wo.form.selectMaterial')}</option>
                                            {materials.map((m) => (
                                                <option key={m.id} value={m.id}>{m.code} — {m.name}</option>
                                            ))}
                                        </select>
                                    </td>
                                    <td className="border border-gray-300 px-2 py-2 text-right">
                                        <input type="number" step="any" min="0" value={l.planned_qty}
                                               className="w-32 border border-gray-300 px-2 py-1 rounded text-right"
                                               onChange={(e) => setLines(lines.map((x, j) =>
                                                   j === i ? { ...x, planned_qty: e.target.value } : x))} />
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>

                <div>
                    <h2 className="font-medium mb-1">{t('processing.wo.form.expected')}</h2>
                    {/* 【这一段留空是一个正当答案 —— 说出来,而不是让人猜】 */}
                    <p className="text-xs text-gray-500 mb-2">{t('processing.wo.form.expectedWhy')}</p>
                    <table className="w-full border-collapse border border-gray-300 text-sm">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-2 py-2 text-left">{t('processing.wo.colMaterial')}</th>
                                <th className="border border-gray-300 px-2 py-2 text-right">{t('processing.wo.colExpected')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {expected.map((e, i) => (
                                <tr key={i}>
                                    <td className="border border-gray-300 px-2 py-2">
                                        <select value={e.material_id} className="w-full border border-gray-300 px-2 py-1 rounded"
                                                onChange={(ev) => setExpected(expected.map((x, j) =>
                                                    j === i ? { ...x, material_id: ev.target.value } : x))}>
                                            <option value="">{t('processing.wo.form.noExpectation')}</option>
                                            {materials.map((m) => (
                                                <option key={m.id} value={m.id}>{m.code} — {m.name}</option>
                                            ))}
                                        </select>
                                    </td>
                                    <td className="border border-gray-300 px-2 py-2 text-right">
                                        <input type="number" step="any" min="0" value={e.expected_qty}
                                               className="w-32 border border-gray-300 px-2 py-1 rounded text-right"
                                               onChange={(ev) => setExpected(expected.map((x, j) =>
                                                   j === i ? { ...x, expected_qty: ev.target.value } : x))} />
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('processing.wo.form.notes')}</label>
                    <textarea rows={2} value={notes} onChange={(e) => setNotes(e.target.value)}
                              className="w-full border border-gray-300 px-3 py-2 rounded" />
                </div>

                <p className="text-xs text-gray-600">{t('processing.wo.form.savesAsDraft')}</p>
                <div className="flex gap-3">
                    <button type="button" onClick={submit} disabled={isPending || blocked}
                            className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400">
                        {isPending ? t('common.saving') : t('processing.wo.form.save')}
                    </button>
                    <Link href="/processing/orders"
                          className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50">
                        {t('common.cancel')}
                    </Link>
                </div>
                {blocked && <p className="text-xs text-amber-700">{t('processing.wo.form.blockedNoLines')}</p>}
            </div>
        </div>
    )
}
