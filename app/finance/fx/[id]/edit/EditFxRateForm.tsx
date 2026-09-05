'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { updateFxRate, type UpdateFxRateState } from './actions'
import FxRateFormFields from '../../FxRateFormFields'
import DeleteButton from './DeleteButton'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

const initialState: UpdateFxRateState = {}

type FxRate = {
    id: string
    currency: string
    rate_type: string
    rate_sgd_per_unit: number
    source: string
    rate_date: string
    notes: string | null
}

export default function EditFxRateForm({
    rate,
    currencies,
}: {
    rate: FxRate
    currencies: string[]
}) {
    const t = useTranslations()
    const updateWithId = updateFxRate.bind(null, rate.id)
    const [state, formAction, isPending] = useActionState(updateWithId, initialState)

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
                    defaults={{
                        currency: rate.currency,
                        rate_type: rate.rate_type,
                        rate_sgd_per_unit: rate.rate_sgd_per_unit,
                        source: rate.source,
                        rate_date: rate.rate_date,
                        notes: rate.notes,
                    }}
                />

                <div className="flex items-center gap-3 pt-4">
                    {/* FX-RATES-1:改一条已在册的牌价必须说明理由 —— 它会连同【改之前是什么】

                         一起进 fx_rate_history。这不是礼貌,是"我们那天用的哪个数"的唯一答案。*/}

                    <div className="mb-4">

                        <label htmlFor="reason" className="block text-sm font-medium mb-1">

                            {t('finance.fxPage.form.reason')}

                        </label>

                        <input

                            id="reason"

                            name="reason"

                            type="text"

                            required

                            placeholder={t('finance.fxPage.form.reasonPlaceholder')}

                            className="border border-gray-300 rounded px-2 py-1 w-full text-sm"

                        />

                        {state.fieldErrors?.reason && (

                            <p className="text-sm text-red-600 mt-1">{state.fieldErrors.reason}</p>

                        )}

                    </div>
                    <Button
                        type="submit"
                        disabled={isPending}
                    >
                        {isPending ? t('common.saving') : t('common.save')}
                    </Button>
                    <Link
                        href="/finance/fx"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('common.cancel')}
                    </Link>
                    <span className="flex-1" />
                    <DeleteButton id={rate.id} />
                </div>
            </form>
        </>
    )
}
