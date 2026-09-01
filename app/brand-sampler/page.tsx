// ════════════════════════════════════════════════════════════════════════════
// ★★★ 临时页 · BRAND-1(2026-09-02)· 用完即删 ★★★
//
// 【它是干什么的】让 Tim 看着三个成体系的样式变体,【指一个】。
// 样子选不出来是因为它没法用散文描述 —— 所以有了这一页。
//
// 【它不是产品的一部分】
//   * 不在导航里(lib/modules.ts 一个字都没动);
//   * 不在冒烟的路由清单里(scripts/smoke-routes.mjs 的 walk() 显式排除,
//     并且【不是】写进 EXPECTED_SKIPS —— 那一栏的含义是「表里没有数据」,
//     用在这里是一句假话);
//   * 不连数据库(样例数据在 ./data.ts,全是照真源的形状现编的);
//   * Tim 选定之后,【连同 app/brand-sampler/ 整个目录一起删掉】,
//     并把 scripts/smoke-routes.mjs 里那三行排除也一起删掉。
//
// 【为什么它看起来和系统里别的页不一样 —— 这是对的】
// 本页用 Google Sans 渲染;而【全站现在仍然是 Arial】。
// R2 说产品字体是 Google Sans,R3 说这一刀不许改任何已上线页面的样子 ——
// 两条直接冲突,处置是 R3 赢:字体在这里加载、在这里演示,
// 全站切换留给【一次单独的、看得见的决定】,由 Tim 看过这一页之后再做。
// 所以本页与 /inbound 字体不同,不是 bug,是那个决定还没做。
// ════════════════════════════════════════════════════════════════════════════

import type { Metadata } from 'next'
import { Google_Sans } from 'next/font/google'
import { Variant, type Spec } from './Variant'

// R2 · Google Sans 由 next/font 在【构建期】取回并自托管(不打 Google 的服务器,
// 没有第三方请求)。只在本页加载 —— 别的页面【连下载都不会发生】。
// 【中文不在它的 subset 里】:Google Sans 有 25 个 subset,没有 chinese-simplified。
// 于是中文落到下面 fallback 链里的系统字体(Mac 上 PingFang SC、Windows 上微软雅黑)。
// 那正是【今天的现状】—— body 现在是 `Arial, Helvetica, sans-serif`,中文一样落到系统字体。
// 详见 docs/brand-tokens.md「中文用什么字渲染」。
const googleSans = Google_Sans({
    subsets: ['latin'],
    weight: ['400', '500', '700'],
    variable: '--font-google-sans',
    display: 'swap',
    fallback: ['ui-sans-serif', 'system-ui', '-apple-system', 'PingFang SC',
        'Microsoft YaHei', 'Noto Sans SC', 'sans-serif'],
})

export const metadata: Metadata = {
    title: 'BRAND-1 样式取样 · 临时页',
    // 【别让它被收录】这是一个用完即删的内部页。
    robots: { index: false, follow: false },
}

const SPECS: Spec[] = [
    {
        key: 'ledger',
        name: 'A · Ledger(账簿)',
        oneLiner: '紧凑 · 全边框表 · 实心按钮 · 无投影 · 拒绝态是灰斜体',
        cellPad: 'px-2 py-1', text: 'text-sm',
        primary: 'default', secondary: 'outline',
        table: 'bordered',
        card: 'border-[color:var(--brand-border)] shadow-none',
        headRow: 'bg-[color:var(--brand-muted)]',
        refusal: 'plain',
    },
    {
        key: 'workbench',
        name: 'B · Workbench(工作台)',
        oneLiner: '宽松 · 斑马纹表 · 描边按钮 · 轻投影 · 拒绝态是描边小标签',
        cellPad: 'px-3 py-2.5', text: 'text-sm',
        primary: 'outline', secondary: 'ghost',
        table: 'striped',
        card: 'border-[color:var(--brand-border)] shadow-sm',
        headRow: 'bg-[color:var(--brand-muted)]',
        refusal: 'outline',
    },
    {
        key: 'brand',
        name: 'C · Brand-forward(品牌前置)',
        oneLiner: '宽松 · 素表 + Hawaiian Ocean 表头线 · 品牌实心按钮 · 明显投影 · 拒绝态是浅色填充片',
        cellPad: 'px-3 py-2.5', text: 'text-[15px]',
        primary: 'default', secondary: 'secondary',
        table: 'plain',
        card: 'border-[color:var(--brand-border)] shadow-md',
        headRow: 'border-b-2 border-[color:var(--brand-ocean)]',
        refusal: 'chip',
    },
]

