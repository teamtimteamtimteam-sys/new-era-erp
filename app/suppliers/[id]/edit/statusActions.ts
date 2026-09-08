'use server'

import { createClient } from '@/lib/supabase/server'
import type { Database } from '@/lib/database.types'
import { revalidatePath } from 'next/cache'
import { refuseFromCoded, refuseNothingChanged } from '@/lib/action-refusal'
import { localizeSupplierError } from '@/app/suppliers/supplierErrorCodes'

export type ChangeStatusState = {
    error?: string
    /** ALERT-1:降级后的数据库原文 —— 永远不做标题。 */
    detail?: string
    success?: boolean
}

export async function changeSupplierStatus(
    id: string,
    newStatus: Database['public']['Enums']['supplier_status']
): Promise<ChangeStatusState> {
    const supabase = await createClient()

    const { data, error } = await supabase
        .from('suppliers')
        .update({ status: newStatus })
        .eq('id', id)
        .is('deleted_at', null)
        // ★ ALERT-1:见 app/materials/actions.ts 的同一段注释 ——
        //   没有这一行,一次被 RLS 挡下的状态变更会报告成功。
        .select('id')

    if (error) {
        // ★★【SILENT-1:这一处的原文【不再是中文散文】】★★
        //   validate_supplier_status_transition 从前抛的是
        //   `RAISE EXCEPTION '非法状态跳转: % → %'` —— 一句散文,不是码。
        //   本地化器接不住散文,于是英文界面上出现
        //   「Status change failed: 非法状态跳转: active → draft」。
        //   本刀把它换成 `INVALID_STATUS_TRANSITION|<from>|<to>`,
        //   与 PERMISSION_DENIED|<码> 逐字同一个形状,localizeSupplierError 认得它。
        //   ☞【注释里【不写】那个字面调用形状】check-i18n 照字面抓,
        //     一句注释会污染将来对它自己的计数 —— 这条法则本仓库付过三次学费。
        //   refuseFromCoded 的三支分支在这里都用得上:
        //     ① PERMISSION_DENIED 先接(本刀给 suppliers 装了库侧闸,它现在真的会来);
        //     ② 本地化器认出 INVALID_STATUS_TRANSITION → 那句人话;
        //     ③ 都不是 → 原文降级进 detail,标题换成说得出下一步的话。
        return await refuseFromCoded(error.message, localizeSupplierError)
    }

    // ★ 零行落地 = 状态没有变。见 app/materials/actions.ts 的注释。
    if (!data || data.length === 0) {
        return await refuseNothingChanged('module.suppliers.edit')
    }

    revalidatePath('/suppliers')
    revalidatePath(`/suppliers/${id}/edit`)
    return { success: true }
}