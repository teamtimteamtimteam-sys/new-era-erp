'use client'

// ★ APR-7(Tim 2026-09-25):注销批次、加工回滚、作废销毁证书 —— 仓库提,CFO 批每一张,批准之前什么都不发生。
//   这是三处(进料 / 产出的注销钮、加工单的回滚钮、证书面板的作废钮)共用的【提申请】按钮:
//   对话框问理由,提交一张申请;成功之后就地说"已交给 CFO"(审批关着时:"已生效")。
//   ☞ 一张在等的申请碰到这一样东西时(openRequestLabel),按钮看得见、按不动、说出是哪一张在等 ——
//     库里同样按名拒(WAREHOUSE_REQUEST_OPEN)。
//   ☞ 码的那一半由 PermissionGate 管(看得见、按不动、点名那个码)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { useTranslations } from '@/lib/i18n/client'
import { submitWarehouseRequest, type WarehouseRequestKind } from './warehouseRequestActions'

export default function WarehouseRequestButton({
    kind, subjectId, subjectCode, permissionCode, allowed, openRequestLabel, extraPath, size = 'inline',
}: {
    kind: WarehouseRequestKind
    subjectId: string
    subjectCode: string
    permissionCode: string
    allowed: boolean
    openRequestLabel?: string | null
    extraPath?: string
    size?: 'inline' | 'default'
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [done, setDone] = useState('')

    return (
        <span className="inline-flex flex-col items-start">
            <PermissionGate code={permissionCode} allowed={allowed} inline={size === 'inline'}>
                <ConfirmButton
                    subject={subjectCode}
                    title={t('warehouseRequest.submitTitle.' + kind)}
                    body={t('warehouseRequest.submitBody.' + kind)}
                    confirmLabel={t('warehouseRequest.submit')}
                    tier="destructive"
                    reason={{ placeholder: t('warehouseRequest.reasonPlaceholder.' + kind) }}
                    triggerVariant="destructive"
                    triggerSize={size === 'inline' ? 'inline' : undefined}
                    disabled={isPending || !!openRequestLabel || !!done}
                    onConfirm={(reason) => {
                        setError('')
                        startTransition(async () => {
                            const res = await submitWarehouseRequest(kind, subjectId, reason, extraPath)
                            if (res.error) {
                                setError(res.error)
                                return
                            }
                            if (res.request) {
                                setDone(res.request.status === 'approved'
                                    ? t('warehouseRequest.sentApproved', { label: res.request.label })
                                    : t('warehouseRequest.sentSubmitted', { label: res.request.label }))
                            }
                            router.refresh()
                        })
                    }}
                >
                    {isPending ? t('common.saving') : t('warehouseRequest.trigger.' + kind)}
                </ConfirmButton>
            </PermissionGate>
            {openRequestLabel && (
                <span className="mt-1 text-xs text-[color:var(--brand-muted-text)] max-w-56" data-state-note="warehouse-request-open">
                    {t('warehouseRequest.waiting', { label: openRequestLabel })}
                </span>
            )}
            {done && <span className="mt-1 text-xs text-[color:var(--brand-muted-text)] max-w-56" role="status">{done}</span>}
            {error && <span className="mt-1 text-xs text-destructive-text">{error}</span>}
        </span>
    )
}
