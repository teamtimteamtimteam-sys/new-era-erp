'use server'

// 评级档位的维护。RLS 在写入策略上要 module.hr.edit,所以这里不重复判断 ——
// 没权限的人写不进去,数据库会拒。(同 leave_types 的 actions)
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'

export type CfgState = { error?: string; success?: boolean }

type ScalePatch = {
    name_en: string
    name_zh: string
    description_en: string | null
    description_zh: string | null
    sort_order: number
    is_active: boolean
    is_probation_pass: boolean
}

// isNew 时 code 一起写入;既有档位的 code 不改 —— 评估行靠它认这一档。
export async function saveRatingScale(
    code: string,
    patch: ScalePatch,
    isNew: boolean
): Promise<CfgState> {
    const supabase = await createClient()
    const { error } = isNew
        ? await supabase.from('review_rating_scale').insert({ code, ...patch })
        : await supabase.from('review_rating_scale').update(patch).eq('code', code)
    if (error) return { error: error.message }
    revalidatePath('/hr/reviews/scale')
    revalidatePath('/hr/reviews')
    return { success: true }
}
