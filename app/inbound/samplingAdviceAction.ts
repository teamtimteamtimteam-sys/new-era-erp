'use server'

// MES-8a(2026-10-16,MES-8 Step 0 Q5):收货表单上的抽样建议 —— 选了供应商之后问库(supplier_grade_advice,module.suppliers.view)。
//   没有那个码 → restricted(不是"没有建议")。只是建议,不加任何一项必须的化验。
import { createClient } from '@/lib/supabase/server'
import type { GradeAdvice } from '@/app/suppliers/scorecardTypes'

export async function samplingAdviceFor(supplierId: string): Promise<{ advice?: GradeAdvice; restricted?: boolean; error?: string }> {
    if (!supplierId) return {}
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('supplier_grade_advice', { p_supplier_id: supplierId })
    if (error) {
        if (/PERMISSION_DENIED/.test(error.message)) return { restricted: true }
        return { error: error.message }
    }
    return { advice: data as unknown as GradeAdvice }
}
