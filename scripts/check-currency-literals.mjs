#!/usr/bin/env node
// scripts/check-currency-literals.mjs
//
// 【为什么有这个检查】币种写死在界面里,已经连着栽了三次:
//   * NewPaymentForm 用 `currency === 'USD' ? 1 : …` 判本位币 —— FIN-0 把本位币
//     改成 SGD 之后,这句就把"本位币付款"判成了无效,金额显示 0.00(FIN-12);
//   * 同一句的另一半让 USD 付款按 1:1 折算,1,000 USD 显示成 1,000.00 基准;
//   * messages 里 "Amount (SGD)" 之类的标签把本位币烤进了译文。
// 两轮人工扫已经各漏一处。人扫会漏第三处、第四处,所以改成【每次都跑】。
//
// 判据【两类】:
//   branch    —— 不允许把 'USD' / 'SGD' 当比较、分支、默认值、对照表键用;
//   jsx-text  —— 不允许把币种当【正文】印到 JSX 上(FIN-18 加)。
// 币种要么来自数据行,要么来自 currencies 表(is_base),不是常量。
//
// 【为什么补第二类】第一类只看判断,而最直接的谎法根本不经过判断:
//     {payment.currency !== baseCurrency && <>= {formatMoney(amount_base)} USD</>}
// 这一行【自己知道本位币是什么】(左边刚拿它比过),右边照样印死 "USD"。
// FIN-0 之后本位币是 SGD,于是屏幕上写着 "= 1,736.00 USD"。一条判断模式都不匹配,
// 这道检查报"币种无写死",db/gate.py 跟着报绿。补上之后一次扫出【六处】同一个写法
// (收付款列表/详情、开支列表/详情、应付批次、应收单据)—— 人扫两轮都没扫到。
// 合法例外写进下面的 ALLOWLIST,并且【必须写理由】—— 与 check_mirrors 的科目码
// 扫描、check-i18n 的后缀清单同一个做法:名单是列出来的,不是记在谁脑子里的。
//
// 用法:node scripts/check-currency-literals.mjs   (退出码 0 = 干净)
import { readdirSync, statSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = new URL('..', import.meta.url).pathname
const CODES = ['USD', 'SGD']

// 例外:path 是路径前缀,match(可选)是该行必须包含的片段 —— 【只豁免那一种写法】,
// 不是整个文件从此免检。reason 必填:名单是列出来的,不是记在谁脑子里的。
const ALLOWLIST = [
    {
        path: 'lib/currencyMap.ts',
        reason: '币种在这里【只出现一次】:BANK_BY_CURRENCY 是银行账户与其本币的对照表,'
            + '对应 db/functions/bank_native_currency.sql。本位币本身仍从 currencies.is_base 读,'
            + '不写死。加银行账户时这里与那个 DB 函数必须同改。',
    },
    // ── 以下两族是【真的就是那个币种】,不是把本位币烤进界面 ────────────────
    {
        path: 'app/hr/claims/', match: 'SGD',
        reason: '医疗报销按【决策】以新元计:限额来自 hr_settings 的新元政策数字,'
            + '列名本身就是 amount_sgd / claimed_sgd / remaining_sgd(不是 FIN-1a 那种'
            + '名不副实的旧名 —— medical_claims.amount_sgd 存的确实是新元)。'
            + '这里的 SGD 不随本位币变;真要改成多币种报销,是先改表再改这里。',
    },
    {
        path: 'app/me/MyClaimsPanel.tsx', match: 'SGD',
        reason: '同 app/hr/claims/:同一组 *_sgd 列的自助视图。',
    },
    {
        path: 'app/purchasing/orders/new/NewOrderForm.tsx', match: 'USD',
        reason: '金属报价【按市场惯例】以美元计价(AGENTS.md 的 FX 规则里写明:'
            + 'USD/t 这类标签留着)。calculate_metal_price 全程 USD 进 USD 出 ——'
            + '这不是缺口,是那条路的设计:换算发生在【路径上】,由 '
            + 'computeLineEstimate 在数字变成价格之前折进单据币种(FIN-15)。'
            + '所以这里的 USD 标签是【真的】,换成本位币反而会说谎。',
    },
]

const allowed = (h) => ALLOWLIST.some((a) =>
    h.rel.startsWith(a.path) && (!a.match || h.text.includes(a.match)))

// 只抓【比较/分支】里的币种字面量 —— 单纯出现在字符串或数组里(例如下拉选项、
// 类型联合)不算,那些是数据,不是规则。
const BRANCH_PATTERNS = CODES.flatMap((c) => [
    new RegExp(`[=!]==?\\s*['"\`]${c}['"\`]`),          // === 'USD'
    new RegExp(`['"\`]${c}['"\`]\\s*[=!]==?`),          // 'USD' ===
    new RegExp(`case\\s+['"\`]${c}['"\`]\\s*:`),        // case 'USD':
    new RegExp(`\\?\\?\\s*['"\`]${c}['"\`]`),           // ?? 'USD'   (默认成某币种)
    new RegExp(`\\|\\|\\s*['"\`]${c}['"\`]`),           // || 'USD'
    // { USD: … } 对照表(排除 'USD'::text 这类【类型转换】—— 那是数据不是分支)
    new RegExp(`(^|[{,\\s])['"\`]?${c}['"\`]?\\s*:(?!:)`),
    // SQL 里把币种当【投影出来的值】:'SGD'::text AS currency —— 那是在替所有行断言币种
    new RegExp(`['"\`]${c}['"\`](::\\w+)?\\s+AS\\s`, 'i'),
])

// ════════════════════════════════════════════════════════════════════════════
// 【第二类:印到屏幕上的币种】上面那组只认【判断】里的字面量。可是币种最直接的
// 谎法根本不是判断 —— 是把币种当【正文】写进 JSX:
//     = {formatMoney(r.amount_base)} USD
// 这不是比较、不是分支、不是默认值、不是对照表,一条也不匹配,于是这道检查
// 报"币种无写死",而操作员的屏幕上,本位币 SGD 的金额后面跟着 "USD"。
// 这正是 FIN-0 之后本该被这道检查拦下的那一类,只是它当时只学会了看判断。
//
// 判据:.tsx 里【剥掉字符串与注释之后】仍然出现的裸 USD / SGD。剥掉字符串是
// 关键 —— 'USD' 作为下拉选项的 value、类型联合、对照表的键都是【数据】,留着;
// 剥完还在的,就只能是 JSX 正文,也就是会被人读到的那一份。
// 标识符不算(estimated_total_usd、amount_usd 是列名,大小写不同,天然不撞)。
// ════════════════════════════════════════════════════════════════════════════
const JSX_TEXT = new RegExp(`(?<![\\w_$])(${CODES.join('|')})(?![\\w_$])`)

// 剥掉行内注释与字符串/模板字面量,只留下"结构性"的代码与 JSX 正文
function stripLiterals(line) {
    let out = ''
    let quote = null
    for (let i = 0; i < line.length; i++) {
        const ch = line[i]
        if (quote) {
            if (ch === '\\') { i++; continue }
            if (ch === quote) quote = null
            continue
        }
        if (ch === "'" || ch === '"' || ch === '`') { quote = ch; out += ' '; continue }
        if (ch === '/' && line[i + 1] === '/') break
        out += ch
    }
    return out
}

// 块注释 /* … */ 与 JSX 注释 {/* … */} 【跨行】—— 逐行剥是不够的:
// NewPaymentForm 里那段解释"标签说 SGD、数字后面跟着 USD"的注释就横跨两行,
// 第二行单看不像注释。整文件先把块注释抹成空格(保留换行,行号不动)。
function blankBlockComments(src) {
    return src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
}

// 币种下拉的选项【本来就该写出币种】—— <option value="USD">USD</option> 是在
// 让人选币种,不是在替某个金额断言币种。只在 value 与文字是同一个码时豁免:
// <option value="1000">1000 · SGD</option> 不算(那是银行账户名,仍要过检查)。
function isCurrencyOption(line, code) {
    return new RegExp(`<option[^>]*value=["']${code}["'][^>]*>\\s*${code}\\s*<`).test(line)
}

function* walk(dir) {
    for (const name of readdirSync(dir)) {
        if (name === 'node_modules' || name === '.next') continue
        const p = join(dir, name)
        if (statSync(p).isDirectory()) yield* walk(p)
        else if ((/\.tsx?$/.test(name) && !name.endsWith('.d.ts')) || /\.sql$/.test(name)) yield p
    }
}

const hits = []
// db/ 下的 SQL 也扫 —— fx_rate_gaps 里那句 `l.currency <> 'SGD'` 说明盲区恰恰
// 落在本位币最要紧的地方。SQL 里判本位币要问 currencies.is_base,不要写字面量。
for (const dir of ['app', 'lib', 'db']) {
    for (const file of walk(join(ROOT, dir))) {
        const rel = file.slice(ROOT.length)
        if (rel.includes('database.types')) continue
        // db/migrations 是【历史记录】:当时写下的字面量不该被今天的规矩追认
        if (rel.startsWith('db/migrations/')) continue
        const lines = blankBlockComments(readFileSync(file, 'utf8')).split('\n')
        lines.forEach((line, i) => {
            if (line.trim().startsWith('//') || line.trim().startsWith('*')
                || line.trim().startsWith('--')) return
            if (BRANCH_PATTERNS.some((re) => re.test(line))) {
                hits.push({ rel, line: i + 1, kind: 'branch', text: line.trim().slice(0, 110) })
                return
            }
            // 印到屏幕上的币种只可能出在 .tsx 的 JSX 正文里
            if (!rel.endsWith('.tsx')) return
            const m = JSX_TEXT.exec(stripLiterals(line))
            if (m && !isCurrencyOption(line, m[1])) {
                hits.push({ rel, line: i + 1, kind: 'jsx-text', text: line.trim().slice(0, 110) })
            }
        })
    }
}

const bad = hits.filter((h) => !allowed(h))
for (const h of bad) console.log(`  [${h.kind}] ${h.rel}:${h.line}  ${h.text}`)
const allowedCount = hits.length - bad.length
console.log(`\ncurrency literals: ${bad.length} unallowed, ${allowedCount} allowlisted`)
if (bad.length) {
    console.log('币种不能写死在判断里 —— 从数据行取,或问 currencies.is_base。')
    console.log('确有例外就加进 ALLOWLIST 并写明理由。')
    process.exit(1)
}
console.log('✓ 没有把币种当常量用的判断')
