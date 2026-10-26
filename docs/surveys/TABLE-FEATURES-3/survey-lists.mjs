import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
const src = readFileSync('scripts/check-list-sorting.mjs','utf8')
const routes = [...src.match(/const LIST_ROUTES = \[([\s\S]*?)\]/)[1].matchAll(/'([^']+)'/g)].map(m=>m[1])
const strip = s => s.replace(/\/\*[\s\S]*?\*\//g,'').replace(/(^|[^:'"`])\/\/.*$/gm,'$1')
const rows=[]
for (const r of routes) {
  const dir = join('app', r)
  const files = readdirSync(dir).filter(f=>/\.(tsx|ts)$/.test(f)).map(f=>join(dir,f))
  let tables=0, client=0, server=0, spKeys=new Set(), clientFilter=[], usesRouterPush=false
  for (const f of files) {
    const s = strip(readFileSync(f,'utf8'))
    tables += (s.match(/<(DataTable|EditableTable|CellsTable)[\s>\n]/g)||[]).length
    client += (s.match(/mode:\s*'client'/g)||[]).length
    server += (s.match(/mode:\s*'server'/g)||[]).length
    const m = s.match(/searchParams\s*:\s*Promise<\s*\{([^}]*)\}/)
    if (m) for (const k of m[1].matchAll(/(\w+)\??\s*:/g)) spKeys.add(k[1])
    if (/'use client'/.test(s) && /useState/.test(s) && /(filter|search|query|keyword|status)\w*\s*,\s*set/i.test(s)) clientFilter.push(f.split('/').pop())
    if (/router\.(push|replace)\(/.test(s)) usesRouterPush=true
  }
  rows.push({r, tables, client, server, sp:[...spKeys].join(','), clientFilter:clientFilter.join(','), urlNav:usesRouterPush})
}
for (const x of rows) console.log([x.r,x.tables,x.client,x.server,x.sp||'-',x.clientFilter||'-',x.urlNav?'nav':'-'].join('\t'))
const withSp=rows.filter(x=>x.sp && x.sp.replace(/\b(page|sort|dir)\b,?/g,'').replace(/,/g,'')!=='')
console.error('routes',rows.length,'| any URL param',rows.filter(x=>x.sp).length,'| URL filter param (not page/sort/dir)',withSp.length,'| client-sort pages',rows.filter(x=>x.client>0).length,'| server-sort pages',rows.filter(x=>x.server>0).length,'| pages with >1 table',rows.filter(x=>x.tables>1).length,'| client filter state',rows.filter(x=>x.clientFilter).length)
