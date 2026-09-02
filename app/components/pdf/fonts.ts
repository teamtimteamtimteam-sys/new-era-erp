// app/components/pdf/fonts.ts
// PDF-1:【对外单据的字体规则 —— 一处注册,一个字体栈,所有文档共用】(2026-09-02)
//
// ════════════════════════════════════════════════════════════════════════════
// ★ 这个模块存在的理由,是一个【真实发生过的缺陷】,不是整洁 ★
// ════════════════════════════════════════════════════════════════════════════
// PDF-1 之前:字体注册住在 `app/finance/invoices/[id]/pdf/InvoiceDocument.tsx` 里,
// 靠"import 它就完成注册"这个【模块副作用】传播给另外五份文档。那套写法能跑,
// 但它把"这份文档嵌了哪些字体"变成了一件**要靠读 import 才知道**的事。
//
// 于是对账单(STATEMENT-1)写成了 `fontFamily: 'Helvetica'` + 六处
// `'Helvetica-Bold'` —— 而发票文档里【白纸黑字写着不许这么做】:
//
//     「凡是要加粗的地方一律用 fontWeight: 'bold'(而不是 fontFamily:
//       'Helvetica-Bold'),否则等于把那个节点换回了拉丁字体。」
//
// 后果实测(PDF-1 渲染复现):`上海金属回收有限公司` 印成 **`wÑ^Þ6 Plø`** ——
// **不是空白、不是豆腐块,是一串看起来像模像样的重音拉丁字母**,所以没人发现。
// 而这张纸是【对账单】:它的全部用途就是寄给欠款人要钱。
//
// ★ 更要紧的是那道守卫【报了绿】★ 路由确实调了 findUnrenderableText(),
// 但它查的是 **Noto Sans SC 的覆盖清单**,而文档嵌的是 **Helvetica** ——
// 一个【标签与判据问的不是同一件事】的检查。本仓库已经为这一族付过多次账。
//
// ════════════════════════════════════════════════════════════════════════════
// ★ 所以这里的修法是:让"嵌了什么"与"查了什么"【在构造上】是同一份东西 ★
// ════════════════════════════════════════════════════════════════════════════
// 1. 字体栈与覆盖清单【同源】—— 两者都来自 assets/fonts/coverage.json,而那份
//    清单是 subset.py 在裁剪字体的【同一次运行】里从裁剪结果的 cmap 反读出来的。
//    要让守卫查错对象,得先让 coverage.json 与 .subset.ttf 对不上,而它们是
//    一起产出的。
// 2. 本模块【按清单注册】,不按硬编码的家族名 —— 见下面 assertStackMatches()。
// 3. 任何 PDF 文档里出现字体栈以外的 fontFamily,`npm run build` 会红
//    (scripts/check-pdf-font-stack.mjs)。对账单那个写法从此写不进来。
//
// ════════════════════════════════════════════════════════════════════════════
// ★ 字体栈怎么工作(R2:拉丁与数字用 Google Sans,中文用中文字体,按字符选)★
// ════════════════════════════════════════════════════════════════════════════
// react-pdf 4.5.1 的 fontFamily 接受【数组】。排版引擎 @react-pdf/textkit 的
// pickFontFromFontStack() 对【每一个码位】依次问 hasGlyphForCodePoint,取第一个
// 画得出来的。所以:
//     fontFamily: ['Google Sans', 'Noto Sans SC']
//         'INVOICE'、'1,234.56' → Google Sans(它有)
//         '上海金属回收'         → Google Sans 没有 → 落到 Noto Sans SC
// **同一个 <Text> 里混排也成立** —— 这是逐字符的,不是逐节点的。
//
// ★★【两个字重都必须注册,否则粗体的拉丁会【静默地】换成中文字体】★★
// 实测(PDF-1 的证明渲染):只注册 Google Sans 400、再写 fontWeight:'bold' 时,
// 拉丁拿不到 Google Sans 的粗体 → 引擎退到 Noto Sans SC Bold,于是
// **同一行里拉丁是细的、中文是粗的**。它看起来像渲染器的毛病,不像"少注册了一个
// 字重",所以会被诊断到别处去。下面的存在性检查因此是【承重的】,不是防御性编程。
import path from 'node:path'
import fs from 'node:fs'
import { Font } from '@react-pdf/renderer'
import coverage from '@/assets/fonts/coverage.json'

const FONT_DIR = path.join(process.cwd(), 'assets', 'fonts')

/** 每个家族要注册的字重。清单里的 files 与 weights 一一对应(subset.py 保证)。 */
type CoverageFamily = {
    family: string
    role: string
    files: string[]
    weights: string[]
}

const FAMILIES = coverage.families as CoverageFamily[]

