//
//  BinderPageGridView.swift
//  binderBuilder
//
//  The one 3x3 pocket-grid layout, shared by the export renderer and the 2D
//  binder editor. Pocket content is pluggable so the export can keep its
//  print styling (pre-fetched CGImages on white) while the editor uses async
//  CardImageView pockets.
//

import SwiftUI

struct BinderPageGridView<Slot, Pocket: View>: View {
    /// Exactly 9 entries, row-major; short arrays render trailing empties.
    let slots: [Slot?]
    var spacing: CGFloat = 10
    @ViewBuilder let pocket: (Int, Slot?) -> Pocket

    private static var columns: Int { 3 }

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<Self.columns, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<Self.columns, id: \.self) { column in
                        let index = row * Self.columns + column
                        pocket(index, slots.indices.contains(index) ? slots[index] : nil)
                    }
                }
            }
        }
    }
}
