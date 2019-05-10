+++
author = "Jorge Aparicio"
date = 2019-05-10T15:33:00+02:00
draft = false
tags = ["AMP", "concurrency", "multi-core"]
title = "μAMP: Asymmetric Multi-Processing on microcontrollers"
+++

> An asymmetric multiprocessing (AMP) system is a multiprocessor computer system
> where not all of the multiple interconnected central processing units (CPUs)
> are treated equally. -- [Wikipedia]

[Wikipedia]: https://en.wikipedia.org/wiki/Asymmetric_multiprocessing

# What is μAMP?

[`microamp`][microamp] (styled as μAMP) is a framework (library plus cargo
subcommand) for building bare-metal applications that target AMP systems.

[microamp]: https://crates.io/crates/microamp/0.1.0-alpha.1

This blog post is a deep dive into this framework which serves as the core
foundation of the *multi-core* version of [Real Time For the Masses
(RTFM)][rtfm], which I'll cover in the next blog post.

[rtfm]: https://japaric.github.io/cortex-m-rtfm/book/en/

# Why?

Historically, microcontrollers have been designed as single-core Systems On a
Chip (SoCs) but newer designs are increasingly opting for an *heterogeneous*
multi-core architecture. For example, the NXP's LPC43xx series pairs a Cortex-M4
processor with one (or more) Cortex-M0 co-processor(s) in a single package. The
goal of these designs is usually optimizing power consumption: for example, the
lower power M0 can handle all the I/O and the M4 core is only activated to
perform expensive floating-point / DSP computations.

The μAMP model lets us target these kind of systems but can also be applied to
*homogeneous* multi-core systems like the dual-core real-time processor (2 ARM
Cortex-R5 cores) on the [Zynq UltraScale+ EG][zup] or the LPC55S69 (2 ARM
Cortex-M33 cores) microcontroller.

# What it looks like?

μAMP takes after CUDA's "single source" / hybrid model in the sense that one can
write a single program (crate) that will run on multiple cores of potentially
different architectures. To statically partition the application across the
cores one uses the conditional compilation support that's built into the
language, that is `#[cfg]` and `cfg!`.

Here's a contrived μAMP program that targets the dual-core real-time processor
(2x ARM Cortex-R5 cores) on the [Zynq UltraScale+ EG][zup].

[zup]: https://www.xilinx.com/products/silicon-devices/soc/zynq-ultrascale-mpsoc.html

([Here] you can find the complete source code of this and other examples shown
in this post)

[here]: https://github.com/japaric/ultrascale-plus/tree/4c15efe749a59f807d21bbe4f9fe21dec96eb90a/firmware/zup-rtfm/examples

``` rust
// examples/amp-hello.rs

#![no_main]
#![no_std]

use arm_dcc::dprintln;
use panic_dcc as _; // panic handler
use zup_rt::entry;

// program entry point for both cores
#[entry]
fn main() -> ! {
    static mut X: u32 = 0;

    // `#[entry]` transforms `X` into a `&'static mut` reference
    let x: &'static mut u32 = X;

    let who_am_i = if cfg!(core = "0") { 0 } else { 1 };
    dprintln!("Hello from core {}", who_am_i);

    dprintln!("X has address {:?}", x as *mut u32);

    loop {}
}
```

The [`cargo-microamp`] subcommand is used to compile this program for each core.

[`cargo-microamp`]: https://crates.io/crates/microamp-tools/0.1.0-alpha.1

``` console
$ # by default cargo-microamp assumses 2 cores but
$ # this can be overridden with the `-c` flag
$ cargo microamp --example amp-hello -v
(..)
"cargo" "rustc" "--example" "amp-hello" "--release" "--" \
  "--cfg" "core=\"0\"" \
  "-C" "link-arg=-Tcore0.x" \
  "-C" "link-arg=/tmp/cargo-microamp.GSj3FpvLfYTR/microamp-data.o"
    Finished dev [unoptimized + debuginfo] target(s) in 0.10s

"cargo" "rustc" "--example" "amp-hello" "--release" "--" \
  "--cfg" "core=\"1\"" \
  "-C" "link-arg=-Tcore1.x" \
  "-C" "link-arg=/tmp/cargo-microamp.GSj3FpvLfYTR/microamp-data.o"
    Finished dev [unoptimized + debuginfo] target(s) in 0.11s
```

This subcommand produces two images, one for each core.

``` console
$ # image for core #0
$ size -Ax target/armv7r-none-eabi/release/examples/amp-hello-0
target/armv7r-none-eabi/debug/examples/amp-hello-0  :
section             size         addr
.text              0x4fc          0x0
.local               0x0      0x20000
.bss                 0x4   0xfffc0000
.data                0x0   0xfffc0004
.rodata             0x40   0xfffc0004
.shared              0x0   0xfffe0000

