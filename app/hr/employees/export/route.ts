// TABLE-EXPORT-1(Tim 2026-10-22 Q2 / Q8):员工名录的统一导出 —— 服务端那一半。
// 按页面【自己的】读取(employeeRows.ts)翻页取全,以 JSON 交给表,
// 由表按它自己的列定义写成 xlsx / csv(app/components/ui/table-export.tsx)。
// 守卫与页面同一个判据(MOD.hr);超过 50,000 行按名拒绝(Q8)。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { parseEmployeeListParams, employeeCount, employeePage, shapeEmployeeRows } from '../employeeRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.hr.permission))) return exportDenied()
    const params = parseEmployeeListParams(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'employee_directory',
        count: async () => mustCount(await employeeCount(supabase, params), 'employee_directory'),
        page: (from, to) => employeePage(supabase, params, from, to),
        shape: (rows) => shapeEmployeeRows(rows),
    })
}
