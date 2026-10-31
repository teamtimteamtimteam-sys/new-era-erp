'use client'

// ESG-2(Tim 2026-10-31 Q14):给一件举报追加一个状态(收到确认 · 调查中 · 结案),带一句说明。追加,不改、不删;结案之后不再收(库按名拒)。
//   能打开这一页的人就读得到这一件,所以也写得了(同一个判据 whistleblowing_report_readable)—— 这里不另判。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { addReportUpdate } from '../../esgActions'
import { WB_UPDATE_STATUSES, wbStatusKey } from '../whistleblowingTypes'

export default function ReportUpdateForm({ reportId }: { reportId: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [status, setStatus] = useState('')
    const [note, setNote] = useState('')
    const [error, setError] = useState('')
    function save() {
        setError('')
        start(async () => {
            const r = await addReportUpdate(reportId, status, note)
            if (r.error) { setError(r.error); return }
            setStatus(''); setNote('')
            router.refresh()
        })
    }
    return (
        <div className="space-y-2 max-w-3xl mt-4" data-form="report-update">
            <label className="block text-sm">
                <span className="block mb-1">{t('esg.whistleblowing.newStatus')} <span className="text-red-600">*</span></span>
                <select value={status} onChange={(e) => setStatus(e.target.value)} className={CONTROL_SELECT} data-field="status">
                    <option value="">—</option>
                    {WB_UPDATE_STATUSES.map((s) => <option key={s} value={s}>{t(wbStatusKey(s))}</option>)}
                </select>
            </label>
            <label className="block text-sm">
                <span className="block mb-1">{t('esg.whistleblowing.note')} <span className="text-red-600">*</span></span>
                <textarea value={note} onChange={(e) => setNote(e.target.value)} rows={3} className={`${CONTROL_TEXTAREA} w-full`} data-field="note" />
            </label>
            <Button type="button" disabled={pending || !status || !note.trim()} onClick={save}>{t('esg.whistleblowing.addUpdate')}</Button>
            {error && <p className="text-sm text-red-600" data-error="report-update">{error}</p>}
        </div>
    )
}