export default function BrandSamplerPage() {
    return (
        <main
            className={`${googleSans.variable} relative min-h-screen`}
            style={{
                fontFamily: 'var(--font-google-sans)',
                background: 'var(--brand-bg)',
                color: 'var(--brand-text)',
            }}
        >
            {/* ── 水印 · 品牌指南许可的用法:Forest Green,50% 不透明度,原描边粗细 ──
                【不透明度 50% 是指南定的,不许改】;而【位置与尺寸是本页的排版决定】:
                第一版放在右侧垂直居中、36rem 宽,压在正文阅读栏上,实测渲染后文字虽仍可读
                但很吵。改到右下角、26rem、窄屏隐藏 —— 水印是背景,不该和内容抢。
                原图一个字节都没改(public/brand/evoltrya-sphere.svg,本身就是
                Forest Green #6B8D54);50% 由 CSS 的 opacity 给,不是另存一版浅色图。
                aria-hidden:它是装饰,读屏软件不该念它。 */}
            {/* eslint-disable-next-line @next/next/no-img-element -- SVG:next/image 不优化矢量图,
                反而多一层 loader。本地静态 SVG 用 <img> 是对的写法。 */}
            <img
                src="/brand/evoltrya-sphere.svg"
                alt=""
                aria-hidden="true"
                className="pointer-events-none fixed right-[-6rem] bottom-[-6rem] hidden w-[26rem] select-none lg:block"
                style={{ opacity: 0.5 }}
            />

            <div className="relative mx-auto max-w-[92rem] px-6 py-10">
                {/* ── 临时横幅:必须一眼看出这不是产品的一部分 ──────────────── */}
                <div
                    className="mb-8 rounded border-2 border-dashed px-4 py-3"
                    style={{
                        borderColor: 'var(--brand-destructive)',
                        background: 'var(--brand-surface)',
                        color: 'var(--brand-destructive)',
                    }}
                >
                    <p className="text-sm font-bold">
                        ⚠ 临时页 —— BRAND-1 样式取样。这不是产品的一部分。
                    </p>
                    <p className="mt-1 text-xs" style={{ color: 'var(--brand-muted-text)' }}>
                        不在导航里、不在冒烟的路由清单里、不连数据库;表里的数字全是编的。
                        Tim 选定一个变体之后,<strong>把 app/brand-sampler/ 整个目录删掉</strong>。
                    </p>
                </div>

                <header className="mb-10">
                    {/* eslint-disable-next-line @next/next/no-img-element -- 同上:矢量字标,next/image 无从优化 */}
                    <img
                        src="/brand/evoltrya-wordmark.svg"
                        alt="EVoltrya"
                        className="mb-6 h-14 w-auto"
                    />
                    <h1 className="text-3xl font-bold">三个样式变体 —— 请指一个</h1>
                    <p className="mt-2 max-w-3xl text-sm" style={{ color: 'var(--brand-muted-text)' }}>
                        三个变体渲染的是<strong>同一份内容</strong>:一张进料批次表、一张表单、
                        一组按钮、四种拒绝态、两条横幅、一个空状态。只有密度、按钮画法、
                        表格画法、卡片投影、以及<strong>拒绝态怎么画</strong>不同。
                        每个变体都有名字 —— 回话时说「A」「B」「C」就够了,
                        也可以说「A 的表格配 C 的拒绝态」。
                    </p>
                    <p className="mt-2 max-w-3xl text-sm" style={{ color: 'var(--brand-muted-text)' }}>
                        本页字体是 <strong>Google Sans</strong>;<strong>系统其余部分仍然是 Arial</strong> ——
                        换字体是一个单独的决定,等你看过这一页再做,所以这里和 /inbound 看起来不一样是正常的。
                    </p>
                </header>

                {/* ── 品牌色板:指南值与推导值【分开陈列】 ─────────────────── */}
                <section className="mb-14">
                    <h2 className="mb-3 text-lg font-bold">品牌色 —— 指南给的 vs 推导出来的</h2>
                    <div className="flex flex-wrap gap-3">
                        {[
                            ['#008EBC', 'Hawaiian Ocean', '指南'],
                            ['#6B8D54', 'Forest Green', '指南'],
                            ['#F1F9FE', 'Background', '指南'],
                            ['#E1F5FF', 'Accent', '指南'],
                            ['#182B4B', 'Text', '指南'],
                            ['#007FAD', 'Ocean fill', '推导'],
                            ['#B75B53', 'Destructive', '推导'],
                            ['#CAD5E0', 'Border', '推导'],
                            ['#62738C', 'Muted text', '推导'],
                        ].map(([hex, label, kind]) => (
                            <div key={hex} className="w-36">
                                <div
                                    className="h-14 rounded border"
                                    style={{ background: hex, borderColor: 'var(--brand-border)' }}
                                />
                                <div className="mt-1 text-xs font-medium">{label}</div>
                                <div className="font-mono text-xs" style={{ color: 'var(--brand-muted-text)' }}>
                                    {hex}
                                </div>
                                <div
                                    className="text-xs"
                                    style={{ color: kind === '指南' ? 'var(--brand-ocean)' : 'var(--brand-muted-text)' }}
                                >
                                    【{kind}】
                                </div>
                            </div>
                        ))}
                    </div>
                    <p className="mt-3 max-w-3xl text-xs" style={{ color: 'var(--brand-muted-text)' }}>
                        【推导】那几个是指南没有给、而组件又非要不可的值。
                        每一个都写明了从哪个指南值、用什么算法推出来的 —— 见 app/brand-tokens.css。
                        其中 Ocean fill 值得一提:<strong>指南主色扛不动白字</strong>
                        (白字 on #008EBC = 3.75:1,正文要 4.5:1),
                        所以按钮底用的是把明度压到刚好够 AA 的那一档,而主色本身一个字节没动。
                    </p>
                </section>

                {SPECS.map((s) => <Variant key={s.key} spec={s} />)}

                <footer className="mt-16 border-t pt-6 text-xs" style={{ borderColor: 'var(--brand-border)', color: 'var(--brand-muted-text)' }}>
                    BRAND-1 · 临时取样页 · 选定后删除 app/brand-sampler/
                    与 scripts/smoke-routes.mjs 里对应的排除。
                </footer>
            </div>
        </main>
    )
}
