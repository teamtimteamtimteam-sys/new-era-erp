'use client'

// ESG-2(Tim 2026-10-31 Q11 · Q12 · Q13):读者登记一件在系统之外收到的举报。举报人的名字空着 = 匿名来源(Q12 —— 只有这里会出现「匿名来源」)。
//   「涉及 CCO」只给持 data.view_whistleblowing_escalated 的人勾:一个登记了就再也读不到的人不该是登记它的人(库同样按名拒)。
//   收到日必填、不给默认(AGENTS.md)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA, CONTROL_RADIO } from '@/app/components/ui/control-style'
import { recordOutsideReport } from '../esgActions'
import { WB_RECEIVED_VIA, wbViaKey } from './whistleblowingTypes'

export default function OutsideReportForm({ canPlain, canEscalated }: { canPlain: boolean; canEscalated: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [receivedOn, setReceivedOn] = useState('')
    const [via, setVia] = useState('')
    const [name, setName] = useState('')
    const [subject, setSubject] = useState('')
    const [details, setDetails] = useState('')
    // 只持其中一个码的读者只有一个选项:那一个就是答案(没持的那一边库也会拒)
    const only = canPlain && !canEscalated ? false : !canPlain && canEscalated ? true : null
    const [concerns, setConcerns] = useState<boolean | null>(only)
    const [bad, setBad] = useState(false)
    const [error, setError] = useState('')

    function save() {
        setError('')
        start(async () => {
            const r = await recordOutsideReport({ receivedOn, receivedVia: via, reporterName: name, subject, details, concernsCco: concerns })
            if (r.error) { setError(r.error); return }
            setReceivedOn(''); setVia(''); setName(''); setSubject(''); setDetails(''); setConcerns(only)
            router.refresh()
        })
    }

    return (
        <section className="mt-8 space-y-2 max-w-3xl" data-section="outside-report" aria-label={t('esg.whistleblowing.outsideTitle')}>
            <h2 className="mb-1">{t('esg.whistleblowing.outsideTitle')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)]">{t('esg.whistleblowing.outsideIntro')}</p>
            <div className="space-y-2" data-form="outside-report">
                <div className="flex flex-wrap items-end gap-2">
                    <div className="text-sm">
                        <span className="block mb-1">{t('esg.whistleblowing.colReceived')} <span className="text-red-600">*</span></span>
                        <DatePicker value={receivedOn} onChange={setReceivedOn} onInvalidChange={setBad} />
                    </div>
                    <label className="block text-sm">
                        <span className="block mb-1">{t('esg.whistleblowing.receivedVia')} <span className="text-red-600">*</span></span>
                        <select value={via} onChange={(e) => setVia(e.target.value)} className={CONTROL_SELECT} data-field="via">
                            <option value="">—</option>
                            {WB_RECEIVED_VIA.map((v) => <option key={v} value={v}>{t(wbViaKey(v))}</option>)}
                        </select>
                    </label>
                    <label className="block text-sm min-w-0 flex-1 basis-64">
                        <span className="block mb-1">{t('esg.whistleblowing.reporterName')}</span>
                        <input type="text" value={name} onChange={(e) => setName(e.target.value)} className={`${CONTROL_INPUT} w-full`} placeholder={t('esg.whistleblowing.reporterNameHint')} data-field="reporter" />
                    </label>
                </div>
                <label className="block text-sm">
                    <span className="block mb-1">{t('esg.whistleblowing.subject')} <span className="text-red-600">*</span></span>
                    <input type="text" value={subject} onChange={(e) => setSubject(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="subject" />
                </label>
                <label className="block text-sm">
                    <span className="block mb-1">{t('esg.whistleblowing.details')} <span className="text-red-600">*</span></span>
                    <textarea value={details} onChange={(e) => setDetails(e.target.value)} rows={4} className={`${CONTROL_TEXTAREA} w-full`} data-field="details" />
                </label>
                <fieldset className="text-sm" data-field="concerns-cco">
                    <legend className="mb-1">{t('esg.whistleblowing.concernsCco')} <span className="text-red-600">*</span></legend>
                    <div className="flex flex-wrap gap-x-4">
                        <label className="inline-flex items-center gap-2">
                            <input type="radio" className={CONTROL_RADIO} name="outside-concerns" checked={concerns === false} disabled={!canPlain} onChange={() => setConcerns(false)} />
                            {t('esg.whistleblowing.concernsNo')}
                        </label>
                        <label className="inline-flex items-center gap-2">
                            <input type="radio" className={CONTROL_RADIO} name="outside-concerns" checked={concerns === true} disabled={!canEscalated} onChange={() => setConcerns(true)} />
                            {t('esg.whistleblowing.concernsYes')}
                        </label>
                    </div>
                    {(!canPlain || !canEscalated) && (
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1" data-concerns-hint="1">
                            {t('esg.whistleblowing.concernsOnlyHint', { code: canPlain ? 'data.view_whistleblowing_escalated' : 'data.view_whistleblowing' })}
                        </p>
                    )}
                </fieldset>
                <Button type="button" disabled={pending || bad || !receivedOn || !via || !subject.trim() || !details.trim() || concerns === null} onClick={save}>
                    {t('esg.whistleblowing.outsideSave')}
                </Button>
                {error && <p className="text-sm text-red-600" data-error="outside-report">{error}</p>}
            </div>
        </section>
    )
}
