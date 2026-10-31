'use client'

// ESG-2(Tim 2026-10-31 Q11 – Q13):/me 上「提出一个关切」与「我提出的关切」。
//   交:标题、内容、「这件事涉及 CCO 吗」(必须答)—— 保密,不是匿名(Q12):表单照直说交的人是谁会被读者看见,以及谁会读到。
//   我提出的:只有标题、交的那一天、现在的状态与它的时刻(my_concerns —— 读者写的说明不给,Q13)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { CONTROL_INPUT, CONTROL_TEXTAREA, CONTROL_RADIO } from '@/app/components/ui/control-style'
import { fileConcern } from './concernActions'

export type MyConcern = { id: string; subject: string; received: string; statusLabel: string; statusAt: string; concernsCco: boolean }

export default function RaiseConcernPanel({ mine }: { mine: MyConcern[] }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [open, setOpen] = useState(false)
    const [subject, setSubject] = useState('')
    const [details, setDetails] = useState('')
    const [concerns, setConcerns] = useState<boolean | null>(null)
    const [error, setError] = useState('')
    const [sent, setSent] = useState(false)

    function send() {
        setError('')
        start(async () => {
            const r = await fileConcern({ subject, details, concernsCco: concerns })
            if (r.error) { setError(r.error); return }
            setSubject(''); setDetails(''); setConcerns(null); setOpen(false); setSent(true)
            router.refresh()
        })
    }

    return (
        <section className="mb-6 rounded border border-[color:var(--brand-border)] p-4" data-section="raise-concern" aria-label={t('me.concern.title')}>
            <h2 className="mb-1">{t('me.concern.title')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] max-w-2xl">{t('me.concern.intro')}</p>
            {sent && <p className="text-sm mt-2 font-medium" data-concern-sent="1">{t('me.concern.sent')}</p>}
            {!open ? (
                <Button type="button" variant="outline" className="mt-3" onClick={() => { setOpen(true); setSent(false) }} data-open="raise-concern">{t('me.concern.open')}</Button>
            ) : (
                <div className="space-y-2 mt-3 max-w-2xl" data-form="raise-concern">
                    <p className="text-sm rounded border border-amber-300 bg-amber-50 px-3 py-2 text-amber-900" data-confidential="1">{t('me.concern.confidential')}</p>
                    <label className="block text-sm">
                        <span className="block mb-1">{t('esg.whistleblowing.subject')} <span className="text-red-600">*</span></span>
                        <input type="text" value={subject} onChange={(e) => setSubject(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="subject" />
                    </label>
                    <label className="block text-sm">
                        <span className="block mb-1">{t('esg.whistleblowing.details')} <span className="text-red-600">*</span></span>
                        <textarea value={details} onChange={(e) => setDetails(e.target.value)} rows={5} className={`${CONTROL_TEXTAREA} w-full`} data-field="details" />
                    </label>
                    <fieldset className="text-sm" data-field="concerns-cco">
                        <legend className="mb-1">{t('me.concern.concernsCco')} <span className="text-red-600">*</span></legend>
                        <div className="flex flex-wrap gap-x-4">
                            <label className="inline-flex items-center gap-2">
                                <input type="radio" className={CONTROL_RADIO} name="concerns-cco" checked={concerns === false} onChange={() => setConcerns(false)} />
                                {t('esg.whistleblowing.concernsNo')}
                            </label>
                            <label className="inline-flex items-center gap-2">
                                <input type="radio" className={CONTROL_RADIO} name="concerns-cco" checked={concerns === true} onChange={() => setConcerns(true)} />
                                {t('esg.whistleblowing.concernsYes')}
                            </label>
                        </div>
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('me.concern.whoReads')}</p>
                    </fieldset>
                    <div className="flex flex-wrap gap-2">
                        <Button type="button" disabled={pending || !subject.trim() || !details.trim() || concerns === null} onClick={send}>{t('me.concern.send')}</Button>
                        <Button type="button" variant="outline" onClick={() => setOpen(false)}>{t('common.cancel')}</Button>
                    </div>
                    {error && <p className="text-sm text-red-600" data-error="raise-concern">{error}</p>}
                </div>
            )}
            {mine.length > 0 && (
                <div className="mt-4" data-my-concerns={mine.length}>
                    <h3 className="text-sm font-medium mb-1">{t('me.concern.mineTitle')}</h3>
                    <ul className="divide-y divide-[color:var(--brand-border)] border-y border-[color:var(--brand-border)] text-sm">
                        {mine.map((c) => (
                            <li key={c.id} className="py-2 flex flex-wrap gap-x-4 gap-y-1">
                                <span className="min-w-0 break-words font-medium">{c.subject}</span>
                                <span>{c.received}</span>
                                <span data-concern-status="1">{c.statusLabel}</span>
                                <span className="text-xs text-[color:var(--brand-muted-text)]">{c.statusAt}</span>
                            </li>
                        ))}
                    </ul>
                </div>
            )}
        </section>
    )
}
