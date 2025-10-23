//
//  ContentView.swift
//  ImageCompressor
//
//  Created by Aleksandr Betra on 10/23/25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This app monitors the Downloads folder for new images and automatically compresses them.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
