+++
author = "Jorge Aparicio"
date = 2018-02-17T18:16:39+01:00
draft = false
tags = ["ARM Cortex-M", "safety"]
title = "Zero cost stack overflow protection for ARM Cortex-M devices"
+++

One of the core features of Rust is memory safety. Whenever possible the compiler enforces memory
safety at compile. One example of this is the borrow checker which prevents data races, iterator
invalidation, pointer invalidation and other issues at compile time. Other memory problems like
buffer overflows can't be prevented at compile time. In those cases the compiler inserts runtime
checks, bounds checks in this case, to enforce memory safety at runtime.

What about stack overflows? For quite a long time Rust didn't have stack overflow checking but that
wasn't much of a problem on tier 1 platforms since these platforms have an OS and a MMU (Memory
Management Unit) that prevents stack overflows from wreaking havoc.

Consider this (silly) program that calls a recursive function that allocates a 1 MB array on the
stack.

``` rust
fn main() {
    println!("{}", fib(10));
}

#[inline(never)]
fn fib(n: u64) -> u64 {
    let _use_stack = [0u8; 1024 * 1024];

    if n < 2 {
        1
    } else {
        fib(n - 1) + fib(n - 2)
    }
}
```

If you run this safe program using last year nightly you get a segmentation fault.

``` console
$ # last year nightly
$ cargo run +nightly-2017-02-16
[1]    15156 segmentation fault (core dumped)  cargo run +nightly-2017-02-16
```

But if you run it with a recent nightly you'll get an abort and a meaningful error message.

``` console
$ cargo run +nightly-2018-02-16
thread 'main' has overflowed its stack
fatal runtime error: stack overflow
[1]    16042 abort (core dumped)  cargo run +nightly-2018-02-16
```

The difference in behavior is due to *stack probe* support landing in rustc / LLVM last year. Like
bounds checks, stack probes are also a runtime memory safety mechanism but for catching stack
overflows. At the time of writing only x86 / x86_64 has stack probe support in rustc / LLVM.

# MMU-less devices

But what's the effect of a stack overflow on bare metal devices that have no OS or a MMU like the
ARM Cortex-M?

Let's find out with this (silly) program:

``` rust
#![no_std]

extern crate cortex_m;
extern crate stm32f103xx;

use cortex_m::asm;

const PATTERN: u32 = 0xdeadbeef;

// initialize some RAM to a known bit pattern
static mut DATA: [u32; 1024] = [PATTERN; 1024];

fn main() {
    asm::bkpt();

    let _x = fib(100);
}

#[inline(never)]
fn fib(n: u32) -> u32 {
    if unsafe { DATA.last() } != Some(&PATTERN) {
        // `DATA` never changes so this should be unreachable, right?
        asm::bkpt();
    }

    // allocate and zero a 1KB of stack memory
    let _use_stack = [0u8; 1024];

    if n < 2 {
        1
    } else {
        fib(n - 1) + fib(n - 2)
    }
}
```

You can probably guess how this will go ... If you debug this program and inspect the memory where
`DATA` is located at the first breakpoint, before `fib` is called, you'll see something like this:

``` console
> # GDB
> continue
overflow::main () at src/main.rs:14
14          asm::bkpt();

> # breakpoint in `main`

> x/1028x 0x20000000 # inspect the DATA variable
0x20000000: 0xdeadbeef  0xdeadbeef  0xdeadbeef  0xdeadbeef  # start of DATA
(..)
0x20000ff0: 0xdeadbeef  0xdeadbeef  0xdeadbeef  0xdeadbeef  # end of DATA
0x20001000: 0xc260b0e9  0xda79849d  0x517bb7fa  0xa84886ba  # uninitialized RAM
```

That matches the expected bit pattern. So far so good.

If you resume the program until it hits the second breakpoint, the one inside the `fib` function,
you'll see this:

``` console
> continue
overflow::fib (n=86) at src/main.rs:22
22              asm::bkpt();

> # breakpoint in `fib`

> x/1028x 0x20000000
0x20000000: 0xdeadbeef  0xdeadbeef  0xdeadbeef  0xdeadbeef  # start of DATA
(..)
0x20000fb0: 0xdeadbeef  0xdeadbeef  0xdeadbeef  0xdeadbeef
0x20000fc0: 0x20000ffc  0x08001070  0x20000ffc  0x08001070
0x20000fd0: 0xdeadbeef  0x00000001  0x2000107c  0x08001074
0x20000fe0: 0x2000107c  0x08001074  0x20001048  0x0800036b
0x20000ff0: 0x20000000  0x00000001  0x00000000  0x00000001  # end of DATA
0x20001000: 0x00000000  0x00000001  0x2000107c  0x08001074
```

