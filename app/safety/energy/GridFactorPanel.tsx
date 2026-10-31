'use client'

// ESG-2(Tim 2026-10-31 Q1 · Q2 · Q9):能耗强度页上的电网排放因子 —— 每一年现在用的那一个版本(与它的出处),换过的版本照直列出;
//   一张表单设某一年的因子(那一年已经有了 = 更正,理由必填 —— 库按名拒)。门 action.manage_esg(admin · cco · cfo):
//   不持的人看得见表单、按不动、说出缺哪个码(DBLOCK-1)。值的单位写死 kg CO2/kWh(EMA 的因子只含 CO2)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { setGridFactor } from '../esgActions'

export type FactorVersion = { id: number; year: number; value: string; source: string; reason: string | null; line: string; current: boolean }

export default function GridFactorPanel({ versions, canManage, defaultYear }: { versions: FactorVersion[]; canManage: boolean; defaultYear: number }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [year, setYear] = useState(String(defaultYear))
    const [value, setValue] = useState('')
    const [source, setSource] = useState('')
    const [reason, setReason] = useState('')
    const [error, setError] = useState('')
    const yearHasOne = versions.some((v) => String(v.year) === year.trim())

    function save() {
        setError('')
        start(async () => {
            const r = await setGridFactor({ year, value, source, reason })
            if (r.error) { setError(r.error); return }
            setValue(''); setSource(''); setReason('')
            router.refresh()
        })
    }

    return (
        <section className="mt-8 space-y-3" data-section="grid-factor" aria-label={t('esg.energy.factorTitle')}>
            <h2 className="mb-1">{t('esg.energy.factorTitle')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] max-w-3xl">{t('esg.energy.factorIntro')}</p>
            {versions.length === 0 ? (
                <p className="text-sm font-medium text-amber-900" data-factor-none="1">{t('esg.energy.factorNone')}</p>
            ) : (
                <ul className="divide-y divide-[color:var(--brand-border)] border-y border-[color:var(--brand-border)] text-sm">
                    {versions.map((v) => (
                        <li key={v.id} className="py-2 flex flex-wrap gap-x-4 gap-y-1" data-factor-year={v.year} data-factor-current={v.current ? '1' : '0'}>
                            <span className="font-medium tabular-nums">{v.year}</span>
                            <span className={v.current ? 'tabular-nums' : 'tabular-nums line-through text-[color:var(--brand-muted-text)]'}>{v.value} kg CO2/kWh</span>
                            <span className="min-w-0 break-words">{v.source}</span>
                            {v.reason && <span className="text-[color:var(--brand-muted-text)] min-w-0 break-words">{t('esg.energy.factorReason', { reason: v.reason })}</span>}
                            <span className="text-xs text-[color:var(--brand-muted-text)] w-full">{v.line}</span>
                        </li>
                    ))}
                </ul>
            )}
            <PermissionGate code="action.manage_esg" allowed={canManage} wrap>
                <div className="space-y-2 max-w-3xl" data-form="grid-factor">
                    <div className="flex flex-wrap items-end gap-2">
                        <label className="block text-sm">
                            <span className="block mb-1">{t('esg.energy.factorYear')} <span className="text-red-600">*</span></span>
                            <input type="number" inputMode="numeric" min={2000} max={2100} value={year} onChange={(e) => setYear(e.target.value)} className={`${CONTROL_INPUT} w-28`} data-field="year" />
                        </label>
                        <label className="block text-sm">
                            <span className="block mb-1">{t('esg.energy.factorValue')} <span className="text-red-600">*</span></span>
                            <input type="number" inputMode="decimal" step="0.0001" min={0} value={value} onChange={(e) => setValue(e.target.value)} className={`${CONTROL_INPUT} w-36`} data-field="value" />
                        </label>
                        <label className="block text-sm min-w-0 flex-1 basis-64">
                            <span className="block mb-1">{t('esg.energy.factorSource')} <span className="text-red-600">*</span></span>
                            <input type="text" value={source} onChange={(e) => setSource(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="source" />
                        </label>
                    </div>
                    {yearHasOne && (
                        <label className="block text-sm">
                            <span className="block mb-1">{t('esg.energy.factorCorrectionReason')} <span className="text-red-600">*</span></span>
                            <input type="text" value={reason} onChange={(e) => setReason(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="reason" />
                        </label>
                    )}
                    <Button type="button" disabled={pending || !year.trim() || !value.trim() || !source.trim() || (yearHasOne && !reason.trim())} onClick={save}>
                        {yearHasOne ? t('esg.energy.factorCorrect') : t('esg.energy.factorSave')}
                    </Button>
                    {error && <p className="text-sm text-red-600" data-error="grid-factor">{error}</p>}
                </div>
            </PermissionGate>
        </section>
    )
}
