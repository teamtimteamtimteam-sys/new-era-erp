#!/usr/bin/env node
// scripts/survey-pages.mjs
// ════════════════════════════════════════════════════════════════════════════
// ★ SURVEY TOOL — NOT A GATE, NOT A CHECK. It asserts nothing and always
//   exits 0 unless it crashes. It exists to produce the counted numbers in
//   docs/page-conversion-survey.md (PAGE-0, 2026-09-03) and to let a later cut
//   RE-COUNT them rather than trust a written-down number that has gone stale.
//   Nothing in the build, gate or smoke path calls it.
//
//   Usage:  node scripts/survey-pages.mjs            # human summary
//           node scripts/survey-pages.mjs --json     # machine-readable dump
//
//   Method: static parse of the tree. Every number it prints is COUNTED from
//   files. Where a question cannot be answered statically (does this page
//   actually overflow 390px in a browser? how many rows does this query return
//   against live data?) it prints nothing rather than a guess — those live in
//   the browser probe and the database probe, which are separate.
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, dirname, relative, basename } from 'node:path'

const ROOT = process.cwd()
const APP = join(ROOT, 'app')

function walk(dir, out = []) {
    for (const e of readdirSync(dir)) {
        const p = join(dir, e)
        const st = statSync(p)
        if (st.isDirectory()) walk(p, out)
        else out.push(p)
    }
    return out
}

const allFiles = walk(APP)
const pageFiles = allFiles.filter((f) => basename(f) === 'page.tsx').sort()

// A route's own file set: page.tsx + every .tsx/.ts colocated in the SAME
// directory that is not itself a page/layout/route. Next colocates a route's
// client components next to it, and a lot of this repo's markup lives there —
// counting only page.tsx would undercount tables badly.
function routeFiles(pageFile) {
    const dir = dirname(pageFile)
    return allFiles.filter(
        (f) =>
            dirname(f) === dir &&
            /\.(tsx|ts)$/.test(f) &&
            !['layout.tsx', 'route.ts'].includes(basename(f))
    )
}

function routeOf(pageFile) {
    const r = '/' + relative(APP, dirname(pageFile)).split('\\').join('/')
    return r === '/.' ? '/' : r
}

const read = (f) => {
    try {
        return readFileSync(f, 'utf8')
    } catch {
        return ''
    }
}
const count = (s, re) => (s.match(re) || []).length

const pages = pageFiles.map((pf) => {
    const files = routeFiles(pf)
    const src = files.map(read).join('\n')
    const own = read(pf)
    const route = routeOf(pf)
    const segs = route.split('/').filter(Boolean)
    const last = segs[segs.length - 1] ?? ''
    const dynamicSegs = segs.filter((s) => s.startsWith('['))
    return {
        route,
        pageFile: relative(ROOT, pf),
        files: files.map((f) => relative(ROOT, f)),
        fileCount: files.length,
        lines: src.split('\n').length,
        ownLines: own.split('\n').length,
        segs,
        last,
        dynamic: dynamicSegs.length,
        src,
        own,
    }
})

