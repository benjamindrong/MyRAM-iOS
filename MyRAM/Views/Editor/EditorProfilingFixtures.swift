import UIKit

enum EditorProfilingFixtures {
    static let largeAttributedBody: NSAttributedString = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 8

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: defaultEditorTextFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph
        ]
        let boldAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: defaultEditorTextFont.pointSize),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph
        ]

        let body = NSMutableAttributedString()
        for index in 1...1_200 {
            body.append(NSAttributedString(
                string: "Profiling paragraph \(index). ",
                attributes: index.isMultiple(of: 9) ? boldAttributes : baseAttributes
            ))
            body.append(NSAttributedString(
                string: "This bare Catalyst UITextView contains a large attributed body for drag-selection and edge auto-scroll profiling. It intentionally avoids the MyRAM editor coordinator, formatting toolbar state, search highlights, checklist rendering, custom gestures, and persistence callbacks.\n\n",
                attributes: baseAttributes
            ))
        }
        return body
    }()
}
