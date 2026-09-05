import Foundation

public enum PhoneCallService {
    public static func url(for rawPhone: String) -> URL? {
        PhoneNumberNormalizer.telURL(rawPhone)
    }
}
