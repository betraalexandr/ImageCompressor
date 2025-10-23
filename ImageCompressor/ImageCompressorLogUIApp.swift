import SwiftUI

@main
struct ImageCompressorLogUIApp: App {
    @StateObject private var compressor = ImageCompressor()
    @AppStorage("deleteOriginals") private var deleteOriginals: Bool = true
    @AppStorage("convertPNGsToJPEG") private var convertPNGsToJPEG: Bool = true

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("This app monitors the Downloads folder for new images and automatically compresses them.")
                    .font(.headline)

                // Dropdown selector: delete original files
                HStack(spacing: 8) {
                    Text("Delete original files:")
                    Picker("", selection: $deleteOriginals) {
                        Text("Yes").tag(true)
                        Text("No").tag(false)
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 120, alignment: .leading)
                }

                // Dropdown selector: convert PNG to JPEG
                HStack(spacing: 8) {
                    Text("Convert PNG to JPEG:")
                    Picker("", selection: $convertPNGsToJPEG) {
                        Text("Yes").tag(true)
                        Text("No").tag(false)
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 120, alignment: .leading)
                }

                Divider()

                ScrollView {
                    ForEach(compressor.logs, id: \.self) { log in
                        Text(log)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 1)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .padding(.top, 4)
            }
            .padding()
            .frame(minWidth: 520, minHeight: 360)
        }
    }
}
