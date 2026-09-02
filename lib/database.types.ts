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
      accounts: {
        Row: {
          account_type: string
          cash_flow_section: string | null
          code: string
          created_at: string
          created_by: string | null
          id: string
          is_active: boolean
          is_cash: boolean
          is_monetary: boolean
          is_system: boolean
          name_en: string
          name_zh: string
          notes: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          account_type: string
          cash_flow_section?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          is_cash?: boolean
          is_monetary: boolean
          is_system?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          account_type?: string
          cash_flow_section?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          is_cash?: boolean
          is_monetary?: boolean
          is_system?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      approval_log: {
        Row: {
          actor_user_id: string | null
          amount_base: number | null
          amount_ccy: number | null
          created_at: string
          currency: string | null
          decided_at: string
          decision: string
          fx_rate: number | null
          id: string
          is_reconstructed: boolean
          level: number | null
          note: string | null
          reconstruction_note: string | null
          seq: number
          subject_code: string | null
          subject_id: string
          subject_type: string
        }
        Insert: {
          actor_user_id?: string | null
          amount_base?: number | null
          amount_ccy?: number | null
          created_at?: string
          currency?: string | null
          decided_at?: string
          decision: string
          fx_rate?: number | null
          id?: string
          is_reconstructed?: boolean
          level?: number | null
          note?: string | null
          reconstruction_note?: string | null
          seq?: number
          subject_code?: string | null
          subject_id: string
          subject_type: string
        }
        Update: {
          actor_user_id?: string | null
          amount_base?: number | null
          amount_ccy?: number | null
          created_at?: string
          currency?: string | null
          decided_at?: string
          decision?: string
          fx_rate?: number | null
          id?: string
          is_reconstructed?: boolean
          level?: number | null
          note?: string | null
          reconstruction_note?: string | null
          seq?: number
          subject_code?: string | null
          subject_id?: string
          subject_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "approval_log_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      assay_result_metals: {
        Row: {
          assay_result_id: string
          content_pct: number
          created_at: string
          metal: string
        }
        Insert: {
          assay_result_id: string
          content_pct: number
          created_at?: string
          metal: string
        }
        Update: {
          assay_result_id?: string
          content_pct?: number
          created_at?: string
          metal?: string
        }
        Relationships: [
          {
            foreignKeyName: "assay_result_metals_assay_result_id_fkey"
            columns: ["assay_result_id"]
            isOneToOne: false
            referencedRelation: "assay_results"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "assay_result_metals_assay_result_id_fkey"
            columns: ["assay_result_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["assay_result_id"]
          },
          {
            foreignKeyName: "assay_result_metals_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
        ]
      }
      assay_results: {
        Row: {
          applied_at: string | null
          applied_by: string | null
          assay_date: string
          certificate_ref: string | null
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          inbound_batch_id: string | null
          is_final: boolean
          lab_name: string | null
          moisture_pct: number | null
          notes: string | null
          output_batch_id: string | null
          result_party: string
          sample_ref: string | null
          superseded_by: string | null
          updated_at: string
          updated_by: string | null
          weight_basis: string | null
        }
        Insert: {
          applied_at?: string | null
          applied_by?: string | null
          assay_date: string
          certificate_ref?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          inbound_batch_id?: string | null
          is_final?: boolean
          lab_name?: string | null
          moisture_pct?: number | null
          notes?: string | null
          output_batch_id?: string | null
          result_party: string
          sample_ref?: string | null
          superseded_by?: string | null
          updated_at?: string
          updated_by?: string | null
          weight_basis?: string | null
        }
        Update: {
          applied_at?: string | null
          applied_by?: string | null
          assay_date?: string
          certificate_ref?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          inbound_batch_id?: string | null
          is_final?: boolean
          lab_name?: string | null
          moisture_pct?: number | null
          notes?: string | null
          output_batch_id?: string | null
          result_party?: string
          sample_ref?: string | null
          superseded_by?: string | null
          updated_at?: string
          updated_by?: string | null
          weight_basis?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "assay_results_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "assay_results_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "assay_results_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "assay_results_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "assay_results_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "assay_results_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "assay_results_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "assay_results_lab_name_fkey"
            columns: ["lab_name"]
            isOneToOne: false
            referencedRelation: "laboratories"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "assay_results_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "assay_results_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "assay_results_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "assay_results_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "assay_results_superseded_by_fkey"
            columns: ["superseded_by"]
            isOneToOne: false
            referencedRelation: "assay_results"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "assay_results_superseded_by_fkey"
            columns: ["superseded_by"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["assay_result_id"]
          },
        ]
      }
      attendance_lines: {
        Row: {
          active_from: string | null
          active_to: string | null
          employee_id: string
          frozen_at: string | null
          id: string
          note: string | null
          ot_normal_hours: number
          ot_public_holiday_hours: number
          ot_rest_day_hours: number
          period_id: string
          recorded_at: string | null
          recorded_by: string | null
          unpaid_days: number | null
        }
        Insert: {
          active_from?: string | null
          active_to?: string | null
          employee_id: string
          frozen_at?: string | null
          id?: string
          note?: string | null
          ot_normal_hours?: number
          ot_public_holiday_hours?: number
          ot_rest_day_hours?: number
          period_id: string
          recorded_at?: string | null
          recorded_by?: string | null
          unpaid_days?: number | null
        }
        Update: {
          active_from?: string | null
          active_to?: string | null
          employee_id?: string
          frozen_at?: string | null
          id?: string
          note?: string | null
          ot_normal_hours?: number
          ot_public_holiday_hours?: number
          ot_rest_day_hours?: number
          period_id?: string
          recorded_at?: string | null
          recorded_by?: string | null
          unpaid_days?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "attendance_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "attendance_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "attendance_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "attendance_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "attendance_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "attendance_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "attendance_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "attendance_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "attendance_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "attendance_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "attendance_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "attendance_lines_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "attendance_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      attendance_periods: {
        Row: {
          code: string
          completed_at: string | null
          completed_by: string | null
          id: string
          opened_at: string
          opened_by: string | null
          period_month: string
          reopen_reason: string | null
          reopened_at: string | null
          reopened_by: string | null
          status: string
        }
        Insert: {
          code: string
          completed_at?: string | null
          completed_by?: string | null
          id?: string
          opened_at?: string
          opened_by?: string | null
          period_month: string
          reopen_reason?: string | null
          reopened_at?: string | null
          reopened_by?: string | null
          status?: string
        }
        Update: {
          code?: string
          completed_at?: string | null
          completed_by?: string | null
          id?: string
          opened_at?: string
          opened_by?: string | null
          period_month?: string
          reopen_reason?: string | null
          reopened_at?: string | null
          reopened_by?: string | null
          status?: string
        }
        Relationships: []
      }
      bank_import_profiles: {
        Row: {
          bank_account_code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          mapping: Json
          name: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          bank_account_code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          mapping: Json
          name: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          bank_account_code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          mapping?: Json
          name?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      bank_line_matches: {
        Row: {
          created_at: string | null
          created_by: string | null
          id: string
          journal_line_id: string
          matched_amount: number
          statement_line_id: string
        }
        Insert: {
          created_at?: string | null
          created_by?: string | null
          id?: string
          journal_line_id: string
          matched_amount: number
          statement_line_id: string
        }
        Update: {
          created_at?: string | null
          created_by?: string | null
          id?: string
          journal_line_id?: string
          matched_amount?: number
          statement_line_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bank_line_matches_journal_line_id_fkey"
            columns: ["journal_line_id"]
            isOneToOne: true
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["journal_line_id"]
          },
          {
            foreignKeyName: "bank_line_matches_journal_line_id_fkey"
            columns: ["journal_line_id"]
            isOneToOne: true
            referencedRelation: "journal_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bank_line_matches_statement_line_id_fkey"
            columns: ["statement_line_id"]
            isOneToOne: false
            referencedRelation: "bank_statement_lines"
            referencedColumns: ["id"]
          },
        ]
      }
      bank_reconciliation_variance_items: {
        Row: {
          amount: number
          created_at: string
          created_by: string | null
          id: string
          item_kind: string
          item_no: number
          note: string
          reconciliation_id: string
        }
        Insert: {
          amount: number
          created_at?: string
          created_by?: string | null
          id?: string
          item_kind: string
          item_no: number
          note: string
          reconciliation_id: string
        }
        Update: {
          amount?: number
          created_at?: string
          created_by?: string | null
          id?: string
          item_kind?: string
          item_no?: number
          note?: string
          reconciliation_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bank_reconciliation_variance_items_reconciliation_id_fkey"
            columns: ["reconciliation_id"]
            isOneToOne: false
            referencedRelation: "bank_reconciliations"
            referencedColumns: ["id"]
          },
        ]
      }
      bank_reconciliations: {
        Row: {
          as_of: string
          bank_closing_balance: number
          book_balance: number
          created_at: string
          currency: string
          difference: number
          id: string
          ignored_lines: number
          matched_lines: number
          reconciled_at: string
          reconciled_by: string | null
          statement_id: string
          superseded_at: string | null
          superseded_reason: string | null
        }
        Insert: {
          as_of: string
          bank_closing_balance: number
          book_balance: number
          created_at?: string
          currency: string
          difference: number
          id?: string
          ignored_lines: number
          matched_lines: number
          reconciled_at?: string
          reconciled_by?: string | null
          statement_id: string
          superseded_at?: string | null
          superseded_reason?: string | null
        }
        Update: {
          as_of?: string
          bank_closing_balance?: number
          book_balance?: number
          created_at?: string
          currency?: string
          difference?: number
          id?: string
          ignored_lines?: number
          matched_lines?: number
          reconciled_at?: string
          reconciled_by?: string | null
          statement_id?: string
          superseded_at?: string | null
          superseded_reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "bank_reconciliations_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "bank_reconciliations_statement_id_fkey"
            columns: ["statement_id"]
            isOneToOne: false
            referencedRelation: "bank_statements"
            referencedColumns: ["id"]
          },
        ]
      }
      bank_statement_lines: {
        Row: {
          amount: number
          created_at: string | null
          description: string | null
          id: string
          ignore_reason: string | null
          line_date: string
          line_no: number
          match_status: string
          notes: string | null
          reference: string | null
          statement_id: string
        }
        Insert: {
          amount: number
          created_at?: string | null
          description?: string | null
          id?: string
          ignore_reason?: string | null
          line_date: string
          line_no: number
          match_status?: string
          notes?: string | null
          reference?: string | null
          statement_id: string
        }
        Update: {
          amount?: number
          created_at?: string | null
          description?: string | null
          id?: string
          ignore_reason?: string | null
          line_date?: string
          line_no?: number
          match_status?: string
          notes?: string | null
          reference?: string | null
          statement_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bank_statement_lines_statement_id_fkey"
            columns: ["statement_id"]
            isOneToOne: false
            referencedRelation: "bank_statements"
            referencedColumns: ["id"]
          },
        ]
      }
      bank_statements: {
        Row: {
          bank_account_code: string
          closing_balance: number
          code: string
          created_at: string
          created_by: string | null
          currency: string
          deleted_at: string | null
          file_name: string | null
          id: string
          notes: string | null
          opening_balance: number
          period_end: string
          period_start: string
          reconciled_at: string | null
          reconciled_by: string | null
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          bank_account_code: string
          closing_balance: number
          code: string
          created_at?: string
          created_by?: string | null
          currency: string
          deleted_at?: string | null
          file_name?: string | null
          id?: string
          notes?: string | null
          opening_balance: number
          period_end: string
          period_start: string
          reconciled_at?: string | null
          reconciled_by?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          bank_account_code?: string
          closing_balance?: number
          code?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          deleted_at?: string | null
          file_name?: string | null
          id?: string
          notes?: string | null
          opening_balance?: number
          period_end?: string
          period_start?: string
          reconciled_at?: string | null
          reconciled_by?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "bank_statements_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      bank_transfers: {
        Row: {
          amount_in: number
          amount_out: number
          bank_reference: string | null
          created_at: string
          created_by: string | null
          from_account: string
          id: string
          journal_entry_id: string
          notes: string | null
          reversal_entry_id: string | null
          reversed_at: string | null
          reversed_by: string | null
          to_account: string
          transfer_date: string
        }
        Insert: {
          amount_in: number
          amount_out: number
          bank_reference?: string | null
          created_at?: string
          created_by?: string | null
          from_account: string
          id?: string
          journal_entry_id: string
          notes?: string | null
          reversal_entry_id?: string | null
          reversed_at?: string | null
          reversed_by?: string | null
          to_account: string
          transfer_date: string
        }
        Update: {
          amount_in?: number
          amount_out?: number
          bank_reference?: string | null
          created_at?: string
          created_by?: string | null
          from_account?: string
          id?: string
          journal_entry_id?: string
          notes?: string | null
          reversal_entry_id?: string | null
          reversed_at?: string | null
          reversed_by?: string | null
          to_account?: string
          transfer_date?: string
        }
        Relationships: [
          {
            foreignKeyName: "bank_transfers_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "bank_transfers_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bank_transfers_reversal_entry_id_fkey"
            columns: ["reversal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "bank_transfers_reversal_entry_id_fkey"
            columns: ["reversal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      batch_processing_cost_allocations: {
        Row: {
          amount_base: number
          basis_qty: number
          basis_total_qty: number
          created_at: string
          created_by: string | null
          id: string
          inbound_batch_id: string
          run_id: string
        }
        Insert: {
          amount_base: number
          basis_qty: number
          basis_total_qty: number
          created_at?: string
          created_by?: string | null
          id?: string
          inbound_batch_id: string
          run_id: string
        }
        Update: {
          amount_base?: number
          basis_qty?: number
          basis_total_qty?: number
          created_at?: string
          created_by?: string | null
          id?: string
          inbound_batch_id?: string
          run_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "batch_processing_cost_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "batch_processing_cost_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "batch_processing_cost_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "batch_processing_cost_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "batch_processing_cost_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "batch_processing_cost_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "batch_processing_cost_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "batch_processing_cost_allocations_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "batch_processing_cost_allocations_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "batch_processing_cost_allocations_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "batch_processing_cost_allocations_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "batch_processing_cost_allocations_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_loss_breakdown"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "batch_processing_cost_allocations_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "batch_processing_cost_allocations_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      battery_chemistries: {
        Row: {
          code: string
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
        }
        Insert: {
          code: string
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
        }
        Relationships: []
      }
      cash_forecast_lines: {
        Row: {
          amount_ccy: number
          cadence: string
          created_at: string
          created_by: string | null
          currency: string
          direction: string
          end_date: string | null
          id: string
          is_active: boolean
          label: string
          notes: string | null
          start_date: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          amount_ccy: number
          cadence: string
          created_at?: string
          created_by?: string | null
          currency: string
          direction: string
          end_date?: string | null
          id?: string
          is_active?: boolean
          label: string
          notes?: string | null
          start_date: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          amount_ccy?: number
          cadence?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          direction?: string
          end_date?: string | null
          id?: string
          is_active?: boolean
          label?: string
          notes?: string | null
          start_date?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "cash_forecast_lines_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      cash_forecasts: {
        Row: {
          base_currency: string
          buckets: Json
          buffer: Json
          code: string
          frozen_at: string
          frozen_by: string | null
          horizon_weeks: number
          id: string
          lines: Json
          opening: Json
          promises_memo: Json
          superseded_at: string | null
          superseded_by: string | null
          superseded_reason: string | null
          undated: Json
          week_start: string
        }
        Insert: {
          base_currency: string
          buckets: Json
          buffer: Json
          code: string
          frozen_at?: string
          frozen_by?: string | null
          horizon_weeks?: number
          id?: string
          lines: Json
          opening: Json
          promises_memo: Json
          superseded_at?: string | null
          superseded_by?: string | null
          superseded_reason?: string | null
          undated: Json
          week_start: string
        }
        Update: {
          base_currency?: string
          buckets?: Json
          buffer?: Json
          code?: string
          frozen_at?: string
          frozen_by?: string | null
          horizon_weeks?: number
          id?: string
          lines?: Json
          opening?: Json
          promises_memo?: Json
          superseded_at?: string | null
          superseded_by?: string | null
          superseded_reason?: string | null
          undated?: Json
          week_start?: string
        }
        Relationships: [
          {
            foreignKeyName: "cash_forecasts_base_currency_fkey"
            columns: ["base_currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "cash_forecasts_superseded_by_fkey"
            columns: ["superseded_by"]
            isOneToOne: false
            referencedRelation: "cash_forecasts"
            referencedColumns: ["id"]
          },
        ]
      }
      certificate_types: {
        Row: {
          code: string
          disposition: string
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
          warn_lead_days: number
        }
        Insert: {
          code: string
          disposition: string
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
          warn_lead_days?: number
        }
        Update: {
          code?: string
          disposition?: string
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
          warn_lead_days?: number
        }
        Relationships: []
      }
      cn_issues: {
        Row: {
          credit_note_id: string
          file_path: string
          id: string
          issued_at: string
          issued_by: string | null
          sha256: string
          version: number
        }
        Insert: {
          credit_note_id: string
          file_path: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          sha256: string
          version: number
        }
        Update: {
          credit_note_id?: string
          file_path?: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          sha256?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "cn_issues_credit_note_id_fkey"
            columns: ["credit_note_id"]
            isOneToOne: false
            referencedRelation: "credit_notes"
            referencedColumns: ["id"]
          },
        ]
      }
      collection_chase_documents: {
        Row: {
          chase_id: string
          created_at: string
          id: string
          subject_code: string | null
          subject_id: string
          subject_type: string
        }
        Insert: {
          chase_id: string
          created_at?: string
          id?: string
          subject_code?: string | null
          subject_id: string
          subject_type: string
        }
        Update: {
          chase_id?: string
          created_at?: string
          id?: string
          subject_code?: string | null
          subject_id?: string
          subject_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "collection_chase_documents_chase_id_fkey"
            columns: ["chase_id"]
            isOneToOne: false
            referencedRelation: "collection_chases"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "collection_chase_documents_chase_id_fkey"
            columns: ["chase_id"]
            isOneToOne: false
            referencedRelation: "collection_promise_status"
            referencedColumns: ["chase_id"]
          },
        ]
      }
      collection_chases: {
        Row: {
          base_currency: string
          channel: string
          chased_by: string | null
          chased_on: string
          code: string
          contacted_person: string | null
          created_at: string
          customer_id: string
          id: string
          net_due_base: number
          on_account_base: number
          owed_base: number
          owed_buckets: Json
          owed_by_currency: Json
          reached: boolean
          summary: string
          superseded_at: string | null
          superseded_by: string | null
          superseded_reason: string | null
        }
        Insert: {
          base_currency: string
          channel: string
          chased_by?: string | null
          chased_on: string
          code: string
          contacted_person?: string | null
          created_at?: string
          customer_id: string
          id?: string
          net_due_base: number
          on_account_base: number
          owed_base: number
          owed_buckets: Json
          owed_by_currency: Json
          reached: boolean
          summary: string
          superseded_at?: string | null
          superseded_by?: string | null
          superseded_reason?: string | null
        }
        Update: {
          base_currency?: string
          channel?: string
          chased_by?: string | null
          chased_on?: string
          code?: string
          contacted_person?: string | null
          created_at?: string
          customer_id?: string
          id?: string
          net_due_base?: number
          on_account_base?: number
          owed_base?: number
          owed_buckets?: Json
          owed_by_currency?: Json
          reached?: boolean
          summary?: string
          superseded_at?: string | null
          superseded_by?: string | null
          superseded_reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "collection_chases_base_currency_fkey"
            columns: ["base_currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "collection_chases_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "collection_chases_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "collection_chases_superseded_by_fkey"
            columns: ["superseded_by"]
            isOneToOne: false
            referencedRelation: "collection_chases"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "collection_chases_superseded_by_fkey"
            columns: ["superseded_by"]
            isOneToOne: false
            referencedRelation: "collection_promise_status"
            referencedColumns: ["chase_id"]
          },
        ]
      }
      collection_promises: {
        Row: {
          chase_id: string
          created_at: string
          created_by: string | null
          currency: string
          fx_rate: number
          id: string
          outcome: string | null
          outcome_note: string | null
          outcome_recorded_at: string | null
          outcome_recorded_by: string | null
          promised_amount_base: number
          promised_amount_ccy: number
          promised_date: string
        }
        Insert: {
          chase_id: string
          created_at?: string
          created_by?: string | null
          currency: string
          fx_rate: number
          id?: string
          outcome?: string | null
          outcome_note?: string | null
          outcome_recorded_at?: string | null
          outcome_recorded_by?: string | null
          promised_amount_base: number
          promised_amount_ccy: number
          promised_date: string
        }
        Update: {
          chase_id?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          fx_rate?: number
          id?: string
          outcome?: string | null
          outcome_note?: string | null
          outcome_recorded_at?: string | null
          outcome_recorded_by?: string | null
          promised_amount_base?: number
          promised_amount_ccy?: number
          promised_date?: string
        }
        Relationships: [
          {
            foreignKeyName: "collection_promises_chase_id_fkey"
            columns: ["chase_id"]
            isOneToOne: true
            referencedRelation: "collection_chases"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "collection_promises_chase_id_fkey"
            columns: ["chase_id"]
            isOneToOne: true
            referencedRelation: "collection_promise_status"
            referencedColumns: ["chase_id"]
          },
          {
            foreignKeyName: "collection_promises_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      commission_agreements: {
        Row: {
          agent_supplier_id: string
          amount_ccy: number | null
          basis: string
          created_at: string
          created_by: string | null
          currency: string | null
          deleted_at: string | null
          id: string
          rate_pct: number | null
          recognition_trigger: string
          remarks: string | null
          side: string
          updated_at: string
          updated_by: string | null
          valid_from: string
          valid_to: string
        }
        Insert: {
          agent_supplier_id: string
          amount_ccy?: number | null
          basis: string
          created_at?: string
          created_by?: string | null
          currency?: string | null
          deleted_at?: string | null
          id?: string
          rate_pct?: number | null
          recognition_trigger: string
          remarks?: string | null
          side: string
          updated_at?: string
          updated_by?: string | null
          valid_from: string
          valid_to: string
        }
        Update: {
          agent_supplier_id?: string
          amount_ccy?: number | null
          basis?: string
          created_at?: string
          created_by?: string | null
          currency?: string | null
          deleted_at?: string | null
          id?: string
          rate_pct?: number | null
          recognition_trigger?: string
          remarks?: string | null
          side?: string
          updated_at?: string
          updated_by?: string | null
          valid_from?: string
          valid_to?: string
        }
        Relationships: [
          {
            foreignKeyName: "commission_agreements_agent_supplier_id_fkey"
            columns: ["agent_supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "commission_agreements_agent_supplier_id_fkey"
            columns: ["agent_supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "commission_agreements_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      company_compliance: {
        Row: {
          approved_storage_limit_tonnes: number | null
          cert_no: string | null
          cert_type_code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          document_path: string | null
          id: string
          issue_date: string | null
          issuing_body: string | null
          notes: string | null
          scope: string | null
          status: string | null
          updated_at: string
          updated_by: string | null
          valid_from: string | null
          valid_until: string | null
        }
        Insert: {
          approved_storage_limit_tonnes?: number | null
          cert_no?: string | null
          cert_type_code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          document_path?: string | null
          id?: string
          issue_date?: string | null
          issuing_body?: string | null
          notes?: string | null
          scope?: string | null
          status?: string | null
          updated_at?: string
          updated_by?: string | null
          valid_from?: string | null
          valid_until?: string | null
        }
        Update: {
          approved_storage_limit_tonnes?: number | null
          cert_no?: string | null
          cert_type_code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          document_path?: string | null
          id?: string
          issue_date?: string | null
          issuing_body?: string | null
          notes?: string | null
          scope?: string | null
          status?: string | null
          updated_at?: string
          updated_by?: string | null
          valid_from?: string | null
          valid_until?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "company_compliance_cert_type_code_fkey"
            columns: ["cert_type_code"]
            isOneToOne: false
            referencedRelation: "certificate_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "company_compliance_cert_type_code_fkey"
            columns: ["cert_type_code"]
            isOneToOne: false
            referencedRelation: "supplier_receiving_blocked"
            referencedColumns: ["cert_type_code"]
          },
        ]
      }
      company_profile: {
        Row: {
          address_lines: string | null
          bank_account_name: string | null
          bank_account_no: string | null
          bank_address: string | null
          bank_name: string | null
          bank_swift: string | null
          city: string | null
          country: string | null
          email: string | null
          id: boolean
          invoice_footer_text: string | null
          legal_name: string
          logo_path: string | null
          phone: string | null
          postal_code: string | null
          registration_no: string | null
          updated_at: string
          updated_by: string | null
          website: string | null
        }
        Insert: {
          address_lines?: string | null
          bank_account_name?: string | null
          bank_account_no?: string | null
          bank_address?: string | null
          bank_name?: string | null
          bank_swift?: string | null
          city?: string | null
          country?: string | null
          email?: string | null
          id?: boolean
          invoice_footer_text?: string | null
          legal_name?: string
          logo_path?: string | null
          phone?: string | null
          postal_code?: string | null
          registration_no?: string | null
          updated_at?: string
          updated_by?: string | null
          website?: string | null
        }
        Update: {
          address_lines?: string | null
          bank_account_name?: string | null
          bank_account_no?: string | null
          bank_address?: string | null
          bank_name?: string | null
          bank_swift?: string | null
          city?: string | null
          country?: string | null
          email?: string | null
          id?: boolean
          invoice_footer_text?: string | null
          legal_name?: string
          logo_path?: string | null
          phone?: string | null
          postal_code?: string | null
          registration_no?: string | null
          updated_at?: string
          updated_by?: string | null
          website?: string | null
        }
        Relationships: []
      }
      container_documents: {
        Row: {
          container_id: string
          created_at: string
          created_by: string | null
          document_type: string
          from_lane: boolean
          id: string
          na_reason: string | null
          notes: string | null
          regime: string | null
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          container_id: string
          created_at?: string
          created_by?: string | null
          document_type: string
          from_lane?: boolean
          id?: string
          na_reason?: string | null
          notes?: string | null
          regime?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          container_id?: string
          created_at?: string
          created_by?: string | null
          document_type?: string
          from_lane?: boolean
          id?: string
          na_reason?: string | null
          notes?: string | null
          regime?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "container_documents_container_id_fkey"
            columns: ["container_id"]
            isOneToOne: false
            referencedRelation: "container_overview"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "container_documents_container_id_fkey"
            columns: ["container_id"]
            isOneToOne: false
            referencedRelation: "containers"
            referencedColumns: ["id"]
          },
        ]
      }
      container_milestones: {
        Row: {
          container_id: string
          event_date: string
          id: string
          milestone: string
          note: string | null
          recorded_at: string
          recorded_by: string | null
        }
        Insert: {
          container_id: string
          event_date: string
          id?: string
          milestone: string
          note?: string | null
          recorded_at?: string
          recorded_by?: string | null
        }
        Update: {
          container_id?: string
          event_date?: string
          id?: string
          milestone?: string
          note?: string | null
          recorded_at?: string
          recorded_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "container_milestones_container_id_fkey"
            columns: ["container_id"]
            isOneToOne: false
            referencedRelation: "container_overview"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "container_milestones_container_id_fkey"
            columns: ["container_id"]
            isOneToOne: false
            referencedRelation: "containers"
            referencedColumns: ["id"]
          },
        ]
      }
      containers: {
        Row: {
          bl_number: string | null
          code: string
          container_number: string | null
          created_at: string
          created_by: string | null
          delete_reason: string | null
          deleted_at: string | null
          deleted_by: string | null
          departure_date: string
          expected_arrival_date: string | null
          forwarder_id: string | null
          id: string
          lane_id: string | null
          notes: string | null
          updated_at: string
          updated_by: string | null
          vessel: string | null
          voyage: string | null
        }
        Insert: {
          bl_number?: string | null
          code: string
          container_number?: string | null
          created_at?: string
          created_by?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          departure_date: string
          expected_arrival_date?: string | null
          forwarder_id?: string | null
          id?: string
          lane_id?: string | null
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          vessel?: string | null
          voyage?: string | null
        }
        Update: {
          bl_number?: string | null
          code?: string
          container_number?: string | null
          created_at?: string
          created_by?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          departure_date?: string
          expected_arrival_date?: string | null
          forwarder_id?: string | null
          id?: string
          lane_id?: string | null
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          vessel?: string | null
          voyage?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "containers_forwarder_id_fkey"
            columns: ["forwarder_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "containers_forwarder_id_fkey"
            columns: ["forwarder_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "containers_lane_id_fkey"
            columns: ["lane_id"]
            isOneToOne: false
            referencedRelation: "lane_checklist_status"
            referencedColumns: ["lane_id"]
          },
          {
            foreignKeyName: "containers_lane_id_fkey"
            columns: ["lane_id"]
            isOneToOne: false
            referencedRelation: "lanes"
            referencedColumns: ["id"]
          },
        ]
      }
      contract_document_terms: {
        Row: {
          contract_code: string
          contract_id: string
          contract_title: string | null
          currency: string | null
          grade_specs: Json
          id: string
          incoterm: string | null
          linked_at: string
          linked_by: string | null
          payment_terms_days: number | null
          pricing_terms: Json
          purchase_order_id: string | null
          sales_order_id: string | null
          settlement_terms: Json
        }
        Insert: {
          contract_code: string
          contract_id: string
          contract_title?: string | null
          currency?: string | null
          grade_specs?: Json
          id?: string
          incoterm?: string | null
          linked_at?: string
          linked_by?: string | null
          payment_terms_days?: number | null
          pricing_terms?: Json
          purchase_order_id?: string | null
          sales_order_id?: string | null
          settlement_terms?: Json
        }
        Update: {
          contract_code?: string
          contract_id?: string
          contract_title?: string | null
          currency?: string | null
          grade_specs?: Json
          id?: string
          incoterm?: string | null
          linked_at?: string
          linked_by?: string | null
          payment_terms_days?: number | null
          pricing_terms?: Json
          purchase_order_id?: string | null
          sales_order_id?: string | null
          settlement_terms?: Json
        }
        Relationships: [
          {
            foreignKeyName: "contract_document_terms_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: false
            referencedRelation: "contracts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contract_document_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: true
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "contract_document_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: true
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "contract_document_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: true
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "contract_document_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: true
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "contract_document_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "contract_document_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: true
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contract_document_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: true
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contract_document_terms_sales_order_id_fkey"
            columns: ["sales_order_id"]
            isOneToOne: true
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      contract_grade_specs: {
        Row: {
          contract_id: string
          created_at: string
          created_by: string | null
          id: string
          material_id: string | null
          max_pct: number | null
          metal: string
          min_pct: number | null
          notes: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          contract_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          material_id?: string | null
          max_pct?: number | null
          metal: string
          min_pct?: number | null
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          contract_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          material_id?: string | null
          max_pct?: number | null
          metal?: string
          min_pct?: number | null
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "contract_grade_specs_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: false
            referencedRelation: "contracts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contract_grade_specs_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "contract_grade_specs_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contract_grade_specs_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "contract_grade_specs_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
        ]
      }
      contract_insurance_obligations: {
        Row: {
          contract_id: string
          cover_type: string
          created_at: string
          created_by: string | null
          currency: string | null
          id: string
          insured_by: string
          min_amount: number | null
          notes: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          contract_id: string
          cover_type: string
          created_at?: string
          created_by?: string | null
          currency?: string | null
          id?: string
          insured_by: string
          min_amount?: number | null
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          contract_id?: string
          cover_type?: string
          created_at?: string
          created_by?: string | null
          currency?: string | null
          id?: string
          insured_by?: string
          min_amount?: number | null
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "contract_insurance_obligations_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: false
            referencedRelation: "contracts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contract_insurance_obligations_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      contract_penalty_elements: {
        Row: {
          contract_id: string
          created_at: string
          created_by: string | null
          id: string
          notes: string | null
          substance: string
          threshold_pct: number
          updated_at: string
          updated_by: string | null
          usd_per_tonne_per_pct_over: number
        }
        Insert: {
          contract_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          notes?: string | null
          substance: string
          threshold_pct: number
          updated_at?: string
          updated_by?: string | null
          usd_per_tonne_per_pct_over: number
        }
        Update: {
          contract_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          notes?: string | null
          substance?: string
          threshold_pct?: number
          updated_at?: string
          updated_by?: string | null
          usd_per_tonne_per_pct_over?: number
        }
        Relationships: [
          {
            foreignKeyName: "contract_penalty_elements_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: false
            referencedRelation: "contracts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contract_penalty_elements_substance_fkey"
            columns: ["substance"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
        ]
      }
      contract_pricing_terms: {
        Row: {
          base_event: string
          contract_id: string
          created_at: string
          created_by: string | null
          id: string
          index_code: string
          metal: string
          notes: string | null
          payable_pct: number
          qp_months: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          base_event: string
          contract_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          index_code: string
          metal: string
          notes?: string | null
          payable_pct: number
          qp_months: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          base_event?: string
          contract_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          index_code?: string
          metal?: string
          notes?: string | null
          payable_pct?: number
          qp_months?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "contract_pricing_terms_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: false
            referencedRelation: "contracts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contract_pricing_terms_index_code_fkey"
            columns: ["index_code"]
            isOneToOne: false
            referencedRelation: "metal_price_indices"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "contract_pricing_terms_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
        ]
      }
      contract_refining_charges: {
        Row: {
          contract_id: string
          created_at: string
          created_by: string | null
          id: string
          metal: string
          notes: string | null
          updated_at: string
          updated_by: string | null
          usd_per_tonne_of_metal: number
        }
        Insert: {
          contract_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          metal: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          usd_per_tonne_of_metal: number
        }
        Update: {
          contract_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          metal?: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          usd_per_tonne_of_metal?: number
        }
        Relationships: [
          {
            foreignKeyName: "contract_refining_charges_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: false
            referencedRelation: "contracts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contract_refining_charges_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
        ]
      }
      contract_settlement_terms: {
        Row: {
          contract_id: string
          created_at: string
          created_by: string | null
          id: string
          notes: string | null
          penalty_basis: string
          refining_charge_basis: string
          sale_weight_basis: string
          sample_retention_days: number | null
          sample_retention_required: boolean
          settling_party: string
          splitting_limit_pct: number | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          contract_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          notes?: string | null
          penalty_basis: string
          refining_charge_basis: string
          sale_weight_basis: string
          sample_retention_days?: number | null
          sample_retention_required: boolean
          settling_party: string
          splitting_limit_pct?: number | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          contract_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          notes?: string | null
          penalty_basis?: string
          refining_charge_basis?: string
          sale_weight_basis?: string
          sample_retention_days?: number | null
          sample_retention_required?: boolean
          settling_party?: string
          splitting_limit_pct?: number | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "contract_settlement_terms_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: true
            referencedRelation: "contracts"
            referencedColumns: ["id"]
          },
        ]
      }
      contract_volume_commitments: {
        Row: {
          committed_by_party: string
          contract_id: string
          created_at: string
          created_by: string | null
          direction: string
          id: string
          material_id: string | null
          notes: string | null
          period: string
          quantity: number
          unit: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          committed_by_party: string
          contract_id: string
          created_at?: string
          created_by?: string | null
          direction?: string
          id?: string
          material_id?: string | null
          notes?: string | null
          period: string
          quantity: number
          unit: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          committed_by_party?: string
          contract_id?: string
          created_at?: string
          created_by?: string | null
          direction?: string
          id?: string
          material_id?: string | null
          notes?: string | null
          period?: string
          quantity?: number
          unit?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "contract_volume_commitments_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: false
            referencedRelation: "contracts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contract_volume_commitments_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "contract_volume_commitments_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contract_volume_commitments_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
        ]
      }
      contracts: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          currency: string | null
          customer_id: string | null
          deleted_at: string | null
          document_ref: string | null
          effective_from: string
          effective_to: string | null
          id: string
          incoterm: string | null
          kind: string
          notes: string | null
          payment_terms_days: number | null
          side: string | null
          signed_on: string | null
          status: string
          supplier_id: string | null
          title: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          currency?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          document_ref?: string | null
          effective_from: string
          effective_to?: string | null
          id?: string
          incoterm?: string | null
          kind: string
          notes?: string | null
          payment_terms_days?: number | null
          side?: string | null
          signed_on?: string | null
          status?: string
          supplier_id?: string | null
          title: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          currency?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          document_ref?: string | null
          effective_from?: string
          effective_to?: string | null
          id?: string
          incoterm?: string | null
          kind?: string
          notes?: string | null
          payment_terms_days?: number | null
          side?: string | null
          signed_on?: string | null
          status?: string
          supplier_id?: string | null
          title?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "contracts_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "contracts_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "contracts_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contracts_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "contracts_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      counterparty_contacts: {
        Row: {
          created_at: string
          created_by: string | null
          customer_id: string | null
          deleted_at: string | null
          email: string | null
          id: string
          is_primary: boolean
          name: string
          name_inferred: boolean
          notes: string | null
          phone: string | null
          role: string | null
          supplier_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          email?: string | null
          id?: string
          is_primary?: boolean
          name: string
          name_inferred?: boolean
          notes?: string | null
          phone?: string | null
          role?: string | null
          supplier_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          email?: string | null
          id?: string
          is_primary?: boolean
          name?: string
          name_inferred?: boolean
          notes?: string | null
          phone?: string | null
          role?: string | null
          supplier_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "counterparty_contacts_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "counterparty_contacts_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "counterparty_contacts_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "counterparty_contacts_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      credit_note_lines: {
        Row: {
          amount: number
          created_at: string
          credit_note_id: string
          id: string
          invoice_line_id: string
          kind: string
          qty: number | null
          tax_base: number
          tax_code: string | null
          tax_rate_pct: number | null
        }
        Insert: {
          amount: number
          created_at?: string
          credit_note_id: string
          id?: string
          invoice_line_id: string
          kind: string
          qty?: number | null
          tax_base?: number
          tax_code?: string | null
          tax_rate_pct?: number | null
        }
        Update: {
          amount?: number
          created_at?: string
          credit_note_id?: string
          id?: string
          invoice_line_id?: string
          kind?: string
          qty?: number | null
          tax_base?: number
          tax_code?: string | null
          tax_rate_pct?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "credit_note_lines_credit_note_id_fkey"
            columns: ["credit_note_id"]
            isOneToOne: false
            referencedRelation: "credit_notes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_note_lines_invoice_line_id_fkey"
            columns: ["invoice_line_id"]
            isOneToOne: false
            referencedRelation: "invoice_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_note_lines_invoice_line_id_fkey"
            columns: ["invoice_line_id"]
            isOneToOne: false
            referencedRelation: "invoice_lines_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_note_lines_tax_code_fkey"
            columns: ["tax_code"]
            isOneToOne: false
            referencedRelation: "tax_codes"
            referencedColumns: ["code"]
          },
        ]
      }
      credit_notes: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          currency: string
          entry_id: string
          fx_rate: number
          id: string
          invoice_id: string
          note_date: string
          reason: string
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          currency: string
          entry_id: string
          fx_rate: number
          id?: string
          invoice_id: string
          note_date: string
          reason: string
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          entry_id?: string
          fx_rate?: number
          id?: string
          invoice_id?: string
          note_date?: string
          reason?: string
        }
        Relationships: [
          {
            foreignKeyName: "credit_notes_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "credit_notes_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "credit_notes_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_notes_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_document_totals"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "credit_notes_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_status"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "credit_notes_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_notes_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_notes_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_balance_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "credit_notes_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_open_all"
            referencedColumns: ["invoice_id"]
          },
        ]
      }
      currencies: {
        Row: {
          code: string
          is_base: boolean
          name: string
        }
        Insert: {
          code: string
          is_base?: boolean
          name: string
        }
        Update: {
          code?: string
          is_base?: boolean
          name?: string
        }
        Relationships: []
      }
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
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "customer_attachments_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      customer_credit_history: {
        Row: {
          changed_at: string
          changed_by: string | null
          customer_id: string
          id: string
          new_credit_hold: boolean | null
          new_credit_limit_base: number | null
          old_credit_hold: boolean | null
          old_credit_limit_base: number | null
        }
        Insert: {
          changed_at?: string
          changed_by?: string | null
          customer_id: string
          id?: string
          new_credit_hold?: boolean | null
          new_credit_limit_base?: number | null
          old_credit_hold?: boolean | null
          old_credit_limit_base?: number | null
        }
        Update: {
          changed_at?: string
          changed_by?: string | null
          customer_id?: string
          id?: string
          new_credit_hold?: boolean | null
          new_credit_limit_base?: number | null
          old_credit_hold?: boolean | null
          old_credit_limit_base?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "customer_credit_history_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "customer_credit_history_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      customer_statements: {
        Row: {
          base_currency: string
          buckets: Json
          by_currency: Json
          charges_base: number
          closing_base: number
          code: string
          created_at: string
          credits_base: number
          customer_id: string
          id: string
          issued_at: string
          issued_by: string | null
          lines: Json
          opening_base: number
          period_end: string
          period_start: string
          receipts_base: number
          superseded_at: string | null
          superseded_by: string | null
          superseded_reason: string | null
        }
        Insert: {
          base_currency: string
          buckets: Json
          by_currency: Json
          charges_base: number
          closing_base: number
          code: string
          created_at?: string
          credits_base: number
          customer_id: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          lines: Json
          opening_base: number
          period_end: string
          period_start: string
          receipts_base: number
          superseded_at?: string | null
          superseded_by?: string | null
          superseded_reason?: string | null
        }
        Update: {
          base_currency?: string
          buckets?: Json
          by_currency?: Json
          charges_base?: number
          closing_base?: number
          code?: string
          created_at?: string
          credits_base?: number
          customer_id?: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          lines?: Json
          opening_base?: number
          period_end?: string
          period_start?: string
          receipts_base?: number
          superseded_at?: string | null
          superseded_by?: string | null
          superseded_reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "customer_statements_base_currency_fkey"
            columns: ["base_currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "customer_statements_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "customer_statements_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "customer_statements_superseded_by_fkey"
            columns: ["superseded_by"]
            isOneToOne: false
            referencedRelation: "customer_statements"
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
          credit_hold: boolean
          credit_limit_base: number | null
          credit_rating: string | null
          customer_types: string[] | null
          default_tax_code: string | null
          deleted_at: string | null
          id: string
          incoterm: string | null
          legal_name: string
          notes: string | null
          payment_terms: string | null
          payment_terms_days: number | null
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
          credit_hold?: boolean
          credit_limit_base?: number | null
          credit_rating?: string | null
          customer_types?: string[] | null
          default_tax_code?: string | null
          deleted_at?: string | null
          id?: string
          incoterm?: string | null
          legal_name: string
          notes?: string | null
          payment_terms?: string | null
          payment_terms_days?: number | null
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
          credit_hold?: boolean
          credit_limit_base?: number | null
          credit_rating?: string | null
          customer_types?: string[] | null
          default_tax_code?: string | null
          deleted_at?: string | null
          id?: string
          incoterm?: string | null
          legal_name?: string
          notes?: string | null
          payment_terms?: string | null
          payment_terms_days?: number | null
          short_name?: string | null
          status?: string
          tax_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "customers_default_tax_code_fkey"
            columns: ["default_tax_code"]
            isOneToOne: false
            referencedRelation: "tax_codes"
            referencedColumns: ["code"]
          },
        ]
      }
      deep_discharge_judgements: {
        Row: {
          code: string
          is_a_claim: boolean
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
        }
        Insert: {
          code: string
          is_a_claim: boolean
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          is_a_claim?: boolean
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
        }
        Relationships: []
      }
      departments: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          is_active: boolean
          manager_employee_id: string | null
          name_en: string
          name_zh: string
          notes: string | null
          parent_department_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          manager_employee_id?: string | null
          name_en: string
          name_zh: string
          notes?: string | null
          parent_department_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          manager_employee_id?: string | null
          name_en?: string
          name_zh?: string
          notes?: string | null
          parent_department_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "departments_parent_department_id_fkey"
            columns: ["parent_department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
        ]
      }
      employees: {
        Row: {
          anonymised_at: string | null
          anonymised_by: string | null
          code: string
          confirmation_date: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          department_id: string | null
          employment_status: string
          employment_type: string
          hire_date: string
          id: string
          identity_no: string | null
          legal_name: string
          manager_id: string | null
          monthly_salary: number | null
          monthly_salary_set: boolean | null
          notes: string | null
          position_id: string | null
          preferred_name: string | null
          probation_end_date: string | null
          residency_status: string | null
          review_exempt: boolean
          separation_date: string | null
          separation_notes: string | null
          separation_type: string | null
          updated_at: string
          updated_by: string | null
          user_id: string | null
          work_category: string
          work_email: string | null
          work_pass_expiry_date: string | null
          work_pass_issue_date: string | null
          work_pass_no: string | null
          work_pass_type: string | null
          work_phone: string | null
        }
        Insert: {
          anonymised_at?: string | null
          anonymised_by?: string | null
          code: string
          confirmation_date?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          department_id?: string | null
          employment_status?: string
          employment_type: string
          hire_date: string
          id?: string
          identity_no?: string | null
          legal_name: string
          manager_id?: string | null
          monthly_salary?: number | null
          monthly_salary_set?: boolean | null
          notes?: string | null
          position_id?: string | null
          preferred_name?: string | null
          probation_end_date?: string | null
          residency_status?: string | null
          review_exempt?: boolean
          separation_date?: string | null
          separation_notes?: string | null
          separation_type?: string | null
          updated_at?: string
          updated_by?: string | null
          user_id?: string | null
          work_category: string
          work_email?: string | null
          work_pass_expiry_date?: string | null
          work_pass_issue_date?: string | null
          work_pass_no?: string | null
          work_pass_type?: string | null
          work_phone?: string | null
        }
        Update: {
          anonymised_at?: string | null
          anonymised_by?: string | null
          code?: string
          confirmation_date?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          department_id?: string | null
          employment_status?: string
          employment_type?: string
          hire_date?: string
          id?: string
          identity_no?: string | null
          legal_name?: string
          manager_id?: string | null
          monthly_salary?: number | null
          monthly_salary_set?: boolean | null
          notes?: string | null
          position_id?: string | null
          preferred_name?: string | null
          probation_end_date?: string | null
          residency_status?: string | null
          review_exempt?: boolean
          separation_date?: string | null
          separation_notes?: string | null
          separation_type?: string | null
          updated_at?: string
          updated_by?: string | null
          user_id?: string | null
          work_category?: string
          work_email?: string | null
          work_pass_expiry_date?: string | null
          work_pass_issue_date?: string | null
          work_pass_no?: string | null
          work_pass_type?: string | null
          work_phone?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employees_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
        ]
      }
      employment_history: {
        Row: {
          anonymised_at: string | null
          change_type: string
          created_at: string
          created_by: string | null
          department_id: string | null
          effective_date: string
          employee_id: string
          employment_status: string | null
          employment_type: string | null
          id: string
          job_title: string | null
          new_monthly_salary: number | null
          notes: string | null
          old_monthly_salary: number | null
          work_category: string | null
        }
        Insert: {
          anonymised_at?: string | null
          change_type: string
          created_at?: string
          created_by?: string | null
          department_id?: string | null
          effective_date: string
          employee_id: string
          employment_status?: string | null
          employment_type?: string | null
          id?: string
          job_title?: string | null
          new_monthly_salary?: number | null
          notes?: string | null
          old_monthly_salary?: number | null
          work_category?: string | null
        }
        Update: {
          anonymised_at?: string | null
          change_type?: string
          created_at?: string
          created_by?: string | null
          department_id?: string | null
          effective_date?: string
          employee_id?: string
          employment_status?: string | null
          employment_type?: string | null
          id?: string
          job_title?: string | null
          new_monthly_salary?: number | null
          notes?: string | null
          old_monthly_salary?: number | null
          work_category?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employment_history_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      equipment_downtime: {
        Row: {
          created_at: string
          created_by: string | null
          duration: string | null
          ended_at: string | null
          equipment_id: string
          id: string
          notes: string | null
          reason: string
          started_at: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          duration?: string | null
          ended_at?: string | null
          equipment_id: string
          id?: string
          notes?: string | null
          reason: string
          started_at: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          duration?: string | null
          ended_at?: string | null
          equipment_id?: string
          id?: string
          notes?: string | null
          reason?: string
          started_at?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "equipment_downtime_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "equipment_service_status"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "equipment_downtime_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "equipment_usage"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "equipment_downtime_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "fixed_assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "equipment_downtime_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_retention_status"
            referencedColumns: ["asset_id"]
          },
        ]
      }
      equipment_maintenance: {
        Row: {
          capitalisation_reason: string | null
          capitalised: boolean
          capitalised_expense_id: string | null
          created_at: string
          created_by: string | null
          description: string
          downtime_id: string | null
          equipment_id: string
          expense_id: string | null
          id: string
          kind: string
          notes: string | null
          performed_by_employee_id: string | null
          performed_by_name: string | null
          performed_by_supplier_id: string | null
          performed_on: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          capitalisation_reason?: string | null
          capitalised?: boolean
          capitalised_expense_id?: string | null
          created_at?: string
          created_by?: string | null
          description: string
          downtime_id?: string | null
          equipment_id: string
          expense_id?: string | null
          id?: string
          kind: string
          notes?: string | null
          performed_by_employee_id?: string | null
          performed_by_name?: string | null
          performed_by_supplier_id?: string | null
          performed_on: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          capitalisation_reason?: string | null
          capitalised?: boolean
          capitalised_expense_id?: string | null
          created_at?: string
          created_by?: string | null
          description?: string
          downtime_id?: string | null
          equipment_id?: string
          expense_id?: string | null
          id?: string
          kind?: string
          notes?: string | null
          performed_by_employee_id?: string | null
          performed_by_name?: string | null
          performed_by_supplier_id?: string | null
          performed_on?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "equipment_maintenance_capitalised_expense_id_fkey"
            columns: ["capitalised_expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "equipment_maintenance_downtime_id_fkey"
            columns: ["downtime_id"]
            isOneToOne: false
            referencedRelation: "equipment_downtime"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "equipment_maintenance_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "equipment_service_status"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "equipment_usage"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "fixed_assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "equipment_maintenance_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_retention_status"
            referencedColumns: ["asset_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "equipment_maintenance_performed_by_employee_id_fkey"
            columns: ["performed_by_employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_performed_by_employee_id_fkey"
            columns: ["performed_by_employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "equipment_maintenance_performed_by_employee_id_fkey"
            columns: ["performed_by_employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "equipment_maintenance_performed_by_employee_id_fkey"
            columns: ["performed_by_employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "equipment_maintenance_performed_by_employee_id_fkey"
            columns: ["performed_by_employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_performed_by_employee_id_fkey"
            columns: ["performed_by_employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_performed_by_employee_id_fkey"
            columns: ["performed_by_employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_performed_by_employee_id_fkey"
            columns: ["performed_by_employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_performed_by_employee_id_fkey"
            columns: ["performed_by_employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_performed_by_employee_id_fkey"
            columns: ["performed_by_employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_performed_by_employee_id_fkey"
            columns: ["performed_by_employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_performed_by_supplier_id_fkey"
            columns: ["performed_by_supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_performed_by_supplier_id_fkey"
            columns: ["performed_by_supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      equipment_service_intervals: {
        Row: {
          created_at: string
          created_by: string | null
          disposition: string
          equipment_id: string
          id: string
          interval_days: number | null
          interval_kg: number | null
          kind: string
          lead_days: number | null
          lead_kg: number | null
          notes: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          disposition?: string
          equipment_id: string
          id?: string
          interval_days?: number | null
          interval_kg?: number | null
          kind: string
          lead_days?: number | null
          lead_kg?: number | null
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          disposition?: string
          equipment_id?: string
          id?: string
          interval_days?: number | null
          interval_kg?: number | null
          kind?: string
          lead_days?: number | null
          lead_kg?: number | null
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "equipment_service_intervals_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "equipment_service_status"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "equipment_service_intervals_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "equipment_usage"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "equipment_service_intervals_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "fixed_assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "equipment_service_intervals_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_retention_status"
            referencedColumns: ["asset_id"]
          },
        ]
      }
      expense_claims: {
        Row: {
          account_code: string | null
          amount_ccy: number
          code: string
          created_at: string
          created_by: string | null
          currency: string
          decided_at: string | null
          decided_by: string | null
          decision_notes: string | null
          description: string
          employee_id: string
          expense_id: string | null
          id: string
          no_receipt_reason: string | null
          posting_date: string | null
          spend_date: string
          status: string
          submitted_at: string
          tax_code: string | null
          withdrawn_at: string | null
        }
        Insert: {
          account_code?: string | null
          amount_ccy: number
          code: string
          created_at?: string
          created_by?: string | null
          currency: string
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          description: string
          employee_id: string
          expense_id?: string | null
          id?: string
          no_receipt_reason?: string | null
          posting_date?: string | null
          spend_date: string
          status?: string
          submitted_at?: string
          tax_code?: string | null
          withdrawn_at?: string | null
        }
        Update: {
          account_code?: string | null
          amount_ccy?: number
          code?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          description?: string
          employee_id?: string
          expense_id?: string | null
          id?: string
          no_receipt_reason?: string | null
          posting_date?: string | null
          spend_date?: string
          status?: string
          submitted_at?: string
          tax_code?: string | null
          withdrawn_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "expense_claims_account_code_fkey"
            columns: ["account_code"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "expense_claims_account_code_fkey"
            columns: ["account_code"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["account_code"]
          },
          {
            foreignKeyName: "expense_claims_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_claims_tax_code_fkey"
            columns: ["tax_code"]
            isOneToOne: false
            referencedRelation: "tax_codes"
            referencedColumns: ["code"]
          },
        ]
      }
      expenses: {
        Row: {
          account_code: string
          amount_base: number
          amount_ccy: number
          bank_account_code: string | null
          code: string
          created_at: string | null
          created_by: string | null
          currency: string
          employee_id: string | null
          expense_date: string
          fx_rate: number
          id: string
          journal_entry_id: string | null
          notes: string | null
          payee_name: string | null
          payment_status: string
          purchase_order_line_id: string | null
          reversed_by_expense: string | null
          status: string
          supplier_id: string | null
          tax_base: number
          tax_code: string | null
          tax_rate_pct: number | null
          wht_amount_ccy: number
          wht_nature: string | null
          wht_payee_residence: string | null
          wht_rate_pct: number | null
          wht_treaty_ref: string | null
        }
        Insert: {
          account_code: string
          amount_base: number
          amount_ccy: number
          bank_account_code?: string | null
          code: string
          created_at?: string | null
          created_by?: string | null
          currency: string
          employee_id?: string | null
          expense_date: string
          fx_rate: number
          id?: string
          journal_entry_id?: string | null
          notes?: string | null
          payee_name?: string | null
          payment_status: string
          purchase_order_line_id?: string | null
          reversed_by_expense?: string | null
          status?: string
          supplier_id?: string | null
          tax_base?: number
          tax_code?: string | null
          tax_rate_pct?: number | null
          wht_amount_ccy?: number
          wht_nature?: string | null
          wht_payee_residence?: string | null
          wht_rate_pct?: number | null
          wht_treaty_ref?: string | null
        }
        Update: {
          account_code?: string
          amount_base?: number
          amount_ccy?: number
          bank_account_code?: string | null
          code?: string
          created_at?: string | null
          created_by?: string | null
          currency?: string
          employee_id?: string | null
          expense_date?: string
          fx_rate?: number
          id?: string
          journal_entry_id?: string | null
          notes?: string | null
          payee_name?: string | null
          payment_status?: string
          purchase_order_line_id?: string | null
          reversed_by_expense?: string | null
          status?: string
          supplier_id?: string | null
          tax_base?: number
          tax_code?: string | null
          tax_rate_pct?: number | null
          wht_amount_ccy?: number
          wht_nature?: string | null
          wht_payee_residence?: string | null
          wht_rate_pct?: number | null
          wht_treaty_ref?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "expenses_account_code_fkey"
            columns: ["account_code"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "expenses_account_code_fkey"
            columns: ["account_code"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["account_code"]
          },
          {
            foreignKeyName: "expenses_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "expenses_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expenses_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expenses_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expenses_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expenses_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expenses_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expenses_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expenses_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expenses_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "expenses_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "expenses_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "expenses_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_lines_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_reversed_by_expense_fkey"
            columns: ["reversed_by_expense"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "expenses_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_tax_code_fkey"
            columns: ["tax_code"]
            isOneToOne: false
            referencedRelation: "tax_codes"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "expenses_wht_nature_fkey"
            columns: ["wht_nature"]
            isOneToOne: false
            referencedRelation: "wht_natures"
            referencedColumns: ["code"]
          },
        ]
      }
      finance_attachments: {
        Row: {
          claim_id: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          doc_type: string | null
          expense_id: string | null
          file_name: string
          file_path: string
          file_size: number | null
          id: string
          inbound_batch_id: string | null
          mime_type: string | null
          notes: string | null
          payment_id: string | null
          sales_record_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          claim_id?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          doc_type?: string | null
          expense_id?: string | null
          file_name: string
          file_path: string
          file_size?: number | null
          id?: string
          inbound_batch_id?: string | null
          mime_type?: string | null
          notes?: string | null
          payment_id?: string | null
          sales_record_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          claim_id?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          doc_type?: string | null
          expense_id?: string | null
          file_name?: string
          file_path?: string
          file_size?: number | null
          id?: string
          inbound_batch_id?: string | null
          mime_type?: string | null
          notes?: string | null
          payment_id?: string | null
          sales_record_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "finance_attachments_claim_id_fkey"
            columns: ["claim_id"]
            isOneToOne: false
            referencedRelation: "expense_claim_status"
            referencedColumns: ["claim_id"]
          },
          {
            foreignKeyName: "finance_attachments_claim_id_fkey"
            columns: ["claim_id"]
            isOneToOne: false
            referencedRelation: "expense_claims"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_attachments_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_attachments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "finance_attachments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "finance_attachments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "finance_attachments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "finance_attachments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_attachments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_attachments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "finance_attachments_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_attachments_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_attachments_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_attachments_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_visible"
            referencedColumns: ["id"]
          },
        ]
      }
      finance_settings: {
        Row: {
          approval_level1_role_code: string | null
          approval_level2_role_code: string | null
          approval_threshold_base: number | null
          approvals_enabled: boolean
          default_allocation_basis: string
          first_fy_end: string | null
          fy_end_day: number
          fy_end_month: number
          gst_rate_pct: number
          gst_registered: boolean
          gst_registration_no: string | null
          id: boolean
          locked_before: string | null
          system_start_date: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          approval_level1_role_code?: string | null
          approval_level2_role_code?: string | null
          approval_threshold_base?: number | null
          approvals_enabled?: boolean
          default_allocation_basis?: string
          first_fy_end?: string | null
          fy_end_day?: number
          fy_end_month?: number
          gst_rate_pct?: number
          gst_registered?: boolean
          gst_registration_no?: string | null
          id?: boolean
          locked_before?: string | null
          system_start_date?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          approval_level1_role_code?: string | null
          approval_level2_role_code?: string | null
          approval_threshold_base?: number | null
          approvals_enabled?: boolean
          default_allocation_basis?: string
          first_fy_end?: string | null
          fy_end_day?: number
          fy_end_month?: number
          gst_rate_pct?: number
          gst_registered?: boolean
          gst_registration_no?: string | null
          id?: boolean
          locked_before?: string | null
          system_start_date?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "finance_settings_approval_level1_role_code_fkey"
            columns: ["approval_level1_role_code"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "finance_settings_approval_level2_role_code_fkey"
            columns: ["approval_level2_role_code"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["code"]
          },
        ]
      }
      fixed_asset_cost_entries: {
        Row: {
          amount_base: number
          amount_ccy: number
          asset_id: string
          created_at: string
          created_by: string | null
          currency: string
          expense_id: string
          fx_rate: number
          id: string
        }
        Insert: {
          amount_base: number
          amount_ccy: number
          asset_id: string
          created_at?: string
          created_by?: string | null
          currency: string
          expense_id: string
          fx_rate: number
          id?: string
        }
        Update: {
          amount_base?: number
          amount_ccy?: number
          asset_id?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          expense_id?: string
          fx_rate?: number
          id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fixed_asset_cost_entries_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "equipment_service_status"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "fixed_asset_cost_entries_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "equipment_usage"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "fixed_asset_cost_entries_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "fixed_assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fixed_asset_cost_entries_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_retention_status"
            referencedColumns: ["asset_id"]
          },
          {
            foreignKeyName: "fixed_asset_cost_entries_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "fixed_asset_cost_entries_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: true
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
        ]
      }
      fixed_asset_depreciation: {
        Row: {
          amount_base: number
          asset_id: string
          created_at: string
          created_by: string | null
          id: string
          journal_entry_id: string
          period_end: string
        }
        Insert: {
          amount_base: number
          asset_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          journal_entry_id: string
          period_end: string
        }
        Update: {
          amount_base?: number
          asset_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          journal_entry_id?: string
          period_end?: string
        }
        Relationships: [
          {
            foreignKeyName: "fixed_asset_depreciation_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "equipment_service_status"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "fixed_asset_depreciation_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "equipment_usage"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "fixed_asset_depreciation_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "fixed_assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fixed_asset_depreciation_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_retention_status"
            referencedColumns: ["asset_id"]
          },
          {
            foreignKeyName: "fixed_asset_depreciation_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "fixed_asset_depreciation_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      fixed_asset_depreciation_anchors: {
        Row: {
          asset_id: string
          created_at: string
          created_by: string | null
          effective_from: string
          expense_id: string | null
          id: string
          maintenance_id: string | null
          pre_anchor_target_base: number
          reason: string
          remaining_months: number
        }
        Insert: {
          asset_id: string
          created_at?: string
          created_by?: string | null
          effective_from: string
          expense_id?: string | null
          id?: string
          maintenance_id?: string | null
          pre_anchor_target_base: number
          reason: string
          remaining_months: number
        }
        Update: {
          asset_id?: string
          created_at?: string
          created_by?: string | null
          effective_from?: string
          expense_id?: string | null
          id?: string
          maintenance_id?: string | null
          pre_anchor_target_base?: number
          reason?: string
          remaining_months?: number
        }
        Relationships: [
          {
            foreignKeyName: "fixed_asset_depreciation_anchors_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "equipment_service_status"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "fixed_asset_depreciation_anchors_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "equipment_usage"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "fixed_asset_depreciation_anchors_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "fixed_assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fixed_asset_depreciation_anchors_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_retention_status"
            referencedColumns: ["asset_id"]
          },
          {
            foreignKeyName: "fixed_asset_depreciation_anchors_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fixed_asset_depreciation_anchors_maintenance_id_fkey"
            columns: ["maintenance_id"]
            isOneToOne: false
            referencedRelation: "equipment_maintenance"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fixed_asset_depreciation_anchors_maintenance_id_fkey"
            columns: ["maintenance_id"]
            isOneToOne: false
            referencedRelation: "equipment_maintenance_advice"
            referencedColumns: ["maintenance_id"]
          },
        ]
      }
      fixed_assets: {
        Row: {
          acceptance_date: string | null
          acquisition_date: string
          category: string
          code: string
          cost_base: number
          cost_ccy: number
          created_at: string
          created_by: string | null
          currency: string
          depreciation_account_code: string
          description: string
          disposal_date: string | null
          disposal_journal_id: string | null
          disposal_proceeds_base: number | null
          expense_id: string | null
          fx_rate: number
          id: string
          in_service_date: string | null
          notes: string | null
          planned_in_service_date: string | null
          residual_base: number
          status: string
          useful_life_months: number
        }
        Insert: {
          acceptance_date?: string | null
          acquisition_date: string
          category?: string
          code: string
          cost_base: number
          cost_ccy: number
          created_at?: string
          created_by?: string | null
          currency: string
          depreciation_account_code?: string
          description: string
          disposal_date?: string | null
          disposal_journal_id?: string | null
          disposal_proceeds_base?: number | null
          expense_id?: string | null
          fx_rate: number
          id?: string
          in_service_date?: string | null
          notes?: string | null
          planned_in_service_date?: string | null
          residual_base?: number
          status?: string
          useful_life_months: number
        }
        Update: {
          acceptance_date?: string | null
          acquisition_date?: string
          category?: string
          code?: string
          cost_base?: number
          cost_ccy?: number
          created_at?: string
          created_by?: string | null
          currency?: string
          depreciation_account_code?: string
          description?: string
          disposal_date?: string | null
          disposal_journal_id?: string | null
          disposal_proceeds_base?: number | null
          expense_id?: string | null
          fx_rate?: number
          id?: string
          in_service_date?: string | null
          notes?: string | null
          planned_in_service_date?: string | null
          residual_base?: number
          status?: string
          useful_life_months?: number
        }
        Relationships: [
          {
            foreignKeyName: "fixed_assets_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "fixed_assets_depreciation_account_code_fkey"
            columns: ["depreciation_account_code"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "fixed_assets_depreciation_account_code_fkey"
            columns: ["depreciation_account_code"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["account_code"]
          },
          {
            foreignKeyName: "fixed_assets_disposal_journal_id_fkey"
            columns: ["disposal_journal_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "fixed_assets_disposal_journal_id_fkey"
            columns: ["disposal_journal_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fixed_assets_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
        ]
      }
      forwarder_details: {
        Row: {
          created_at: string
          created_by: string | null
          dg_classes: string | null
          free_time_terms: string | null
          main_routes: string | null
          notes: string | null
          ports_served: string | null
          supplier_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          dg_classes?: string | null
          free_time_terms?: string | null
          main_routes?: string | null
          notes?: string | null
          ports_served?: string | null
          supplier_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          dg_classes?: string | null
          free_time_terms?: string | null
          main_routes?: string | null
          notes?: string | null
          ports_served?: string | null
          supplier_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "forwarder_details_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: true
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "forwarder_details_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: true
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      forwarder_rate_quotes: {
        Row: {
          amount_ccy: number
          created_at: string
          created_by: string | null
          currency: string
          deleted_at: string | null
          free_days: number | null
          id: string
          lane_id: string
          notes: string | null
          supplier_id: string
          valid_from: string
          valid_to: string
        }
        Insert: {
          amount_ccy: number
          created_at?: string
          created_by?: string | null
          currency: string
          deleted_at?: string | null
          free_days?: number | null
          id?: string
          lane_id: string
          notes?: string | null
          supplier_id: string
          valid_from: string
          valid_to: string
        }
        Update: {
          amount_ccy?: number
          created_at?: string
          created_by?: string | null
          currency?: string
          deleted_at?: string | null
          free_days?: number | null
          id?: string
          lane_id?: string
          notes?: string | null
          supplier_id?: string
          valid_from?: string
          valid_to?: string
        }
        Relationships: [
          {
            foreignKeyName: "forwarder_rate_quotes_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "forwarder_rate_quotes_lane_id_fkey"
            columns: ["lane_id"]
            isOneToOne: false
            referencedRelation: "lane_checklist_status"
            referencedColumns: ["lane_id"]
          },
          {
            foreignKeyName: "forwarder_rate_quotes_lane_id_fkey"
            columns: ["lane_id"]
            isOneToOne: false
            referencedRelation: "lanes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "forwarder_rate_quotes_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "forwarder_rate_quotes_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      freight_allocations: {
        Row: {
          amount_base: number
          basis_qty: number | null
          created_at: string
          created_by: string | null
          freight_document_id: string
          id: string
          in_stock_ratio: number
          inbound_batch_id: string
        }
        Insert: {
          amount_base: number
          basis_qty?: number | null
          created_at?: string
          created_by?: string | null
          freight_document_id: string
          id?: string
          in_stock_ratio: number
          inbound_batch_id: string
        }
        Update: {
          amount_base?: number
          basis_qty?: number | null
          created_at?: string
          created_by?: string | null
          freight_document_id?: string
          id?: string
          in_stock_ratio?: number
          inbound_batch_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "freight_allocations_freight_document_id_fkey"
            columns: ["freight_document_id"]
            isOneToOne: false
            referencedRelation: "freight_documents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "freight_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "freight_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "freight_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "freight_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "freight_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "freight_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "freight_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
        ]
      }
      freight_documents: {
        Row: {
          allocation_basis: string
          amount_base: number
          amount_ccy: number
          bank_account_code: string | null
          code: string
          container_id: string | null
          created_at: string
          created_by: string | null
          currency: string
          deleted_at: string | null
          direction: string
          doc_date: string
          fx_rate: number
          id: string
          journal_entry_id: string | null
          notes: string | null
          payment_status: string
          reversal_entry_id: string | null
          reversal_reason: string | null
          reversed_at: string | null
          reversed_by: string | null
          status: string
          supplier_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          allocation_basis: string
          amount_base: number
          amount_ccy: number
          bank_account_code?: string | null
          code: string
          container_id?: string | null
          created_at?: string
          created_by?: string | null
          currency: string
          deleted_at?: string | null
          direction: string
          doc_date: string
          fx_rate: number
          id?: string
          journal_entry_id?: string | null
          notes?: string | null
          payment_status: string
          reversal_entry_id?: string | null
          reversal_reason?: string | null
          reversed_at?: string | null
          reversed_by?: string | null
          status?: string
          supplier_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          allocation_basis?: string
          amount_base?: number
          amount_ccy?: number
          bank_account_code?: string | null
          code?: string
          container_id?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          deleted_at?: string | null
          direction?: string
          doc_date?: string
          fx_rate?: number
          id?: string
          journal_entry_id?: string | null
          notes?: string | null
          payment_status?: string
          reversal_entry_id?: string | null
          reversal_reason?: string | null
          reversed_at?: string | null
          reversed_by?: string | null
          status?: string
          supplier_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "freight_documents_container_id_fkey"
            columns: ["container_id"]
            isOneToOne: false
            referencedRelation: "container_overview"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "freight_documents_container_id_fkey"
            columns: ["container_id"]
            isOneToOne: false
            referencedRelation: "containers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "freight_documents_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "freight_documents_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "freight_documents_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "freight_documents_reversal_entry_id_fkey"
            columns: ["reversal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "freight_documents_reversal_entry_id_fkey"
            columns: ["reversal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "freight_documents_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "freight_documents_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      fx_rate_history: {
        Row: {
          action: string
          changed_at: string
          changed_by: string | null
          currency: string
          fx_rate_id: string
          id: string
          notes: string | null
          prev_rate: number | null
          rate_date: string
          rate_sgd_per_unit: number
          rate_type: string
          reason: string | null
          source: string | null
        }
        Insert: {
          action: string
          changed_at?: string
          changed_by?: string | null
          currency: string
          fx_rate_id: string
          id?: string
          notes?: string | null
          prev_rate?: number | null
          rate_date: string
          rate_sgd_per_unit: number
          rate_type: string
          reason?: string | null
          source?: string | null
        }
        Update: {
          action?: string
          changed_at?: string
          changed_by?: string | null
          currency?: string
          fx_rate_id?: string
          id?: string
          notes?: string | null
          prev_rate?: number | null
          rate_date?: string
          rate_sgd_per_unit?: number
          rate_type?: string
          reason?: string | null
          source?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fx_rate_history_fx_rate_id_fkey"
            columns: ["fx_rate_id"]
            isOneToOne: false
            referencedRelation: "fx_rates"
            referencedColumns: ["id"]
          },
        ]
      }
      fx_rates: {
        Row: {
          created_at: string
          created_by: string | null
          currency: string
          deleted_at: string | null
          id: string
          notes: string | null
          rate_date: string
          rate_sgd_per_unit: number
          rate_type: string
          source: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          currency: string
          deleted_at?: string | null
          id?: string
          notes?: string | null
          rate_date: string
          rate_sgd_per_unit: number
          rate_type: string
          source?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          currency?: string
          deleted_at?: string | null
          id?: string
          notes?: string | null
          rate_date?: string
          rate_sgd_per_unit?: number
          rate_type?: string
          source?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fx_rates_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      gst_periods: {
        Row: {
          code: string
          corrects_period_id: string | null
          created_at: string
          created_by: string | null
          filed_at: string | null
          filed_by: string | null
          filed_on: string | null
          filed_reference: string | null
          id: string
          notes: string | null
          period_end: string
          period_start: string
          status: string
        }
        Insert: {
          code: string
          corrects_period_id?: string | null
          created_at?: string
          created_by?: string | null
          filed_at?: string | null
          filed_by?: string | null
          filed_on?: string | null
          filed_reference?: string | null
          id?: string
          notes?: string | null
          period_end: string
          period_start: string
          status?: string
        }
        Update: {
          code?: string
          corrects_period_id?: string | null
          created_at?: string
          created_by?: string | null
          filed_at?: string | null
          filed_by?: string | null
          filed_on?: string | null
          filed_reference?: string | null
          id?: string
          notes?: string | null
          period_end?: string
          period_start?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "gst_periods_corrects_period_id_fkey"
            columns: ["corrects_period_id"]
            isOneToOne: false
            referencedRelation: "gst_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      gst_return_boxes: {
        Row: {
          box: string
          created_at: string
          id: string
          label_en: string
          label_zh: string
          period_id: string
          value_base: number
        }
        Insert: {
          box: string
          created_at?: string
          id?: string
          label_en: string
          label_zh: string
          period_id: string
          value_base: number
        }
        Update: {
          box?: string
          created_at?: string
          id?: string
          label_en?: string
          label_zh?: string
          period_id?: string
          value_base?: number
        }
        Relationships: [
          {
            foreignKeyName: "gst_return_boxes_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "gst_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      handover_item_types: {
        Row: {
          code: string
          is_active: boolean
          is_required: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
        }
        Insert: {
          code: string
          is_active?: boolean
          is_required?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          is_active?: boolean
          is_required?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
        }
        Relationships: []
      }
      hr_settings: {
        Row: {
          carry_forward_months: number
          id: boolean
          medical_annual_limit_sgd: number
          medical_pro_rate_for_joiners: boolean
          personal_data_retention_months: number | null
          updated_at: string
          updated_by: string | null
          working_days_per_week: number
        }
        Insert: {
          carry_forward_months?: number
          id?: boolean
          medical_annual_limit_sgd?: number
          medical_pro_rate_for_joiners?: boolean
          personal_data_retention_months?: number | null
          updated_at?: string
          updated_by?: string | null
          working_days_per_week?: number
        }
        Update: {
          carry_forward_months?: number
          id?: boolean
          medical_annual_limit_sgd?: number
          medical_pro_rate_for_joiners?: boolean
          personal_data_retention_months?: number | null
          updated_at?: string
          updated_by?: string | null
          working_days_per_week?: number
        }
        Relationships: []
      }
      import_batches: {
        Row: {
          code_first: string
          code_last: string
          file_name: string
          id: string
          imported_at: string
          imported_by: string | null
          row_count: number
          target_table: string
        }
        Insert: {
          code_first: string
          code_last: string
          file_name: string
          id?: string
          imported_at?: string
          imported_by?: string | null
          row_count: number
          target_table: string
        }
        Update: {
          code_first?: string
          code_last?: string
          file_name?: string
          id?: string
          imported_at?: string
          imported_by?: string | null
          row_count?: number
          target_table?: string
        }
        Relationships: []
      }
      inbound_batch_metals: {
        Row: {
          content_pct: number
          content_source: string | null
          created_at: string
          created_by: string | null
          inbound_batch_id: string
          metal: string
          source_assay_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          content_pct: number
          content_source?: string | null
          created_at?: string
          created_by?: string | null
          inbound_batch_id: string
          metal: string
          source_assay_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          content_pct?: number
          content_source?: string | null
          created_at?: string
          created_by?: string | null
          inbound_batch_id?: string
          metal?: string
          source_assay_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inbound_batch_metals_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inbound_batch_metals_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inbound_batch_metals_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inbound_batch_metals_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "inbound_batch_metals_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batch_metals_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batch_metals_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inbound_batch_metals_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "inbound_batch_metals_source_assay_id_fkey"
            columns: ["source_assay_id"]
            isOneToOne: false
            referencedRelation: "assay_results"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batch_metals_source_assay_id_fkey"
            columns: ["source_assay_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["assay_result_id"]
          },
        ]
      }
      inbound_batch_safety_states: {
        Row: {
          created_at: string
          created_by: string | null
          inbound_batch_id: string
          safety_state_code: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          inbound_batch_id: string
          safety_state_code: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          inbound_batch_id?: string
          safety_state_code?: string
        }
        Relationships: [
          {
            foreignKeyName: "inbound_batch_safety_states_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inbound_batch_safety_states_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inbound_batch_safety_states_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inbound_batch_safety_states_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "inbound_batch_safety_states_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batch_safety_states_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batch_safety_states_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inbound_batch_safety_states_safety_state_code_fkey"
            columns: ["safety_state_code"]
            isOneToOne: false
            referencedRelation: "inbound_safety_states"
            referencedColumns: ["code"]
          },
        ]
      }
      inbound_batches: {
        Row: {
          arrival_date: string | null
          chemistry_certainty_code: string | null
          code: string
          created_at: string
          created_by: string | null
          declared_qty: number | null
          deep_discharge_actual_code: string | null
          delete_reason: string | null
          deleted_at: string | null
          deleted_by: string | null
          id: string
          import_permit_ref: string | null
          import_permit_verified_at: string | null
          import_permit_verified_by: string | null
          imported: boolean | null
          material_id: string
          notes: string | null
          pricing_formula_id: string | null
          pricing_status: string
          purchase_order_id: string | null
          purchase_order_line_id: string | null
          quantity: number
          remaining_qty: number
          source_reason_code: string | null
          source_reason_note: string | null
          source_reason_recorded_at: string | null
          source_reason_recorded_by: string | null
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
          chemistry_certainty_code?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          declared_qty?: number | null
          deep_discharge_actual_code?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          id?: string
          import_permit_ref?: string | null
          import_permit_verified_at?: string | null
          import_permit_verified_by?: string | null
          imported?: boolean | null
          material_id: string
          notes?: string | null
          pricing_formula_id?: string | null
          pricing_status?: string
          purchase_order_id?: string | null
          purchase_order_line_id?: string | null
          quantity: number
          remaining_qty: number
          source_reason_code?: string | null
          source_reason_note?: string | null
          source_reason_recorded_at?: string | null
          source_reason_recorded_by?: string | null
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
          chemistry_certainty_code?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          declared_qty?: number | null
          deep_discharge_actual_code?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          id?: string
          import_permit_ref?: string | null
          import_permit_verified_at?: string | null
          import_permit_verified_by?: string | null
          imported?: boolean | null
          material_id?: string
          notes?: string | null
          pricing_formula_id?: string | null
          pricing_status?: string
          purchase_order_id?: string | null
          purchase_order_line_id?: string | null
          quantity?: number
          remaining_qty?: number
          source_reason_code?: string | null
          source_reason_note?: string | null
          source_reason_recorded_at?: string | null
          source_reason_recorded_by?: string | null
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
            foreignKeyName: "inbound_batches_chemistry_certainty_code_fkey"
            columns: ["chemistry_certainty_code"]
            isOneToOne: false
            referencedRelation: "inbound_chemistry_certainties"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "inbound_batches_deep_discharge_actual_code_fkey"
            columns: ["deep_discharge_actual_code"]
            isOneToOne: false
            referencedRelation: "deep_discharge_judgements"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "inbound_batches_import_permit_verified_by_fkey"
            columns: ["import_permit_verified_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "inbound_batches_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_lines_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_source_reason_code_fkey"
            columns: ["source_reason_code"]
            isOneToOne: false
            referencedRelation: "inbound_source_reasons"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "inbound_batches_source_reason_recorded_by_fkey"
            columns: ["source_reason_recorded_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "inbound_batches_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
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
      inbound_chemistry_certainties: {
        Row: {
          code: string
          is_active: boolean
          may_be_fed: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
        }
        Insert: {
          code: string
          is_active?: boolean
          may_be_fed: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          is_active?: boolean
          may_be_fed?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
        }
        Relationships: []
      }
      inbound_safety_states: {
        Row: {
          code: string
          is_active: boolean
          may_be_fed: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
        }
        Insert: {
          code: string
          is_active?: boolean
          may_be_fed: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          is_active?: boolean
          may_be_fed?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
        }
        Relationships: []
      }
      inbound_source_reasons: {
        Row: {
          code: string
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          requires_explanation: boolean
          sort_order: number
        }
        Insert: {
          code: string
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          requires_explanation: boolean
          sort_order?: number
        }
        Update: {
          code?: string
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          requires_explanation?: boolean
          sort_order?: number
        }
        Relationships: []
      }
      index_market_calendar: {
        Row: {
          calendar_date: string
          created_at: string
          created_by: string | null
          index_code: string
          is_trading_day: boolean
          note: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          calendar_date: string
          created_at?: string
          created_by?: string | null
          index_code: string
          is_trading_day: boolean
          note?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          calendar_date?: string
          created_at?: string
          created_by?: string | null
          index_code?: string
          is_trading_day?: boolean
          note?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "index_market_calendar_index_code_fkey"
            columns: ["index_code"]
            isOneToOne: false
            referencedRelation: "metal_price_indices"
            referencedColumns: ["code"]
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
          pair_id: string | null
          qty_delta: number
          run_id: string | null
          stock_status: string
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
          pair_id?: string | null
          qty_delta: number
          run_id?: string | null
          stock_status?: string
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
          pair_id?: string | null
          qty_delta?: number
          run_id?: string | null
          stock_status?: string
        }
        Relationships: [
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
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
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
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
            foreignKeyName: "inventory_movements_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
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
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "inventory_movements_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "inventory_movements_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_loss_breakdown"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "inventory_movements_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      invoice_issues: {
        Row: {
          file_path: string
          id: string
          invoice_id: string
          issued_at: string
          issued_by: string | null
          sha256: string
          version: number
        }
        Insert: {
          file_path: string
          id?: string
          invoice_id: string
          issued_at?: string
          issued_by?: string | null
          sha256: string
          version: number
        }
        Update: {
          file_path?: string
          id?: string
          invoice_id?: string
          issued_at?: string
          issued_by?: string | null
          sha256?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "invoice_issues_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_document_totals"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_issues_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_status"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_issues_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_issues_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_issues_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_balance_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_issues_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_open_all"
            referencedColumns: ["invoice_id"]
          },
        ]
      }
      invoice_lines: {
        Row: {
          amount_base: number
          amount_ccy: number | null
          created_at: string | null
          description: string
          id: string
          invoice_id: string
          invoice_voided: boolean
          line_no: number
          quantity: number
          sales_order_line_id: string | null
          sales_record_id: string | null
          tax_base: number
          tax_code: string | null
          tax_rate_pct: number | null
          unit: string
          unit_price: number
        }
        Insert: {
          amount_base: number
          amount_ccy?: number | null
          created_at?: string | null
          description: string
          id?: string
          invoice_id: string
          invoice_voided?: boolean
          line_no: number
          quantity: number
          sales_order_line_id?: string | null
          sales_record_id?: string | null
          tax_base?: number
          tax_code?: string | null
          tax_rate_pct?: number | null
          unit: string
          unit_price: number
        }
        Update: {
          amount_base?: number
          amount_ccy?: number | null
          created_at?: string | null
          description?: string
          id?: string
          invoice_id?: string
          invoice_voided?: boolean
          line_no?: number
          quantity?: number
          sales_order_line_id?: string | null
          sales_record_id?: string | null
          tax_base?: number
          tax_code?: string | null
          tax_rate_pct?: number | null
          unit?: string
          unit_price?: number
        }
        Relationships: [
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_document_totals"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_status"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_balance_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_open_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_order_line_id_fkey"
            columns: ["sales_order_line_id"]
            isOneToOne: false
            referencedRelation: "sales_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_visible"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_tax_code_fkey"
            columns: ["tax_code"]
            isOneToOne: false
            referencedRelation: "tax_codes"
            referencedColumns: ["code"]
          },
        ]
      }
      invoices: {
        Row: {
          bill_to_snapshot: Json
          code: string
          created_at: string | null
          created_by: string | null
          currency: string
          customer_id: string
          due_date: string
          entry_id: string | null
          fx_rate: number | null
          id: string
          issue_date: string
          kind: string
          notes: string | null
          payment_terms_days: number
          sales_order_id: string | null
          status: string
          subtotal_base: number
          tax_base: number
          tax_rate_pct: number
          terms_text: string | null
          total_base: number
          void_reason: string | null
          voided_at: string | null
          voided_by: string | null
        }
        Insert: {
          bill_to_snapshot: Json
          code: string
          created_at?: string | null
          created_by?: string | null
          currency: string
          customer_id: string
          due_date: string
          entry_id?: string | null
          fx_rate?: number | null
          id?: string
          issue_date: string
          kind?: string
          notes?: string | null
          payment_terms_days: number
          sales_order_id?: string | null
          status?: string
          subtotal_base: number
          tax_base?: number
          tax_rate_pct?: number
          terms_text?: string | null
          total_base: number
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Update: {
          bill_to_snapshot?: Json
          code?: string
          created_at?: string | null
          created_by?: string | null
          currency?: string
          customer_id?: string
          due_date?: string
          entry_id?: string | null
          fx_rate?: number | null
          id?: string
          issue_date?: string
          kind?: string
          notes?: string | null
          payment_terms_days?: number
          sales_order_id?: string | null
          status?: string
          subtotal_base?: number
          tax_base?: number
          tax_rate_pct?: number
          terms_text?: string | null
          total_base?: number
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "invoices_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_sales_order_id_fkey"
            columns: ["sales_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      journal_entries: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          entry_date: string
          id: string
          memo: string | null
          reversed_by: string | null
          source_id: string | null
          source_type: string | null
          status: string
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          entry_date: string
          id?: string
          memo?: string | null
          reversed_by?: string | null
          source_id?: string | null
          source_type?: string | null
          status?: string
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          entry_date?: string
          id?: string
          memo?: string | null
          reversed_by?: string | null
          source_id?: string | null
          source_type?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "journal_entries_reversed_by_fkey"
            columns: ["reversed_by"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "journal_entries_reversed_by_fkey"
            columns: ["reversed_by"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      journal_lines: {
        Row: {
          account_id: string
          amount_ccy: number
          created_at: string
          credit: number
          currency: string
          debit: number
          entry_id: string
          fx_rate: number
          fx_rate_date: string | null
          id: string
          line_memo: string | null
          tax_code: string | null
        }
        Insert: {
          account_id: string
          amount_ccy: number
          created_at?: string
          credit?: number
          currency: string
          debit?: number
          entry_id: string
          fx_rate: number
          fx_rate_date?: string | null
          id?: string
          line_memo?: string | null
          tax_code?: string | null
        }
        Update: {
          account_id?: string
          amount_ccy?: number
          created_at?: string
          credit?: number
          currency?: string
          debit?: number
          entry_id?: string
          fx_rate?: number
          fx_rate_date?: string | null
          id?: string
          line_memo?: string | null
          tax_code?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "journal_lines_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "journal_lines_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "journal_lines_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "journal_lines_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "journal_lines_tax_code_fkey"
            columns: ["tax_code"]
            isOneToOne: false
            referencedRelation: "tax_codes"
            referencedColumns: ["code"]
          },
        ]
      }
      kpi_cycles: {
        Row: {
          created_at: string
          created_by: string | null
          deleted_at: string | null
          due_date: string
          gate: string | null
          id: string
          name: string
          notes: string | null
          period_end: string
          period_start: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          due_date: string
          gate?: string | null
          id?: string
          name: string
          notes?: string | null
          period_end: string
          period_start: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          due_date?: string
          gate?: string | null
          id?: string
          name?: string
          notes?: string | null
          period_end?: string
          period_start?: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      kpi_entries: {
        Row: {
          computed_basis: string | null
          created_at: string
          created_by: string | null
          cycle_id: string
          employee_id: string
          evidence_note: string | null
          evidence_source: string | null
          id: string
          is_provisional: boolean
          kpi_ref: string
          org_codes: string[]
          override_cap: number | null
          override_reason: string | null
          provisional_note: string | null
          score: number | null
          score_kind: string | null
          scored_at: string | null
          scored_by: string | null
          source_position_id: string
          source_template_id: string
          source_template_version: number
          target_text: string
          title: string
          updated_at: string
          updated_by: string | null
          weight_pct: number
        }
        Insert: {
          computed_basis?: string | null
          created_at?: string
          created_by?: string | null
          cycle_id: string
          employee_id: string
          evidence_note?: string | null
          evidence_source?: string | null
          id?: string
          is_provisional?: boolean
          kpi_ref: string
          org_codes: string[]
          override_cap?: number | null
          override_reason?: string | null
          provisional_note?: string | null
          score?: number | null
          score_kind?: string | null
          scored_at?: string | null
          scored_by?: string | null
          source_position_id: string
          source_template_id: string
          source_template_version: number
          target_text: string
          title: string
          updated_at?: string
          updated_by?: string | null
          weight_pct: number
        }
        Update: {
          computed_basis?: string | null
          created_at?: string
          created_by?: string | null
          cycle_id?: string
          employee_id?: string
          evidence_note?: string | null
          evidence_source?: string | null
          id?: string
          is_provisional?: boolean
          kpi_ref?: string
          org_codes?: string[]
          override_cap?: number | null
          override_reason?: string | null
          provisional_note?: string | null
          score?: number | null
          score_kind?: string | null
          scored_at?: string | null
          scored_by?: string | null
          source_position_id?: string
          source_template_id?: string
          source_template_version?: number
          target_text?: string
          title?: string
          updated_at?: string
          updated_by?: string | null
          weight_pct?: number
        }
        Relationships: [
          {
            foreignKeyName: "kpi_entries_cycle_id_fkey"
            columns: ["cycle_id"]
            isOneToOne: false
            referencedRelation: "kpi_cycles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "kpi_entries_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "kpi_entries_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "kpi_entries_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "kpi_entries_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "kpi_entries_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "kpi_entries_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "kpi_entries_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "kpi_entries_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "kpi_entries_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "kpi_entries_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "kpi_entries_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "kpi_entries_source_position_id_fkey"
            columns: ["source_position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "kpi_entries_source_template_id_fkey"
            columns: ["source_template_id"]
            isOneToOne: false
            referencedRelation: "kpi_position_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      kpi_organisation: {
        Row: {
          code: string
          created_at: string
          criticality_note: string
          definition: string
          id: string
          is_provisional: boolean
          measurement_evidence: string
          month3_target: string
          month6_target: string
          provisional_note: string | null
          sort_order: number
          title: string
          updated_at: string
          weight_pct: number
        }
        Insert: {
          code: string
          created_at?: string
          criticality_note: string
          definition: string
          id?: string
          is_provisional?: boolean
          measurement_evidence: string
          month3_target: string
          month6_target: string
          provisional_note?: string | null
          sort_order?: number
          title: string
          updated_at?: string
          weight_pct: number
        }
        Update: {
          code?: string
          created_at?: string
          criticality_note?: string
          definition?: string
          id?: string
          is_provisional?: boolean
          measurement_evidence?: string
          month3_target?: string
          month6_target?: string
          provisional_note?: string | null
          sort_order?: number
          title?: string
          updated_at?: string
          weight_pct?: number
        }
        Relationships: []
      }
      kpi_position_templates: {
        Row: {
          created_at: string
          evidence_source: string | null
          id: string
          is_provisional: boolean
          kpi_ref: string
          position_id: string
          provisional_note: string | null
          sort_order: number
          target_text: string
          title: string
          updated_at: string
          version: number
          weight_pct: number
        }
        Insert: {
          created_at?: string
          evidence_source?: string | null
          id?: string
          is_provisional?: boolean
          kpi_ref: string
          position_id: string
          provisional_note?: string | null
          sort_order?: number
          target_text: string
          title: string
          updated_at?: string
          version?: number
          weight_pct: number
        }
        Update: {
          created_at?: string
          evidence_source?: string | null
          id?: string
          is_provisional?: boolean
          kpi_ref?: string
          position_id?: string
          provisional_note?: string | null
          sort_order?: number
          target_text?: string
          title?: string
          updated_at?: string
          version?: number
          weight_pct?: number
        }
        Relationships: [
          {
            foreignKeyName: "kpi_position_templates_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
        ]
      }
      kpi_template_org_links: {
        Row: {
          org_code: string
          template_id: string
        }
        Insert: {
          org_code: string
          template_id: string
        }
        Update: {
          org_code?: string
          template_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "kpi_template_org_links_org_code_fkey"
            columns: ["org_code"]
            isOneToOne: false
            referencedRelation: "kpi_organisation"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "kpi_template_org_links_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "kpi_position_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      laboratories: {
        Row: {
          code: string
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
        }
        Insert: {
          code: string
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
        }
        Relationships: []
      }
      lane_document_requirements: {
        Row: {
          created_at: string
          created_by: string | null
          deleted_at: string | null
          document_type: string
          id: string
          lane_id: string
          notes: string | null
          regime: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          document_type: string
          id?: string
          lane_id: string
          notes?: string | null
          regime?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          document_type?: string
          id?: string
          lane_id?: string
          notes?: string | null
          regime?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "lane_document_requirements_lane_id_fkey"
            columns: ["lane_id"]
            isOneToOne: false
            referencedRelation: "lane_checklist_status"
            referencedColumns: ["lane_id"]
          },
          {
            foreignKeyName: "lane_document_requirements_lane_id_fkey"
            columns: ["lane_id"]
            isOneToOne: false
            referencedRelation: "lanes"
            referencedColumns: ["id"]
          },
        ]
      }
      lanes: {
        Row: {
          checklist_reviewed_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          destination_port_id: string
          id: string
          origin_port_id: string
        }
        Insert: {
          checklist_reviewed_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          destination_port_id: string
          id?: string
          origin_port_id: string
        }
        Update: {
          checklist_reviewed_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          destination_port_id?: string
          id?: string
          origin_port_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "lanes_destination_port_id_fkey"
            columns: ["destination_port_id"]
            isOneToOne: false
            referencedRelation: "ports"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lanes_origin_port_id_fkey"
            columns: ["origin_port_id"]
            isOneToOne: false
            referencedRelation: "ports"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_accrual_rates: {
        Row: {
          created_at: string
          created_by: string | null
          days_per_year: number | null
          effective_from: string
          employee_id: string | null
          id: string
          notes: string | null
          reason: string | null
          updated_at: string
          updated_by: string | null
          work_category: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          days_per_year?: number | null
          effective_from: string
          employee_id?: string | null
          id?: string
          notes?: string | null
          reason?: string | null
          updated_at?: string
          updated_by?: string | null
          work_category?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          days_per_year?: number | null
          effective_from?: string
          employee_id?: string | null
          id?: string
          notes?: string | null
          reason?: string | null
          updated_at?: string
          updated_by?: string | null
          work_category?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      leave_consumption: {
        Row: {
          accrual_year: number | null
          created_at: string
          created_by: string | null
          days: number
          entry_type: string
          id: string
          leave_grant_id: string | null
          leave_request_id: string
          notes: string | null
        }
        Insert: {
          accrual_year?: number | null
          created_at?: string
          created_by?: string | null
          days: number
          entry_type?: string
          id?: string
          leave_grant_id?: string | null
          leave_request_id: string
          notes?: string | null
        }
        Update: {
          accrual_year?: number | null
          created_at?: string
          created_by?: string | null
          days?: number
          entry_type?: string
          id?: string
          leave_grant_id?: string | null
          leave_request_id?: string
          notes?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "leave_consumption_leave_grant_id_fkey"
            columns: ["leave_grant_id"]
            isOneToOne: false
            referencedRelation: "leave_grants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_consumption_leave_request_id_fkey"
            columns: ["leave_request_id"]
            isOneToOne: false
            referencedRelation: "leave_calendar"
            referencedColumns: ["request_id"]
          },
          {
            foreignKeyName: "leave_consumption_leave_request_id_fkey"
            columns: ["leave_request_id"]
            isOneToOne: false
            referencedRelation: "leave_requests"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_grants: {
        Row: {
          created_at: string
          created_by: string | null
          days: number
          deleted_at: string | null
          employee_id: string
          expires_on: string | null
          grant_type: string
          granted_on: string
          id: string
          leave_type_code: string
          leave_year: number
          notes: string | null
          source_grant_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          days: number
          deleted_at?: string | null
          employee_id: string
          expires_on?: string | null
          grant_type: string
          granted_on: string
          id?: string
          leave_type_code: string
          leave_year: number
          notes?: string | null
          source_grant_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          days?: number
          deleted_at?: string | null
          employee_id?: string
          expires_on?: string | null
          grant_type?: string
          granted_on?: string
          id?: string
          leave_type_code?: string
          leave_year?: number
          notes?: string | null
          source_grant_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_grants_leave_type_code_fkey"
            columns: ["leave_type_code"]
            isOneToOne: false
            referencedRelation: "leave_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "leave_grants_leave_type_code_fkey"
            columns: ["leave_type_code"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["leave_type_code"]
          },
          {
            foreignKeyName: "leave_grants_source_grant_id_fkey"
            columns: ["source_grant_id"]
            isOneToOne: false
            referencedRelation: "leave_grants"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_requests: {
        Row: {
          certificate_ref: string | null
          code: string
          created_at: string
          created_by: string | null
          days: number
          decided_at: string | null
          decided_by: string | null
          decision_notes: string | null
          deleted_at: string | null
          employee_id: string
          end_date: string
          end_half_day: boolean
          exception_reason: string | null
          id: string
          is_exception: boolean
          leave_type_code: string
          reason: string | null
          start_date: string
          start_half_day: boolean
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          certificate_ref?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          days: number
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          deleted_at?: string | null
          employee_id: string
          end_date: string
          end_half_day?: boolean
          exception_reason?: string | null
          id?: string
          is_exception?: boolean
          leave_type_code: string
          reason?: string | null
          start_date: string
          start_half_day?: boolean
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          certificate_ref?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          days?: number
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          deleted_at?: string | null
          employee_id?: string
          end_date?: string
          end_half_day?: boolean
          exception_reason?: string | null
          id?: string
          is_exception?: boolean
          leave_type_code?: string
          reason?: string | null
          start_date?: string
          start_half_day?: boolean
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_leave_type_code_fkey"
            columns: ["leave_type_code"]
            isOneToOne: false
            referencedRelation: "leave_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "leave_requests_leave_type_code_fkey"
            columns: ["leave_type_code"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["leave_type_code"]
          },
        ]
      }
      leave_types: {
        Row: {
          allows_half_day: boolean
          code: string
          created_at: string
          created_by: string | null
          default_days_per_year: number | null
          description_en: string | null
          description_zh: string | null
          gender_restriction: string | null
          is_accrued: boolean
          is_active: boolean
          is_paid: boolean
          name_en: string
          name_zh: string
          notes: string | null
          requires_approval: boolean
          requires_certificate_after_days: number | null
          sort_order: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          allows_half_day?: boolean
          code: string
          created_at?: string
          created_by?: string | null
          default_days_per_year?: number | null
          description_en?: string | null
          description_zh?: string | null
          gender_restriction?: string | null
          is_accrued?: boolean
          is_active?: boolean
          is_paid?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          requires_approval?: boolean
          requires_certificate_after_days?: number | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          allows_half_day?: boolean
          code?: string
          created_at?: string
          created_by?: string | null
          default_days_per_year?: number | null
          description_en?: string | null
          description_zh?: string | null
          gender_restriction?: string | null
          is_accrued?: boolean
          is_active?: boolean
          is_paid?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          requires_approval?: boolean
          requires_certificate_after_days?: number | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      loss_categories: {
        Row: {
          code: string
          is_active: boolean
          is_true_loss: boolean
          metal_fate: string
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
        }
        Insert: {
          code: string
          is_active?: boolean
          is_true_loss: boolean
          metal_fate: string
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          is_active?: boolean
          is_true_loss?: boolean
          metal_fate?: string
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
        }
        Relationships: [
          {
            foreignKeyName: "loss_categories_metal_fate_fkey"
            columns: ["metal_fate"]
            isOneToOne: false
            referencedRelation: "loss_metal_fates"
            referencedColumns: ["code"]
          },
        ]
      }
      loss_metal_fates: {
        Row: {
          code: string
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
        }
        Insert: {
          code: string
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
        }
        Relationships: []
      }
      maintenance_settings: {
        Row: {
          capitalise_floor_base: number
          capitalise_pct_of_cost: number
          id: boolean
          notes: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          capitalise_floor_base?: number
          capitalise_pct_of_cost?: number
          id?: boolean
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          capitalise_floor_base?: number
          capitalise_pct_of_cost?: number
          id?: boolean
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      management_packs: {
        Row: {
          base_currency: string
          code: string
          id: string
          locked_before_at_production: string
          notes: string | null
          payload: Json
          period_end: string
          period_month: string
          period_start: string
          produced_at: string
          produced_by: string | null
          superseded_at: string | null
          superseded_by: string | null
          superseded_reason: string | null
        }
        Insert: {
          base_currency: string
          code: string
          id?: string
          locked_before_at_production: string
          notes?: string | null
          payload: Json
          period_end: string
          period_month: string
          period_start: string
          produced_at?: string
          produced_by?: string | null
          superseded_at?: string | null
          superseded_by?: string | null
          superseded_reason?: string | null
        }
        Update: {
          base_currency?: string
          code?: string
          id?: string
          locked_before_at_production?: string
          notes?: string | null
          payload?: Json
          period_end?: string
          period_month?: string
          period_start?: string
          produced_at?: string
          produced_by?: string | null
          superseded_at?: string | null
          superseded_by?: string | null
          superseded_reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "management_packs_base_currency_fkey"
            columns: ["base_currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "management_packs_superseded_by_fkey"
            columns: ["superseded_by"]
            isOneToOne: false
            referencedRelation: "management_packs"
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
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "material_attachments_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_attachments_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
        ]
      }
      material_forms: {
        Row: {
          code: string
          implies_dismantling: boolean
          is_active: boolean
          may_be_sold: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
        }
        Insert: {
          code: string
          implies_dismantling: boolean
          is_active?: boolean
          may_be_sold: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          implies_dismantling?: boolean
          is_active?: boolean
          may_be_sold?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
        }
        Relationships: []
      }
      material_kinds: {
        Row: {
          code: string
          has_condition_axes: boolean
          is_active: boolean
          may_ever_be_processed: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
        }
        Insert: {
          code: string
          has_condition_axes?: boolean
          is_active?: boolean
          may_ever_be_processed: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          has_condition_axes?: boolean
          is_active?: boolean
          may_ever_be_processed?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
        }
        Relationships: []
      }
      material_required_metals: {
        Row: {
          created_at: string
          created_by: string | null
          material_id: string
          metal: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          material_id: string
          metal: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          material_id?: string
          metal?: string
        }
        Relationships: [
          {
            foreignKeyName: "material_required_metals_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "material_required_metals_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_required_metals_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "material_required_metals_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
        ]
      }
      material_size_formats: {
        Row: {
          code: string
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
        }
        Insert: {
          code: string
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
        }
        Relationships: []
      }
      material_sources: {
        Row: {
          code: string
          implies_never_charged: boolean
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
        }
        Insert: {
          code: string
          implies_never_charged: boolean
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          implies_never_charged?: boolean
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
        }
        Relationships: []
      }
      materials: {
        Row: {
          chemistry: string | null
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          form_code: string | null
          id: string
          kind_code: string | null
          may_be_processed: boolean | null
          name: string
          notes: string | null
          safety_stock_qty: number | null
          size_format_code: string | null
          source_code: string | null
          spec: string | null
          status: string
          unit: string
          updated_at: string
          updated_by: string | null
          waste_classification_code: string | null
        }
        Insert: {
          chemistry?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          form_code?: string | null
          id?: string
          kind_code?: string | null
          may_be_processed?: boolean | null
          name: string
          notes?: string | null
          safety_stock_qty?: number | null
          size_format_code?: string | null
          source_code?: string | null
          spec?: string | null
          status?: string
          unit?: string
          updated_at?: string
          updated_by?: string | null
          waste_classification_code?: string | null
        }
        Update: {
          chemistry?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          form_code?: string | null
          id?: string
          kind_code?: string | null
          may_be_processed?: boolean | null
          name?: string
          notes?: string | null
          safety_stock_qty?: number | null
          size_format_code?: string | null
          source_code?: string | null
          spec?: string | null
          status?: string
          unit?: string
          updated_at?: string
          updated_by?: string | null
          waste_classification_code?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "materials_chemistry_fkey"
            columns: ["chemistry"]
            isOneToOne: false
            referencedRelation: "battery_chemistries"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "materials_form_code_fkey"
            columns: ["form_code"]
            isOneToOne: false
            referencedRelation: "material_forms"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "materials_kind_code_fkey"
            columns: ["kind_code"]
            isOneToOne: false
            referencedRelation: "material_kinds"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "materials_size_format_code_fkey"
            columns: ["size_format_code"]
            isOneToOne: false
            referencedRelation: "material_size_formats"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "materials_source_code_fkey"
            columns: ["source_code"]
            isOneToOne: false
            referencedRelation: "material_sources"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "materials_waste_classification_code_fkey"
            columns: ["waste_classification_code"]
            isOneToOne: false
            referencedRelation: "waste_classifications"
            referencedColumns: ["code"]
          },
        ]
      }
      medical_claims: {
        Row: {
          amount_sgd: number
          claim_date: string
          claim_year: number
          code: string
          created_at: string
          created_by: string | null
          decided_at: string | null
          decided_by: string | null
          decision_notes: string | null
          deleted_at: string | null
          description: string | null
          employee_id: string
          expense_id: string | null
          id: string
          receipt_ref: string | null
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          amount_sgd: number
          claim_date: string
          claim_year: number
          code: string
          created_at?: string
          created_by?: string | null
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          deleted_at?: string | null
          description?: string | null
          employee_id: string
          expense_id?: string | null
          id?: string
          receipt_ref?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          amount_sgd?: number
          claim_date?: string
          claim_year?: number
          code?: string
          created_at?: string
          created_by?: string | null
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          deleted_at?: string | null
          description?: string | null
          employee_id?: string
          expense_id?: string | null
          id?: string
          receipt_ref?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
        ]
      }
      metal_price_indices: {
        Row: {
          code: string
          created_at: string
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          quote_currency: string | null
          quote_currency_basis: string | null
          sort_order: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          quote_currency?: string | null
          quote_currency_basis?: string | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          quote_currency?: string | null
          quote_currency_basis?: string | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "metal_price_indices_quote_currency_fkey"
            columns: ["quote_currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      metal_prices: {
        Row: {
          anomaly_check: Json | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          metal: string
          notes: string | null
          price_date: string
          price_index: string | null
          price_usd_per_tonne: number
          quote_delayed: boolean | null
          source: string
          source_reference: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          anomaly_check?: Json | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          metal: string
          notes?: string | null
          price_date: string
          price_index?: string | null
          price_usd_per_tonne: number
          quote_delayed?: boolean | null
          source: string
          source_reference?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          anomaly_check?: Json | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          metal?: string
          notes?: string | null
          price_date?: string
          price_index?: string | null
          price_usd_per_tonne?: number
          quote_delayed?: boolean | null
          source?: string
          source_reference?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "metal_prices_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "metal_prices_price_index_fkey"
            columns: ["price_index"]
            isOneToOne: false
            referencedRelation: "metal_price_indices"
            referencedColumns: ["code"]
          },
        ]
      }
      notification_reads: {
        Row: {
          notification_id: string
          read_at: string
          user_id: string
        }
        Insert: {
          notification_id: string
          read_at?: string
          user_id: string
        }
        Update: {
          notification_id?: string
          read_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "notification_reads_notification_id_fkey"
            columns: ["notification_id"]
            isOneToOne: false
            referencedRelation: "notifications"
            referencedColumns: ["id"]
          },
        ]
      }
      notifications: {
        Row: {
          actor_user_id: string | null
          created_at: string
          event_type: string
          id: string
          occurred_at: string
          payload: Json
          subject_code: string | null
          subject_id: string | null
          subject_type: string
        }
        Insert: {
          actor_user_id?: string | null
          created_at?: string
          event_type: string
          id?: string
          occurred_at?: string
          payload?: Json
          subject_code?: string | null
          subject_id?: string | null
          subject_type: string
        }
        Update: {
          actor_user_id?: string | null
          created_at?: string
          event_type?: string
          id?: string
          occurred_at?: string
          payload?: Json
          subject_code?: string | null
          subject_id?: string | null
          subject_type?: string
        }
        Relationships: []
      }
      operation_kinds: {
        Row: {
          code: string
          consumes_input: boolean
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          produces_outputs: boolean
          sort_order: number
        }
        Insert: {
          code: string
          consumes_input: boolean
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          produces_outputs: boolean
          sort_order?: number
        }
        Update: {
          code?: string
          consumes_input?: boolean
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          produces_outputs?: boolean
          sort_order?: number
        }
        Relationships: []
      }
      operation_type_input_forms: {
        Row: {
          form_code: string
          notes: string | null
          operation_type_code: string
        }
        Insert: {
          form_code: string
          notes?: string | null
          operation_type_code: string
        }
        Update: {
          form_code?: string
          notes?: string | null
          operation_type_code?: string
        }
        Relationships: [
          {
            foreignKeyName: "operation_type_input_forms_form_code_fkey"
            columns: ["form_code"]
            isOneToOne: false
            referencedRelation: "material_forms"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "operation_type_input_forms_operation_type_code_fkey"
            columns: ["operation_type_code"]
            isOneToOne: false
            referencedRelation: "operation_types"
            referencedColumns: ["code"]
          },
        ]
      }
      operation_type_output_forms: {
        Row: {
          form_code: string
          notes: string | null
          operation_type_code: string
        }
        Insert: {
          form_code: string
          notes?: string | null
          operation_type_code: string
        }
        Update: {
          form_code?: string
          notes?: string | null
          operation_type_code?: string
        }
        Relationships: [
          {
            foreignKeyName: "operation_type_output_forms_form_code_fkey"
            columns: ["form_code"]
            isOneToOne: false
            referencedRelation: "material_forms"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "operation_type_output_forms_operation_type_code_fkey"
            columns: ["operation_type_code"]
            isOneToOne: false
            referencedRelation: "operation_types"
            referencedColumns: ["code"]
          },
        ]
      }
      operation_type_safety_states: {
        Row: {
          notes: string | null
          operation_type_code: string
          resolves: boolean
          safety_state_code: string
        }
        Insert: {
          notes?: string | null
          operation_type_code: string
          resolves?: boolean
          safety_state_code: string
        }
        Update: {
          notes?: string | null
          operation_type_code?: string
          resolves?: boolean
          safety_state_code?: string
        }
        Relationships: [
          {
            foreignKeyName: "operation_type_safety_states_operation_type_code_fkey"
            columns: ["operation_type_code"]
            isOneToOne: false
            referencedRelation: "operation_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "operation_type_safety_states_safety_state_code_fkey"
            columns: ["safety_state_code"]
            isOneToOne: false
            referencedRelation: "inbound_safety_states"
            referencedColumns: ["code"]
          },
        ]
      }
      operation_types: {
        Row: {
          code: string
          is_active: boolean
          kind_code: string
          name_en: string
          name_zh: string
          notes: string | null
          resulting_safety_state_code: string | null
          sort_order: number
        }
        Insert: {
          code: string
          is_active?: boolean
          kind_code: string
          name_en: string
          name_zh: string
          notes?: string | null
          resulting_safety_state_code?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          is_active?: boolean
          kind_code?: string
          name_en?: string
          name_zh?: string
          notes?: string | null
          resulting_safety_state_code?: string | null
          sort_order?: number
        }
        Relationships: [
          {
            foreignKeyName: "operation_types_kind_code_fkey"
            columns: ["kind_code"]
            isOneToOne: false
            referencedRelation: "operation_kinds"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "operation_types_resulting_safety_state_code_fkey"
            columns: ["resulting_safety_state_code"]
            isOneToOne: false
            referencedRelation: "inbound_safety_states"
            referencedColumns: ["code"]
          },
        ]
      }
      output_batch_metals: {
        Row: {
          content_pct: number
          content_source: string
          created_at: string
          created_by: string | null
          metal: string
          output_batch_id: string
          source_assay_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          content_pct: number
          content_source: string
          created_at?: string
          created_by?: string | null
          metal: string
          output_batch_id: string
          source_assay_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          content_pct?: number
          content_source?: string
          created_at?: string
          created_by?: string | null
          metal?: string
          output_batch_id?: string
          source_assay_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "output_batch_metals_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "output_batch_metals_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "output_batch_metals_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "output_batch_metals_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "output_batch_metals_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "output_batch_metals_source_assay_id_fkey"
            columns: ["source_assay_id"]
            isOneToOne: false
            referencedRelation: "assay_results"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "output_batch_metals_source_assay_id_fkey"
            columns: ["source_assay_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["assay_result_id"]
          },
        ]
      }
      output_batch_purposes: {
        Row: {
          code: string
          is_active: boolean
          is_saleable_stock: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
        }
        Insert: {
          code: string
          is_active?: boolean
          is_saleable_stock: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          is_active?: boolean
          is_saleable_stock?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
        }
        Relationships: []
      }
      output_batch_safety_states: {
        Row: {
          created_at: string
          created_by: string | null
          output_batch_id: string
          safety_state_code: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          output_batch_id: string
          safety_state_code: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          output_batch_id?: string
          safety_state_code?: string
        }
        Relationships: [
          {
            foreignKeyName: "output_batch_safety_states_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "output_batch_safety_states_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "output_batch_safety_states_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "output_batch_safety_states_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "output_batch_safety_states_safety_state_code_fkey"
            columns: ["safety_state_code"]
            isOneToOne: false
            referencedRelation: "inbound_safety_states"
            referencedColumns: ["code"]
          },
        ]
      }
      output_batch_states: {
        Row: {
          code: string
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
        }
        Insert: {
          code: string
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
        }
        Update: {
          code?: string
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
        }
        Relationships: []
      }
      output_batches: {
        Row: {
          awaiting_operation_type_code: string | null
          code: string
          created_at: string
          created_by: string | null
          customer_id: string | null
          delete_reason: string | null
          deleted_at: string | null
          deleted_by: string | null
          id: string
          material_id: string
          notes: string | null
          output_date: string | null
          purity: string | null
          purpose_code: string
          quantity: number
          remaining_qty: number
          state: string
          status: string
          unit: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          awaiting_operation_type_code?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          id?: string
          material_id: string
          notes?: string | null
          output_date?: string | null
          purity?: string | null
          purpose_code?: string
          quantity: number
          remaining_qty: number
          state?: string
          status?: string
          unit?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          awaiting_operation_type_code?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          id?: string
          material_id?: string
          notes?: string | null
          output_date?: string | null
          purity?: string | null
          purpose_code?: string
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
            foreignKeyName: "output_batches_awaiting_operation_type_code_fkey"
            columns: ["awaiting_operation_type_code"]
            isOneToOne: false
            referencedRelation: "operation_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "output_batches_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
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
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "output_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "output_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "output_batches_purpose_code_fkey"
            columns: ["purpose_code"]
            isOneToOne: false
            referencedRelation: "output_batch_purposes"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "output_batches_state_fkey"
            columns: ["state"]
            isOneToOne: false
            referencedRelation: "output_batch_states"
            referencedColumns: ["code"]
          },
        ]
      }
      payment_allocations: {
        Row: {
          allocated_base: number
          allocated_ccy: number
          allocated_pay: number
          created_at: string | null
          expense_id: string | null
          freight_document_id: string | null
          id: string
          inbound_batch_id: string | null
          invoice_id: string | null
          payment_id: string
          purchase_order_id: string | null
          sales_record_id: string | null
          withheld_base: number
          withheld_pay: number
        }
        Insert: {
          allocated_base: number
          allocated_ccy: number
          allocated_pay: number
          created_at?: string | null
          expense_id?: string | null
          freight_document_id?: string | null
          id?: string
          inbound_batch_id?: string | null
          invoice_id?: string | null
          payment_id: string
          purchase_order_id?: string | null
          sales_record_id?: string | null
          withheld_base?: number
          withheld_pay?: number
        }
        Update: {
          allocated_base?: number
          allocated_ccy?: number
          allocated_pay?: number
          created_at?: string | null
          expense_id?: string | null
          freight_document_id?: string | null
          id?: string
          inbound_batch_id?: string | null
          invoice_id?: string | null
          payment_id?: string
          purchase_order_id?: string | null
          sales_record_id?: string | null
          withheld_base?: number
          withheld_pay?: number
        }
        Relationships: [
          {
            foreignKeyName: "payment_allocations_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_freight_document_id_fkey"
            columns: ["freight_document_id"]
            isOneToOne: false
            referencedRelation: "freight_documents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "payment_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "payment_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "payment_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "payment_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "payment_allocations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_document_totals"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "payment_allocations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_status"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "payment_allocations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_balance_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "payment_allocations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_open_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "payment_allocations_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "payment_allocations_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "payment_allocations_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "payment_allocations_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "payment_allocations_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "payment_allocations_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_visible"
            referencedColumns: ["id"]
          },
        ]
      }
      payment_event_owners: {
        Row: {
          note: string | null
          owner_name: string
          trigger_event: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          note?: string | null
          owner_name: string
          trigger_event: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          note?: string | null
          owner_name?: string
          trigger_event?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      payment_term_template_lines: {
        Row: {
          created_at: string
          days_offset: number | null
          fixed_amount_ccy: number | null
          id: string
          label: string
          notes: string | null
          percentage: number | null
          seq: number
          template_id: string
          trigger_event: string
        }
        Insert: {
          created_at?: string
          days_offset?: number | null
          fixed_amount_ccy?: number | null
          id?: string
          label: string
          notes?: string | null
          percentage?: number | null
          seq: number
          template_id: string
          trigger_event: string
        }
        Update: {
          created_at?: string
          days_offset?: number | null
          fixed_amount_ccy?: number | null
          id?: string
          label?: string
          notes?: string | null
          percentage?: number | null
          seq?: number
          template_id?: string
          trigger_event?: string
        }
        Relationships: [
          {
            foreignKeyName: "payment_term_template_lines_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "payment_term_templates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_term_template_lines_trigger_event_fkey"
            columns: ["trigger_event"]
            isOneToOne: false
            referencedRelation: "payment_trigger_events"
            referencedColumns: ["code"]
          },
        ]
      }
      payment_term_templates: {
        Row: {
          created_at: string
          created_by: string | null
          currency: string | null
          deleted_at: string | null
          description: string | null
          id: string
          is_active: boolean
          name: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          currency?: string | null
          deleted_at?: string | null
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          currency?: string | null
          deleted_at?: string | null
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payment_term_templates_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      payment_trigger_events: {
        Row: {
          applies_to_equipment: boolean
          applies_to_material: boolean
          can_anchor_retention: boolean
          code: string
          created_at: string
          is_active: boolean
          name_en: string
          name_zh: string
          phrase_en: string
          sort_order: number
        }
        Insert: {
          applies_to_equipment: boolean
          applies_to_material: boolean
          can_anchor_retention?: boolean
          code: string
          created_at?: string
          is_active?: boolean
          name_en: string
          name_zh: string
          phrase_en: string
          sort_order: number
        }
        Update: {
          applies_to_equipment?: boolean
          applies_to_material?: boolean
          can_anchor_retention?: boolean
          code?: string
          created_at?: string
          is_active?: boolean
          name_en?: string
          name_zh?: string
          phrase_en?: string
          sort_order?: number
        }
        Relationships: []
      }
      payments: {
        Row: {
          amount_base: number
          amount_ccy: number
          bank_account_code: string
          code: string
          counterparty_type: string
          created_at: string | null
          created_by: string | null
          currency: string
          customer_id: string | null
          direction: string
          employee_id: string | null
          fx_rate: number
          id: string
          journal_entry_id: string | null
          notes: string | null
          payment_date: string
          reversed_by_payment: string | null
          status: string
          supplier_id: string | null
        }
        Insert: {
          amount_base: number
          amount_ccy: number
          bank_account_code: string
          code: string
          counterparty_type: string
          created_at?: string | null
          created_by?: string | null
          currency: string
          customer_id?: string | null
          direction: string
          employee_id?: string | null
          fx_rate: number
          id?: string
          journal_entry_id?: string | null
          notes?: string | null
          payment_date: string
          reversed_by_payment?: string | null
          status?: string
          supplier_id?: string | null
        }
        Update: {
          amount_base?: number
          amount_ccy?: number
          bank_account_code?: string
          code?: string
          counterparty_type?: string
          created_at?: string | null
          created_by?: string | null
          currency?: string
          customer_id?: string | null
          direction?: string
          employee_id?: string | null
          fx_rate?: number
          id?: string
          journal_entry_id?: string | null
          notes?: string | null
          payment_date?: string
          reversed_by_payment?: string | null
          status?: string
          supplier_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payments_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "payments_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "payments_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payments_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payments_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payments_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payments_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payments_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payments_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payments_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payments_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "payments_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_reversed_by_payment_fkey"
            columns: ["reversed_by_payment"]
            isOneToOne: false
            referencedRelation: "payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "payments_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_lines: {
        Row: {
          created_at: string
          employee_cpf: number
          employee_id: string
          employer_cpf: number
          gross_pay: number
          id: string
          net_pay: number
          notes: string | null
          other_deductions: number
          paid_at: string | null
          paid_journal_entry_id: string | null
          payroll_period_id: string
        }
        Insert: {
          created_at?: string
          employee_cpf?: number
          employee_id: string
          employer_cpf?: number
          gross_pay: number
          id?: string
          net_pay: number
          notes?: string | null
          other_deductions?: number
          paid_at?: string | null
          paid_journal_entry_id?: string | null
          payroll_period_id: string
        }
        Update: {
          created_at?: string
          employee_cpf?: number
          employee_id?: string
          employer_cpf?: number
          gross_pay?: number
          id?: string
          net_pay?: number
          notes?: string | null
          other_deductions?: number
          paid_at?: string | null
          paid_journal_entry_id?: string | null
          payroll_period_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_paid_journal_entry_id_fkey"
            columns: ["paid_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "payroll_lines_paid_journal_entry_id_fkey"
            columns: ["paid_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_payroll_period_id_fkey"
            columns: ["payroll_period_id"]
            isOneToOne: false
            referencedRelation: "payroll_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_periods: {
        Row: {
          code: string
          cpf_journal_entry_id: string | null
          cpf_paid_at: string | null
          created_at: string
          created_by: string | null
          currency: string
          deductions_journal_entry_id: string | null
          deductions_paid_at: string | null
          deleted_at: string | null
          employee_cpf_total: number
          employer_cpf_total: number
          fx_rate: number
          gross_total: number
          id: string
          journal_entry_id: string | null
          net_pay_total: number
          notes: string | null
          other_deductions_total: number
          payment_date: string
          period_month: string
          source_note: string | null
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          cpf_journal_entry_id?: string | null
          cpf_paid_at?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          deductions_journal_entry_id?: string | null
          deductions_paid_at?: string | null
          deleted_at?: string | null
          employee_cpf_total?: number
          employer_cpf_total?: number
          fx_rate: number
          gross_total?: number
          id?: string
          journal_entry_id?: string | null
          net_pay_total?: number
          notes?: string | null
          other_deductions_total?: number
          payment_date: string
          period_month: string
          source_note?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          cpf_journal_entry_id?: string | null
          cpf_paid_at?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          deductions_journal_entry_id?: string | null
          deductions_paid_at?: string | null
          deleted_at?: string | null
          employee_cpf_total?: number
          employer_cpf_total?: number
          fx_rate?: number
          gross_total?: number
          id?: string
          journal_entry_id?: string | null
          net_pay_total?: number
          notes?: string | null
          other_deductions_total?: number
          payment_date?: string
          period_month?: string
          source_note?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payroll_periods_cpf_journal_entry_id_fkey"
            columns: ["cpf_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "payroll_periods_cpf_journal_entry_id_fkey"
            columns: ["cpf_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_periods_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "payroll_periods_deductions_journal_entry_id_fkey"
            columns: ["deductions_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "payroll_periods_deductions_journal_entry_id_fkey"
            columns: ["deductions_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_periods_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "payroll_periods_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      performance_reviews: {
        Row: {
          acknowledged_at: string | null
          approved_at: string | null
          approved_by: string | null
          created_at: string
          created_by: string | null
          cycle_id: string | null
          employee_id: string
          id: string
          new_monthly_salary: number | null
          notes: string | null
          period_end: string
          period_start: string
          probation_outcome: string | null
          rating_code: string | null
          review_type: string
          reviewer_employee_id: string | null
          salary_effective_date: string | null
          self_assessment_submitted_at: string | null
          self_assessment_text: string | null
          status: string
          submitted_at: string | null
          submitted_by: string | null
          summary_text: string | null
          updated_at: string
          updated_by: string | null
          void_reason: string | null
          voided_at: string | null
          voided_by: string | null
        }
        Insert: {
          acknowledged_at?: string | null
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string
          created_by?: string | null
          cycle_id?: string | null
          employee_id: string
          id?: string
          new_monthly_salary?: number | null
          notes?: string | null
          period_end: string
          period_start: string
          probation_outcome?: string | null
          rating_code?: string | null
          review_type: string
          reviewer_employee_id?: string | null
          salary_effective_date?: string | null
          self_assessment_submitted_at?: string | null
          self_assessment_text?: string | null
          status?: string
          submitted_at?: string | null
          submitted_by?: string | null
          summary_text?: string | null
          updated_at?: string
          updated_by?: string | null
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Update: {
          acknowledged_at?: string | null
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string
          created_by?: string | null
          cycle_id?: string | null
          employee_id?: string
          id?: string
          new_monthly_salary?: number | null
          notes?: string | null
          period_end?: string
          period_start?: string
          probation_outcome?: string | null
          rating_code?: string | null
          review_type?: string
          reviewer_employee_id?: string | null
          salary_effective_date?: string | null
          self_assessment_submitted_at?: string | null
          self_assessment_text?: string | null
          status?: string
          submitted_at?: string | null
          submitted_by?: string | null
          summary_text?: string | null
          updated_at?: string
          updated_by?: string | null
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "performance_reviews_cycle_id_fkey"
            columns: ["cycle_id"]
            isOneToOne: false
            referencedRelation: "review_cycles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_rating_code_fkey"
            columns: ["rating_code"]
            isOneToOne: false
            referencedRelation: "review_rating_scale"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      period_closes: {
        Row: {
          closed_at: string
          closed_by: string | null
          entries_count: number
          id: string
          notes: string | null
          period_end: string
          reopen_reason: string | null
          reopened_at: string | null
          reopened_by: string | null
          total_credits: number
          total_debits: number
        }
        Insert: {
          closed_at?: string
          closed_by?: string | null
          entries_count: number
          id?: string
          notes?: string | null
          period_end: string
          reopen_reason?: string | null
          reopened_at?: string | null
          reopened_by?: string | null
          total_credits: number
          total_debits: number
        }
        Update: {
          closed_at?: string
          closed_by?: string | null
          entries_count?: number
          id?: string
          notes?: string | null
          period_end?: string
          reopen_reason?: string | null
          reopened_at?: string | null
          reopened_by?: string | null
          total_credits?: number
          total_debits?: number
        }
        Relationships: []
      }
      permissions: {
        Row: {
          category: string
          code: string
          description_en: string | null
          description_zh: string | null
          name_en: string
          name_zh: string
          sort_order: number
        }
        Insert: {
          category: string
          code: string
          description_en?: string | null
          description_zh?: string | null
          name_en: string
          name_zh: string
          sort_order?: number
        }
        Update: {
          category?: string
          code?: string
          description_en?: string | null
          description_zh?: string | null
          name_en?: string
          name_zh?: string
          sort_order?: number
        }
        Relationships: []
      }
      po_issues: {
        Row: {
          file_path: string
          id: string
          issued_at: string
          issued_by: string | null
          purchase_order_id: string
          sha256: string
          version: number
        }
        Insert: {
          file_path: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          purchase_order_id: string
          sha256: string
          version: number
        }
        Update: {
          file_path?: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          purchase_order_id?: string
          sha256?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "po_issues_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "po_issues_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "po_issues_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "po_issues_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "po_issues_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "po_issues_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "po_issues_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      ports: {
        Row: {
          code: string
          country: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          name: string
        }
        Insert: {
          code: string
          country?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name: string
        }
        Update: {
          code?: string
          country?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name?: string
        }
        Relationships: []
      }
      positions: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          id: string
          is_active: boolean
          notes: string | null
          sort_order: number
          source_incumbent_name: string | null
          title: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          notes?: string | null
          sort_order?: number
          source_incumbent_name?: string | null
          title: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          notes?: string | null
          sort_order?: number
          source_incumbent_name?: string | null
          title?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      prepayment_applications: {
        Row: {
          amount_base: number
          amount_ccy: number | null
          created_at: string
          created_by: string | null
          currency: string | null
          expense_id: string | null
          id: string
          inbound_batch_id: string | null
          journal_entry_id: string | null
          notes: string | null
          purchase_order_id: string
        }
        Insert: {
          amount_base: number
          amount_ccy?: number | null
          created_at?: string
          created_by?: string | null
          currency?: string | null
          expense_id?: string | null
          id?: string
          inbound_batch_id?: string | null
          journal_entry_id?: string | null
          notes?: string | null
          purchase_order_id: string
        }
        Update: {
          amount_base?: number
          amount_ccy?: number | null
          created_at?: string
          created_by?: string | null
          currency?: string | null
          expense_id?: string | null
          id?: string
          inbound_batch_id?: string | null
          journal_entry_id?: string | null
          notes?: string | null
          purchase_order_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "prepayment_applications_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "prepayment_applications_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "prepayment_applications_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      price_history: {
        Row: {
          created_at: string
          created_by: string | null
          currency: string
          fx_rate: number
          id: string
          inbound_batch_id: string
          new_unit_price: number
          notes: string | null
          old_unit_price: number | null
          original_price: number
          rate_as_of: string | null
          rate_type: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          currency: string
          fx_rate: number
          id?: string
          inbound_batch_id: string
          new_unit_price: number
          notes?: string | null
          old_unit_price?: number | null
          original_price: number
          rate_as_of?: string | null
          rate_type?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          currency?: string
          fx_rate?: number
          id?: string
          inbound_batch_id?: string
          new_unit_price?: number
          notes?: string | null
          old_unit_price?: number | null
          original_price?: number
          rate_as_of?: string | null
          rate_type?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
        ]
      }
      pricing_formula_history: {
        Row: {
          change_type: string
          changed_at: string
          changed_by: string | null
          formula_id: string
          id: string
          metal: string | null
          new_average_days: number | null
          new_direction: string | null
          new_flat_discount_pct: number | null
          new_is_active: boolean | null
          new_name: string | null
          new_payable_pct: number | null
          new_price_basis: string | null
          new_treatment_charge_usd_per_tonne: number | null
          old_average_days: number | null
          old_direction: string | null
          old_flat_discount_pct: number | null
          old_is_active: boolean | null
          old_name: string | null
          old_payable_pct: number | null
          old_price_basis: string | null
          old_treatment_charge_usd_per_tonne: number | null
        }
        Insert: {
          change_type: string
          changed_at?: string
          changed_by?: string | null
          formula_id: string
          id?: string
          metal?: string | null
          new_average_days?: number | null
          new_direction?: string | null
          new_flat_discount_pct?: number | null
          new_is_active?: boolean | null
          new_name?: string | null
          new_payable_pct?: number | null
          new_price_basis?: string | null
          new_treatment_charge_usd_per_tonne?: number | null
          old_average_days?: number | null
          old_direction?: string | null
          old_flat_discount_pct?: number | null
          old_is_active?: boolean | null
          old_name?: string | null
          old_payable_pct?: number | null
          old_price_basis?: string | null
          old_treatment_charge_usd_per_tonne?: number | null
        }
        Update: {
          change_type?: string
          changed_at?: string
          changed_by?: string | null
          formula_id?: string
          id?: string
          metal?: string | null
          new_average_days?: number | null
          new_direction?: string | null
          new_flat_discount_pct?: number | null
          new_is_active?: boolean | null
          new_name?: string | null
          new_payable_pct?: number | null
          new_price_basis?: string | null
          new_treatment_charge_usd_per_tonne?: number | null
          old_average_days?: number | null
          old_direction?: string | null
          old_flat_discount_pct?: number | null
          old_is_active?: boolean | null
          old_name?: string | null
          old_payable_pct?: number | null
          old_price_basis?: string | null
          old_treatment_charge_usd_per_tonne?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "pricing_formula_history_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formula_history_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formula_history_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
        ]
      }
      pricing_formula_metals: {
        Row: {
          created_at: string
          created_by: string | null
          formula_id: string
          metal: string
          payable_pct: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          formula_id: string
          metal: string
          payable_pct: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          formula_id?: string
          metal?: string
          payable_pct?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pricing_formula_metals_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formula_metals_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formula_metals_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
        ]
      }
      pricing_formulas: {
        Row: {
          average_days: number | null
          code: string
          created_at: string
          created_by: string | null
          customer_id: string | null
          deleted_at: string | null
          direction: string
          flat_discount_pct: number
          id: string
          is_active: boolean
          name: string
          notes: string | null
          price_basis: string
          price_index: string | null
          supplier_id: string | null
          treatment_charge_usd_per_tonne: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          average_days?: number | null
          code: string
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          direction?: string
          flat_discount_pct?: number
          id?: string
          is_active?: boolean
          name: string
          notes?: string | null
          price_basis?: string
          price_index?: string | null
          supplier_id?: string | null
          treatment_charge_usd_per_tonne?: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          average_days?: number | null
          code?: string
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          direction?: string
          flat_discount_pct?: number
          id?: string
          is_active?: boolean
          name?: string
          notes?: string | null
          price_basis?: string
          price_index?: string | null
          supplier_id?: string | null
          treatment_charge_usd_per_tonne?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pricing_formulas_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "pricing_formulas_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formulas_price_index_fkey"
            columns: ["price_index"]
            isOneToOne: false
            referencedRelation: "metal_price_indices"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "pricing_formulas_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "pricing_formulas_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      pricing_settings: {
        Row: {
          default_metal_index: string | null
          id: boolean
          metal_price_change_warn_pct: number
          metal_quote_stale_days: number
          notes: string | null
          notes_en: string | null
          notes_zh: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          default_metal_index?: string | null
          id?: boolean
          metal_price_change_warn_pct: number
          metal_quote_stale_days?: number
          notes?: string | null
          notes_en?: string | null
          notes_zh?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          default_metal_index?: string | null
          id?: boolean
          metal_price_change_warn_pct?: number
          metal_quote_stale_days?: number
          notes?: string | null
          notes_en?: string | null
          notes_zh?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pricing_settings_default_metal_index_fkey"
            columns: ["default_metal_index"]
            isOneToOne: false
            referencedRelation: "metal_price_indices"
            referencedColumns: ["code"]
          },
        ]
      }
      pricing_term_commitment_metals: {
        Row: {
          commitment_id: string
          metal: string
          payable_pct: number
        }
        Insert: {
          commitment_id: string
          metal: string
          payable_pct: number
        }
        Update: {
          commitment_id?: string
          metal?: string
          payable_pct?: number
        }
        Relationships: [
          {
            foreignKeyName: "pricing_term_commitment_metals_commitment_id_fkey"
            columns: ["commitment_id"]
            isOneToOne: false
            referencedRelation: "pricing_term_commitments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitment_metals_commitment_id_fkey"
            columns: ["commitment_id"]
            isOneToOne: false
            referencedRelation: "pricing_term_commitments_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitment_metals_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
        ]
      }
      pricing_term_commitments: {
        Row: {
          average_days: number | null
          committed_at: string
          committed_by: string | null
          flat_discount_pct: number
          id: string
          inbound_batch_id: string | null
          price_basis: string
          price_index: string | null
          purchase_order_line_id: string | null
          source_formula_code: string
          source_formula_id: string | null
          source_formula_name: string | null
          treatment_charge_usd_per_tonne: number
        }
        Insert: {
          average_days?: number | null
          committed_at?: string
          committed_by?: string | null
          flat_discount_pct: number
          id?: string
          inbound_batch_id?: string | null
          price_basis: string
          price_index?: string | null
          purchase_order_line_id?: string | null
          source_formula_code: string
          source_formula_id?: string | null
          source_formula_name?: string | null
          treatment_charge_usd_per_tonne: number
        }
        Update: {
          average_days?: number | null
          committed_at?: string
          committed_by?: string | null
          flat_discount_pct?: number
          id?: string
          inbound_batch_id?: string | null
          price_basis?: string
          price_index?: string | null
          purchase_order_line_id?: string | null
          source_formula_code?: string
          source_formula_id?: string | null
          source_formula_name?: string | null
          treatment_charge_usd_per_tonne?: number
        }
        Relationships: [
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_price_index_fkey"
            columns: ["price_index"]
            isOneToOne: false
            referencedRelation: "metal_price_indices"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "pricing_term_commitments_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_lines_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_cost_entries: {
        Row: {
          amount_base: number
          cost_type: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          is_estimate: boolean
          notes: string | null
          relief_expense_id: string | null
          relieved_at: string | null
          remitted_at: string | null
          remitted_journal_entry_id: string | null
          run_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          amount_base: number
          cost_type: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_estimate?: boolean
          notes?: string | null
          relief_expense_id?: string | null
          relieved_at?: string | null
          remitted_at?: string | null
          remitted_journal_entry_id?: string | null
          run_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          amount_base?: number
          cost_type?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_estimate?: boolean
          notes?: string | null
          relief_expense_id?: string | null
          relieved_at?: string | null
          remitted_at?: string | null
          remitted_journal_entry_id?: string | null
          run_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_cost_entries_relief_expense_id_fkey"
            columns: ["relief_expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entries_remitted_journal_entry_id_fkey"
            columns: ["remitted_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_remitted_journal_entry_id_fkey"
            columns: ["remitted_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
          },
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
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_loss_breakdown"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_cost_entry_history: {
        Row: {
          change_type: string
          changed_at: string
          changed_by: string | null
          entry_id: string
          id: string
          new_amount_base: number | null
          new_cost_type: string | null
          new_is_estimate: boolean | null
          old_amount_base: number | null
          old_cost_type: string | null
          old_is_estimate: boolean | null
          run_id: string
        }
        Insert: {
          change_type: string
          changed_at?: string
          changed_by?: string | null
          entry_id: string
          id?: string
          new_amount_base?: number | null
          new_cost_type?: string | null
          new_is_estimate?: boolean | null
          old_amount_base?: number | null
          old_cost_type?: string | null
          old_is_estimate?: boolean | null
          run_id: string
        }
        Update: {
          change_type?: string
          changed_at?: string
          changed_by?: string | null
          entry_id?: string
          id?: string
          new_amount_base?: number | null
          new_cost_type?: string | null
          new_is_estimate?: boolean | null
          old_amount_base?: number | null
          old_cost_type?: string | null
          old_is_estimate?: boolean | null
          run_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "processing_cost_entry_history_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "processing_cost_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "processing_cost_entries_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_loss_breakdown"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_inputs: {
        Row: {
          created_at: string
          id: string
          inbound_batch_id: string | null
          output_batch_id: string | null
          quantity_consumed: number
          run_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          inbound_batch_id?: string | null
          output_batch_id?: string | null
          quantity_consumed: number
          run_id: string
        }
        Update: {
          created_at?: string
          id?: string
          inbound_batch_id?: string | null
          output_batch_id?: string | null
          quantity_consumed?: number
          run_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "processing_inputs_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "processing_inputs_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "processing_inputs_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "processing_inputs_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "processing_inputs_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_inputs_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_inputs_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "processing_inputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "processing_inputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_inputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_inputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "processing_inputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
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
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_inputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_inputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_loss_breakdown"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_inputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_inputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_outputs: {
        Row: {
          allocated_cost_base: number | null
          cost_incomplete: boolean
          created_at: string
          id: string
          output_batch_id: string
          quantity_produced: number
          run_id: string
          unit_cost_base: number | null
        }
        Insert: {
          allocated_cost_base?: number | null
          cost_incomplete?: boolean
          created_at?: string
          id?: string
          output_batch_id: string
          quantity_produced: number
          run_id: string
          unit_cost_base?: number | null
        }
        Update: {
          allocated_cost_base?: number | null
          cost_incomplete?: boolean
          created_at?: string
          id?: string
          output_batch_id?: string
          quantity_produced?: number
          run_id?: string
          unit_cost_base?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_outputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "processing_outputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_outputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_outputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
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
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_loss_breakdown"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_run_losses: {
        Row: {
          created_at: string
          created_by: string | null
          loss_category_code: string
          notes: string | null
          quantity: number
          run_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          loss_category_code: string
          notes?: string | null
          quantity: number
          run_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          loss_category_code?: string
          notes?: string | null
          quantity?: number
          run_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "processing_run_losses_loss_category_code_fkey"
            columns: ["loss_category_code"]
            isOneToOne: false
            referencedRelation: "loss_categories"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "processing_run_losses_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_run_losses_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_run_losses_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_run_losses_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_run_losses_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_loss_breakdown"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_run_losses_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_run_losses_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_runs: {
        Row: {
          allocated_at: string | null
          allocated_by: string | null
          allocation_basis: string
          allocation_basis_changed_at: string | null
          allocation_snapshot: Json | null
          capitalization_entry_id: string | null
          capitalized_cost_base: number | null
          code: string
          created_at: string
          created_by: string | null
          delete_reason: string | null
          deleted_at: string | null
          deleted_by: string | null
          equipment_id: string | null
          id: string
          loss_qty: number | null
          material_cost_base: number | null
          notes: string | null
          operation_type_code: string | null
          process_cost_base: number | null
          process_date: string | null
          status: string
          total_cost_base: number | null
          total_input: number | null
          total_output: number | null
          updated_at: string
          updated_by: string | null
          work_order_id: string | null
        }
        Insert: {
          allocated_at?: string | null
          allocated_by?: string | null
          allocation_basis: string
          allocation_basis_changed_at?: string | null
          allocation_snapshot?: Json | null
          capitalization_entry_id?: string | null
          capitalized_cost_base?: number | null
          code: string
          created_at?: string
          created_by?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          equipment_id?: string | null
          id?: string
          loss_qty?: number | null
          material_cost_base?: number | null
          notes?: string | null
          operation_type_code?: string | null
          process_cost_base?: number | null
          process_date?: string | null
          status: string
          total_cost_base?: number | null
          total_input?: number | null
          total_output?: number | null
          updated_at?: string
          updated_by?: string | null
          work_order_id?: string | null
        }
        Update: {
          allocated_at?: string | null
          allocated_by?: string | null
          allocation_basis?: string
          allocation_basis_changed_at?: string | null
          allocation_snapshot?: Json | null
          capitalization_entry_id?: string | null
          capitalized_cost_base?: number | null
          code?: string
          created_at?: string
          created_by?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          equipment_id?: string | null
          id?: string
          loss_qty?: number | null
          material_cost_base?: number | null
          notes?: string | null
          operation_type_code?: string | null
          process_cost_base?: number | null
          process_date?: string | null
          status?: string
          total_cost_base?: number | null
          total_input?: number | null
          total_output?: number | null
          updated_at?: string
          updated_by?: string | null
          work_order_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_runs_capitalization_entry_id_fkey"
            columns: ["capitalization_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "processing_runs_capitalization_entry_id_fkey"
            columns: ["capitalization_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_runs_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "equipment_service_status"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "processing_runs_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "equipment_usage"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "processing_runs_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "fixed_assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_runs_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_retention_status"
            referencedColumns: ["asset_id"]
          },
          {
            foreignKeyName: "processing_runs_operation_type_code_fkey"
            columns: ["operation_type_code"]
            isOneToOne: false
            referencedRelation: "operation_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "processing_runs_work_order_id_fkey"
            columns: ["work_order_id"]
            isOneToOne: false
            referencedRelation: "work_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_settings: {
        Row: {
          id: boolean
          notes: string | null
          updated_at: string
          updated_by: string | null
          wo_input_overrun_pct: number
          wo_output_shortfall_pct: number
        }
        Insert: {
          id?: boolean
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          wo_input_overrun_pct?: number
          wo_output_shortfall_pct?: number
        }
        Update: {
          id?: boolean
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          wo_input_overrun_pct?: number
          wo_output_shortfall_pct?: number
        }
        Relationships: []
      }
      public_holidays: {
        Row: {
          country: string
          created_at: string
          created_by: string | null
          holiday_date: string
          id: string
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          country?: string
          created_at?: string
          created_by?: string | null
          holiday_date: string
          id?: string
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          country?: string
          created_at?: string
          created_by?: string | null
          holiday_date?: string
          id?: string
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      purchase_order_history: {
        Row: {
          amend_reason: string | null
          change_type: string
          changed_at: string
          changed_by: string | null
          id: string
          line_no: number | null
          new_estimated_amount_ccy: number | null
          new_estimated_total_ccy: number | null
          new_estimated_unit_price: number | null
          new_expected_delivery_date: string | null
          new_fx_rate: number | null
          new_incoterm: string | null
          new_notes: string | null
          new_order_date: string | null
          new_quantity: number | null
          new_terms_text: string | null
          new_unit: string | null
          old_estimated_amount_ccy: number | null
          old_estimated_total_ccy: number | null
          old_estimated_unit_price: number | null
          old_expected_delivery_date: string | null
          old_fx_rate: number | null
          old_incoterm: string | null
          old_notes: string | null
          old_order_date: string | null
          old_quantity: number | null
          old_terms_text: string | null
          old_unit: string | null
          purchase_order_id: string
          purchase_order_line_id: string | null
        }
        Insert: {
          amend_reason?: string | null
          change_type: string
          changed_at?: string
          changed_by?: string | null
          id?: string
          line_no?: number | null
          new_estimated_amount_ccy?: number | null
          new_estimated_total_ccy?: number | null
          new_estimated_unit_price?: number | null
          new_expected_delivery_date?: string | null
          new_fx_rate?: number | null
          new_incoterm?: string | null
          new_notes?: string | null
          new_order_date?: string | null
          new_quantity?: number | null
          new_terms_text?: string | null
          new_unit?: string | null
          old_estimated_amount_ccy?: number | null
          old_estimated_total_ccy?: number | null
          old_estimated_unit_price?: number | null
          old_expected_delivery_date?: string | null
          old_fx_rate?: number | null
          old_incoterm?: string | null
          old_notes?: string | null
          old_order_date?: string | null
          old_quantity?: number | null
          old_terms_text?: string | null
          old_unit?: string | null
          purchase_order_id: string
          purchase_order_line_id?: string | null
        }
        Update: {
          amend_reason?: string | null
          change_type?: string
          changed_at?: string
          changed_by?: string | null
          id?: string
          line_no?: number | null
          new_estimated_amount_ccy?: number | null
          new_estimated_total_ccy?: number | null
          new_estimated_unit_price?: number | null
          new_expected_delivery_date?: string | null
          new_fx_rate?: number | null
          new_incoterm?: string | null
          new_notes?: string | null
          new_order_date?: string | null
          new_quantity?: number | null
          new_terms_text?: string | null
          new_unit?: string | null
          old_estimated_amount_ccy?: number | null
          old_estimated_total_ccy?: number | null
          old_estimated_unit_price?: number | null
          old_expected_delivery_date?: string | null
          old_fx_rate?: number | null
          old_incoterm?: string | null
          old_notes?: string | null
          old_order_date?: string | null
          old_quantity?: number | null
          old_terms_text?: string | null
          old_unit?: string | null
          purchase_order_id?: string
          purchase_order_line_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_history_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_history_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_history_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_history_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_history_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_history_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_history_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_order_line_retentions: {
        Row: {
          anchor_event: string
          created_at: string
          created_by: string | null
          fixed_amount_ccy: number | null
          id: string
          notes: string | null
          percentage: number | null
          purchase_order_line_id: string
          released_amount_ccy: number | null
          released_at: string | null
          released_by: string | null
          retention_months: number
          withheld_amount_ccy: number | null
          withholding_reason: string | null
        }
        Insert: {
          anchor_event?: string
          created_at?: string
          created_by?: string | null
          fixed_amount_ccy?: number | null
          id?: string
          notes?: string | null
          percentage?: number | null
          purchase_order_line_id: string
          released_amount_ccy?: number | null
          released_at?: string | null
          released_by?: string | null
          retention_months?: number
          withheld_amount_ccy?: number | null
          withholding_reason?: string | null
        }
        Update: {
          anchor_event?: string
          created_at?: string
          created_by?: string | null
          fixed_amount_ccy?: number | null
          id?: string
          notes?: string | null
          percentage?: number | null
          purchase_order_line_id?: string
          released_amount_ccy?: number | null
          released_at?: string | null
          released_by?: string | null
          retention_months?: number
          withheld_amount_ccy?: number | null
          withholding_reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_line_retentions_anchor_event_fkey"
            columns: ["anchor_event"]
            isOneToOne: false
            referencedRelation: "payment_trigger_events"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "purchase_order_line_retentions_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "purchase_order_line_retentions_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "purchase_order_line_retentions_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_line_retentions_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_lines_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_order_lines: {
        Row: {
          asset_id: string | null
          created_at: string
          created_by: string | null
          deep_discharge_judgement_code: string | null
          estimated_amount_ccy: number
          estimated_unit_price: number | null
          expected_assay: Json | null
          id: string
          line_no: number
          material_id: string | null
          notes: string | null
          price_provenance: Json | null
          price_source: string | null
          pricing_formula_id: string | null
          purchase_order_id: string
          quantity: number
          unit: string
        }
        Insert: {
          asset_id?: string | null
          created_at?: string
          created_by?: string | null
          deep_discharge_judgement_code?: string | null
          estimated_amount_ccy?: number
          estimated_unit_price?: number | null
          expected_assay?: Json | null
          id?: string
          line_no: number
          material_id?: string | null
          notes?: string | null
          price_provenance?: Json | null
          price_source?: string | null
          pricing_formula_id?: string | null
          purchase_order_id: string
          quantity: number
          unit?: string
        }
        Update: {
          asset_id?: string | null
          created_at?: string
          created_by?: string | null
          deep_discharge_judgement_code?: string | null
          estimated_amount_ccy?: number
          estimated_unit_price?: number | null
          expected_assay?: Json | null
          id?: string
          line_no?: number
          material_id?: string | null
          notes?: string | null
          price_provenance?: Json | null
          price_source?: string | null
          pricing_formula_id?: string | null
          purchase_order_id?: string
          quantity?: number
          unit?: string
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_lines_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "equipment_service_status"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "equipment_usage"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "fixed_assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_retention_status"
            referencedColumns: ["asset_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_deep_discharge_judgement_code_fkey"
            columns: ["deep_discharge_judgement_code"]
            isOneToOne: false
            referencedRelation: "deep_discharge_judgements"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_order_payment_terms: {
        Row: {
          created_at: string
          due_date: string | null
          expected_date: string | null
          expected_date_set_at: string | null
          expected_date_set_by: string | null
          fixed_amount_ccy: number | null
          id: string
          label: string
          notes: string | null
          percentage: number | null
          purchase_order_id: string
          seq: number
          trigger_event: string
        }
        Insert: {
          created_at?: string
          due_date?: string | null
          expected_date?: string | null
          expected_date_set_at?: string | null
          expected_date_set_by?: string | null
          fixed_amount_ccy?: number | null
          id?: string
          label: string
          notes?: string | null
          percentage?: number | null
          purchase_order_id: string
          seq: number
          trigger_event: string
        }
        Update: {
          created_at?: string
          due_date?: string | null
          expected_date?: string | null
          expected_date_set_at?: string | null
          expected_date_set_by?: string | null
          fixed_amount_ccy?: number | null
          id?: string
          label?: string
          notes?: string | null
          percentage?: number | null
          purchase_order_id?: string
          seq?: number
          trigger_event?: string
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_trigger_event_fkey"
            columns: ["trigger_event"]
            isOneToOne: false
            referencedRelation: "payment_trigger_events"
            referencedColumns: ["code"]
          },
        ]
      }
      purchase_orders: {
        Row: {
          approval_status: string
          approved_at: string | null
          approved_by: string | null
          cancel_reason: string | null
          cancelled_at: string | null
          cancelled_by: string | null
          closed_at: string | null
          code: string
          contract_id: string | null
          created_at: string
          created_by: string | null
          currency: string
          delete_reason: string | null
          deleted_at: string | null
          deleted_by: string | null
          estimated_total_ccy: number
          expected_delivery_date: string | null
          fx_rate: number
          id: string
          incoterm: string | null
          notes: string | null
          order_date: string
          status: string
          supplier_id: string
          terms_text: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          approval_status?: string
          approved_at?: string | null
          approved_by?: string | null
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          closed_at?: string | null
          code: string
          contract_id?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          estimated_total_ccy?: number
          expected_delivery_date?: string | null
          fx_rate: number
          id?: string
          incoterm?: string | null
          notes?: string | null
          order_date: string
          status?: string
          supplier_id: string
          terms_text?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          approval_status?: string
          approved_at?: string | null
          approved_by?: string | null
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          closed_at?: string | null
          code?: string
          contract_id?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          estimated_total_ccy?: number
          expected_delivery_date?: string | null
          fx_rate?: number
          id?: string
          incoterm?: string | null
          notes?: string | null
          order_date?: string
          status?: string
          supplier_id?: string
          terms_text?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_orders_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: false
            referencedRelation: "contracts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_orders_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      qt_issues: {
        Row: {
          file_path: string
          id: string
          issued_at: string
          issued_by: string | null
          quote_id: string
          sha256: string
          version: number
        }
        Insert: {
          file_path: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          quote_id: string
          sha256: string
          version: number
        }
        Update: {
          file_path?: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          quote_id?: string
          sha256?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "qt_issues_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: false
            referencedRelation: "quote_status"
            referencedColumns: ["quote_id"]
          },
          {
            foreignKeyName: "qt_issues_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: false
            referencedRelation: "quotes"
            referencedColumns: ["id"]
          },
        ]
      }
      quote_history: {
        Row: {
          change_type: string
          changed_at: string
          changed_by: string | null
          detail: string | null
          id: string
          quote_id: string
        }
        Insert: {
          change_type: string
          changed_at?: string
          changed_by?: string | null
          detail?: string | null
          id?: string
          quote_id: string
        }
        Update: {
          change_type?: string
          changed_at?: string
          changed_by?: string | null
          detail?: string | null
          id?: string
          quote_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "quote_history_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: false
            referencedRelation: "quote_status"
            referencedColumns: ["quote_id"]
          },
          {
            foreignKeyName: "quote_history_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: false
            referencedRelation: "quotes"
            referencedColumns: ["id"]
          },
        ]
      }
      quote_lines: {
        Row: {
          created_at: string
          id: string
          line_no: number
          material_id: string
          notes: string | null
          price_provenance: Json | null
          price_source: string | null
          quantity: number
          quote_id: string
          unit_price: number
        }
        Insert: {
          created_at?: string
          id?: string
          line_no: number
          material_id: string
          notes?: string | null
          price_provenance?: Json | null
          price_source?: string | null
          quantity: number
          quote_id: string
          unit_price: number
        }
        Update: {
          created_at?: string
          id?: string
          line_no?: number
          material_id?: string
          notes?: string | null
          price_provenance?: Json | null
          price_source?: string | null
          quantity?: number
          quote_id?: string
          unit_price?: number
        }
        Relationships: [
          {
            foreignKeyName: "quote_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "quote_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "quote_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "quote_lines_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: false
            referencedRelation: "quote_status"
            referencedColumns: ["quote_id"]
          },
          {
            foreignKeyName: "quote_lines_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: false
            referencedRelation: "quotes"
            referencedColumns: ["id"]
          },
        ]
      }
      quotes: {
        Row: {
          code: string
          converted_order_id: string | null
          created_at: string
          created_by: string | null
          currency: string
          customer_id: string
          decline_reason: string | null
          delete_reason: string | null
          deleted_at: string | null
          deleted_by: string | null
          fx_rate: number
          id: string
          notes: string | null
          quote_date: string
          status: string
          terms_text: string | null
          updated_at: string
          updated_by: string | null
          valid_until: string
        }
        Insert: {
          code: string
          converted_order_id?: string | null
          created_at?: string
          created_by?: string | null
          currency: string
          customer_id: string
          decline_reason?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          fx_rate: number
          id?: string
          notes?: string | null
          quote_date: string
          status?: string
          terms_text?: string | null
          updated_at?: string
          updated_by?: string | null
          valid_until: string
        }
        Update: {
          code?: string
          converted_order_id?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          customer_id?: string
          decline_reason?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          fx_rate?: number
          id?: string
          notes?: string | null
          quote_date?: string
          status?: string
          terms_text?: string | null
          updated_at?: string
          updated_by?: string | null
          valid_until?: string
        }
        Relationships: [
          {
            foreignKeyName: "quotes_converted_order_id_fkey"
            columns: ["converted_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "quotes_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "quotes_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "quotes_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      receiving_settings: {
        Row: {
          grn_assay_tolerance_pct: number
          grn_over_pct: number
          grn_short_pct: number
          id: boolean
          notes: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          grn_assay_tolerance_pct?: number
          grn_over_pct?: number
          grn_short_pct?: number
          id?: boolean
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          grn_assay_tolerance_pct?: number
          grn_over_pct?: number
          grn_short_pct?: number
          id?: boolean
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      review_cycles: {
        Row: {
          created_at: string
          created_by: string | null
          deleted_at: string | null
          due_date: string
          id: string
          name: string
          notes: string | null
          period_end: string
          period_start: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          due_date: string
          id?: string
          name: string
          notes?: string | null
          period_end: string
          period_start: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          due_date?: string
          id?: string
          name?: string
          notes?: string | null
          period_end?: string
          period_start?: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      review_goals: {
        Row: {
          actual_value: number | null
          created_at: string
          created_by: string | null
          employee_result_text: string | null
          id: string
          objective_text: string
          review_id: string
          reviewer_assessment_text: string | null
          sequence: number
          target_value: number | null
          unit: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          actual_value?: number | null
          created_at?: string
          created_by?: string | null
          employee_result_text?: string | null
          id?: string
          objective_text: string
          review_id: string
          reviewer_assessment_text?: string | null
          sequence: number
          target_value?: number | null
          unit?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          actual_value?: number | null
          created_at?: string
          created_by?: string | null
          employee_result_text?: string | null
          id?: string
          objective_text?: string
          review_id?: string
          reviewer_assessment_text?: string | null
          sequence?: number
          target_value?: number | null
          unit?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["review_id"]
          },
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "my_self_assessment"
            referencedColumns: ["review_id"]
          },
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "performance_reviews"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "performance_reviews_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      review_rating_scale: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          description_en: string | null
          description_zh: string | null
          is_active: boolean
          is_probation_pass: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          description_en?: string | null
          description_zh?: string | null
          is_active?: boolean
          is_probation_pass?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          description_en?: string | null
          description_zh?: string | null
          is_active?: boolean
          is_probation_pass?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      role_permissions: {
        Row: {
          created_at: string
          created_by: string | null
          permission_code: string
          role_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          permission_code: string
          role_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          permission_code?: string
          role_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "role_permissions_permission_code_fkey"
            columns: ["permission_code"]
            isOneToOne: false
            referencedRelation: "permissions"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "role_permissions_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["id"]
          },
        ]
      }
      roles: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          description_en: string | null
          description_zh: string | null
          id: string
          is_active: boolean
          is_system: boolean
          name_en: string
          name_zh: string
          sort_order: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          description_en?: string | null
          description_zh?: string | null
          id?: string
          is_active?: boolean
          is_system?: boolean
          name_en: string
          name_zh: string
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          description_en?: string | null
          description_zh?: string | null
          id?: string
          is_active?: boolean
          is_system?: boolean
          name_en?: string
          name_zh?: string
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      sales_attribution_log: {
        Row: {
          amount_base: number
          attributed_at: string
          attributed_by: string | null
          customer_id: string
          exposure_after: number
          id: string
          note: string | null
          sales_record_id: string
        }
        Insert: {
          amount_base: number
          attributed_at?: string
          attributed_by?: string | null
          customer_id: string
          exposure_after: number
          id?: string
          note?: string | null
          sales_record_id: string
        }
        Update: {
          amount_base?: number
          attributed_at?: string
          attributed_by?: string | null
          customer_id?: string
          exposure_after?: number
          id?: string
          note?: string | null
          sales_record_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sales_attribution_log_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "sales_attribution_log_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_attribution_log_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_attribution_log_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_attribution_log_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_visible"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_order_history: {
        Row: {
          amend_reason: string | null
          change_type: string
          changed_at: string
          changed_by: string | null
          detail: string | null
          id: string
          line_no: number | null
          new_notes: string | null
          new_quantity: number | null
          new_terms_text: string | null
          new_unit_price: number | null
          old_notes: string | null
          old_quantity: number | null
          old_terms_text: string | null
          old_unit_price: number | null
          sales_order_id: string
          sales_order_line_id: string | null
        }
        Insert: {
          amend_reason?: string | null
          change_type: string
          changed_at?: string
          changed_by?: string | null
          detail?: string | null
          id?: string
          line_no?: number | null
          new_notes?: string | null
          new_quantity?: number | null
          new_terms_text?: string | null
          new_unit_price?: number | null
          old_notes?: string | null
          old_quantity?: number | null
          old_terms_text?: string | null
          old_unit_price?: number | null
          sales_order_id: string
          sales_order_line_id?: string | null
        }
        Update: {
          amend_reason?: string | null
          change_type?: string
          changed_at?: string
          changed_by?: string | null
          detail?: string | null
          id?: string
          line_no?: number | null
          new_notes?: string | null
          new_quantity?: number | null
          new_terms_text?: string | null
          new_unit_price?: number | null
          old_notes?: string | null
          old_quantity?: number | null
          old_terms_text?: string | null
          old_unit_price?: number | null
          sales_order_id?: string
          sales_order_line_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "sales_order_history_sales_order_id_fkey"
            columns: ["sales_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_order_lines: {
        Row: {
          created_at: string
          id: string
          line_no: number
          material_id: string
          notes: string | null
          price_provenance: Json | null
          price_source: string | null
          quantity: number
          sales_order_id: string
          unit_price: number
        }
        Insert: {
          created_at?: string
          id?: string
          line_no: number
          material_id: string
          notes?: string | null
          price_provenance?: Json | null
          price_source?: string | null
          quantity: number
          sales_order_id: string
          unit_price: number
        }
        Update: {
          created_at?: string
          id?: string
          line_no?: number
          material_id?: string
          notes?: string | null
          price_provenance?: Json | null
          price_source?: string | null
          quantity?: number
          sales_order_id?: string
          unit_price?: number
        }
        Relationships: [
          {
            foreignKeyName: "sales_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "sales_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "sales_order_lines_sales_order_id_fkey"
            columns: ["sales_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_order_reservations: {
        Row: {
          consumed_at: string | null
          consumed_by: string | null
          created_at: string
          created_by: string | null
          id: string
          location_id: string | null
          output_batch_id: string
          pair_id: string
          qty: number
          release_pair_id: string | null
          release_reason: string | null
          released_at: string | null
          released_by: string | null
          sales_order_line_id: string
        }
        Insert: {
          consumed_at?: string | null
          consumed_by?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          location_id?: string | null
          output_batch_id: string
          pair_id: string
          qty: number
          release_pair_id?: string | null
          release_reason?: string | null
          released_at?: string | null
          released_by?: string | null
          sales_order_line_id: string
        }
        Update: {
          consumed_at?: string | null
          consumed_by?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          location_id?: string | null
          output_batch_id?: string
          pair_id?: string
          qty?: number
          release_pair_id?: string | null
          release_reason?: string | null
          released_at?: string | null
          released_by?: string | null
          sales_order_line_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sales_order_reservations_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "storage_locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_order_reservations_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "sales_order_reservations_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_order_reservations_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_order_reservations_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "sales_order_reservations_sales_order_line_id_fkey"
            columns: ["sales_order_line_id"]
            isOneToOne: false
            referencedRelation: "sales_order_lines"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_orders: {
        Row: {
          cancel_reason: string | null
          cancelled_at: string | null
          closed_at: string | null
          code: string
          confirmed_at: string | null
          contract_id: string | null
          created_at: string
          created_by: string | null
          currency: string
          customer_id: string
          delete_reason: string | null
          deleted_at: string | null
          deleted_by: string | null
          fx_rate: number
          id: string
          notes: string | null
          order_date: string
          status: string
          terms_text: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          cancel_reason?: string | null
          cancelled_at?: string | null
          closed_at?: string | null
          code: string
          confirmed_at?: string | null
          contract_id?: string | null
          created_at?: string
          created_by?: string | null
          currency: string
          customer_id: string
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          fx_rate: number
          id?: string
          notes?: string | null
          order_date: string
          status?: string
          terms_text?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          cancel_reason?: string | null
          cancelled_at?: string | null
          closed_at?: string | null
          code?: string
          confirmed_at?: string | null
          contract_id?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          customer_id?: string
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          fx_rate?: number
          id?: string
          notes?: string | null
          order_date?: string
          status?: string
          terms_text?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "sales_orders_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: false
            referencedRelation: "contracts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_orders_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "sales_orders_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "sales_orders_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_record_movements: {
        Row: {
          created_at: string
          id: string
          movement_id: string
          sales_record_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          movement_id: string
          sales_record_id: string
        }
        Update: {
          created_at?: string
          id?: string
          movement_id?: string
          sales_record_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sales_record_movements_movement_id_fkey"
            columns: ["movement_id"]
            isOneToOne: true
            referencedRelation: "inventory_movements"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_record_movements_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_record_movements_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_record_movements_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_visible"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_records: {
        Row: {
          amount_base: number
          cogs_entry_id: string | null
          created_at: string | null
          created_by: string | null
          currency: string
          customer_id: string | null
          fx_rate: number
          id: string
          notes: string | null
          output_batch_id: string
          price_provenance: Json | null
          price_source: string | null
          quantity: number
          sale_date: string
          sales_order_line_id: string | null
          unit_price: number
        }
        Insert: {
          amount_base: number
          cogs_entry_id?: string | null
          created_at?: string | null
          created_by?: string | null
          currency: string
          customer_id?: string | null
          fx_rate: number
          id?: string
          notes?: string | null
          output_batch_id: string
          price_provenance?: Json | null
          price_source?: string | null
          quantity: number
          sale_date: string
          sales_order_line_id?: string | null
          unit_price: number
        }
        Update: {
          amount_base?: number
          cogs_entry_id?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string
          customer_id?: string | null
          fx_rate?: number
          id?: string
          notes?: string | null
          output_batch_id?: string
          price_provenance?: Json | null
          price_source?: string | null
          quantity?: number
          sale_date?: string
          sales_order_line_id?: string | null
          unit_price?: number
        }
        Relationships: [
          {
            foreignKeyName: "sales_records_cogs_entry_id_fkey"
            columns: ["cogs_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "sales_records_cogs_entry_id_fkey"
            columns: ["cogs_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "sales_records_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "sales_records_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "sales_records_sales_order_line_id_fkey"
            columns: ["sales_order_line_id"]
            isOneToOne: false
            referencedRelation: "sales_order_lines"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_settlements: {
        Row: {
          amount_usd: number
          assay_result_id: string
          breakdown: Json
          computed_at: string
          computed_by: string | null
          gross_weight_kg: number
          id: string
          metal_value_usd: number
          moisture_pct: number | null
          output_batch_id: string
          penalty_usd: number
          refining_charge_usd: number
          sales_order_id: string
          settlement_weight_kg: number
          settling_party_used: string
          superseded_by: string | null
          terms_snapshot: Json
          weight_basis_used: string
        }
        Insert: {
          amount_usd: number
          assay_result_id: string
          breakdown: Json
          computed_at?: string
          computed_by?: string | null
          gross_weight_kg: number
          id?: string
          metal_value_usd: number
          moisture_pct?: number | null
          output_batch_id: string
          penalty_usd: number
          refining_charge_usd: number
          sales_order_id: string
          settlement_weight_kg: number
          settling_party_used: string
          superseded_by?: string | null
          terms_snapshot: Json
          weight_basis_used: string
        }
        Update: {
          amount_usd?: number
          assay_result_id?: string
          breakdown?: Json
          computed_at?: string
          computed_by?: string | null
          gross_weight_kg?: number
          id?: string
          metal_value_usd?: number
          moisture_pct?: number | null
          output_batch_id?: string
          penalty_usd?: number
          refining_charge_usd?: number
          sales_order_id?: string
          settlement_weight_kg?: number
          settling_party_used?: string
          superseded_by?: string | null
          terms_snapshot?: Json
          weight_basis_used?: string
        }
        Relationships: [
          {
            foreignKeyName: "sales_settlements_assay_result_id_fkey"
            columns: ["assay_result_id"]
            isOneToOne: false
            referencedRelation: "assay_results"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_settlements_assay_result_id_fkey"
            columns: ["assay_result_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["assay_result_id"]
          },
          {
            foreignKeyName: "sales_settlements_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "sales_settlements_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_settlements_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_settlements_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "sales_settlements_sales_order_id_fkey"
            columns: ["sales_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_settlements_superseded_by_fkey"
            columns: ["superseded_by"]
            isOneToOne: false
            referencedRelation: "sales_settlements"
            referencedColumns: ["id"]
          },
        ]
      }
      shift_handover_equipment_refs: {
        Row: {
          created_at: string
          created_by: string | null
          downtime_id: string
          handover_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          downtime_id: string
          handover_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          downtime_id?: string
          handover_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shift_handover_equipment_refs_downtime_id_fkey"
            columns: ["downtime_id"]
            isOneToOne: false
            referencedRelation: "equipment_downtime"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_handover_equipment_refs_handover_id_fkey"
            columns: ["handover_id"]
            isOneToOne: false
            referencedRelation: "shift_handovers"
            referencedColumns: ["id"]
          },
        ]
      }
      shift_handover_items: {
        Row: {
          body: string
          created_at: string
          created_by: string | null
          handover_id: string
          id: string
          item_type_code: string
          sort_order: number
        }
        Insert: {
          body: string
          created_at?: string
          created_by?: string | null
          handover_id: string
          id?: string
          item_type_code: string
          sort_order?: number
        }
        Update: {
          body?: string
          created_at?: string
          created_by?: string | null
          handover_id?: string
          id?: string
          item_type_code?: string
          sort_order?: number
        }
        Relationships: [
          {
            foreignKeyName: "shift_handover_items_handover_id_fkey"
            columns: ["handover_id"]
            isOneToOne: false
            referencedRelation: "shift_handovers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_handover_items_item_type_code_fkey"
            columns: ["item_type_code"]
            isOneToOne: false
            referencedRelation: "handover_item_types"
            referencedColumns: ["code"]
          },
        ]
      }
      shift_handovers: {
        Row: {
          acknowledged_at: string | null
          acknowledged_by: string | null
          created_at: string
          created_by: string | null
          handover_date: string
          id: string
          incoming_employee_id: string
          notes: string | null
          outgoing_employee_id: string
          shift_code: string
          submitted_at: string
          submitted_by: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          acknowledged_at?: string | null
          acknowledged_by?: string | null
          created_at?: string
          created_by?: string | null
          handover_date: string
          id?: string
          incoming_employee_id: string
          notes?: string | null
          outgoing_employee_id: string
          shift_code: string
          submitted_at?: string
          submitted_by?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          acknowledged_at?: string | null
          acknowledged_by?: string | null
          created_at?: string
          created_by?: string | null
          handover_date?: string
          id?: string
          incoming_employee_id?: string
          notes?: string | null
          outgoing_employee_id?: string
          shift_code?: string
          submitted_at?: string
          submitted_by?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "shift_handovers_acknowledged_by_fkey"
            columns: ["acknowledged_by"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_acknowledged_by_fkey"
            columns: ["acknowledged_by"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_handovers_acknowledged_by_fkey"
            columns: ["acknowledged_by"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_handovers_acknowledged_by_fkey"
            columns: ["acknowledged_by"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_handovers_acknowledged_by_fkey"
            columns: ["acknowledged_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_acknowledged_by_fkey"
            columns: ["acknowledged_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_acknowledged_by_fkey"
            columns: ["acknowledged_by"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_acknowledged_by_fkey"
            columns: ["acknowledged_by"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_acknowledged_by_fkey"
            columns: ["acknowledged_by"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_acknowledged_by_fkey"
            columns: ["acknowledged_by"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_acknowledged_by_fkey"
            columns: ["acknowledged_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_incoming_employee_id_fkey"
            columns: ["incoming_employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_incoming_employee_id_fkey"
            columns: ["incoming_employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_handovers_incoming_employee_id_fkey"
            columns: ["incoming_employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_handovers_incoming_employee_id_fkey"
            columns: ["incoming_employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_handovers_incoming_employee_id_fkey"
            columns: ["incoming_employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_incoming_employee_id_fkey"
            columns: ["incoming_employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_incoming_employee_id_fkey"
            columns: ["incoming_employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_incoming_employee_id_fkey"
            columns: ["incoming_employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_incoming_employee_id_fkey"
            columns: ["incoming_employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_incoming_employee_id_fkey"
            columns: ["incoming_employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_incoming_employee_id_fkey"
            columns: ["incoming_employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_outgoing_employee_id_fkey"
            columns: ["outgoing_employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_outgoing_employee_id_fkey"
            columns: ["outgoing_employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_handovers_outgoing_employee_id_fkey"
            columns: ["outgoing_employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_handovers_outgoing_employee_id_fkey"
            columns: ["outgoing_employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_handovers_outgoing_employee_id_fkey"
            columns: ["outgoing_employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_outgoing_employee_id_fkey"
            columns: ["outgoing_employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_outgoing_employee_id_fkey"
            columns: ["outgoing_employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_outgoing_employee_id_fkey"
            columns: ["outgoing_employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_outgoing_employee_id_fkey"
            columns: ["outgoing_employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_outgoing_employee_id_fkey"
            columns: ["outgoing_employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_outgoing_employee_id_fkey"
            columns: ["outgoing_employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "shift_handovers_shift_code_fkey"
            columns: ["shift_code"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["code"]
          },
        ]
      }
      shifts: {
        Row: {
          code: string
          created_at: string
          ends_at: string | null
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
          starts_at: string | null
          updated_at: string
        }
        Insert: {
          code: string
          created_at?: string
          ends_at?: string | null
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
          starts_at?: string | null
          updated_at?: string
        }
        Update: {
          code?: string
          created_at?: string
          ends_at?: string | null
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
          starts_at?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      shipment_issues: {
        Row: {
          file_path: string
          id: string
          issued_at: string
          issued_by: string | null
          sha256: string
          shipment_id: string
          version: number
        }
        Insert: {
          file_path: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          sha256: string
          shipment_id: string
          version: number
        }
        Update: {
          file_path?: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          sha256?: string
          shipment_id?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "shipment_issues_shipment_id_fkey"
            columns: ["shipment_id"]
            isOneToOne: false
            referencedRelation: "shipments"
            referencedColumns: ["id"]
          },
        ]
      }
      shipment_lines: {
        Row: {
          created_at: string
          id: string
          location_id: string | null
          output_batch_id: string
          qty: number
          reservation_id: string
          sales_order_line_id: string
          sales_record_id: string
          shipment_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          location_id?: string | null
          output_batch_id: string
          qty: number
          reservation_id: string
          sales_order_line_id: string
          sales_record_id: string
          shipment_id: string
        }
        Update: {
          created_at?: string
          id?: string
          location_id?: string | null
          output_batch_id?: string
          qty?: number
          reservation_id?: string
          sales_order_line_id?: string
          sales_record_id?: string
          shipment_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shipment_lines_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "storage_locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "shipment_lines_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "shipment_lines_reservation_id_fkey"
            columns: ["reservation_id"]
            isOneToOne: true
            referencedRelation: "sales_order_reservations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_sales_order_line_id_fkey"
            columns: ["sales_order_line_id"]
            isOneToOne: false
            referencedRelation: "sales_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_visible"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_shipment_id_fkey"
            columns: ["shipment_id"]
            isOneToOne: false
            referencedRelation: "shipments"
            referencedColumns: ["id"]
          },
        ]
      }
      shipments: {
        Row: {
          code: string
          container_id: string | null
          created_at: string
          created_by: string | null
          id: string
          notes: string | null
          sales_order_id: string
          ship_date: string
        }
        Insert: {
          code: string
          container_id?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          notes?: string | null
          sales_order_id: string
          ship_date: string
        }
        Update: {
          code?: string
          container_id?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          notes?: string | null
          sales_order_id?: string
          ship_date?: string
        }
        Relationships: [
          {
            foreignKeyName: "shipments_container_id_fkey"
            columns: ["container_id"]
            isOneToOne: false
            referencedRelation: "container_overview"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipments_container_id_fkey"
            columns: ["container_id"]
            isOneToOne: false
            referencedRelation: "containers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipments_sales_order_id_fkey"
            columns: ["sales_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      so_issues: {
        Row: {
          file_path: string
          id: string
          issued_at: string
          issued_by: string | null
          sales_order_id: string
          sha256: string
          version: number
        }
        Insert: {
          file_path: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          sales_order_id: string
          sha256: string
          version: number
        }
        Update: {
          file_path?: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          sales_order_id?: string
          sha256?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "so_issues_sales_order_id_fkey"
            columns: ["sales_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      statement_issues: {
        Row: {
          file_path: string
          id: string
          issued_at: string
          issued_by: string | null
          sha256: string
          statement_id: string
          version: number
        }
        Insert: {
          file_path: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          sha256: string
          statement_id: string
          version: number
        }
        Update: {
          file_path?: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          sha256?: string
          statement_id?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "statement_issues_statement_id_fkey"
            columns: ["statement_id"]
            isOneToOne: false
            referencedRelation: "customer_statements"
            referencedColumns: ["id"]
          },
        ]
      }
      stocktake_lines: {
        Row: {
          book_qty: number
          counted_at: string
          counted_qty: number
          created_by: string | null
          id: string
          inbound_batch_id: string | null
          notes: string | null
          output_batch_id: string | null
          stocktake_id: string
        }
        Insert: {
          book_qty: number
          counted_at?: string
          counted_qty: number
          created_by?: string | null
          id?: string
          inbound_batch_id?: string | null
          notes?: string | null
          output_batch_id?: string | null
          stocktake_id: string
        }
        Update: {
          book_qty?: number
          counted_at?: string
          counted_qty?: number
          created_by?: string | null
          id?: string
          inbound_batch_id?: string | null
          notes?: string | null
          output_batch_id?: string | null
          stocktake_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "stocktake_lines_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "stocktake_lines_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "stocktake_lines_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "stocktake_lines_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "stocktake_lines_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stocktake_lines_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stocktake_lines_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "stocktake_lines_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "stocktake_lines_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stocktake_lines_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stocktake_lines_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "stocktake_lines_stocktake_id_fkey"
            columns: ["stocktake_id"]
            isOneToOne: false
            referencedRelation: "stocktakes"
            referencedColumns: ["id"]
          },
        ]
      }
      stocktakes: {
        Row: {
          cancel_reason: string | null
          cancelled_at: string | null
          cancelled_by: string | null
          code: string
          created_at: string
          created_by: string | null
          delete_reason: string | null
          deleted_at: string | null
          deleted_by: string | null
          id: string
          notes: string | null
          posted_at: string | null
          started_at: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          id?: string
          notes?: string | null
          posted_at?: string | null
          started_at?: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          id?: string
          notes?: string | null
          posted_at?: string | null
          started_at?: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      storage_location_allowed_classes: {
        Row: {
          classification_code: string
          created_at: string
          created_by: string | null
          id: string
          location_id: string
        }
        Insert: {
          classification_code: string
          created_at?: string
          created_by?: string | null
          id?: string
          location_id: string
        }
        Update: {
          classification_code?: string
          created_at?: string
          created_by?: string | null
          id?: string
          location_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "storage_location_allowed_classes_classification_code_fkey"
            columns: ["classification_code"]
            isOneToOne: false
            referencedRelation: "waste_classifications"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "storage_location_allowed_classes_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "storage_locations"
            referencedColumns: ["id"]
          },
        ]
      }
      storage_locations: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          id: string
          is_active: boolean
          name: string
          notes: string | null
          updated_at: string
          updated_by: string | null
          zone: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          name: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          zone?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          name?: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          zone?: string | null
        }
        Relationships: []
      }
      substances: {
        Row: {
          code: string
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
          symbol: string | null
        }
        Insert: {
          code: string
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
          symbol?: string | null
        }
        Update: {
          code?: string
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
          symbol?: string | null
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
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
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
          cert_type_code: string
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
          cert_type_code: string
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
          cert_type_code?: string
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
            foreignKeyName: "supplier_compliance_cert_type_code_fkey"
            columns: ["cert_type_code"]
            isOneToOne: false
            referencedRelation: "certificate_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "supplier_compliance_cert_type_code_fkey"
            columns: ["cert_type_code"]
            isOneToOne: false
            referencedRelation: "supplier_receiving_blocked"
            referencedColumns: ["cert_type_code"]
          },
          {
            foreignKeyName: "supplier_compliance_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "supplier_compliance_document_fkey"
            columns: ["document_id"]
            isOneToOne: false
            referencedRelation: "supplier_attachments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_compliance_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "supplier_compliance_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_compliance_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
        ]
      }
      suppliers: {
        Row: {
          address: string | null
          code: string
          counterparty_type: string
          country: string
          created_at: string
          created_by: string | null
          credit_rating: string | null
          default_payment_term_template_id: string | null
          default_tax_code: string | null
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
          supplies_goods: boolean | null
          tax_id: string | null
          tax_residence: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          address?: string | null
          code: string
          counterparty_type: string
          country: string
          created_at?: string
          created_by?: string | null
          credit_rating?: string | null
          default_payment_term_template_id?: string | null
          default_tax_code?: string | null
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
          supplies_goods?: boolean | null
          tax_id?: string | null
          tax_residence?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          address?: string | null
          code?: string
          counterparty_type?: string
          country?: string
          created_at?: string
          created_by?: string | null
          credit_rating?: string | null
          default_payment_term_template_id?: string | null
          default_tax_code?: string | null
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
          supplies_goods?: boolean | null
          tax_id?: string | null
          tax_residence?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "suppliers_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "suppliers_default_payment_term_template_id_fkey"
            columns: ["default_payment_term_template_id"]
            isOneToOne: false
            referencedRelation: "payment_term_templates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "suppliers_default_tax_code_fkey"
            columns: ["default_tax_code"]
            isOneToOne: false
            referencedRelation: "tax_codes"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "suppliers_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "suppliers_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
        ]
      }
      task_history: {
        Row: {
          change_type: string
          changed_at: string
          changed_by: string | null
          employee_id: string | null
          id: string
          new_description: string | null
          new_due_date: string | null
          new_node_done: boolean | null
          new_node_target_date: string | null
          new_node_title: string | null
          new_priority: string | null
          new_reminder_at: string | null
          new_sort_order: number | null
          new_status: string | null
          new_tags: string[] | null
          new_title: string | null
          node_id: string | null
          old_description: string | null
          old_due_date: string | null
          old_node_done: boolean | null
          old_node_target_date: string | null
          old_node_title: string | null
          old_priority: string | null
          old_reminder_at: string | null
          old_sort_order: number | null
          old_status: string | null
          old_tags: string[] | null
          old_title: string | null
          task_id: string
        }
        Insert: {
          change_type: string
          changed_at?: string
          changed_by?: string | null
          employee_id?: string | null
          id?: string
          new_description?: string | null
          new_due_date?: string | null
          new_node_done?: boolean | null
          new_node_target_date?: string | null
          new_node_title?: string | null
          new_priority?: string | null
          new_reminder_at?: string | null
          new_sort_order?: number | null
          new_status?: string | null
          new_tags?: string[] | null
          new_title?: string | null
          node_id?: string | null
          old_description?: string | null
          old_due_date?: string | null
          old_node_done?: boolean | null
          old_node_target_date?: string | null
          old_node_title?: string | null
          old_priority?: string | null
          old_reminder_at?: string | null
          old_sort_order?: number | null
          old_status?: string | null
          old_tags?: string[] | null
          old_title?: string | null
          task_id: string
        }
        Update: {
          change_type?: string
          changed_at?: string
          changed_by?: string | null
          employee_id?: string | null
          id?: string
          new_description?: string | null
          new_due_date?: string | null
          new_node_done?: boolean | null
          new_node_target_date?: string | null
          new_node_title?: string | null
          new_priority?: string | null
          new_reminder_at?: string | null
          new_sort_order?: number | null
          new_status?: string | null
          new_tags?: string[] | null
          new_title?: string | null
          node_id?: string | null
          old_description?: string | null
          old_due_date?: string | null
          old_node_done?: boolean | null
          old_node_target_date?: string | null
          old_node_title?: string | null
          old_priority?: string | null
          old_reminder_at?: string | null
          old_sort_order?: number | null
          old_status?: string | null
          old_tags?: string[] | null
          old_title?: string | null
          task_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "task_history_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_history_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_history_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_history_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_history_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "task_board_rows"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_history_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      task_nodes: {
        Row: {
          created_at: string
          created_by: string | null
          depth: number
          done: boolean
          done_at: string | null
          done_by: string | null
          id: string
          parent_depth: number | null
          parent_id: string | null
          sort_order: number
          target_date: string | null
          task_id: string
          title: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          depth?: number
          done?: boolean
          done_at?: string | null
          done_by?: string | null
          id?: string
          parent_depth?: number | null
          parent_id?: string | null
          sort_order: number
          target_date?: string | null
          task_id: string
          title: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          depth?: number
          done?: boolean
          done_at?: string | null
          done_by?: string | null
          id?: string
          parent_depth?: number | null
          parent_id?: string | null
          sort_order?: number
          target_date?: string | null
          task_id?: string
          title?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "task_nodes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_nodes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_nodes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_nodes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_done_by_fkey"
            columns: ["done_by"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_done_by_fkey"
            columns: ["done_by"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_nodes_done_by_fkey"
            columns: ["done_by"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_nodes_done_by_fkey"
            columns: ["done_by"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_nodes_done_by_fkey"
            columns: ["done_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_done_by_fkey"
            columns: ["done_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_done_by_fkey"
            columns: ["done_by"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_done_by_fkey"
            columns: ["done_by"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_done_by_fkey"
            columns: ["done_by"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_done_by_fkey"
            columns: ["done_by"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_done_by_fkey"
            columns: ["done_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_parent_id_task_id_parent_depth_fkey"
            columns: ["parent_id", "task_id", "parent_depth"]
            isOneToOne: false
            referencedRelation: "task_nodes"
            referencedColumns: ["id", "task_id", "depth"]
          },
          {
            foreignKeyName: "task_nodes_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "task_board_rows"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_nodes_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "tasks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_nodes_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_nodes_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_nodes_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_nodes_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_nodes_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      task_participants: {
        Row: {
          added_at: string
          added_by: string
          employee_id: string
          id: string
          removed_at: string | null
          removed_by: string | null
          task_id: string
        }
        Insert: {
          added_at?: string
          added_by: string
          employee_id: string
          id?: string
          removed_at?: string | null
          removed_by?: string | null
          task_id: string
        }
        Update: {
          added_at?: string
          added_by?: string
          employee_id?: string
          id?: string
          removed_at?: string | null
          removed_by?: string | null
          task_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "task_board_rows"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      tasks: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          description: string | null
          due_date: string | null
          id: string
          owner_id: string | null
          priority: string
          reminder_at: string | null
          status: string
          tags: string[] | null
          task_type: string
          title: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          description?: string | null
          due_date?: string | null
          id?: string
          owner_id?: string | null
          priority?: string
          reminder_at?: string | null
          status?: string
          tags?: string[] | null
          task_type?: string
          title: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          description?: string | null
          due_date?: string | null
          id?: string
          owner_id?: string | null
          priority?: string
          reminder_at?: string | null
          status?: string
          tags?: string[] | null
          task_type?: string
          title?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      tax_codes: {
        Row: {
          code: string
          description_en: string | null
          description_zh: string | null
          f5_purchase_box: string | null
          f5_supply_box: string | null
          f5_tax_box: string | null
          is_active: boolean
          is_claimable: boolean
          name_en: string
          name_zh: string
          side: string
          sort_order: number
        }
        Insert: {
          code: string
          description_en?: string | null
          description_zh?: string | null
          f5_purchase_box?: string | null
          f5_supply_box?: string | null
          f5_tax_box?: string | null
          is_active?: boolean
          is_claimable?: boolean
          name_en: string
          name_zh: string
          side: string
          sort_order?: number
        }
        Update: {
          code?: string
          description_en?: string | null
          description_zh?: string | null
          f5_purchase_box?: string | null
          f5_supply_box?: string | null
          f5_tax_box?: string | null
          is_active?: boolean
          is_claimable?: boolean
          name_en?: string
          name_zh?: string
          side?: string
          sort_order?: number
        }
        Relationships: []
      }
      tax_rates: {
        Row: {
          created_at: string
          effective_from: string
          effective_to: string | null
          id: string
          note: string | null
          rate_pct: number
          tax_code: string
        }
        Insert: {
          created_at?: string
          effective_from: string
          effective_to?: string | null
          id?: string
          note?: string | null
          rate_pct: number
          tax_code: string
        }
        Update: {
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          id?: string
          note?: string | null
          rate_pct?: number
          tax_code?: string
        }
        Relationships: [
          {
            foreignKeyName: "tax_rates_tax_code_fkey"
            columns: ["tax_code"]
            isOneToOne: false
            referencedRelation: "tax_codes"
            referencedColumns: ["code"]
          },
        ]
      }
      traceability_report_issues: {
        Row: {
          code: string
          file_path: string
          id: string
          issued_at: string
          issued_by: string | null
          output_batch_id: string
          sha256: string
          version: number
        }
        Insert: {
          code: string
          file_path: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          output_batch_id: string
          sha256: string
          version: number
        }
        Update: {
          code?: string
          file_path?: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          output_batch_id?: string
          sha256?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "traceability_report_issues_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "traceability_report_issues_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "traceability_report_issues_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "traceability_report_issues_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
        ]
      }
      training_records: {
        Row: {
          category: string | null
          certificate_ref: string | null
          completed_date: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          employee_id: string
          expiry_date: string | null
          id: string
          notes: string | null
          provider: string | null
          training_name: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          category?: string | null
          certificate_ref?: string | null
          completed_date: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          employee_id: string
          expiry_date?: string | null
          id?: string
          notes?: string | null
          provider?: string | null
          training_name: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          category?: string | null
          certificate_ref?: string | null
          completed_date?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          employee_id?: string
          expiry_date?: string | null
          id?: string
          notes?: string | null
          provider?: string | null
          training_name?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      user_dock: {
        Row: {
          collapsed: boolean
          created_at: string
          hrefs: string[] | null
          updated_at: string
          user_id: string
        }
        Insert: {
          collapsed?: boolean
          created_at?: string
          hrefs?: string[] | null
          updated_at?: string
          user_id: string
        }
        Update: {
          collapsed?: boolean
          created_at?: string
          hrefs?: string[] | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_dock_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
        ]
      }
      user_roles: {
        Row: {
          granted_at: string
          granted_by: string | null
          id: string
          revoke_reason: string | null
          revoked_at: string | null
          revoked_by: string | null
          role_id: string
          user_id: string
        }
        Insert: {
          granted_at?: string
          granted_by?: string | null
          id?: string
          revoke_reason?: string | null
          revoked_at?: string | null
          revoked_by?: string | null
          role_id: string
          user_id: string
        }
        Update: {
          granted_at?: string
          granted_by?: string | null
          id?: string
          revoke_reason?: string | null
          revoked_at?: string | null
          revoked_by?: string | null
          role_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_roles_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["id"]
          },
        ]
      }
      waste_classifications: {
        Row: {
          code: string
          created_at: string
          is_active: boolean
          is_controlled: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          is_active?: boolean
          is_controlled: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          is_active?: boolean
          is_controlled?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      wht_natures: {
        Row: {
          code: string
          description_en: string | null
          description_zh: string | null
          is_active: boolean
          name_en: string
          name_zh: string
          sort_order: number
          statute_ref: string
        }
        Insert: {
          code: string
          description_en?: string | null
          description_zh?: string | null
          is_active?: boolean
          name_en: string
          name_zh: string
          sort_order?: number
          statute_ref: string
        }
        Update: {
          code?: string
          description_en?: string | null
          description_zh?: string | null
          is_active?: boolean
          name_en?: string
          name_zh?: string
          sort_order?: number
          statute_ref?: string
        }
        Relationships: []
      }
      wht_rates: {
        Row: {
          created_at: string
          effective_from: string
          effective_to: string | null
          id: string
          nature: string
          note: string
          rate_pct: number
        }
        Insert: {
          created_at?: string
          effective_from: string
          effective_to?: string | null
          id?: string
          nature: string
          note: string
          rate_pct: number
        }
        Update: {
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          id?: string
          nature?: string
          note?: string
          rate_pct?: number
        }
        Relationships: [
          {
            foreignKeyName: "wht_rates_nature_fkey"
            columns: ["nature"]
            isOneToOne: false
            referencedRelation: "wht_natures"
            referencedColumns: ["code"]
          },
        ]
      }
      wht_remittances: {
        Row: {
          amount_base: number
          code: string
          created_at: string
          created_by: string | null
          filed_reference: string
          id: string
          journal_entry_id: string
          notes: string | null
          period_month: string
          remitted_on: string
        }
        Insert: {
          amount_base: number
          code: string
          created_at?: string
          created_by?: string | null
          filed_reference: string
          id?: string
          journal_entry_id: string
          notes?: string | null
          period_month: string
          remitted_on: string
        }
        Update: {
          amount_base?: number
          code?: string
          created_at?: string
          created_by?: string | null
          filed_reference?: string
          id?: string
          journal_entry_id?: string
          notes?: string | null
          period_month?: string
          remitted_on?: string
        }
        Relationships: [
          {
            foreignKeyName: "wht_remittances_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "wht_remittances_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      work_order_expected_outputs: {
        Row: {
          basis: string | null
          basis_reference: string | null
          created_at: string
          expected_qty: number
          id: string
          material_id: string
          work_order_id: string
        }
        Insert: {
          basis?: string | null
          basis_reference?: string | null
          created_at?: string
          expected_qty: number
          id?: string
          material_id: string
          work_order_id: string
        }
        Update: {
          basis?: string | null
          basis_reference?: string | null
          created_at?: string
          expected_qty?: number
          id?: string
          material_id?: string
          work_order_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "work_order_expected_outputs_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "work_order_expected_outputs_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_order_expected_outputs_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "work_order_expected_outputs_work_order_id_fkey"
            columns: ["work_order_id"]
            isOneToOne: false
            referencedRelation: "work_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      work_order_history: {
        Row: {
          amend_reason: string | null
          change_type: string
          changed_at: string
          changed_by: string | null
          detail: string | null
          id: string
          material_id: string | null
          new_notes: string | null
          new_qty: number | null
          new_scheduled_date: string | null
          old_notes: string | null
          old_qty: number | null
          old_scheduled_date: string | null
          work_order_expected_id: string | null
          work_order_id: string
          work_order_line_id: string | null
        }
        Insert: {
          amend_reason?: string | null
          change_type: string
          changed_at?: string
          changed_by?: string | null
          detail?: string | null
          id?: string
          material_id?: string | null
          new_notes?: string | null
          new_qty?: number | null
          new_scheduled_date?: string | null
          old_notes?: string | null
          old_qty?: number | null
          old_scheduled_date?: string | null
          work_order_expected_id?: string | null
          work_order_id: string
          work_order_line_id?: string | null
        }
        Update: {
          amend_reason?: string | null
          change_type?: string
          changed_at?: string
          changed_by?: string | null
          detail?: string | null
          id?: string
          material_id?: string | null
          new_notes?: string | null
          new_qty?: number | null
          new_scheduled_date?: string | null
          old_notes?: string | null
          old_qty?: number | null
          old_scheduled_date?: string | null
          work_order_expected_id?: string | null
          work_order_id?: string
          work_order_line_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "work_order_history_work_order_id_fkey"
            columns: ["work_order_id"]
            isOneToOne: false
            referencedRelation: "work_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      work_order_lines: {
        Row: {
          created_at: string
          id: string
          material_id: string
          planned_qty: number
          work_order_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          material_id: string
          planned_qty: number
          work_order_id: string
        }
        Update: {
          created_at?: string
          id?: string
          material_id?: string
          planned_qty?: number
          work_order_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "work_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "work_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "work_order_lines_work_order_id_fkey"
            columns: ["work_order_id"]
            isOneToOne: false
            referencedRelation: "work_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      work_orders: {
        Row: {
          cancel_reason: string | null
          cancelled_at: string | null
          cancelled_by: string | null
          close_reason: string | null
          closed_at: string | null
          closed_by: string | null
          code: string
          created_at: string
          created_by: string | null
          id: string
          notes: string | null
          scheduled_date: string | null
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          close_reason?: string | null
          closed_at?: string | null
          closed_by?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          id?: string
          notes?: string | null
          scheduled_date?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          close_reason?: string | null
          closed_at?: string | null
          closed_by?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          id?: string
          notes?: string | null
          scheduled_date?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      year_closes: {
        Row: {
          closed_at: string
          closed_by: string | null
          closing_journal_id: string
          id: string
          net_result: number
          notes: string | null
          reopen_reason: string | null
          reopened_at: string | null
          reopened_by: string | null
          reversal_journal_id: string | null
          year_end: string
        }
        Insert: {
          closed_at?: string
          closed_by?: string | null
          closing_journal_id: string
          id?: string
          net_result: number
          notes?: string | null
          reopen_reason?: string | null
          reopened_at?: string | null
          reopened_by?: string | null
          reversal_journal_id?: string | null
          year_end: string
        }
        Update: {
          closed_at?: string
          closed_by?: string | null
          closing_journal_id?: string
          id?: string
          net_result?: number
          notes?: string | null
          reopen_reason?: string | null
          reopened_at?: string | null
          reopened_by?: string | null
          reversal_journal_id?: string | null
          year_end?: string
        }
        Relationships: [
          {
            foreignKeyName: "year_closes_closing_journal_id_fkey"
            columns: ["closing_journal_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "year_closes_closing_journal_id_fkey"
            columns: ["closing_journal_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "year_closes_reversal_journal_id_fkey"
            columns: ["reversal_journal_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "year_closes_reversal_journal_id_fkey"
            columns: ["reversal_journal_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      ap_open_items: {
        Row: {
          bucket: string | null
          counterparty_id: string | null
          counterparty_kind: string | null
          counterparty_name: string | null
          currency: string | null
          days_outstanding: number | null
          doc_code: string | null
          doc_date: string | null
          doc_id: string | null
          doc_kind: string | null
          doc_value_base: number | null
          inbound_batch_id: string | null
          open_base: number | null
          open_ccy: number | null
          settled_base: number | null
          supplier_id: string | null
          supplier_name: string | null
        }
        Relationships: []
      }
      ar_open_items: {
        Row: {
          amount_base: number | null
          amount_ccy: number | null
          bucket: string | null
          credited_base: number | null
          credited_ccy: number | null
          currency: string | null
          customer_id: string | null
          customer_name: string | null
          days_outstanding: number | null
          doc_code: string | null
          doc_kind: string | null
          invoice_code: string | null
          invoice_id: string | null
          open_base: number | null
          open_ccy: number | null
          sale_date: string | null
          sales_record_id: string | null
          settled_base: number | null
          settled_ccy: number | null
        }
        Relationships: []
      }
      attendance_period_status: {
        Row: {
          code: string | null
          completed_at: string | null
          line_count: number | null
          opened_at: string | null
          ot_normal_hours: number | null
          ot_public_holiday_hours: number | null
          ot_rest_day_hours: number | null
          payroll_posted: boolean | null
          period_id: string | null
          period_month: string | null
          reopen_reason: string | null
          reopened_at: string | null
          status: string | null
          unpaid_days: number | null
          unrecorded_count: number | null
        }
        Relationships: []
      }
      bank_reconciliation_record: {
        Row: {
          bank_account_code: string | null
          bank_closing_balance: number | null
          book_balance: number | null
          book_balance_drift: number | null
          book_balance_now: number | null
          currency: string | null
          difference: number | null
          ignored_lines: number | null
          is_current: boolean | null
          matched_lines: number | null
          period_end: string | null
          period_start: string | null
          reconciled_at: string | null
          reconciled_by: string | null
          reconciliation_id: string | null
          statement_code: string | null
          statement_id: string | null
          superseded_at: string | null
          superseded_reason: string | null
          variance_item_count: number | null
        }
        Relationships: []
      }
      bank_reconciliation_status: {
        Row: {
          account_code: string | null
          currency: string | null
          difference: number | null
          ignored_statement_lines: number | null
          latest_closing_balance: number | null
          latest_statement_code: string | null
          latest_statement_period_end: string | null
          ledger_balance: number | null
          unmatched_journal_amount: number | null
          unmatched_journal_lines: number | null
          unmatched_statement_lines: number | null
        }
        Relationships: []
      }
      bank_unmatched_journal_lines: {
        Row: {
          account_code: string | null
          amount_ccy: number | null
          currency: string | null
          direction: string | null
          entry_code: string | null
          entry_date: string | null
          entry_id: string | null
          journal_line_id: string | null
          memo: string | null
          source_id: string | null
          source_type: string | null
        }
        Relationships: [
          {
            foreignKeyName: "journal_lines_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      batch_assay_status: {
        Row: {
          assay_count: number | null
          batch_code: string | null
          formula_code: string | null
          has_unapplied_assay: boolean | null
          inbound_batch_id: string | null
          latest_assay_applied: boolean | null
          latest_assay_code: string | null
          latest_assay_date: string | null
          latest_assay_id: string | null
          material_name: string | null
          po_code: string | null
          pricing_formula_id: string | null
          pricing_status: string | null
          purchase_order_id: string | null
          quantity: number | null
          supplier_name: string | null
          unit: string | null
          unit_price: number | null
        }
        Relationships: [
          {
            foreignKeyName: "inbound_batches_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      batch_audit_trail: {
        Row: {
          actor_id: string | null
          actor_space: string | null
          batch_id: string | null
          batch_kind: string | null
          business_date: string | null
          detail: Json | null
          event_kind: string | null
          href: string | null
          may_view: boolean | null
          module_code: string | null
          occurred_at: string | null
          seams: string[] | null
          source_code: string | null
          source_id: string | null
          source_table: string | null
        }
        Relationships: []
      }
      batch_audit_trail_all: {
        Row: {
          actor_id: string | null
          actor_space: string | null
          batch_id: string | null
          batch_kind: string | null
          business_date: string | null
          detail: Json | null
          event_kind: string | null
          href: string | null
          module_code: string | null
          occurred_at: string | null
          seams: string[] | null
          source_code: string | null
          source_id: string | null
          source_table: string | null
        }
        Relationships: []
      }
      batch_lineage: {
        Row: {
          depth: number | null
          output_batch_id: string | null
          parent_batch_id: string | null
          parent_code: string | null
          parent_kind: string | null
          quantity_consumed: number | null
          via_run_code: string | null
          via_run_id: string | null
        }
        Relationships: []
      }
      batch_lineage_all: {
        Row: {
          depth: number | null
          output_batch_id: string | null
          parent_batch_id: string | null
          parent_code: string | null
          parent_kind: string | null
          quantity_consumed: number | null
          via_run_code: string | null
          via_run_id: string | null
        }
        Relationships: []
      }
      batch_margin: {
        Row: {
          batch_code: string | null
          cogs_differs: boolean | null
          cogs_posted_base: number | null
          cost_current_base: number | null
          cost_incomplete: boolean | null
          is_stale: boolean | null
          margin_base: number | null
          margin_pct: number | null
          margin_status: string | null
          material_name: string | null
          output_batch_id: string | null
          qty_sold: number | null
          revenue_base: number | null
          run_code: string | null
          run_id: string | null
          unit_cost_base: number | null
        }
        Relationships: []
      }
      batch_required_assay_gaps: {
        Row: {
          arrival_date: string | null
          batch_code: string | null
          inbound_batch_id: string | null
          material_code: string | null
          material_id: string | null
          material_name: string | null
          missing_metals: string[] | null
          remaining_qty: number | null
          required_metals: string[] | null
          sampleable: boolean | null
          supplier_name: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
        ]
      }
      collection_promise_status: {
        Row: {
          channel: string | null
          chase_code: string | null
          chase_id: string | null
          chase_superseded: boolean | null
          chased_on: string | null
          currency: string | null
          customer_code: string | null
          customer_id: string | null
          customer_name: string | null
          is_open: boolean | null
          is_overdue: boolean | null
          outcome: string | null
          outcome_recorded_at: string | null
          promise_id: string | null
          promised_amount_base: number | null
          promised_amount_ccy: number | null
          promised_date: string | null
          superseded_reason: string | null
        }
        Relationships: [
          {
            foreignKeyName: "collection_chases_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "collection_chases_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "collection_promises_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      company_profile_masked: {
        Row: {
          address_lines: string | null
          bank_account_name: string | null
          bank_account_no: string | null
          bank_address: string | null
          bank_name: string | null
          bank_swift: string | null
          city: string | null
          country: string | null
          email: string | null
          id: boolean | null
          invoice_footer_text: string | null
          legal_name: string | null
          logo_path: string | null
          phone: string | null
          postal_code: string | null
          registration_no: string | null
          updated_at: string | null
          updated_by: string | null
          website: string | null
        }
        Insert: {
          address_lines?: string | null
          bank_account_name?: never
          bank_account_no?: never
          bank_address?: never
          bank_name?: never
          bank_swift?: never
          city?: string | null
          country?: string | null
          email?: string | null
          id?: boolean | null
          invoice_footer_text?: string | null
          legal_name?: string | null
          logo_path?: string | null
          phone?: string | null
          postal_code?: string | null
          registration_no?: string | null
          updated_at?: string | null
          updated_by?: string | null
          website?: string | null
        }
        Update: {
          address_lines?: string | null
          bank_account_name?: never
          bank_account_no?: never
          bank_address?: never
          bank_name?: never
          bank_swift?: never
          city?: string | null
          country?: string | null
          email?: string | null
          id?: boolean | null
          invoice_footer_text?: string | null
          legal_name?: string | null
          logo_path?: string | null
          phone?: string | null
          postal_code?: string | null
          registration_no?: string | null
          updated_at?: string | null
          updated_by?: string | null
          website?: string | null
        }
        Relationships: []
      }
      container_overview: {
        Row: {
          bl_number: string | null
          code: string | null
          container_number: string | null
          customer_count: number | null
          departure_date: string | null
          documents_pending: number | null
          forwarder_id: string | null
          forwarder_name: string | null
          id: string | null
          lane_checklist_state: string | null
          lane_id: string | null
          latest_milestone: string | null
          latest_milestone_date: string | null
          shipment_count: number | null
          vessel: string | null
          voyage: string | null
        }
        Relationships: [
          {
            foreignKeyName: "containers_forwarder_id_fkey"
            columns: ["forwarder_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "containers_forwarder_id_fkey"
            columns: ["forwarder_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "containers_lane_id_fkey"
            columns: ["lane_id"]
            isOneToOne: false
            referencedRelation: "lane_checklist_status"
            referencedColumns: ["lane_id"]
          },
          {
            foreignKeyName: "containers_lane_id_fkey"
            columns: ["lane_id"]
            isOneToOne: false
            referencedRelation: "lanes"
            referencedColumns: ["id"]
          },
        ]
      }
      contract_coverage: {
        Row: {
          contracts_active: number | null
          contracts_buy_side: number | null
          contracts_sell_side: number | null
          contracts_total: number | null
          documents_with_grade_specs: number | null
          purchase_orders_total: number | null
          purchase_orders_under_contract: number | null
          sales_orders_total: number | null
          sales_orders_under_contract: number | null
        }
        Relationships: []
      }
      contract_grade_breaches: {
        Row: {
          assay_date: string | null
          assay_result_id: string | null
          breach_side: string | null
          content_pct: number | null
          contract_code: string | null
          contract_id: string | null
          inbound_batch_code: string | null
          inbound_batch_id: string | null
          max_pct: number | null
          metal: string | null
          min_pct: number | null
          purchase_order_code: string | null
          purchase_order_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "assay_result_metals_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "contract_document_terms_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: false
            referencedRelation: "contracts"
            referencedColumns: ["id"]
          },
        ]
      }
      customer_credit_status: {
        Row: {
          code: string | null
          credit_hold: boolean | null
          credit_limit_base: number | null
          customer_id: string | null
          exposure_base: number | null
          headroom_base: number | null
          legal_name: string | null
          sales_blocked: boolean | null
        }
        Insert: {
          code?: string | null
          credit_hold?: boolean | null
          credit_limit_base?: number | null
          customer_id?: string | null
          exposure_base?: never
          headroom_base?: never
          legal_name?: string | null
          sales_blocked?: never
        }
        Update: {
          code?: string | null
          credit_hold?: boolean | null
          credit_limit_base?: number | null
          customer_id?: string | null
          exposure_base?: never
          headroom_base?: never
          legal_name?: string | null
          sales_blocked?: never
        }
        Relationships: []
      }
      deleted_records: {
        Row: {
          code: string | null
          delete_reason: string | null
          deleted_at: string | null
          deleted_by: string | null
          detail: string | null
          movement_id: string | null
          permission: string | null
          record_id: string | null
          record_kind: string | null
        }
        Relationships: []
      }
      employee_directory: {
        Row: {
          annual_leave_accrued_days: number | null
          annual_leave_available_days: number | null
          annual_leave_rate_days: number | null
          code: string | null
          current_gross_pay: number | null
          current_pay_period: string | null
          days_to_work_pass_expiry: number | null
          department_id: string | null
          department_name_en: string | null
          department_name_zh: string | null
          employee_id: string | null
          employment_status: string | null
          employment_type: string | null
          hire_date: string | null
          job_title: string | null
          legal_name: string | null
          manager_code: string | null
          manager_id: string | null
          manager_name: string | null
          preferred_name: string | null
          probation_end_date: string | null
          residency_status: string | null
          training_count: number | null
          work_category: string | null
          work_pass_alert: string | null
          work_pass_expiry_date: string | null
          work_pass_type: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employees_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      employees_masked: {
        Row: {
          annual_leave_accrued_days: number | null
          annual_leave_available_days: number | null
          annual_leave_rate_days: number | null
          anonymised_at: string | null
          anonymised_by: string | null
          code: string | null
          confirmation_date: string | null
          created_at: string | null
          created_by: string | null
          deleted_at: string | null
          department_id: string | null
          employment_status: string | null
          employment_type: string | null
          hire_date: string | null
          id: string | null
          identity_no: string | null
          job_title: string | null
          legal_name: string | null
          manager_id: string | null
          monthly_salary: number | null
          monthly_salary_set: boolean | null
          notes: string | null
          position_id: string | null
          preferred_name: string | null
          probation_end_date: string | null
          residency_status: string | null
          review_exempt: boolean | null
          separation_date: string | null
          separation_notes: string | null
          separation_type: string | null
          updated_at: string | null
          updated_by: string | null
          user_id: string | null
          work_category: string | null
          work_email: string | null
          work_pass_expiry_date: string | null
          work_pass_issue_date: string | null
          work_pass_no: string | null
          work_pass_type: string | null
          work_phone: string | null
        }
        Insert: {
          annual_leave_accrued_days?: never
          annual_leave_available_days?: never
          annual_leave_rate_days?: never
          anonymised_at?: string | null
          anonymised_by?: string | null
          code?: string | null
          confirmation_date?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          department_id?: string | null
          employment_status?: string | null
          employment_type?: string | null
          hire_date?: string | null
          id?: string | null
          identity_no?: never
          job_title?: never
          legal_name?: string | null
          manager_id?: string | null
          monthly_salary?: never
          monthly_salary_set?: boolean | null
          notes?: string | null
          position_id?: string | null
          preferred_name?: string | null
          probation_end_date?: string | null
          residency_status?: string | null
          review_exempt?: boolean | null
          separation_date?: string | null
          separation_notes?: string | null
          separation_type?: string | null
          updated_at?: string | null
          updated_by?: string | null
          user_id?: string | null
          work_category?: string | null
          work_email?: never
          work_pass_expiry_date?: string | null
          work_pass_issue_date?: string | null
          work_pass_no?: never
          work_pass_type?: string | null
          work_phone?: never
        }
        Update: {
          annual_leave_accrued_days?: never
          annual_leave_available_days?: never
          annual_leave_rate_days?: never
          anonymised_at?: string | null
          anonymised_by?: string | null
          code?: string | null
          confirmation_date?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          department_id?: string | null
          employment_status?: string | null
          employment_type?: string | null
          hire_date?: string | null
          id?: string | null
          identity_no?: never
          job_title?: never
          legal_name?: string | null
          manager_id?: string | null
          monthly_salary?: never
          monthly_salary_set?: boolean | null
          notes?: string | null
          position_id?: string | null
          preferred_name?: string | null
          probation_end_date?: string | null
          residency_status?: string | null
          review_exempt?: boolean | null
          separation_date?: string | null
          separation_notes?: string | null
          separation_type?: string | null
          updated_at?: string | null
          updated_by?: string | null
          user_id?: string | null
          work_category?: string | null
          work_email?: never
          work_pass_expiry_date?: string | null
          work_pass_issue_date?: string | null
          work_pass_no?: never
          work_pass_type?: string | null
          work_phone?: never
        }
        Relationships: [
          {
            foreignKeyName: "employees_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
        ]
      }
      employment_history_masked: {
        Row: {
          anonymised_at: string | null
          change_type: string | null
          created_at: string | null
          created_by: string | null
          department_id: string | null
          effective_date: string | null
          employee_id: string | null
          employment_status: string | null
          employment_type: string | null
          id: string | null
          job_title: string | null
          new_monthly_salary: number | null
          notes: string | null
          old_monthly_salary: number | null
          work_category: string | null
        }
        Insert: {
          anonymised_at?: string | null
          change_type?: string | null
          created_at?: string | null
          created_by?: string | null
          department_id?: string | null
          effective_date?: string | null
          employee_id?: string | null
          employment_status?: string | null
          employment_type?: string | null
          id?: string | null
          job_title?: string | null
          new_monthly_salary?: never
          notes?: string | null
          old_monthly_salary?: never
          work_category?: string | null
        }
        Update: {
          anonymised_at?: string | null
          change_type?: string | null
          created_at?: string | null
          created_by?: string | null
          department_id?: string | null
          effective_date?: string | null
          employee_id?: string | null
          employment_status?: string | null
          employment_type?: string | null
          id?: string | null
          job_title?: string | null
          new_monthly_salary?: never
          notes?: string | null
          old_monthly_salary?: never
          work_category?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employment_history_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      equipment_maintenance_advice: {
        Row: {
          capitalise_floor_base: number | null
          capitalise_pct_of_cost: number | null
          capitalised: boolean | null
          equipment_code: string | null
          equipment_cost_base: number | null
          equipment_id: string | null
          expense_id: string | null
          kind: string | null
          maintenance_id: string | null
          meets_threshold: boolean | null
          pct_of_equipment_cost: number | null
          performed_on: string | null
          work_cost_base: number | null
        }
        Relationships: [
          {
            foreignKeyName: "equipment_maintenance_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "equipment_service_status"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "equipment_usage"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "fixed_assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "equipment_maintenance_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_retention_status"
            referencedColumns: ["asset_id"]
          },
          {
            foreignKeyName: "equipment_maintenance_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
        ]
      }
      equipment_service_status: {
        Row: {
          acquisition_date: string | null
          approaching_reason: string | null
          baseline_date: string | null
          days_since: number | null
          disposition: string | null
          due_days: boolean | null
          due_kg: boolean | null
          due_reason: string | null
          equipment_code: string | null
          equipment_description: string | null
          equipment_id: string | null
          equipment_status: string | null
          interval_days: number | null
          interval_id: string | null
          interval_kg: number | null
          is_approaching: boolean | null
          is_due: boolean | null
          kg_since: number | null
          last_service_date: string | null
          lead_days: number | null
          lead_kg: number | null
          monitored: boolean | null
          never_serviced: boolean | null
          service_kind: string | null
          unattributed_runs_in_window: number | null
        }
        Relationships: []
      }
      equipment_usage: {
        Row: {
          acquisition_date: string | null
          equipment_code: string | null
          equipment_description: string | null
          equipment_id: string | null
          equipment_status: string | null
          first_run_date: string | null
          in_service_date: string | null
          input_kg: number | null
          last_run_date: string | null
          loss_kg: number | null
          output_kg: number | null
          run_count: number | null
        }
        Relationships: []
      }
      expense_claim_status: {
        Row: {
          account_code: string | null
          amount_ccy: number | null
          claim_id: string | null
          code: string | null
          currency: string | null
          decided_at: string | null
          decision_notes: string | null
          description: string | null
          employee_code: string | null
          employee_id: string | null
          employee_name: string | null
          expense_id: string | null
          expense_reversed: boolean | null
          has_receipt: boolean | null
          is_owing: boolean | null
          is_paid: boolean | null
          no_receipt_reason: string | null
          payment_status: string | null
          posting_date: string | null
          settled_ccy: number | null
          spend_date: string | null
          status: string | null
          submitted_at: string | null
          tax_code: string | null
        }
        Relationships: [
          {
            foreignKeyName: "expense_claims_account_code_fkey"
            columns: ["account_code"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "expense_claims_account_code_fkey"
            columns: ["account_code"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["account_code"]
          },
          {
            foreignKeyName: "expense_claims_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_claims_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_claims_tax_code_fkey"
            columns: ["tax_code"]
            isOneToOne: false
            referencedRelation: "tax_codes"
            referencedColumns: ["code"]
          },
        ]
      }
      fx_month_end_readiness: {
        Row: {
          blocks_close: boolean | null
          currency: string | null
          has_mid: boolean | null
          mid_rate: number | null
          mid_rate_as_of: string | null
          month_end: string | null
          revalued: boolean | null
        }
        Relationships: [
          {
            foreignKeyName: "journal_lines_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      fx_rate_gaps: {
        Row: {
          currency: string | null
          entry_count: number | null
          gap_source: string | null
          missing_types: string[] | null
          quote_count: number | null
          rate_date: string | null
        }
        Relationships: []
      }
      grn_discrepancies: {
        Row: {
          arrival_date: string | null
          assay_beyond_tolerance: boolean | null
          assay_metals_compared: number | null
          batch_code: string | null
          batch_id: string | null
          declared_delta_qty: number | null
          declared_qty: number | null
          deep_discharge_actual: string | null
          deep_discharge_contradicted: boolean | null
          deep_discharge_judged: string | null
          kinds: string[] | null
          line_delta_pct: number | null
          line_delta_qty: number | null
          line_id: string | null
          line_no: number | null
          line_receipt_count: number | null
          line_received_qty: number | null
          ordered_material_code: string | null
          ordered_material_id: string | null
          ordered_qty: number | null
          ordered_unit: string | null
          po_code: string | null
          po_id: string | null
          po_status: string | null
          received_material_code: string | null
          received_material_id: string | null
          received_qty: number | null
          received_unit: string | null
          supplier_id: string | null
          supplier_name: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inbound_batches_deep_discharge_actual_code_fkey"
            columns: ["deep_discharge_actual"]
            isOneToOne: false
            referencedRelation: "deep_discharge_judgements"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["received_material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["received_material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["received_material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "inbound_batches_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "inbound_batches_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_deep_discharge_judgement_code_fkey"
            columns: ["deep_discharge_judged"]
            isOneToOne: false
            referencedRelation: "deep_discharge_judgements"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["ordered_material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["ordered_material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["ordered_material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
        ]
      }
      handover_people: {
        Row: {
          code: string | null
          id: string | null
          preferred_name: string | null
          work_category: string | null
        }
        Insert: {
          code?: string | null
          id?: string | null
          preferred_name?: string | null
          work_category?: string | null
        }
        Update: {
          code?: string | null
          id?: string | null
          preferred_name?: string | null
          work_category?: string | null
        }
        Relationships: []
      }
      hr_alerts: {
        Row: {
          alert_type: string | null
          days_remaining: number | null
          due_date: string | null
          employee_code: string | null
          employee_id: string | null
          employee_name: string | null
          severity: string | null
          subject: string | null
        }
        Relationships: []
      }
      inbound_batch_valuation: {
        Row: {
          aging_bucket: string | null
          aging_days: number | null
          arrival_date: string | null
          code: string | null
          id: string | null
          landed_unit_cost: number | null
          landed_value_base: number | null
          material_id: string | null
          quantity: number | null
          remaining_qty: number | null
          stage: string | null
          supplier_id: string | null
          unit: string | null
          unpriced: boolean | null
        }
        Relationships: []
      }
      inbound_batches_masked: {
        Row: {
          arrival_date: string | null
          chemistry_certainty_code: string | null
          code: string | null
          created_at: string | null
          created_by: string | null
          declared_qty: number | null
          deep_discharge_actual_code: string | null
          delete_reason: string | null
          deleted_at: string | null
          deleted_by: string | null
          id: string | null
          import_permit_ref: string | null
          import_permit_verified_at: string | null
          import_permit_verified_by: string | null
          imported: boolean | null
          material_id: string | null
          notes: string | null
          pricing_formula_id: string | null
          pricing_status: string | null
          purchase_order_id: string | null
          purchase_order_line_id: string | null
          quantity: number | null
          remaining_qty: number | null
          source_reason_code: string | null
          source_reason_note: string | null
          source_reason_recorded_at: string | null
          source_reason_recorded_by: string | null
          stage: string | null
          status: string | null
          supplier_id: string | null
          unit: string | null
          unit_price: number | null
          updated_at: string | null
          updated_by: string | null
        }
        Insert: {
          arrival_date?: string | null
          chemistry_certainty_code?: string | null
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          declared_qty?: number | null
          deep_discharge_actual_code?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          id?: string | null
          import_permit_ref?: string | null
          import_permit_verified_at?: string | null
          import_permit_verified_by?: string | null
          imported?: boolean | null
          material_id?: string | null
          notes?: string | null
          pricing_formula_id?: string | null
          pricing_status?: string | null
          purchase_order_id?: string | null
          purchase_order_line_id?: string | null
          quantity?: number | null
          remaining_qty?: number | null
          source_reason_code?: string | null
          source_reason_note?: string | null
          source_reason_recorded_at?: string | null
          source_reason_recorded_by?: string | null
          stage?: string | null
          status?: string | null
          supplier_id?: string | null
          unit?: string | null
          unit_price?: never
          updated_at?: string | null
          updated_by?: string | null
        }
        Update: {
          arrival_date?: string | null
          chemistry_certainty_code?: string | null
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          declared_qty?: number | null
          deep_discharge_actual_code?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          id?: string | null
          import_permit_ref?: string | null
          import_permit_verified_at?: string | null
          import_permit_verified_by?: string | null
          imported?: boolean | null
          material_id?: string | null
          notes?: string | null
          pricing_formula_id?: string | null
          pricing_status?: string | null
          purchase_order_id?: string | null
          purchase_order_line_id?: string | null
          quantity?: number | null
          remaining_qty?: number | null
          source_reason_code?: string | null
          source_reason_note?: string | null
          source_reason_recorded_at?: string | null
          source_reason_recorded_by?: string | null
          stage?: string | null
          status?: string | null
          supplier_id?: string | null
          unit?: string | null
          unit_price?: never
          updated_at?: string | null
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inbound_batches_chemistry_certainty_code_fkey"
            columns: ["chemistry_certainty_code"]
            isOneToOne: false
            referencedRelation: "inbound_chemistry_certainties"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "inbound_batches_deep_discharge_actual_code_fkey"
            columns: ["deep_discharge_actual_code"]
            isOneToOne: false
            referencedRelation: "deep_discharge_judgements"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "inbound_batches_import_permit_verified_by_fkey"
            columns: ["import_permit_verified_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "inbound_batches_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_lines_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_source_reason_code_fkey"
            columns: ["source_reason_code"]
            isOneToOne: false
            referencedRelation: "inbound_source_reasons"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "inbound_batches_source_reason_recorded_by_fkey"
            columns: ["source_reason_recorded_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "inbound_batches_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
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
      invoice_document_totals: {
        Row: {
          currency: string | null
          invoice_id: string | null
          subtotal_ccy: number | null
          tax_ccy: number | null
          total_ccy: number | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      invoice_lines_masked: {
        Row: {
          amount_base: number | null
          amount_ccy: number | null
          created_at: string | null
          description: string | null
          id: string | null
          invoice_id: string | null
          invoice_voided: boolean | null
          line_no: number | null
          quantity: number | null
          sales_order_line_id: string | null
          sales_record_id: string | null
          tax_base: number | null
          tax_code: string | null
          tax_rate_pct: number | null
          unit: string | null
          unit_price: number | null
        }
        Insert: {
          amount_base?: never
          amount_ccy?: never
          created_at?: string | null
          description?: string | null
          id?: string | null
          invoice_id?: string | null
          invoice_voided?: boolean | null
          line_no?: number | null
          quantity?: number | null
          sales_order_line_id?: string | null
          sales_record_id?: string | null
          tax_base?: never
          tax_code?: string | null
          tax_rate_pct?: number | null
          unit?: string | null
          unit_price?: never
        }
        Update: {
          amount_base?: never
          amount_ccy?: never
          created_at?: string | null
          description?: string | null
          id?: string | null
          invoice_id?: string | null
          invoice_voided?: boolean | null
          line_no?: number | null
          quantity?: number | null
          sales_order_line_id?: string | null
          sales_record_id?: string | null
          tax_base?: never
          tax_code?: string | null
          tax_rate_pct?: number | null
          unit?: string | null
          unit_price?: never
        }
        Relationships: [
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_document_totals"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_status"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_balance_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_open_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_order_line_id_fkey"
            columns: ["sales_order_line_id"]
            isOneToOne: false
            referencedRelation: "sales_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_visible"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_tax_code_fkey"
            columns: ["tax_code"]
            isOneToOne: false
            referencedRelation: "tax_codes"
            referencedColumns: ["code"]
          },
        ]
      }
      invoice_status: {
        Row: {
          code: string | null
          credited_base: number | null
          credited_ccy: number | null
          currency: string | null
          customer_id: string | null
          customer_name: string | null
          days_overdue: number | null
          due_date: string | null
          invoice_id: string | null
          issue_date: string | null
          kind: string | null
          open_base: number | null
          overdue: boolean | null
          payment_state: string | null
          settled_base: number | null
          total_base: number | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      invoices_masked: {
        Row: {
          bill_to_snapshot: Json | null
          code: string | null
          created_at: string | null
          created_by: string | null
          currency: string | null
          customer_id: string | null
          due_date: string | null
          entry_id: string | null
          fx_rate: number | null
          id: string | null
          issue_date: string | null
          kind: string | null
          notes: string | null
          payment_terms_days: number | null
          sales_order_id: string | null
          status: string | null
          subtotal_base: number | null
          tax_base: number | null
          tax_rate_pct: number | null
          terms_text: string | null
          total_base: number | null
          void_reason: string | null
          voided_at: string | null
          voided_by: string | null
        }
        Insert: {
          bill_to_snapshot?: Json | null
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          customer_id?: string | null
          due_date?: string | null
          entry_id?: string | null
          fx_rate?: never
          id?: string | null
          issue_date?: string | null
          kind?: string | null
          notes?: string | null
          payment_terms_days?: number | null
          sales_order_id?: string | null
          status?: string | null
          subtotal_base?: never
          tax_base?: never
          tax_rate_pct?: number | null
          terms_text?: string | null
          total_base?: never
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Update: {
          bill_to_snapshot?: Json | null
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          customer_id?: string | null
          due_date?: string | null
          entry_id?: string | null
          fx_rate?: never
          id?: string | null
          issue_date?: string | null
          kind?: string | null
          notes?: string | null
          payment_terms_days?: number | null
          sales_order_id?: string | null
          status?: string | null
          subtotal_base?: never
          tax_base?: never
          tax_rate_pct?: number | null
          terms_text?: string | null
          total_base?: never
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "invoices_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_sales_order_id_fkey"
            columns: ["sales_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      kpi_employee_linkage_matrix: {
        Row: {
          cycle_id: string | null
          employee_code: string | null
          employee_id: string | null
          kpi_count: number | null
          legal_name: string | null
          o1_count: number | null
          o2_count: number | null
          o3_count: number | null
          o4_count: number | null
          o5_count: number | null
          position_code: string | null
        }
        Relationships: [
          {
            foreignKeyName: "kpi_entries_cycle_id_fkey"
            columns: ["cycle_id"]
            isOneToOne: false
            referencedRelation: "kpi_cycles"
            referencedColumns: ["id"]
          },
        ]
      }
      kpi_employee_rollup: {
        Row: {
          capped_count: number | null
          computed_count: number | null
          cycle_id: string | null
          cycle_name: string | null
          employee_code: string | null
          employee_id: string | null
          gate: string | null
          judged_count: number | null
          kpi_count: number | null
          legal_name: string | null
          performance_pct: number | null
          position_code: string | null
          position_title: string | null
          provisional_count: number | null
          scored_count: number | null
          weight_total: number | null
          weighted_score_achieved: number | null
        }
        Relationships: [
          {
            foreignKeyName: "kpi_entries_cycle_id_fkey"
            columns: ["cycle_id"]
            isOneToOne: false
            referencedRelation: "kpi_cycles"
            referencedColumns: ["id"]
          },
        ]
      }
      kpi_position_linkage_matrix: {
        Row: {
          kpi_count: number | null
          o1_count: number | null
          o2_count: number | null
          o3_count: number | null
          o4_count: number | null
          o5_count: number | null
          position_code: string | null
          position_title: string | null
          sort_order: number | null
          weight_total: number | null
        }
        Relationships: []
      }
      lane_checklist_status: {
        Row: {
          checklist_reviewed_at: string | null
          checklist_state: string | null
          lane_id: string | null
          requirement_count: number | null
        }
        Relationships: []
      }
      leave_calendar: {
        Row: {
          code: string | null
          days: number | null
          department_id: string | null
          employee_code: string | null
          employee_id: string | null
          end_date: string | null
          end_half_day: boolean | null
          leave_type_code: string | null
          leave_type_en: string | null
          leave_type_zh: string | null
          legal_name: string | null
          request_id: string | null
          start_date: string | null
          start_half_day: boolean | null
          status: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employees_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_leave_type_code_fkey"
            columns: ["leave_type_code"]
            isOneToOne: false
            referencedRelation: "leave_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "leave_requests_leave_type_code_fkey"
            columns: ["leave_type_code"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["leave_type_code"]
          },
        ]
      }
      material_stock_available: {
        Row: {
          available_qty: number | null
          code: string | null
          last_movement_date: string | null
          material_id: string | null
          name: string | null
          safety_stock_qty: number | null
          unit: string | null
        }
        Relationships: []
      }
      medical_claim_status: {
        Row: {
          amount_sgd: number | null
          claim_date: string | null
          claim_id: string | null
          claim_year: number | null
          code: string | null
          decided_at: string | null
          description: string | null
          employee_code: string | null
          employee_id: string | null
          expense_amount_base: number | null
          expense_code: string | null
          expense_id: string | null
          legal_name: string | null
          linked_to_expense: boolean | null
          receipt_ref: string | null
          settled_base: number | null
          settlement_state: string | null
          status: string | null
        }
        Relationships: [
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
        ]
      }
      my_kpi_entries: {
        Row: {
          computed_basis: string | null
          cycle_id: string | null
          cycle_name: string | null
          cycle_status: string | null
          due_date: string | null
          evidence_note: string | null
          evidence_source: string | null
          gate: string | null
          id: string | null
          is_provisional: boolean | null
          kpi_ref: string | null
          org_codes: string[] | null
          override_cap: number | null
          override_reason: string | null
          period_end: string | null
          period_start: string | null
          position_code: string | null
          position_title: string | null
          provisional_note: string | null
          score: number | null
          score_kind: string | null
          score_visible: boolean | null
          source_template_version: number | null
          target_text: string | null
          title: string | null
          weight_pct: number | null
        }
        Relationships: [
          {
            foreignKeyName: "kpi_entries_cycle_id_fkey"
            columns: ["cycle_id"]
            isOneToOne: false
            referencedRelation: "kpi_cycles"
            referencedColumns: ["id"]
          },
        ]
      }
      my_leave_balance: {
        Row: {
          available: number | null
          consumed: number | null
          employee_code: string | null
          employee_id: string | null
          expired: number | null
          granted: number | null
          leave_type_code: string | null
          name_en: string | null
          name_zh: string | null
        }
        Relationships: []
      }
      my_profile: {
        Row: {
          annual_leave_accrued_days: number | null
          annual_leave_available_days: number | null
          annual_leave_rate_days: number | null
          code: string | null
          department_name_en: string | null
          department_name_zh: string | null
          employee_id: string | null
          employment_status: string | null
          employment_type: string | null
          hire_date: string | null
          identity_no: string | null
          job_title: string | null
          latest_payroll_code: string | null
          latest_payroll_month: string | null
          legal_name: string | null
          manager_code: string | null
          manager_name: string | null
          position_code: string | null
          preferred_name: string | null
          probation_end_date: string | null
          residency_status: string | null
          training_count: number | null
          work_category: string | null
          work_email: string | null
          work_pass_expiry_date: string | null
          work_pass_issue_date: string | null
          work_pass_no: string | null
          work_pass_type: string | null
          work_phone: string | null
        }
        Relationships: []
      }
      my_review_subjects: {
        Row: {
          cycle_name: string | null
          department_name_en: string | null
          department_name_zh: string | null
          employee_code: string | null
          employee_id: string | null
          employee_name: string | null
          job_title: string | null
          review_id: string | null
        }
        Relationships: []
      }
      my_self_assessment: {
        Row: {
          cycle_id: string | null
          cycle_name: string | null
          employee_id: string | null
          period_end: string | null
          period_start: string | null
          review_id: string | null
          review_type: string | null
          self_assessment_submitted_at: string | null
          self_assessment_text: string | null
          status: string | null
        }
        Relationships: [
          {
            foreignKeyName: "performance_reviews_cycle_id_fkey"
            columns: ["cycle_id"]
            isOneToOne: false
            referencedRelation: "review_cycles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      my_self_assessment_goals: {
        Row: {
          actual_value: number | null
          employee_result_text: string | null
          goal_id: string | null
          objective_text: string | null
          review_id: string | null
          sequence: number | null
          target_value: number | null
          unit: string | null
        }
        Relationships: [
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["review_id"]
          },
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "my_self_assessment"
            referencedColumns: ["review_id"]
          },
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "performance_reviews"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "performance_reviews_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      operations_now: {
        Row: {
          days_waiting: number | null
          doc_kind: string | null
          item_code: string | null
          item_date: string | null
          item_id: string | null
          item_type: string | null
          permission: string | null
          permission_any: string[] | null
          subject: string | null
        }
        Relationships: []
      }
      order_invoice_balance_all: {
        Row: {
          amount_ccy: number | null
          code: string | null
          credited_base: number | null
          credited_ccy: number | null
          currency: string | null
          customer_id: string | null
          due_date: string | null
          fx_rate: number | null
          invoice_id: string | null
          issue_date: string | null
          open_base: number | null
          open_ccy: number | null
          settled_ccy: number | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      order_invoice_open_all: {
        Row: {
          amount_ccy: number | null
          code: string | null
          credited_base: number | null
          credited_ccy: number | null
          currency: string | null
          customer_id: string | null
          due_date: string | null
          fx_rate: number | null
          invoice_id: string | null
          issue_date: string | null
          open_base: number | null
          open_ccy: number | null
          settled_ccy: number | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      output_batch_valuation: {
        Row: {
          aging_bucket: string | null
          aging_days: number | null
          code: string | null
          cost_value_base: number | null
          id: string | null
          material_id: string | null
          never_costed: boolean | null
          output_date: string | null
          quantity: number | null
          remaining_qty: number | null
          state: string | null
          unit: string | null
          unit_cost_base: number | null
        }
        Relationships: [
          {
            foreignKeyName: "output_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "output_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "output_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "output_batches_state_fkey"
            columns: ["state"]
            isOneToOne: false
            referencedRelation: "output_batch_states"
            referencedColumns: ["code"]
          },
        ]
      }
      payment_term_template_lines_masked: {
        Row: {
          created_at: string | null
          days_offset: number | null
          fixed_amount_ccy: number | null
          id: string | null
          label: string | null
          notes: string | null
          percentage: number | null
          seq: number | null
          template_id: string | null
          trigger_event: string | null
        }
        Insert: {
          created_at?: string | null
          days_offset?: number | null
          fixed_amount_ccy?: never
          id?: string | null
          label?: string | null
          notes?: string | null
          percentage?: number | null
          seq?: number | null
          template_id?: string | null
          trigger_event?: string | null
        }
        Update: {
          created_at?: string | null
          days_offset?: number | null
          fixed_amount_ccy?: never
          id?: string | null
          label?: string | null
          notes?: string | null
          percentage?: number | null
          seq?: number | null
          template_id?: string | null
          trigger_event?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payment_term_template_lines_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "payment_term_templates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_term_template_lines_trigger_event_fkey"
            columns: ["trigger_event"]
            isOneToOne: false
            referencedRelation: "payment_trigger_events"
            referencedColumns: ["code"]
          },
        ]
      }
      payroll_lines_masked: {
        Row: {
          created_at: string | null
          employee_cpf: number | null
          employee_id: string | null
          employer_cpf: number | null
          gross_pay: number | null
          id: string | null
          net_pay: number | null
          notes: string | null
          other_deductions: number | null
          paid_at: string | null
          paid_journal_entry_id: string | null
          payroll_period_id: string | null
        }
        Insert: {
          created_at?: string | null
          employee_cpf?: never
          employee_id?: string | null
          employer_cpf?: never
          gross_pay?: never
          id?: string | null
          net_pay?: never
          notes?: string | null
          other_deductions?: never
          paid_at?: string | null
          paid_journal_entry_id?: string | null
          payroll_period_id?: string | null
        }
        Update: {
          created_at?: string | null
          employee_cpf?: never
          employee_id?: string | null
          employer_cpf?: never
          gross_pay?: never
          id?: string | null
          net_pay?: never
          notes?: string | null
          other_deductions?: never
          paid_at?: string | null
          paid_journal_entry_id?: string | null
          payroll_period_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_paid_journal_entry_id_fkey"
            columns: ["paid_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "payroll_lines_paid_journal_entry_id_fkey"
            columns: ["paid_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_payroll_period_id_fkey"
            columns: ["payroll_period_id"]
            isOneToOne: false
            referencedRelation: "payroll_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      performance_reviews_masked: {
        Row: {
          acknowledged_at: string | null
          approved_at: string | null
          approved_by: string | null
          created_at: string | null
          created_by: string | null
          cycle_id: string | null
          employee_id: string | null
          id: string | null
          new_monthly_salary: number | null
          notes: string | null
          period_end: string | null
          period_start: string | null
          probation_outcome: string | null
          rating_code: string | null
          review_type: string | null
          reviewer_employee_id: string | null
          salary_effective_date: string | null
          self_assessment_submitted_at: string | null
          self_assessment_text: string | null
          status: string | null
          submitted_at: string | null
          submitted_by: string | null
          summary_text: string | null
          updated_at: string | null
          updated_by: string | null
          void_reason: string | null
          voided_at: string | null
          voided_by: string | null
        }
        Insert: {
          acknowledged_at?: string | null
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string | null
          created_by?: string | null
          cycle_id?: string | null
          employee_id?: string | null
          id?: string | null
          new_monthly_salary?: never
          notes?: string | null
          period_end?: string | null
          period_start?: string | null
          probation_outcome?: string | null
          rating_code?: string | null
          review_type?: string | null
          reviewer_employee_id?: string | null
          salary_effective_date?: string | null
          self_assessment_submitted_at?: string | null
          self_assessment_text?: string | null
          status?: string | null
          submitted_at?: string | null
          submitted_by?: string | null
          summary_text?: string | null
          updated_at?: string | null
          updated_by?: string | null
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Update: {
          acknowledged_at?: string | null
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string | null
          created_by?: string | null
          cycle_id?: string | null
          employee_id?: string | null
          id?: string | null
          new_monthly_salary?: never
          notes?: string | null
          period_end?: string | null
          period_start?: string | null
          probation_outcome?: string | null
          rating_code?: string | null
          review_type?: string | null
          reviewer_employee_id?: string | null
          salary_effective_date?: string | null
          self_assessment_submitted_at?: string | null
          self_assessment_text?: string | null
          status?: string | null
          submitted_at?: string | null
          submitted_by?: string | null
          summary_text?: string | null
          updated_at?: string | null
          updated_by?: string | null
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "performance_reviews_cycle_id_fkey"
            columns: ["cycle_id"]
            isOneToOne: false
            referencedRelation: "review_cycles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_rating_code_fkey"
            columns: ["rating_code"]
            isOneToOne: false
            referencedRelation: "review_rating_scale"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      po_prepayment_applicable: {
        Row: {
          applicable_base: number | null
          batch_ap_open_base: number | null
          batch_code: string | null
          inbound_batch_id: string | null
          po_code: string | null
          po_unapplied_prepayment_base: number | null
          purchase_order_id: string | null
          supplier_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      po_receivable_lines: {
        Row: {
          estimated_unit_price: number | null
          expected_assay: Json | null
          line_id: string | null
          line_no: number | null
          material_id: string | null
          material_name: string | null
          order_date: string | null
          ordered_qty: number | null
          po_code: string | null
          po_id: string | null
          pricing_formula_id: string | null
          received_qty: number | null
          remaining_qty: number | null
          supplier_id: string | null
          supplier_name: string | null
          unit: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      prepayment_applications_masked: {
        Row: {
          amount_base: number | null
          amount_ccy: number | null
          created_at: string | null
          created_by: string | null
          currency: string | null
          expense_id: string | null
          id: string | null
          inbound_batch_id: string | null
          journal_entry_id: string | null
          notes: string | null
          purchase_order_id: string | null
        }
        Insert: {
          amount_base?: never
          amount_ccy?: never
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          expense_id?: string | null
          id?: string | null
          inbound_batch_id?: string | null
          journal_entry_id?: string | null
          notes?: string | null
          purchase_order_id?: string | null
        }
        Update: {
          amount_base?: never
          amount_ccy?: never
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          expense_id?: string | null
          id?: string | null
          inbound_batch_id?: string | null
          journal_entry_id?: string | null
          notes?: string | null
          purchase_order_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "prepayment_applications_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "prepayment_applications_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "prepayment_applications_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      price_history_masked: {
        Row: {
          created_at: string | null
          created_by: string | null
          currency: string | null
          fx_rate: number | null
          id: string | null
          inbound_batch_id: string | null
          new_unit_price: number | null
          notes: string | null
          old_unit_price: number | null
          original_price: number | null
          rate_as_of: string | null
          rate_type: string | null
        }
        Insert: {
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          fx_rate?: never
          id?: string | null
          inbound_batch_id?: string | null
          new_unit_price?: never
          notes?: string | null
          old_unit_price?: never
          original_price?: never
          rate_as_of?: string | null
          rate_type?: string | null
        }
        Update: {
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          fx_rate?: never
          id?: string | null
          inbound_batch_id?: string | null
          new_unit_price?: never
          notes?: string | null
          old_unit_price?: never
          original_price?: never
          rate_as_of?: string | null
          rate_type?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
        ]
      }
      pricing_formula_history_masked: {
        Row: {
          change_type: string | null
          changed_at: string | null
          changed_by: string | null
          formula_id: string | null
          id: string | null
          metal: string | null
          new_average_days: number | null
          new_direction: string | null
          new_flat_discount_pct: number | null
          new_is_active: boolean | null
          new_name: string | null
          new_payable_pct: number | null
          new_price_basis: string | null
          new_treatment_charge_usd_per_tonne: number | null
          old_average_days: number | null
          old_direction: string | null
          old_flat_discount_pct: number | null
          old_is_active: boolean | null
          old_name: string | null
          old_payable_pct: number | null
          old_price_basis: string | null
          old_treatment_charge_usd_per_tonne: number | null
        }
        Insert: {
          change_type?: string | null
          changed_at?: string | null
          changed_by?: string | null
          formula_id?: string | null
          id?: string | null
          metal?: string | null
          new_average_days?: number | null
          new_direction?: string | null
          new_flat_discount_pct?: never
          new_is_active?: boolean | null
          new_name?: string | null
          new_payable_pct?: never
          new_price_basis?: string | null
          new_treatment_charge_usd_per_tonne?: never
          old_average_days?: number | null
          old_direction?: string | null
          old_flat_discount_pct?: never
          old_is_active?: boolean | null
          old_name?: string | null
          old_payable_pct?: never
          old_price_basis?: string | null
          old_treatment_charge_usd_per_tonne?: never
        }
        Update: {
          change_type?: string | null
          changed_at?: string | null
          changed_by?: string | null
          formula_id?: string | null
          id?: string | null
          metal?: string | null
          new_average_days?: number | null
          new_direction?: string | null
          new_flat_discount_pct?: never
          new_is_active?: boolean | null
          new_name?: string | null
          new_payable_pct?: never
          new_price_basis?: string | null
          new_treatment_charge_usd_per_tonne?: never
          old_average_days?: number | null
          old_direction?: string | null
          old_flat_discount_pct?: never
          old_is_active?: boolean | null
          old_name?: string | null
          old_payable_pct?: never
          old_price_basis?: string | null
          old_treatment_charge_usd_per_tonne?: never
        }
        Relationships: [
          {
            foreignKeyName: "pricing_formula_history_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formula_history_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formula_history_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
        ]
      }
      pricing_formula_metals_masked: {
        Row: {
          created_at: string | null
          created_by: string | null
          formula_id: string | null
          metal: string | null
          payable_pct: number | null
          updated_at: string | null
          updated_by: string | null
        }
        Insert: {
          created_at?: string | null
          created_by?: string | null
          formula_id?: string | null
          metal?: string | null
          payable_pct?: never
          updated_at?: string | null
          updated_by?: string | null
        }
        Update: {
          created_at?: string | null
          created_by?: string | null
          formula_id?: string | null
          metal?: string | null
          payable_pct?: never
          updated_at?: string | null
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pricing_formula_metals_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formula_metals_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formula_metals_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
        ]
      }
      pricing_formulas_masked: {
        Row: {
          average_days: number | null
          code: string | null
          created_at: string | null
          created_by: string | null
          customer_id: string | null
          deleted_at: string | null
          direction: string | null
          flat_discount_pct: number | null
          id: string | null
          is_active: boolean | null
          name: string | null
          notes: string | null
          price_basis: string | null
          price_index: string | null
          supplier_id: string | null
          treatment_charge_usd_per_tonne: number | null
          updated_at: string | null
          updated_by: string | null
        }
        Insert: {
          average_days?: number | null
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          direction?: string | null
          flat_discount_pct?: never
          id?: string | null
          is_active?: boolean | null
          name?: string | null
          notes?: string | null
          price_basis?: string | null
          price_index?: string | null
          supplier_id?: string | null
          treatment_charge_usd_per_tonne?: never
          updated_at?: string | null
          updated_by?: string | null
        }
        Update: {
          average_days?: number | null
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          direction?: string | null
          flat_discount_pct?: never
          id?: string | null
          is_active?: boolean | null
          name?: string | null
          notes?: string | null
          price_basis?: string | null
          price_index?: string | null
          supplier_id?: string | null
          treatment_charge_usd_per_tonne?: never
          updated_at?: string | null
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pricing_formulas_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "pricing_formulas_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formulas_price_index_fkey"
            columns: ["price_index"]
            isOneToOne: false
            referencedRelation: "metal_price_indices"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "pricing_formulas_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "pricing_formulas_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      pricing_term_commitment_metals_masked: {
        Row: {
          commitment_id: string | null
          metal: string | null
          payable_pct: number | null
        }
        Insert: {
          commitment_id?: string | null
          metal?: string | null
          payable_pct?: never
        }
        Update: {
          commitment_id?: string | null
          metal?: string | null
          payable_pct?: never
        }
        Relationships: [
          {
            foreignKeyName: "pricing_term_commitment_metals_commitment_id_fkey"
            columns: ["commitment_id"]
            isOneToOne: false
            referencedRelation: "pricing_term_commitments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitment_metals_commitment_id_fkey"
            columns: ["commitment_id"]
            isOneToOne: false
            referencedRelation: "pricing_term_commitments_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitment_metals_metal_fkey"
            columns: ["metal"]
            isOneToOne: false
            referencedRelation: "substances"
            referencedColumns: ["code"]
          },
        ]
      }
      pricing_term_commitments_masked: {
        Row: {
          average_days: number | null
          committed_at: string | null
          committed_by: string | null
          flat_discount_pct: number | null
          id: string | null
          inbound_batch_id: string | null
          price_basis: string | null
          price_index: string | null
          purchase_order_line_id: string | null
          source_formula_code: string | null
          source_formula_id: string | null
          source_formula_name: string | null
          treatment_charge_usd_per_tonne: number | null
        }
        Insert: {
          average_days?: number | null
          committed_at?: string | null
          committed_by?: string | null
          flat_discount_pct?: never
          id?: string | null
          inbound_batch_id?: string | null
          price_basis?: string | null
          price_index?: string | null
          purchase_order_line_id?: string | null
          source_formula_code?: string | null
          source_formula_id?: string | null
          source_formula_name?: string | null
          treatment_charge_usd_per_tonne?: never
        }
        Update: {
          average_days?: number | null
          committed_at?: string | null
          committed_by?: string | null
          flat_discount_pct?: never
          id?: string | null
          inbound_batch_id?: string | null
          price_basis?: string | null
          price_index?: string | null
          purchase_order_line_id?: string | null
          source_formula_code?: string | null
          source_formula_id?: string | null
          source_formula_name?: string | null
          treatment_charge_usd_per_tonne?: never
        }
        Relationships: [
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_price_index_fkey"
            columns: ["price_index"]
            isOneToOne: false
            referencedRelation: "metal_price_indices"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "pricing_term_commitments_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_lines_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_cost_entries_masked: {
        Row: {
          amount_base: number | null
          cost_type: string | null
          created_at: string | null
          created_by: string | null
          deleted_at: string | null
          id: string | null
          is_estimate: boolean | null
          notes: string | null
          relief_expense_id: string | null
          relieved_at: string | null
          remitted_at: string | null
          remitted_journal_entry_id: string | null
          run_id: string | null
          updated_at: string | null
          updated_by: string | null
        }
        Insert: {
          amount_base?: never
          cost_type?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          id?: string | null
          is_estimate?: boolean | null
          notes?: string | null
          relief_expense_id?: string | null
          relieved_at?: string | null
          remitted_at?: string | null
          remitted_journal_entry_id?: string | null
          run_id?: string | null
          updated_at?: string | null
          updated_by?: string | null
        }
        Update: {
          amount_base?: never
          cost_type?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          id?: string | null
          is_estimate?: boolean | null
          notes?: string | null
          relief_expense_id?: string | null
          relieved_at?: string | null
          remitted_at?: string | null
          remitted_journal_entry_id?: string | null
          run_id?: string | null
          updated_at?: string | null
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_cost_entries_relief_expense_id_fkey"
            columns: ["relief_expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entries_remitted_journal_entry_id_fkey"
            columns: ["remitted_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_remitted_journal_entry_id_fkey"
            columns: ["remitted_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
          },
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
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_loss_breakdown"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_cost_entry_history_masked: {
        Row: {
          change_type: string | null
          changed_at: string | null
          changed_by: string | null
          entry_id: string | null
          id: string | null
          new_amount_base: number | null
          new_cost_type: string | null
          new_is_estimate: boolean | null
          old_amount_base: number | null
          old_cost_type: string | null
          old_is_estimate: boolean | null
          run_id: string | null
        }
        Insert: {
          change_type?: string | null
          changed_at?: string | null
          changed_by?: string | null
          entry_id?: string | null
          id?: string | null
          new_amount_base?: never
          new_cost_type?: string | null
          new_is_estimate?: boolean | null
          old_amount_base?: never
          old_cost_type?: string | null
          old_is_estimate?: boolean | null
          run_id?: string | null
        }
        Update: {
          change_type?: string | null
          changed_at?: string | null
          changed_by?: string | null
          entry_id?: string | null
          id?: string | null
          new_amount_base?: never
          new_cost_type?: string | null
          new_is_estimate?: boolean | null
          old_amount_base?: never
          old_cost_type?: string | null
          old_is_estimate?: boolean | null
          run_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_cost_entry_history_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "processing_cost_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "processing_cost_entries_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_loss_breakdown"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_cost_variance: {
        Row: {
          actual_total: number | null
          cost_type: string | null
          direction: string | null
          estimated_total: number | null
          month: string | null
          variance: number | null
        }
        Relationships: []
      }
      processing_metal_recovery: {
        Row: {
          conservation_warning: boolean | null
          input_measured: boolean | null
          input_metal_kg: number | null
          input_source: string | null
          metal: string | null
          output_measured: boolean | null
          output_metal_kg: number | null
          output_source: string | null
          process_date: string | null
          recovery_blocked_by: string | null
          recovery_pct: number | null
          run_code: string | null
          run_id: string | null
          run_recovery_computable: boolean | null
        }
        Relationships: []
      }
      processing_metal_recovery_all: {
        Row: {
          conservation_warning: boolean | null
          input_measured: boolean | null
          input_metal_kg: number | null
          input_source: string | null
          metal: string | null
          output_measured: boolean | null
          output_metal_kg: number | null
          output_source: string | null
          process_date: string | null
          recovery_blocked_by: string | null
          recovery_pct: number | null
          run_code: string | null
          run_id: string | null
          run_recovery_computable: boolean | null
        }
        Relationships: []
      }
      processing_outputs_masked: {
        Row: {
          allocated_cost_base: number | null
          cost_incomplete: boolean | null
          created_at: string | null
          id: string | null
          output_batch_id: string | null
          quantity_produced: number | null
          run_id: string | null
          unit_cost_base: number | null
        }
        Insert: {
          allocated_cost_base?: never
          cost_incomplete?: boolean | null
          created_at?: string | null
          id?: string | null
          output_batch_id?: string | null
          quantity_produced?: number | null
          run_id?: string | null
          unit_cost_base?: never
        }
        Update: {
          allocated_cost_base?: never
          cost_incomplete?: boolean | null
          created_at?: string | null
          id?: string | null
          output_batch_id?: string | null
          quantity_produced?: number | null
          run_id?: string | null
          unit_cost_base?: never
        }
        Relationships: [
          {
            foreignKeyName: "processing_outputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "processing_outputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_outputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_outputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
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
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_loss_breakdown"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_run_allocation_status: {
        Row: {
          allocated_at: string | null
          code: string | null
          cogs_posted: number | null
          is_stale: boolean | null
          last_cost_change: string | null
          run_id: string | null
          safe_to_reallocate: boolean | null
        }
        Relationships: []
      }
      processing_run_loss_breakdown: {
        Row: {
          categorised_qty: number | null
          loss_qty: number | null
          process_date: string | null
          run_code: string | null
          run_id: string | null
          unexplained_qty: number | null
        }
        Relationships: []
      }
      processing_runs_masked: {
        Row: {
          allocated_at: string | null
          allocated_by: string | null
          allocation_basis: string | null
          allocation_basis_changed_at: string | null
          allocation_snapshot: Json | null
          capitalization_entry_id: string | null
          capitalized_cost_base: number | null
          code: string | null
          created_at: string | null
          created_by: string | null
          delete_reason: string | null
          deleted_at: string | null
          deleted_by: string | null
          equipment_id: string | null
          id: string | null
          loss_qty: number | null
          material_cost_base: number | null
          notes: string | null
          operation_type_code: string | null
          process_cost_base: number | null
          process_date: string | null
          status: string | null
          total_cost_base: number | null
          total_input: number | null
          total_output: number | null
          updated_at: string | null
          updated_by: string | null
          work_order_id: string | null
        }
        Insert: {
          allocated_at?: string | null
          allocated_by?: string | null
          allocation_basis?: string | null
          allocation_basis_changed_at?: string | null
          allocation_snapshot?: Json | null
          capitalization_entry_id?: string | null
          capitalized_cost_base?: never
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          equipment_id?: string | null
          id?: string | null
          loss_qty?: number | null
          material_cost_base?: never
          notes?: string | null
          operation_type_code?: string | null
          process_cost_base?: never
          process_date?: string | null
          status?: string | null
          total_cost_base?: never
          total_input?: number | null
          total_output?: number | null
          updated_at?: string | null
          updated_by?: string | null
          work_order_id?: string | null
        }
        Update: {
          allocated_at?: string | null
          allocated_by?: string | null
          allocation_basis?: string | null
          allocation_basis_changed_at?: string | null
          allocation_snapshot?: Json | null
          capitalization_entry_id?: string | null
          capitalized_cost_base?: never
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          equipment_id?: string | null
          id?: string | null
          loss_qty?: number | null
          material_cost_base?: never
          notes?: string | null
          operation_type_code?: string | null
          process_cost_base?: never
          process_date?: string | null
          status?: string | null
          total_cost_base?: never
          total_input?: number | null
          total_output?: number | null
          updated_at?: string | null
          updated_by?: string | null
          work_order_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_runs_capitalization_entry_id_fkey"
            columns: ["capitalization_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "processing_runs_capitalization_entry_id_fkey"
            columns: ["capitalization_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_runs_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "equipment_service_status"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "processing_runs_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "equipment_usage"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "processing_runs_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "fixed_assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_runs_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_retention_status"
            referencedColumns: ["asset_id"]
          },
          {
            foreignKeyName: "processing_runs_operation_type_code_fkey"
            columns: ["operation_type_code"]
            isOneToOne: false
            referencedRelation: "operation_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "processing_runs_work_order_id_fkey"
            columns: ["work_order_id"]
            isOneToOne: false
            referencedRelation: "work_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_wip: {
        Row: {
          awaiting_operation_en: string | null
          awaiting_operation_type_code: string | null
          awaiting_operation_zh: string | null
          batch_code: string | null
          material_code: string | null
          material_id: string | null
          material_name: string | null
          output_batch_id: string | null
          output_date: string | null
          purpose_code: string | null
          remaining_qty: number | null
          safety_states_recorded: number | null
          unit: string | null
        }
        Relationships: [
          {
            foreignKeyName: "output_batches_awaiting_operation_type_code_fkey"
            columns: ["awaiting_operation_type_code"]
            isOneToOne: false
            referencedRelation: "operation_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "output_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "output_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "output_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "output_batches_purpose_code_fkey"
            columns: ["purpose_code"]
            isOneToOne: false
            referencedRelation: "output_batch_purposes"
            referencedColumns: ["code"]
          },
        ]
      }
      purchase_order_line_retentions_masked: {
        Row: {
          anchor_event: string | null
          created_at: string | null
          created_by: string | null
          fixed_amount_ccy: number | null
          id: string | null
          notes: string | null
          percentage: number | null
          purchase_order_line_id: string | null
          released_amount_ccy: number | null
          released_at: string | null
          released_by: string | null
          retention_months: number | null
          withheld_amount_ccy: number | null
          withholding_reason: string | null
        }
        Insert: {
          anchor_event?: string | null
          created_at?: string | null
          created_by?: string | null
          fixed_amount_ccy?: never
          id?: string | null
          notes?: string | null
          percentage?: number | null
          purchase_order_line_id?: string | null
          released_amount_ccy?: never
          released_at?: string | null
          released_by?: string | null
          retention_months?: number | null
          withheld_amount_ccy?: never
          withholding_reason?: string | null
        }
        Update: {
          anchor_event?: string | null
          created_at?: string | null
          created_by?: string | null
          fixed_amount_ccy?: never
          id?: string | null
          notes?: string | null
          percentage?: number | null
          purchase_order_line_id?: string | null
          released_amount_ccy?: never
          released_at?: string | null
          released_by?: string | null
          retention_months?: number | null
          withheld_amount_ccy?: never
          withholding_reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_line_retentions_anchor_event_fkey"
            columns: ["anchor_event"]
            isOneToOne: false
            referencedRelation: "payment_trigger_events"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "purchase_order_line_retentions_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "purchase_order_line_retentions_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "purchase_order_line_retentions_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_line_retentions_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_lines_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_order_lines_masked: {
        Row: {
          asset_id: string | null
          created_at: string | null
          created_by: string | null
          deep_discharge_judgement_code: string | null
          estimated_amount_ccy: number | null
          estimated_unit_price: number | null
          expected_assay: Json | null
          id: string | null
          line_no: number | null
          material_id: string | null
          notes: string | null
          price_provenance: Json | null
          price_source: string | null
          pricing_formula_id: string | null
          purchase_order_id: string | null
          quantity: number | null
          unit: string | null
        }
        Insert: {
          asset_id?: string | null
          created_at?: string | null
          created_by?: string | null
          deep_discharge_judgement_code?: string | null
          estimated_amount_ccy?: never
          estimated_unit_price?: never
          expected_assay?: Json | null
          id?: string | null
          line_no?: number | null
          material_id?: string | null
          notes?: string | null
          price_provenance?: never
          price_source?: string | null
          pricing_formula_id?: string | null
          purchase_order_id?: string | null
          quantity?: number | null
          unit?: string | null
        }
        Update: {
          asset_id?: string | null
          created_at?: string | null
          created_by?: string | null
          deep_discharge_judgement_code?: string | null
          estimated_amount_ccy?: never
          estimated_unit_price?: never
          expected_assay?: Json | null
          id?: string | null
          line_no?: number | null
          material_id?: string | null
          notes?: string | null
          price_provenance?: never
          price_source?: string | null
          pricing_formula_id?: string | null
          purchase_order_id?: string | null
          quantity?: number | null
          unit?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_lines_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "equipment_service_status"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "equipment_usage"
            referencedColumns: ["equipment_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "fixed_assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_retention_status"
            referencedColumns: ["asset_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_deep_discharge_judgement_code_fkey"
            columns: ["deep_discharge_judgement_code"]
            isOneToOne: false
            referencedRelation: "deep_discharge_judgements"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_order_payment_terms_masked: {
        Row: {
          created_at: string | null
          due_date: string | null
          expected_date: string | null
          expected_date_set_at: string | null
          expected_date_set_by: string | null
          fixed_amount_ccy: number | null
          id: string | null
          label: string | null
          notes: string | null
          percentage: number | null
          purchase_order_id: string | null
          seq: number | null
          trigger_event: string | null
        }
        Insert: {
          created_at?: string | null
          due_date?: string | null
          expected_date?: string | null
          expected_date_set_at?: string | null
          expected_date_set_by?: string | null
          fixed_amount_ccy?: never
          id?: string | null
          label?: string | null
          notes?: string | null
          percentage?: number | null
          purchase_order_id?: string | null
          seq?: number | null
          trigger_event?: string | null
        }
        Update: {
          created_at?: string | null
          due_date?: string | null
          expected_date?: string | null
          expected_date_set_at?: string | null
          expected_date_set_by?: string | null
          fixed_amount_ccy?: never
          id?: string | null
          label?: string | null
          notes?: string | null
          percentage?: number | null
          purchase_order_id?: string | null
          seq?: number | null
          trigger_event?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_trigger_event_fkey"
            columns: ["trigger_event"]
            isOneToOne: false
            referencedRelation: "payment_trigger_events"
            referencedColumns: ["code"]
          },
        ]
      }
      purchase_order_retention_status: {
        Row: {
          acceptance_date: string | null
          anchor_event: string | null
          asset_code: string | null
          asset_description: string | null
          asset_id: string | null
          currency: string | null
          fixed_amount_ccy: number | null
          line_no: number | null
          maturity_date: string | null
          percentage: number | null
          purchase_order_code: string | null
          purchase_order_id: string | null
          purchase_order_line_id: string | null
          released_amount_ccy: number | null
          released_at: string | null
          released_by: string | null
          retention_amount_ccy: number | null
          retention_id: string | null
          retention_months: number | null
          retention_state: string | null
          withheld_amount_ccy: number | null
          withholding_reason: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_line_retentions_anchor_event_fkey"
            columns: ["anchor_event"]
            isOneToOne: false
            referencedRelation: "payment_trigger_events"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "purchase_order_line_retentions_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "purchase_order_line_retentions_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "purchase_order_line_retentions_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_line_retentions_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_lines_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_orders_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      purchase_order_status: {
        Row: {
          code: string | null
          currency: string | null
          estimated_total_ccy: number | null
          expected_delivery_date: string | null
          order_date: string | null
          ordered_qty: number | null
          po_id: string | null
          prepaid_applied_base: number | null
          prepaid_base: number | null
          prepaid_remaining_base: number | null
          receipt_pct: number | null
          received_batches: number | null
          received_qty: number | null
          status: string | null
          supplier_id: string | null
          supplier_name: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_orders_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_orders_masked: {
        Row: {
          approval_status: string | null
          approved_at: string | null
          approved_by: string | null
          cancel_reason: string | null
          cancelled_at: string | null
          cancelled_by: string | null
          closed_at: string | null
          code: string | null
          contract_id: string | null
          created_at: string | null
          created_by: string | null
          currency: string | null
          delete_reason: string | null
          deleted_at: string | null
          deleted_by: string | null
          estimated_total_ccy: number | null
          expected_delivery_date: string | null
          fx_rate: number | null
          id: string | null
          incoterm: string | null
          notes: string | null
          order_date: string | null
          status: string | null
          supplier_id: string | null
          terms_text: string | null
          updated_at: string | null
          updated_by: string | null
        }
        Insert: {
          approval_status?: string | null
          approved_at?: string | null
          approved_by?: string | null
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          closed_at?: string | null
          code?: string | null
          contract_id?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          estimated_total_ccy?: never
          expected_delivery_date?: string | null
          fx_rate?: never
          id?: string | null
          incoterm?: string | null
          notes?: string | null
          order_date?: string | null
          status?: string | null
          supplier_id?: string | null
          terms_text?: string | null
          updated_at?: string | null
          updated_by?: string | null
        }
        Update: {
          approval_status?: string | null
          approved_at?: string | null
          approved_by?: string | null
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          closed_at?: string | null
          code?: string | null
          contract_id?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          estimated_total_ccy?: never
          expected_delivery_date?: string | null
          fx_rate?: never
          id?: string | null
          incoterm?: string | null
          notes?: string | null
          order_date?: string | null
          status?: string | null
          supplier_id?: string | null
          terms_text?: string | null
          updated_at?: string | null
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_orders_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: false
            referencedRelation: "contracts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_orders_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      quote_status: {
        Row: {
          amended_since_issue: boolean | null
          code: string | null
          converted_order_code: string | null
          converted_order_id: string | null
          convertible: boolean | null
          currency: string | null
          customer_code: string | null
          customer_id: string | null
          customer_name: string | null
          decline_reason: string | null
          expired: boolean | null
          fx_rate: number | null
          issue_version: number | null
          notes: string | null
          quote_date: string | null
          quote_id: string | null
          status: string | null
          terms_text: string | null
          updated_at: string | null
          valid_until: string | null
        }
        Relationships: [
          {
            foreignKeyName: "quotes_converted_order_id_fkey"
            columns: ["converted_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "quotes_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "quotes_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "quotes_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_records_masked: {
        Row: {
          amount_base: number | null
          cogs_entry_id: string | null
          created_at: string | null
          created_by: string | null
          currency: string | null
          customer_id: string | null
          fx_rate: number | null
          id: string | null
          notes: string | null
          output_batch_id: string | null
          price_provenance: Json | null
          price_source: string | null
          quantity: number | null
          sale_date: string | null
          sales_order_line_id: string | null
          unit_price: number | null
        }
        Insert: {
          amount_base?: never
          cogs_entry_id?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          customer_id?: string | null
          fx_rate?: never
          id?: string | null
          notes?: string | null
          output_batch_id?: string | null
          price_provenance?: never
          price_source?: string | null
          quantity?: number | null
          sale_date?: string | null
          sales_order_line_id?: string | null
          unit_price?: never
        }
        Update: {
          amount_base?: never
          cogs_entry_id?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          customer_id?: string | null
          fx_rate?: never
          id?: string | null
          notes?: string | null
          output_batch_id?: string | null
          price_provenance?: never
          price_source?: string | null
          quantity?: number | null
          sale_date?: string | null
          sales_order_line_id?: string | null
          unit_price?: never
        }
        Relationships: [
          {
            foreignKeyName: "sales_records_cogs_entry_id_fkey"
            columns: ["cogs_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "sales_records_cogs_entry_id_fkey"
            columns: ["cogs_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "sales_records_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "sales_records_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "sales_records_sales_order_line_id_fkey"
            columns: ["sales_order_line_id"]
            isOneToOne: false
            referencedRelation: "sales_order_lines"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_records_visible: {
        Row: {
          amount_base: number | null
          created_at: string | null
          created_by: string | null
          currency: string | null
          customer_id: string | null
          customer_name: string | null
          fx_rate: number | null
          id: string | null
          notes: string | null
          output_batch_code: string | null
          output_batch_id: string | null
          quantity: number | null
          sale_date: string | null
          unit_price: number | null
        }
        Relationships: [
          {
            foreignKeyName: "sales_records_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "sales_records_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "sales_records_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
        ]
      }
      stock_by_status: {
        Row: {
          batch_code: string | null
          inbound_batch_id: string | null
          location_code: string | null
          location_id: string | null
          location_name: string | null
          output_batch_id: string | null
          qty: number | null
          stock_status: string | null
          unit: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "contract_grade_breaches"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "grn_discrepancies"
            referencedColumns: ["batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
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
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batch_valuation"
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
            foreignKeyName: "inventory_movements_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "processing_wip"
            referencedColumns: ["output_batch_id"]
          },
        ]
      }
      stock_class_violations: {
        Row: {
          class_code: string | null
          location_code: string | null
          location_id: string | null
          material_code: string | null
          material_id: string | null
          qty: number | null
        }
        Relationships: [
          {
            foreignKeyName: "inventory_movements_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "storage_locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "materials_waste_classification_code_fkey"
            columns: ["class_code"]
            isOneToOne: false
            referencedRelation: "waste_classifications"
            referencedColumns: ["code"]
          },
        ]
      }
      stock_class_violations_all: {
        Row: {
          class_code: string | null
          location_code: string | null
          location_id: string | null
          material_code: string | null
          material_id: string | null
          qty: number | null
        }
        Relationships: [
          {
            foreignKeyName: "inventory_movements_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "storage_locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "materials_waste_classification_code_fkey"
            columns: ["class_code"]
            isOneToOne: false
            referencedRelation: "waste_classifications"
            referencedColumns: ["code"]
          },
        ]
      }
      stock_snapshot: {
        Row: {
          location_code: string | null
          location_id: string | null
          location_name: string | null
          material_code: string | null
          material_id: string | null
          material_name: string | null
          qty: number | null
          stock_status: string | null
          unit: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inventory_movements_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "storage_locations"
            referencedColumns: ["id"]
          },
        ]
      }
      supplier_receipt_pattern: {
        Row: {
          assay_beyond_receipts: number | null
          comparable_receipts: number | null
          declared_vs_actual_receipts: number | null
          earliest_receipt: string | null
          excluded_receipts: number | null
          grn_assay_tolerance_pct: number | null
          grn_over_pct: number | null
          grn_short_pct: number | null
          latest_receipt: string | null
          material_mismatch_receipts: number | null
          over_lines: number | null
          over_qty: number | null
          over_receipts: number | null
          receipts_with_any_discrepancy: number | null
          short_lines: number | null
          short_qty: number | null
          short_receipts: number | null
          supplier_code: string | null
          supplier_id: string | null
          supplier_name: string | null
          undated_receipts: number | null
          undated_with_discrepancy: number | null
          window_days: number | null
          window_from: string | null
        }
        Relationships: []
      }
      supplier_receiving_blocked: {
        Row: {
          cert_type_code: string | null
          name_en: string | null
          name_zh: string | null
          supplier_code: string | null
          supplier_id: string | null
          valid_until: string | null
        }
        Relationships: [
          {
            foreignKeyName: "supplier_compliance_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "supplier_receipt_pattern"
            referencedColumns: ["supplier_id"]
          },
          {
            foreignKeyName: "supplier_compliance_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      task_assignable_employees: {
        Row: {
          code: string | null
          display_name: string | null
          employee_id: string | null
        }
        Insert: {
          code?: string | null
          display_name?: never
          employee_id?: string | null
        }
        Update: {
          code?: string | null
          display_name?: never
          employee_id?: string | null
        }
        Relationships: []
      }
      task_board_rows: {
        Row: {
          code: string | null
          done_count: number | null
          due_date: string | null
          id: string | null
          node_count: number | null
          owner_id: string | null
          priority: string | null
          reminder_at: string | null
          status: string | null
          steps_overrun_due_date: boolean | null
          tags: string[] | null
          task_type: string | null
          title: string | null
        }
        Relationships: [
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      task_participant_directory: {
        Row: {
          added_at: string | null
          added_by: string | null
          added_by_name: string | null
          display_name: string | null
          employee_id: string | null
          left_voluntarily: boolean | null
          participant_id: string | null
          removed_at: string | null
          removed_by: string | null
          task_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "handover_people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_linkage_matrix"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "kpi_employee_rollup"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "task_assignable_employees"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_removed_by_fkey"
            columns: ["removed_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "task_participants_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "task_board_rows"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "task_participants_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      user_directory: {
        Row: {
          created_at: string | null
          email: string | null
          employee_code: string | null
          employee_id: string | null
          employee_name: string | null
          last_sign_in_at: string | null
          roles: Json | null
          user_id: string | null
        }
        Relationships: []
      }
      wht_liability_by_month: {
        Row: {
          due_date: string | null
          is_overdue: boolean | null
          period_month: string | null
          remitted_base: number | null
          unremitted_base: number | null
          withheld_base: number | null
        }
        Relationships: []
      }
      work_order_fulfilment: {
        Row: {
          actual_qty: number | null
          has_plan: boolean | null
          material_code: string | null
          material_id: string | null
          material_name: string | null
          planned_or_expected_qty: number | null
          scheduled_date: string | null
          side: string | null
          status: string | null
          variance_qty: number | null
          work_order_code: string | null
          work_order_id: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      account_ledger: {
        Args: {
          p_account_code: string
          p_from: string
          p_include_year_close: boolean
          p_to: string
        }
        Returns: Json
      }
      accrued_annual_leave: {
        Args: { p_as_of?: string; p_employee_id: string }
        Returns: number
      }
      accrued_annual_leave_detail: {
        Args: { p_as_of?: string; p_employee_id: string }
        Returns: Json
      }
      acknowledge_review: { Args: { p_review_id: string }; Returns: Json }
      acknowledge_shift_handover: {
        Args: { p_handover_id: string }
        Returns: string
      }
      add_review_goal: {
        Args: {
          p_objective_text: string
          p_review_id: string
          p_target_value?: number
          p_unit?: string
        }
        Returns: Json
      }
      aging_bucket: { Args: { p_days: number }; Returns: string }
      allocate_processing_costs: {
        Args: { p_basis?: string; p_run_id: string }
        Returns: Json
      }
      amend_purchase_order: {
        Args: {
          p_header?: Json
          p_lines?: Json
          p_purchase_order_id: string
          p_reason: string
        }
        Returns: Json
      }
      amend_sales_order: {
        Args: {
          p_header?: Json
          p_lines?: Json
          p_order_id: string
          p_reason: string
        }
        Returns: Json
      }
      amend_work_order: {
        Args: {
          p_expected?: Json
          p_lines?: Json
          p_notes?: string
          p_reason: string
          p_scheduled_date?: string
          p_set_notes?: boolean
          p_set_scheduled?: boolean
          p_work_order_id: string
        }
        Returns: Json
      }
      annual_leave_available_from: {
        Args: { p_days: number; p_employee_id: string; p_from?: string }
        Returns: string
      }
      annual_leave_rate_per_year: {
        Args: { p_as_of?: string; p_employee_id: string }
        Returns: number
      }
      anonymise_employee: {
        Args: { p_employee_id: string; p_reason: string }
        Returns: Json
      }
      ap_aging_asof: { Args: { p_as_of?: string }; Returns: Json }
      apply_assay_result: {
        Args: {
          p_assay_result_id: string
          p_pricing_formula_id?: string
          p_reference_date?: string
        }
        Returns: Json
      }
      apply_output_assay: { Args: { p_assay_result_id: string }; Returns: Json }
      apply_payment_term_template: {
        Args: { p_purchase_order_id: string; p_template_id: string }
        Returns: Json
      }
      apply_prepayment: {
        Args: {
          p_amount: number
          p_expense_id?: string
          p_inbound_batch_id: string
          p_notes?: string
          p_purchase_order_id: string
          p_release_date?: string
        }
        Returns: Json
      }
      approval_level_for: { Args: { p_amount_base: number }; Returns: number }
      approvals_enabled: { Args: never; Returns: boolean }
      approvals_readiness: { Args: never; Returns: Json }
      approve_purchase_order: {
        Args: { p_note?: string; p_po_id: string }
        Returns: Json
      }
      approve_review: { Args: { p_review_id: string }; Returns: Json }
      ar_aging_asof: { Args: { p_as_of?: string }; Returns: Json }
      arm_permission_any: { Args: { p_item_type: string }; Returns: string[] }
      arm_permission_widen: { Args: { p_item_type: string }; Returns: string[] }
      assert_material_form_saleable: {
        Args: { p_material_id: string }
        Returns: undefined
      }
      assert_output_batch_saleable: {
        Args: { p_output_batch_id: string }
        Returns: undefined
      }
      assert_posting_allowed: {
        Args: { p_entry_date: string; p_source_type: string }
        Returns: undefined
      }
      assert_segregated: {
        Args: { p_code: string; p_first_actors: string[]; p_subject: string }
        Returns: undefined
      }
      assign_position_kpis: {
        Args: { p_cycle_id: string; p_employee_id: string }
        Returns: Json
      }
      attach_shipment_to_container: {
        Args: { p_container_id: string; p_shipment_id: string }
        Returns: Json
      }
      attendance_period_status_rows: {
        Args: never
        Returns: {
          code: string
          completed_at: string
          line_count: number
          opened_at: string
          ot_normal_hours: number
          ot_public_holiday_hours: number
          ot_rest_day_hours: number
          payroll_posted: boolean
          period_id: string
          period_month: string
          reopen_reason: string
          reopened_at: string
          status: string
          unpaid_days: number
          unrecorded_count: number
        }[]
      }
      attendance_unpaid_days: {
        Args: { p_employee_id: string; p_month: string }
        Returns: number
      }
      attribute_sale_customer: {
        Args: {
          p_customer_id: string
          p_note?: string
          p_sales_record_id: string
        }
        Returns: Json
      }
      available_annual_accrual: {
        Args: { p_as_of?: string; p_employee_id: string }
        Returns: number
      }
      balance_sheet: { Args: { p_as_of: string }; Returns: Json }
      bank_account_for_currency: {
        Args: { p_currency: string }
        Returns: string
      }
      bank_book_balance_asof: {
        Args: { p_account_code: string; p_as_of: string }
        Returns: number
      }
      bank_native_currency: {
        Args: { p_account_code: string }
        Returns: string
      }
      bank_reconciliation_record_rows: {
        Args: never
        Returns: {
          bank_account_code: string
          bank_closing_balance: number
          book_balance: number
          book_balance_drift: number
          book_balance_now: number
          currency: string
          difference: number
          ignored_lines: number
          is_current: boolean
          matched_lines: number
          period_end: string
          period_start: string
          reconciled_at: string
          reconciled_by: string
          reconciliation_id: string
          statement_code: string
          statement_id: string
          superseded_at: string
          superseded_reason: string
          variance_item_count: number
        }[]
      }
      bank_reconciliation_rows: {
        Args: never
        Returns: {
          account_code: string
          currency: string
          difference: number
          ignored_statement_lines: number
          latest_closing_balance: number
          latest_statement_code: string
          latest_statement_period_end: string
          ledger_balance: number
          unmatched_journal_amount: number
          unmatched_journal_lines: number
          unmatched_statement_lines: number
        }[]
      }
      base_currency_code: { Args: never; Returns: string }
      batch_freight_base: {
        Args: { p_inbound_batch_id: string }
        Returns: number
      }
      batch_freight_base_all: {
        Args: { p_inbound_batch_id: string }
        Returns: number
      }
      batch_processing_cost_base: {
        Args: { p_inbound_batch_id: string }
        Returns: number
      }
      batch_processing_cost_base_all: {
        Args: { p_inbound_batch_id: string }
        Returns: number
      }
      calculate_leave_days: {
        Args: {
          p_end: string
          p_end_half?: boolean
          p_start: string
          p_start_half?: boolean
        }
        Returns: number
      }
      calculate_metal_price: {
        Args: {
          p_formula_id: string
          p_metals: Json
          p_quantity_kg: number
          p_reference_date?: string
        }
        Returns: Json
      }
      calculate_metal_price_from_terms: {
        Args: {
          p_metals: Json
          p_quantity_kg: number
          p_reference_date: string
          p_terms: Json
        }
        Returns: Json
      }
      calculate_metal_price_internal: {
        Args: {
          p_formula_id: string
          p_metals: Json
          p_quantity_kg: number
          p_reference_date?: string
        }
        Returns: Json
      }
      can_edit_task: { Args: { p_task_id: string }; Returns: boolean }
      can_view_task: { Args: { p_task_id: string }; Returns: boolean }
      cancel_leave_request: {
        Args: { p_reason?: string; p_request_id: string }
        Returns: Json
      }
      cancel_purchase_order: {
        Args: { p_id: string; p_reason: string }
        Returns: Json
      }
      cancel_stocktake: {
        Args: { p_reason: string; p_stocktake_id: string }
        Returns: undefined
      }
      cancel_work_order: {
        Args: { p_reason: string; p_work_order_id: string }
        Returns: Json
      }
      carry_forward_annual_leave: {
        Args: { p_leave_year: number }
        Returns: Json
      }
      cash_flow_statement: {
        Args: { p_from: string; p_to: string }
        Returns: Json
      }
      cash_forecast_data: { Args: { p_week_start?: string }; Returns: Json }
      check_location_class: {
        Args: { p_location_id: string; p_material_id: string }
        Returns: string[]
      }
      close_financial_year: {
        Args: { p_notes?: string; p_year_end: string }
        Returns: Json
      }
      close_period: {
        Args: { p_notes?: string; p_period_end: string }
        Returns: Json
      }
      close_purchase_order: {
        Args: { p_notes?: string; p_purchase_order_id: string }
        Returns: Json
      }
      close_work_order: {
        Args: { p_reason: string; p_work_order_id: string }
        Returns: Json
      }
      commit_pricing_terms: {
        Args: {
          p_formula_id: string
          p_inbound_batch_id?: string
          p_purchase_order_line_id?: string
        }
        Returns: string
      }
      commit_processing_run: {
        Args: {
          p_allocation_basis: string
          p_equipment_id?: string
          p_inputs: Json
          p_loss_qty: number
          p_notes: string
          p_operation_type_code?: string
          p_outputs: Json
          p_process_date: string
          p_work_order_id?: string
        }
        Returns: string
      }
      committed_terms_price: {
        Args: { p_inbound_batch_id: string; p_reference_date: string }
        Returns: Json
      }
      complete_attendance_period: {
        Args: { p_period_id: string }
        Returns: Json
      }
      compute_leave_encashment: {
        Args: { p_as_of?: string; p_employee_id: string }
        Returns: Json
      }
      consumed_from_accrual: {
        Args: { p_employee_id: string; p_leave_year: number }
        Returns: number
      }
      convert_grade_basis: {
        Args: {
          p_content_pct: number
          p_from_basis: string
          p_moisture_pct: number
          p_to_basis: string
        }
        Returns: number
      }
      convert_quote: {
        Args: { p_order_date: string; p_quote_id: string }
        Returns: Json
      }
      convert_weight_basis: {
        Args: {
          p_from_basis: string
          p_moisture_pct: number
          p_to_basis: string
          p_weight: number
        }
        Returns: number
      }
      correct_gst_return: {
        Args: { p_original_period_id: string; p_reason: string }
        Returns: Json
      }
      correct_task_type: { Args: { p_task_id: string }; Returns: undefined }
      counterparty_overlap_report: { Args: never; Returns: Json }
      create_container: {
        Args: {
          p_bl_number?: string
          p_container_number?: string
          p_departure_date: string
          p_forwarder_id?: string
          p_lane_id: string
          p_notes?: string
          p_vessel?: string
          p_voyage?: string
        }
        Returns: Json
      }
      create_credit_note: {
        Args: {
          p_invoice_id: string
          p_lines: Json
          p_note_date: string
          p_reason: string
        }
        Returns: Json
      }
      create_fixed_asset: {
        Args: {
          p_acquisition_date: string
          p_category?: string
          p_depreciation_account_code?: string
          p_description: string
          p_notes?: string
          p_useful_life_months: number
        }
        Returns: Json
      }
      create_inbound_batch: {
        Args: {
          p_arrival_date?: string
          p_chemistry_certainty?: string
          p_declared_qty?: number
          p_location_id?: string
          p_material_id: string
          p_notes?: string
          p_purchase_order_id?: string
          p_purchase_order_line_id?: string
          p_quantity: number
          p_safety_states?: string[]
          p_source_reason_code?: string
          p_source_reason_note?: string
          p_stage?: string
          p_supplier_id: string
          p_unit?: string
          p_unit_price?: number
        }
        Returns: Json
      }
      create_invoice: {
        Args: {
          p_customer_id: string
          p_issue_date?: string
          p_notes?: string
          p_payment_terms_days?: number
          p_sales_record_ids: string[]
          p_tax_code?: string
          p_terms_text?: string
        }
        Returns: Json
      }
      create_order_invoice: {
        Args: {
          p_issue_date: string
          p_line_ids?: string[]
          p_notes?: string
          p_payment_terms_days?: number
          p_sales_order_id: string
          p_tax_code?: string
          p_terms_text?: string
        }
        Returns: Json
      }
      create_output_batch: {
        Args: {
          p_customer_id?: string
          p_location_id?: string
          p_material_id: string
          p_notes?: string
          p_output_date?: string
          p_purity?: string
          p_quantity: number
          p_state?: string
          p_unit?: string
        }
        Returns: Json
      }
      create_purchase_order: {
        Args: {
          p_currency: string
          p_expected_delivery: string
          p_fx_rate: number
          p_incoterm: string
          p_lines: Json
          p_notes: string
          p_order_date: string
          p_payment_terms?: Json
          p_supplier_id: string
          p_terms_text: string
        }
        Returns: Json
      }
      create_sales_order: {
        Args: {
          p_currency: string
          p_customer_id: string
          p_fx_rate: number
          p_lines: Json
          p_notes?: string
          p_order_date: string
          p_terms_text?: string
        }
        Returns: Json
      }
      create_stock_transfer: {
        Args: {
          p_from_location_id?: string
          p_inbound_batch_id?: string
          p_note?: string
          p_output_batch_id?: string
          p_qty: number
          p_stock_status?: string
          p_to_location_id: string
        }
        Returns: Json
      }
      create_work_order: {
        Args: {
          p_expected?: Json
          p_lines: Json
          p_notes?: string
          p_scheduled_date?: string
        }
        Returns: Json
      }
      current_user_employee: { Args: never; Returns: string }
      current_user_permissions: { Args: never; Returns: string[] }
      customer_ar_exposure_base: {
        Args: { p_customer_id: string }
        Returns: number
      }
      customer_ar_exposure_visible: {
        Args: { p_customer_id: string }
        Returns: number
      }
      customer_collection_context: {
        Args: { p_as_of?: string; p_customer_id: string }
        Returns: Json
      }
      customer_statement_data: {
        Args: { p_customer_id: string; p_from: string; p_to: string }
        Returns: Json
      }
      decide_expense_claim: {
        Args: {
          p_account_code?: string
          p_approve: boolean
          p_claim_id: string
          p_notes?: string
          p_posting_date?: string
          p_tax_code?: string
        }
        Returns: Json
      }
      decide_leave_request: {
        Args: { p_approve: boolean; p_notes?: string; p_request_id: string }
        Returns: Json
      }
      decide_medical_claim: {
        Args: { p_approve: boolean; p_claim_id: string; p_notes?: string }
        Returns: Json
      }
      decline_quote: {
        Args: { p_quote_id: string; p_reason: string }
        Returns: Json
      }
      depreciate_fixed_assets: { Args: { p_period_end: string }; Returns: Json }
      depreciation_months_elapsed: {
        Args: { p_period_end: string; p_start: string }
        Returns: number
      }
      derived_stock_qty: {
        Args: {
          p_inbound_batch_id: string
          p_location_id: string
          p_output_batch_id: string
          p_stock_status: string
        }
        Returns: number
      }
      detach_shipment_from_container: {
        Args: { p_reason: string; p_shipment_id: string }
        Returns: Json
      }
      dispose_fixed_asset: {
        Args: {
          p_asset_id: string
          p_bank_account?: string
          p_disposal_date: string
          p_notes?: string
          p_proceeds?: number
        }
        Returns: Json
      }
      drain_stock: {
        Args: {
          p_business_date: string
          p_created_by?: string
          p_inbound_batch_id?: string
          p_movement_type: string
          p_notes?: string
          p_output_batch_id?: string
          p_qty: number
          p_run_id?: string
          p_statuses?: string[]
        }
        Returns: string[]
      }
      employee_work_category_at: {
        Args: { p_employee_id: string; p_month: string }
        Returns: string
      }
      ensure_task_owner_participant: {
        Args: { p_actor?: string; p_owner_emp: string; p_task_id: string }
        Returns: string
      }
      explain_inbound_source: {
        Args: { p_batch_id: string; p_note?: string; p_reason_code: string }
        Returns: undefined
      }
      export_my_personal_data: { Args: never; Returns: Json }
      f5_box_detail: {
        Args: { p_box: string; p_period_end: string; p_period_start: string }
        Returns: {
          amount_base: number
          doc_code: string
          doc_date: string
          doc_id: string
          doc_kind: string
          memo: string
          tax_code: string
        }[]
      }
      f5_return: {
        Args: { p_period_end: string; p_period_start: string }
        Returns: Json
      }
      file_gst_return: {
        Args: { p_filed_on?: string; p_period_id: string; p_reference?: string }
        Returns: Json
      }
      fin_cost_account: { Args: { p_cost_type: string }; Returns: string }
      fin_cost_lines: {
        Args: { p_amount: number; p_cost_type: string; p_reverse: boolean }
        Returns: Json
      }
      fin_next_payment_code: {
        Args: { p_date: string; p_prefix: string }
        Returns: string
      }
      freeze_cash_forecast: {
        Args: { p_supersede_reason?: string; p_week_start?: string }
        Returns: Json
      }
      freeze_management_pack: {
        Args: {
          p_notes?: string
          p_period_month: string
          p_supersede_reason?: string
        }
        Returns: Json
      }
      fx_rate_asof: {
        Args: { p_currency: string; p_date: string; p_rate_type: string }
        Returns: {
          as_of: string
          rate: number
        }[]
      }
      fx_rate_for: {
        Args: { p_currency: string; p_date: string; p_rate_type: string }
        Returns: number
      }
      gl_control_reconciliation: { Args: { p_as_of: string }; Returns: Json }
      gst_registered: { Args: never; Returns: boolean }
      has_any_permission: { Args: { p_codes: string[] }; Returns: boolean }
      has_permission: { Args: { p_code: string }; Returns: boolean }
      hazardous_qty_on_hand_tonnes: { Args: never; Returns: number }
      hold_stock: {
        Args: {
          p_inbound_batch_id?: string
          p_location_id?: string
          p_output_batch_id?: string
          p_qty: number
          p_reason: string
        }
        Returns: Json
      }
      ignore_bank_line: {
        Args: { p_reason: string; p_statement_line_id: string }
        Returns: undefined
      }
      import_bank_statement: {
        Args: {
          p_bank_account: string
          p_closing: number
          p_file_name: string
          p_lines: Json
          p_opening: number
          p_period_end: string
          p_period_start: string
        }
        Returns: Json
      }
      inbound_batch_has_landed_cost: {
        Args: { p_inbound_batch_id: string }
        Returns: boolean
      }
      inbound_batch_landed_unit_cost: {
        Args: { p_inbound_batch_id: string }
        Returns: number
      }
      inbound_batch_landed_unit_cost_all: {
        Args: { p_inbound_batch_id: string }
        Returns: number
      }
      inbound_batch_valuation_rows: {
        Args: never
        Returns: {
          aging_bucket: string
          aging_days: number
          arrival_date: string
          code: string
          id: string
          landed_unit_cost: number
          landed_value_base: number
          material_id: string
          quantity: number
          remaining_qty: number
          stage: string
          supplier_id: string
          unit: string
          unpriced: boolean
        }[]
      }
      inbound_unit_price_asof: {
        Args: { p_as_of: string; p_batch_id: string }
        Returns: number
      }
      index_period_average: {
        Args: {
          p_from: string
          p_index_code: string
          p_metal: string
          p_to: string
        }
        Returns: Json
      }
      instantiate_container_documents: {
        Args: { p_container_id: string }
        Returns: Json
      }
      inventory_control_reconciliation: {
        Args: { p_as_of: string }
        Returns: Json
      }
      inventory_valuation_snapshot: {
        Args: { p_as_of?: string }
        Returns: Json
      }
      is_business_day: {
        Args: { p_country?: string; p_date: string }
        Returns: boolean
      }
      is_reviewer_of: {
        Args: { p_reviewer_employee_id: string }
        Returns: boolean
      }
      issue_customer_statement: {
        Args: {
          p_customer_id: string
          p_from: string
          p_supersede_reason?: string
          p_to: string
        }
        Returns: Json
      }
      journal_activity_lines: {
        Args: { p_from: string; p_include_year_close: boolean; p_to: string }
        Returns: {
          account_code: string
          account_id: string
          account_name_en: string
          account_name_zh: string
          account_type: string
          credit: number
          debit: number
          entry_code: string
          entry_date: string
          entry_id: string
          entry_memo: string
          entry_status: string
          line_id: string
          line_memo: string
          signed_base: number
          source_id: string
          source_type: string
        }[]
      }
      leave_accrual_rate: {
        Args: {
          p_employee_id: string
          p_month: string
          p_work_category: string
        }
        Returns: Json
      }
      leave_balance: {
        Args: {
          p_as_of?: string
          p_employee_id: string
          p_leave_type_code?: string
        }
        Returns: Json
      }
      leave_balance_internal: {
        Args: {
          p_as_of?: string
          p_employee_id: string
          p_leave_type_code?: string
        }
        Returns: Json
      }
      licence_storage_within_limit: { Args: never; Returns: boolean }
      line_spoken_for: {
        Args: { p_sales_order_line_id: string }
        Returns: number
      }
      link_document_to_contract: {
        Args: {
          p_contract_id: string
          p_document_id: string
          p_document_kind: string
        }
        Returns: Json
      }
      management_pack_data: { Args: { p_period_month: string }; Returns: Json }
      master_import_apply: {
        Args: {
          p_dry_run?: boolean
          p_file_name?: string
          p_rows: Json
          p_table: string
        }
        Returns: Json
      }
      master_import_forbidden_columns: { Args: never; Returns: string[] }
      master_import_template_columns: {
        Args: { p_table: string }
        Returns: {
          accepted_values: string[]
          column_name: string
          is_required: boolean
        }[]
      }
      match_bank_line: {
        Args: { p_journal_line_ids: string[]; p_statement_line_id: string }
        Returns: Json
      }
      medical_claim_balance: {
        Args: { p_employee_id: string; p_year: number }
        Returns: Json
      }
      metal_price_anomaly: {
        Args: {
          p_exclude_id?: string
          p_metal: string
          p_price: number
          p_price_date: string
          p_price_index?: string
        }
        Returns: Json
      }
      metal_quote_to_usd: {
        Args: {
          p_price: number
          p_quote_currency: string
          p_quote_date: string
        }
        Returns: {
          leg: Json
          usd: number
        }[]
      }
      mirror_consume_restore: {
        Args: {
          p_business_date: string
          p_created_by: string
          p_expected_total: number
          p_inbound_batch_id: string
          p_output_batch_id: string
          p_run_id: string
        }
        Returns: undefined
      }
      next_assay_code: { Args: { p_date?: string }; Returns: string }
      next_chase_code: { Args: { p_date?: string }; Returns: string }
      next_container_code: { Args: { p_date: string }; Returns: string }
      next_credit_note_code: { Args: { p_date?: string }; Returns: string }
      next_employee_code: { Args: { p_date?: string }; Returns: string }
      next_expense_claim_code: { Args: { p_date?: string }; Returns: string }
      next_fixed_asset_code: { Args: { p_on: string }; Returns: string }
      next_forecast_code: { Args: { p_date?: string }; Returns: string }
      next_leave_request_code: { Args: { p_date?: string }; Returns: string }
      next_medical_claim_code: { Args: { p_date?: string }; Returns: string }
      next_payroll_code: { Args: { p_date?: string }; Returns: string }
      next_pricing_formula_code: { Args: { p_date?: string }; Returns: string }
      next_purchase_order_code: { Args: { p_date?: string }; Returns: string }
      next_quote_code: { Args: { p_date?: string }; Returns: string }
      next_sales_order_code: { Args: { p_date?: string }; Returns: string }
      next_shipment_code: { Args: { p_date: string }; Returns: string }
      next_statement_code: { Args: { p_date?: string }; Returns: string }
      next_traceability_report_code: {
        Args: { p_date?: string }
        Returns: string
      }
      next_work_order_code: { Args: { p_date?: string }; Returns: string }
      notify_class_violations: {
        Args: {
          p_cause: string
          p_location_ids: string[]
          p_material_ids: string[]
        }
        Returns: undefined
      }
      notify_landing_warnings: {
        Args: { p_location_id: string; p_material_id: string; p_warn: string[] }
        Returns: undefined
      }
      open_attendance_period: {
        Args: { p_period_month: string }
        Returns: Json
      }
      open_for_self_assessment: { Args: { p_review_id: string }; Returns: Json }
      open_gst_period: {
        Args: { p_period_end: string; p_period_start: string }
        Returns: Json
      }
      open_probation_review: { Args: { p_employee_id: string }; Returns: Json }
      open_review_cycle: { Args: { p_cycle_id: string }; Returns: Json }
      pay_medical_claim: {
        Args: {
          p_claim_id: string
          p_expense_date?: string
          p_fx_rate?: number
        }
        Returns: Json
      }
      pay_payroll_cpf: {
        Args: {
          p_bank_account?: string
          p_payment_date?: string
          p_payroll_period_id: string
        }
        Returns: Json
      }
      pay_payroll_deductions: {
        Args: {
          p_bank_account?: string
          p_payment_date?: string
          p_payroll_period_id: string
        }
        Returns: Json
      }
      pay_payroll_lines: {
        Args: {
          p_bank_account?: string
          p_line_ids: string[]
          p_payment_date?: string
          p_payroll_period_id: string
        }
        Returns: Json
      }
      pnl_statement: { Args: { p_from: string; p_to: string }; Returns: Json }
      po_document_data: { Args: { p_po_id: string }; Returns: Json }
      post_journal_entry: {
        Args: {
          p_entry_date: string
          p_lines: Json
          p_memo: string
          p_source_id: string
          p_source_type: string
        }
        Returns: Json
      }
      post_payroll_period: {
        Args: { p_payroll_period_id: string }
        Returns: Json
      }
      post_stocktake: { Args: { p_stocktake_id: string }; Returns: Json }
      preview_apply_output_assay: {
        Args: { p_assay_result_id?: string; p_output_batch_id: string }
        Returns: Json
      }
      preview_assay_price: {
        Args: {
          p_inbound_batch_id: string
          p_metals: Json
          p_reference_date: string
        }
        Returns: Json
      }
      preview_close_financial_year: {
        Args: { p_year_end?: string }
        Returns: Json
      }
      preview_depreciate_fixed_assets: {
        Args: { p_period_end: string }
        Returns: Json
      }
      preview_metal_price_anomalies: {
        Args: { p_price_date: string; p_price_index?: string; p_prices: Json }
        Returns: Json
      }
      preview_reconcile_statement: {
        Args: { p_statement_id: string }
        Returns: Json
      }
      preview_reprice_from_committed_terms: {
        Args: { p_inbound_batch_id: string; p_reference_date?: string }
        Returns: Json
      }
      preview_reprice_inbound_batch: {
        Args: {
          p_currency: string
          p_inbound_batch_id: string
          p_new_unit_price: number
        }
        Returns: Json
      }
      preview_revalue_foreign_balances: {
        Args: { p_period_end: string }
        Returns: Json
      }
      price_exposure_report: { Args: never; Returns: Json }
      price_output_sale: {
        Args: {
          p_currency: string
          p_formula_id: string
          p_output_batch_id: string
          p_quantity: number
          p_reference_date: string
        }
        Returns: Json
      }
      pricing_terms_of_commitment: {
        Args: { p_commitment_id: string }
        Returns: Json
      }
      pricing_terms_of_formula: {
        Args: { p_formula_id: string }
        Returns: Json
      }
      promote_task_to_team: { Args: { p_task_id: string }; Returns: undefined }
      purchase_order_kind: {
        Args: { p_purchase_order_id: string }
        Returns: string
      }
      quotational_period: {
        Args: { p_base_date: string; p_qp_months: number }
        Returns: {
          qp_from: string
          qp_to: string
        }[]
      }
      quote_is_expired: { Args: { p_valid_until: string }; Returns: boolean }
      real_role_holders: {
        Args: { p_role_code: string }
        Returns: {
          user_id: string
        }[]
      }
      rebalance_task_nodes: {
        Args: { p_parent_id: string; p_task_id: string }
        Returns: number
      }
      receive_inbound_batch_against_po: {
        Args: {
          p_arrival_date?: string
          p_chemistry_certainty?: string
          p_declared_qty?: number
          p_location_id?: string
          p_material_id: string
          p_notes?: string
          p_purchase_order_id?: string
          p_purchase_order_line_id?: string
          p_quantity: number
          p_safety_states?: string[]
          p_source_reason_code?: string
          p_source_reason_note?: string
          p_supplier_id: string
        }
        Returns: Json
      }
      reconcile_statement: {
        Args: { p_statement_id: string; p_variance_items?: Json }
        Returns: Json
      }
      record_approval_decision: {
        Args: {
          p_decision: string
          p_level?: number
          p_note?: string
          p_subject_id: string
          p_subject_type: string
        }
        Returns: string
      }
      record_assay_result: {
        Args: {
          p_assay_date: string
          p_certificate_ref?: string
          p_inbound_batch_id?: string
          p_is_final?: boolean
          p_lab_name?: string
          p_metals: Json
          p_moisture_pct?: number
          p_notes?: string
          p_output_batch_id?: string
          p_result_party?: string
          p_sample_ref?: string
          p_weight_basis?: string
        }
        Returns: Json
      }
      record_attendance: {
        Args: {
          p_holiday?: number
          p_line_id: string
          p_normal?: number
          p_note?: string
          p_rest_day?: number
        }
        Returns: Json
      }
      record_bank_transfer: {
        Args: {
          p_amount_in: number
          p_amount_out: number
          p_bank_reference?: string
          p_from_account: string
          p_notes?: string
          p_to_account: string
          p_transfer_date: string
        }
        Returns: Json
      }
      record_cn_issue: {
        Args: {
          p_credit_note_id: string
          p_file_path: string
          p_sha256: string
        }
        Returns: Json
      }
      record_collection_chase: {
        Args: {
          p_channel: string
          p_chased_on: string
          p_contacted_person?: string
          p_customer_id: string
          p_documents?: Json
          p_promise?: Json
          p_reached: boolean
          p_summary: string
          p_supersede_reason?: string
          p_supersedes?: string
        }
        Returns: Json
      }
      record_expense: {
        Args: {
          p_account_code: string
          p_amount: number
          p_asset?: Json
          p_bank_account?: string
          p_currency: string
          p_employee_id?: string
          p_expense_date: string
          p_fx_rate?: number
          p_maintenance_id?: string
          p_notes?: string
          p_payee_name?: string
          p_payment_status?: string
          p_purchase_order_line?: string
          p_supplier_id?: string
          p_tax_code?: string
          p_wht_nature?: string
          p_wht_rate_pct?: number
          p_wht_treaty_ref?: string
        }
        Returns: Json
      }
      record_export_freight_document: {
        Args: {
          p_amount: number
          p_bank_account?: string
          p_container_id?: string
          p_currency: string
          p_doc_date: string
          p_notes?: string
          p_payment_status?: string
          p_supplier_id: string
        }
        Returns: Json
      }
      record_freight_document: {
        Args: {
          p_allocation_basis: string
          p_allocations?: Json
          p_amount: number
          p_bank_account?: string
          p_currency: string
          p_doc_date: string
          p_gst_amount?: number
          p_notes?: string
          p_payment_status?: string
          p_supplier_id: string
        }
        Returns: Json
      }
      record_fx_rate: {
        Args: {
          p_currency: string
          p_notes?: string
          p_rate: number
          p_rate_date: string
          p_rate_type: string
          p_reason?: string
          p_source?: string
        }
        Returns: Json
      }
      record_fx_rates_bulk: { Args: { p_rows: Json }; Returns: Json }
      record_invoice_issue: {
        Args: { p_file_path: string; p_invoice_id: string; p_sha256: string }
        Returns: Json
      }
      record_output_sale: {
        Args: {
          p_currency: string
          p_customer_id?: string
          p_fx_rate?: number
          p_notes?: string
          p_output_batch_id: string
          p_price_provenance?: Json
          p_price_source?: string
          p_quantity: number
          p_sale_date?: string
          p_unit_price: number
        }
        Returns: Json
      }
      record_payment: {
        Args: {
          p_allocations?: Json
          p_amount: number
          p_bank_account?: string
          p_counterparty_id: string
          p_counterparty_kind?: string
          p_currency: string
          p_direction: string
          p_fx_rate?: number
          p_notes?: string
          p_payment_date?: string
        }
        Returns: Json
      }
      record_po_issue: {
        Args: { p_file_path: string; p_po_id: string; p_sha256: string }
        Returns: Json
      }
      record_promise_outcome: {
        Args: { p_note?: string; p_outcome: string; p_promise_id: string }
        Returns: Json
      }
      record_qt_issue: {
        Args: { p_file_path: string; p_quote_id: string; p_sha256: string }
        Returns: Json
      }
      record_sale_settlement: {
        Args: {
          p_assay_result_id: string
          p_output_batch_id: string
          p_sales_order_id: string
        }
        Returns: Json
      }
      record_shipment_issue: {
        Args: { p_file_path: string; p_sha256: string; p_shipment_id: string }
        Returns: Json
      }
      record_so_issue: {
        Args: { p_file_path: string; p_order_id: string; p_sha256: string }
        Returns: Json
      }
      record_statement_issue: {
        Args: { p_file_path: string; p_sha256: string; p_statement_id: string }
        Returns: Json
      }
      record_traceability_report_issue: {
        Args: {
          p_file_path: string
          p_output_batch_id: string
          p_sha256: string
        }
        Returns: Json
      }
      reject_purchase_order: {
        Args: { p_po_id: string; p_reason: string }
        Returns: Json
      }
      release_purchase_order_retention: {
        Args: {
          p_released_amount_ccy: number
          p_retention_id: string
          p_withheld_amount_ccy: number
          p_withholding_reason?: string
        }
        Returns: Json
      }
      release_reservation: {
        Args: { p_qty?: number; p_reason?: string; p_reservation_id: string }
        Returns: Json
      }
      release_stock: {
        Args: {
          p_inbound_batch_id?: string
          p_location_id?: string
          p_note?: string
          p_output_batch_id?: string
          p_qty: number
        }
        Returns: Json
      }
      release_work_order: { Args: { p_work_order_id: string }; Returns: Json }
      relieve_processing_accruals: {
        Args: {
          p_actual_amount: number
          p_bank_account?: string
          p_entry_ids: string[]
          p_expense_date: string
          p_notes?: string
          p_payee_name?: string
          p_payment_status?: string
          p_supplier_id?: string
        }
        Returns: Json
      }
      remit_processing_costs: {
        Args: {
          p_bank_account?: string
          p_entry_ids: string[]
          p_payment_date?: string
        }
        Returns: Json
      }
      remit_wht: {
        Args: {
          p_bank_account?: string
          p_filed_reference?: string
          p_notes?: string
          p_period_month: string
          p_remitted_on?: string
        }
        Returns: Json
      }
      remove_review_goal: { Args: { p_goal_id: string }; Returns: Json }
      reopen_attendance_period: {
        Args: { p_period_id: string; p_reason: string }
        Returns: Json
      }
      reopen_financial_year: {
        Args: { p_reason: string; p_year_end: string }
        Returns: Json
      }
      reopen_period: {
        Args: { p_period_end: string; p_reason: string }
        Returns: Json
      }
      reopen_purchase_order: {
        Args: { p_purchase_order_id: string; p_reason: string }
        Returns: Json
      }
      reprice_from_committed_terms: {
        Args: { p_inbound_batch_id: string; p_reference_date?: string }
        Returns: Json
      }
      reprice_inbound_batch: {
        Args: {
          p_currency?: string
          p_fx_rate?: number
          p_inbound_batch_id: string
          p_notes?: string
          p_unit_price: number
        }
        Returns: Json
      }
      reprice_split: {
        Args: {
          p_new_price: number
          p_old_price: number
          p_quantity: number
          p_remaining: number
        }
        Returns: Json
      }
      require_approver_for: { Args: { p_level: number }; Returns: undefined }
      require_permission: { Args: { p_code: string }; Returns: undefined }
      require_reviewer_of: {
        Args: { p_allowed_status: string[]; p_review_id: string }
        Returns: undefined
      }
      reserve_stock: {
        Args: {
          p_location_id?: string
          p_output_batch_id: string
          p_qty: number
          p_sales_order_line_id: string
        }
        Returns: Json
      }
      resolve_pricing_commitment: {
        Args: { p_inbound_batch_id: string }
        Returns: string
      }
      resolve_receipt_location: {
        Args: { p_location_id: string }
        Returns: string
      }
      resolve_review_reviewer: {
        Args: { p_employee_id: string }
        Returns: string
      }
      resolve_tax_code: {
        Args: {
          p_default: string
          p_override: string
          p_side: string
          p_subject: string
        }
        Returns: string
      }
      revalue_foreign_balances: {
        Args: { p_period_end: string }
        Returns: Json
      }
      reverse_bank_transfer: {
        Args: {
          p_memo?: string
          p_reversal_date?: string
          p_transfer_id: string
        }
        Returns: Json
      }
      reverse_expense: {
        Args: { p_expense_id: string; p_memo?: string }
        Returns: Json
      }
      reverse_freight_document: {
        Args: { p_freight_document_id: string; p_reason: string }
        Returns: Json
      }
      reverse_journal_entry: {
        Args: { p_entry_id: string; p_memo?: string; p_reversal_date: string }
        Returns: Json
      }
      reverse_journal_entry_internal: {
        Args: { p_entry_id: string; p_memo?: string; p_reversal_date: string }
        Returns: Json
      }
      reverse_payment: {
        Args: { p_memo?: string; p_payment_id: string }
        Returns: Json
      }
      role_can_see_amounts: { Args: { p_role_code: string }; Returns: boolean }
      rollback_processing_run: {
        Args: { p_reason: string; p_run_id: string }
        Returns: undefined
      }
      sale_settlement_compute: {
        Args: {
          p_assay_result_id: string
          p_output_batch_id: string
          p_sales_order_id: string
        }
        Returns: Json
      }
      sales_order_fulfilment_status: {
        Args: { p_sales_order_id: string }
        Returns: string
      }
      save_counterparty_contact: {
        Args: {
          p_contact_id?: string
          p_customer_id?: string
          p_email?: string
          p_is_primary?: boolean
          p_name?: string
          p_notes?: string
          p_phone?: string
          p_role?: string
          p_supplier_id?: string
        }
        Returns: Json
      }
      save_self_assessment: {
        Args: {
          p_final?: boolean
          p_goal_results?: Json
          p_review_id: string
          p_self_assessment_text: string
        }
        Returns: Json
      }
      score_kpi_entry: {
        Args: {
          p_computed_basis?: string
          p_entry_id: string
          p_evidence_note?: string
          p_override_cap?: number
          p_override_reason?: string
          p_score: number
          p_score_kind?: string
        }
        Returns: Json
      }
      set_asset_acceptance: {
        Args: { p_acceptance_date: string; p_asset_id: string }
        Returns: Json
      }
      set_asset_in_service: {
        Args: { p_asset_id: string; p_date: string }
        Returns: Json
      }
      set_goal_actual_value: {
        Args: { p_actual_value: number; p_goal_id: string }
        Returns: Json
      }
      set_goal_assessment: {
        Args: { p_goal_id: string; p_reviewer_assessment_text: string }
        Returns: Json
      }
      set_inbound_safety_states: {
        Args: { p_codes: string[]; p_inbound_batch_id: string }
        Returns: Json
      }
      set_inbound_unit_price: {
        Args: {
          p_currency?: string
          p_fx_rate?: number
          p_inbound_batch_id: string
          p_notes?: string
          p_unit_price: number
        }
        Returns: Json
      }
      set_material_required_metals: {
        Args: { p_material_id: string; p_metals: string[] }
        Returns: Json
      }
      set_output_batch_purpose: {
        Args: {
          p_awaiting_operation_type_code?: string
          p_output_batch_id: string
          p_purpose_code: string
        }
        Returns: Json
      }
      set_payment_term_expected_date: {
        Args: { p_expected_date?: string; p_term_id: string }
        Returns: Json
      }
      set_review_conclusion: {
        Args: {
          p_rating_code: string
          p_review_id: string
          p_summary_text: string
        }
        Returns: Json
      }
      set_review_reviewer: {
        Args: { p_review_id: string; p_reviewer_employee_id: string }
        Returns: Json
      }
      set_role_permissions: {
        Args: { p_permission_codes: string[]; p_role_id: string }
        Returns: Json
      }
      set_sales_order_status: {
        Args: { p_order_id: string; p_reason?: string; p_to: string }
        Returns: Json
      }
      set_user_employee_link: {
        Args: { p_employee_id?: string; p_user_id: string }
        Returns: Json
      }
      set_user_roles: {
        Args: { p_reason?: string; p_role_ids: string[]; p_user_id: string }
        Returns: Json
      }
      ship_order: {
        Args: { p_lines: Json; p_sales_order_id: string; p_ship_date: string }
        Returns: Json
      }
      sod_manual_posters_in: {
        Args: { p_from: string; p_to: string }
        Returns: string[]
      }
      sod_supplier_creator: {
        Args: { p_supplier_id: string }
        Returns: string[]
      }
      soft_delete_container: {
        Args: { p_container_id: string; p_reason: string }
        Returns: Json
      }
      soft_delete_counterparty_contact: {
        Args: { p_contact_id: string }
        Returns: Json
      }
      soft_delete_inbound_batch: {
        Args: { p_batch_id: string; p_reason: string }
        Returns: Json
      }
      soft_delete_output_batch: {
        Args: { p_batch_id: string; p_reason: string }
        Returns: Json
      }
      submit_expense_claim: {
        Args: {
          p_amount: number
          p_currency: string
          p_description: string
          p_employee_id: string
          p_no_receipt_reason?: string
          p_spend_date: string
        }
        Returns: Json
      }
      submit_leave_request: {
        Args: {
          p_certificate_ref?: string
          p_employee_id: string
          p_end: string
          p_end_half?: boolean
          p_exception_days?: number
          p_exception_reason?: string
          p_is_exception?: boolean
          p_leave_type_code: string
          p_reason?: string
          p_start: string
          p_start_half?: boolean
        }
        Returns: Json
      }
      submit_medical_claim: {
        Args: {
          p_amount_sgd: number
          p_claim_date: string
          p_description?: string
          p_employee_id: string
          p_receipt_ref?: string
        }
        Returns: Json
      }
      submit_review: { Args: { p_review_id: string }; Returns: Json }
      submit_shift_handover: {
        Args: {
          p_downtime_ids?: string[]
          p_handover_date: string
          p_incoming_employee_id: string
          p_items?: Json
          p_notes?: string
          p_outgoing_employee_id: string
          p_shift_code: string
        }
        Returns: string
      }
      sync_attendance_period: { Args: { p_period_id: string }; Returns: Json }
      tax_rate_for: {
        Args: { p_code: string; p_date: string }
        Returns: number
      }
      traceability_report_data: {
        Args: { p_output_batch_id: string }
        Returns: Json
      }
      unapply_assay_result: {
        Args: { p_assay_result_id: string; p_reason: string }
        Returns: Json
      }
      unignore_bank_line: {
        Args: { p_statement_line_id: string }
        Returns: undefined
      }
      unmatch_bank_line: {
        Args: { p_statement_line_id: string }
        Returns: undefined
      }
      unpost_payroll_period: {
        Args: { p_id: string; p_reason: string }
        Returns: Json
      }
      unreconcile_statement: {
        Args: { p_reason: string; p_statement_id: string }
        Returns: undefined
      }
      update_review_goal: {
        Args: {
          p_goal_id: string
          p_objective_text: string
          p_target_value?: number
          p_unit?: string
        }
        Returns: Json
      }
      upsert_metal_prices: {
        Args: {
          p_price_date: string
          p_price_index?: string
          p_prices: Json
          p_quote_delayed?: boolean
          p_source?: string
          p_source_reference?: string
        }
        Returns: Json
      }
      upsert_payroll_period: {
        Args: {
          p_currency: string
          p_fx_rate: number
          p_lines: Json
          p_notes: string
          p_payment_date: string
          p_period_month: string
          p_source_note: string
        }
        Returns: Json
      }
      void_invoice: {
        Args: {
          p_invoice_id: string
          p_reason: string
          p_reversal_date?: string
        }
        Returns: Json
      }
      void_review: {
        Args: { p_reason: string; p_review_id: string }
        Returns: Json
      }
      wht_rate_for: {
        Args: { p_date: string; p_nature: string }
        Returns: number
      }
      withdraw_expense_claim: { Args: { p_claim_id: string }; Returns: Json }
      withdraw_fx_rate: {
        Args: { p_id: string; p_reason: string }
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
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
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
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
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
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
