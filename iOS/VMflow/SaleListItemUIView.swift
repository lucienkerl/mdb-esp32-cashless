//
//  SaleListItemUIView.swift
//  VMflow
//
//  Created by Lucien Kerl on 24.12.25.
//

import SwiftUI

struct SaleListItemUIView: View {
    var sale: Sale
    @Environment(\.locale) private var locale
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0, content: {
                Text(sale.channel)
                    .bold()
                Text("Item # \(sale.item_number)")
                Text(sale.created_at)
                    .font(.caption2)
            })
            Spacer()
            VStack(alignment: .trailing) {
                Text("Embedded: \(sale.embeddeds.subdomain)")
                    .font(.caption2)
                Text(sale.item_price.formatted(.currency(code: locale.currency?.identifier ?? "EUR")))
            }
        }
    }
}

#Preview {
    SaleListItemUIView(sale: Sale(id: "asdf", embedded_id: "123", item_number: 2, item_price: 1.5, channel: "mqtt", created_at: "2025-12-22T21:23:54.660601+00:00", embeddeds: Embeddeds(id: "1", subdomain: 200, status: "online", status_at: "2025-12-13", mac_address: "aa:bb:cc:dd:ee:ff")))
}
