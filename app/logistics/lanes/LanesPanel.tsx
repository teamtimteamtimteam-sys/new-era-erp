'use client'

import { useState, useTransition } from 'react'
import { addPort, addLane, addRequirement, removeRequirement, markLaneReviewed } from './actions'
import { Button } from '@/app/components/ui/button'

type Req = { id: string; document_type: string; regime: string | null }
type Lane = { id: string; label: string; state: string; requirements: Req[] }

export default function LanesPanel({
    ports, lanes, labels,
}: {
    ports: { id: string; label: string }[]
    lanes: Lane[]
    labels: Record<string, string>
}) {
    const [error, setError] = useState<string | null>(null)
    const [pending, start] = useTransition()
    const field = 'rounded border border-gray-300 px-2 py-1 text-sm'
    const run = (fn: () => Promise<{ error: string } | { success: true }>, form?: HTMLFormElement) =>
        start(async () => {
            const res = await fn()
            if ('error' in res) setError(res.error)
            else { setError(null); form?.reset() }
        })

    return (
        <>
            {error && <div className="mb-4 rounded border border-red-400 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}

            <div className="flex flex-wrap gap-6">
                <form
                    onSubmit={(e) => { e.preventDefault(); const f = e.currentTarget; const d = new FormData(f)
                        run(() => addPort(d.get('code') as string, d.get('name') as string, ((d.get('country') as string) || null)), f) }}
                    className="flex items-end gap-2 rounded border border-gray-200 bg-gray-50 p-3"
                >
                    <div>
                        <label className="block text-xs font-medium mb-1">{labels.portCode}</label>
                        <input name="code" required className={`${field} w-28`} />
                    </div>
                    <div>
                        <label className="block text-xs font-medium mb-1">{labels.portName}</label>
                        <input name="name" required className={field} />
                    </div>
                    <Button variant="default" size="sm" className="text-sm shrink whitespace-normal" disabled={pending}>{labels.addPort}</Button>
                </form>

                {ports.length >= 2 && (
                    <form
                        onSubmit={(e) => { e.preventDefault(); const f = e.currentTarget; const d = new FormData(f)
                            run(() => addLane(d.get('origin') as string, d.get('destination') as string), f) }}
                        className="flex items-end gap-2 rounded border border-gray-200 bg-gray-50 p-3"
                    >
                        <div>
                            <label className="block text-xs font-medium mb-1">{labels.origin}</label>
                            <select name="origin" required className={field}>
                                {ports.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
                            </select>
                        </div>
                        <div>
                            <label className="block text-xs font-medium mb-1">{labels.destination}</label>
                            <select name="destination" required className={field}>
                                {ports.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
                            </select>
                        </div>
                        <Button variant="default" size="sm" className="text-sm shrink whitespace-normal" disabled={pending}>{labels.addLane}</Button>
                    </form>
                )}
            </div>

            {lanes.length === 0 ? (
                <p className="mt-6 max-w-2xl rounded border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900">{labels.noLanes}</p>
            ) : (
                <div className="mt-6 space-y-6">
                    {lanes.map((l) => (
                        <section key={l.id} className="rounded border border-gray-200 p-4">
                            <h2 className="font-bold mb-2">{l.label}</h2>

                            {/* 【三种状态,三句话】。中间那一句说的是"有人做过这个决定" ——
                                把它与"没人看过"合并成"零条要求",就是把一次没做完的活
                                显示成一个做完了的结论。 */}
                            {l.state === 'not_defined' && (
                                <p className="mb-3 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
                                    {labels.notDefined}
                                </p>
                            )}
                            {l.state === 'defined_empty' && (
                                <p className="mb-3 rounded border border-gray-300 bg-gray-50 px-3 py-2 text-sm text-gray-700">
                                    {labels.definedEmpty}
                                </p>
                            )}
                            {l.state === 'defined' && (
                                <p className="mb-2 text-sm font-medium">{labels.defined}</p>
                            )}

                            {l.requirements.length > 0 && (
                                <ul className="mb-3 list-disc pl-6 text-sm">
                                    {l.requirements.map((r) => (
                                        <li key={r.id}>
                                            {r.document_type}
                                            {r.regime ? <span className="ml-2 text-xs text-gray-500">({r.regime})</span> : null}
                                            <Button
                                                variant="destructive"
                                                size="inline"
                                                type="button"
                                                disabled={pending}
                                                onClick={() => run(() => removeRequirement(r.id))}
                                                className="ml-3 text-xs"
                                            >{labels.removeRequirement}</Button>
                                        </li>
                                    ))}
                                </ul>
                            )}

                            <form
                                onSubmit={(e) => { e.preventDefault(); const f = e.currentTarget; const d = new FormData(f)
                                    run(() => addRequirement(l.id, d.get('document_type') as string, ((d.get('regime') as string) || null)), f) }}
                                className="flex flex-wrap items-end gap-2"
                            >
                                <div>
                                    <label className="block text-xs font-medium mb-1">{labels.documentType}</label>
                                    <input name="document_type" required className={field} />
                                </div>
                                <div>
                                    <label className="block text-xs font-medium mb-1">{labels.regime}</label>
                                    <input name="regime" className={field} />
                                </div>
                                <Button variant="default" size="sm" className="text-sm shrink whitespace-normal" disabled={pending}>
                                    {labels.addRequirement}
                                </Button>
                                {l.state === 'not_defined' && (
                                    <Button variant="secondary" size="sm" className="text-sm shrink whitespace-normal"
                                        type="button"
                                        disabled={pending}
                                        onClick={() => run(() => markLaneReviewed(l.id))}
                                    >{labels.markReviewed}</Button>
                                )}
                            </form>
                            <p className="mt-1 text-xs text-gray-500">{labels.regimeHint}</p>
                        </section>
                    ))}
                </div>
            )}
        </>
    )
}
