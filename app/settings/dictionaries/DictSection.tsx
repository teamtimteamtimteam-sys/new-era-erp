'use client'

// DICT-ADMIN:一张字典的一小节。共用的六个字段写在这里【一遍】;
// 额外那几列由 registry 声明,连同它们各自的那一句解释。
//
// CONV-3 · 表本身换成 DataTable(只读 —— 编辑在下面那张表单里,不在格子里);
// 表单外壳换成 AddRowPanel(见该文件抬头:同一个盒子既管新增也管编辑复用)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { addDictValue, updateDictValue, setDictActive } from './actions'
import type { DictSpec } from './registry'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { AddRowPanel } from '@/app/components/ui/add-row-panel'

export type DictRow = {
    code: string; name_en: string; name_zh: string
    is_active: boolean; sort_order: number; notes: string | null
} & Record<string, unknown>

const blank = { code: '', nameEn: '', nameZh: '', sortOrder: '', notes: '' }

export default function DictSection({ spec, rows, usage, locale }: {
    spec: DictSpec
    rows: DictRow[]
    usage: Record<string, number>
    locale: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [editing, setEditing] = useState<string | null>(null)   // code | '__new__'
    const [f, setF] = useState({ ...blank })
    const [extras, setExtras] = useState<Record<string, string>>({})

    function run(fn: () => Promise<{ error?: string }>) {
        setError(null)
        start(async () => {
            const r = await fn()
            if (r.error) { setError(r.error); return }
            setEditing(null); setF({ ...blank }); setExtras({}); router.refresh()
        })
    }
    function openNew() {
        setF({ ...blank, sortOrder: String((rows.at(-1)?.sort_order ?? 0) + 1) })
        setExtras({}); setEditing('__new__')
    }
    function openEdit(r: DictRow) {
        setF({ code: r.code, nameEn: r.name_en, nameZh: r.name_zh,
               sortOrder: String(r.sort_order), notes: r.notes ?? '' })
        const e: Record<string, string> = {}
        for (const x of spec.extras) {
            const v = r[x.column]
            e[x.column] = x.kind === 'boolean' ? (v === true ? 'true' : v === false ? 'false' : '')
                                               : ((v as string | null) ?? '')
        }
        setExtras(e); setEditing(r.code)
    }

    const label = (r: DictRow) => (locale === 'zh' ? r.name_zh : r.name_en)

    // ★【手机上留哪两列】code 是外键指向的稳定标识,name 是人读的名字 ——
    // 两者一起才认得出"这是哪一条"。sort_order / inUse / isActive 是读到
    // 这一条之后才要问的东西,进展开区。
    const columns: Column<DictRow>[] = [
        { key: 'code', header: t('dict.f.code'), priority: true, className: 'font-mono text-xs', render: (r) => r.code },
        { key: 'name', header: t('dict.f.name'), priority: true, render: (r) => label(r) },
        { key: 'sortOrder', header: t('dict.f.sortOrder'), align: 'right', render: (r) => r.sort_order },
        // D4:停用之前先看见有多少行带着它。
        { key: 'inUse', header: t('dict.inUse'), align: 'right', render: (r) => usage[r.code] ?? 0 },
        { key: 'isActive', header: t('dict.f.isActive'), render: (r) => (r.is_active ? t('dict.active') : t('dict.inactive')) },
        {
            key: 'actions', header: '',
            render: (r) => (
                <>
                    <button type="button" onClick={() => openEdit(r)} disabled={pending}
                            className="mr-2 rounded border border-[color:var(--brand-border)] px-2 py-0.5 text-xs hover:bg-[color:var(--brand-muted)] disabled:opacity-50">
                        {t('common.edit')}
                    </button>
                    <button type="button" disabled={pending}
                            onClick={() => {
                                // 【D2/D4:停用之前把那个数说出来,并说清它【不是】删除】
                                if (r.is_active && !window.confirm(
                                    t('dict.confirmDeactivate', { 0: r.code, 1: String(usage[r.code] ?? 0) }))) return
                                run(() => setDictActive({ table: spec.table, code: r.code, active: !r.is_active }))
                            }}
                            className="rounded border border-[color:var(--brand-border)] px-2 py-0.5 text-xs hover:bg-[color:var(--brand-muted)] disabled:opacity-50">
                        {r.is_active ? t('dict.deactivate') : t('dict.reactivate')}
                    </button>
                </>
            ),
        },
    ]

    const field = 'rounded border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-2 py-1 text-sm w-full'
    const flabel = 'block text-xs font-medium text-[color:var(--brand-muted-text)] mb-1'

    return (
        <section className="mb-8">
            <div className="mb-2 flex items-baseline gap-3">
                <h2 className="text-lg font-medium">{t(spec.titleKey)}</h2>
                <button type="button" onClick={openNew} disabled={pending}
                        className="rounded border border-[color:var(--brand-border)] px-2 py-1 text-xs hover:bg-[color:var(--brand-muted)] disabled:opacity-50">
                    {t('dict.add')}
                </button>
                <span className="text-xs text-[color:var(--brand-muted-text)]">{t('dict.gatedBy', { 0: spec.permission })}</span>
            </div>

            <div className="mb-3">
                <DataTable
                    rows={rows}
                    columns={columns}
                    rowKey={(r) => r.code}
                    phone={{ mode: 'columns' }}
                />
            </div>
            {/* 表格自己的错误(空态)与表单的错误是两回事 —— 表单错误画在
                AddRowPanel 里,不在这里再重复一份。 */}

            {editing && (
                <AddRowPanel
                    error={error}
                    className="max-w-2xl"
                    actions={
                        <>
                            <button type="button" disabled={pending}
                                    onClick={() => run(() => (editing === '__new__' ? addDictValue : updateDictValue)({
                                        table: spec.table, code: f.code, nameEn: f.nameEn, nameZh: f.nameZh,
                                        sortOrder: f.sortOrder, notes: f.notes, extras,
                                    }))}
                                    className="rounded border border-[color:var(--brand-border)] bg-[color:var(--brand-text)] px-3 py-1 text-xs text-white disabled:opacity-50">
                                {pending ? t('common.saving') : t('common.save')}
                            </button>
                            <button type="button" disabled={pending}
                                    onClick={() => { setEditing(null); setError(null) }}
                                    className="rounded border border-[color:var(--brand-border)] px-3 py-1 text-xs hover:bg-[color:var(--brand-muted)] disabled:opacity-50">
                                {t('common.cancel')}
                            </button>
                        </>
                    }
                >
                    {/* ★ AddRowPanel 把 children 横排,而这里的字段需要成对分组 ——
                        用一个内层 grid 覆盖外层的 flex,布局与转换前逐字相同。 */}
                    <div className="grid w-full grid-cols-2 gap-3">
                        <label className="block">
                            <span className={flabel}>{t('dict.f.code')}</span>
                            <input value={f.code} disabled={editing !== '__new__'}
                                   onChange={(e) => setF({ ...f, code: e.target.value })}
                                   className={`${field} font-mono disabled:bg-[color:var(--brand-disabled-bg)]`} />
                            {/* 【D6:建好之后 code 不能改 —— 说出来,不要只是灰掉】 */}
                            <span className="text-xs text-[color:var(--brand-muted-text)]">
                                {editing === '__new__' ? t('dict.h.codeNew') : t('dict.h.codeLocked')}
                            </span>
                        </label>
                        <label className="block">
                            <span className={flabel}>{t('dict.f.sortOrder')}</span>
                            <input type="number" value={f.sortOrder}
                                   onChange={(e) => setF({ ...f, sortOrder: e.target.value })}
                                   className={field} />
                            <span className="text-xs text-[color:var(--brand-muted-text)]">{t('dict.h.sortOrder')}</span>
                        </label>
                        <label className="block">
                            <span className={flabel}>{t('dict.f.nameEn')}</span>
                            <input value={f.nameEn} onChange={(e) => setF({ ...f, nameEn: e.target.value })}
                                   className={field} />
                        </label>
                        <label className="block">
                            <span className={flabel}>{t('dict.f.nameZh')}</span>
                            <input value={f.nameZh} onChange={(e) => setF({ ...f, nameZh: e.target.value })}
                                   className={field} />
                        </label>

                        {/* ── 这张字典【自己】那几列 —— 由 registry 声明,各带一句解释 ── */}
                        {spec.extras.map((x) => (
                            <div key={x.column}>
                                {x.kind === 'boolean' ? (
                                    <div>
                                        <span className={flabel}>{t(x.labelKey)}</span>
                                        {/* 【必填的规则布尔用三态下拉,不用裸勾选框】 */}
                                        <select value={extras[x.column] ?? ''}
                                                onChange={(e) => setExtras({ ...extras, [x.column]: e.target.value })}
                                                className={field}>
                                            <option value="" disabled>{t('dict.pickYesNo')}</option>
                                            <option value="true">{t('common.yes')}</option>
                                            <option value="false">{t('common.no')}</option>
                                        </select>
                                        <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">{t(x.hintKey)}</p>
                                    </div>
                                ) : (
                                    <label className="block">
                                        <span className={flabel}>{t(x.labelKey)}</span>
                                        <input value={extras[x.column] ?? ''}
                                               onChange={(e) => setExtras({ ...extras, [x.column]: e.target.value })}
                                               className={field} />
                                        <span className="text-xs text-[color:var(--brand-muted-text)]">{t(x.hintKey)}</span>
                                    </label>
                                )}
                            </div>
                        ))}

                        <label className="block">
                            <span className={flabel}>{t('dict.f.notes')}</span>
                            <input value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })}
                                   className={field} />
                        </label>
                    </div>
                </AddRowPanel>
            )}
        </section>
    )
}