$ # image for core #1
$ size -Ax target/armv7r-none-eabi/release/examples/amp-hello-1
target/armv7r-none-eabi/debug/examples/amp-hello-1  :
section              size         addr
.text              0x4fc          0x0
.local               0x0      0x20000
.bss                 0x4   0xfffd0000
.data                0x0   0xfffd0004
.rodata             0x40   0xfffd0004
.shared              0x0   0xfffe0000
```

As you can see the linker sections (`.bss`, `.data`, etc) of each image are
placed at different addresses. The memory layout of these images is specified by
the linker scripts `core0.x` and `core1.x`. These must be provided by the user
or by some crate (the `zup-rt` crate in this case). Later I'll talk about those
linker scripts in detail.

These images can be executed independently; this is their output:

``` console
$ # on another terminal: load and run the program
$ CORE=0 xsdb -interactive debug.tcl amp-hello-0

$ # output of core #0
$ tail -f dcc0.log
Hello from core 0
X has address 0xfffc0000
```

``` console
$ # on another terminal: load and run the program
$ CORE=1 xsdb -interactive debug.tcl amp-hello-1

$ # the output of core #1
$ tail -f dcc1.log
Hello from core 1
X has address 0xfffd0000
```

Note here that each core reports a different address for variable `X`. I'll get
back to this later.

So far `cargo-microamp` doesn't seem to offer much advantage. One could build
each of these images separately by calling `cargo build` twice.

The magic of the framework comes in when you use the `#[shared]` attribute.

# `#[shared]` memory

The static variable `X` we used in the previous program does *not* refer to the
same memory location: each image has *a copy* of the variable `X`. This can be
seen in the output of the program where each core reports a different address of
the variable `X`.

To place a variable in shared memory one has to opt-in using the `#[shared]`
attribute provided by the `microamp` crate. `#[shared]` variables can be used to
synchronize program execution and / or share / exchange data. Here's an example:

``` rust
// examples/amp-shared.rs

#![no_main]
#![no_std]

use core::sync::atomic::{AtomicU8, Ordering};

use arm_dcc::dprintln;
use microamp::shared;
use panic_dcc as _; // panic handler
use zup_rt::entry;

// non-atomic variable
#[shared] // <- means: same memory location on all the cores
static mut SHARED: u64 = 0;

// used to synchronize access to `SHARED`
#[shared]
static SEMAPHORE: AtomicU8 = AtomicU8::new(CORE0);

// possible values for SEMAPHORE

const CORE0: u8 = 0;
const CORE1: u8 = 1;
const LOCKED: u8 = 2;

#[entry]
fn main() -> ! {
    let (our_turn, next_core) = if cfg!(core = "0") {
        (CORE0, CORE1)
    } else {
        (CORE1, CORE0)
    };

    dprintln!("START");

    let mut done = false;
    while !done {
        // try to acquire the lock
        while SEMAPHORE
            .compare_exchange(our_turn, LOCKED, Ordering::AcqRel, Ordering::Relaxed)
            .is_err()
        {
            // busy wait if the lock is held by the other core
        }

        // we acquired the lock; now we have exclusive access to `SHARED`
        unsafe {
            if SHARED >= 10 {
                // stop at some arbitrary point
                done = true;
            } else {
                dprintln!("{}", SHARED);

                SHARED += 1;
            }
        }

        // release the lock & unblock the other core
        SEMAPHORE.store(next_core, Ordering::Release);
    }

    dprintln!("DONE");

    loop {}
}
```

In this program the two cores increase the non-atomic `SHARED` variable *in
turns*. The atomic `SEMAPHORE` variable is used to synchronized access to the
`SHARED` variable.

Both variables are placed in shared memory so they bind to the same memory
location. We can confirm this by looking at the symbols of each image.

``` console
$ # image for core #0

$ # output format: $address $size $symbol_type $symbol_name
$ arm-none-eabi-nm -CSn amp-shared-0
(..)
fffc0000 00000008 D SHARED
fffc0008 00000001 D SEMAPHORE
```

``` console
$ # image for core #1

$ # output format: $address $size $symbol_type $symbol_name
$ arm-none-eabi-nm -CSn amp-shared-1
(..)
fffc0000 00000008 D SHARED
fffc0008 00000001 D SEMAPHORE
```

If we run core #0 we'll see ..

``` console
$ # on another terminal:
$ CORE=0 xsdb -interactive debug.tcl amp-shared-0

$ # output of core #0
$ tail -f dcc0.log
START
0
```

.. that the program halts because it's waiting for the other core. Now, we run
core #1 ..

``` console
$ # on another terminal:
$ CORE=1 xsdb -interactive debug.tcl amp-shared-1

$ # output of core #1
$ tail -f dcc1.log
START
1
3
5
7
9
DONE
```

.. and we'll get new output from core #0.

``` console
$ # output of core #0
$ tail -f dcc0.log
START
0
2
4
6
8
DONE
```

That's all the μAMP framework gives you: sound and memory safe inter-processor
communication over shared memory. Sounds simple, right? The API *is* simple but
the implementation was rather tricky. This is Rust so if something does *not*
need `unsafe` then it *must* be memory safe and sound under *all* possible
scenarios; that's what makes it tricky.

Let's now analyze the soundness of the `#[shared]` abstraction.

# To `Send` or `!Send`

As soon as you get shared memory you can *send* (move) values from one core to
the other: for example, a `Mutex<Option<T>>` can be used as a poor man's
channel. Consider this program:

