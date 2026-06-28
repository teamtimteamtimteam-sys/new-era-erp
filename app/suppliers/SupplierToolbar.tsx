'use client'

// 供应商列表工具栏:搜索框(q)+ 状态下拉(status)。
// 改动只写进 URL searchParams,真正的过滤在服务端 page.tsx 完成。
import { useEffect, useRef, useState } from 'react'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { SUPPLIER_STATUSES } from './[id]/edit/statusMachine'

export default function SupplierToolbar() {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const currentQ = searchParams.get('q') ?? ''
    const currentStatus = searchParams.get('status') ?? ''

    // 搜索框是受控的:本地 state 即时反映输入,URL 防抖更新
    const [q, setQ] = useState(currentQ)

    // 外部导致 URL 的 q 变化(后退/前进、外部清空)时同步输入框
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
            // replace:逐字输入不往浏览历史里塞记录(服务端再 trim)。
            // page:null —— 改变搜索时回到第 1 页(避免停在已不存在的旧页码)。
            router.replace(buildHref({ q: value || null, page: null }))
        }, 300)
    }

    function onStatusChange(value: string) {
        // push:筛选切换是离散动作,保留在历史里(后退可回到上一筛选)。
        // page:null —— 改变筛选时回到第 1 页。
        router.push(buildHref({ status: value || null, page: null }))
    }

    // 导出链接:带上当前 q / status / sort / dir,导出的就是用户此刻筛选到的结果。
    // 但【剔除 page】—— 导出永远是全部匹配行,不受分页影响。
    // 用普通 <a>(而非 next/link):整页请求命中 route handler,Content-Disposition 触发下载。
    const exportParams = new URLSearchParams(searchParams.toString())
    exportParams.delete('page')
    const exportQs = exportParams.toString()
    const exportHref = exportQs ? `/suppliers/export?${exportQs}` : '/suppliers/export'

    return (
        <div className="mb-4 flex flex-wrap items-center gap-3">
            <input
                type="search"
                value={q}
                onChange={(e) => onSearchChange(e.target.value)}
                placeholder={t('suppliers.searchPlaceholder')}
                className="w-72 max-w-full rounded border border-gray-300 px-3 py-2"
            />
            <select
                value={currentStatus}
                onChange={(e) => onStatusChange(e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2"
            >
                <option value="">{t('suppliers.allStatuses')}</option>
                {SUPPLIER_STATUSES.map((s) => (
                    <option key={s} value={s}>
                        {t('suppliers.status.' + s)}
                    </option>
                ))}
            </select>
            <a
                href={exportHref}
                className="rounded border border-gray-300 bg-white px-3 py-2 hover:bg-gray-50"
            >
                {t('suppliers.export')}
            </a>
        </div>
    )
}
