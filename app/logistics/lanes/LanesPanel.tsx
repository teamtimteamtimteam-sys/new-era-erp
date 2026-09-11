'use client'

import { useState, useTransition } from 'react'
import { addPort, addLane, addRequirement, removeRequirement, markLaneReviewed } from './actions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'

type Req = { id: string; document_type: string; regime: string | null }
type Lane = { id: string; label: string; state: string; requirements: Req[] }

export default function LanesPanel({
    ports, lanes, labels,
canEdit
}: {
    ports: { id: string; label: string }[]
    lanes: Lane[]
    labels: Record<string, string>

canEdit: boolean
}) {
    const [error, setError] = useState<string | null>(null)
    const [pending, start] = useTransition()
    // ★ 这一页的控件【宽度由 INPUT-2 设定】(Tim 裁定 2026-09-10):
    //   共享模块不带宽度类,而一个没有宽度类的原生 <input>/<select> 是按
    //   **字号与内边距**自己算宽的 —— 标准把手机字号 14→16px、左内边距 8→10px、
    //   下拉右内边距 →24px,于是这两张【不换行的】flex 表单在 390px 上从
    //   +12px 溢出长到 +76px。下面三个 w-* 是把它按回基线的最小一组:390px 上
    //   `name` w-40(160px)、两颗下拉各 w-34(136px)—— 实测整页溢出 +76px → **+4px**
    //   (基线是 +12px)。
    //
    //   ★ 而【桌面另给一档 `md:`】不是装饰,是一次实测逼出来的:
    //   Chromium 给 `<select>` 的箭头留的位置**在 padding-right 之外**,实测约 **27px**
    //   (拿两次自动宽反算:14px 那次 140 = 文字 + 8 + 8 + 2 + 27;16px 那次 172 = 文字 + 10 + 24 + 2 + 27)。
    //   于是「文字装得下」要的宽度是【文字 + 左内边距 + 右内边距 + 边框 + 27】。
    //   390px 上这一页**给不起**那个宽度(两颗下拉合起来不能超过 279.5px,否则整页又溢出),
    //   所以手机上「SG Singapore」会被截掉尾巴 —— **那是标准的 16px 字号撞上一张不换行的表单,
    //   已经在交回报告里照直报了(带截图),不是靠宽度类修得掉的。**
    //   ☞ **但桌面有的是余地(那一行最右 738px / 1440px),没有理由跟着手机一起受委屈:**
    //   `md:` 把 `name` 还原成标准自己算出来的 **168px**、下拉给到 **160px**
    //   (标准不加宽度类时自己算出来的是 158px,这里贴着它 +2px,文字装得下:87.94 / 97)。
    //   **只在这一页的调用点上,共享模块仍然不带宽度。**
    const field = CONTROL_INPUT
    const fieldSelect = CONTROL_SELECT
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
                <PermissionGate code="module.purchasing.edit" allowed={canEdit}>
                <form
                    onSubmit={(e) => { e.preventDefault(); const f = e.currentTarget; const d = new FormData(f)
                        run(() => addPort(d.get('code') as string, d.get('name') as string, ((d.get('country') as string) || null)), f) }}
                    className="flex flex-wrap items-end gap-2 rounded border border-gray-200 bg-gray-50 p-3"
                >
                    <div>
                        <label className="block mb-1">{labels.portCode}</label>
                        <input name="code" required className={`${field} w-28`} />
                    </div>
                    <div>
                        <label className="block mb-1">{labels.portName}</label>
                        <input name="name" required className={field} />
                    </div>
                    <Button variant="default" className="text-sm shrink whitespace-normal" disabled={pending}>{labels.addPort}</Button>
                </form>
                </PermissionGate>

                {ports.length >= 2 && (
                    <PermissionGate code="module.purchasing.edit" allowed={canEdit}>
                    <form
                        onSubmit={(e) => { e.preventDefault(); const f = e.currentTarget; const d = new FormData(f)
                            run(() => addLane(d.get('origin') as string, d.get('destination') as string), f) }}
                        className="flex flex-wrap items-end gap-2 rounded border border-gray-200 bg-gray-50 p-3"
                    >
                        <div>
                            <label className="block mb-1">{labels.origin}</label>
                            <select name="origin" required className={fieldSelect}>
                                {ports.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
                            </select>
                        </div>
                        <div>
                            <label className="block mb-1">{labels.destination}</label>
                            <select name="destination" required className={fieldSelect}>
                                {ports.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
                            </select>
                        </div>
                        <Button variant="default" className="text-sm shrink whitespace-normal" disabled={pending}>{labels.addLane}</Button>
                    </form>
                    </PermissionGate>
                )}
            </div>

            {lanes.length === 0 ? (
                <p className="mt-6 max-w-2xl rounded border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900">{labels.noLanes}</p>
            ) : (
                <div className="mt-6 space-y-6">
                    {lanes.map((l) => (
                        <section key={l.id} className="rounded border border-gray-200 p-4">
                            <h2 className="mb-2">{l.label}</h2>

                            {/* 【三种状态,三句话】。中间那一句说的是"有人做过这个决定" ——
                                把它与"没人看过"合并成"零条要求",就是把一次没做完的活
                                显示成一个做完了的结论。 */}
                            {l.state === 'not_defined' && (
                                <p className="mb-3 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
                                    {labels.notDefined}
                                </p>
                            )}
                            {l.state === 'defined_empty' && (
                                <p className="mb-3 rounded border border-gray-300 bg-gray-50 px-3 py-2 text-sm text-[color:var(--brand-text)]">
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
                                            {r.regime ? <span className="ml-2 text-xs text-[color:var(--brand-muted-text)]">({r.regime})</span> : null}
                                            <PermissionGate code="module.purchasing.edit" allowed={canEdit}>
                                            <Button
                                                variant="destructive"
                                                size="inline"
                                                type="button"
                                                disabled={pending}
                                                onClick={() => run(() => removeRequirement(r.id))}
                                                className="ml-3 text-xs"
                                            >{labels.removeRequirement}</Button>
                                            </PermissionGate>
                                        </li>
                                    ))}
                                </ul>
                            )}

                            <PermissionGate code="module.purchasing.edit" allowed={canEdit}>
                            <form
                                onSubmit={(e) => { e.preventDefault(); const f = e.currentTarget; const d = new FormData(f)
                                    run(() => addRequirement(l.id, d.get('document_type') as string, ((d.get('regime') as string) || null)), f) }}
                                className="flex flex-wrap items-end gap-2"
                            >
                                <div>
                                    <label className="block mb-1">{labels.documentType}</label>
                                    <input name="document_type" required className={field} />
                                </div>
                                <div>
                                    <label className="block mb-1">{labels.regime}</label>
                                    <input name="regime" className={field} />
                                </div>
                                <Button variant="default" className="text-sm shrink whitespace-normal" disabled={pending}>
                                    {labels.addRequirement}
                                </Button>
                                {l.state === 'not_defined' && (
                                    <Button variant="secondary" className="text-sm shrink whitespace-normal"
                                        type="button"
                                        disabled={pending}
                                        onClick={() => run(() => markLaneReviewed(l.id))}
                                    >{labels.markReviewed}</Button>
                                )}
                            </form>
                            </PermissionGate>
                            <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">{labels.regimeHint}</p>
                        </section>
                    ))}
                </div>
            )}
        </>
    )
}
