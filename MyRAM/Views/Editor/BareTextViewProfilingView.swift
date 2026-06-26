import SwiftUI
import UIKit
import os

struct BareTextViewProfilingView: View {
    var body: some View {
        BareProfilingTextView()
            .ignoresSafeArea()
    }
}

private struct BareProfilingTextView: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let signpostID = OSSignpostID(log: EditorSelectionProfiling.log)
        os_signpost(.begin, log: EditorSelectionProfiling.log, name: "BareProfilingTextView.makeUIView", signpostID: signpostID)
        defer {
            os_signpost(.end, log: EditorSelectionProfiling.log, name: "BareProfilingTextView.makeUIView", signpostID: signpostID)
        }

        return EditorTextViewFactory.makeBareProfilingTextView(
            attributedText: EditorProfilingFixtures.largeAttributedBody
        )
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let signpostID = OSSignpostID(log: EditorSelectionProfiling.log)
        os_signpost(.begin, log: EditorSelectionProfiling.log, name: "BareProfilingTextView.updateUIView", signpostID: signpostID)
        os_signpost(.end, log: EditorSelectionProfiling.log, name: "BareProfilingTextView.updateUIView", signpostID: signpostID)
    }
}
