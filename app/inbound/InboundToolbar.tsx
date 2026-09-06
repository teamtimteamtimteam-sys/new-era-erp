'use client'

// 进料列表工具栏:搜索(code)+ 阶段下拉 + 供应商下拉 + 物料下拉 + 导出。
// 阶段用 STAGE_OPTIONS(value/labelKey);供应商/物料是 FK-id 下拉,选项由 page 以 props 传入。
// 改动只写进 URL searchParams,真正的过滤在服务端 page.tsx 完成。
import { useEffect, useRef, useState } from 'react'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { STAGE_OPTIONS } from './options'
import { PRICING_STATUS_VALUES } from './inboundQuery'
import { Button } from '@/app/components/ui/button'

export type PartyOption = { id: string; label: string }

export default function InboundToolbar({
    suppliers,
    materials,
}: {
    suppliers: PartyOption[]
    materials: PartyOption[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const currentQ = searchParams.get('q') ?? ''
    const currentStage = searchParams.get('stage') ?? ''
    const currentSupplier = searchParams.get('supplier_id') ?? ''
    const currentMaterial = searchParams.get('material_id') ?? ''
    const currentDateFrom = searchParams.get('date_from') ?? ''
    const currentDateTo = searchParams.get('date_to') ?? ''
    const currentPricingStatus = searchParams.get('pricing_status') ?? ''

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
    const exportHref = exportQs ? `/inbound/export?${exportQs}` : '/inbound/export'

    return (
        <div className="mb-4 flex flex-wrap items-center gap-3">
            <input
                type="search"
                value={q}
                onChange={(e) => onSearchChange(e.target.value)}
                placeholder={t('inbound.searchPlaceholder')}
                className="w-60 max-w-full rounded border border-gray-300 px-3 py-2"
            />
            <select
                value={currentStage}
                onChange={(e) => onFilterChange('stage', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2"
            >
                <option value="">{t('inbound.allStages')}</option>
                {STAGE_OPTIONS.map((o) => (
                    <option key={o.value} value={o.value}>
                        {t(o.labelKey)}
                    </option>
                ))}
            </select>
            <select
                value={currentSupplier}
                onChange={(e) => onFilterChange('supplier_id', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2"
            >
                <option value="">{t('inbound.allSuppliers')}</option>
                {suppliers.map((s) => (
                    <option key={s.id} value={s.id}>
                        {s.label}
                    </option>
                ))}
            </select>
            <select
                value={currentMaterial}
                onChange={(e) => onFilterChange('material_id', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2"
            >
                <option value="">{t('inbound.allMaterials')}</option>
                {materials.map((m) => (
                    <option key={m.id} value={m.id}>
                        {m.label}
                    </option>
                ))}
            </select>
            {/* 定价状态(cut 5b):等化验的批次就是还没算对的钱,要能一眼筛出来 */}
            <select
                value={currentPricingStatus}
                onChange={(e) => onFilterChange('pricing_status', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2"
            >
                <option value="">{t('assay.allPricingStatuses')}</option>
                {PRICING_STATUS_VALUES.map((s) => (
                    <option key={s} value={s}>
                        {t('assay.pricingStatus.' + s)}
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
                    {t('inbound.export')}
                </a>
            </Button>
        </div>
    )
}
