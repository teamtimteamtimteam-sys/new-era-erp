'use client'

// PARTY-1:一个对手方的联系人【们】。同一个面板服务客户与供应商 ——
// 归属由 props 决定,而服务端函数按归属那一侧查权限。
//
// ★【它不是一方两身那个结构】★ 这个面板画的是【一边】的联系人。
//   它不把某个客户与某个供应商连起来 —— 那个问题的今天只有一份报告
//   (/sales/customers/overlap),没有结构上的答案。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { saveContact, removeContact } from './contactActions'

export type ContactRow = {
    id: string
    name: string
    name_inferred: boolean
    role: string | null
    email: string | null
    phone: string | null
    is_primary: boolean
    notes: string | null
}

const EMPTY = { name: '', role: '', email: '', phone: '', notes: '', isPrimary: false }

export default function ContactsPanel({ customerId, supplierId, rows, canEdit }: {
    customerId?: string
    supplierId?: string
    rows: ContactRow[]
    canEdit: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [editing, setEditing] = useState<string | null>(null)   // contact id or 'new'
    const [f, setF] = useState(EMPTY)

    // 【按不下去就把理由摆在旁边】—— 一个按不下去又不说为什么的按钮读起来像是坏了。
    const why = !f.name.trim() ? t('contacts.needName')
              : (!f.email.trim() && !f.phone.trim()) ? t('contacts.needReach')
              : ''

    function open(r?: ContactRow) {
        setError(null)
        setEditing(r?.id ?? 'new')
        setF(r ? { name: r.name, role: r.role ?? '', email: r.email ?? '',
                   phone: r.phone ?? '', notes: r.notes ?? '', isPrimary: r.is_primary }
               : EMPTY)
    }

    function submit() {
        setError(null)
        start(async () => {
            const res = await saveContact({
                customerId, supplierId,
                contactId: editing && editing !== 'new' ? editing : undefined,
                name: f.name, role: f.role, email: f.email, phone: f.phone,
                notes: f.notes, isPrimary: f.isPrimary,
            })
            if (res.error) { setError(res.error); return }
            setEditing(null); router.refresh()
        })
    }

    function drop(id: string) {
        setError(null)
        start(async () => {
            const res = await removeContact({ contactId: id, customerId, supplierId })
            if (res.error) { setError(res.error); return }
            router.refresh()
        })
    }

    return (
        <div>
            {error && <p className="text-sm text-red-700 mb-2">{error}</p>}
            {rows.length === 0 ? (
                /* 【具名的缺席,不是空白】为什么这里没有人,以及该做什么 */
                <p className="text-sm text-gray-600">{t('contacts.noneYet')}</p>
            ) : (
                <table className="w-full border-collapse mb-3">
                    <thead>
                        <tr className="bg-gray-100">
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contacts.colName')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contacts.colRole')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contacts.colEmail')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contacts.colPhone')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contacts.colPrimary')}</th>
                            {canEdit && <th className="border border-gray-300 px-3 py-2" />}
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.id}>
                                <td className="border border-gray-300 px-3 py-2 text-sm">
                                    {r.name}
                                    {/* 【这个名字是凑出来的,说出来】迁移时"有邮箱没名字"的那一支 */}
                                    {r.name_inferred && (
                                        <span className="ml-1 text-xs text-amber-700" title={t('contacts.inferredWhy')}>
                                            {t('contacts.inferredTag')}
                                        </span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{r.role ?? '—'}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm break-all">{r.email ?? '—'}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{r.phone ?? '—'}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">
                                    {r.is_primary
                                        ? <span className="text-xs bg-gray-800 text-white px-2 py-1 rounded">{t('contacts.primaryTag')}</span>
                                        : <span className="text-xs text-gray-400">—</span>}
                                </td>
                                {canEdit && (
                                    <td className="border border-gray-300 px-3 py-2 text-sm whitespace-nowrap">
                                        <button type="button" onClick={() => open(r)} disabled={pending}
                                                className="border border-gray-400 px-2 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                                            {t('common.edit')}
                                        </button>
                                        <button type="button" onClick={() => drop(r.id)} disabled={pending}
                                                className="ml-2 border border-gray-400 px-2 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                                            {t('contacts.remove')}
                                        </button>
                                    </td>
                                )}
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}

            {canEdit && editing === null && (
                <button type="button" onClick={() => open()} disabled={pending}
                        className="border border-gray-600 px-3 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                    {t('contacts.add')}
                </button>
            )}

            {canEdit && editing !== null && (
                <div className="border border-gray-400 rounded p-3 bg-gray-50 max-w-2xl">
                    <div className="grid grid-cols-2 gap-2">
                        <label className="text-xs">{t('contacts.colName')}
                            <input type="text" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })}
                                   className="block w-full border border-gray-300 rounded px-2 py-1 text-xs" />
                        </label>
                        <label className="text-xs">{t('contacts.colRole')}
                            <input type="text" value={f.role} onChange={(e) => setF({ ...f, role: e.target.value })}
                                   className="block w-full border border-gray-300 rounded px-2 py-1 text-xs" />
                        </label>
                        <label className="text-xs">{t('contacts.colEmail')}
                            <input type="text" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })}
                                   className="block w-full border border-gray-300 rounded px-2 py-1 text-xs" />
                        </label>
                        <label className="text-xs">{t('contacts.colPhone')}
                            <input type="text" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })}
                                   className="block w-full border border-gray-300 rounded px-2 py-1 text-xs" />
                        </label>
                        <label className="text-xs col-span-2">{t('contacts.colNotes')}
                            <input type="text" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })}
                                   className="block w-full border border-gray-300 rounded px-2 py-1 text-xs" />
                        </label>
                    </div>
                    <label className="flex items-center gap-2 mt-2 text-xs">
                        <input type="checkbox" checked={f.isPrimary}
                               onChange={(e) => setF({ ...f, isPrimary: e.target.checked })} />
                        {t('contacts.makePrimary')}
                    </label>
                    {/* 【主联系人会被开票快照读到 —— 按之前说出来】 */}
                    <p className="text-xs text-gray-600 mt-1">{t('contacts.primaryWhat')}</p>
                    <div className="flex gap-2 items-center mt-2">
                        <button type="button" disabled={pending || why !== ''} onClick={submit}
                                className="border border-gray-600 bg-gray-800 text-white px-3 py-1 rounded text-xs disabled:opacity-50">
                            {t('common.save')}
                        </button>
                        <button type="button" disabled={pending} onClick={() => { setEditing(null); setError(null) }}
                                className="border border-gray-400 px-3 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                            {t('common.cancel')}
                        </button>
                        {why && <span className="text-xs text-gray-600">{why}</span>}
                    </div>
                </div>
            )}
        </div>
    )
}
