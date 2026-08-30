'use server'

// CMPL-1:进口尽调的写入口 —— **记录一次人的核对,不是一次系统判断**。
//
// ★★【为什么这条路【告警】而不是【拒绝】—— 写在这里,因为下一个人一定会问】★★
//   本仓库的标准是:**当下判得了的可以拒;判不了的只能提醒。**
//
//   · **判得了的那一半【今天已经在拒】** —— certificate_types 里 nea_import
//     (NEA Import Permit)的 disposition 是 block,一张过期的准证会经
//     supplier_receiving_blocked → trg_inbound_batches_po_receivable **拦在收货上**。
//     本刀**不重复它,也不在它旁边加第二道**。
//
//   · **本刀这一半判不了** —— 执照正文要求的是「交货方【在进口当时】持有准证」,
//     那是一件关于**过去**、关于**某一票具体货**的事实。系统手上没有那一刻的准证
//     状态,只有一份【人核对过】的断言。**对一件系统确立不了的事实设一道拒绝,
//     是把判断伪装成机制。**
//
//   【两个方向的代价,都写出来】
//     · 错拒:一车合规的货被拦在门口 —— 代价不只是那一车,是**它会制造绕过这道闸
//       的压力**,而一道被绕过去的闸比没有闸更坏(本仓库记过这一条)。
//     · 错放:收了一票没有准证的进口货,违反我们自己的执照条件 —— 但**判得了的
//       那一半已经拦着**,而这一半留下的是一条【谁核的、核的是哪张准证、什么时候核的】
//       的记录,它既追得了责,也拿得出去给监管方看。

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'

export async function saveImportDiligence(
    batchId: string,
    imported: 'unknown' | 'no' | 'yes',
    permitRef: string,
    markVerified: boolean,
) {
    const supabase = await createClient()
    const t = await getTranslations()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError) return { error: t('inbound.importDiligence.errors.AUTH_UNAVAILABLE') }

    // 【三个状态 + 一个"还没说"】—— NULL 绝不等于 false。
    const isImported = imported === 'unknown' ? null : imported === 'yes'

    // 不是进口货(或还没说)时,核验记录必须一并清掉 —— 表上的 CHECK 也这么要求,
    // 而在这里先清是为了让人看到的是一次干净的改动,不是一句约束违反。
    const row = isImported === true
        ? {
              imported: true,
              import_permit_ref: permitRef.trim() === '' ? null : permitRef.trim(),
              ...(markVerified
                  ? { import_permit_verified_by: user?.id ?? null, import_permit_verified_at: new Date().toISOString() }
                  : { import_permit_verified_by: null, import_permit_verified_at: null }),
          }
        : {
              imported: isImported,
              import_permit_ref: null,
              import_permit_verified_by: null,
              import_permit_verified_at: null,
          }

    const { error } = await supabase.from('inbound_batches').update(row).eq('id', batchId)
    if (error) {
        if (/row-level security|42501/i.test(error.message)) {
            return { error: t('inbound.importDiligence.errors.NOT_PERMITTED') }
        }
        return { error: error.message }
    }

    revalidatePath(`/inbound/${batchId}/edit`)
    return { success: true }
}
