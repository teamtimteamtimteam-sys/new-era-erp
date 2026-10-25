'use client'

// 加工成本条目面板。只在【已提交】的加工单上渲染(页面决定)。
// 底部一个共用表单:editingId 为空 = 新增,非空 = 编辑该行(表单按 key 重挂载以带入默认值)。
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { formatMoneyBare } from '@/lib/format'
import { COST_TYPE_OPTIONS, costTypeLabelKey, type CostEntryRow } from './costTypes'
import { addCostEntry, updateCostEntry, softDeleteCostEntry } from './costActions'
import { MaskedValue } from '@/app/components/MaskedValue'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xMasked, xMoney, xText, xTime } from '@/lib/export/cells'
import { Button } from '@/app/components/ui/button'
import { CONTROL_CHECKBOX, CONTROL_SELECT, CONTROL_INPUT } from '@/app/components/ui/control-style'

/**
 * TABLE-EXPORT-3c(Tim 2026-10-25):导出要【原始】的创建时刻(屏幕上 created_at_display 是排好的字)。
 * 只在这张面板上加,不动 costTypes.ts 里共用的 CostEntryRow。
 */
export type CostPanelRow = CostEntryRow & { created_at: string }

export default function CostPanel({
    runId,
    runCode,
    entries,
    canViewPrices,
}: {
    runId: string
    /** TABLE-EXPORT-3c:导出的 About 表写这一炉的单号 */
    runCode: string
    entries: CostPanelRow[]
    /** cut 2b:当前登录者是否持有 data.view_prices。为 false 时金额显示「受限」。 */
    canViewPrices: boolean
}) {
    const t = useTranslations()
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()
    const [editingId, setEditingId] = useState<string | null>(null)
    const [formKey, setFormKey] = useState(0) // 成功后 +1,重挂表单以清空

    const typeLabel = (v: string) => {
        const k = costTypeLabelKey(v)
        return k ? t(k) : v
    }

    // cut 2b:任何一条金额被遮蔽,合计就无从算起 —— 此时整个合计显示「受限」,
    // 而不是把 null 当 0 加进去(那会得出一个看起来像真的、其实偏小的数)。
    const anyMasked = entries.some((e) => e.amount_base === null)
    const total = anyMasked ? null : entries.reduce((s, e) => s + (e.amount_base ?? 0), 0)
    const editing = editingId ? entries.find((e) => e.id === editingId) ?? null : null

    // ★ TABLE-EXPORT-3c(Tim 2026-10-25):一对导出。
    //   种类一格旁边的「(估)」改变这一行的意思(估计数,不是实际)—— 照 BatchDetail 的先例附在种类后面。
    //   金额:与 <MaskedValue> 同一条判据(xMasked);币种写在列头「金额 (SGD)」里,格子是光秃秃的数 —— 与屏幕一样。
    //   创建一格叠着创建时刻与「改于 X · 谁」那一行 —— 导出写主值:创建时刻(真的日期格)。
    //     改动的时刻与人在页底审计记录里;这一行的金额本来就是【现在】的值。
    //   动作列(改 / 删)是控件,不导出。表下面那一行合计是 <p>,不是表里的行 —— 不进文件(TABLE-EXPORT-1 Q12)。
    const costColumns: ExportableColumn<CostPanelRow>[] = [
        {
            key: 'type',
            header: t('processing.cost.colType'),
            // 身份列:一条成本条目的主语是「哪一种成本」。
            priority: true,
            render: (e) => (
                <>
                    {typeLabel(e.cost_type)}
                    {e.is_estimate && (
                        <span className="text-amber-600 text-xs ml-1">{t('processing.cost.estimateTag')}</span>
                    )}
                </>
            ),
            exportAs: (e) => xText(e.is_estimate ? `${typeLabel(e.cost_type)} ${t('processing.cost.estimateTag')}` : typeLabel(e.cost_type)),
        },
        {
            key: 'amount',
            header: t('processing.cost.colAmount'),
            align: 'right',
            // ★ 这张表被打开的理由:这一笔【多少钱】。
            priority: true,
            className: 'text-sm',
            render: (e) => (
                <MaskedValue value={e.amount_base} canView={canViewPrices}
                             format={(v) => formatMoneyBare(v, '列头「金额 (SGD)」')} />
            ),
            exportAs: (e) => xMasked(e.amount_base, canViewPrices, (v) => xMoney(v)),
        },
        { key: 'notes', header: t('processing.cost.colNotes'), className: 'text-sm', render: (e) => e.notes ?? '—', exportAs: (e) => xText(e.notes) },
        {
            key: 'created', header: t('processing.cost.colCreated'), className: 'text-sm text-gray-600',
            render: (e) => (
                <>
                    {e.created_at_display}
                    {/* 改过就说出来 —— 只显示创建日期会让改后的数字看着像原值 */}
                    {e.edited_at_display && (
                        <span className="block text-xs text-amber-700">
                            {t('processing.cost.editedAt', { at: e.edited_at_display })}
                            {e.edited_by_name ? ` · ${e.edited_by_name}` : ''}
                        </span>
                    )}
                </>
            ),
            exportAs: (e) => xTime(e.created_at),
        },
        {
            key: 'actions',
            header: t('processing.cost.colActions'),
            className: 'whitespace-nowrap',
            exportAs: false,
            render: (e) => (
                <>
                    <Button variant="link" size="inline" type="button"
                            onClick={() => { setEditingId(e.id); setError(null) }}
                            disabled={isPending}>
                        {t('processing.cost.edit')}
                    </Button>
                    <span className="mx-2 text-gray-300">|</span>
                    {/* CONFIRM-1:主语用【身份列】那一格的字 —— 成本种类,有备注就带上备注。
                        ★ 金额【刻意不放进主语】:它走 MaskedValue + canViewPrices,
                          把它拼进对话框会绕过那道遮罩,对没有看价权限的人泄一个数。 */}
                    <ConfirmButton
                        subject={e.notes ? `${typeLabel(e.cost_type)} · ${e.notes}` : typeLabel(e.cost_type)}
                        title={t('processing.cost.deleteConfirm')}
                        body={t('common.softDeleteNote')}
                        details={
                            <p className="text-sm font-medium text-[color:var(--brand-text)]">
                                {t('processing.cost.deleteConsequence')}
                            </p>
                        }
                        confirmLabel={t('common.delete')}
                        tier="destructive"
                        disabled={isPending}
                        triggerVariant="destructive" triggerSize="inline"
                        onConfirm={() => handleDelete(e.id)}
                    >
                        {t('common.delete')}
                    </ConfirmButton>
                </>
            ),
        },
    ]

    function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
        e.preventDefault()
        const fd = new FormData(e.currentTarget)
        setError(null)
        startTransition(async () => {
            const result = editingId
                ? await updateCostEntry(editingId, fd)
                : await addCostEntry(runId, fd)
            if (result?.error) {
                setError(result.error)
                return
            }
            setEditingId(null)
            setFormKey((k) => k + 1)
        })
    }

    function handleDelete(id: string) {
        setError(null)
        startTransition(async () => {
            const result = await softDeleteCostEntry(id)
            if (result?.error) setError(result.error)
            else if (editingId === id) setEditingId(null)
        })
    }

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="mb-4">{t('processing.cost.title')}</h2>

            {error && <p className="text-red-600 text-sm mb-3">{error}</p>}

            {/* ★ CONV-10:转换前这张表被 {entries.length > 0 && …} 整个包着 ——
                一条成本都没有时【整张表连同表头一起消失】,而空态由表外一句
                「合计:0」隐晦地说。现在表【无条件】画,空态由表自己说
                (与 CONV-9 给 /hr/employees/[id] 绩效表的修法同向)。
                ☞ 每行的「改 / 删」是【自成一体的格内控件】,状态(editingId)归本面板,
                   表单在表【下面】—— 所以它留在 DataTable,不是 EditableTable。
                   CONV-8 §④ 那条判据:问的是【谁持有状态】,不是有没有 <button>。 */}
            <div className="mb-4">
                <DataTable
                    rows={entries}
                    columns={costColumns}
                    rowKey={(e) => e.id}
                    phone={{ mode: 'columns' }}
                    rowClassName={(e) => (editingId === e.id ? 'bg-blue-50' : undefined)}
                    empty={t('processing.cost.empty')}
                    exportSpec={{
                        name: 'processing-run-cost-entries',
                        title: t('processing.cost.title'),
                        aboutExtra: [[t('processing.colCode'), runCode]],
                    }}
                />
            </div>

            {/* 合计 */}
            <p className="text-sm mb-4">
                <span className="text-[color:var(--brand-muted-text)] mr-1">{t('processing.cost.sumLabel')}:</span>
                <span>
                    <MaskedValue
                        value={total}
                        canView={canViewPrices}
                        format={(v) => formatMoneyBare(v, '上表列头「金额 (SGD)」—— 合计就是那一列的和')}
                    />
                </span>
            </p>

            {/* 新增 / 编辑表单(共用) */}
            <h3 className="mb-2">
                {editing ? t('processing.cost.editTitle') : t('processing.cost.addTitle')}
            </h3>
            <form
                key={editingId ?? `new-${formKey}`}
                onSubmit={handleSubmit}
                className="flex flex-wrap gap-2 items-start"
            >
                <select
                    name="cost_type"
                    required
                    defaultValue={editing?.cost_type ?? ''}
                    className={CONTROL_SELECT}
                >
                    <option value="" disabled>{t('processing.cost.selectType')}</option>
                    {COST_TYPE_OPTIONS.map((o) => (
                        <option key={o.value} value={o.value}>
                            {t(o.labelKey)}
                        </option>
                    ))}
                </select>
                <input
                    type="number"
                    name="amount_base"
                    step="0.01"
                    required
                    defaultValue={editing?.amount_base ?? ''}
                    placeholder={t('processing.cost.amountPlaceholder')}
                    className={`${CONTROL_INPUT} w-32`}
                />
                <label className="flex items-center gap-1 px-1 py-2">
                    <input
                        type="checkbox"
                        className={CONTROL_CHECKBOX}
                        name="is_estimate"
                        defaultChecked={editing?.is_estimate ?? false}
                    />
                    {t('processing.cost.estimateLabel')}
                </label>
                <input
                    type="text"
                    name="notes"
                    defaultValue={editing?.notes ?? ''}
                    placeholder={t('processing.cost.notesPlaceholder')}
                    className={`${CONTROL_INPUT} flex-1 min-w-[8rem]`}
                />
                <Button
                    type="submit"
                    disabled={isPending}
                >
                    {t('processing.cost.save')}
                </Button>
                {editing && (
                    <Button variant="secondary"
                        type="button"
                        onClick={() => {
                            setEditingId(null)
                            setError(null)
                        }}
                        disabled={isPending}>
                        {t('common.cancel')}
                    </Button>
                )}
            </form>
        </section>
    )
}
