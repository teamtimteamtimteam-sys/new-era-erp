'use client'

// 客户列表工具栏:搜索框(q)+ 导出。无状态下拉(客户没有状态筛选)。
// 改动只写进 URL searchParams,真正的过滤在服务端 page.tsx 完成。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useEffect, useRef, useState } from 'react'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { filteredListHref } from '@/lib/savedViews' // SYSTEM-MAP-1 D1:清空筛选 → 原始列表

export default function CustomerToolbar() {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const currentQ = searchParams.get('q') ?? ''

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
        return filteredListHref(pathname, params)
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

    return (
        <div className="mb-4 flex flex-wrap items-center gap-3">
            <input
                type="search"
                value={q}
                onChange={(e) => onSearchChange(e.target.value)}
                placeholder={t('customers.searchPlaceholder')}
                className={`${CONTROL_INPUT} w-72 max-w-full`}
            />
        </div>
    )
}
