import Foundation

/// Fixed-format roster stamps are independent of device locale and time zone.
/// Keep the formatter immutable and the parsed-date cache bounded. Foundation's
/// DateFormatter and NSCache support concurrent callers on our deployment OS.
enum RosterTimestamp {
    private static let formatter: DateFormatter = {
        let value = DateFormatter()
        value.calendar = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)
        value.dateFormat = "yyyy-MM-dd HH:mm"
        return value
    }()
    private static let dates: NSCache<NSString, NSDate> = {
        let value = NSCache<NSString, NSDate>()
        value.countLimit = 2_048
        return value
    }()

    static func parse(_ stamp: String) -> Date? {
        guard !stamp.isEmpty else { return nil }
        let key = stamp as NSString
        if let cached = dates.object(forKey: key) { return cached as Date }
        guard let date = formatter.date(from: stamp) else { return nil }
        dates.setObject(date as NSDate, forKey: key)
        return date
    }
}
