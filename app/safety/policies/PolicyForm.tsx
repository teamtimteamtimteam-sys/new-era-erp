'use client'

// ESG-2(Tim 2026-10-31 Q9 · Q10):制度登记簿的表单 —— 登记一份新制度,或给一份现行的制度登记一个新版本(它取代旧的那一版)。
//   门 action.manage_esg(admin · cco · cfo);规矩在库里(company_policy_record)。日期都必填、不给默认(AGENTS.md)。
//   文件只写「在哪里」(一句文字),不上传(Q10)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { recordPolicy } from '../esgActions'

export type CurrentPolicy = { id: string; title: string; version: string; ownerId: string }
export type OwnerOption = { id: string; label: string }

export default function PolicyForm({ current, owners, canManage }: { current: CurrentPolicy[]; owners: OwnerOption[]; canManage: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [supersedes, setSupersedes] = useState('')
    const [title, setTitle] = useState('')
    const [version, setVersion] = useState('')
    const [owner, setOwner] = useState('')
    const [effective, setEffective] = useState('')
    const [review, setReview] = useState('')
    const [doc, setDoc] = useState('')
    const [bad, setBad] = useState(false)
    const [error, setError] = useState('')

    function pick(id: string) {
        setSupersedes(id)
        const p = current.find((x) => x.id === id)
        if (p) { setTitle(p.title); setOwner(p.ownerId) }
    }
    function save() {
        setError('')
        start(async () => {
            const r = await recordPolicy({ supersedesId: supersedes || null, title, version, ownerId: owner, effective, review, documentRef: doc })
            if (r.error) { setError(r.error); return }
            setSupersedes(''); setTitle(''); setVersion(''); setOwner(''); setEffective(''); setReview(''); setDoc('')
            router.refresh()
        })
    }

    return (
        <section className="mt-8 space-y-2 max-w-3xl" data-section="policy-form" aria-label={t('esg.policies.formTitle')}>
            <h2 className="mb-1">{t('esg.policies.formTitle')}</h2>
            <PermissionGate code="action.manage_esg" allowed={canManage} wrap>
                <div className="space-y-2" data-form="policy">
                    <label className="block text-sm">
                        <span className="block mb-1">{t('esg.policies.supersedes')}</span>
                        <select value={supersedes} onChange={(e) => pick(e.target.value)} className={`${CONTROL_SELECT} max-w-full`} data-field="supersedes">
                            <option value="">{t('esg.policies.newPolicy')}</option>
                            {current.map((p) => <option key={p.id} value={p.id}>{p.title} — {p.version}</option>)}
                        </select>
                    </label>
                    <div className="flex flex-wrap items-end gap-2">
                        <label className="block text-sm min-w-0 flex-1 basis-64">
                            <span className="block mb-1">{t('esg.policies.colTitle')} <span className="text-red-600">*</span></span>
                            <input type="text" value={title} onChange={(e) => setTitle(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="title" />
                        </label>
                        <label className="block text-sm">
                            <span className="block mb-1">{t('esg.policies.colVersion')} <span className="text-red-600">*</span></span>
                            <input type="text" value={version} onChange={(e) => setVersion(e.target.value)} className={`${CONTROL_INPUT} w-28`} data-field="version" />
                        </label>
                        <label className="block text-sm min-w-0 basis-64">
                            <span className="block mb-1">{t('esg.policies.colOwner')} <span className="text-red-600">*</span></span>
                            <select value={owner} onChange={(e) => setOwner(e.target.value)} className={`${CONTROL_SELECT} max-w-full`} data-field="owner">
                                <option value="">—</option>
                                {owners.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
                            </select>
                        </label>
                    </div>
                    <div className="flex flex-wrap items-end gap-2">
                        <div className="text-sm">
                            <span className="block mb-1">{t('esg.policies.colEffective')} <span className="text-red-600">*</span></span>
                            <DatePicker value={effective} onChange={setEffective} onInvalidChange={setBad} />
                        </div>
                        <div className="text-sm">
                            <span className="block mb-1">{t('esg.policies.colReview')} <span className="text-red-600">*</span></span>
                            <DatePicker value={review} onChange={setReview} onInvalidChange={setBad} />
                        </div>
                    </div>
                    <label className="block text-sm">
                        <span className="block mb-1">{t('esg.policies.colDocument')} <span className="text-red-600">*</span></span>
                        <input type="text" value={doc} onChange={(e) => setDoc(e.target.value)} className={`${CONTROL_INPUT} w-full`} placeholder={t('esg.policies.documentHint')} data-field="document" />
                    </label>
                    <Button type="button" disabled={pending || bad || !title.trim() || !version.trim() || !owner || !effective || !review || !doc.trim()} onClick={save}>
                        {supersedes ? t('esg.policies.saveVersion') : t('esg.policies.save')}
                    </Button>
                    {error && <p className="text-sm text-red-600" data-error="policy">{error}</p>}
                </div>
            </PermissionGate>
        </section>
    )
}
