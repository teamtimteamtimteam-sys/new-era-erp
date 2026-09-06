'use client'

// 补上/更换评估人(set_review_reviewer;module.hr.edit)。
// 评估轮管理页与评估文档页共用 —— 没有评估人的评估不该要人去待办看板里找。
//
// 【PAY-1:三种禁用,此前一种理由都不说】按钮的禁用条件是
// `pending || !value || value === currentReviewerId`,而屏幕上一个字都没有。
// 最坏的一种是【下拉里根本没有人可选】:自己不能评自己,所以候选是"除本人以外
// 的在册员工";线上今天只有三名员工(其中一名还是冒烟残骸),所以这个空下拉
// 是【现实中会发生的那一种】,而不是理论情形。那时按钮永远按不下去,
// 而人只会以为页面坏了 —— CMP-2 那条:一个按不下去又不说为什么的按钮,
// 读起来就是坏的。
//
// 【真正的补救在别处,所以这里只把条件说出来】"没有人可选"要靠把组织图录进来
// (EXEC-0b 计划里的 org-fill),那是一次 HR 数据录入,不是这个组件能做的事。
// 所以这一支的文案说的是【条件】与【去哪里补】,而不是假装它能被这里解决。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { setReviewer } from './actions'

export type EmployeeOption = { id: string; code: string; legal_name: string }

type Props = {
    reviewId: string
    employees: EmployeeOption[]
    currentReviewerId: string | null
    subjectEmployeeId: string // 自己不能评自己:选项里直接不出现
}

export default function SetReviewerControl({ reviewId, employees, currentReviewerId, subjectEmployeeId }: Props) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [value, setValue] = useState(currentReviewerId ?? '')

    // 候选 = 除本人以外的在册员工(自己不能评自己,CHECK not_self_review)
    const candidates = employees.filter((e) => e.id !== subjectEmployeeId)
    // 【每一种禁用都算出它自己的理由】—— 顺序就是它们互相遮蔽的顺序:
    // 没有人可选是最根本的一种,它一旦成立,后两种说什么都没有意义。
    const why = candidates.length === 0 ? t('reviews.blocked.noCandidates')
        : !value ? t('reviews.blocked.pickOne')
        : value === currentReviewerId ? t('reviews.blocked.sameAsCurrent')
        : ''

    function save() {
        if (!value) return
        setError(null)
        startTransition(async () => {
            const r = await setReviewer(reviewId, value)
            if (r.error) setError(r.error)
            else router.refresh()
        })
    }

    // ★【PRE-ACCOUNT-1】390px:这一行从前【不换行】,而 <select> 按最宽的那个
    //   <option>(「工号 · 姓名」)定宽 —— 员工名一长,整行把页面顶出去。
    //   实测 /hr/reviews/[id] +37px。被点名的元凶是旁边那个琥珀色的
    //   「为什么按不动」,但撑宽的是这个 select —— CONV-10 在
    //   /logistics/containers/[id] 上量到的是同一个形状,并且把它写成了一条规矩:
    //   **culprit 是溢出边界上的那个元素,不一定是造成溢出的那个。**
    //   修法与那一处逐字相同:让这一行换行,并且不许 select 超过容器。
    //   ☞ 这个组件被 /hr/reviews/[id] 与 /hr/reviews/cycles 【两页共用】,
    //     所以这一处改动一次修好两页。
    return (
        <span className="inline-flex flex-wrap items-center gap-2 max-w-full">
            <select
                value={value}
                onChange={(e) => setValue(e.target.value)}
                className="border border-gray-300 rounded px-2 py-1 text-sm max-w-full min-w-0"
            >
                <option value="">{t('reviews.pickReviewer')}</option>
                {candidates
                    .map((e) => (
                        <option key={e.id} value={e.id}>
                            {e.code} · {e.legal_name}
                        </option>
                    ))}
            </select>
            <Button
                variant="link"
                size="inline"
                type="button"
                onClick={save}
                disabled={pending || why !== ''}
            >
                {t('reviews.assign')}
            </Button>
            {/* 【禁用了就把理由摆在旁边】(CMP-2) */}
            {why && <span className="text-xs text-amber-700">{why}</span>}
            {error && <span className="text-xs text-red-700">{error}</span>}
        </span>
    )
}