``` rust
#![no_main]
#![no_std]

use core::sync::atomic::{AtomicBool, Ordering};

use arm_dcc::dprintln;
use microamp::shared;
use panic_dcc as _; // panic handler
use spin::Mutex; // spin = "0.5.0"
use zup_rt::entry;

#[shared]
static CHANNEL: Mutex<Option<&'static mut [u8; 1024]>> = Mutex::new(None);

#[shared]
static READY: AtomicBool = AtomicBool::new(false);

// runs on first core
#[cfg(core = "0")]
#[entry]
fn main() -> ! {
    static mut BUFFER: [u8; 1024] = [0; 1024];

    dprintln!("BUFFER is located at address {:?}", BUFFER.as_ptr());

    // send message
    *CHANNEL.lock() = Some(BUFFER);

    // unblock core #1
    READY.store(true, Ordering::Release);

    loop {}
}

// runs on second core
#[cfg(core = "1")]
#[entry]
fn main() -> ! {
    // wait until we receive a message
    while !READY.load(Ordering::Acquire) {
        // spin wait
    }

    let buffer: &'static mut [u8; 1024] = CHANNEL.lock().take().unwrap();

    dprintln!("Received a buffer located at address {:?}", buffer.as_ptr());

    // is this sound?
    // let first = buffer[0];

    loop {}
}
```

This program could print something like this:

``` console
$ # output of core #0
$ tail -f dcc0.log
BUFFER is located at address 0xfffc0000
```

``` console
$ # output of core #1
$ tail -f dcc1.log
Received a buffer located at address 0xfffc0000
```

If core #1 reads or writes to the buffer it received from core #0, would the
program still be sound? The answer is *it depends*. It depends on the target
device and the memory layout of each image.

## Memory location matters

Let's take the UltraScale+ as an example. This device has many memory blocks
with different performance characteristics. Each R5 core has 3 blocks of Tightly
Coupled Memory (TCM) named ATCM (64 KB), BTCM0 (32 KB) and BTCM1 (32 KB). The
idea behind the TCM is that it should be exclusively accessed by a single core;
this makes memory access low latency and predictable.

Apart from the TCM there's 256 KB of On-Chip Memory (OCM) divided in 4 blocks of
64 KB. This memory region is meant to be used to share data / exchange messages
between the R5 cores.

Each TCM and OCM block has a different *global* address. The TCM blocks of each
R5 core are a bit special because they are additionally mapped (aliased) at
address 0. See the table below:

|           |R5#0 view    |R5#1 view    |Global address    |
|-----------|-------------|-------------|------------------|
|R5#0 ATCM  |`0x0000_0000`|~            |`0xFFE0_0000`     |
|R5#0 BTCM0 |`0x0002_0000`|~            |`0xFFE2_0000`     |
|R5#0 BTCM1 |`0x0002_8000`|~            |`0xFFE2_8000`     |
|R5#1 ATCM  |~            |`0x0000_0000`|`0xFFE9_0000`     |
|R5#1 BTCM0 |~            |`0x0002_0000`|`0xFFEB_0000`     |
|R5#1 BTCM1 |~            |`0x0002_8000`|`0xFFEB_8000`     |
|OCM0       |~            |~            |`0xFFFC_0000`     |
|OCM1       |~            |~            |`0xFFFD_0000`     |
|OCM2       |~            |~            |`0xFFFE_0000`     |
|OCM3       |~            |~            |`0xFFFF_0000`     |

This means that if both cores execute the operation `(0x2_0000 as *const
u32).read()` they will actually read different memory locations and likely get
different results.

An important question here is: Can core #0 access core #1's TCM? The answer is
*yes*, core #0 can read and write to core #1's TCM through its global address
(e.g. `0xFFE9_0000`). However, this operation is *very slow* and will likely
degrade the performance of core #1's accesses to its own TCM.

