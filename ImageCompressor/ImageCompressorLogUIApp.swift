import SwiftUI

@main
struct ImageCompressorLogUIApp: App {
    @StateObject private var compressor = ImageCompressor()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading) {
                Text("This app monitors the Downloads folder for new images and automatically compresses them.")
                    .font(.headline)
                    .padding(.bottom, 8)

                ScrollView {
                    ForEach(compressor.logs, id: \.self) { log in
                        Text(log)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 1)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .padding()
            }
            .padding()
            .frame(minWidth: 500, minHeight: 300)
        }
    }
}
