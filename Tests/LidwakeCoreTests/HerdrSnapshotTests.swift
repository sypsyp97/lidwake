import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    /// Spec §2: HerdrSnapshot.workingAgentCount.
    @Suite struct HerdrSnapshotTests {
        @Test(
            "counts agents whose agent_status is exactly \"working\"",
            arguments: [
                (#"{"id":"s1","result":{"snapshot":{"agents":[]}}}"#, 0),
                (#"{"id":"s1","result":{"snapshot":{"agents":[{"pane_id":"w49:p1","agent":"claude","agent_status":"working"}]}}}"#, 1),
                (
                    #"{"id":"s1","result":{"snapshot":{"agents":[{"pane_id":"w1:p1","agent":"claude","agent_status":"working"},{"pane_id":"w1:p2","agent":"claude","agent_status":"idle"},{"pane_id":"w1:p3","agent":"codex","agent_status":"working"},{"pane_id":"w1:p4","agent":"claude","agent_status":"blocked"},{"pane_id":"w1:p5","agent":"claude","agent_status":"done"},{"pane_id":"w1:p6","agent":"claude","agent_status":"unknown"}],"workspaces":[]}}}"#,
                    2
                ),
                (#"{"id":"s1","result":{"snapshot":{"agents":[{"agent_status":"idle"},{"agent_status":"blocked"},{"agent_status":"done"},{"agent_status":"unknown"}]}}}"#, 0),
                (#"{"id":"s1","result":{"snapshot":{"agents":[{"agent_status":"Working"},{"agent_status":"working "},{"pane_id":"x"}]}}}"#, 0),
                (#"{"id":"lidwake","result":{"snapshot":{"agents":[{"agent_status":"working"},{"agent_status":"working"},{"agent_status":"working"}],"extra":{"nested":[1,2,3]}},"other":true}}"#, 3),
            ]
        )
        func workingCount(json: String, expected: Int) throws {
            #expect(try HerdrSnapshot.workingAgentCount(Data(json.utf8)) == expected)
        }

        @Test("valid result.snapshot without an agents key counts 0")
        func missingAgentsIsZero() throws {
            let json = #"{"id":"s1","result":{"snapshot":{"workspaces":[]}}}"#
            #expect(try HerdrSnapshot.workingAgentCount(Data(json.utf8)) == 0)
            let empty = #"{"id":"s1","result":{"snapshot":{}}}"#
            #expect(try HerdrSnapshot.workingAgentCount(Data(empty.utf8)) == 0)
        }

        @Test(
            "malformed input throws HerdrError.malformed",
            arguments: [
                "",
                "not json",
                "{",
                #"[{"result":{"snapshot":{"agents":[]}}}]"#,
                #"{"id":"s1"}"#,
                #"{"id":"s1","result":{}}"#,
                #"{"id":"s1","result":{"snapshot":null}}"#,
                #"{"id":"s1","result":{"snapshot":[]}}"#,
                #"{"id":"s1","result":{"agents":[{"agent_status":"working"}]}}"#,
                #"{"id":"s1","error":{"code":-32601,"message":"method not found"}}"#,
                #"{"id":"s1","error":{"code":1,"message":"x"},"result":{"snapshot":{"agents":[{"agent_status":"working"}]}}}"#,
            ]
        )
        func malformed(json: String) {
            #expect(throws: HerdrError.malformed) {
                try HerdrSnapshot.workingAgentCount(Data(json.utf8))
            }
        }
    }
}
