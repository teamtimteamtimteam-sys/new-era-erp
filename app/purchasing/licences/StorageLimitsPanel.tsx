'use client'

// MES-3a(2026-10-06,MES-0 Q32 · V2;MES-3a Step 0 Q6 · Q12,Tim):每一张执照对每一类 NEA 废物的库存上限(吨)。
//   一格一类;空着 = "上限没给"(V2)—— 收货照收、在收货单上记 ceiling_not_set,而不是"没有上限"。
//   执照自己那一行的「批准的贮存上限」是【总上限】(所有有类别的存量之和),在上面那张表里改。
//   类别列表本身从 /settings/dictionaries 来(V29);一个类别都没有时,这一块说出来,不画一张空表。
//   写:module.suppliers.edit(与执照同一个码);没码看得见、按不动、说出那个码(PermissionGate)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { saveStorageLimit, removeStorageLimit } from './licenceActions'

export type StorageCategory = { code: string; label: string }
export type StorageLimit = { id: string; licence_id: string; category_code: string; limit_tonnes: number }
export type StorageLicence = { id: string; label: string; total: number | null }

export default function StorageLimitsPanel({ licences, categories, limits, canEdit }: {
    licences: StorageLicence[]
    categories: StorageCategory[]
    limits: StorageLimit[]
    canEdit: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [draft, setDraft] = useState<Record<string, string>>({})
    const keyOf = (l: string, c: string) => `${l}|${c}`
    const current = new Map(limits.map((x) => [keyOf(x.licence_id, x.category_code), x]))

    function save(licenceId: string, categoryCode: string) {
        setError(null)
        start(async () => {
            const r = await saveStorageLimit({ licenceId, categoryCode, limitTonnes: draft[keyOf(licenceId, categoryCode)] ?? '' })
            if (r.error) { setError(r.error); return }
            router.refresh()
        })
    }
    function remove(id: string) {
        setError(null)
        start(async () => {
            const r = await removeStorageLimit(id)
            if (r.error) { setError(r.error); return }
            router.refresh()
        })
    }

    return (
        <section className="mt-8 max-w-3xl" data-storage-limits={limits.length}>
            <h2 className="mb-1">{t('company.licence.limits.title')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">{t('company.licence.limits.intro')}</p>
            {error && <p className="text-red-600 text-xs mb-2">{error}</p>}
            {categories.length === 0 ? (
                <p className="text-sm border border-amber-300 bg-amber-50 text-amber-800 rounded px-3 py-2" data-no-categories="1">
                    {t('company.licence.limits.noCategories')}
                </p>
            ) : licences.length === 0 ? (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{t('company.licence.limits.noLicence')}</p>
            ) : licences.map((lic) => (
                <div key={lic.id} className="mb-4">
                    <h3 className="text-sm font-medium mb-1">{lic.label}</h3>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">
                        {lic.total === null ? t('company.licence.limits.totalNotSet') : t('company.licence.limits.total', { t: String(lic.total) })}
                    </p>
                    <ul className="space-y-2 text-sm">
                        {categories.map((c) => {
                            const k = keyOf(lic.id, c.code)
                            const cur = current.get(k)
                            return (
                                <li key={c.code} className="flex flex-wrap items-center gap-2">
                                    <span className="min-w-[12rem]">{c.label}</span>
                                    <span className={cur ? '' : 'text-amber-700'} data-limit={cur ? String(cur.limit_tonnes) : 'not-set'}>
                                        {cur ? t('company.licence.limits.value', { t: String(cur.limit_tonnes) }) : t('company.licence.limits.notSet')}
                                    </span>
                                    <PermissionGate code="module.suppliers.edit" allowed={canEdit} inline>
                                        <span className="inline-flex flex-wrap items-center gap-2">
                                            <input type="number" min="0" step="any" inputMode="decimal"
                                                   aria-label={t('company.licence.limits.inputLabel', { category: c.label })}
                                                   value={draft[k] ?? ''} placeholder={cur ? String(cur.limit_tonnes) : ''}
                                                   onChange={(e) => setDraft((d) => ({ ...d, [k]: e.target.value }))}
                                                   className={`${CONTROL_INPUT} w-28`} />
                                            <Button size="xs" type="button" disabled={pending || (draft[k] ?? '').trim() === ''}
                                                    onClick={() => save(lic.id, c.code)}>
                                                {t('common.save')}
                                            </Button>
                                            {cur && (
                                                <Button size="xs" variant="outline" type="button" disabled={pending} onClick={() => remove(cur.id)}>
                                                    {t('company.licence.limits.clear')}
                                                </Button>
                                            )}
                                        </span>
                                    </PermissionGate>
                                </li>
                            )
                        })}
                    </ul>
                </div>
            ))}
        </section>
    )
}
