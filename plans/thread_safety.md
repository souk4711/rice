# Rice Thread-Safety Review

## Executive Summary

Rice has **no internal synchronization mechanisms** (no mutexes, atomics, or locks). It relies entirely on Ruby's GVL (Global VM Lock) for thread safety. This is a reasonable design for most Ruby extension use cases, but there are several categories of concern ranging from **currently problematic** to **latent risks that would surface under Ractors or future GVL changes**.

---

## 1. CRITICAL: `NativeCallback` Without FFI is Fundamentally Unsafe

**Files:** `rice/detail/NativeCallback.hpp:52-54`, `rice/detail/NativeCallback.ipp:192-193`

Without `HAVE_LIBFFI`, the non-FFI fallback uses **static class members** shared across all instances of the same callback signature:

```cpp
static inline NativeCallback_T* native_;      // line 54
static inline Callback_T callback_ = nullptr;  // line 45 (instance member, but...)
```

In the constructor (`NativeCallback.ipp:192-193`):
```cpp
NativeCallback_T::callback_ = &NativeCallback_T::invoke;
NativeCallback_T::native_ = this;
```

And `invoke()` (`NativeCallback.ipp:92`) reads:
```cpp
NativeCallback::native_->callRuby(indices, args...);
```

**Problem:** If two `NativeCallback` instances of the same signature type exist simultaneously, the second constructor overwrites `native_` for the first. This is broken even *with* the GVL, because creating a second callback invalidates the first. The destructor (`NativeCallback.ipp:204-205`) nullifies these, creating a dangling pointer for any surviving callbacks. This is a **correctness bug**, not just a thread-safety issue.

**Severity:** HIGH - data corruption / segfault possible even in single-threaded code.

---

## 2. InstanceRegistry Thread-Safety Analysis

### 2a. Ownership Model Verification

The `InstanceRegistry` uses a `Mode` enum and `shouldTrack(bool isOwner)` to gate registry access (`InstanceRegistry.ipp:38-51`):

```cpp
inline bool InstanceRegistry::shouldTrack(bool isOwner) const
{
  switch (this->mode)
  {
    case Mode::Off:    return false;
    case Mode::Owned:  return isOwner;   // default
    case Mode::All:    return true;
    default:           return false;
  }
}
```

With the default `Mode::Owned`, **only Ruby-owned objects are tracked**. This is correct:

**Ruby-owned objects (isOwner=true) -- TRACKED, safe under GVL:**
- `wrap<T*>(data, true)` (`Wrapper.ipp:270-279`) -- lookup then add. These are pointers Ruby will free via GC.
- `wrapConstructed()` (`Wrapper.ipp:347-374`) -- always passes `isOwner=true`. Constructor-created objects.
- `wrapReference()` for incomplete types with `isOwner=true` -- rare edge case.
- Ruby controls the lifecycle; all access paths run under the GVL.

**Ruby-owned value types -- NOT TRACKED, safe by construction:**
- `wrap<T&>(data, true)` with complete types goes to `wrapLvalue`/`wrapRvalue` (`Wrapper.ipp:238-255`), which copy/move the data into a `Wrapper<T>`. Each Ruby object gets its own copy. No registry needed.
- `To_Ruby<T>::convert()` (`Data_Object.ipp:121-129`) -- always copies. No registry.

**C++-owned objects (isOwner=false) -- NOT TRACKED, correctly excluded:**
- `wrap<T&>(data, false)` → `wrapReference()` → `shouldTrack(false)` returns false → lookup returns `Qnil`, add is a no-op. A new `Wrapper<T&>` is created every time.
- `wrap<T*>(data, false)` → same: `shouldTrack(false)` gates out lookup and add.
- C++-owned objects never enter `objectMap_`, which is correct because C++ can free them at any time -- tracking them would leave stale pointer→VALUE entries.

**Conclusion:** The ownership-based gating is correctly implemented. The registry only tracks objects whose lifecycle Ruby controls.

### 2b. Unconditional `remove()` in Destructors

All Wrapper destructors call `remove()` unconditionally:
```cpp
// Wrapper<T&>::~Wrapper() - Wrapper.ipp:89-92
Registries::instance.instances.remove(this->get(this->rb_data_type_));

// Wrapper<T*>::~Wrapper() - Wrapper.ipp:118-135
Registries::instance.instances.remove(this->get(this->rb_data_type_));

// Wrapper<T**>::~Wrapper() - Wrapper.ipp:161-175
// Wrapper<shared_ptr<T>>::~Wrapper() - shared_ptr.ipp:80-83
// Wrapper<unique_ptr<T>>::~Wrapper() - unique_ptr.ipp:74-78
```