The `DATA` variable has been silently corrupted! Although this program has some `unsafe` code the
memory corruption is not caused by the `unsafe` code; it is caused by calling the `fib` function,
which is safe to call.

This means that ARM Cortex-M programs which only contain safe code can run into memory corruption
issues and that goes against Rust core feature of being memory safe. Let's fix it!

# Fixing it

Stack probes seems like the right way to fix this, but unfortunately stack probe support is only
available on x86 and here we are talking about the ARM Cortex-M architecture. There's another
problem as well: the [x86 implementation] of stack probes assumes there's some paging (virtual
memory) mechanism being used so that implementation can't be directly translated to bare metal ARM.
Finally, stack probes impose a runtime overhead on function calls so it's not a zero cost solution.

[x86 implementation]: https://github.com/rust-lang-nursery/compiler-builtins/blob/0ba07e49264a54cb5bbd4856fcea083bb3fbec15/src/probestack.rs#L50

Thankfully, there's another way to fix this and that's truly zero cost. Before I explain it let me
first show you how stack overflows cause memory corruption.

This is the memory layout of a bare metal Cortex-M program like the one I showed before.

<p align="center">
  <img alt="Stack overflow" src="/stack-overflow-protection/overflow.svg">
</p>

Static variables, like the `DATA` variable from the previous program, are stored at the bottom
(start) of RAM, in the `.bss` and `.data` sections, which are fixed in size. The stack is located
at the top (end) of RAM and it grows downwards. If the stack grows too large it can crash into
the `.bss+.data` section, overwriting it; this corrupts `static` variables.

The way to prevent stack overflows from corrupting memory is simple: you place the `.bss+.data`
section at the *top* of RAM and put the stack below it. Like this:

<p align="center">
  <img alt="Stack overflow" src="/stack-overflow-protection/swapped.svg">
</p>

In this scenario when the stack grows too large it ends up crashing into the boundary of the RAM
region and that triggers a *hard fault* exception. With this layout the `static` variables remain
safe during a stack overflow condition. Nice!

## `cortex-m-rt-ld`

Now all we need to do is change the memory layout of the program. The [`cortex-m-rt`] crate decides
the memory layout by providing a linker script to the linker. This linker script describes the
memory layout of the program in a declarative manner (details [here], if you are interested).

[here]: https://sourceware.org/binutils/docs/ld/Scripts.html

The problem is that linker scripts don't support arranging memory as we want: they only let you
specify the *start* address of sections like `.bss+.data` but in this case we want to specify the
*end* address of `.bss+.data`. We can't specify the start address of `.bss+.data` to be
`0x2000_4000` or some other fixed number because the correct number depends on the size of the
`.bss+.data` section and linker scripts don't provide support to get the size of an *output* section
-- simply because the size is not known at link time; the size of a section will only be known
*after* the linking process.

[`cortex-m-rt`]: https://crates.io/crates/cortex-m-rt
[linker script]: https://github.com/japaric/cortex-m-rt/blob/v0.3.13/link.x

The workaround for this missing linker script functionality is ... to link the program *twice* --
this technique is [also used in the C world][c]. Linking is done the first time to figure out the
size of the `.bss+.data` section; after linking you can run `arm-none-eabi-size` over the output
binary and find out the size. In the second linking step we feed the size of the section to the
linker script, as a *hardcoded* number, and use that to select the right start address of the
`.bss+.data` section.

[c]: https://stackoverflow.com/a/39477543

In C this two step linking is done using Makefiles. We can't replicate that approach in Rust because
it requires having the user explicitly write down the linker invocations and in Rust land linking is
done transparently by `rustc` / Cargo.

So what we'll do instead is to use a *linker wrapper*. Instead of linking the program using
`arm-none-eabi-ld` we'll use a linker wrapper called [`cortex-m-rt-ld`]. This wrapper is a Rust
program that will call the linker twice.

The only thing a user needs to do, apart from installing `cortex-m-rt-ld`, is to change the linker
in Cargo's configuration file:

[`cortex-m-rt-ld`]: https://crates.io/crates/cortex-m-rt-ld

