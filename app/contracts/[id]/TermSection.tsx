'use client'

// TERMS-EDIT-1(Tim 2026-09-27,grilling Q1 · Q2 · Q6):合同的一张条款表 —— 一张表、每行一个 编辑 / 删除,下面一张新增的表单。
//
// 【按不动的两种理由,分开说】
//   · 没有 action.contract_terms → <PermissionGate> 说出那个码(DBLOCK-1:看得见、按不动、带理由);
//   · 有码,但这份合同此刻不许改(生效中 / 在等 CFO / 到期 / 终止)或这一段是卖方条款而这是买方合同(Q6)
//     → blockedReason:页面算好的一句话,画在段首,控件一律 disabled。**不混成一个布尔**
//     (AGENTS.md「Never gate on a boolean that mixes permission with record state」)。
// 【值与显示分开传】服务端把每一格摊平成显示用的字(字典名、枚举标签)与表单用的原值,这里不再翻译字典。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { AddRowPanel } from '@/app/components/ui/add-row-panel'
import { Refusal } from '@/app/components/ui/refusal'
import { showActionMessage } from '@/app/components/ui/action-message'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xNum, xText, xRestricted, type ExportCell } from '@/lib/export/cells'
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import PpmReadout from '@/app/components/metals/PpmReadout'
import type { SubstanceRole } from '@/lib/substances'
import { saveTermRow, deleteTermRow, type EditResult } from './actions'

export type TermFieldView = {
    name: string
    label: string
    type: 'text' | 'number' | 'integer' | 'select' | 'boolean' | 'textarea'
    required: boolean
    options?: { value: string; label: string }[]
    min?: number
    max?: number
    defaultValue?: string
    /** MES-6b-1(F7 · Q18):旁边实时带 ppm —— 当同一张表单里 roleOf 那一格选的物质在 roles 里是惩罚元素时 */
    ppmBeside?: { roleOf: string; roles: Record<string, SubstanceRole> }
}

export type TermRowView = {
    id: string
    /** 表格里显示的字(已翻译) */
    shown: Record<string, string>
    /** 编辑表单的原值 */
    values: Record<string, string>
    /** GOLIVE-1 第 12 行(Tim Q9):这一行里画「受限」的格(价格格,读者不持这份合同那一侧的价格码)。有它的行不给编辑 ——
     *  表单里那一格只会是空白,存下去就是拿一个空值盖掉看不见的数。删除照旧(删的是整行,不是那个数)。 */
    restricted?: string[]
}

