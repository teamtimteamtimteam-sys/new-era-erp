// app/hr/reviews/scale/page.tsx
// 评级档位配置。加一档、停用一档都是【数据】,不该需要发版 —— 与假别配置同一套路。
// code 一列只读:评估行与历史都靠它认这一档。
//
// CONV-2:外壳换成 <ListPage>。
// ★【这一页有两级标题,而外壳只有一个 title 槽】★
//   原来的版式是 h1「人力资源」→ h2「评级档位」+ 返回链接 → 一句说明 → 表。
//   `intro` 画在 `notices` 【之前】,所以把 h2 放进 notices 而 intro 留空,
//   才能一字不差地保住这个顺序。**这是第二处 notices 在替别的东西站岗**
//   (第一处是 /hr/leave/types 的子导航)—— 见 docs/editable-grid-template.md §⑥。
import Link from 'next/link'
import { mustRows } from '@/lib/db-helpers'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import ScaleEditor, { type ScaleRow } from './ScaleEditor'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'

export default async function RatingScalePage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const res = await supabase.from('review_rating_scale').select('*').order('sort_order')
    const rows = mustRows(res) as ScaleRow[]

    return (
        <ListPage
            title={t('hr.title')}
            maxWidth="max-w-6xl"
            notices={
                <>
                    <div className="mb-4 flex items-baseline justify-between gap-2">
                        <h2 className="text-xl font-bold">{t('reviews.scaleTitle')}</h2>
                        <Link href="/hr/reviews" className="text-sm text-blue-600 hover:underline">
                            {t('common.back')}
                        </Link>
                    </div>
                    <p className="mb-4 text-sm text-gray-600">{t('reviews.scaleIntro')}</p>
                </>
            }
            // ★★★【这一页【不能】用外壳的 empty 分支 —— 差一点就发出去了】★★★
            //
            //   外壳只在 `ok` 时画 children,而这一页的 children 里有那张
            //   **「新增一档」的卡** —— 它正是把空态变成非空的【唯一出口】。
            //   走 `{ kind: 'empty' }` 的话:一张空的档位表会画出一句
            //   「还没有任何档位」,然后把那张唯一能加一档的卡一起藏掉,
            //   **人被留在一个自己走不出去的空页上。**
            //
            //   这与 CONV-1 在 /sales/commissions 撞见的是【同一个缺陷的第三种出口】:
            //   ① 无条件提示被 ok 分支吃掉(CONV-1 加了 notices);
            //   ② 子导航被吃掉(本刀 /hr/leave/types,暂借 notices);
            //   ③ **把空态变成非空的那个动作本身被吃掉**(这里)。
            //
            //   所以空态那句话交给【表】自己说(EditableTable 的 empty),
            //   外壳恒为 ok。**一句空态的归属,取决于【出口】在谁里面。**
            //   见 docs/editable-grid-template.md §⑥。
            state={{ kind: 'ok' }}
        >
            <ScaleEditor rows={rows} />
        </ListPage>
    )
}
