// app/hr/reviews/scale/page.tsx
// 评级档位配置。加一档、停用一档都是【数据】,不该需要发版 —— 与假别配置同一套路。
// code 一列只读:评估行与历史都靠它认这一档。
import Link from 'next/link'
import { mustRows } from '@/lib/db-helpers'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import ScaleEditor, { type ScaleRow } from './ScaleEditor'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function RatingScalePage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const res = await supabase.from('review_rating_scale').select('*').order('sort_order')
    return (
        <div className="p-8 max-w-6xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <Subnav />
            <div className="flex items-baseline justify-between mb-4">
                <h2 className="text-xl font-bold">{t('reviews.scaleTitle')}</h2>
                <Link href="/hr/reviews" className="text-sm text-blue-600 hover:underline">
                    {t('common.back')}
                </Link>
            </div>
            <p className="text-sm text-gray-600 mb-4">{t('reviews.scaleIntro')}</p>
            <ScaleEditor rows={mustRows(res) as ScaleRow[]} />
        </div>
    )
}
