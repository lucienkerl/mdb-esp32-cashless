//
//  Supabase.swift
//  VMflow
//
//  Created by Lucien Kerl on 24.12.25.
//

import Supabase
import Foundation

let supabase = SupabaseClient(
  supabaseURL: URL(string: "https://supabase.vmflow.xyz")!,
  supabaseKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlLWRlbW8iLCJpYXQiOjE2NDE3NjkyMDAsImV4cCI6MTc5OTUzNTYwMH0.VGEEIztVo-do9cy_Qw2-2sF8bSONckhX71Nvtwj15X4"
)

struct Sale: Decodable, Identifiable {
    let id: String
    let embedded_id: String
    let item_number: Int
    let item_price: Float
    let channel: String
    let created_at: String
    let embeddeds: Embeddeds
}

struct Embeddeds: Decodable {
    let id: String
    let subdomain: Int
    let status: String
    let status_at: String
    let mac_address: String
}
