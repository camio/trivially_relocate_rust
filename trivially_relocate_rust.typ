#import "tlanginterop.typ" as tli

#show: tli.template.with(
  title: [Improving Rust/C++ Interop with Trivial Relocatability \[DRAFT\] ],
  authors: (
    (
      name: "David Sankel",
      department: "Primary Logistics Department",
      institution: "Adobe",
      city: "New York",
      country: "USA",
      mail: "dsankel@adobe.com",
    ),
  ),
  date: (
    year: 2025,
    month: "July",
    day: 9,
  ),
  keywords: (
    "C++",
    "Rust",
    "C++/Rust Interop",
    "Trivial Relocatability",
  ),
  abstract: [
      The transition of new development from C++ to memory-safe languages like
      Rust is a key strategy for improving software safety. However, this
      migration is often hindered by fundamental incompatibilities at the
      language boundary, particularly concerning object move semantics. In Rust,
      relocating an object is always a simple bitwise copy (memcpy), whereas in
      C++, it can trigger arbitrary user-defined code via move constructors.
      This semantic gap creates significant friction when integrating legacy C++
      code with modern Rust development.

      Current solutions impose undesirable trade-offs: heap allocating C++
      objects in Rust introduces performance overhead, while pinning them to
      memory degrades ergonomics and complicates API design. This paper presents
      a novel strategy that resolves this core incompatibility by leveraging the
      anticipated C++26 trivial relocatability feature. We demonstrate that a
      minor adjustment to the basis operation for this feature can make the vast
      majority of real-world C++ types trivially relocatable from Rust's
      perspective. This approach eliminates the performance and ergonomic
      penalties of existing methods, enabling seamless and efficient use of C++
      types within Rust.
  ],
)

= Introduction

The migration from memory-unsafe languages like C++ to memory-safe alternatives
like Rust is a critical strategy for enhancing software security, a point
underscored in a recent joint report by the NSA and CISA @NSA2025MemorySafe.
However, rewriting entire C++ codebases is often impractical, making seamless
interoperability between the two languages essential.

This interoperability presents significant challenges, particularly due to a
fundamental mismatch in how each language handles object relocation—the moving
of an object from one memory location to another. While modern tools like CXX
@cxx, Zngur @zngur, and Crubit @crubit have emerged to bridge the C++/Rust
divide, they still grapple with this semantic difference.

This paper proposes a novel solution to the relocation problem. We begin by
detailing the relocation semantics in both languages from a theoretical and
practical perspective (@sec-problem) and examining the drawbacks of existing
solutions (@sec-existing). We then show how C++26's new trivial relocatability
feature can be leveraged (@sec-trivial-relocatability) and introduce our key
contribution: a `start_lifetime_at` function that resolves the semantic gap
(@sec-start_lifetime_at). Finally, we outline the future work required to make
this solution production-ready for C++/Rust interop (@sec-future).

= Divergent Relocation Models in C++ and Rust <sec-problem>

While C++ and Rust both have mechanisms for relocating objects, their approaches
are fundamentally incompatible. Rust's move semantics are built on a universal
principle: a move is a destructive bitwise copy (`memcpy`). The compiler then
statically guarantees that the original object cannot be used again. This rule
applies to all types, with the only exception being those that implement the
`Copy` trait, which are also bit-copied but whose source remains valid.

Conversely, C++ relocation is a high-level operation defined by move
constructors and assignment operators. A C++ move is a function call, not a
guaranteed bit-copy, designed to "steal" internal resources. This leaves the
source object in a "valid but unspecified state," relying on runtime convention
to ensure it is handled safely.

This bitwise-copy behavior is deeply embedded throughout Rust and cannot be
overridden. Core language operations, from simple assignment to generic
functions like `std::ptr::read`@RustStdPtrRead, depend on the ability to safely
relocate any type via `memcpy`. This creates a fundamental conflict when trying
to interoperate with C++ types. A C++ object with a custom move constructor, for
example, cannot be safely relocated by Rust's universal bitwise copy, as this
would bypass the C++ object's essential logic, leading to incorrect program
state or memory errors.

== Why Arbitrary Bitwise Copies are Undefined in C++

In C++, you cannot safely create a copy of an arbitrary object by simply copying
its bits to a new memory location. Treating the resulting memory as a valid
object results in undefined behavior.