/**
 * ★ 字体栈 —— 【每一份对外单据的 page 样式都必须用它,不许写别的】★
 * 顺序来自 coverage.json 的 stack,而那个顺序就是 subset.py 里 FAMILIES 的顺序。
 * 拉丁在前、中文在后:反过来的话汉字字体会把拉丁字母也画走。
 */
export const DOC_FONT_STACK: string[] = coverage.stack as string[]

/**
 * 【兼容旧名】PDF-1 之前六份文档从 InvoiceDocument 引 INVOICE_FONT_FAMILY。
 * 那个名字现在是错的(它不再是"发票的"字体,也不再是单个 family),所以调用方
 * 全部改成了 DOC_FONT_STACK。这里【不】保留旧的别名 —— 留一个别名等于留一条
 * "写单个家族也行"的路,而那正是要关掉的那条。
 */

// ── 启动期的三道检查 ─────────────────────────────────────────────────────────
// 三道都在【模块加载时】跑,不是渲染时。字体没装好属于部署事故,应该在冷启动
// 就炸掉,而不是等某个客户的某一张发票渲染到一半抛一个含糊的 fontkit 错误。

/** ① 清单与栈自洽:stack 里的每个家族都要在 families 里有一条。 */
function assertStackMatches(): void {
    const declared = new Set(FAMILIES.map((f) => f.family))
    const missing = DOC_FONT_STACK.filter((f) => !declared.has(f))
    if (missing.length) {
        throw new Error(
            `assets/fonts/coverage.json 自相矛盾:stack 里的 ${missing.join('、')} ` +
                `在 families 里没有对应条目。重跑 python3 assets/fonts/subset.py。`
        )
    }
}

/** ② 每个家族都必须同时有 normal 与 bold —— 理由见抬头那段 ★★。 */
function assertBothWeights(): void {
    for (const fam of FAMILIES) {
        const missing = ['normal', 'bold'].filter((w) => !fam.weights.includes(w))
        if (missing.length) {
            throw new Error(
                `字体家族 ${fam.family} 缺字重:${missing.join('、')}。\n` +
                    `缺一个字重不会报错,它会【静默地】让那个字重的拉丁字符换成栈里的` +
                    `下一个字体 —— 同一行里粗细不一致。改 assets/fonts/subset.py 的 ` +
                    `FAMILIES[].weights 并重跑。`
            )
        }
    }
}

/** ③ 清单点名的每个文件都要在磁盘上。 */
function assertFilesPresent(): void {
    const missing: string[] = []
    for (const fam of FAMILIES) {
        for (const file of fam.files) {
            if (!fs.existsSync(path.join(FONT_DIR, file))) missing.push(file)
        }
    }
    if (missing.length) {
        throw new Error(
            `对外单据字体缺失:${missing.join('、')}\n` +
                `位置:${FONT_DIR}\n` +
                `请按 assets/fonts/subset.py 头部注释放好完整字重后重跑该脚本。`
        )
    }
}

assertStackMatches()
assertBothWeights()
assertFilesPresent()

for (const fam of FAMILIES) {
    Font.register({
        family: fam.family,
        fonts: fam.files.map((file, i) => ({
            src: path.join(FONT_DIR, file),
            fontStyle: 'normal' as const,
            fontWeight: fam.weights[i] as 'normal' | 'bold',
        })),
    })
}

// 排版引擎【只按空格切词】(textkit 的 wrapWords:split(/([ ]+)/)),而中文不写空格 ——
// 一整段中文地址会被当成一个不可断开的"词"。实测 69 个汉字的地址(9pt ≈ 621pt)在
// 515pt 的正文宽里【直接冲出页面右边缘被截掉】,后面十几个字整段消失。
//
// 所以对含中日韩字符的词逐字切开,让断行点能落在任意两个汉字之间;纯拉丁的词保持
// 整体,避免把英文单词拆散。
//
// 【已知缺陷】textkit 在断词点一律插一个连字符(breakLines 里对 penalty 节点
// insertGlyph(HYPHEN)),中文断行处因此会多出一个 "-":"…大楼北翼-/办公室…"。
// 中文排版上这是错的。但两害相权:多一个连字符 = 难看但信息完整;不切词 = 地址后半
// 截直接从纸面上消失,而且没人会发现 —— 后者正是这一族要防的静默丢字。
// 要彻底修好得绕开 textkit 的 hyphenation 回调(它没有"无连字符断点"这种节点),
// 属于另一件事。
const CJK = /[　-〿㐀-䶿一-鿿豈-﫿＀-￯]/
Font.registerHyphenationCallback((word) => (CJK.test(word) ? Array.from(word) : [word]))
