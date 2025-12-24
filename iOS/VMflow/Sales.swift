//
//  Sales.swift
//  VMflow
//
//  Created by Lucien Kerl on 24.12.25.
//

import SwiftUI
import Supabase

struct Sales: View {
    
    @State var sales: [Sale] = []
    
    var body: some View {
        List(sales) { sale in
                SaleListItemUIView(sale: sale)
            }
            .overlay {
              if sales.isEmpty {
                ProgressView()
              }
            }
            .task {
              do {
                  try await supabase.auth.signIn(email: "lucien@kerl.io", password: "test1234")
                  sales = try await supabase.from("sales").select("*,embeddeds(*)").order("created_at", ascending: false).execute().value
              } catch {
                dump(error)
              }
            }
    }
}

#Preview {
    Sales()
}
