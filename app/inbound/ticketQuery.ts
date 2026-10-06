// app/inbound/ticketQuery.ts
// MES-2(2026-10-06,MES-2 Step 0 Q19):两个收货表单读同一份"可以挂的地磅单" —— 完成了的进厂单,而且净重还有没分出去的公斤数。
//   读 weighbridge_ticket_weights(属主视图,行谓词:收货或物流查看码 —— 收货页本来就要收货查看码)。读不出来就抛(mustRows)。
import type { SupabaseClient } from '@supabase/supabase-js'
import { mustRows } from '@/lib/db-helpers'
import type { TicketOption } from './TicketShareFields'

export async function loadShareableTickets(supabase: SupabaseClient): Promise<TicketOption[]> {
    const rows = mustRows(await supabase.from('weighbridge_ticket_weights')
        .select('ticket_id, code, vehicle_reg, net_kg, difference_kg')
        .eq('direction', 'inbound').eq('status', 'complete').gt('difference_kg', 0)
        .order('completed_at', { ascending: false }).limit(50), 'weighbridge_ticket_weights') as
        { ticket_id: string; code: string; vehicle_reg: string; net_kg: number; difference_kg: number }[]
    return rows.map((r) => ({ id: r.ticket_id, code: r.code, vehicle_reg: r.vehicle_reg, net_kg: Number(r.net_kg), remaining_kg: Number(r.difference_kg) }))
}
