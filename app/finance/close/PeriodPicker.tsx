'use client'

// 关账月份选择:最近 12 个月末,已关账 / 早于期间锁的禁选。
// 选择写进 URL ?period=,预览在服务端 page.tsx 计算。
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

export type PeriodOption = { value: string; disabled: boolean }

export default function PeriodPicker({
    options,
    selected,
}: {
    options: PeriodOption[]
    selected: string
}) {
    const t = useTranslations()
    const router = useRouter()

    return (
        <label className="text-sm text-gray-600">
            {t('finance.selectPeriod')}{' '}
            <select
                value={selected}
                onChange={(e) => router.push(`/finance/close?period=${e.target.value}`)}
                className="rounded border border-gray-300 bg-white px-3 py-2"
            >
                {options.map((o) => (
                    <option key={o.value} value={o.value} disabled={o.disabled}>
                        {o.value}
                    </option>
                ))}
            </select>
        </label>
    )
}