// ── signals ─────────────────────────────────────────────────────────────────
const S = {
    tableOpen: /<table[\s>]/g,
    th: /<th[\s>]/g,
    td: /<td[\s>]/g,
    dataTableImport: /from '@\/app\/components\/ui\/data-table'/g,
    dataTableUse: /<DataTable[\s>]/g,
    formOpen: /<form[\s>]/g,
    useActionState: /useActionState|useFormState/g,
    serverAction: /'use server'/g,
    inputEl: /<input[\s>]|<Input[\s>]/g,
    selectEl: /<select[\s>]|<Select[\s>]/g,
    textareaEl: /<textarea[\s>]|<Textarea[\s>]/g,
    useState: /useState\s*[<(]/g,
    useClient: /'use client'/g,
    chartImport: /components\/charts\//g,
    requireModule: /requireModule\s*\(/g,
    requirePerm: /requirePermission|requireAnyPermission|requirePerm\b/g,
    restricted: /t\('common\.restricted'\)|common\.restricted/g,
    refusalImport: /from '@\/app\/components\/ui\/refusal'/g,
    refusalUse: /<Refusal[\s>]/g,
    maskedValue: /<MaskedValue[\s>]/g,
    actorName: /<ActorName[\s>]/g,
    range: /\.range\s*\(/g,
    orderBy: /\.order\s*\(/g,
    sortableTh: /sortableTh|sortHref/g,
    pageHref: /pageHref|\?page=|params\.set\('page'/g,
    countExact: /count:\s*'exact'/g,
    suspense: /<Suspense[\s>]/g,
    loadingSkeleton: /Skeleton|animate-pulse|base-skeleton/g,
    csvExport: /csv|CSV/g,
    downloadLink: /download=|\/export|Content-Disposition/g,
    searchParams: /searchParams/g,
    mustRows: /mustRows|mustRow\b/g,
    nullCoalesceEmpty: /\?\?\s*\[\]/g,
    p8: /className="p-8"|className=\{?"p-8/g,
    maxW: /max-w-\w+/g,
    minW: /min-w-\[|min-w-\w+/g,
    overflowX: /overflow-x-auto|overflow-auto|overflow-x-scroll/g,
    whitespaceNowrap: /whitespace-nowrap/g,
    smPrefix: /\b(sm:|md:|lg:|xl:)/g,
    gridCols: /grid-cols-\d/g,
    hiddenSm: /\bhidden\s+sm:|sm:hidden|md:hidden|hidden\s+md:/g,
    fixedWidthPx: /w-\[\d+px\]|min-w-\[\d+px\]|width:\s*\d+px/g,
    emptyStateNoRecords: /noRecords|noRows|emptyState|\.empty\b|isEmpty|length === 0|length ===0|!\w+\.length/g,
    tooFewToDraw: /tooFew|notEnough|insufficient/g,
    errorBox: /bg-red-100|text-red-700|loadError|border-red-400/g,
}

for (const p of pages) {
    p.sig = {}
    for (const [k, re] of Object.entries(S)) p.sig[k] = count(p.src, new RegExp(re.source, 'g'))
}

// ── classification ──────────────────────────────────────────────────────────
// Kind is decided by ROUTE SHAPE first (unambiguous, and it is what a human
// means by "a form page"), then content signals break the remaining ties.
const REPORTISH = new Set([
    'pnl','balance-sheet','trial-balance','cashflow','cash-forecast','aging',
    'ledger','revaluation','cost-variance','price-exposure','margin','wip',
    'kpi','snapshot','safety','violations','overlap','discrepancies',
    'processing-costs','month-end','close','payables','receivables',
])
const LANDING = new Set(['/', '/finance', '/operation', '/settings', '/hr', '/inventory',
    '/tools/pricing', '/purchasing', '/welcome', '/me', '/logistics'])

for (const p of pages) {
    const { route, last, segs } = p
    let kind
    if (LANDING.has(route)) kind = 'landing/dashboard'
    else if (segs[0] === 'settings') kind = 'settings/dictionary'
    else if (last === 'new' || last === 'edit' || last === 'amend' || last === 'bulk' || last === 'import') kind = 'form'
    else if (route === '/login' || route === '/set-password' || route === '/logout' || route === '/brand-sampler') kind = 'auth/scratch'
    else if (segs.some((s) => s === 'reports') || REPORTISH.has(last)) kind = 'report'
    else if (last.startsWith('[')) kind = 'detail'
    else if (p.sig.tableOpen > 0 || p.sig.dataTableUse > 0) kind = 'list/table'
    else kind = 'other'
    // content override: a route-shaped "detail" that is really a form
    if (kind === 'detail' && p.sig.formOpen > 0 && p.sig.tableOpen === 0) kind = 'form'
    p.kind = kind
}

const byKind = {}
for (const p of pages) (byKind[p.kind] ||= []).push(p)

// ── output ──────────────────────────────────────────────────────────────────
const out = { total: pages.length, byKind: {}, pages }
for (const [k, v] of Object.entries(byKind)) out.byKind[k] = v.length

if (process.argv.includes('--json')) {
    console.log(JSON.stringify({
        total: pages.length,
        byKind: out.byKind,
        pages: pages.map(({ src, own, ...rest }) => rest),
    }, null, 2))
    process.exit(0)
}

const sum = (arr, f) => arr.reduce((a, b) => a + f(b), 0)
console.log(`TOTAL page.tsx: ${pages.length}`)
console.log(`\n── BY KIND ──`)
for (const [k, v] of Object.entries(out.byKind).sort((a, b) => b[1] - a[1]))
    console.log(`  ${String(v).padStart(4)}  ${k}`)
console.log(`\n── TABLES ──`)
console.log(`  <table> blocks (route files):  ${sum(pages, (p) => p.sig.tableOpen)}`)
console.log(`  pages with >=1 <table>:        ${pages.filter((p) => p.sig.tableOpen > 0).length}`)
console.log(`  <th>: ${sum(pages, (p) => p.sig.th)}   <td>: ${sum(pages, (p) => p.sig.td)}`)
console.log(`  pages importing DataTable:     ${pages.filter((p) => p.sig.dataTableImport > 0).length}`)
console.log(`  pages rendering <DataTable>:   ${pages.filter((p) => p.sig.dataTableUse > 0).length}`)
console.log(`\n── CAPABILITIES ──`)
console.log(`  pages with sortableTh/sortHref: ${pages.filter((p) => p.sig.sortableTh > 0).length}`)
console.log(`  pages with .range():            ${pages.filter((p) => p.sig.range > 0).length}`)
console.log(`  pages with count:'exact':       ${pages.filter((p) => p.sig.countExact > 0).length}`)
console.log(`  pages with overflow-x-*:        ${pages.filter((p) => p.sig.overflowX > 0).length}`)
console.log(`  pages with any sm:/md:/lg:      ${pages.filter((p) => p.sig.smPrefix > 0).length}`)
console.log(`\n── REFUSAL / EMPTY / LOADING ──`)
console.log(`  pages touching common.restricted: ${pages.filter((p) => p.sig.restricted > 0).length}`)
console.log(`  pages with <Refusal>:             ${pages.filter((p) => p.sig.refusalUse > 0).length}`)
console.log(`  pages with requireModule():       ${pages.filter((p) => p.sig.requireModule > 0).length}`)
console.log(`  pages with <MaskedValue>:         ${pages.filter((p) => p.sig.maskedValue > 0).length}`)
console.log(`  pages with <ActorName>:           ${pages.filter((p) => p.sig.actorName > 0).length}`)
console.log(`  pages with <Suspense>:            ${pages.filter((p) => p.sig.suspense > 0).length}`)
console.log(`  pages with Skeleton/animate-pulse:${pages.filter((p) => p.sig.loadingSkeleton > 0).length}`)
console.log(`  pages with red error box:         ${pages.filter((p) => p.sig.errorBox > 0).length}`)