There are many ways to arrange the memory layout of each image; some of them
can make our previous program unsound. For example, if we place the `.data` and
`.bss` sections of both images (core #0's `.bss` contains the `BUFFER` variable)
at address `0x2_0000` (that is in BTCM0) it would become possible to break Rust
aliasing rule with *no* `unsafe` code. This can be more easily observed if we
tweak our previous program like this:

``` rust
// keep the rest of the program the same

#[cfg(core = "1")]
#[entry]
fn main() -> ! {
    static mut X: [u8; 1024] = [0; 1024]; // NEW!

    // wait until we receive a "message"
    while !READY.load(Ordering::Acquire) {
        // spin wait
    }

    let buffer: &'static mut [u8; 1024] = CHANNEL.lock().take().unwrap();
    let x: &'static mut [u8; 1024] = X; // NEW!

    dprintln!("Received a buffer located at address {:?}", buffer.as_ptr());
    dprintln!("X has address {:?}", x.as_ptr()); // NEW!

    // would this be sound?
    // let head = buffer[0];

    loop {}
}
```

Running this program produces this output:

``` console
$ # output of core #1
$ tail -f dcc1.log
Received a buffer located at address 0x20000
X has address 0x20000
```

:collision: Mutable aliasing! :collision:

Yikes, using the aliased address of the TCM (`0x000?_????`) leads to Undefined
Behavior in safe Rust. What went wrong? On core #0 `BUFFER` is an owning pointer
to a 1KB buffer with value `0x2_000` which is an alias for the global address
`0xFFE2_000`. On core #1 `X` is an owning pointer to a 1KB buffer with value
`0x2_000` which is an alias for the global address `0xFFEB_0000`. So far so
good, there's no overlap between these two pointers because they point to
different memory locations (see global addresses). The problem is that sending
the `BUFFER` pointer to the other core effectively changes where it actually
points to (from global address `0xFFE2_000` to global address `0xFFEB_0000`),
even though its value is unchanged.

One way to fix this issue is to use the TCM *global* addresses (i.e.
`0xFFE?_????`) instead of the aliased addresses. Using global addresses
everywhere changes the output of the program to:

``` console
$ tail -f dcc1.log
Received a buffer located at address 0xffe20000
X has address 0xffeb0000
```

No mutable aliasing in this case.

But, is there any difference between using the aliased address (e.g. `0x2_0000`)
and using the global address (e.g. `0xFFE2_0000`) to access the TCM? Yes,
there's a huge difference. Both addresses refer to the same physical memory but
the aliased address goes through the fast TCM bus, whereas the global address
goes through the slower AXI interface.

But how much is a "huge" difference? We can measure it. Consider the following
program:

``` rust
#[cfg(core = "0")]
#[entry]
fn main() -> ! {
    static mut X: [u8; 1024] = [0; 1024];

    let start = Instant::now();
    for x in X.iter_mut() {
        unsafe {
            ptr::write_volatile(x, ptr::read_volatile(x) + 1);
        }
    }
    let end = Instant::now();

    // `checked` version to avoid panicking branches
    if let Some(dur) = end.checked_duration_since(start) {
        print(dur);
    }

    loop {}
}

// never inline to minimize impact on `main` (e.g. register spilling)
#[inline(never)]
fn print(dur: Duration) {
    dprintln!("{}", dur.as_cycles());
}
```

This program performs a RMW operation on each byte of a 1 KB array and the whole
operation is timed. Let's see how long this takes depending on *where* the array
`X` is located.

|Location                 |`X.as_ptr()`  |Clock cycles |Ratio|
|-------------------------|--------------|-------------|-----|
|BTCM0 (aliased address)  |`0x0002_0000` |1,462        |1.00 |
|BTCM0 (global address)   |`0xFFE2_0000` |23,171       |15.8 |
|OCM0                     |`0xFFFC_0000` |13,340       |9.1  |

Ouch, accessing the TCM through its global address is 15-16x slower. Even
accessing the OCM is faster (~2x) than accessing the TCM through its global
address.

## Memory safe program layout

Regardless of the performance, we must default to a memory safe program layout
so we'll pick the following layout:

- The stack will be placed at the end of aliased BTCM1 (`0x3_0000`). Note that
  the stack grows downwards, towards smaller addresses.

*Rationale*: References to stack variables can *not* be sent to a different core
because they have non-static lifetimes and to place a value in a static variable
it must only contain static lifetimes ( there's an implicit `T: 'static` bound
on all static variables).

- Code (`.text`) is placed in the aliased ATCM0 (`0x0`).

*Rationale*: We actually have no choice on this one. We'll return to this later.

- Constants (`.rodata`) and static variables (`.bss` and `.data`) are placed in
  OCM0 (core #0) or OCM1 (core #1).

*Rationale*: References to static variables (`&'static mut` / `&'static`) can
safely be sent across cores so they must *not* be placed in the aliased TCM or
we'll run into the problem described above. We choose the OCM instead of the
"global" TCM (`0xFFE?_????`) because the former has better performance.

- `#[shared]` variables (`.shared`) are placed in OCM2 (both cores).

*Rationale*: We'll return to this later

The bottom line here is that it's safe (as in it doesn't require `unsafe`) to
send static references across the core boundary so one must think about whether
that's actually sound (doesn't result in Undefined Behavior). In particular, one
must think about these scenarios:

- Sending a string literal (`&'static str`) or a static reference into something
  immutable (e.g. `&'static i32`). These point into the `.rodata` section.

- Sending a static reference into something mutable (e.g. `&'static mut u32` or
  `&'static AtomicU32`). These point into the `.bss` and `.data` sections.

The UltraScale+ is particularly tricky because it aliases memory in hardware.
To prevent footguns one must not place static variables in aliased memory even
if this significantly degrades performance.

It is possible to recover the performance using `#[link_section]` to place a
static variable in the aliased memory (see below). However, one must be careful
and never send a reference to this static variable to a different core.

``` rust
#[entry]
fn main() -> ! {
    // place this in the BTCM0
    #[link_section = ".btcm0.BUFFER"]
    static mut BUFFER: [u8; 128] = [0; 128];

    // prints `0x2_0000`
    dprintln!("{:?}", BUFFER.as_ptr());
}
```

Using `#[link_section]` is actually a unsafe operation even though the above
program doesn't contain any `unsafe` block -- a lot of stuff can go horribly
wrong if you misuse `#[link_section]`. This is something we didn't think about
carefully enough in preparation for Rust 1.0 and I hope we'll fix by the next
edition: that is `#[link_section]` should require the `unsafe` keyword somewhere
and be rejected by `#[deny(unsafe_code)]`.

