'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { createFxRate, type CreateFxRateState } from './actions'
import FxRateFormFields from '../FxRateFormFields'
import { useTranslations } from '@/lib/i18n/client'

const initialState: CreateFxRateState = {}

// 本地日期(YYYY-MM-DD),用作汇率日期默认值(避免 UTC 偏移)。
function todayIsoLocal(): string {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
}

export default function NewFxRateForm({ currencies }: { currencies: string[] }) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createFxRate, initialState)

    return (
        <>
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                <FxRateFormFields
                    currencies={currencies}
                    fieldErrors={state.fieldErrors}
                    defaults={{ rate_date: todayIsoLocal() }}
                />

                <div className="flex gap-3 pt-4">
                    <button
                        type="submit"
                        disabled={isPending}
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                    >
                        {isPending ? t('common.saving') : t('common.save')}
                    </button>
                    <Link
                        href="/finance/fx"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </>
    )
}
