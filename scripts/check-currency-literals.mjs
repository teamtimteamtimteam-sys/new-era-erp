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
// 判据:app/ 与 lib/ 的代码里,不允许把 'USD' / 'SGD' 当【比较或分支条件】用。
// 币种要么来自数据行,要么来自 currencies 表(is_base),不是常量。
// 合法例外写进下面的 ALLOWLIST,并且【必须写理由】—— 与 check_mirrors 的科目码
// 扫描、check-i18n 的后缀清单同一个做法:名单是列出来的,不是记在谁脑子里的。
//
// 用法:node scripts/check-currency-literals.mjs   (退出码 0 = 干净)
import { readdirSync, statSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = new URL('..', import.meta.url).pathname
const CODES = ['USD', 'SGD']

// 例外:key 是 `相对路径:行号内容片段`,value 是【为什么这里可以写死】
const ALLOWLIST = {
    'lib/currencyMap.ts':
        '币种在这里【只出现一次】:BANK_BY_CURRENCY 是银行账户与其本币的对照表,'
        + '对应 db/functions/bank_native_currency.sql。本位币本身仍从 currencies.is_base 读,'
        + '不写死。加银行账户时这里与那个 DB 函数必须同改。',
}

// 只抓【比较/分支】里的币种字面量 —— 单纯出现在字符串或数组里(例如下拉选项、
// 类型联合)不算,那些是数据,不是规则。
const PATTERNS = CODES.flatMap((c) => [
    new RegExp(`[=!]==?\\s*['"\`]${c}['"\`]`),          // === 'USD'
    new RegExp(`['"\`]${c}['"\`]\\s*[=!]==?`),          // 'USD' ===
    new RegExp(`case\\s+['"\`]${c}['"\`]\\s*:`),        // case 'USD':
    new RegExp(`\\?\\?\\s*['"\`]${c}['"\`]`),           // ?? 'USD'   (默认成某币种)
    new RegExp(`\\|\\|\\s*['"\`]${c}['"\`]`),           // || 'USD'
    new RegExp(`(^|[{,\\s])['"\`]?${c}['"\`]?\\s*:`),      // { USD: … } 对照表
])

function* walk(dir) {
    for (const name of readdirSync(dir)) {
        if (name === 'node_modules' || name === '.next') continue
        const p = join(dir, name)
        if (statSync(p).isDirectory()) yield* walk(p)
        else if (/\.tsx?$/.test(name) && !name.endsWith('.d.ts')) yield p
    }
}

const hits = []
for (const dir of ['app', 'lib']) {
    for (const file of walk(join(ROOT, dir))) {
        const rel = file.slice(ROOT.length)
        if (rel.includes('database.types')) continue
        const lines = readFileSync(file, 'utf8').split('\n')
        lines.forEach((line, i) => {
            if (line.trim().startsWith('//') || line.trim().startsWith('*')) return
            if (PATTERNS.some((re) => re.test(line))) {
                hits.push({ rel, line: i + 1, text: line.trim().slice(0, 110) })
            }
        })
    }
}

const bad = hits.filter((h) => !Object.keys(ALLOWLIST).some((a) => h.rel.startsWith(a)))
for (const h of bad) console.log(`  ${h.rel}:${h.line}  ${h.text}`)
const allowed = hits.length - bad.length
console.log(`\ncurrency literals: ${bad.length} unallowed, ${allowed} allowlisted`)
if (bad.length) {
    console.log('币种不能写死在判断里 —— 从数据行取,或问 currencies.is_base。')
    console.log('确有例外就加进 ALLOWLIST 并写明理由。')
    process.exit(1)
}
console.log('✓ 没有把币种当常量用的判断')