## Data not code

Are we completely safe with just using a certain memory layout? The answer is:
in the general case, *no*; and in the particular case of UltraScale+, *also no*.

The issue is that one can not only safely send pointers to *data* across the
core boundary; one can also safely send pointers to *code*. Function pointers
(e.g. `fn()`) obviously qualify as pointers to code; less obviously, trait
objects also qualify as pointers to code (they contain a vtable pointer). One
should not send either across the core boundary.

But what's the problem with pointers to code? Consider this `unsafe`-less,
seemingly OK program that's *rejected* by the μAMP framework:

``` rust
// slight variation of the `amp-channel` example

#[shared]
static CHANNEL: Mutex<Option<fn()>> = Mutex::new(None);
//~ error: the trait bound `fn(): DataNotCode` is not satisfied in Mutex<Option<fn()>>

#[shared]
static READY: AtomicBool = AtomicBool::new(false);

// runs on first core
#[cfg(core = "0")]
#[entry]
fn main() -> ! {
    fn foo() {
        dprintln!("foo");
    }

    let f: fn() = foo;

    *CHANNEL.lock() = Some(f);

    // unblock core #1
    READY.store(true, Ordering::Release);

    loop {}
}

// runs on second core
#[cfg(core = "1")]
#[entry]
fn main() -> ! {
    // wait until we receive a "message"
    while !READY.load(Ordering::Acquire) {
        // spin wait
    }

    let f: fn() = CHANNEL.lock().take().unwrap();

    // is this sound?
    f();

    loop {}
}
```

This is a variation of `amp-channel` where we send a function pointer from one
core to the other. Why is this program rejected?

In the general case we could have a heterogeneous device where one core uses
instruction set `X` (e.g. Cortex-M4F Thumb2 encoded instructions) and the
other core uses instruction set `Y` (e.g. Cortex-R5 ARM encoded instructions);
executing a function encoded using instruction set `X` on the core that uses
instruction set `Y` is Undefined Behavior -- *if* you are lucky this operation
will make the core jump into some exception handler but anything could happen.

That's why we reject this operation in the `#[shared]` attribute using a trait
bound. Both function pointers (`fn(..) -> _`) and trait objects (`dyn Trait`)
are rejected.

"But the UltraScale+ is an *homogeneous* multi-core device! Both cores use the
same instruction set so the above program ought to be OK, right?" Unfortunately,
the UltraScale+ is a complex device so the above program is still not OK.

The R5 cores in the UltraScale+ can only execute code that's located in the TCM
*and* fetched from the aliased address range (`0x000?_????`). Trying to execute
code located in the OCM results in a *prefetch abort* at runtime. Same thing if
the core tries to fetch code from the global address of the TCM (`0xFFE?_????`).

Thus we have no choice but to place the `.text` section (all functions) in the
*aliased* TCM, that is at address `0x000?_????`. Once we have done that we can
no longer safely send function pointers between the cores due to the aliasing
problem we saw before -- each core would interpret the same address
`0x000?_????` as different memory locations.

# How is `#[shared]` implemented?

Getting `#[shared]` to work required a bit of linker (script) magic. Let's see
how it works.

`#[shared]` is a procedural macro attribute (`proc_macro_attribute`) that
performs a small source level transformation. Let's see the expanded code:

``` rust
// user input
#[shared]
static mut SHARED: u64 = 0;
```

``` rust
// attribute expansion
#[cfg(microamp)]
#[link_section = ".shared"]
#[no_mangle]
static mut SHARED: u64 = {
    fn assert() {
        // used to check that `u64` is not a function pointer or trait object
        microamp::export::is_data::<u64>();
    }

    0
};

#[cfg(not(microamp))]
extern {
    static mut SHARED: u64;
}
```

The application code will be compiled *without* `--cfg microamp` so it will use
the *external* (`extern`) `SHARED` variable. The "definition" of this external
variable (its size and initial value) must be provided at link time or linking
will fail. That's where the `#[cfg(microamp)]` item comes in. When one invokes
the `cargo-microamp` subcommand it first compiles the application with `--cfg
microamp` and produces a single object file.

``` console
$ cargo microamp --example amp-shared -v
"cargo" "rustc" "--example" "amp-shared" "--" \
  "-C" "lto" \
  "--cfg" "microamp" \
  "--emit=obj" \
  "-A" "warnings" \
  "-C" "linker=microamp-true"
(..)
```

This object file contains all the `#[shared]` variables packed in a *single*
linker section named `.shared`.

``` console
$ size -Ax $(find target -name '*.o')
target/armv7r-none-eabi/debug/examples/amp_shared-6ca3c73e139e6dd1.o  :
(..)
.shared                                          0x9    0x0
(..)
```

`cargo-microamp` then strips this object file from all linker sections but the
one named `.shared`, renames it to `microamp-data.o` and places it in a
temporary directory.

``` console
$ cargo microamp --example amp-shared -v
(..)
"arm-none-eabi-strip" \
  "-R" "*" \
  "-R" "!.shared" \
  "--strip-unneeded" \
  "/tmp/cargo-microamp.GSj3FpvLfYTR/microamp-data.o"
```

