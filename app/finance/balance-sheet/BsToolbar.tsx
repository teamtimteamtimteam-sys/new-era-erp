'use client'

// 资产负债表工具栏:截至日期(显示生效值,含默认今天)。
// 改动只写进 URL searchParams,聚合在服务端 page.tsx 完成。
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

export default function BsToolbar({ asOf }: { asOf: string }) {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    function onChange(value: string) {
        const params = new URLSearchParams(searchParams.toString())
        if (!value) params.delete('as_of')
        else params.set('as_of', value)
        const qs = params.toString()
        router.push(qs ? `${pathname}?${qs}` : pathname)
    }

    return (
        <div className="mb-4 flex flex-wrap items-center gap-3">
            <label className="text-sm text-gray-600">
                {t('finance.asOf')}{' '}
                <input
                    type="date"
                    value={asOf}
                    onChange={(e) => onChange(e.target.value)}
                    className="rounded border border-gray-300 bg-white px-3 py-2"
                />
            </label>
        </div>
    )
}
