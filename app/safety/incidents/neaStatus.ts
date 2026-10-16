// MES-7b-1(MES-7b Step 0 Q10 · Q11):一件事故的 NEA 状态说成一句话 —— 清单与事故页同一句。
//   判据全部是库里算好的列(incident_rows 的 nea_reportable · notified_at · report_submitted_at · report_deadline · deadline_state ·
//   deadline_confirmed);这里只挑句子。期限没有确认(V19 未确认)时句子里带"未确认";算不出来、没有设定时不编日子。
import { formatDate } from '@/lib/dates'
import { deadlineStateKey } from '../safetyTypes'

type T = (key: string, params?: Record<string, string>) => string
type NeaRow = {
    nea_reportable: boolean; notified_at: string | null; report_submitted_at: string | null
    report_deadline: string | null; deadline_state: string; deadline_confirmed: boolean
}

export function deadlineLabel(t: T, locale: string, r: NeaRow): string {
    if (r.deadline_state === 'computed' && r.report_deadline) {
        const d = formatDate(r.report_deadline, locale)
        return r.deadline_confirmed ? t('safety.nea.deadlineConfirmed', { date: d }) : t('safety.nea.deadlineUnconfirmed', { date: d })
    }
    return t(deadlineStateKey(r.deadline_state))
}

export function neaStatusLabel(t: T, locale: string, r: NeaRow): string {
    if (!r.nea_reportable) return t('safety.nea.notReportable')
    if (!r.notified_at) return t('safety.nea.notifyDue')
    if (!r.report_submitted_at) return t('safety.nea.reportDue', { deadline: deadlineLabel(t, locale, r) })
    return t('safety.nea.done')
}