These are the contents of the object file after running `arm-none-eabi-strip`.

``` console
$ size -Ax microamp-data.o
microamp-data.o  :
section   size   addr
.shared    0x9    0x0
Total      0x9

$ # output format: $address $size $symbol_type $symbol_name
$ arm-none-eabi-nm -CSn microamp-data.o
00000000 00000008 D SHARED
00000008 00000001 D SEMAPHORE
```

Note that the input object files (`.o`) are relocatable so the addresses
reported by `nm` are not final; only the reported size is final.

When `cargo-microamp` links the image for each core it passes the path to this
stripped object file to the linker.

``` console
$ cargo microamp --example amp-shared -v
(..)
"cargo" "rustc" "--example" "amp-shared" "--release" "--" \
  "--cfg" "core=\"0\"" \
  "-C" "link-arg=-Tcore0.x" \
  "-C" "link-arg=/tmp/cargo-microamp.GSj3FpvLfYTR/microamp-data.o"
(..)
"cargo" "rustc" "--example" "amp-shared" "--release" "--" \
  "--cfg" "core=\"1\"" \
  "-C" "link-arg=-Tcore1.x" \
  "-C" "link-arg=/tmp/cargo-microamp.GSj3FpvLfYTR/microamp-data.o"
(..)
```

Let's take a quick look at the object file produced by `rustc` before it's
linked with `microamp-data.o`

``` rust
$ # core #0

$ # output format: $address $size $symbol_type $symbol_name
$ arm-none-eabi-nm -CSn amp_shared-75511011384774a7.amp_shared.du4sqj84-cgu.0.rcgu.o
(..)
                  U SEMAPHORE
                  U SHARED
00000000 00000004 T DefaultHandler
00000000 00000070 T IRQ
00000000 000001f0 T main
(..)
```

The `#[shared]` variables which are actually `extern` variables in the expanded
code show up as "undefined" (`U`) symbols and have no address or size.
`microamp-data.o` will provide the size and initial value of these symbols but
the symbols are still missing a meaningful address.

## Linker script

The final piece to glue all this together is the linker script -- one script per
core actually -- which must be provided by the user or some crate. These linker
scripts must be named `core0.x`, `core1.x`, etc. and they must place the *input*
`.shared` section contained in the `microamp-data.o` file into an *output*
section named `.shared`. The output `.shared` section must be placed at the
*same* memory location on all images.

`core*.x` linker scripts will look like this:

``` text
/* showing just the part common to both core0.x and core1.x */

MEMORY
{
  /* .. */

  OCM0 : ORIGIN = 0xFFFC0000, LENGTH = 64K
  OCM1 : ORIGIN = 0xFFFD0000, LENGTH = 64K
  OCM2 : ORIGIN = 0xFFFE0000, LENGTH = 64K
  OCM3 : ORIGIN = 0xFFFF0000, LENGTH = 64K
}

SECTIONS
{
  /* .. */

  /* output section placed in OCM2 */
  .shared : ALIGN(4)
  {
    KEEP(microamp-data.o(.shared));
    . = ALIGN(4);
  } > OCM2

  /* .. */
}
```

The `> OCM2` bit tells the linker where to place the `#[shared]` variables. The
variables need to have the same address on all the images so we have to pick the
same memory region in all the `core*.x` linker scripts. We pick OCM2 here and
not OCM0 / OCM1 to avoid other sections like `.data`, which could have a
different size on each image, from displacing the `.shared` section.

How `#[shared]` variables are laid out in memory is critical. The `.shared`
section in both images must have the exact same layout or the application will
run into Undefined Behavior. To understand why this linker script / attribute
does what we want one needs to understand how compiler and linker optimizations
can affect the memory layout of a program.

The compiler is free to optimize away unused *static variables*; variables
optimized away by the compiler never make it to the linker. On the other hand, a
linker is free to discard entire unused *linker sections*. This difference in
granularity is important because a linker section may contain more than one
variable.

`rustc` by default places each static variable in its *own* linker section, for
example `static mut FOO: u32` goes into a section named `.data.FOO` (the actual
name is longer due to mangling); this lets the linker *individually* discard
unused static variables.

Let's look again at the part of the expansion of `#[shared]` that goes into
`microamp-data.o`.

``` rust
#[cfg(microamp)]
#[link_section = ".shared"]
#[no_mangle]
static mut SHARED: u64 = {
    fn assert() {
        // used to check that `u64` is not a function pointer / trait object
        microamp::export::is_data::<u64>();
    }

    0
};
```

To prevent the *compiler* from optimizing away this variable we use
`#[no_mangle]`, which implies `#[used]`. Note that, in any case, `#[no_mangle]`
is required to make `extern "C" { static mut SHARED: u64 }` work.

All these `#[shared]` variables are placed in the *same* output section:
`.shared`. In the linker script we use `KEEP` to prevent the *linker* from
discarding the input `.shared` section. The linker can't discard any particular
variable in the input `.shared` section because it operates on linker sections
not individual variables. For the same reason the linker can't reorder the
variables within the input `.shared` section so the variables will have the same
order in all the images -- the order of the variables in each image will match
their order in the `microamp-data.o` object file, which is up to the compiler to
decide.

