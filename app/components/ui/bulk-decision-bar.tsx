'use client'
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-3(Tim 2026-10-25 Q2)· 批量批准 / 驳回 —— 7 张清单共用这一条
// ════════════════════════════════════════════════════════════════════════════
// 五个申请面板(凭证 · 仓库 · 条款 ×2 页 · 资产处置)批准与驳回;报销单队列与过磅草稿只驳回。没有批量撤回、没有批量导出。
//   · 「全选」只勾【屏幕上的】那几行(lib/bulkRun.ts toggleAllOnScreen)。
//   · 驳回:整批一句理由,写到每一项上(那张卡片上的单项驳回逐项各收一次同一句)。
//   · 一次一项,走那张卡片上的单项动作 —— 四眼、CFO 档位与拒绝按项由库判(lib/bulkRun.ts runOneAtATime)。
//   · 跑完一张结果名单:每一项「做成了」或「被拒了」+ 它自己的理由(data-slot="bulk-results")。
// 卡片清单每张卡片一个 <BulkCheck>;表格清单用 DataTable 的 selection。
import * as React from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { Button } from '@/app/components/ui/button'
import { SelectAllCheckbox } from '@/app/components/ui/data-table'
import { CONTROL_CHECKBOX } from '@/app/components/ui/control-style'
import { runOneAtATime, selectedInScreenOrder, toggleAllOnScreen, type BulkItem, type BulkOutcome } from '@/lib/bulkRun'

type Act = { error?: string; detail?: string } | void | undefined

