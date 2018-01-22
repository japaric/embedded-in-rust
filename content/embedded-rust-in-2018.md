---
title: "Embedded Rust in 2018"
date: 2018-01-21T22:10:38+01:00
draft: false
---

This is my [#Rust2018] blog post.

[#Rust2018]: https://blog.rust-lang.org/2018/01/03/new-years-rust-a-call-for-community-blogposts.html

These are some things I think the Rust team needs to address this year to make Rust a (more) viable
alternative to C/C++ in the area of bare metal (i.e. `no_std`) embedded applications.

# Stability

Here's a list of breakage / regressions *I* encountered (i.e. that I had to work around / fix)
during 2017:

- Changes in target specification files broke compilation of no_std projects that use custom
  targets. Happened once or twice this year (it has happened in 2016 too); don't recall the exact
  number.

- Adding column information to panic messages, which changed the signature of `panic_fmt`, bloated
  binary size by 200-600%.

- ThinLTO, which became enabled by default, broke linking in release mode.

- Parallel codegen, which became enabled by default, broke linking in dev mode.

- Incremental compilation, which became enabled by default, broke linking in dev mode. Or maybe it
  was the `Termination` trait stuff. Neither is the direct cause but either change made [an old bug]
  resurface. This is still [unfixed] and disabling both incremental compilation and parallel codegen
  is the best way to avoid the problem.

[an old bug]: https://github.com/rust-lang/rust/issues/18807
[unfixed]: https://github.com/rust-lang/rust/issues/47074

- The `Termination` trait broke one of the core crates of the Cortex-M ecosystem (and every other
  user of the `start` lang item).

- A routine dependency update (`cargo update`) in rust-lang/rust broke one of Xargo use cases.
  Fixing the issue in Xargo broke another use case. Finally, undoing the fix a few days later fixed
  both use cases.

- A change in libcore broke compilation of it for ARMv6-M and MSP430, and probably other custom
  targets. This happened twice.

- I recall some breakage related to compiler-builtins but don't remember the details.

Note that only *two* of these are actually related to *feature gated* language features (`start` and
`panic_fmt`). Target specification files are not feature gated even though they are considered
unstable by the Rust team.

Ideally, this list should be empty this year. [As others have expressed][thejpster] it's
demotivating to come back to a project after a while and see that it no longer builds. And this
instability can be exhausting for library crate authors / maintainers, let me explain:

[thejpster]: http://railwayelectronics.blogspot.se/2018/01/i-recently-picked-up-embedded-project.html

If a library crate has 10 users those users can potentially use up to 10 *different* nightly
versions at any point in time. The bigger this nightly spread the higher the chance of (a) users
reporting issues, which usually are rustc issues or language level breaking changes, that
occur on nightlies newer than the one the crate author tested, and of (b) users reporting already
fixed issues that occur on nightlies older than the one the author tested.

I've seen some people suggest pinning crates to some specific nightly version using a
`rust-toolchain` file as a solution to the stability problem. That may work for projects centered
around binary crates like Servo and for projects that use monorepos like Tock but it doesn't work
for library crates because the `rust-toolchain` files of dependencies are ignored.

Library authors could enforce their crates to only build for a certain range of nightlies by
checking the compiler version in their crate build script but that makes them less composable: a
downstream user may not be able to use your crate if they are also using some other crate that
restricts its use to a range of nightlies incompatible with your crate's restrictions. There are
other issues as well: I actually tried this approach and [broke] the docs.rs build of my
`cortex-m-rt` crate *and* the docs.rs builds of all the reverse dependencies of my crate.

[broke]: https://docs.rs/crate/f3/0.5.0/builds/82700

## Establishing a first line of defense

Around half of the issues in my 2017 list were eventually fixed in rustc or in the std facade and
required no modification of user code. These issues could have been spotted and fixed by Rust
developers *before* they landed if the Rust test system incorporated building some embedded crates
as one of its tests.

Of course, compiler development should not be halted because some crate stops compiling due to a
breaking change in an unstable feature. In those cases, the result of building *that* crate should
explicitly marked as "ignore" to let the PR land.

Being able to ignore a failed build seems to defeat the purpose but even in that scenario this
system serves as a way to notify the crate author about the upcoming breakage; that way they can
start taking measures before the PR lands.

There's a mechanism for temporarily ignoring some parts of a CI build already in rust-lang/rust
(it's used to test the RLS, clippy, etc.) that could be could be used for this purpose.

## Stabilization in baby steps

The ultimate solution to the instability problem is to make embedded development possible on stable.
Unfortunately, that's unlikely to be accomplished in a single year: the number of unstable features
used in embedded development is not only long but also includes the hardest ones to stabilize:
language items, features for low level control of symbols, features tightly coupled to the backend,
etc.

Still, that doesn't mind we shouldn't make some progress this year. I think we can attack
stabilization from two fronts: (a) get embedded no-std libraries working on stable, and (b) get a
*minimal* no-std binary working on stable.

The feature list for (a) is not that long and it probably overlaps with the needs of non embedded
developers. The list contains:

- Xargo.
- `const fn`
- `asm!`

There may be more features but those are the most common.

The feature list for (b) in short:

- Xargo
- `panic_fmt`

That should be enough for applications where the boot sequence and compiler intrinsics are written
in C (e.g. when you link to newlibc, a libc for embedded systems). If you want to do everything in
Rust while providing the functionality you would get from newlib then the list becomes much longer:

- The `compiler_builtins` library
- `#[start]` entry point
- `#[used]`
- `Termination` trait (this wasn't in last year list ....)
- `#[linkage = "weak"]`

But I think it makes sense to start with the short version first.

How can we tackle the most pressing unstable features?

### Xargo

Xargo only works on nightly so if you it need for development you are stuck with nightly. The
general fix is to land [Xargo functionality in Cargo] and then stabilize it. But a more targeted and
faster fix would be to make a `rust-core` component available for some embedded targets,
`thumbv7m-none-eabi` for example.

The Cargo team has [expressed] their intention on working on the general fix this year so we should
see some progress.

[Xargo functionality in Cargo]: https://github.com/rust-lang/cargo/issues/4959
[expressed]: https://github.com/japaric/xargo/issues/193#issuecomment-359180429

### `const fn`

I know the plan is to swap the current const evaluator with [miri] to make const evaluation more
powerful. Personally, I wouldn't want that improvement to *delay* stabilization of the `const fn`
feature. Even in its current state, where it can only evaluate expression and other calls to const
fn, `const fn` is already very useful and widely used. I'd like to see the current, limited form
stabilized sometime this year and the miri version behind a feature gate.

[miri]: https://github.com/solson/miri


### `asm!`

I saw someone posted an `asm!` like macro that works on stable by compiling external assembly files
and using FFI to call into them. Unfortunately, that solution is not appropriate for this
application space, for several reasons:

- These assembly invocations can't be inlined (FFI works at the symbol level) so they will always
  have a function call indirection. `no_std` embedded applications are both performance and binary
  size sensitive; the indirection would put us behind C / C++ in both aspects.

- The function call indirection also makes impossible to have safe wrappers around things like "read
  the   Program Counter", or "read the Link Register". It also reduces the effectiveness of
  breakpoint instructions: the debugger ends in the wrong stack frame.

- You can't do `global_asm!` because of the FFI call. We use `global_asm!` in the ARM Cortex-M space
  to implement weak   aliasing since the language doesn't have support for it (C does).

- This adds a dependency on an external assembler or, worst, a C compiler (the implementation used a
  C compiler last time I checked). I would consider that a tooling regression. Today, building ARM
  Cortex-M applications only requires an external linker and we use `ld`, not `gcc`. LLD also
  works as a linker and as soon as LLD lands in rustc Cortex-M builds won't require *any external
  tool*.

Bottom line: we need proper inline assembly to be stabilized. And, yes, I know it's hard; which is
why I don't have any suggestion here :-).

### `panic_fmt`

I wrote an [RFC] for adding a stable mechanism to specify panicking behavior in `no_std`
applications that would remove the need for the `panic_fmt` lang item. The RFC has been accepted but
it has not been implemented yet. If you are looking for ways to help solve the instability problem
[implementing that RFC][rfc-impl] would be a great contribution!

[RFC]: https://github.com/rust-lang/rfcs/blob/master/text/2070-panic-implementation.md
[rfc-impl]: https://github.com/rust-lang/rust/issues/44489

# The `no_std` / `std` gap

Only a small fragment of crates.io ecosystem is `no_std` compatible but there are several crates
in the `std`-only category that could become `no_std` compatible:

- Some `std`-only crates can become `no_std` compatible simply by adding `#![no_std]` to the source
code. Many times this wasn't done from the beginning because the author wasn't aware it was possible
or because `#![no_std]` wasn't a priority for them.

- Some `std`-only crates only depend on re-exported things that are defined in the `core` and
`collections` crates. These could become `no_std` compatible by adding a `"std"` Cargo feature,
`#[cfg(not(std))] extern collections`, and a few other `#[cfg]` statements here and there.

- Some `std`-only crates depend on abstractions, like `CStr` and `HashMap`, that are defined in
`std` but that don't depend on OS abstractions like threads, sockets, etc.. This situation has led
`no_std` developers to *fork* these `std` abstractions to make them `no_std` compatible (cf.
[`cstr_core`] and [`hashmap_core`]) with the goal of making these crates.io crates `no_std`
compatible.

[`cstr_core`]: https://crates.io/crates/cstr_core
[`hashmap_core`]: https://crates.io/crates/hashmap_core

Making a crate `no_std` compatible needs to become simpler to avoid the scenario where people prefer
to create a *new* `no_std` compatible crate instead of making the ones already published `no_std`
compatible.

I don't have good suggestions here. Perhaps the first scenario could be improved with some `rustc` /
clippy lint that points out that the crate can be marked as `no_std` compatible. The second and
third scenarios *might* be addressed by the portable lint stuff, but I'm not familiar with that
feature.

UPDATE(2018-01-22) I think [this comment] by /u/Zoxc32 would be a great solution to the last two
scenarios.

[this comment]: https://www.reddit.com/r/rust/comments/7s0m6f/eir_embedded_rust_in_2018/dt1f5r2/

# Better IDE support

Another thing that C embedded developers are used to work with are IDEs with integrated embedded
tooling: register views, tracing and profiling. Of course, I'm not going to ask the Rust team to
implement embedded tooling but improvements to the RLS improve the IDE experience for everyone so
those are very welcome.

## Code completion

I'm personally really looking forward to *awesome* code completion support in the RLS. Recently I've
been writing some crates using [svd2rust] generated APIs and I'm afraid to admit that I had to
*disable* auto completion because it was slowing down my coding with delays of around one second and
because it didn't provide assistance where I needed it (it didn't suggest methods). `svd2rust`
generated crates are huge though; they usually contain thousands of structs, each one with a handful
of methods. I hope RLS powered code completion will be able to handle them!

[svd2rust]: https://crates.io/crates/svd2rust

# Language features

In embedded programs we tend to use a bunch of `static` variables. There are still some limitations
around `static` variables but some planned features would solve them. I'm personally looking forward
to these features:

## `impl Trait` everywhere

As I mentioned in my [previous] blog post we want to write generic async drivers but to do that we
need traits whose methods return generators and that doesn't work right now so we are blocked on
that front.

[previous]: /brave-new-io

``` rust
trait Write {
    fn write_all<B>(
        self,
        buffer: B,
    ) -> impl Generator<Return = (Self, B), Yield = ()> where ..;
    // `-> Box<..>` would work but don't want to depend on a memory allocator
}
```

There's also a use case for storing generators in `static` variables. That could potentially let us
write reactive code (code that gets dispatched in interrupt handlers) in a more natural way
("straight line" code). Today, that reactive style requires hand writing state machines.

``` rust
// Some DSL (macro) could expand to something like this

static mut GN: Option<impl Generator<Return = (), Yield = ()>> = None;

fn interrupt_handler() {
    // do some magic with `GN`
}
```

## Const generics

Often we need collections like [`Vec`]s and [queues] with fixed, known at compile time, capacities.
Those collections internally use arrays as buffers and need to have their capacity (the array size)
parametrized in their types. The problem is that the capacity is a number not a type.

[`Vec`]: https://docs.rs/heapless/0.2.1/heapless/struct.Vec.html
[queues]: https://docs.rs/heapless/0.2.1/heapless/ring_buffer/struct.RingBuffer.html

I tried using `AsRef` and `AsMut` as bounds but they didn't cut it because they are limited to
arrays of 32 elements.

```
fn example<T>(xs: &T) where
    T: AsRef<[u8]>,
{
    // ..
}

let xs = [0; 33];
example(&xs);
//~^ error: `AsRef<[u8]>` not implemented for `[u8; 33]`
```

So I'm currently using the `Unsize` trait and it works for arrays of any size but it's a hack (not
its intended usage) and it makes type signatures weird.

``` rust
struct Vec<T, B>
where
    B: Unsize<[T]>,
{
    buffer: B, // B is effectively `[T; N]`
    /* .. */
}

impl<T, B> Vec<T, B>
where
    B: Unsize<[T]>,
{
    fn pop(&mut self) -> Option<T> {
        // unsize the array
        let slice: &mut [T] = &mut self.array;
        // ..
    }
}

fn example(xs: &mut Vec<u8, [u8; 33]>) { .. }
//                      odd ^^^^^^^^
```

With const generics we would be able to *directly* parametrize the capacity in the `Vec` type:

``` rust
struct Vec<T, const N: usize> {
    buffer: [T; N],
    /* .. */
}

fn example(xs: &mut Vec<u8, 33>) { .. }
//                   better ^^
```

This one's not a blocker but would be nice to have. We only need the most basic version of const
generics, which has already been accepted, so I'm hoping it gets implemented sooner than latter.

---

That's my wishlist for the Rust team. Let's make 2018 a great year for embedded Rust!

Let's discuss on [reddit].

[reddit]: https://www.reddit.com/r/rust/comments/7s0m6f/eir_embedded_rust_in_2018/