```
class Foo {
public:
  Foo();
  void bar();
// ...
};

void bar() {
  // Allocate raw, aligned memory buffers
  alignas(Foo) char x_buffer[sizeof(Foo)];
  alignas(Foo) char y_buffer[sizeof(Foo)];

  // Create a valid Foo object in the first buffer
  Foo* x = new (buffer) Foo();

  // Copy the raw bytes from the first buffer to
  // the second
  std::memcpy(&y_buffer, x, sizeof(Foo));

  // Treat the bytes in the second buffer as a
  // Foo object
  Foo* y = reinterpret_cast<Foo*>(y_buffer);

  y->bar(); // UNDEFINED BEHAVIOR
}

```

Intuitively, it makes sense to disallow this. If `Foo` contained a pointer to
one of its own members, the copied object `*y` would have a pointer pointing
back into the memory of the original object `*x`. C++ formalizes this by stating
that `y` doesn't point to an object within its lifetime.

The major exception to this rule is for _trivially copyable_ types.
These are types (like simple C-style structs) whose state is nothing more than
the sum of their bits. For these specific types, a bitwise copy is a valid way
to create a new object.
#footnote[
This is defined for trivially copyable types due to two clauses. First,
[cstring.cyn] paragraph 3 states that `memcpy` "implicitly creates objects in
the destination region of storage immediately prior to copying the sequence of
characters to the destination. Second, [basic.types.general] states "For two
distinct objects `obj1` and `obj2` of trivially copyable type `T`, where neither
`obj1` nor `obj2` is a potentially-overlapping subobject, if the underlying bytes
making up `obj1` are copied into `obj2`, `obj2` shall subsequently hold the same
value as `obj1`.
]
However, this excludes any class with virtual functions or custom copy, move, or
destructor logic.

== When Undefined Behavior Fails: Pointer Authentication

A common argument holds that because truly self-referential types are rare, the
C++ standard is overly aggressive in defining bitwise object relocation as
undefined behavior. This perspective was bolstered for years by the fact that
major compilers produced predictable results, enabling the development of
sophisticated relocation libraries like Bloomberg's BSL@BslRelocation and
Facebook's Folly@FollyRelocation.

However, this reliance demonstrates the classic danger of undefined behavior: a
program that works today can fail catastrophically after a compiler upgrade or a
change in hardware architecture.

This exact scenario unfolded with Apple's arm64e ABI@Arm64e, which introduced
Pointer Authentication Codes (PAC)@PointerAuthentication to mitigate security
vulnerabilities. This architecture uses an object's own memory address to
generate a cryptographic signature for its v-table pointer. Consequently, if a
polymorphic object is relocated with a simple bitwise copy, its v-pointer
becomes invalid because the signature—which was calculated from the old
address—no longer matches the object's new address. In essence, the arm64e ABI
made all polymorphic C++ objects self-referential, breaking any code that
depended on the non-standard assumption that they could be safely relocated.

= Existing solutions and their drawbacks <sec-existing>

== Pinning (CXX)

- Poor ergonomics
- Use examples from Zngur's rationale documentation.

== Allocation (Zngur)

= C++26's Trivial Relocatability <sec-trivial-relocatability>

- Introduce the idea
- Use existing formal wording

The March 2025 C++ draft standard @CppStandardDraft provides the following
`trivially_relocate` specification:

#tli.standardese[
```
template<class T>
T* trivially_relocate(T* first, T* last,
                      T* result);
```

_Mandates_: `is_trivially_relocatable_v<T> && !is_const_v<T>` is `true`. `T` is not an array of
unknown bound.

_Preconditions_:
- `[first, last)` is a valid range.
- `[result, result + (last - first))` denotes a region of storage that is a
  subset of the region reachable through result (6.8.4) and suitably aligned for
  the type `T`.
- No element in the range `[first, last)` is a potentially-overlapping subobject.

_Postconditions_: No effect if `result == first` is `true`. Otherwise, the range denoted by `[result, result
+ (last - first))` contains objects (including subobjects) whose lifetime has begun and whose object
representations are the original object representations of the corresponding objects in the source range
`[first, last)` except for any parts of the object representations used by the implementation to represent
type information (6.8.2). If any of the objects has union type, its active member is the same as that of
the corresponding object in the source range. If any of the aforementioned objects has a non-static data
member of reference type, that reference refers to the same entity as does the corresponding reference
in the source range. The lifetimes of the original objects in the source range have ended.

_Returns_: `result + (last - first)`.

_Throws_: Nothing.

_Complexity_: Linear in the length of the source range.

_Remarks_: The destination region of storage is considered reused (6.7.4). No constructors or destructors are invoked.

[_Note 2_: Overlapping ranges are supported. — _end note_]
]

== `start_lifetime_at` extension <sec-start_lifetime_at>

