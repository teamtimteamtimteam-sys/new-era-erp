'use client'

// DICT-ADMIN:一张字典的一小节。共用的六个字段写在这里【一遍】;
// 额外那几列由 registry 声明,连同它们各自的那一句解释。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { addDictValue, updateDictValue, setDictActive } from './actions'
import type { DictSpec } from './registry'

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

    return (
        <section className="mb-8">
            <div className="flex items-baseline gap-3 mb-2">
                <h2 className="text-lg font-medium">{t(spec.titleKey)}</h2>
                <button type="button" onClick={openNew} disabled={pending}
                        className="border border-gray-400 px-2 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                    {t('dict.add')}
                </button>
                <span className="text-xs text-gray-500">{t('dict.gatedBy', { 0: spec.permission })}</span>
            </div>
            {error && <p className="text-red-600 text-xs mb-2">{error}</p>}

            <table className="w-full border-collapse text-sm">
                <thead>
                    <tr className="bg-gray-50">
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('dict.f.code')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('dict.f.name')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-right">{t('dict.f.sortOrder')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-right">{t('dict.inUse')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('dict.f.isActive')}</th>
                        <th className="border border-gray-300 px-2 py-1"></th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => (
                        <tr key={r.code} className={r.is_active ? '' : 'bg-gray-50 text-gray-500'}>
                            <td className="border border-gray-300 px-2 py-1 font-mono text-xs">{r.code}</td>
                            <td className="border border-gray-300 px-2 py-1">{label(r)}</td>
                            <td className="border border-gray-300 px-2 py-1 text-right font-mono">{r.sort_order}</td>
                            {/* D4:**停用之前先看见有多少行带着它。** */}
                            <td className="border border-gray-300 px-2 py-1 text-right font-mono">{usage[r.code] ?? 0}</td>
                            <td className="border border-gray-300 px-2 py-1">
                                {r.is_active ? t('dict.active') : t('dict.inactive')}
                            </td>
                            <td className="border border-gray-300 px-2 py-1 whitespace-nowrap">
                                <button type="button" onClick={() => openEdit(r)} disabled={pending}
                                        className="border border-gray-300 px-2 py-0.5 rounded text-xs hover:bg-gray-50 mr-1 disabled:opacity-50">
                                    {t('common.edit')}
                                </button>
                                <button type="button" disabled={pending}
                                        onClick={() => {
                                            // 【D2/D4:停用之前把那个数说出来,并说清它【不是】删除】
                                            if (r.is_active && !window.confirm(
                                                t('dict.confirmDeactivate',
                                                  { 0: r.code, 1: String(usage[r.code] ?? 0) }))) return
                                            run(() => setDictActive({ table: spec.table, code: r.code, active: !r.is_active }))
                                        }}
                                        className="border border-gray-300 px-2 py-0.5 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                                    {r.is_active ? t('dict.deactivate') : t('dict.reactivate')}
                                </button>
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>

            {editing && (
                <div className="mt-3 border border-gray-300 rounded p-3 space-y-2 max-w-2xl">
                    <div className="grid grid-cols-2 gap-3">
                        <label className="block">
                            <span className="text-xs text-gray-600 block">{t('dict.f.code')}</span>
                            <input value={f.code} disabled={editing !== '__new__'}
                                   onChange={(e) => setF({ ...f, code: e.target.value })}
                                   className="border border-gray-300 px-2 py-1 rounded text-sm w-full disabled:bg-gray-100 font-mono" />
                            {/* 【D6:建好之后 code 不能改 —— 说出来,不要只是灰掉】
                                改 code 等于改外键指向,那是一次数据迁移,不是一次编辑。 */}
                            <span className="text-xs text-gray-500">
                                {editing === '__new__' ? t('dict.h.codeNew') : t('dict.h.codeLocked')}
                            </span>
                        </label>
                        <label className="block">
                            <span className="text-xs text-gray-600 block">{t('dict.f.sortOrder')}</span>
                            <input type="number" value={f.sortOrder}
                                   onChange={(e) => setF({ ...f, sortOrder: e.target.value })}
                                   className="border border-gray-300 px-2 py-1 rounded text-sm w-full" />
                            {/* D5:顺序是数据 —— PROC-4 量过不设它的后果。 */}
                            <span className="text-xs text-gray-500">{t('dict.h.sortOrder')}</span>
                        </label>
                        <label className="block">
                            <span className="text-xs text-gray-600 block">{t('dict.f.nameEn')}</span>
                            <input value={f.nameEn} onChange={(e) => setF({ ...f, nameEn: e.target.value })}
                                   className="border border-gray-300 px-2 py-1 rounded text-sm w-full" />
                        </label>
                        <label className="block">
                            <span className="text-xs text-gray-600 block">{t('dict.f.nameZh')}</span>
                            <input value={f.nameZh} onChange={(e) => setF({ ...f, nameZh: e.target.value })}
                                   className="border border-gray-300 px-2 py-1 rounded text-sm w-full" />
                        </label>
                    </div>

                    {/* ── 这张字典【自己】那几列 —— 由 registry 声明,各带一句解释 ── */}
                    {spec.extras.map((x) => (
                        <div key={x.column}>
                            {x.kind === 'boolean' ? (
                                <div>
                                    <span className="text-xs text-gray-600 block">{t(x.labelKey)}</span>
                                    {/* 【必填的规则布尔用三态下拉,不用裸勾选框】
                                        一个没勾的勾选框读起来是"否",而那可能只是"还没决定"——
                                        本仓库反复付账的正是这个区别。 */}
                                    <select value={extras[x.column] ?? ''}
                                            onChange={(e) => setExtras({ ...extras, [x.column]: e.target.value })}
                                            className="border border-gray-300 px-2 py-1 rounded text-sm">
                                        <option value="" disabled>{t('dict.pickYesNo')}</option>
                                        <option value="true">{t('common.yes')}</option>
                                        <option value="false">{t('common.no')}</option>
                                    </select>
                                    {/* 【规则开关必须带句子】—— may_be_fed 拦的是起火。 */}
                                    <p className="text-xs text-gray-600 mt-1">{t(x.hintKey)}</p>
                                </div>
                            ) : (
                                <label className="block">
                                    <span className="text-xs text-gray-600 block">{t(x.labelKey)}</span>
                                    <input value={extras[x.column] ?? ''}
                                           onChange={(e) => setExtras({ ...extras, [x.column]: e.target.value })}
                                           className="border border-gray-300 px-2 py-1 rounded text-sm" />
                                    <span className="text-xs text-gray-500">{t(x.hintKey)}</span>
                                </label>
                            )}
                        </div>
                    ))}

                    <label className="block">
                        <span className="text-xs text-gray-600 block">{t('dict.f.notes')}</span>
                        <input value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })}
                               className="border border-gray-300 px-2 py-1 rounded text-sm w-full" />
                    </label>

                    <div className="flex gap-2 items-center">
                        <button type="button" disabled={pending}
                                onClick={() => run(() => (editing === '__new__' ? addDictValue : updateDictValue)({
                                    table: spec.table, code: f.code, nameEn: f.nameEn, nameZh: f.nameZh,
                                    sortOrder: f.sortOrder, notes: f.notes, extras,
                                }))}
                                className="border border-gray-600 bg-gray-800 text-white px-3 py-1 rounded text-xs disabled:opacity-50">
                            {pending ? t('common.saving') : t('common.save')}
                        </button>
                        <button type="button" disabled={pending}
                                onClick={() => { setEditing(null); setError(null) }}
                                className="border border-gray-400 px-3 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                            {t('common.cancel')}
                        </button>
                    </div>
                </div>
            )}
        </section>
    )
}
