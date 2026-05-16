import Foundation

extension TimeInterval {
  /// "M:SS" via a `FormatStyle` (never `String(format:)`). Returns an
  /// em-dash placeholder when the value isn't usable.
  var musicTimeText: String {
    guard isFinite, self >= 0 else { return "—" }
    return Duration.seconds(self).formatted(.time(pattern: .minuteSecond))
  }
}
