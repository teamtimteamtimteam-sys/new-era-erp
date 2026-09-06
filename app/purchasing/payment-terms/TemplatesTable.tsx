'use client'

// app/purchasing/payment-terms/TemplatesTable.tsx
// CONV-5 · 付款条件模板那张表。
// 【注意】同目录下的 TemplateForm 只挂在 /new 与 /[id]/edit —— 不在这一页上。
// CONV-3 §⑧-10 点名要核实的四张之一,本刀按 import 核实后更正。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import DeleteTemplateButton from './DeleteTemplateButton'
import { Button } from '@/app/components/ui/button'

export type TemplateRow = {
    id: string
    name: string
    description: string
    /** 各期占比 · 触发事件 · 偏移,已在服务端拼成一句话。 */
    termsSummary: string
    isActive: boolean
}

export default function TemplatesTable({ rows, empty }: { rows: TemplateRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【模板名】与【付款条件】—— 名字是身份,而那一串"几成 / 什么时候"
    //   就是这个模板【是什么】,它不是一个可以点开再看的细节。
    const columns: Column<TemplateRow>[] = [
        { key: 'name', header: t('purchasing.colName'), priority: true, className: 'font-medium', render: (r) => r.name },
        { key: 'description', header: t('purchasing.colDescription'), className: 'text-sm text-gray-600', render: (r) => r.description },
        {
            key: 'terms', header: t('purchasing.form.paymentTerms'), priority: true, className: 'text-sm',
            render: (r) => r.termsSummary,
        },
        {
            key: 'status', header: t('purchasing.colStatus'),
            render: (r) => (
                <span className={'px-2 py-1 rounded text-xs ' + (r.isActive ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-600')}>
                    {r.isActive ? t('pricing.form.active') : t('finance.inactive')}
                </span>
            ),
        },
        {
            key: 'actions', header: t('metalPrices.colActions'), className: 'text-sm whitespace-nowrap',
            render: (r) => (
                <>
                    <Button asChild variant="link" size="inline" className="mr-3">
                        <Link href={`/purchasing/payment-terms/${r.id}/edit`}>
                            {t('purchasing.editLink')}
                        </Link>
                    </Button>
                    <DeleteTemplateButton templateId={r.id} name={r.name} />
                </>
            ),
        },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
