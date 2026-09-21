import SwiftUI

struct RootView: View {
    let model: RemoteViewModel

    @State private var page = 0
    @State private var drag: CGFloat = 0

    private let pageCount = 3
    /// Narrow enough to sit in the margin beside every page's controls, so a strip
    /// never steals a touch meant for the trackpad or the text field.
    private let edgeWidth: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            header

            GeometryReader { proxy in
                HStack(spacing: 0) {
                    DPadView(model: model, pageSwipe: swipe)
                        .frame(width: proxy.size.width)
                    TrackpadView(model: model)
                        .frame(width: proxy.size.width)
                    TextPageView(model: model, isActive: page == 2, pageSwipe: swipe)
                        .frame(width: proxy.size.width)
                }
                .offset(x: offset(for: proxy.size.width))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .leading) { edge }
        .overlay(alignment: .trailing) { edge }
        // The pages reach the bottom edge, where a sideways drag would otherwise
        // flick iOS into another app mid-gesture.
        .defersSystemGestures(on: .bottom)
    }

    /// Paging happens here and nowhere else: the trackpad needs every horizontal
    /// drag inside it, and the d-pad buttons swallow drags of their own.
    private var edge: some View {
        Color.clear
            .frame(width: edgeWidth)
            .contentShape(.rect)
            .gesture(swipe)
    }

    private var header: some View {
        VStack(spacing: 14) {
            StatusLabel(model: model)
            PageDots(count: pageCount, current: page)
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    private var swipe: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation.width }
            .onEnded { value in
                let travel = value.translation.width + value.predictedEndTranslation.width
                withAnimation(.snappy(duration: 0.3)) {
                    if travel < -80 {
                        page = min(page + 1, pageCount - 1)
                    } else if travel > 80 {
                        page = max(page - 1, 0)
                    }
                    drag = 0
                }
            }
    }

    private func offset(for width: CGFloat) -> CGFloat {
        let settled = -CGFloat(page) * width
        return min(max(settled + drag, -CGFloat(pageCount - 1) * width), 0)
    }
}

struct StatusLabel: View {
    let model: RemoteViewModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isConnected ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(model.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
    }
}
