'use client'

import { useState, useTransition } from 'react'
import { createContainer } from './actions'

// LOG-2c:新建集装箱。
// 【开航日永不预填】—— 它是世界那一侧的事实,系统无从知道。给它一个"今天",
// 会让"没填"比"填对"更容易通过,而这一栏填错了没有任何下游会喊。
// 库那一侧也拒绝空的开航日(CONTAINER_DEPARTURE_DATE_REQUIRED),两层各自成立。
// 【承运方只列货代】—— counterparty_type 是唯一真源;表上还有一条按名拒绝兜底。

export default function NewContainerForm({
    lanes, forwarders, labels,
}: {
    lanes: { id: string; label: string }[]
    forwarders: { id: string; label: string }[]
    labels: Record<string, string>
}) {
    const [error, setError] = useState<string | null>(null)
    const [pending, start] = useTransition()
    const field = 'rounded border border-gray-300 px-2 py-1 text-sm'

    if (lanes.length === 0) {
        return (
            <p className="mt-4 max-w-2xl rounded border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900">
                {labels.noLanes}
            </p>
        )
    }

    return (
        <form
            className="mt-4 rounded border border-gray-200 bg-gray-50 p-4"
            onSubmit={(e) => {
                e.preventDefault()
                const fd = new FormData(e.currentTarget)
                setError(null)
                start(async () => {
                    const res = await createContainer({
                        lane_id: fd.get('lane_id') as string,
                        departure_date: fd.get('departure_date') as string,
                        container_number: (fd.get('container_number') as string)?.trim() || null,
                        vessel: (fd.get('vessel') as string)?.trim() || null,
                        voyage: (fd.get('voyage') as string)?.trim() || null,
                        forwarder_id: (fd.get('forwarder_id') as string) || null,
                        bl_number: (fd.get('bl_number') as string)?.trim() || null,
                    })
                    if (res && 'error' in res) setError(res.error)
                })
            }}
        >
            <h2 className="font-medium mb-3">{labels.heading}</h2>
            {error && <div className="mb-3 rounded border border-red-400 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}
            <div className="flex flex-wrap items-end gap-3">
                <div>
                    <label className="block text-xs font-medium mb-1">{labels.lane} <span className="text-red-600">*</span></label>
                    <select name="lane_id" required className={field}>
                        {lanes.map((l) => <option key={l.id} value={l.id}>{l.label}</option>)}
                    </select>
                </div>
                <div>
                    <label className="block text-xs font-medium mb-1">{labels.departure} <span className="text-red-600">*</span></label>
                    {/* 【没有 defaultValue】—— 见组件抬头 */}
                    <input type="date" name="departure_date" required className={field} />
                </div>
                <div>
                    <label className="block text-xs font-medium mb-1">{labels.containerNumber}</label>
                    <input name="container_number" className={field} />
                </div>
                <div>
                    <label className="block text-xs font-medium mb-1">{labels.vessel}</label>
                    <input name="vessel" className={field} />
                </div>
                <div>
                    <label className="block text-xs font-medium mb-1">{labels.voyage}</label>
                    <input name="voyage" className={`${field} w-24`} />
                </div>
                <div>
                    <label className="block text-xs font-medium mb-1">{labels.forwarder}</label>
                    <select name="forwarder_id" className={field} defaultValue="">
                        <option value="">—</option>
                        {forwarders.map((f) => <option key={f.id} value={f.id}>{f.label}</option>)}
                    </select>
                </div>
                <div>
                    <label className="block text-xs font-medium mb-1">{labels.bl}</label>
                    <input name="bl_number" className={field} />
                </div>
                <button type="submit" disabled={pending} className="rounded bg-blue-600 px-4 py-2 text-white disabled:opacity-50">
                    {labels.submit}
                </button>
            </div>
            <p className="mt-2 text-xs text-gray-500">{labels.departureHint} · {labels.blHint}</p>
        </form>
    )
}
