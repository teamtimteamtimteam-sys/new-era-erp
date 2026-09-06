'use client'

// 产出列表工具栏:搜索(code)+ 状态下拉 + 客户下拉 + 物料下拉 + 导出。端口自 InboundToolbar。
// 状态用 STATE_OPTIONS(value/labelKey);客户/物料是 FK-id 下拉,选项由 page 以 props 传入。
// 改动只写进 URL searchParams,真正的过滤在服务端 page.tsx 完成。
import { useEffect, useRef, useState } from 'react'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { STATE_OPTIONS } from '../inbound/options'
import { Button } from '@/app/components/ui/button'

export type PartyOption = { id: string; label: string }

export default function OutputToolbar({
    customers,
    materials,
}: {
    customers: PartyOption[]
    materials: PartyOption[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const currentQ = searchParams.get('q') ?? ''
    const currentState = searchParams.get('state') ?? ''
    const currentCustomer = searchParams.get('customer_id') ?? ''
    const currentMaterial = searchParams.get('material_id') ?? ''
    const currentDateFrom = searchParams.get('date_from') ?? ''
    const currentDateTo = searchParams.get('date_to') ?? ''

    // 搜索框是受控的:本地 state 即时反映输入,URL 防抖更新
    const [q, setQ] = useState(currentQ)
    useEffect(() => {
        setQ(currentQ)
    }, [currentQ])

    const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null)
    useEffect(() => {
        return () => {
            if (debounceRef.current) clearTimeout(debounceRef.current)
        }
    }, [])

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

    function onSearchChange(value: string) {
        setQ(value)
        if (debounceRef.current) clearTimeout(debounceRef.current)
        debounceRef.current = setTimeout(() => {
            // replace:逐字输入不进历史。page:null —— 改搜索回到第 1 页。
            router.replace(buildHref({ q: value || null, page: null }))
        }, 300)
    }

    // 筛选切换都是离散动作(push),且都把 page 清回第 1 页
    function onFilterChange(key: string, value: string) {
        router.push(buildHref({ [key]: value || null, page: null }))
    }

    // 导出链接:带上当前所有筛选,但【剔除 page】—— 导出永远是全部匹配行。
    const exportParams = new URLSearchParams(searchParams.toString())
    exportParams.delete('page')
    const exportQs = exportParams.toString()
    const exportHref = exportQs ? `/output/export?${exportQs}` : '/output/export'

    return (
        <div className="mb-4 flex flex-wrap items-center gap-3">
            <input
                type="search"
                value={q}
                onChange={(e) => onSearchChange(e.target.value)}
                placeholder={t('output.searchPlaceholder')}
                className="w-60 max-w-full rounded border border-gray-300 px-3 py-2"
            />
            <select
                value={currentState}
                onChange={(e) => onFilterChange('state', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2"
            >
                <option value="">{t('output.allStates')}</option>
                {STATE_OPTIONS.map((o) => (
                    <option key={o.value} value={o.value}>
                        {t(o.labelKey)}
                    </option>
                ))}
            </select>
            <select
                value={currentCustomer}
                onChange={(e) => onFilterChange('customer_id', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2"
            >
                <option value="">{t('output.allCustomers')}</option>
                {customers.map((c) => (
                    <option key={c.id} value={c.id}>
                        {c.label}
                    </option>
                ))}
            </select>
            <select
                value={currentMaterial}
                onChange={(e) => onFilterChange('material_id', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2"
            >
                <option value="">{t('output.allMaterials')}</option>
                {materials.map((m) => (
                    <option key={m.id} value={m.id}>
                        {m.label}
                    </option>
                ))}
            </select>
            <label className="flex items-center gap-1 text-sm text-gray-600">
                {t('listFilters.dateFrom')}
                <input
                    type="date"
                    value={currentDateFrom}
                    onChange={(e) => onFilterChange('date_from', e.target.value)}
                    className="rounded border border-gray-300 bg-white px-2 py-2"
                />
            </label>
            <label className="flex items-center gap-1 text-sm text-gray-600">
                {t('listFilters.dateTo')}
                <input
                    type="date"
                    value={currentDateTo}
                    onChange={(e) => onFilterChange('date_to', e.target.value)}
                    className="rounded border border-gray-300 bg-white px-2 py-2"
                />
            </label>
            <Button asChild variant="outline" size="sm">
                <a
                    href={exportHref}
                >
                    {t('output.export')}
                </a>
            </Button>
        </div>
    )
}
