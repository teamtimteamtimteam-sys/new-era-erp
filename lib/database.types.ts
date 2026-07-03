export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      customer_attachments: {
        Row: {
          created_at: string
          created_by: string | null
          customer_id: string
          deleted_at: string | null
          doc_category: string | null
          file_name: string
          file_size: number | null
          file_type: string | null
          id: string
          notes: string | null
          storage_path: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          customer_id: string
          deleted_at?: string | null
          doc_category?: string | null
          file_name: string
          file_size?: number | null
          file_type?: string | null
          id?: string
          notes?: string | null
          storage_path: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          customer_id?: string
          deleted_at?: string | null
          doc_category?: string | null
          file_name?: string
          file_size?: number | null
          file_type?: string | null
          id?: string
          notes?: string | null
          storage_path?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "customer_attachments_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      customers: {
        Row: {
          address: string | null
          code: string
          country: string
          created_at: string
          created_by: string | null
          credit_rating: string | null
          customer_types: string[] | null
          deleted_at: string | null
          id: string
          incoterm: string | null
          legal_name: string
          notes: string | null
          payment_terms: string | null
          short_name: string | null
          status: string
          tax_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          address?: string | null
          code: string
          country: string
          created_at?: string
          created_by?: string | null
          credit_rating?: string | null
          customer_types?: string[] | null
          deleted_at?: string | null
          id?: string
          incoterm?: string | null
          legal_name: string
          notes?: string | null
          payment_terms?: string | null
          short_name?: string | null
          status?: string
          tax_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          address?: string | null
          code?: string
          country?: string
          created_at?: string
          created_by?: string | null
          credit_rating?: string | null
          customer_types?: string[] | null
          deleted_at?: string | null
          id?: string
          incoterm?: string | null
          legal_name?: string
          notes?: string | null
          payment_terms?: string | null
          short_name?: string | null
          status?: string
          tax_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      inbound_batch_metals: {
        Row: {
          content_pct: number
          created_at: string
          created_by: string | null
          inbound_batch_id: string
          metal: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          content_pct: number
          created_at?: string
          created_by?: string | null
          inbound_batch_id: string
          metal: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          content_pct?: number
          created_at?: string
          created_by?: string | null
          inbound_batch_id?: string
          metal?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inbound_batch_metals_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
        ]
      }
      inbound_batches: {
        Row: {
          arrival_date: string | null
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          material_id: string
          notes: string | null
          quantity: number
          remaining_qty: number
          stage: string
          status: string
          supplier_id: string
          unit: string
          unit_price: number | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          arrival_date?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          material_id: string
          notes?: string | null
          quantity: number
          remaining_qty: number
          stage?: string
          status?: string
          supplier_id: string
          unit?: string
          unit_price?: number | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          arrival_date?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          material_id?: string
          notes?: string | null
          quantity?: number
          remaining_qty?: number
          stage?: string
          status?: string
          supplier_id?: string
          unit?: string
          unit_price?: number | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      inventory_movements: {
        Row: {
          business_date: string | null
          created_at: string
          created_by: string | null
          id: string
          inbound_batch_id: string | null
          location_id: string | null
          movement_type: string
          notes: string | null
          occurred_at: string
          output_batch_id: string | null
          qty_delta: number
          run_id: string | null
        }
        Insert: {
          business_date?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          inbound_batch_id?: string | null
          location_id?: string | null
          movement_type: string
          notes?: string | null
          occurred_at?: string
          output_batch_id?: string | null
          qty_delta: number
          run_id?: string | null
        }
        Update: {
          business_date?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          inbound_batch_id?: string | null
          location_id?: string | null
          movement_type?: string
          notes?: string | null
          occurred_at?: string
          output_batch_id?: string | null
          qty_delta?: number
          run_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "storage_locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "inventory_movements_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      material_attachments: {
        Row: {
          created_at: string
          created_by: string | null
          deleted_at: string | null
          doc_category: string | null
          file_name: string
          file_size: number | null
          file_type: string | null
          id: string
          material_id: string
          notes: string | null
          storage_path: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          doc_category?: string | null
          file_name: string
          file_size?: number | null
          file_type?: string | null
          id?: string
          material_id: string
          notes?: string | null
          storage_path: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          doc_category?: string | null
          file_name?: string
          file_size?: number | null
          file_type?: string | null
          id?: string
          material_id?: string
          notes?: string | null
          storage_path?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "material_attachments_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
        ]
      }
      materials: {
        Row: {
          category: string
          chemistry: string | null
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          name: string
          notes: string | null
          spec: string | null
          status: string
          unit: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          category: string
          chemistry?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name: string
          notes?: string | null
          spec?: string | null
          status?: string
          unit?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          category?: string
          chemistry?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name?: string
          notes?: string | null
          spec?: string | null
          status?: string
          unit?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      metal_prices: {
        Row: {
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          metal: string
          notes: string | null
          price_date: string
          price_usd_per_tonne: number
          source: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          metal: string
          notes?: string | null
          price_date: string
          price_usd_per_tonne: number
          source?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          metal?: string
          notes?: string | null
          price_date?: string
          price_usd_per_tonne?: number
          source?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      output_batch_metals: {
        Row: {
          content_pct: number
          created_at: string
          created_by: string | null
          metal: string
          output_batch_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          content_pct: number
          created_at?: string
          created_by?: string | null
          metal: string
          output_batch_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          content_pct?: number
          created_at?: string
          created_by?: string | null
          metal?: string
          output_batch_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "output_batch_metals_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
        ]
      }
      output_batches: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          customer_id: string | null
          deleted_at: string | null
          id: string
          material_id: string
          notes: string | null
          output_date: string | null
          purity: string | null
          quantity: number
          remaining_qty: number
          state: string
          status: string
          unit: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          id?: string
          material_id: string
          notes?: string | null
          output_date?: string | null
          purity?: string | null
          quantity: number
          remaining_qty: number
          state?: string
          status?: string
          unit?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          id?: string
          material_id?: string
          notes?: string | null
          output_date?: string | null
          purity?: string | null
          quantity?: number
          remaining_qty?: number
          state?: string
          status?: string
          unit?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "output_batches_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "output_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_cost_entries: {
        Row: {
          amount_usd: number
          cost_type: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          is_estimate: boolean
          notes: string | null
          run_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          amount_usd: number
          cost_type: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_estimate?: boolean
          notes?: string | null
          run_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          amount_usd?: number
          cost_type?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_estimate?: boolean
          notes?: string | null
          run_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_inputs: {
        Row: {
          created_at: string
          id: string
          inbound_batch_id: string
          quantity_consumed: number
          run_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          inbound_batch_id: string
          quantity_consumed: number
          run_id: string
        }
        Update: {
          created_at?: string
          id?: string
          inbound_batch_id?: string
          quantity_consumed?: number
          run_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "processing_inputs_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_inputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_inputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_outputs: {
        Row: {
          allocated_cost_usd: number | null
          created_at: string
          id: string
          output_batch_id: string
          quantity_produced: number
          run_id: string
          unit_cost_usd: number | null
        }
        Insert: {
          allocated_cost_usd?: number | null
          created_at?: string
          id?: string
          output_batch_id: string
          quantity_produced: number
          run_id: string
          unit_cost_usd?: number | null
        }
        Update: {
          allocated_cost_usd?: number | null
          created_at?: string
          id?: string
          output_batch_id?: string
          quantity_produced?: number
          run_id?: string
          unit_cost_usd?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_outputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_runs: {
        Row: {
          allocated_at: string | null
          allocated_by: string | null
          allocation_basis: string
          allocation_snapshot: Json | null
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          loss_qty: number | null
          material_cost_usd: number | null
          notes: string | null
          process_cost_usd: number | null
          process_date: string | null
          status: string
          total_cost_usd: number | null
          total_input: number | null
          total_output: number | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          allocated_at?: string | null
          allocated_by?: string | null
          allocation_basis?: string
          allocation_snapshot?: Json | null
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          loss_qty?: number | null
          material_cost_usd?: number | null
          notes?: string | null
          process_cost_usd?: number | null
          process_date?: string | null
          status: string
          total_cost_usd?: number | null
          total_input?: number | null
          total_output?: number | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          allocated_at?: string | null
          allocated_by?: string | null
          allocation_basis?: string
          allocation_snapshot?: Json | null
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          loss_qty?: number | null
          material_cost_usd?: number | null
          notes?: string | null
          process_cost_usd?: number | null
          process_date?: string | null
          status?: string
          total_cost_usd?: number | null
          total_input?: number | null
          total_output?: number | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      storage_locations: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          name: string | null
          notes: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name?: string | null
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name?: string | null
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      supplier_attachments: {
        Row: {
          created_at: string
          created_by: string | null
          deleted_at: string | null
          doc_category: string | null
          file_name: string
          file_size: number | null
          file_type: string | null
          id: string
          notes: string | null
          storage_path: string
          supplier_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          doc_category?: string | null
          file_name: string
          file_size?: number | null
          file_type?: string | null
          id?: string
          notes?: string | null
          storage_path: string
          supplier_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          doc_category?: string | null
          file_name?: string
          file_size?: number | null
          file_type?: string | null
          id?: string
          notes?: string | null
          storage_path?: string
          supplier_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "supplier_attachments_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      supplier_compliance: {
        Row: {
          cert_no: string | null
          cert_type: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          document_id: string | null
          id: string
          issuing_body: string | null
          notes: string | null
          supplier_id: string
          updated_at: string
          updated_by: string | null
          valid_from: string | null
          valid_until: string | null
        }
        Insert: {
          cert_no?: string | null
          cert_type: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          document_id?: string | null
          id?: string
          issuing_body?: string | null
          notes?: string | null
          supplier_id: string
          updated_at?: string
          updated_by?: string | null
          valid_from?: string | null
          valid_until?: string | null
        }
        Update: {
          cert_no?: string | null
          cert_type?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          document_id?: string | null
          id?: string
          issuing_body?: string | null
          notes?: string | null
          supplier_id?: string
          updated_at?: string
          updated_by?: string | null
          valid_from?: string | null
          valid_until?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "supplier_compliance_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      suppliers: {
        Row: {
          address: string | null
          code: string
          country: string
          created_at: string
          created_by: string | null
          credit_rating: string | null
          deleted_at: string | null
          id: string
          incoterm: string | null
          legal_name: string
          notes: string | null
          owner_id: string | null
          payment_terms: string | null
          short_name: string | null
          status: Database["public"]["Enums"]["supplier_status"]
          supplier_types: string[]
          tax_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          address?: string | null
          code: string
          country: string
          created_at?: string
          created_by?: string | null
          credit_rating?: string | null
          deleted_at?: string | null
          id?: string
          incoterm?: string | null
          legal_name: string
          notes?: string | null
          owner_id?: string | null
          payment_terms?: string | null
          short_name?: string | null
          status?: Database["public"]["Enums"]["supplier_status"]
          supplier_types?: string[]
          tax_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          address?: string | null
          code?: string
          country?: string
          created_at?: string
          created_by?: string | null
          credit_rating?: string | null
          deleted_at?: string | null
          id?: string
          incoterm?: string | null
          legal_name?: string
          notes?: string | null
          owner_id?: string | null
          payment_terms?: string | null
          short_name?: string | null
          status?: Database["public"]["Enums"]["supplier_status"]
          supplier_types?: string[]
          tax_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      tasks: {
        Row: {
          assigned_to: string | null
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          description: string | null
          due_date: string | null
          editors: string[] | null
          entity: string | null
          id: string
          owner_id: string | null
          priority: string
          reminder_at: string | null
          shared_with: string[] | null
          status: string
          tags: string[] | null
          task_type: string
          title: string
          updated_at: string
          updated_by: string | null
          visibility: string
        }
        Insert: {
          assigned_to?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          description?: string | null
          due_date?: string | null
          editors?: string[] | null
          entity?: string | null
          id?: string
          owner_id?: string | null
          priority?: string
          reminder_at?: string | null
          shared_with?: string[] | null
          status?: string
          tags?: string[] | null
          task_type?: string
          title: string
          updated_at?: string
          updated_by?: string | null
          visibility?: string
        }
        Update: {
          assigned_to?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          description?: string | null
          due_date?: string | null
          editors?: string[] | null
          entity?: string | null
          id?: string
          owner_id?: string | null
          priority?: string
          reminder_at?: string | null
          shared_with?: string[] | null
          status?: string
          tags?: string[] | null
          task_type?: string
          title?: string
          updated_at?: string
          updated_by?: string | null
          visibility?: string
        }
        Relationships: []
      }
    }
    Views: {
      processing_metal_recovery: {
        Row: {
          input_metal_kg: number | null
          metal: string | null
          output_metal_kg: number | null
          process_date: string | null
          recovery_pct: number | null
          run_code: string | null
          run_id: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      allocate_processing_costs: {
        Args: { p_basis?: string; p_run_id: string }
        Returns: Json
      }
      commit_processing_run: {
        Args: {
          p_inputs: Json
          p_loss_qty: number
          p_notes: string
          p_outputs: Json
          p_process_date: string
        }
        Returns: string
      }
      record_output_sale: {
        Args: {
          p_notes?: string
          p_output_batch_id: string
          p_quantity: number
          p_sale_date?: string
        }
        Returns: Json
      }
      rollback_processing_run: {
        Args: { p_run_id: string }
        Returns: undefined
      }
    }
    Enums: {
      supplier_status:
        | "draft"
        | "pending_review"
        | "approved"
        | "rejected"
        | "active"
        | "suspended"
        | "blacklisted"
        | "archived"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      supplier_status: [
        "draft",
        "pending_review",
        "approved",
        "rejected",
        "active",
        "suspended",
        "blacklisted",
        "archived",
      ],
    },
  },
} as const