`remove()` has no `shouldTrack` gate -- it always calls `objectMap_.erase()`. For C++-owned objects that were never added, `erase()` on a non-existent key is a structural no-op on `std::map`, but it still **traverses the tree** to find (and not find) the key. This means every GC finalization of a C++-owned wrapper touches `objectMap_`.

Under CRuby's GVL, this is safe because GC runs with the GVL held. Under Ractors, this would be a concurrent access.

### 2c. TOCTOU Race in Wrap Functions

Even with a mutex on individual InstanceRegistry methods, the callers in `Wrapper.ipp` perform a non-atomic check-then-act:

```cpp
// Wrapper.ipp:270-279 - wrap<T*>
VALUE result = Registries::instance.instances.lookup(data, isOwner);  // lock, unlock
if (result != Qnil) return result;
WrapperBase* wrapper = new Wrapper<T*>(rb_data_type, data, isOwner);  // gap!
result = TypedData_Wrap_Struct(klass, rb_data_type, wrapper);
Registries::instance.instances.add(data, result, isOwner);            // lock, unlock

// Wrapper.ipp:210-216 - wrapReference<T>
VALUE result = Registries::instance.instances.lookup(&data, isOwner); // lock, unlock
if (result == Qnil)
{
  WrapperBase* wrapper = new Wrapper<T&>(rb_data_type, data);         // gap!
  result = TypedData_Wrap_Struct(klass, rb_data_type, wrapper);
  Registries::instance.instances.add(&data, result, isOwner);         // lock, unlock
}
```

Two concurrent callers wrapping the **same C++ pointer** will both see `Qnil` from lookup, both allocate a Wrapper, and both add -- the second silently overwrites the first, leaking a Wrapper and leaving an orphaned Ruby VALUE.

**Severity:** MEDIUM today (GVL prevents), HIGH under Ractors.

### 2d. Recommended Safe API

