'use client'

// app/purchasing/licences/LicenceTable.tsx
// CONV-3 · 公司执照登记簿的那张表。见 docs/list-page-template.md 的 Kind-E 一节。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import type { LicenceRow, CertType } from './LicencePanel'

export default function LicenceTable({
    rows, certTypes, canEdit, pending, onEdit, onDelete,
}: {
    rows: LicenceRow[]
    certTypes: CertType[]
    canEdit: boolean
    pending: boolean
    onEdit: (r: LicenceRow) => void
    onDelete: (id: string) => void
}) {
    const t = useTranslations()

    // ★【手机上留哪两列】种类是身份,到期日是这张登记簿存在的理由 ——
    // 人来查这一页多半是想知道"什么时候要续"。证号、状态、贮存上限是
    // 读到那一条之后才要问的,进展开区。
    const columns: Column<LicenceRow>[] = [
        {
            key: 'kind', header: t('company.licence.colKind'), priority: true,
            render: (r) => {
                const ct = certTypes.find((c) => c.code === r.cert_type_code)
                return ct ? ct.name_en : r.cert_type_code
            },
        },
        {
            key: 'no', header: t('company.licence.colNo'), className: 'font-mono',
            render: (r) => r.cert_no ?? <span className="text-amber-800">{t('company.licence.notRecorded')}</span>,
        },
        {
            key: 'status', header: t('company.licence.colStatus'),
            render: (r) => (r.status
                ? t('company.licence.status.' + r.status)
                : <span className="text-amber-800">{t('company.licence.notRecorded')}</span>),
        },
        {
            key: 'validity', header: t('company.licence.colValidity'), priority: true,
            render: (r) => r.valid_until ?? <span className="text-amber-800">{t('company.licence.notRecorded')}</span>,
        },
        {
            // ★ 上限那一格:空 = 【没有人录过】,不是【没有上限】★
            key: 'limit', header: t('company.licence.colStorageLimit'), align: 'right',
            render: (r) => (r.approved_storage_limit_tonnes !== null
                ? r.approved_storage_limit_tonnes
                : <span className="font-medium text-red-800">{t('company.licence.limitNotSet')}</span>),
        },
        {
            key: 'actions', header: '',
            render: (r) => canEdit ? (
                <>
                    <button type="button" disabled={pending} onClick={() => onEdit(r)}
                            className="mr-2 text-xs text-blue-600 hover:underline disabled:opacity-50">
                        {t('company.licence.edit')}
                    </button>
                    <button type="button" disabled={pending} onClick={() => onDelete(r.id)}
                            className="text-xs text-red-700 hover:underline disabled:opacity-50">
                        {t('company.licence.delete')}
                    </button>
                </>
            ) : null,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            // ★【空态住在 DataTable 里,不住在 ListPage 里 —— 见 page.tsx 的说明】
            //   「还没有执照」是正确状态,而「新增执照」按钮就在这张表【外面】
            //   (LicencePanel 的标题行),不受行数门槛管 —— 但整页仍然要恒为 ok,
            //   否则 ListPage 的 empty 分支会把那个按钮也一起藏掉。
            empty={t('company.licence.none')}
        />
    )
}
