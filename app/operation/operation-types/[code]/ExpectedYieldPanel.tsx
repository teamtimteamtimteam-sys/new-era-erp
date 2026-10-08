'use client'

// MES-5b-1(2026-10-08,V37;MES-5b Step 0 Q15,Tim):这道工序每一种产出形态的【预期质量得率】(占一炉总投入的 %)。
//   空 = Not yet set(Tim 与工艺工程师在试车之后给)。只标不拒 —— 得率页把低于它的一炉、一道工序的一个月标出来。
//   改要 module.processing.edit(与容差同一个码);没有它的人:输入框看得见、按不动,旁边说出缺哪个码(PermissionGate,DBLOCK-1)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { setExpectedYield } from '../actions'

export type ExpectedYieldRow = { form: string; label: string; expected: string | null }

export default function ExpectedYieldPanel({ code, rows, canEdit }: { code: string; rows: ExpectedYieldRow[]; canEdit: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [values, setValues] = useState<Record<string, string>>(Object.fromEntries(rows.map((r) => [r.form, r.expected ?? ''])))
    const [error, setError] = useState<{ form: string; text: string } | null>(null)

    function save(form: string) {
        setError(null)
        startTransition(async () => {
            const res = await setExpectedYield(code, form, values[form] ?? '')
            if (res.error) setError({ form, text: res.error })
            else router.refresh()
        })
    }

    return (
        <section data-section="expected-yield" className="mt-8">
            <h2 className="mb-1">{t('massBalance.opType.title')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('massBalance.opType.intro')}</p>
            <PermissionGate code="module.processing.edit" allowed={canEdit}>
                <ul className="space-y-2">
                    {rows.map((r) => (
                        <li key={r.form} className="flex flex-wrap items-end gap-3" data-expected-form={r.form}>
                            <label className="block">
                                <span className="block text-sm mb-1">{r.label}</span>
                                <span className="inline-flex items-center gap-1">
                                    <input type="number" min="0" max="100" step="any" value={values[r.form] ?? ''} placeholder={t('massBalance.opType.notSet')}
                                           onChange={(e) => setValues({ ...values, [r.form]: e.target.value })} className={`${CONTROL_INPUT} w-28`} />
                                    <span>%</span>
                                </span>
                            </label>
                            <Button type="button" disabled={pending} onClick={() => save(r.form)}>{t('massBalance.opType.save')}</Button>
                            {r.expected === null && <span className="text-sm text-amber-700">{t('massBalance.opType.notSet')}</span>}
                            {error?.form === r.form && <p className="w-full text-sm text-red-700">{error.text}</p>}
                        </li>
                    ))}
                </ul>
            </PermissionGate>
        </section>
    )
}
