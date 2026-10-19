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
        forEach(indices: 0..<count, objectAt: objectAt, shouldStop: shouldStop, body)
    }

    /// Read a sparse selection without materializing a complete object array.
    @discardableResult
    static func forEach<Indices: Sequence, Object>(
        indices: Indices,
        objectAt: (Int) -> Object,
        shouldStop: () -> Bool = { false },
        _ body: (Object, Int) -> Void
    ) -> Bool where Indices.Element == Int {
        for index in indices {
            guard !shouldStop() else { return false }
            autoreleasepool {
                body(objectAt(index), index)
            }
        }
        return !shouldStop()
    }
}
