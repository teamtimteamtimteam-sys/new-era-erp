'use client'

// EQP-1c-b(P1):登记一台机器。
// 【这张表单与开支表单的资本勾选项是【两扇门,不是一新一旧】】——
// 页面上那句话不是装饰:选错门的代价是真的(见 twoDoors 那段文案)。
import { useActionState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { createAsset, type NewAssetState } from './actions'

const CATEGORIES = ['equipment', 'vehicle', 'office', 'other'] as const

export default function NewAssetForm() {
    const t = useTranslations()
    const [state, formAction, pending] = useActionState<NewAssetState, FormData>(
        createAsset, {} as NewAssetState,
    )

    return (
        <form action={formAction} className="max-w-2xl space-y-5">
            {/* 【为什么有两扇门】—— 一句话,就在表单旁边。
                读不出区别的人会选错,而两者的账是不一样的。 */}
            <div className="rounded-lg border border-blue-200 bg-blue-50 p-3 text-sm text-blue-900">
                <p className="font-medium">{t('assets.new.twoDoorsTitle')}</p>
                <p className="mt-1">{t('assets.new.twoDoorsThis')}</p>
                <p className="mt-1">
                    {t('assets.new.twoDoorsOther')}{' '}
                    <Link href="/finance/expenses/new" className="underline">
                        {t('assets.new.twoDoorsOtherLink')}
                    </Link>
                </p>
            </div>

            {state.error && (
                <p className="rounded-md bg-red-50 border border-red-200 px-3 py-2 text-sm text-red-700">
                    {state.error}
                </p>
            )}

            <div>
                <label htmlFor="description" className="block text-sm font-medium mb-1">
                    {t('assets.new.description')}
                </label>
                <input id="description" name="description" required
                    className="w-full border border-gray-300 rounded-md px-3 py-2" />
                <p className="mt-1 text-xs text-gray-600">{t('assets.new.descriptionHint')}</p>
            </div>

            <div className="grid grid-cols-2 gap-4">
                <div>
                    <label htmlFor="acquisition_date" className="block text-sm font-medium mb-1">
                        {t('assets.new.acquisitionDate')}
                    </label>
                    <input id="acquisition_date" name="acquisition_date" type="date" required
                        className="w-full border border-gray-300 rounded-md px-3 py-2" />
                    {/* 【为什么不预填今天】它是投用日的下界 —— 预填会把投用日的
                        合法范围一起挪掉,而那不是这张表单该替人决定的事。 */}
                    <p className="mt-1 text-xs text-gray-600">{t('assets.new.acquisitionDateHint')}</p>
                </div>
                <div>
                    <label htmlFor="useful_life_months" className="block text-sm font-medium mb-1">
                        {t('assets.new.usefulLife')}
                    </label>
                    <input id="useful_life_months" name="useful_life_months" type="number"
                        min="1" step="1" required
                        className="w-full border border-gray-300 rounded-md px-3 py-2" />
                    <p className="mt-1 text-xs text-gray-600">{t('assets.new.usefulLifeHint')}</p>
                </div>
            </div>

            <div>
                <label htmlFor="category" className="block text-sm font-medium mb-1">
                    {t('assets.new.category')}
                </label>
                <select id="category" name="category" defaultValue="equipment"
                    className="w-full border border-gray-300 rounded-md px-3 py-2">
                    {CATEGORIES.map((c) => (
                        <option key={c} value={c}>{t('assets.category.' + c)}</option>
                    ))}
                </select>
            </div>

            <div>
                <label htmlFor="notes" className="block text-sm font-medium mb-1">
                    {t('assets.new.notes')}
                </label>
                <textarea id="notes" name="notes" rows={2}
                    className="w-full border border-gray-300 rounded-md px-3 py-2" />
                {/* E2 的既有事实:序列号/制造商/型号全库没有列,只能写在这里。 */}
                <p className="mt-1 text-xs text-gray-600">{t('assets.new.notesHint')}</p>
            </div>

            {/* 【成本不在这张表单上,而这要说出来】否则第一个用它的人会找价格字段。 */}
            <p className="rounded-md bg-gray-50 border border-gray-200 px-3 py-2 text-sm text-gray-700">
                {t('assets.new.costComesLater')}
            </p>

            <div className="flex gap-3">
                <button type="submit" disabled={pending}
                    className="bg-blue-600 text-white px-4 py-2 rounded-md disabled:opacity-50">
                    {pending ? t('common.saving') : t('assets.new.submit')}
                </button>
                <Link href="/finance/assets" className="px-4 py-2 rounded-md border border-gray-300">
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}
