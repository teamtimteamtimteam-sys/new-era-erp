'use client'

// 金属价格列表工具栏:只有一个金属筛选下拉(全部 + 7 金属)。
// 端口自 InboundToolbar,但去掉搜索/其它筛选 —— 参考表只需按金属过滤。
// 改动只写进 URL searchParams,真正的过滤在服务端 page.tsx 完成。
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import type { MetalOption } from './options'

export default function MetalPricesToolbar({
    substanceOptions,
}: {
    // PROC-4:物质清单由页面从字典读好传进来(清单与顺序都由它定)。
    substanceOptions: MetalOption[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const currentMetal = searchParams.get('metal') ?? ''

    // 合并到当前 params:空值删除该键,保持 URL 干净
    function buildHref(updates: Record<string, string | null>) {
        const params = new URLSearchParams(searchParams.toString())
        for (const [k, v] of Object.entries(updates)) {
            if (!v) params.delete(k)
            else params.set(k, v)
        }
        const qs = params.toString()
        return qs ? `${pathname}?${qs}` : pathname
    }

    // 筛选切换是离散动作(push),并把 page 清回第 1 页
    function onFilterChange(key: string, value: string) {
        router.push(buildHref({ [key]: value || null, page: null }))
    }

    return (
        <div className="mb-4 flex flex-wrap items-center gap-3">
            <select
                value={currentMetal}
                onChange={(e) => onFilterChange('metal', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2"
            >
                <option value="">{t('metalPrices.allMetals')}</option>
                {substanceOptions.filter((s) => s.isActive).map((o) => (
                    <option key={o.value} value={o.value}>
                        {t(o.labelKey)}
                    </option>
                ))}
            </select>
        </div>
    )
}
