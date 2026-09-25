'use client'

// AUDEL-2:回滚前先问【为什么】,而且把后果摆在按下之前。
// 这不是"删掉一条记录":它还原投入、作废产出、写一整串冲销流水。
//
// ★ APR-7(Tim 2026-09-25):回滚是【一张给 CFO 的申请】,批准之前什么都不发生 —— 这一颗钮提申请
//   (共用的 WarehouseRequestButton;后果那一句在对话框的 body 里,照旧在按下之前就在眼前)。
//   一张在等的申请碰到这张单时(openRequestLabel),看得见、按不动、说出是哪一张在等。
//   库里的旧门 rollback_processing_run 一张都不回滚了(WAREHOUSE_NEEDS_APPROVED_REQUEST)。
// ★ ROLE-1 Batch 3b:提回滚申请的码是 action.processing_rollback(仓库、管理员)。
//   canRollback 由页面 can() 算好传进来;缺码时看得见、按不动、点名那个码。
import WarehouseRequestButton from '@/app/components/inventory/WarehouseRequestButton'

export default function DeleteButton({ runId, code, canRollback, openRequestLabel }: {
    runId: string; code: string; canRollback: boolean; openRequestLabel?: string | null
}) {
    return (
        <div className="inline-flex flex-col items-end">
            <WarehouseRequestButton kind="rollback" subjectId={runId} subjectCode={code}
                permissionCode="action.processing_rollback" allowed={canRollback}
                openRequestLabel={openRequestLabel} extraPath={`/operation/processing/${runId}`} size="default" />
        </div>
    )
}
