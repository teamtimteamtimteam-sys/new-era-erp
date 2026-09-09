'use client'

import { useState, useTransition } from 'react'
import { addCompliance, deleteCompliance } from './complianceActions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { Button } from '@/app/components/ui/button'

type ComplianceRow = {
    id: string
    cert_type_code: string
    cert_no: string | null
    issuing_body: string | null
    valid_from: string | null
    valid_until: string | null
    notes: string | null
    document_id: string | null
}

// CMP-1:类型选项来自 certificate_types【表】,不再硬编码 —— 加一种证书是编辑
// 一行数据,不是改这里的数组。disposition 顺带显示,让录入的人知道这一类过期
// 会不会挡收货。
export type CertTypeOption = {
    code: string
    name_en: string
    name_zh: string
    disposition: string
}
export type AttachmentOption = { id: string; file_name: string }

export default function CompliancePanel({
    supplierId,
    rows,
    certTypes,
    attachments,
    locale,
}: {
    supplierId: string
    rows: ComplianceRow[]
    certTypes: CertTypeOption[]
    attachments: AttachmentOption[]
    locale: string
}) {
    const typeLabel = (code: string) => {
        const ct = certTypes.find((c) => c.code === code)
        return ct ? (locale === 'zh' ? ct.name_zh : ct.name_en) : code
    }
    const t = useTranslations()
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

    /* ★ TABLE-PHONE-3:同一个删除钮要在两个断点各画一次(桌面档在自己那一列,
       手机档叠在「种类」格里),所以在这里定义一次 —— 免得两处日后走散。
       确认框与动作一个字没改:同一个 ConfirmButton、同一个 handleDelete(row.id)。 */
    const deleteControl = (row: (typeof rows)[number]) => (
        <ConfirmButton
            subject={row.cert_no
                ? `${typeLabel(row.cert_type_code)} · ${row.cert_no}`
                : typeLabel(row.cert_type_code)}
            title={t('suppliers.compliance.deleteConfirm')}
            body={t('common.softDeleteNote')}
            details={
                <p className="text-sm font-medium text-foreground">
                    {t('suppliers.compliance.deleteConsequence')}
                </p>
            }
            confirmLabel={t('suppliers.compliance.deleteCert')}
            tier="destructive"
            disabled={isPending}
            className="text-red-600 text-sm hover:underline disabled:text-gray-400"
            onConfirm={() => handleDelete(row.id)}
        >
            {t('suppliers.compliance.deleteCert')}
        </ConfirmButton>
    )

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-4">{t('suppliers.compliance.sectionTitle')}</h2>

            {rows.length === 0 ? (
                <p className="text-sm text-gray-500 mb-6">{t('suppliers.compliance.empty')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 mb-6">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('suppliers.compliance.colType')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('suppliers.compliance.colNo')}</th>
                            <th className="hidden sm:table-cell border border-gray-300 px-4 py-2 text-left">{t('suppliers.compliance.colIssuer')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('suppliers.compliance.colValidity')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('suppliers.compliance.colActions')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((row) => {
                            const expired =
                                row.valid_until !== null &&
                                new Date(row.valid_until) < now
                            return (
                                <tr key={row.id}>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {typeLabel(row.cert_type_code)}
                                        {/* ★ TABLE-PHONE-3:手机档被拿掉的那一列(发证机构),
                                            原样叠在这里,带着自己的列头 —— 拿掉的是那一列,不是那个事实。
                                            ★★ TABLE-STYLE-1 / R1(Tim 裁定,2026-09-09):
                                              【动作列在手机上不折】。这里原本还叠着一份删除钮,现在
                                              那一列自己留在明面上了,所以这一份【拿掉】——
                                              留着就是同一颗钮在同一行里画两遍。规矩见
                                              docs/base-components.md §二十。
                                            这张表没有数,留在列上的是【认得出是哪一张、以及它还作不作数】:
                                            种类 + 证号 + 有效期(过期就红在这一列上)。 */}
                                        <div className="sm:hidden mt-1 space-y-0.5 text-xs text-gray-600">
                                            <div>
                                                <span className="text-gray-500">{t('suppliers.compliance.colIssuer')}: </span>
                                                {row.issuing_body ?? '—'}
                                            </div>
                                        </div>
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-sm">
                                        {row.cert_no ?? '—'}
                                    </td>
                                    <td className="hidden sm:table-cell border border-gray-300 px-4 py-2 text-sm">
                                        {row.issuing_body ?? '—'}
                                    </td>
                                    <td
                                        className={`border border-gray-300 px-4 py-2 text-sm ${
                                            expired ? 'text-red-600' : ''
                                        }`}
                                    >
                                        {row.valid_from || '—'} ~ {row.valid_until || '—'}
                                        {expired && t('suppliers.compliance.expired')}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {/* CONFIRM-1:「确定删除这张证书吗?」答不上来是哪一张。
                                            主语 = 证书类型 + 证号(证号可以为空,那就只报类型)。 */}
                                        {deleteControl(row)}
                                    </td>
                                </tr>
                            )
                        })}
                    </tbody>
                </table>
            )}

            <h3 className="text-lg font-semibold mb-3">{t('suppliers.compliance.addTitle')}</h3>

            {error && (
                <p className="text-red-600 text-sm mb-3">{error}</p>
            )}

            <form key={formKey} action={handleAdd} className="space-y-3">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('suppliers.compliance.certType')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="cert_type_code"
                        required
                        defaultValue=""
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>
                            {t('suppliers.compliance.certTypePlaceholder')}
                        </option>
                        {certTypes.map((ct) => (
                            <option key={ct.code} value={ct.code}>
                                {(locale === 'zh' ? ct.name_zh : ct.name_en) +
                                    (ct.disposition === 'block' ? t('suppliers.compliance.blockSuffix') : '')}
                            </option>
                        ))}
                    </select>
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.compliance.document')}</label>
                    {/* CMP-1:证书文件引用本供应商已上传的附件(上传走下方附件面板)——
                        document_id 从此有外键、有人写入,证书记录能走到证书本身 */}
                    <select
                        name="document_id"
                        defaultValue=""
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">{t('suppliers.compliance.documentNone')}</option>
                        {attachments.map((a) => (
                            <option key={a.id} value={a.id}>
                                {a.file_name}
                            </option>
                        ))}
                    </select>
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.compliance.certNo')}</label>
                    <input
                        type="text"
                        name="cert_no"
                        placeholder={t('suppliers.compliance.certNo')}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.compliance.issuer')}</label>
                    <input
                        type="text"
                        name="issuing_body"
                        placeholder={t('suppliers.compliance.issuer')}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div className="grid grid-cols-2 gap-3">
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('suppliers.compliance.validFrom')}</label>
                        <input
                            type="date"
                            name="valid_from"
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('suppliers.compliance.validUntil')}</label>
                        <input
                            type="date"
                            name="valid_until"
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.compliance.notes')}</label>
                    <input
                        type="text"
                        name="notes"
                        placeholder={t('suppliers.compliance.notesPlaceholder')}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div className="pt-2">
                    <Button
                        type="submit"
                        disabled={isPending}
                    >
                        {isPending ? t('suppliers.compliance.adding') : t('suppliers.compliance.addButton')}
                    </Button>
                </div>
            </form>
        </section>
    )
}
