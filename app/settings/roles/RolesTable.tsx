'use client'

// app/settings/roles/RolesTable.tsx
// CONV-5 · 角色一览那张表。
// 【注意】同目录下的 PermissionMatrix 是权限勾选矩阵,它挂在 /settings/roles/[id]
// (详情页),不在这一页上 —— CONV-3 §⑧-10 点名要核实的四张之一,本刀按 import
// 核实后更正:这一页是纯只读账簿。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type RoleRow = {
    id: string
    code: string
    isSystem: boolean
    name: string
    description: string
    permissionCount: number
    userCount: number
    isActive: boolean
}

export default function RolesTable({ rows, empty }: { rows: RoleRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【角色码】与【持有人数】—— 角色码是身份;而"这个角色下有几个人"
    //   决定了改它的后果有多大,那是打开这一页的人要先知道的事。
    const columns: Column<RoleRow>[] = [
        {
            key: 'code', header: t('permissions.roleCode'), priority: true, className: 'font-mono text-xs',
            render: (r) => (
                <>
                    {r.code}
                    {r.isSystem && (
                        <span className="ml-2 rounded bg-amber-100 px-1.5 py-0.5 text-[10px] text-amber-800">
                            {t('permissions.systemRole')}
                        </span>
                    )}
                </>
            ),
        },
        { key: 'name', header: t('permissions.roleName'), render: (r) => r.name },
        { key: 'description', header: t('permissions.roleDescription'), className: 'text-gray-600', render: (r) => r.description },
        {
            key: 'permCount', header: t('permissions.permissionCount'), align: 'right', className: 'font-mono',
            render: (r) => r.permissionCount,
        },
        {
            key: 'userCount', header: t('permissions.userCount'), priority: true, align: 'right', className: 'font-mono',
            render: (r) => r.userCount,
        },
        { key: 'active', header: t('permissions.active'), render: (r) => (r.isActive ? t('permissions.yes') : t('permissions.no')) },
        {
            key: 'actions', header: '',
            render: (r) => (
                <Link href={`/settings/roles/${r.id}`} className="text-blue-600 hover:underline">
                    {t('permissions.editRole')}
                </Link>
            ),
        },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
