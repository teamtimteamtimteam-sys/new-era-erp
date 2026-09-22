import { getTranslations } from '@/lib/i18n/server'

// APR-2(2026-09-22):`SELF_APPROVAL_FORBIDDEN` 的那两句人话,【只写一遍】。
//
// 数据库那一侧的判据也只有一份(db/functions/forbid_self_approval.sql),
// 它抛的是带后缀的码:
//     SELF_APPROVAL_FORBIDDEN|raiser    —— 这张单是你提的
//     SELF_APPROVAL_FORBIDDEN|subject   —— 这张单说的就是你
//
// 【为什么两句话,不是一句带参数的】它们的【下一步动作不同】,而这正是本仓库
// 反复写下的那条判据:提单的人要去找同事批;单据的主角要去找【别人】来批,
// 而"别人"里可能根本没有第二个持有那个权限的人 —— 后者常常是一次真的配置问题。
// 一条共用的句子会把这个区别藏起来。
//
// 【裸码仍然要接住】approve_purchase_order / reject_purchase_order 【没有改】
// (Tim 的委托书:leave them),它们抛的仍然是裸的 SELF_APPROVAL_FORBIDDEN;
// 采购单也确实没有"这张单说的是谁"这条腿。所以三种形状都要有去处。
export async function localizeSelfApproval(param: string | undefined | null): Promise<string> {
    const t = await getTranslations()
    if (param === 'subject') return t('common.selfApprovalSubject')
    if (param === 'raiser') return t('common.selfApprovalRaiser')
    return t('common.selfApprovalGeneric')
}