## Validation

Obviously, I got the linker scripts wrong the first time and also the second
time and maybe even the third time ... after all not many people fully
understand what linkers are allowed to do with one's code -- IMO, it's a great
thing that most people don't have to think about linking.

I knew I got things wrong because I added a validation pass, a sanity check if
you will, to `cargo-microamp`. This sanity check told me if the images were
broken at compile time -- figuring out that the images were invalid at runtime
would probably have been Really Fun to debug but I passed on that.

The sanity check works like this: after `cargo-microamp` links the images it
proceeds to read the `.shared` section of each image and checks that they
contain the same set of symbols (static variables) and that each of these
symbols has the same address on all images.

To see this in action I'll intentionally add an error to the linker script of
the second core:

``` text
/* core1.x */
SECTIONS
{
  /* .. */

  .shared : ALIGN(4)
  {
    /* NEW let's add a 32-bit zero here for no particular reason */
    LONG(0);

    KEEP(microamp-data.o(.shared));
    . = ALIGN(4);
  } > OCM2

  /* .. */
}
```

This is the error reported by the tool:

``` console
$ cargo microamp --example amp-shared
(..)
Error: the layout of the `.shared` section doesn't match
amp-shared-0:
{
    0xfffe0000: Symbol {
        size: 8,
        name: "SHARED",
    },
    0xfffe0008: Symbol {
        size: 1,
        name: "SEMAPHORE",
    },
}
amp-shared-1
{
    0xfffe0008: Symbol {
        size: 8,
        name: "SHARED",
    },
    0xfffe0010: Symbol {
        size: 1,
        name: "SEMAPHORE",
    },
}
```

This check was good for catching bugs in the implementation of `microamp` but it
can also catch some user errors. For example a `#[shared]` variable that
contains a `usize` field is an error if one core has `target_pointer_width =
"32"` and the other core has `target_pointer_width = "64"` because the shared
variable will not have the same size on both images. The fix in that case would
be to use something like `u32` instead of `usize`.

## `#[repr(C)]`

`cargo-microamp`'s sanity check can catch *some* problems with `#[shared]`
variables but not all of them. In particular, the validation pass can't inspect
the memory layout of *each* `#[shared]` variable. Consider this program:

``` rust
struct Triplet {
    x: u32,
    y: u32,
    z: u32,
}

#[shared]
static mut SHARED: Triplet = Triplet { x: 0, y: 0, z: 0 };

#[shared]
static READY: AtomicBool = AtomicBool::new(false);

#[cfg(core = "0")]
#[entry]
fn main() -> ! {
    unsafe {
        SHARED.x = 1;
        SHARED.y = 2;
    }

    // unblock core #1
    READY.store(true, Ordering::Release);

    loop {}
}

#[cfg(core = "1")]
#[entry]
fn main() -> ! {
    // wait until core #0 initializes the fields of `SHARED`
    while !READY.load(Ordering::Acquire) {}

    unsafe {
        assert_eq!(SHARED.y, 2);
        assert_eq!(SHARED.z, 0);
    }

    loop {}
}
```

Can these assertions fail? Maybe.

The issue here is that the layout of Rust structs is *unspecified*. As of [two
years ago][pr37429] the compiler is able to reorder the fields of a struct to
optimize its size (reduce padding). And even before that PR landed the compiler
has been able to optimize away the unused fields of a struct.

What could go wrong in this case? In theory, the compiler can optimize the
program differently for each core, for example it could optimize away the field
`z` in the first image and `x` in the second image:

[pr37429]: https://github.com/rust-lang/rust/pull/37429

``` rust
/* core #0 */
struct Triplet {
    x: u32,
    y: u32,
    // z: u32, // never accessed so the compiler optimizes this field away
}

extern {
    // addr_of(SHARED) == 0xFFFE_0000; size_of(SHARED) == 8
    static mut SHARED: Triplet;

    // addr_of(READY) == 0xFFFE_0008; size_of(READY) == 1
    static READY: AtomicBool;
}

#[entry]
fn main() -> ! {
    unsafe {
        // *0xFFFE_0000 <- 1
        SHARED.x = 1;

        // *0xFFFE_0004 <- 2
        SHARED.y = 2;
    }

    // *0xFFFE_0008 <- 1
    READY.store(true, Ordering::Release);

    loop {}
}
```

``` rust
/* core #1 */
struct Triplet {
    // x: u32, // never accessed so the compiler optimizes this field away
    y: u32,
    z: u32,
}

// cargo-microamp's sanity check ensures that these have
// the same address and size on both images
extern {
    // addr_of(SHARED) == 0xFFFE_0000; size_of(SHARED) == 8
    static mut SHARED: Triplet;

    // addr_of(READY) == 0xFFFE_0008; size_of(READY) == 1
    static READY: AtomicBool;
}

#[entry]
fn main() -> ! {
    // *0xFFFE_0008 == 0?
    while !READY.load(Ordering::Acquire) {}

    unsafe {
        // *0xFFFE_0000 == 2?
        assert_eq!(SHARED.y, 2);
        // *0xFFFE_0004 == 0?
        assert_eq!(SHARED.z, 0);
    }

    loop {}
}
```