export default function TermSection({
    contractId, contractCode, table, title, hint, fields, rows, canWrite, blockedReason, onePerContract,
}: {
    contractId: string
    contractCode: string
    table: string
    title: string
    hint: string
    fields: TermFieldView[]
    rows: TermRowView[]
    canWrite: boolean
    /** null = 此刻改得了;否则是那一句理由 */
    blockedReason: string | null
    onePerContract: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [editing, setEditing] = useState<string | null>(null)
    const [result, setResult] = useState<{ key: string; r: EditResult } | null>(null)
    // MES-6b-1(F7):表单是非受控的;ppm 那一格要读正在打的值,所以按表单记下【改过的】几格(没改过的读初值)
    const [live, setLive] = useState<Record<string, Record<string, string>>>({})
    const blocked = blockedReason !== null
    const subject = `${contractCode} · ${title}`

    function submit(rowId: string | null, form: HTMLFormElement) {
        const fd = new FormData(form)
        const key = rowId ?? 'new'
        start(async () => {
            const r = await saveTermRow(contractId, table, rowId, fd)
            if (r.error || r.fieldErrors) { setResult({ key, r }); return }
            setResult(null)
            setEditing(null)
            setLive((m) => ({ ...m, [key]: {} }))
            if (rowId === null) form.reset()
            router.refresh()
        })
    }

    function remove(rowId: string) {
        start(async () => {
            const r = await deleteTermRow(contractId, table, rowId)
            if (r.error) {
                showActionMessage({ subject, headline: t('common.actionMessage.headline.notDecided'), body: r.error, detail: r.detail })
                return
            }
            router.refresh()
        })
    }

    const form = (rowId: string | null, values: Record<string, string> | null) => {
        const key = rowId ?? 'new'
        const mine = result?.key === key ? result.r : null
        return (
            <form
                key={`${table}:${key}`}
                onSubmit={(e) => { e.preventDefault(); submit(rowId, e.currentTarget) }}
                onChange={(e) => {
                    const el = e.target as unknown as HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement
                    if (el.name) setLive((m) => ({ ...m, [key]: { ...m[key], [el.name]: el.value } }))
                }}
                data-term-form={`${table}:${key}`}
            >
                <AddRowPanel
                    title={rowId === null ? t('contractDetail.addRow') : t('contractDetail.editRow')}
                    error={mine?.error}
                    actions={
                        <>
                            <PermissionGate code="action.contract_terms" allowed={canWrite}>
                                <Button type="submit" disabled={pending || blocked}>
                                    {pending ? t('common.saving') : t('common.save')}
                                </Button>
                            </PermissionGate>
                            {rowId !== null && (
                                <Button type="button" variant="secondary" onClick={() => { setEditing(null); setResult(null) }}>
                                    {t('common.cancel')}
                                </Button>
                            )}
                        </>
                    }
                >
                    {fields.map((f) => {
                        const v = values?.[f.name] ?? f.defaultValue ?? ''
                        const now = (name: string) => live[key]?.[name] ?? values?.[name] ?? fields.find((x) => x.name === name)?.defaultValue ?? ''
                        const err = mine?.fieldErrors?.[f.name]
                        const id = `${table}-${key}-${f.name}`
                        const disabled = blocked || !canWrite
                        return (
                            <div key={f.name} className={f.type === 'textarea' ? 'min-w-64 flex-1' : 'min-w-40'}>
                                <label htmlFor={id} className="block mb-1 text-sm">
                                    {f.label}{f.required && <span className="text-red-600"> *</span>}
                                </label>
                                {f.type === 'select' || f.type === 'boolean' ? (
                                    <select id={id} name={f.name} defaultValue={v} disabled={disabled}
                                            className={`${CONTROL_SELECT} w-full`} aria-invalid={Boolean(err)}>
                                        <option value="">{t('contractDetail.choose')}</option>
                                        {(f.type === 'boolean'
                                            ? [{ value: 'true', label: t('contractDetail.yes') }, { value: 'false', label: t('contractDetail.no') }]
                                            : f.options ?? []
                                        ).map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
                                    </select>
                                ) : f.type === 'textarea' ? (
                                    <textarea id={id} name={f.name} defaultValue={v} disabled={disabled}
                                              className={`${CONTROL_TEXTAREA} w-full`} />
                                ) : (
                                    <input id={id} name={f.name} defaultValue={v} disabled={disabled}
                                           type={f.type === 'text' ? 'text' : 'number'}
                                           step={f.type === 'integer' ? 1 : 'any'}
                                           min={f.min} max={f.max}
                                           className={`${CONTROL_INPUT} w-full`} aria-invalid={Boolean(err)} />
                                )}
                                {f.ppmBeside && (
                                    <PpmReadout value={now(f.name)} role={f.ppmBeside.roles[now(f.ppmBeside.roleOf)]} />
                                )}
                                {err && <p className="text-red-600 text-xs mt-1">{err}</p>}
                            </div>
                        )
                    })}
                </AddRowPanel>
            </form>
        )
    }

    // TABLE-EXPORT-3c(Tim 2026-10-25):八张条款表各一对导出。Q3 当时:费率不遮蔽 —— ★ GOLIVE-1 第 12 行(Q9)起遮:受限的格写 "Restricted"(与屏幕同一个判据)。
    //   数(number / integer)从 values 里的原值写成数:惩罚条款的阈值与费率屏幕上旁边带着 ppm 等值
    //   (「0.5 %(5,000 ppm)」),导出只写主值 —— 那个以 % 存、以 % 录的原数;ppm 是从它换算出来的,不写。
    //   字典、枚举、是 / 否、文字:写屏幕上那串已经翻译好的字(shown)。空 = 没填 → 空格(屏幕上的「—」不写)。
    const cellOf = (f: TermFieldView, r: TermRowView): ExportCell =>
        r.restricted?.includes(f.name) ? xRestricted
        : f.type === 'number' || f.type === 'integer'
            ? xNum(r.values[f.name], f.type === 'integer' ? 'int' : 'qty')
            : xText(r.shown[f.name] || null)
    const columns: ExportableColumn<TermRowView>[] = [
        ...fields.map((f, i): ExportableColumn<TermRowView> => ({
            key: f.name,
            header: f.label,
            priority: i === 0,
            className: f.type === 'textarea' ? 'whitespace-pre-line break-words' : undefined,
            render: (r) => r.restricted?.includes(f.name) ? <Refusal>{t('common.restricted')}</Refusal> : r.shown[f.name] || '—',
            exportAs: (r) => cellOf(f, r),
        })),
        {
            key: 'actions', header: t('contractDetail.colActions'), priority: true,
            render: (r) => (
                <PermissionGate code="action.contract_terms" allowed={canWrite} inline>
                    <span className="inline-flex gap-2">
                        <Button type="button" size="sm" variant="outline" disabled={pending || blocked || Boolean(r.restricted?.length)}
                                title={r.restricted?.length ? t('contractDetail.editRestricted') : undefined}
                                onClick={() => { setEditing(r.id); setResult(null) }}>
                            {t('contractDetail.edit')}
                        </Button>
                        <ConfirmButton
                            subject={subject}
                            title={t('contractDetail.deleteConfirm')}
                            body={t('contractDetail.deleteBody')}
                            confirmLabel={t('contractDetail.delete')}
                            tier="destructive"
                            triggerVariant="outline"
                            triggerSize="sm"
                            disabled={pending || blocked}
                            onConfirm={() => remove(r.id)}
                        >
                            {t('contractDetail.delete')}
                        </ConfirmButton>
                    </span>
                </PermissionGate>
            ),
            // 编辑 / 删除两颗钮,不是数据
            exportAs: false,
        },
    ]

    const editingRow = rows.find((r) => r.id === editing) ?? null
    const canAddAnother = !(onePerContract && rows.length > 0)

    return (
        <section className="space-y-3" aria-label={title} data-contract-section={table}>
            <h2 className="mb-1">{title}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] max-w-4xl">{hint}</p>
            {blockedReason && (
                <p className="text-sm"><Refusal className="whitespace-normal text-left">{blockedReason}</Refusal></p>
            )}
            {rows.length === 0 ? (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{t('contractDetail.noneFiled')}</p>
            ) : (
                <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }}
                           // 名字用 contract-detail- 前缀:合同清单页已有 contract-pricing-terms / contract-settlement-terms 两张(全体合同),
                           //   这里是【一份合同】的那一段,文件名分得开;About 表写明是哪份合同
                           exportSpec={{ name: `contract-detail-${table.replace(/_/g, '-')}`, title,
                                         aboutExtra: [[t('contracts.colCode'), contractCode]] }} />
            )}
            {editingRow && form(editingRow.id, editingRow.values)}
            {canAddAnother
                ? form(null, null)
                : <p className="text-xs text-[color:var(--brand-muted-text)]">{t('contractDetail.onePerContract')}</p>}
        </section>
    )
}
