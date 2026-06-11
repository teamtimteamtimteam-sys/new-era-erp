'use client'

import { useState, useTransition } from 'react'
import { addCompliance, deleteCompliance } from './complianceActions'

type ComplianceRow = {
    id: string
    cert_type: string
    cert_no: string | null
    issuing_body: string | null
    valid_from: string | null
    valid_until: string | null
    notes: string | null
}

const CERT_TYPE_OPTIONS = [
    'Basel Convention',
    'Article 18',
    'NEA Import Permit',
    'GWDF Licence',
    'TFS Document',
    '其他',
]

export default function CompliancePanel({
    supplierId,
    rows,
}: {
    supplierId: string
    rows: ComplianceRow[]
}) {
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()
    const [formKey, setFormKey] = useState(0)

    function handleAdd(formData: FormData) {
        startTransition(async () => {
            const result = await addCompliance(supplierId, formData)
            if (result?.error) {
                setError(result.error)
            } else {
                setError(null)
                setFormKey((k) => k + 1)
            }
        })
    }

    function handleDelete(id: string) {
        if (!window.confirm('确定删除这张证书吗?')) return
        startTransition(async () => {
            const result = await deleteCompliance(id, supplierId)
            if (result?.error) {
                setError(result.error)
            } else {
                setError(null)
            }
        })
    }

    const now = new Date()

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-4">合规证书</h2>

            {rows.length === 0 ? (
                <p className="text-sm text-gray-500 mb-6">暂无合规证书</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 mb-6">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">证书类型</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">证书编号</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">签发机构</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">有效期</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">操作</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((row) => {
                            const expired =
                                row.valid_until !== null &&
                                new Date(row.valid_until) < now
                            return (
                                <tr key={row.id}>
                                    <td className="border border-gray-300 px-4 py-2">{row.cert_type}</td>
                                    <td className="border border-gray-300 px-4 py-2 text-sm">
                                        {row.cert_no ?? '—'}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-sm">
                                        {row.issuing_body ?? '—'}
                                    </td>
                                    <td
                                        className={`border border-gray-300 px-4 py-2 text-sm ${
                                            expired ? 'text-red-600' : ''
                                        }`}
                                    >
                                        {row.valid_from || '—'} ~ {row.valid_until || '—'}
                                        {expired && ' (已过期)'}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        <button
                                            type="button"
                                            onClick={() => handleDelete(row.id)}
                                            disabled={isPending}
                                            className="text-red-600 text-sm hover:underline disabled:text-gray-400"
                                        >
                                            删除
                                        </button>
                                    </td>
                                </tr>
                            )
                        })}
                    </tbody>
                </table>
            )}

            <h3 className="text-lg font-semibold mb-3">添加证书</h3>

            {error && (
                <p className="text-red-600 text-sm mb-3">{error}</p>
            )}

            <form key={formKey} action={handleAdd} className="space-y-3">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        证书类型 <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="cert_type"
                        required
                        defaultValue=""
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>
                            请选择证书类型
                        </option>
                        {CERT_TYPE_OPTIONS.map((opt) => (
                            <option key={opt} value={opt}>
                                {opt}
                            </option>
                        ))}
                    </select>
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">证书编号</label>
                    <input
                        type="text"
                        name="cert_no"
                        placeholder="证书编号"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">签发机构</label>
                    <input
                        type="text"
                        name="issuing_body"
                        placeholder="签发机构"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div className="grid grid-cols-2 gap-3">
                    <div>
                        <label className="block text-sm font-medium mb-1">生效日期</label>
                        <input
                            type="date"
                            name="valid_from"
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">到期日期</label>
                        <input
                            type="date"
                            name="valid_until"
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">备注</label>
                    <input
                        type="text"
                        name="notes"
                        placeholder="备注(可选)"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div className="pt-2">
                    <button
                        type="submit"
                        disabled={isPending}
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                    >
                        {isPending ? '添加中...' : '添加证书'}
                    </button>
                </div>
            </form>
        </section>
    )
}
