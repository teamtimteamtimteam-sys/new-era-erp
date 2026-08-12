'use server'

// LOC-1:库位主数据的服务端动作 —— 新建 / 编辑 / 停用与启用。
//
// 【允许分类是删后重插】与 pricing_formula_metals、进料含量格子同形:
// "不在表里"就是"不允许",所以一次保存就是把这个库位的允许集合整体换掉。
// 这类物理删除已记在 docs/as-built-divergences.md 第 2 条。
//
// 【没有删除动作,一个都没有】这张表没有硬删路径。下架只有停用,数据库那一侧
// 由 guard_storage_location_no_hard_delete 具名拒绝 —— 界面这一侧连按钮都不给,
// 两者说的是同一件事。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import type { InsertRow } from '@/lib/db-helpers'
import { localizeLocationError } from './locationErrorCodes'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

export type LocationFormState = {
    error?: string
    fieldErrors?: Record<string, string>
}

const LIST = '/inventory/locations'

// 表单 → 字段。code 去空白并转大写:库位号是写在货架上的东西,
// 大小写不同的"同一个号"是人不会认可的两个号。
function readForm(formData: FormData) {
    return {
        code: String(formData.get('code') ?? '').trim().toUpperCase(),
        name: String(formData.get('name') ?? '').trim(),
        zone: String(formData.get('zone') ?? '').trim() || null,
        notes: String(formData.get('notes') ?? '').trim() || null,
        classes: formData.getAll('allowed_class').map(String).filter((s) => s !== ''),
    }
}

async function validate(f: ReturnType<typeof readForm>) {
    const t = await getTranslations()
    const fieldErrors: Record<string, string> = {}
    if (!f.code) fieldErrors.code = t('locations.form.errCode')
    if (!f.name) fieldErrors.name = t('locations.form.errName')
    return Object.keys(fieldErrors).length ? fieldErrors : null
}

// 允许分类整体换掉。【空集合是合法的,它的意思是"未配置"】——
// 不是"不允许任何分类",所以这里不拦空,界面也照直把它显示成「未配置」。
async function replaceAllowedClasses(locationId: string, classes: string[]) {
    const supabase = await createClient()

    const { error: delErr } = await supabase
        .from('storage_location_allowed_classes')
        .delete()
        .eq('location_id', locationId)
    if (delErr) return delErr

    if (classes.length === 0) return null

    const { error: insErr } = await supabase
        .from('storage_location_allowed_classes')
        .insert(
            classes.map((c) => ({
                location_id: locationId,
                classification_code: c,
            })) as InsertRow<'storage_location_allowed_classes'>[]
        )
    return insErr
}

export async function createLocation(
    _prev: LocationFormState,
    formData: FormData
): Promise<LocationFormState> {
    const f = readForm(formData)
    const fieldErrors = await validate(f)
    if (fieldErrors) return { fieldErrors }

    const supabase = await createClient()
    const { data, error } = await supabase
        .from('storage_locations')
        .insert({ code: f.code, name: f.name, zone: f.zone, notes: f.notes } as InsertRow<'storage_locations'>)
        .select('id')
        .single()

    // 重号在这里现身,带着 LOC_CODE_EXISTS —— 触发器给的名字,翻成一句人话。
    if (error) return { error: await localizeLocationError(error.message) }
    if (!data) return { error: await localizeLocationError('') }

    const classErr = await replaceAllowedClasses(data.id, f.classes)
    if (classErr) return { error: await localizeLocationError(classErr.message) }

    revalidatePath(LIST)
    redirect(LIST)
}

export async function updateLocation(
    id: string,
    _prev: LocationFormState,
    formData: FormData
): Promise<LocationFormState> {
    const f = readForm(formData)
    const fieldErrors = await validate(f)
    if (fieldErrors) return { fieldErrors }

    const supabase = await createClient()
    const { error } = await supabase
        .from('storage_locations')
        .update({ code: f.code, name: f.name, zone: f.zone, notes: f.notes })
        .eq('id', id)

    if (error) return { error: await localizeLocationError(error.message) }

    const classErr = await replaceAllowedClasses(id, f.classes)
    if (classErr) return { error: await localizeLocationError(classErr.message) }

    revalidatePath(LIST)
    revalidatePath(`${LIST}/${id}/edit`)
    redirect(LIST)
}

// 停用 / 启用。【永远可点】—— 它没有前置条件:一个正被历史流水引用的库位
// 照样停得掉,那正是停用相对于删除的全部意义(历史指着的那一行继续说得出
// 自己是谁)。后果写在按钮旁边,不靠把按钮变灰来表达。
export async function setLocationActive(
    id: string,
    isActive: boolean
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase
        .from('storage_locations')
        .update({ is_active: isActive })
        .eq('id', id)

    if (error) return { error: await localizeLocationError(error.message) }

    revalidatePath(LIST)
    revalidatePath(`${LIST}/${id}/edit`)
    return {}
}
