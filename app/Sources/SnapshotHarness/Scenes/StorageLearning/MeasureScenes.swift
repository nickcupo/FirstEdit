import AppKit
import SwiftUI
import PipelineKit

/// §2.9: a version waiting on a check that could not reach one shoot, for
/// want of its picture vectors, with the Measure button beside the line that
/// used to end in a command to type.
final class MeasureScenes: SceneProvider {
    static let panel = #"""
    {"keepers": {"photos": 773, "shoots": 7}, "queued": false, "new_to_learn_from": [], "due": false,
     "learners": [
      {"id": "drop-reasons", "title": "Why you drop frames",
       "changes": "Which frames the cull sets aside, and the fault it names under them.",
       "state": "couldnt_check",
       "sentence": "Not in use: the cull's own fixed rules decide.",
       "candidate_state": "couldnt_check",
       "candidate_sentence": "Waiting: a version (learned when you finished 2026-09-21) has not been checked yet. Not checked yet, so nothing has changed: 2026-09-16 has no picture vectors kept; measured off its previews, it can be checked.",
       "check_do": [{"shoot": "2026-09-16", "do": "vectors"}],
       "needs_sentence": "", "needs_lines": [], "needs_do": [],
       "can_go_back": false, "can_stop": false, "can_use_anyway": false,
       "check": {"kind": "drop-reasons", "passed": false, "keepers": 773, "checked": 620,
                 "moved_down": 0, "hidden": 0, "lifted": 0, "shoots": [],
                 "couldnt_check": [{"shoot": "2026-09-16", "keepers": 153,
                                    "why": "its frames have no picture vectors kept"}]}}
     ],
     "fixed": []}
    """#

    override class var scenes: [SnapshotScene] {
        [
            SnapshotScene(name: "learning-measure", size: CGSize(width: 1100, height: 700)) { f in
                let learned = try! JSONDecoder().decode(Learned.self, from: Data(panel.utf8))
                return .window(AnyView(LearnedView(app: f.makeApp(selection: .learned),
                                                   model: LearnedModel(preview: learned))))
            },
        ]
    }
}
