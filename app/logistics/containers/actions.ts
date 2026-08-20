'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeLogisticsError } from '../logisticsErrorCodes'

export type Result = { error: string }

// LOG-2c:唯一的创建门。**它调的是 create_container(DEFINER)**,不是直接 insert ——
// 无缝取号器 next_container_code 对 authenticated 是收权的(LOG-2a-fu1),
// 所以取号只能发生在函数体内,与 ship_order 调 next_shipment_code 同一个形状。
export async function createContainer(input: {
    lane_id: string; departure_date: string
    container_number: string | null; vessel: string | null; voyage: string | null
    forwarder_id: string | null; bl_number: string | null
}): Promise<Result | never> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('create_container', {
        p_lane_id: input.lane_id,
        p_departure_date: input.departure_date,
        p_container_number: input.container_number,
        p_vessel: input.vessel,
        p_voyage: input.voyage,
        p_forwarder_id: input.forwarder_id,
        p_bl_number: input.bl_number,
        p_notes: null,
    } as never)
    if (error) return { error: await localizeLogisticsError(error.message) }

    revalidatePath('/logistics/containers')
    redirect(`/logistics/containers/${(data as unknown as { id: string }).id}`)
}