The mutex overhead (~15-25ns uncontended) is negligible compared to the `std::map` operations (~50-200ns) and Ruby VM dispatch surrounding every call. A compile-time `#ifdef` opt-in (as proposed in PR #401) adds complexity without meaningful performance benefit. The mutex should always be present.

The key fix is making the lookup-then-insert atomic. Recommended changes to `InstanceRegistry`:

```cpp
// InstanceRegistry.hpp
#include <mutex>

class InstanceRegistry
{
public:
  enum class Mode { Off, Owned, All };

  // Atomic lookup-or-insert: returns existing VALUE or calls factory to create one.
  // The mutex is held across the entire operation, eliminating the TOCTOU race.
  template <typename T, typename Factory_T>
  VALUE lookup_or_wrap(T* cppInstance, bool isOwner, Factory_T factory);

  // Simple lookup (read-only, still needs lock for concurrent remove() from GC)
  template <typename T>
  VALUE lookup(T* cppInstance, bool isOwner);

  void remove(void* cppInstance);
  void clear();

public:
  Mode mode = Mode::Owned;

private:
  bool shouldTrack(bool isOwner) const;

  std::mutex mutex_;
  std::map<void*, VALUE> objectMap_;
};
```

```cpp
// InstanceRegistry.ipp
template <typename T, typename Factory_T>
inline VALUE InstanceRegistry::lookup_or_wrap(T* cppInstance, bool isOwner, Factory_T factory)
{
  std::lock_guard lock(mutex_);

  if (!this->shouldTrack(isOwner))
  {
    // Not tracked -- always create a new wrapper, no registry entry.
    return factory();
  }

  auto it = this->objectMap_.find((void*)cppInstance);
  if (it != this->objectMap_.end())
  {
    return it->second;
  }

  VALUE result = factory();
  this->objectMap_[(void*)cppInstance] = result;
  return result;
}

template <typename T>
inline VALUE InstanceRegistry::lookup(T* cppInstance, bool isOwner)
{
  std::lock_guard lock(mutex_);

  if (!this->shouldTrack(isOwner))
    return Qnil;

  auto it = this->objectMap_.find((void*)cppInstance);
  return it != this->objectMap_.end() ? it->second : Qnil;
}

inline void InstanceRegistry::remove(void* cppInstance)
{
  std::lock_guard lock(mutex_);
  this->objectMap_.erase(cppInstance);
}

inline void InstanceRegistry::clear()
{
  std::lock_guard lock(mutex_);
  this->objectMap_.clear();
}
```

Callers in `Wrapper.ipp` would then use:

```cpp
// wrapReference<T> - replaces Wrapper.ipp:207-218
template <typename T>
inline VALUE wrapReference(VALUE klass, rb_data_type_t* rb_data_type, T& data, bool isOwner)
{
  return Registries::instance.instances.lookup_or_wrap(&data, isOwner, [&]() {
    WrapperBase* wrapper = new Wrapper<T&>(rb_data_type, data);
    return TypedData_Wrap_Struct(klass, rb_data_type, wrapper);
  });
}

// wrap<T*> - replaces Wrapper.ipp:267-280
template <typename T>
inline VALUE wrap(VALUE klass, rb_data_type_t* rb_data_type, T* data, bool isOwner)
{
  return Registries::instance.instances.lookup_or_wrap(data, isOwner, [&]() {
    WrapperBase* wrapper = new Wrapper<T*>(rb_data_type, data, isOwner);
    return TypedData_Wrap_Struct(klass, rb_data_type, wrapper);
  });
}
```

This eliminates the TOCTOU race, always protects against concurrent GC `remove()` calls, and requires no compile-time flags.

---

## 3. HIGH: `NoGVL` Methods Can Race on Shared C++ State

**Files:** `rice/detail/NativeMethod.ipp:185-226`, `rice/detail/NativeFunction.ipp:115-131`

When a method is defined with `NoGVL`:
1. Arguments are converted from Ruby to C++ **with** the GVL held (`getNativeValues`)
2. The actual C++ function runs **without** the GVL (`rb_thread_call_without_gvl`)
3. Return value conversion back to Ruby happens **with** the GVL

The NoGVL call flow (`NativeMethod.ipp:228-251`):
```cpp
Apply_Args_T nativeArgs = this->getNativeValues(self, rubyValues, indices);  // GVL held
if constexpr (NoGVL)
  result = this->invokeNoGVL(self, std::forward<Apply_Args_T>(nativeArgs));  // GVL released
```

**Problem:** Rice provides no mechanism for users to protect their C++ objects from concurrent access. If two Ruby threads call a `NoGVL` method on the same C++ object, the C++ method executes concurrently with no synchronization. Rice doesn't warn about this or provide any locking facilities.

This isn't a Rice bug per se (users are expected to handle their own C++ thread safety), but **Rice's documentation/API gives no indication that users must synchronize their own data when using `NoGVL`**. The `NoGVL` marker class is just an empty tag (`NoGVL.hpp:6-10`).

**Severity:** HIGH for users - easy to misuse. Rice should at minimum document this clearly.

---

## 4. MEDIUM: `Anchor` Static Members Have a TOCTOU Race

**File:** `rice/detail/Anchor.ipp:36-50`

```cpp
inline void Anchor::registerExitHandler()
{
  if (!Anchor::exitHandlerRegistered_)            // check
  {
    ruby_vm_at_exit([](ruby_vm_t*) { ... });       // register
    Anchor::exitHandlerRegistered_ = true;         // set
  }
}
```

`exitHandlerRegistered_` is a plain `bool` (not `std::atomic<bool>`). If two threads create `Anchor` objects simultaneously (even under the GVL, if one path doesn't hold it), the exit handler could be registered twice. Under current CRuby with the GVL, this is safe because `Anchor` construction only happens during Ruby-facing operations. But it's fragile.

Similarly, `enabled_` (`Anchor.ipp:47`) is set to `false` during VM shutdown and read during destruction (`Anchor.ipp:23`). If any Anchor destructor runs concurrently with the exit handler (e.g., OS thread cleanup racing VM teardown), this is a data race on a non-atomic `bool`.

**Severity:** LOW today (GVL protects), MEDIUM in Ractor/future contexts.

---

## 5. MEDIUM: All Registries Are Completely Unprotected

**Files:**
- `rice/detail/TypeRegistry.ipp` - `std::unordered_map` reads/writes
- `rice/detail/NativeRegistry.ipp` - `std::map` reads/writes
- `rice/detail/ModuleRegistry.ipp` - `std::set` reads/writes
- `rice/detail/HandlerRegistry.ipp` - `std::function` reads/writes

These are all accessed through the global singleton `Registries::instance` (`Registries.ipp:4`). The design assumption (documented in `docs/architecture/registries.md`) is:
- Writes happen only during initialization (single-threaded `Init_` functions)
- Reads happen during method dispatch (under the GVL)

**Current risk:** In practice, types/methods can be defined at any time from Ruby (not just during init). For example, calling `define_class_under` from a Ruby thread while another thread is invoking methods would race on `NativeRegistry::natives_` - the `lookup()` method at `NativeRegistry.ipp:66-78` uses `operator[]` which **inserts** into the map if the key doesn't exist:

```cpp
return this->natives_[key];  // line 77 - MUTATING operation!
```

This is called from both the registration path (`NativeMethod.ipp:20`) and the resolve path (`Native.ipp:54`). If one thread defines a method while another resolves it, this is a concurrent read-write on `std::map`, which is undefined behavior.

**Severity:** MEDIUM - rare in practice but possible and has UB consequences.

---

## 6. MEDIUM: `Data_Type<T>` Static Members

**Files:** `rice/Data_Type.hpp:152-157`, `rice/Data_Type.ipp:53,130`

Each `Data_Type<T>` has:
```cpp
static inline VALUE klass_ = Qnil;
static inline rb_data_type_t* rb_data_type_ = nullptr;
static inline std::set<Data_Type<T>*>& unbound_instances();
```

These are written during `bind()` (`Data_Type.ipp:53`) and read from many paths (`klass()`, `ruby_data_type()`, `is_bound()`, etc.). Under the assumption that binding happens during single-threaded init, this is fine. But Rice provides no enforcement of this contract.

**Severity:** LOW if init discipline is followed, MEDIUM if violated.

---

## 7. LOW: `NativeRegistry::lookup` Uses Mutating `operator[]`

**File:** `rice/detail/NativeRegistry.ipp:66-78`

```cpp
inline std::vector<std::unique_ptr<Native>>& NativeRegistry::lookup(VALUE klass, ID methodId)
{
  // ...
  return this->natives_[key];  // Creates entry if missing!
}
```

This `operator[]` inserts a default-constructed value if the key is absent. This means **every method resolution lookup is potentially a write operation**. Even if the GVL protects concurrent access, this unnecessarily grows the map with empty entries for every failed lookup, and it means there's no const-correct read path.

**Severity:** LOW (correctness issue more than thread-safety, but prevents any future const/shared-lock optimization).

---

## 8. Ractor Compatibility

Ruby Ractors enable true parallel execution. Rice's thread-safety model relies on the GVL, which Ractors bypass. Key issues:

- Global `Registries::instance` is shared mutable state with no synchronization
- Template static members (`Data_Type<T>::klass_`) are shared
- No `std::mutex` or `std::atomic` anywhere

The InstanceRegistry is the most critical piece because it is the only registry mutated at runtime (the others are written during init and read-only thereafter, with the exception of `NativeRegistry::lookup`'s `operator[]` bug noted in section 7). The recommended API in section 2d addresses the InstanceRegistry with an always-on mutex and atomic lookup-or-insert, which is the minimum change needed for Ractor safety of the runtime hot path.

---

## Summary Table

| # | Issue | Severity | GVL Protects? | Ractor-Safe? |
|---|-------|----------|---------------|--------------|
| 1 | NativeCallback static `native_` overwrite (no FFI) | HIGH | No - broken even single-threaded | No |
| 2 | InstanceRegistry TOCTOU + concurrent GC remove | MEDIUM | Yes (today) | No |
| 3 | NoGVL methods race on user C++ objects | HIGH (user) | N/A (by design) | No |
| 4 | Anchor bool TOCTOU race | LOW | Yes (today) | No |
| 5 | Registry concurrent read/write during late binding | MEDIUM | Mostly | No |
| 6 | Data_Type static members | LOW-MEDIUM | Yes if init discipline | No |
| 7 | NativeRegistry::lookup mutating reads | LOW | Yes | No |
| 8 | Ractor compatibility | N/A | N/A | No |

## Recommendations

1. **Fix NativeCallback (no-FFI path)** - This is a correctness bug independent of threading. The static `native_` pointer cannot be shared across instances.
2. **Add always-on mutex to InstanceRegistry with `lookup_or_wrap`** - See section 2d. Eliminates TOCTOU race, protects against concurrent GC `remove()`, enables Ractor safety for the runtime hot path. No compile-time flags needed -- the overhead is negligible.
3. **Make `NativeRegistry::lookup(klass, methodId)` use `find()` instead of `operator[]`** - Avoid mutating the map on reads. This is both a correctness fix and a prerequisite for any future read-write lock optimization.
4. **Make `Anchor::enabled_` and `exitHandlerRegistered_` `std::atomic<bool>`** - Trivial cost, eliminates a class of potential races.
5. **Document NoGVL thread-safety requirements** for users - Clearly state that `NoGVL` methods may execute concurrently and users must synchronize their own C++ objects.
