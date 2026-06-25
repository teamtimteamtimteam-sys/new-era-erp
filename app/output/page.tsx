// app/output/page.tsx
// 产出批次列表页(只读)
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import { STATE_OPTIONS, labelKeyForValue } from '../inbound/options'
import { getTranslations, getLocale } from '@/lib/i18n/server'

// FK 嵌入运行时是对象;显式类型 + cast 锁住,避免 TS 默认数组推断。
type OutputRow = {
    id: string
    code: string
    quantity: number
    unit: string
    remaining_qty: number
    output_date: string | null
    state: string
    status: string
    created_at: string
    materials: { name: string } | null
    customers: { legal_name: string } | null
}

export default async function OutputPage() {
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    // 嵌入外键:materials 和 customers 通过 material_id / customer_id 关联。
    // 注意:customer_id 可空,库存中的批次还没指派客户,customers 会是 null。
    const { data, error } = await supabase
        .from('output_batches')
        .select(`
            id, code, quantity, unit, remaining_qty, output_date, state, status, created_at,
            materials ( name ),
            customers ( legal_name )
        `)
        .is('deleted_at', null)
        .order('created_at', { ascending: false })

    const batches = data as unknown as OutputRow[] | null

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('output.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('output.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    // state 存储值反查成本地化文案;未知值原样显示
    const stateLabel = (value: string) => {
        const key = labelKeyForValue(STATE_OPTIONS, value)
        return key ? t(key) : value
    }

    return (
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('output.listTitle')}</h1>
                <Link
                    href="/output/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('output.addButton')}
                </Link>
            </div>
            <p className="text-sm text-gray-600 mb-4">
                {t('output.recordCount', { count: batches?.length ?? 0 })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">Code</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colMaterial')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colCustomer')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colQuantity')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colRemaining')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colOutputDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colState')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">Status</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colActions')}</th>
                    </tr>
                </thead>
                <tbody>
                    {batches?.map((b) => (
                        <tr key={b.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/output/${b.id}/edit`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {b.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{b.materials?.name ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.customers?.legal_name ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.quantity} {b.unit}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.remaining_qty} {b.unit}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.output_date ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {stateLabel(b.state)}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {b.status}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <DeleteButton id={b.id} code={b.code} />
                            </td>
                        </tr>
                    ))}
                    {(!batches || batches.length === 0) && (
                        <tr>
                            <td
                                colSpan={9}
                                className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                            >
                                {t('output.emptyState')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
