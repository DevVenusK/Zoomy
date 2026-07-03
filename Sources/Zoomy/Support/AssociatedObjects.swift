import ObjectiveC

/// Type-safe wrapper around the `objc_(get|set)AssociatedObject` C API, plus a lightweight
/// `Key` type so call sites don't need to hand-roll `UInt8` handle statics. Each `Key` instance
/// is a unique, stable object whose address (via `Unmanaged.passUnretained`) serves as the
/// association's pointer identity — the classic "empty object as a unique key" idiom.
///
/// Works for both class and value types stored at a key: the Swift/ObjC bridge auto-boxes
/// non-object values (structs, enums) passed through `Any?` on the way into the runtime.
enum AssociatedObjects {
    final class Key {}

    static func get<T>(_ object: AnyObject, _ key: Key) -> T? {
        objc_getAssociatedObject(object, keyPointer(key)) as? T
    }

    static func set<T>(
        _ object: AnyObject,
        _ key: Key,
        _ value: T?,
        policy: objc_AssociationPolicy = .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    ) {
        objc_setAssociatedObject(object, keyPointer(key), value, policy)
    }

    static func remove(_ object: AnyObject, _ key: Key) {
        objc_setAssociatedObject(object, keyPointer(key), nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static func keyPointer(_ key: Key) -> UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(key).toOpaque())
    }
}
