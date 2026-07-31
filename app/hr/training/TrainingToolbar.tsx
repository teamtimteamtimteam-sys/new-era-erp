'use client'

// 培训列表工具栏:类别 + 到期状态(已过期 / 90 天内到期 / 无到期日)。
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { TRAINING_CATEGORY_OPTIONS } from '../options'

export default function TrainingToolbar() {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const category = searchParams.get('category') ?? ''
    const expiry = searchParams.get('expiry') ?? ''

    function onChange(key: string, value: string) {
        const params = new URLSearchParams(searchParams.toString())
        if (!value) params.delete(key)
        else params.set(key, value)
        const qs = params.toString()
        router.push(qs ? `${pathname}?${qs}` : pathname)
    }

    return (
        <div className="mb-4 flex flex-wrap items-center gap-3">
            <select
                value={category}
                onChange={(e) => onChange('category', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm"
            >
                <option value="">{t('hr.allCategoriesTraining')}</option>
                {TRAINING_CATEGORY_OPTIONS.map((o) => (
                    <option key={o.value} value={o.value}>
                        {t(o.labelKey)}
                    </option>
                ))}
            </select>
            <select
                value={expiry}
                onChange={(e) => onChange('expiry', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm"
            >
                <option value="">{t('hr.allExpiryStates')}</option>
                <option value="expired">{t('hr.severity.expired')}</option>
                <option value="soon">{t('hr.expiringSoon')}</option>
                <option value="none">{t('hr.noExpiry')}</option>
            </select>
        </div>
    )
}
