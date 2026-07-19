import Flutter
import UIKit
import XCTest
import integration_test

/// XCTest wrapper for the Dart integration_test target selected by
/// `flutter build ios --config-only <suite>.dart` — lets `xcodebuild test`
/// drive the suites on CI without the flutter tool's install/attach step,
/// which hangs on GitHub's virtualized macOS runners after "Xcode build
/// done" (actions/runner-images#12777).
class RunnerTests: XCTestCase {
  func testIntegrationTest() {
    let integrationTestRunner = IntegrationTestIosTest()
    var testResult: NSString?
    XCTAssertTrue(
      integrationTestRunner.testIntegrationTest(&testResult),
      (testResult as String?) ?? "integration test failed")
  }
}
