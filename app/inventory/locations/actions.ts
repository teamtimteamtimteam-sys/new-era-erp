'use server'

// LOC-1:库位主数据的服务端动作 —— 新建 / 编辑 / 停用与启用。
//
// 【允许分类:一次调用、只写变了的】(AUDIT-TRAIL-1b-3,Tim 的 Q13)此前这里是三次写 —— 改库位那一行、
// 删掉全部允许分类、再把勾上的全部插回去 —— 于是审计记录里没动过的分类每保存一次都读成"拿掉了"又"加上了",
// 还分成三条记录。现在新建与修改都走 save_storage_location:库位那一行只有真的变了才写,分类只删不再勾着的、
// 只插新勾上的,全在一笔事务里。"不在表里"仍然就是"不允许"(物理删除那一条,docs/as-built-divergences.md 第 2 条)。
//
// 【没有删除动作,一个都没有】这张表没有硬删路径。下架只有停用,数据库那一侧
// 由 guard_storage_location_no_hard_delete 具名拒绝 —— 界面这一侧连按钮都不给,
// 两者说的是同一件事。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
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
        // MES-3a(Q17):隔离库位。复选框没勾时表单里没有这个键 —— 那是"否",不是"不改"(这张表单总是画着它)。
        isQuarantine: formData.get('is_quarantine') === 'on',
    }
}

async function validate(f: ReturnType<typeof readForm>) {
    const t = await getTranslations()
    const fieldErrors: Record<string, string> = {}
    if (!f.code) fieldErrors.code = t('locations.form.errCode')
    if (!f.name) fieldErrors.name = t('locations.form.errName')
    return Object.keys(fieldErrors).length ? fieldErrors : null
}

// 新建与修改共用一扇门。【空集合是合法的,它的意思是"未配置"】—— 不是"不允许任何分类",
// 所以这里不拦空,界面也照直把它显示成「未配置」。
async function saveLocation(id: string | null, f: ReturnType<typeof readForm>) {
    const supabase = await createClient()
    // 可空的三个参数在库里带 DEFAULT NULL —— 不传就是 NULL(新建没有 id;区域与备注可以留空)
    return supabase.rpc('save_storage_location', {
        p_code: f.code, p_name: f.name, p_classes: f.classes,
        p_id: id ?? undefined, p_zone: f.zone ?? undefined, p_notes: f.notes ?? undefined,
        p_is_quarantine: f.isQuarantine,
    })
}

export async function createLocation(
    _prev: LocationFormState,
    formData: FormData
): Promise<LocationFormState> {
    const f = readForm(formData)
    const fieldErrors = await validate(f)
    if (fieldErrors) return { fieldErrors }

    const { data, error } = await saveLocation(null, f)

    // 重号在这里现身,带着 LOC_CODE_EXISTS —— 触发器给的名字,翻成一句人话。
    if (error) return { error: await localizeLocationError(error.message) }
    if (!data) return { error: await localizeLocationError('') }

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

    const { data, error } = await saveLocation(id, f)

    if (error) return { error: await localizeLocationError(error.message) }
    if (!data) return { error: await localizeLocationError('') }

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