- Suggested alternative wording
- Fundamentally decouples the operation of copying memory and starting lifetimes.

#tli.standardese[
```
template<class T>
T* start_lifetime_at(uintptr_t origin,
                     void* p) noexcept;
```

_Mandates_: `is_trivially_relocatable_v<T> && !is_const_v<T>` is `true`.

_Preconditions_:
- [`p`, `(char*)p + sizeof(T)`) denotes a region of allocated storage that
  is a subset of the region of storage reachable through [basic.compound] `p`
  and suitably aligned for the type `T`.
- The contents of [`p`, `(char*)p + sizeof(T)`) is the value representation of
  an object `a` that was stored at `origin`.

_Effects_: Implicitly creates an object _b_ within the denoted region of type
`T` whose address is `p`, whose lifetime has begun, and whose object
representation is the same as that of _a_.

_Returns_: A pointer to the _b_ defined in the _Effects_ paragraph.
]

== An example C++/Rust interop usage

Say we have a polymorphic class hierarchy implemented in C++:

```Cpp
class Shape {
public:
  virtual float area() const = 0;
  virtual ~Shape() = default;
};

class Circle final : public Shape {
public:
  Circle(float radius);
  float area() const override;
private:
  float m_area;
};
```

We'd like to interact with this API idiomatically within Rust.

```Rust
let a = Circle::new(0.5);
let b = Circle::new(1.0);
a = b;
print("a's area: {}", a.area()); // Outputs ≈ 3.14159
```

To do so, we first observe that `Shape` and `Circle` are trivially
relocatable and replaceable types.
#footnote[A class is _eligible for trivial relocation_ if it lacks virtual base
classes, lacks base classes that are not trivially relocatable, lacks non-static
data members with object types that are not trivially relocatable, and lacks a
deleted destructor. A class is _trivially relocatable_ if it is _eligible for
trivial relocation_ and either has the `trivially_relocatable_if_eligible`
keyword, is a union with no user-declared special member functions, or is
default-movable. In this case, both `Shape` and `Circle` are default-movable so
the `trivially_relocatable_if_eligible` keyword is not required. See
@CppStandardDraft for the full specification.]
We denote the alignment of `Circle` as `CIRCLE_ALIGNMENT` and its size as
`CIRCLE_SIZE`.
#footnote[These can be determined at compile time by evaluating
`alignof(Circle)` and `sizeof(Circle)`]
Now we can define the Rust-side `Circle` type:

```Rust
#[repr(C)]
#[repr(align(CIRCLE_ALIGNMENT))]
struct Circle {
    data: Cell<[u8; CIRCLE_SIZE]>,
    origin: Cell<cpp_uintptr_t>
}
```

`data` holds the bit representation of the object and `origin` holds the
originating pointer which will be described later. Lets now turn to Circle's
methods. Their implementations are essentially boilerplate that delegates to
corresponding C functions prefixed with `c_`:

```Rust
impl Circle {
    fn new(radius: f32) -> Circle {
        let mut c = MaybeUninit::uninit();
        unsafe { c_create(
            c.as_mut_ptr() as *mut c_void,
            &radius as *const f32
                    as *mut c_void)};
        unsafe { c.assume_init() }
    }
    fn area(&self) -> f32 {
        let mut result = MaybeUninit::uninit();
        unsafe { c_area(
            result.as_mut_ptr() as *mut c_void,
            self as *const Circle
                 as *mut c_void)};
        unsafe { result.assume_init() }
    }
}
```

These C functions are implemented as follows:

```Cpp
void c_create(void* result, void* radius) {
    Circle *data = new (result)
        Circle(*static_cast<float*>(radius));
    uintptr_t *origin =
        reinterpret_cast<uintptr_t*>(data+1);
    *origin = reinterpret_cast<uintptr_t>(data);
}

void c_area(void* result, void* circle) {
    Circle *data = static_cast<Circle*>(circle);
    uintptr_t *origin =
        reinterpret_cast<uintptr_t*>(data+1);
    data = std::start_lifetime_at<Circle>(*origin,
                                          data);
    *origin = reinterpret_cast<uintptr_t>(data);
    *static_cast<float*>(result) = data->area();
}
```

Note that `origin` is used to ensure a `Circle` object is within its lifetime
before any C++ function is called.

= Future work <sec-future>

- Attempt to standardize `start_lifetime_at` as part of the C++26 cycle.
    - The fact that it makes trivial relocatability more general useful and
      solves the realloc issue will help here.
- Get standard types trivially relocatable in a portable way.
- Extend Zngur with this new method.

#bibliography("references.yml", style: "ieee")
