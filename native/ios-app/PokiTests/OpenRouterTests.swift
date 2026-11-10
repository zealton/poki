import PiSwiftAI
import XCTest
@testable import Poki

@MainActor
final class OpenRouterTests: XCTestCase {
    func testDeepSeekUsesOpenRouterWithImagesAndNativeToolCalling() throws {
        let model = try XCTUnwrap(ModelProvider.openrouter.piModel(OpenRouterDefaults.modelID))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, OpenRouterDefaults.modelID)
        XCTAssertEqual(json["provider"] as? String, "openrouter")
        XCTAssertEqual(json["baseUrl"] as? String, "https://openrouter.ai/api/v1")
        XCTAssertEqual(Set(json["input"] as? [String] ?? []), ["text", "image"])
        // Real phone actions remain PokiCore's, not the fixture-only workspace allowlist.
        let act = try XCTUnwrap(Harness.tools.first { $0.name == "do" })
        XCTAssertTrue(act.description.contains("launch"))
        XCTAssertTrue(Harness.tools.contains { $0.name == "look" })
    }

    func testFreshInstallDefaultsAndExistingAccountChoiceAreBothRespected() {
        let defaults = UserDefaults.standard
        let keys = ["chat.provider", "chat.model.openrouter", "models.enabled.openrouter"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        keys.forEach { defaults.removeObject(forKey: $0) }
        XCTAssertEqual(ModelKeys.selectedProvider, .openrouter)
        XCTAssertEqual(ModelKeys.selectedModel, OpenRouterDefaults.modelID)
        defaults.set("anthropic", forKey: "chat.provider")
        XCTAssertEqual(ModelKeys.selectedProvider, .anthropic)
    }
}