``` console
$ # this file comes from the cortex-m-quickstart template v0.2.4
$ cat .cargo/config
[target.thumbv7m-none-eabi]
runner = 'arm-none-eabi-gdb'
rustflags = [
  "-C", "link-arg=-Tlink.x",
  "-C", "linker=cortex-m-rt-ld", # <- CHANGED!
  "-Z", "linker-flavor=ld",
  "-Z", "thinlto=no",
]

[build]
target = "thumbv7m-none-eabi"
```

This will make `rustc` invoke `cortex-m-rt-ld` with all the arguments it would normally pass to
`arm-none-eabi-ld`.

## In practice

Let's put this technique in practice by relinking the Cortex M program I showed before. But before
we do that let's look at the linker sections of the binary we debugged.

``` console
$ arm-none-eabi-size -Ax target/thumbv7m-none-eabi/debug/overflow
section                  size         addr
.vector_table           0x130    0x8000000
.text                   0xeb2    0x8000130
.rodata                 0x294    0x8000ff0
.stack                 0x5000   0x20000000
.bss                      0x0   0x20000000
.data                  0x1000   0x20000000
```

This output shows the start addresses and the sizes of the `.stack`, `.bss` and `.data` sections.
From the output you can see that they overlap: `.stack` starts at address `0x2000_5000` and ends at
address `0x2000_0000` (remember that it grows downwards); `.data` starts at address `0x2000_0000`
and ends at address
`0x2000_1000`.

Now let's relink the program using `cortex-m-rt-ld` and look at the linker sections again.

``` console
$ arm-none-eabi-size -Ax target/thumbv7m-none-eabi/debug/overflow
section                  size         addr
.vector_table           0x130    0x8000000
.text                   0xeb2    0x8000130
.rodata                 0x294    0x8000ff0
.stack                 0x4000   0x20000000
.bss                      0x0   0x20004000
.data                  0x1000   0x20004000
```

Now the sections don't overlap! `.stack` starts at address `0x2000_4000` and ends at address
`0x2000_0000`; `.data` starts at address `0x2000_4000` and ends at address `0x2000_5000`.

I mentioned that on stack overflow a hard fault exception would be triggered. Turns out we can
define *how* that is handled using the `exception!` macro so we can choose how the program should
behave on a stack overflow condition.

``` rust
#![no_std]

extern crate cortex_m;
#[macro_use(exception)] // NEW!
extern crate stm32f103xx;

// same program as before

// NEW!
exception!(HARD_FAULT, on_stack_overflow);

#[inline(always)]
fn on_stack_overflow() {
    asm::bkpt();
}
```

Now let's run this program.

```
> # GDB
> continue
overflow::main () at src/main.rs:15
15          asm::bkpt();

> # breakpoint in `main`

> continue
HARD_FAULT () at <exception macros>:14
14      <exception macros>: No such file or directory.

> # breakpoint in `on_stack_overflow`

> x/1028x 0x20003ff0
0x20003ff0: 0x00000000  0x00000000  0x00000014  0xffffffff
0x20004000: 0xdeadbeef  0xdeadbeef  0xdeadbeef  0xdeadbeef # start of DATA
(..)
0x20004ff0: 0xdeadbeef  0xdeadbeef  0xdeadbeef  0xdeadbeef # end of DATA
```

This time we hit the `HARD_FAULT` exception handler during the stack overflow and the `DATA`
variable remained intact.

# What if I have a heap?

When you have a heap and you use the standard memory layout you can run into two different problems:
a stack overflow can overwrite the `.heap`; and memory allocations can make the `.heap` grow too
large and crash into the `.stack`, overwriting it.

<p align="center">
  <img alt="Stack overflow" src="/stack-overflow-protection/heap.svg">
</p>

Again, tweaking the memory layout can prevent the problem. If you place the `.heap` at the top of
the RAM, place `.bss+.data` below it and the `.stack` below that then you avoid memory corruption in
both scenarios.

<p align="center">
  <img alt="Stack overflow" src="/stack-overflow-protection/swapped-heap.svg">
</p>

`cortex-m-rt-ld` supports this memory layout but it requires you to specify the size of the `.heap`
in a linker script. You can do that by adding a `_heap_size` symbol to `memory.x`, if you are
providing that file; or by passing a new linker script that provides that symbol to the linker.

The former will look like this:

``` console
$ tail -n1 memory.x
_heap_size = 0x400; /* 1 KB */
```

And the latter will look like this:

``` console
$ echo '_heap_size = 0x400;' > heap.x

$ cat .cargo/config
[target.thumbv7m-none-eabi]
runner = 'arm-none-eabi-gdb'
rustflags = [
  "-C", "link-arg=-Tlink.x",
  "-C", "link-arg=-Theap.x", # NEW!
  "-C", "linker=cortex-m-rt-ld",
  "-Z", "linker-flavor=ld",
  "-Z", "thinlto=no",
]

[build]
target = "thumbv7m-none-eabi"
```

Here are the linker sections of our running example after adding a 1 KB heap and linking it using
`cortex-m-rt-ld`.

``` rust
$ arm-none-eabi-size -Ax target/thumbv7m-none-eabi/debug/overflow
section                  size         addr
.vector_table           0x130    0x8000000
.text                   0xe8e    0x8000130
.rodata                 0x294    0x8000fc0
.stack                 0x3c00   0x20000000
.bss                      0x0   0x20003c00
.data                  0x1000   0x20003c00
.heap                   0x400   0x20004c00
```

Note how `.bss`, `.data` and `.stack` have been pushed *down* (towards a lower address) by the
`.heap`.

# Other configurations?

Currently `cortex-m-rt-ld` doesn't support memory layouts that involve more than one RAM region but
we don't have great support for that in `cortex-m-rt` either so there's no much point in supporting
that in `cortex-m-rt-ld` at the moment.

The approach described here doesn't help if you are using threads, where each one has its own stack.
In that scenario the thread stacks are laid out contiguously in memory and no amount of shuffling
around will prevent one from overflowing into the other. There pretty much your only choice is to
use a MPU (Memory Protection Unit) -- assuming your microcontroller has one -- to create stack
boundaries on demand. Using the MPU is not zero cost as there's some setup involved on each context
switch.

# Conclusion

That's it. Protect your ARM Cortex-M program from stack overflows and make it truly memory safe by
just swapping out the linker!

---

__Thank you patrons! :heart:__

I want to wholeheartedly thank:

<div class="grid">
  <div class="cell">
    <a href="https://www.sharebrained.com/" style="border-bottom:0px">
      <img alt="ShareBrained Technology" class="image" src="/logo/sharebrained.png"/>
    </a>
  </div>

  <div class="cell">
    <a href="https://www.pollen-robotics.com/" style="border-bottom:0px">
      <img alt="Pollen Robotics" class="image" src="/logo/pollen-robotics.png"/>
    </a>
  </div>

  <div class="cell">
    <a href="https://formation.sh/" style="border-bottom:0px">
      <img alt="Formation Aerosystems" class="image" src="/logo/formation.png"/>
    </a>
  </div>
</div>

[Iban Eguia],
[Aaron Turon],
[Geoff Cant],
[Harrison Chin],
[Brandon Edens],
[whitequark],
[James Munns],
[Fredrik Lundström],
[Kjetil Kjeka],
Kor Nielsen,
[Alexander Payne],
[Dietrich Ayala],
[Kenneth Keiter],
[Hadrien Grasland],
[vitiral]
and 48 more people for [supporting my work on Patreon][Patreon].

[Iban Eguia]: https://github.com/Razican
[Aaron Turon]: https://github.com/aturon
[Geoff Cant]: https://github.com/archaelus
[Harrison Chin]: http://www.harrisonchin.com/
[Brandon Edens]: https://github.com/brandonedens
[whitequark]: https://github.com/whitequark
[James Munns]: https://jamesmunns.com/
[Fredrik Lundström]: https://github.com/flundstrom2
[Kjetil Kjeka]: https://github.com/kjetilkjeka
<!-- [Kor Nielsen]: -->
[Alexander Payne]: https://myrrlyn.net/
[Dietrich Ayala]: https://metafluff.com/
[Kenneth Keiter]: http://kenkeiter.com/
[Hadrien Grasland]: https://github.com/HadrienG2
[vitiral]: https://github.com/vitiral

---

<!-- Let's discuss on [reddit]. -->

<!-- [reddit]: TODO -->

Enjoyed this post? Like my work on embedded stuff? Consider supporting my work
on [Patreon]!

[Patreon]: https://www.patreon.com/japaric

Follow me on [twitter] for even more embedded stuff.

[twitter]: https://twitter.com/japaricious

The embedded Rust community gathers on the #rust-embedded IRC channel
(irc.mozilla.org). Join us!
