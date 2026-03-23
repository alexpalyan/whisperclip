import SwiftUI

// MARK: - Speaker colour palette (shared across all meeting views)

/// Returns a stable `Color` for a given `Speaker` value.
/// `.me` → blue, `.other` → purple, `.unknown` → gray,
/// `.labeled` speakers cycle through a palette of distinct colours.
func speakerPaletteColor(_ speaker: Speaker) -> Color {
    let palette: [Color] = [
        Color(hex: "#4A9EFF"),  // 0 - Me: vivid blue
        Color(hex: "#9C27B0"),  // 1 - Other (legacy): purple
        Color(hex: "#00C896"),  // 2 - Speaker 1: emerald
        Color(hex: "#FF7A00"),  // 3 - Speaker 2: vivid orange
        Color(hex: "#E040FB"),  // 4 - Speaker 3: vivid purple
        Color(hex: "#00BCD4"),  // 5 - Speaker 4: cyan
        Color(hex: "#FF4081"),  // 6 - Speaker 5: pink
        Color(hex: "#69F0AE"),  // 7 - Speaker 6: mint
        Color(hex: "#FF6E40"),  // 8 - Speaker 7: deep orange
    ]
    if speaker == .unknown { return .gray }
    let index = speaker.colorIndex
    return palette[min(index, palette.count - 1)]
}

struct ResultView: View {
    let resultText: String
    let statusMessage: String
    @Binding var showShareSheet: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Result")
                    .font(.headline)
                    .foregroundColor(.white)

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.green)
                }

                Spacer()

                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(resultText.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(resultText)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                        .textSelection(.enabled)
                        .foregroundColor(.white)
                        .id("resultTextBottom")
                }
                .frame(height: 150)
                .onChange(of: resultText) {
                    withAnimation {
                        proxy.scrollTo("resultTextBottom", anchor: .bottom)
                    }
                }
            }
        }
        .padding(.top, 16)
        .sheet(isPresented: $showShareSheet) {
            VStack {
                HStack {
                    Spacer()
                    Button {
                        showShareSheet = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                    .padding([.top, .trailing], 10)
                }

                if #available(macOS 13.0, *) {
                    ShareLink("Share", item: resultText)
                        .padding()
                } else {
                    Text("Sharing not available on this OS version")
                        .padding()
                }
            }
        }
    }
}

struct ErrorView: View {
    let errorMessage: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Error")
                .font(.headline)
                .foregroundColor(.red)

            ScrollView {
                Text(errorMessage)
                    .font(.body)
                    .foregroundColor(.red)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                    .textSelection(.enabled)
            }
            .frame(height: 100)
        }
        .padding(.top, 16)
    }
}
