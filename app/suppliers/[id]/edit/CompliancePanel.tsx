'use client'

import { CONTROL_SELECT, CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { addCompliance, deleteCompliance } from './complianceActions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { Button } from '@/app/components/ui/button'
import { DataTable, type Column } from '@/app/components/ui/data-table'

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

    const certColumns: Column<ComplianceRow>[] = [
        {
            // 身份列:一行合规记录的主语是【哪一种证书】。
            key: 'type',
            header: t('suppliers.compliance.colType'),
            priority: true,
            render: (row) => typeLabel(row.cert_type_code),
        },
        {
            key: 'no',
            header: t('suppliers.compliance.colNo'),
            // ⚠ 转换前这一格是 text-sm;没有搬过来(列定义不许钉字号),
            //   而组件表体本来就是 14px,不写字号渲染出来是同一个值。
            priority: true,
            render: (row) => row.cert_no ?? '—',
        },
        {
            // ★ 手机档折起来的就是这一列(转换前它带着 hidden sm:table-cell,
            //   另有一份叠在种类格里带着自己的列头)—— 搬运,不是新判断。
            key: 'issuer',
            header: t('suppliers.compliance.colIssuer'),
            render: (row) => row.issuing_body ?? '—',
        },
        {
            key: 'validity',
            header: t('suppliers.compliance.colValidity'),
            priority: true,
            // ★ 过期那一抹红是【按行变的】,而组件的 Column.className 是每列一份
            //   静态串、rowClassName 管的是整行 —— 两个都不是"这一行的这一格"。
            //   TABLE-CONVERT-2 §7 已经按名登记过这处缺口,本刀没有修它,
            //   照它的处置把颜色搬进 render 里的一个 <span>。
            //   (那里要负外边距是因为搬的是【整格底色】;这里搬的只是字色,
            //    一个素 span 就够,不需要把矩形撑回整格。)
            render: (row) => {
                const expired = row.valid_until !== null && new Date(row.valid_until) < now
                const text = (
                    <>
                        {row.valid_from || '—'} ~ {row.valid_until || '—'}
                        {expired && t('suppliers.compliance.expired')}
                    </>
                )
                return expired ? <span className="text-red-600">{text}</span> : text
            },
        },
        {
            // ★★ R1(Tim 裁定):画【要按的控件】的那一列必须 priority ——
            //   够不着的删除钮等于没有这个删除钮。转换前这一列在手机上也是
            //   留在明面上的(TABLE-STYLE-1 已经把叠加块里那一份拿掉了),
            //   所以这里是原样搬运。列头保持它原来的字,没有新增 key。
            key: 'actions',
            header: t('suppliers.compliance.colActions'),
            priority: true,
            // CONFIRM-1:「确定删除这张证书吗?」答不上来是哪一张。
            // 主语 = 证书类型 + 证号(证号可以为空,那就只报类型)。
            render: (row) => deleteControl(row),
        },
    ]

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-4">{t('suppliers.compliance.sectionTitle')}</h2>

            {/* ★ TABLE-CONVERT-4:换成 DataTable。
                五列、列头、每一格的字、删除钮与它的确认框全部原样;手机档留下的
                仍然是 种类 · 证号 · 有效期 · 操作 四列,折起来的仍然只有【发证机构】。
                ★ 空态搬进了组件的 empty prop,原来那一支三元【已经拿掉】——
                  留着它 empty 就永远到不了,是一段死代码(TABLE-CONVERT-3 §6.1 的教训)。 */}
            <DataTable
                rows={rows}
                columns={certColumns}
                rowKey={(r) => r.id}
                phone={{ mode: 'columns' }}
                empty={t('suppliers.compliance.empty')}
                className="mb-6"
            />

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
                        className={`${CONTROL_SELECT} w-full`}
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
                        className={`${CONTROL_SELECT} w-full`}
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
                        className={`${CONTROL_INPUT} w-full`}
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.compliance.issuer')}</label>
                    <input
                        type="text"
                        name="issuing_body"
                        placeholder={t('suppliers.compliance.issuer')}
                        className={`${CONTROL_INPUT} w-full`}
                    />
                </div>

                <div className="grid grid-cols-2 gap-3">
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('suppliers.compliance.validFrom')}</label>
                        <input
                            type="date"
                            name="valid_from"
                            className={`${CONTROL_INPUT} w-full`}
                        />
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('suppliers.compliance.validUntil')}</label>
                        <input
                            type="date"
                            name="valid_until"
                            className={`${CONTROL_INPUT} w-full`}
                        />
                    </div>
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.compliance.notes')}</label>
                    <input
                        type="text"
                        name="notes"
                        placeholder={t('suppliers.compliance.notesPlaceholder')}
                        className={`${CONTROL_INPUT} w-full`}
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
