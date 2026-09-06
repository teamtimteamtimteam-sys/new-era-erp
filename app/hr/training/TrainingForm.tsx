'use client'

// 培训记录表单(新建/编辑共用)。从员工档案页进来时员工已预选并锁定 ——
// 那一步的意图很明确,不该再给一次选错人的机会。
import { useActionState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { TRAINING_CATEGORY_OPTIONS } from '../options'
import { saveTraining, type TrainingFormState } from './actions'
import { Button } from '@/app/components/ui/button'

const initialState: TrainingFormState = {}

export type EmployeeOption = { id: string; label: string }

export default function TrainingForm({
    record,
    employees,
    lockedEmployeeId,
    returnTo,
}: {
    record?: {
        id: string
        employee_id: string
        training_name: string
        category: string | null
        completed_date: string
        expiry_date: string | null
        provider: string | null
        certificate_ref: string | null
        notes: string | null
    }
    employees: EmployeeOption[]
    lockedEmployeeId?: string
    returnTo?: string
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(saveTraining, initialState)

    const selectedEmployee = record?.employee_id ?? lockedEmployeeId ?? ''
    const locked = !!lockedEmployeeId && !record

    const label = 'block text-sm font-medium mb-1'
    const field = 'w-full border border-gray-300 px-3 py-2 rounded'

    return (
        <form action={formAction} className="space-y-4 max-w-3xl">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            {record && <input type="hidden" name="training_id" value={record.id} />}
            {returnTo && <input type="hidden" name="return_to" value={returnTo} />}
            {locked && <input type="hidden" name="employee_id" value={selectedEmployee} />}

            <div className="flex flex-wrap gap-4">
                <div className="flex-1 min-w-[16rem]">
                    <label className={label}>
                        {t('hr.colEmployee')} <span className="text-red-600">*</span>
                    </label>
                    {locked ? (
                        <p className="border border-gray-200 bg-gray-100 px-3 py-2 rounded">
                            {employees.find((e) => e.id === selectedEmployee)?.label ?? '—'}
                        </p>
                    ) : (
                        <select
                            name="employee_id"
                            required
                            defaultValue={selectedEmployee}
                            className={field}
                        >
                            <option value="" disabled>
                                —
                            </option>
                            {employees.map((e) => (
                                <option key={e.id} value={e.id}>
                                    {e.label}
                                </option>
                            ))}
                        </select>
                    )}
                </div>
                <div className="flex-1 min-w-[16rem]">
                    <label className={label}>
                        {t('hr.colTrainingName')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="training_name"
                        required
                        defaultValue={record?.training_name ?? ''}
                        className={field}
                    />
                </div>
            </div>

            <div className="flex flex-wrap gap-4">
                <div>
                    <label className={label}>{t('hr.colCategory')}</label>
                    <select
                        name="category"
                        defaultValue={record?.category ?? ''}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">—</option>
                        {TRAINING_CATEGORY_OPTIONS.map((o) => (
                            <option key={o.value} value={o.value}>
                                {t(o.labelKey)}
                            </option>
                        ))}
                    </select>
                </div>
                <div>
                    <label className={label}>
                        {t('hr.colCompletedDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="completed_date"
                        required
                        defaultValue={record?.completed_date ?? ''}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div>
                    <label className={label}>{t('hr.colExpiryDate')}</label>
                    <input
                        type="date"
                        name="expiry_date"
                        defaultValue={record?.expiry_date ?? ''}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                    <p className="text-xs text-gray-500 mt-1">{t('hr.expiryHint')}</p>
                </div>
            </div>

            <div className="flex flex-wrap gap-4">
                <div className="flex-1 min-w-[14rem]">
                    <label className={label}>{t('hr.colProvider')}</label>
                    <input
                        type="text"
                        name="provider"
                        defaultValue={record?.provider ?? ''}
                        className={field}
                    />
                </div>
                <div className="flex-1 min-w-[14rem]">
                    <label className={label}>{t('hr.colCertificateRef')}</label>
                    <input
                        type="text"
                        name="certificate_ref"
                        defaultValue={record?.certificate_ref ?? ''}
                        className={field}
                    />
                </div>
            </div>

            <div>
                <label className={label}>{t('hr.colNotes')}</label>
                <textarea name="notes" rows={2} defaultValue={record?.notes ?? ''} className={field} />
            </div>

            <div className="flex gap-3 pt-2">
                <Button
                    type="submit"
                    disabled={isPending}
                >
                    {isPending ? t('common.saving') : t('common.save')}
                </Button>
                <Button asChild variant="secondary">
                    <Link
                        href={returnTo || '/hr/training'}
                    >
                        {t('common.cancel')}
                    </Link>
                </Button>
            </div>
        </form>
    )
}
