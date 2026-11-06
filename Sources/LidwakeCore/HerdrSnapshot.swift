import Foundation

public enum HerdrError: Error, Equatable {
  case malformed, timeout, tooLarge
  case connect(Int32)
  case io(Int32)
}

public enum HerdrSnapshot {
  /// Counts `result.snapshot.agents[*]` with `agent_status == "working"`.
  public static func workingAgentCount(_ json: Data) throws -> Int {
    guard let object = try? JSONSerialization.jsonObject(with: json),
      let response = object as? [String: Any],
      response["error"] == nil,
      let result = response["result"] as? [String: Any],
      let snapshot = result["snapshot"] as? [String: Any]
    else { throw HerdrError.malformed }

    guard let rawAgents = snapshot["agents"] else { return 0 }
    guard let agents = rawAgents as? [[String: Any]] else { throw HerdrError.malformed }
    return agents.reduce(0) { count, agent in
      count + ((agent["agent_status"] as? String) == "working" ? 1 : 0)
    }
  }
}
