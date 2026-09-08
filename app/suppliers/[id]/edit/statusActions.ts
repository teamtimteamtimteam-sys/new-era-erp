'use server'

import { createClient } from '@/lib/supabase/server'
import type { Database } from '@/lib/database.types'
import { revalidatePath } from 'next/cache'
import { refuseFromDriver, refuseNothingChanged } from '@/lib/action-refusal'

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
        // ★★【这一处的原文【是中文】,而界面可能是英文的】★★
        //   validate_supplier_status_transition 抛的是
        //   `RAISE EXCEPTION '非法状态跳转: % → %'` —— 一句【中文散文,不是码】。
        //   旧写法把它拼进那个「状态变更失败:{message}」的模板里(消息键
        //   suppliers.statusPanel 下的 changeError),于是英文界面上出现
        //   「Status change failed: 非法状态跳转: active → draft」。
        //   ☞【注释里【不写】那个字面调用】本刀第一版把那句模板写成了真的调用形状,
        //     check-i18n 照字面抓,当场把注释当成了一处缺键 —— AGENTS.md 记过这个形状:
        //     一句注释会污染将来对它自己的计数。这一行是那条法则的第三次学费。
        //   本地化器接不住一句散文,所以这里只能退到那句写好的兜底,把原文降级。
        //   ☞ 正解是给这个触发器一个【码】,那是一次迁移 —— ALERT-1 闸上登记为独立一刀。
        return await refuseFromDriver(error.message)
    }

    // ★ 零行落地 = 状态没有变。见 app/materials/actions.ts 的注释。
    if (!data || data.length === 0) {
        return await refuseNothingChanged('module.suppliers.edit')
    }

    revalidatePath('/suppliers')
    revalidatePath(`/suppliers/${id}/edit`)
    return { success: true }
}