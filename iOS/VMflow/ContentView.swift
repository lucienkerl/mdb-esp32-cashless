//
//  ContentView.swift
//  VMflow
//
//  Created by Lucien Kerl on 21.12.25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
                    Sales()
                        .tabItem {
                            Label("Sales", systemImage: "dollarsign.arrow.trianglehead.counterclockwise.rotate.90")
                        }
                }
    }
}

#Preview {
    ContentView()
}
