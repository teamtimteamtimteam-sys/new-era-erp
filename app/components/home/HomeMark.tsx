'use client'

// app/components/home/HomeMark.tsx
// ════════════════════════════════════════════════════════════════════════════
// UI-1b ①·② · 首页那个大字标 —— 平日一张,节日窗口里换一张
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【顶栏那个标记不在这里,也永远不换】★★
// 这个组件只画【首页】那一个。顶栏画的是 app/components/TopNav.tsx 里的
// `<Wordmark>`(`evoltrya-os-black.svg`,黑白 25.5px)。**它不 import 本文件,
// 本文件也不 import 它** —— 那就是「顶栏永不换」这条保证的机械形式,
// 不是一句承诺。理由见 lib/festivalDoodle.ts 抬头。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【为什么它必须是 'use client' —— 只为一件事:onError】★★
// ════════════════════════════════════════════════════════════════════════════
//
// 委托书:**一张加载失败的节日画,是这一页最坏的失败。** 一个碎图标占着页面
// 正中央,比没有节日画糟得多 —— 它看起来像整套系统坏了。
//
// 服务端渲染不出"这张图取不到"这件事:HTTP 200 的 HTML 里,`<img src>` 取不取
// 得到要等浏览器去试。**所以回退只能长在客户端**,而 `onError` 是唯一能
// 观察到它的地方。这是本组件唯一的 'use client' 理由 —— 没有 state 机器、
// 没有数据获取,一个 `useState<boolean>` 而已。
//
// ★【回退【不是】换一个 src 让它再试一次】★ 那会在 src 也坏的时候变成一个
//   死循环(错误 → 换 → 错误 → 换)。这里是**一次性**地把 `failed` 置真,
//   然后渲染平日字标 —— 一条单向的闸,不是一次重试。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【两张图共用一个盒子,所以页面上没有东西会动】★★
// ════════════════════════════════════════════════════════════════════════════
//
// 23 张节日画在 scripts/build-festival-doodles.mjs 里被归一化成【同一个】
// 3.40:1 的画框(1224×360),而 3.40:1 正是 `evoltrya-wordmark.svg` 自己的
// viewBox 比例(1204.72 / 354.331)。所以:
//   · 平日字标与任何一张节日画,占的是【同一个矩形】;
//   · `aspect-ratio` 写在盒子上,**图还没加载时那个矩形就已经占好位** ——
//     于是问候语与搜索框不会在图落地的一瞬间往下跳;
//   · 回退发生时也不跳:回退目标与它替换掉的东西一样大。
//
// 尺寸 `clamp(15rem, 60vw, 26rem)` = 240→416px 宽、71→122px 高。
// **比登录页那个大**(那里是 `clamp(9.5rem, 42vw, 14.5rem)`,152→232px):
// 登录页的字标是一张表单上方的【标签】,这一个是这一页的【主语】。
// 而它仍然窄于搜索外壳的 34rem(544px),所以最宽的东西还是搜索框 ——
// 这一页读起来是一张落地页,不是一张表单。
import { useState } from 'react'
import { useLocale, useTranslations } from '@/lib/i18n/client'
// 【样式与首页同一份】home.module.css —— 盒子的 aspect-ratio 与 clamp 尺寸写在
// 那里,与 .stage / .shell 挨着,好让"字标比搜索框窄"这条关系读得出来。
import styles from '@/app/home.module.css'

export type HomeMarkProps = {
    /** 今天的节日画;null = 平日。服务端算好传进来(lib/festivalDoodle.ts)。 */
    doodle: { holidayKey: string; nameEn: string; nameZh: string; src: string } | null
}

/** 平日字标。**LOGIN-1 的裁定:界面里球体只以字标里那个「O」的形式出现** —— 不合成。 */
const WORDMARK = '/brand/evoltrya-wordmark.svg'

export default function HomeMark({ doodle }: HomeMarkProps) {
    const t = useTranslations()
    const locale = useLocale()
    const [failed, setFailed] = useState(false)

    const showDoodle = doodle !== null && !failed
    // 【节日名按界面语言【选一个】,不是把两种拼起来】—— 同一个插值里三元,
    // 这正是 scripts/check-bilingual-concat.mjs 认可的写法(它抬头点名了这一形状)。
    const festivalName = doodle ? (locale === 'zh' ? doodle.nameZh : doodle.nameEn) : ''

    return (
        <div
            className={styles.mark}
            data-home-mark={showDoodle ? 'doodle' : 'wordmark'}
            data-home-doodle-key={showDoodle ? doodle.holidayKey : undefined}
        >
            {/* eslint-disable-next-line @next/next/no-img-element -- 见下 */}
            <img
                className={styles.markImg}
                // ★【为什么不用 next/image】两条,各自独立成立:
                //   ① 平日那张是 SVG,next/image 无从优化(login/page.tsx:129 已为
                //      同一个理由写过一次 eslint-disable);
                //   ② 节日那 23 张【已经是】按最终渲染尺寸编码好的 WebP
                //      (1224 宽 = 416px × DPR 3),再过一次优化器只是多一跳。
                //   两张必须走同一个标签,否则回退时会换掉整个元素,而那会闪。
                src={showDoodle ? doodle.src : WORDMARK}
                alt={showDoodle ? t('home.doodleAlt', { name: festivalName }) : t('home.markAlt')}
                // ★ 回退只发生一次,而且只向一个方向(见抬头)。
                onError={() => setFailed(true)}
                // 节日画是 LCP 元素,而它每次都是一张新文件 —— 不该等到布局之后才开始取。
                fetchPriority="high"
                draggable={false}
            />
        </div>
    )
}
