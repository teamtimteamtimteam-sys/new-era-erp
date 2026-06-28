// app/suppliers/page.tsx
// 供应商列表页:URL 驱动的搜索 / 状态筛选 / 排序(全部在服务端的 Supabase 查询里完成)
import { Suspense } from 'react'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import SupplierToolbar from './SupplierToolbar'
import { SUPPLIER_STATUSES } from './[id]/edit/statusMachine'
import { getTranslations, getLocale } from '@/lib/i18n/server'

// 允许排序的列白名单(防止任意列名进入 .order())
const SORTABLE = ['legal_name', 'code', 'status', 'created_at'] as const
type SortCol = (typeof SORTABLE)[number]

export default async function SuppliersPage({
    searchParams,
}: {
    // 本版本 Next 里 searchParams 是 Promise,需要 await
    searchParams: Promise<{
        q?: string
        status?: string
        sort?: string
        dir?: string
    }>
}) {
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    // 解析并校验 URL 参数(都给安全默认值)
    const q = (sp.q ?? '').trim()
    const status: (typeof SUPPLIER_STATUSES)[number] | '' =
        sp.status && (SUPPLIER_STATUSES as readonly string[]).includes(sp.status)
            ? (sp.status as (typeof SUPPLIER_STATUSES)[number])
            : ''
    const sort: SortCol = (SORTABLE as readonly string[]).includes(sp.sort ?? '')
        ? (sp.sort as SortCol)
        : 'created_at'
    const dir: 'asc' | 'desc' = sp.dir === 'asc' ? 'asc' : 'desc'

    // 构造查询:select -> 软删除过滤 -> 搜索 -> 状态 -> 排序
    let query = supabase
        .from('suppliers')
        .select(
            'id, code, legal_name, short_name, country, supplier_types, status, tax_id, created_at'
        )
        .is('deleted_at', null)

    if (q) {
        // 去掉会破坏 PostgREST or() 表达式的字符(逗号 / 括号),再做 ilike 模糊匹配
        const safe = q.replace(/[,()]/g, ' ')
        const pattern = `%${safe}%`
        query = query.or(
            `code.ilike.${pattern},legal_name.ilike.${pattern},short_name.ilike.${pattern},tax_id.ilike.${pattern},country.ilike.${pattern}`
        )
    }

    if (status) {
        query = query.eq('status', status)
    }

    query = query.order(sort, { ascending: dir === 'asc' })

    const { data: suppliers, error } = await query

    // 表头排序链接:点当前列翻转方向,点其它列默认升序;保留 q / status
    function sortHref(col: SortCol) {
        const nextDir = sort === col && dir === 'asc' ? 'desc' : 'asc'
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        if (status) params.set('status', status)
        params.set('sort', col)
        params.set('dir', nextDir)
        return `/suppliers?${params.toString()}`
    }

    function sortableTh(col: SortCol, label: string) {
        const indicator = sort === col ? (dir === 'asc' ? ' ▲' : ' ▼') : ''
        return (
            <th className="border border-gray-300 px-4 py-2 text-left">
                <Link href={sortHref(col)} className="hover:underline">
                    {label}
                    {indicator}
                </Link>
            </th>
        )
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('suppliers.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('suppliers.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('suppliers.listTitle')}</h1>
                <Link
                    href="/suppliers/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('suppliers.addButton')}
                </Link>
            </div>

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <SupplierToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('suppliers.recordCount', { count: suppliers?.length ?? 0 })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        {sortableTh('code', t('suppliers.col.code'))}
                        {sortableTh('legal_name', t('suppliers.col.legalName'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('suppliers.col.country')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('suppliers.col.types')}
                        </th>
                        {sortableTh('status', t('suppliers.col.status'))}
                        {sortableTh('created_at', t('suppliers.col.created'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('suppliers.colActions')}
                        </th>
                    </tr>
                </thead>
                <tbody>
                    {suppliers?.map((s) => (
                        <tr key={s.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/suppliers/${s.id}/edit`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {s.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{s.legal_name}</td>
                            <td className="border border-gray-300 px-4 py-2">{s.country}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {s.supplier_types?.join(', ')}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {t('suppliers.status.' + s.status)}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">
                                {new Date(s.created_at).toLocaleString(dateLocale)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <DeleteButton id={s.id} legalName={s.legal_name} />
                            </td>
                        </tr>
                    ))}
                    {(!suppliers || suppliers.length === 0) && (
                        <tr>
                            <td
                                colSpan={7}
                                className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                            >
                                {t('suppliers.emptyState')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