export function BulkDecisionBar({
    items, selected, onSelectedChange, approve, reject, showSelectAll = true,
}: {
    /** 屏幕上可以批量处理的每一项,按屏幕先后 */
    items: readonly BulkItem[]
    selected: ReadonlySet<string>
    onSelectedChange: (next: Set<string>) => void
    /** 不给 = 这张清单只能批量驳回(报销单队列 · 过磅草稿) */
    approve?: { title: string; body?: string; act: (item: BulkItem) => Promise<Act> }
    reject: { title: string; body?: string; placeholder: string; act: (item: BulkItem, reason: string) => Promise<Act> }
    /** 表格清单的全选在表头(DataTable selection)—— 那时这里不再画一枚 */
    showSelectAll?: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [running, setRunning] = React.useState<{ done: number; total: number } | null>(null)
    const [results, setResults] = React.useState<BulkOutcome[]>([])
    const chosen = selectedInScreenOrder(items, selected)
    const n = chosen.length
    const subject = t('bulk.subject', { count: n })
    const busy = running !== null

    const go = async (fn: (item: BulkItem) => Promise<Act>) => {
        const batch = chosen
        setResults([])
        setRunning({ done: 0, total: batch.length })
        const out = await runOneAtATime(batch, fn, {
            thrownReason: t('bulk.thrown'),
            onProgress: (done, total) => setRunning({ done, total }),
        })
        setRunning(null)
        setResults(out)
        onSelectedChange(new Set())
        router.refresh()
    }

    if (items.length === 0 && results.length === 0) return null
    const done = results.filter((r) => r.done).length

    return (
        <div data-slot="bulk-bar" className="rounded border border-gray-300 bg-gray-50 p-3 space-y-2 text-sm">
            <div className="flex flex-wrap items-center gap-3">
                {showSelectAll && items.length > 0 && (
                    <label className="flex items-center gap-2">
                        <SelectAllCheckbox
                            total={items.length}
                            selected={n}
                            onChange={() => onSelectedChange(toggleAllOnScreen(items, selected))}
                            label={t('bulk.selectAllOnScreen')}
                        />
                        <span>{t('bulk.selectAllOnScreen')}</span>
                    </label>
                )}
                <span data-bulk-count={n}>{t('bulk.selectedCount', { count: n })}</span>
                {approve && (
                    <ConfirmButton
                        subject={subject}
                        title={approve.title}
                        body={approve.body ?? t('bulk.approveBody')}
                        confirmLabel={t('bulk.approve', { count: n })}
                        tier="default"
                        triggerVariant="default"
                        triggerSize="sm"
                        disabled={busy || n === 0}
                        onConfirm={() => { void go(approve.act) }}
                    >
                        {t('bulk.approve', { count: n })}
                    </ConfirmButton>
                )}
                <ConfirmButton
                    subject={subject}
                    title={reject.title}
                    body={reject.body ?? t('bulk.rejectBody')}
                    confirmLabel={t('bulk.reject', { count: n })}
                    tier="destructive"
                    triggerVariant="destructive"
                    triggerSize="sm"
                    reason={{ placeholder: reject.placeholder }}
                    disabled={busy || n === 0}
                    onConfirm={(reason) => { void go((item) => reject.act(item, reason)) }}
                >
                    {t('bulk.reject', { count: n })}
                </ConfirmButton>
                {running && (
                    <span role="status">{t('bulk.running', { done: running.done, total: running.total })}</span>
                )}
            </div>
            <p className="text-xs text-[color:var(--brand-muted-text)]">{t('bulk.hint')}</p>

            {results.length > 0 && (
                <div data-slot="bulk-results" role="status" aria-live="polite">
                    <p className="font-medium">{t('bulk.resultHeadline', { done, refused: results.length - done })}</p>
                    <ul className="mt-1 space-y-1">
                        {results.map((r) => (
                            <li key={r.id} data-bulk-item={r.label} data-bulk-done={r.done ? 'true' : 'false'}
                                className={r.done ? 'text-green-800' : 'text-red-800'}>
                                <span className="font-mono">{r.label}</span>
                                {' — '}
                                {r.done ? t('bulk.itemDone') : t('bulk.itemRefused', { reason: r.reason ?? '' })}
                                {!r.done && r.detail && (
                                    <details className="ml-4 text-xs text-[color:var(--brand-muted-text)]">
                                        <summary className="cursor-pointer">{t('common.actionMessage.technicalDetail')}</summary>
                                        <span className="break-all">{r.detail}</span>
                                    </details>
                                )}
                            </li>
                        ))}
                    </ul>
                    <Button type="button" variant="link" size="xs" className="mt-1 px-0" onClick={() => setResults([])}>{t('bulk.dismiss')}</Button>
                </div>
            )}
        </div>
    )
}

/** 卡片清单上每一张卡片的那一枚勾选框。 */
export function BulkCheck({ label, checked, onChange, disabled }: {
    label: string
    checked: boolean
    onChange: () => void
    disabled?: boolean
}) {
    const t = useTranslations()
    return (
        <label className="inline-flex items-center">
            <input
                type="checkbox"
                checked={checked}
                onChange={onChange}
                disabled={disabled}
                aria-label={t('bulk.selectItem', { label })}
                data-bulk-check={label}
                className={`${CONTROL_CHECKBOX} w-4 base-pressable`}
            />
        </label>
    )
}

// ── 服务端页面上的表格清单(过磅草稿):勾选框画在服务端造好的格子里,与条子共享一份选中状态 ──
// 页面把这一段包进 <BulkScope>;格子里放 <BulkScopeCheck>;条子用 <BulkScopeBar>,单项动作(一个 server action)原样交进来。
type Scope = { selected: Set<string>; setSelected: (s: Set<string>) => void }
const BulkScopeCtx = React.createContext<Scope | null>(null)

export function BulkScope({ children }: { children: React.ReactNode }) {
    const [selected, setSelected] = React.useState<Set<string>>(new Set())
    return <BulkScopeCtx.Provider value={{ selected, setSelected }}>{children}</BulkScopeCtx.Provider>
}

export function BulkScopeCheck({ id, label, disabled }: { id: string; label: string; disabled?: boolean }) {
    const ctx = React.useContext(BulkScopeCtx)
    if (!ctx) throw new Error('BULK_SCOPE_MISSING|BulkScopeCheck 要放在 <BulkScope> 里面')
    const { selected, setSelected } = ctx
    return (
        <BulkCheck label={label} checked={selected.has(id)} disabled={disabled}
                   onChange={() => { const n = new Set(selected); if (n.has(id)) n.delete(id); else n.add(id); setSelected(n) }} />
    )
}

export function BulkScopeBar({ items, reject }: {
    items: readonly BulkItem[]
    reject: { title: string; placeholder: string; action: (id: string, reason: string) => Promise<Act> }
}) {
    const ctx = React.useContext(BulkScopeCtx)
    if (!ctx) throw new Error('BULK_SCOPE_MISSING|BulkScopeBar 要放在 <BulkScope> 里面')
    return (
        <BulkDecisionBar
            items={items}
            selected={ctx.selected}
            onSelectedChange={ctx.setSelected}
            reject={{ title: reject.title, placeholder: reject.placeholder, act: (i, reason) => reject.action(i.id, reason) }}
        />
    )
}
