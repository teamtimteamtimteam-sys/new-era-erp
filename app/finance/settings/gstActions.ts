'use server'

// GST-3:注册开关的写入路径 —— **在这一刀之前它一条都没有。**
// `finance_settings.gst_registered` 在 app/ 里只被【读】过(七处),
// 于是 GST-1 与 GST-2 两刀的成果没有任何一个人碰得到,手走清单 §17 整节
// 100% 走不了。而这件事不是任何一道检查发现的,是 Tim 发现的。
//
// 【闸不在这里,在数据库上】trg_gst_switch 守两个方向(开:登记号必须在册;
// 关:带税码的费用单冲销不了 / 在册的带税发票会留下矛盾状态)。
// 这里只负责把它的具名拒绝翻成人话 —— 一条有句子却到不了屏幕的拒绝,
// 等于没有句子(IOD-2 那一课,setPeriodLock 抬头逐字记着同一条)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'
import { localizeFinanceError } from '../financeErrorCodes'

export type GstSwitchState = { error?: string }

export async function setGstRegistration(
    on: boolean,
    registrationNo: string
): Promise<GstSwitchState> {
    const t = await getTranslations()
    const supabase = await createClient()
    // 【接住 auth 的 error —— 丢掉它,"认证够不着"与"这个人没登录"会走同一条分支】
    // 而在这里那条分支的后果特别难看:两者都会让 updated_by 落成 null,
    // 于是【翻开关的是谁】这件事悄悄消失,而这是一个要留痕的动作 ——
    // 打开 GST 会立刻改变每一张新单据的形状。
    // **答不出"谁"的时候就不改**,而不是记一条没有主语的变更
    // (与"一次删除要记下谁和为什么"同一条规矩)。
    const { data: { user }, error: userErr } = await supabase.auth.getUser()
    if (userErr || !user) {
        return { error: t('finance.gstSwitch.authUnknown') }
    }

    const trimmed = registrationNo.trim()

    // 【开的时候先在这里问一次,而这【不是】把闸搬过来】数据库那条
    // GST_REGISTRATION_NO_REQUIRED 仍然是唯一的正确性来源(直连 UPDATE 也逃不掉)。
    // 这一句只是让人不必按下一个注定被拒的按钮 —— CMP-2:禁用与说明要在动作之前。
    if (on && trimmed === '') {
        return { error: t('finance.errors.GST_REGISTRATION_NO_REQUIRED') }
    }

    // 【一次 UPDATE 同时写两列】号码与开关必须在同一条语句里落地,
    // 否则"先写号码、再开开关"中间存在一个【已注册但没有号】的瞬间,
    // 而那正是这条规矩要消灭的状态。触发器也是按 NEW 的两列一起判的。
    const { error } = await supabase
        .from('finance_settings')
        .update({
            gst_registered: on,
            gst_registration_no: trimmed === '' ? null : trimmed,
            updated_by: user.id,
        })
        .eq('id', true)

    if (error) {
        return { error: await localizeFinanceError(error.message) }
    }

    // 开关一翻,这些页面的渲染【形状】就变了(税码那一格出现或消失),
    // 不只是数字变了 —— 所以逐个 revalidate,不指望某一次导航碰巧刷新它们。
    revalidatePath('/finance/settings')
    revalidatePath('/finance/gst')
    revalidatePath('/finance/invoices/new')
    revalidatePath('/finance/expenses/new')
    return {}
}
