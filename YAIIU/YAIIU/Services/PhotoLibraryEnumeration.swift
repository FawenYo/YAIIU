import Foundation

enum PhotoLibraryEnumeration {
    /// Include the lookup itself: PhotoKit allocates batch buffers before calling
    /// an enumeration callback, so a pool inside that callback is too late.
    @discardableResult
    static func forEach<Object>(
        count: Int,
        objectAt: (Int) -> Object,
        shouldStop: () -> Bool = { false },
        _ body: (Object, Int) -> Void
    ) -> Bool {
        for index in 0..<count {
            guard !shouldStop() else { return false }
            autoreleasepool {
                body(objectAt(index), index)
            }
        }
        return !shouldStop()
    }
}
