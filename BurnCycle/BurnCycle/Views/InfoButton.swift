import SwiftUI

/// An `info.circle` icon that reveals help text in a popover on click (reliable,
/// unlike `.help()` which only shows a slow hover tooltip and ignores clicks).
/// The hover tooltip is kept too, as a bonus for users who do hover.
struct InfoButton: View {
    let text: String
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .font(.caption)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 240)
        }
    }
}