This kind of optimization would make the application hit the assertions.

The only way to avoid this problem, that I know of, is to only use `#[repr(C)]`
types in `#[shared]` variables. The framework is already using `extern "C" { ..
}` blocks in the expanded code so compiling the above program actually produces
a warning:

``` console
$ cargo microamp --example amp-triplet
warning: `extern` block uses type `Triplet` which is not FFI-safe: this struct has unspecified layout
  --> zup-rtfm/examples/amp-triplet.rs:42:20
   |
42 | static mut SHARED: Triplet = Triplet { x: 0, y: 0, z: 0 };
   |                    ^^^^
   |
   = note: #[warn(improper_ctypes)] on by default
   = help: consider adding a #[repr(C)] or #[repr(transparent)] attribute to this struct
```

As the warning says we should add `#[repr(C)]` to `struct Triplet`! That would
prevent the compiler from removing and reordering the fields of the `struct`.

## Safe `static` variables

One last bullet point: we want to keep access to static variables safe but
accessing an `extern static` variable is `unsafe` so we do a slightly different
expansion in that case.

``` rust
// user input
#[shared]
static SEMAPHORE: AtomicU8 = AtomicU8::new(CORE0);
```

``` rust
// attribute expansion
#[cfg(microamp)]
#[link_section = ".shared"]
#[no_mangle]
static SEMAPHORE: AtomicU8 = {
    fn assert() {
        microamp::export::is_data::<AtomicU8>();
    }

    AtomicU8::new(CORE0)
};

// the second part of the expansion is different!
#[cfg(not(microamp))]
struct SEMAPHORE;

#[cfg(not(microamp))]
impl core::ops::Deref for SEMAPHORE {
    type Target = AtomicU8;

    fn deref(&self) -> &AtomicU8 {
        extern "C" {
            static SEMAPHORE: AtomicBool;
        }

        unsafe {
            &SEMAPHORE
        }
    }
}
```

When the application calls `SEMAPHORE.load(Ordering::Acquire)` it's actually
using the proxy struct named `SEMAPHORE` that derefs to an external variable
(also) named `SEMAPHORE`. Referring to the proxy struct and `deref`-ing it are
both safe operations so this accurately mimics a normal `static` variable.

# Outro

For now I have pre-released both `microamp` and `cargo-microamp` with version
v0.1.0-alpha.1. Before I do a proper release I want to test the whole thing on a
heterogenous multi-core device. I have an LPC43xx microcontroller, which has one
Cortex-M0 core and one Cortex-M4F core, lying around but haven't had time to
play with it and probably won't have time until next month. To get that working
I'll need to add a command line flag that lets you specify a different
compilation target per core, maybe something like this:

``` console
$ # core #0 is ARMv6-M
$ # core #1 is ARMv7-EM
$ cargo microamp \
    --example heterogenous \
    -t0 thumbv6m-none-eabi \
    -t1 thumbv7em-none-eabihf
```

In any case, that's μAMP! It's a very small (no pun intended) API that serves as
the foundation of multi-core RTFM, which I'll cover in the next blog post. Until
next time!

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
    <a href="https://memfault.com/?utm_source=jorge&utm_medium=patreon" style="border-bottom:0px">
      <img alt="Memfault" class="image" src="/logo/memfault.svg"/>
    </a>
  </div>
</div>

[Iban Eguia],
[Geoff Cant],
[Harrison Chin],
[Brandon Edens],
[whitequark],
[James Munns],
[Fredrik Lundström],
[Kor Nielsen],
[Dietrich Ayala],
[Hadrien Grasland],
[vitiral],
[Lee Smith],
[Florian Uekermann],
[Ivan Dubrov]
and 64 more people for [supporting my work on Patreon][Patreon].

[Iban Eguia]: https://github.com/Razican
[Geoff Cant]: https://github.com/archaelus
[Harrison Chin]: http://www.harrisonchin.com/
[Brandon Edens]: https://github.com/brandonedens
[whitequark]: https://github.com/whitequark
[James Munns]: https://jamesmunns.com/
[Fredrik Lundström]: https://github.com/flundstrom2
[Kor Nielsen]: https://github.com/korran
[Dietrich Ayala]: https://metafluff.com/
[Hadrien Grasland]: https://github.com/HadrienG2
[vitiral]: https://github.com/vitiral
[Lee Smith]: https://github.com/leenozara
[Florian Uekermann]: https://github.com/FlorianUekermann
[Ivan Dubrov]: https://github.com/idubrov

---

Let's discuss on [reddit].

[reddit]: https://www.reddit.com/r/rust/comments/bmyeah/%CE%BCamp_asymmetric_multiprocessing_on/

Enjoyed this post? Like my work on embedded stuff? Consider supporting my work
on [Patreon]!

[Patreon]: https://www.patreon.com/japaric

Follow me on [twitter] for even more embedded stuff.

[twitter]: https://twitter.com/japaricious

The embedded Rust community gathers on the #rust-embedded IRC channel
(irc.mozilla.org). Join us!
