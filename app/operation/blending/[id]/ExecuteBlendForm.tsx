'use client'

// MES-5b-3(MES-5b Step 0 Q18):从计划页上执行一份已放行的配料计划 —— 记一炉 blending(execute_blending_plan,经 commit_processing_run)。
//   每一行实际投了多少(预填计划的公斤数;可以不同,没用上写 0)、混出来那一批称了多少、加工日与开始 / 结束 / 班次。
//   【加工日、开始、结束、班次都不给默认值】它们决定这一炉落在哪一天、哪个班(FIN-10);空着不给按,服务端照样按名拒。
//   缺 action.processing_commit:整块在 PermissionGate 里,看得见、按不动、说出码。
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { executeBlendingPlan } from '../actions'

export type ExecLine = { lineId: string; batchCode: string; plannedKg: number }
export type ShiftOption = { code: string; name: string }

export default function ExecuteBlendForm({ id, lines, shifts, canExecute }: {
    id: string; lines: ExecLine[]; shifts: ShiftOption[]; canExecute: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [processDate, setProcessDate] = useState('')
    const [startedAt, setStartedAt] = useState('')
    const [endedAt, setEndedAt] = useState('')
    const [shiftCode, setShiftCode] = useState('')
    const [weight, setWeight] = useState('')
    const [actual, setActual] = useState<Record<string, string>>(() => Object.fromEntries(lines.map((l) => [l.lineId, String(l.plannedKg)])))

    const fed = lines.reduce((s, l) => s + (Number(actual[l.lineId]) || 0), 0)
    const ready = !!processDate && !!startedAt && !!endedAt && !!shiftCode && Number(weight) > 0 && fed > 0
        && lines.every((l) => actual[l.lineId] !== '' && Number(actual[l.lineId]) >= 0)

    function submit() {
        setError('')
        startTransition(async () => {
            const res = await executeBlendingPlan(id, {
                process_date: processDate, started_at: startedAt, ended_at: endedAt, shift_code: shiftCode,
                actual: lines.map((l) => ({ line_id: l.lineId, actual_kg: Number(actual[l.lineId]) })),
                weight_kg: Number(weight),
            })
            if (res?.error) { setError(res.error); return }
            router.refresh()
        })
    }

    return (
        <PermissionGate code="action.processing_commit" allowed={canExecute}>
            <div className="space-y-4" data-form="execute-blend">
                {error && <p className="text-sm text-red-600">{error}</p>}
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        <span className="block mb-1">{t('blending.exec.processDate')} <span className="text-red-600">*</span></span>
                        <DatePicker kind="date" required value={processDate} onChange={setProcessDate} className="flex" />
                    </label>
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        <span className="block mb-1">{t('blending.exec.shift')} <span className="text-red-600">*</span></span>
                        <select value={shiftCode} onChange={(e) => setShiftCode(e.target.value)} className={`${CONTROL_SELECT} w-full`}>
                            <option value="" disabled>{t('blending.exec.pickShift')}</option>
                            {shifts.map((s) => <option key={s.code} value={s.code}>{s.name}</option>)}
                        </select>
                    </label>
                </div>
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        <span className="block mb-1">{t('blending.exec.startedAt')} <span className="text-red-600">*</span></span>
                        <DatePicker kind="datetime" required value={startedAt} onChange={setStartedAt} className="flex" />
                    </label>
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        <span className="block mb-1">{t('blending.exec.endedAt')} <span className="text-red-600">*</span></span>
                        <DatePicker kind="datetime" required value={endedAt} onChange={setEndedAt} className="flex" />
                    </label>
                </div>
                <div>
                    <p className="text-sm font-semibold mb-1">{t('blending.exec.actual')}</p>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('blending.exec.actualWhy')}</p>
                    <div className="space-y-2">
                        {lines.map((l) => (
                            <div key={l.lineId} className="flex flex-wrap items-center gap-2" data-row="actual">
                                <span className="text-sm min-w-0 basis-full sm:basis-48">{l.batchCode}</span>
                                <span className="text-xs text-[color:var(--brand-muted-text)]">{t('blending.exec.planned', { kg: String(l.plannedKg) })}</span>
                                <input type="number" inputMode="decimal" min={0} step="any" value={actual[l.lineId] ?? ''}
                                       onChange={(e) => setActual({ ...actual, [l.lineId]: e.target.value })}
                                       className={`${CONTROL_INPUT} w-32`} aria-label={t('blending.exec.actualKg', { batch: l.batchCode })} />
                            </div>
                        ))}
                    </div>
                </div>
                <label className="block text-sm">
                    <span className="block mb-1">{t('blending.exec.weight')} <span className="text-red-600">*</span></span>
                    <input type="number" inputMode="decimal" min={0} step="any" value={weight} onChange={(e) => setWeight(e.target.value)}
                           className={`${CONTROL_INPUT} w-40`} />
                    <span className="block mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('blending.exec.weightWhy')}</span>
                </label>
                <div className="flex flex-wrap items-center gap-3">
                    <Button type="button" disabled={isPending || !ready} onClick={submit}>
                        {isPending ? t('common.saving') : t('blending.exec.submit')}
                    </Button>
                    {!ready && !isPending && <span className="text-xs text-[color:var(--brand-muted-text)]">{t('blending.exec.needs')}</span>}
                </div>
            </div>
        </PermissionGate>
    )
}
