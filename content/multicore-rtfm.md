+++
author = "Jorge Aparicio"
date = 2019-06-23T18:00:00+02:00
tags = ["AMP", "concurrency", "multi-core", "rtfm"]
title = "Real Time For the Masses goes multi-core"
+++

v0.5.0 of Real Time For the Masses (RTFM), the embedded concurrency framework,
is coming out soon-ish -- some time after Rust 1.36 is released -- and will
include experimental support for homogeneous and heterogeneous multi-core
Cortex-M  devices. This blog post covers the upcoming multi-core API and
includes a refresher on the single-core API.

# Heterogeneous support in μAMP

But first, one update relevant to multi-core RTFM from the [μAMP][]
(`microamp`) front since the last post: [`cargo-microamp`] has gained support
for heterogeneous multi-core devices. The `--target` flag can now be used to
specify the compilation target of *each* core and these targets can be different
-- that's how μAMP supports heterogeneous devices.

[μAMP]: ../microamp
[`cargo-microamp`]: https://crates.io/crates/microamp-tools

I have written some μAMP examples for the [LPC54114], a microcontroller which
has one ARM Cortex-M4F core and one Cortex-M0+ core; you can find them
[here][lpcxpresso54114].

[LPC54114]:  https://www.nxp.com/products/processors-and-microcontrollers/arm-based-processors-and-mcus/lpc-cortex-m-mcus/lpc54000-cortex-m4-/low-power-microcontrollers-mcus-based-on-arm-cortex-m4-cores-with-optional-cortex-m0-plus-co-processor:LPC541XX
[lpcxpresso54114]: https://github.com/japaric/lpcxpresso54114/tree/d10a0a52856b67f0e99284f0fb32abb3c2fd4f51/firmware/lpc541xx/examples

For those not familiar with the `rustc` compilation targets for Cortex-M cores:
one uses the `thumbv7em-none-eabihf` target for Cortex-M4F cores and
`thumbv6m-none-eabi` for Cortex-M0+ cores. The difference between these two
targets is that the former has FPU (Floating Point Unit) and CAS (Compare And
Swap) instructions [^cas] in its instruction set that the latter doesn't have.
As the `thumbv6m-none-eabi` target doesn't have FPU instructions math involving
single precision floats (`f32`) is emulated and super slow.

[^cas]: to be more precise it has LL-SC (Load-link / Store-conditional)
    instructions which can be used to implement CAS loops.

Here's the mutex example I [presented in the last post] but ported to this
heterogeneous device:

[presented in the last post]: ../microamp/#shared-memory

``` rust
#![no_main]
#![no_std]

use core::sync::atomic::{self, Ordering};

use cortex_m::asm;
#[cfg(core = "0")]
use cortex_m::iprintln;
use lpc541xx as _;
use microamp::shared;
use panic_halt as _;

// non-atomic variable
#[shared] // <- means: same memory location on all the cores
static mut SHARED: u64 = 0;

// used to synchronize access to `SHARED`; this is a memory mapped register
const MAILBOX_MUTEX: *mut u32 = 0x4008_b0f8 as *mut u32;

// entry point for both cores
#[no_mangle]
unsafe extern "C" fn main() -> ! {
    // only core #0 has a functional ITM
    #[cfg(core = "0")]
    let mut itm = cortex_m::Peripherals::take().unwrap().ITM;

    let mut done = false;
    while !done {
        while MAILBOX_MUTEX.read_volatile() == 0 {
            // busy wait while the lock is held by the other core
        }
        atomic::fence(Ordering::Acquire);

        // we acquired the lock; now we have exclusive access to `SHARED`
        {
            let shared = &mut SHARED;

            if *shared >= 10 {
                // stop at some arbitrary point
                done = true;
            } else {
                *shared += 1;

                // log a message through the stimulus port #0
                #[cfg(core = "0")]
                iprintln!(&mut itm.stim[0], "[0] SHARED = {}", *shared);
            }
        }

        // release the lock to unblock the other core
        atomic::fence(Ordering::Release);
        MAILBOX_MUTEX.write_volatile(1);

        // artificial delay to let the *other* core take the lock
        for _ in 0..1_000 {
            asm::nop();
        }
    }

    #[cfg(core = "0")]
    iprintln!(&mut itm.stim[0], "[0] DONE");

    loop {}
}
```

In this example both cores access and increase the value of a shared static
variable; access to the variable is synchronized using a mutex. As I mentioned
above, the Cortex-M0+ core has no CAS instructions so we can't use the
`AtomicU8::compare_and_exchange` API this time. The vendor provides a memory
mapped register that provides mutex functionality though so we use that instead.

[`spin::Mutex`]: https://docs.rs/spin/0.5.0/spin/struct.Mutex.html

We use the latest `cargo-microamp` to build this program for two different
compilation targets.

``` console
$ cargo microamp \
    --example mutex \
    --target thumbv7em-none-eabihf,thumbv6m-none-eabi \
    --release
```

This subcommand produces two ELF images; note the different compilation targets
in their paths.

``` console
$ ( cd target && size */release/examples/mutex-{0,1} )
   text    data     bss     dec     hex filename
   3796       8       4    3808     ee0 thumbv7em-none-eabihf/release/examples/mutex-0
    376       8       0     384     180 thumbv6m-none-eabi/release/examples/mutex-1
```

Looking at the ELF tags confirms that the images use different instruction sets
and calling conventions (`hardfp` vs `softfp`).

``` console
$ readelf -A target/*/release/examples/mutex-{0,1}

File: target/thumbv7em-none-eabihf/release/examples/mutex-0
Attribute Section: aeabi
File Attributes
  Tag_CPU_arch: v7E-M
  Tag_CPU_arch_profile: Microcontroller
  Tag_THUMB_ISA_use: Thumb-2
  Tag_FP_arch: VFPv4-D16
  Tag_ABI_HardFP_use: SP only
  Tag_ABI_VFP_args: VFP registers
  Tag_CPU_unaligned_access: v6
  Tag_FP_HP_extension: Allowed

File: target/thumbv6m-none-eabi/release/examples/mutex-1
Attribute Section: aeabi
File Attributes
  Tag_CPU_arch: v6S-M
  Tag_CPU_arch_profile: Microcontroller
  Tag_THUMB_ISA_use: Thumb-1
  Tag_CPU_unaligned_access: None
```

Loading the program -- which is a bit [more involved] than building it -- and
running it produces the following output.

[more involved]: https://github.com/japaric/lpcxpresso54114/tree/4439c4b5877df430e9240ce69fb55706ce0d6fd6#how-to-run-the-examples

``` console
$ # Output of the ITM stimulus port #0
$ # (port-demux is part of the itm-tools crate -- https://github.com/japaric/itm-tools)
$ port-demux -f -r0 /dev/ttyUSB0
[0] SHARED = 2
[0] SHARED = 4
[0] SHARED = 6
[0] SHARED = 8
[0] SHARED = 10
[0] DONE
```

# The single-core API

Before we dive into multi-core RTFM I want to go over the core features of
single-core RTFM with an example. This serves two purposes: (a) it will get
you up to speed with RTFM if you are not familiar with it (or will serve as a
refresher if you have seen it or used it before) and (b) I'll use the
single-core API / syntax as a reference for the multi-core API / syntax. If you
are familiar with RTFM feel free to skim over this section or directly jump to
the [next one](#the-multi-core-extension).

## An example

This is the context for the example application:

You have a microcontroller connected to an external radio (e.g. a 802.15.4 one).
The microcontroller receives command packets over this radio and performs
actions (like turning lights on / off) in response to the packets. The external
radio has limited memory and can only hold a single incoming packet in memory.
Until this packet is read out the radio will refuse to receive new packets
leading to packet loss.

Now let's look at the code:

> **NB:** At the time of writing the syntax of the RTFM DSL is still being
> [actively discussed][rfcs] so all the examples in this post may not match the final
> syntax. When v0.5.0 is out I'll come back and update these examples.

[rfcs]: https://github.com/japaric/cortex-m-rtfm/milestone/4

``` rust
#![deny(unsafe_code)]
#![no_std]
#![no_main]

// heapless = "0.5.0-alpha.2"
use heapless::{
    pool,
    pool::singleton::{Box, Pool},
};

// https://github.com/japaric/owning-slice#f8c70ead919bb26d11eaf01408eca2cd48cb8c72
use owning_slice::OwningSliceTo; // like `x[..end]` but by value

// panic-halt = "0.2.0"
use panic_halt as _; // panic handler

// Declare a lock-free memory pool that manages memory blocks of 128 bytes each
pool!(P: [u8; 128]);

#[rtfm::app(device = stm32f103xx)]
const APP: () = {
    /* Resources used by the tasks */
    // Abstraction for an external radio; it will be initialized in `init`
    static mut RADIO: Radio = ();

    // Initialization phase; runs before any task can start
    #[init]
    fn init(c: init::Context) -> init::LateResources {
        static mut M: [u8; 512] = [0; 512];

        // initialize the pool with enough memory for 4 blocks
        // (`M` actually has type `&'static mut [u8; 512]` due to macro expansion)
        P::grow(M);

        // omitted: initialization of peripherals

        init::LateResources {
            // initial value for  the `RADIO` resource
            RADIO: radio,
        }
    }

    /* Tasks */
    // hardware task bound to interrupt signal `EXTI0`
    // signal `EXTI0` fires when a new packet can be read from the external radio
    #[task(
        binds = EXTI0,
        priority = 2,
        resources = [RADIO], // only this task has access to the `RADIO`
        spawn = [process_packet], // tasks this task can spawn
    )]
    fn on_new_packet(c: on_new_packet::Context) {
        // proxy for the packet we just received
        // it has some info like the size of the packet but not the actual contents
        let mut next_packet = c.resources.RADIO.next_packet();

        if let Some(buffer) = P::alloc() {
            // read the packet contents
            let packet = next_packet.read(buffer.freeze());

            // the radio can start receiving a new packet at this point

            // spawn a new instance of the software task and send the packet to it
            let _ = c.spawn.process_packet(packet);
            //  ^ (ignore the `Result`;  this operation will never error)
        } else {
            // not enough memory to read this packet ATM
            // discard it so the radio can start receiving a new packet
            // (losing a packet is OK-ish and not that uncommon in lossy links like
            //  802.15.4; the client will likely retry the transmission. Of course,
            //  it would be best to never drop packets but we have limited memory!)
            next_packet.discard();
        }
    }

    // software task that runs at lower priority and processes packets
    #[task(
        priority = 1,
        resources = [], // this task doesn't have access to the RADIO
        capacity = 4, // input buffer can hold up to 4 messages
    )]
    fn process_packet(
        c: process_packet::Context,
        packet: OwningSliceTo<Box<P>, u8>, // task input = message sent to it
    ) {
        // ommited: parse packet and perform an action based on its contents

        // (this happens implicitly and returns the memory block back to the pool)
        drop(packet)
    }

    // ..
};
```

That's quite a bit to unpack so let's go over the code function by function.

### Initialization

First, the `init` function. This function is called the *initialization
phase* within the RTFM framework. The microcontroller will run this function
right after it boots. The value returned by this function will be used by the
framework to initialize the static `RADIO` variable.

Static variables -- called *resources* within the RTFM framework -- are used by
*tasks* to preserve state across their invocations. You can think of resources
as *task state*. The `RADIO` resource can't be initialized at compile time ("in
const context") because it requires runtime operations like initializing
peripherals and talking to an external device. Resources that are initialized at
runtime are called *late resources* within the framework.

In `init` we also initialize the memory pool named `P` by giving it some initial
memory.

### Event driven

After `init` returns, the framework initializes the `RADIO` resource and then
puts the microcontroller to sleep. That's the default state of RTFM
applications: power saving sleep mode. The microcontroller will wake up and
perform useful work only when it receives an *interrupt signal* that tells it to
do so. In response to this, usually external, signal the microcontroller will
run a *hardware task*.

In our example, `on_new_packet` is a hardware task that runs when the signal
named `EXTI0` ("External Interrupt 0") arrives. This signal is raised when the
external radio has finished receiving a new packet.

In the `on_new_packet` task we request a memory block (`heapless::pool::Box<P>`)
from the memory pool. If we get one we copy the contents of the newly
received packet into it, otherwise we tell the radio to discard the newly
received packet. In either case, the radio can start receiving a new packet by
the time this task ends (returns).

Now that we have a packet we have to parse it and perform some action based on
its contents but we won't do that in *this* task. Instead we'll use a *software*
task to do that work.

### Message passing

`process_packet` is a *software* task. Unlike hardware tasks, which start in
response to events, software tasks are `spawn`-ed by the software on demand.
And when a task is `spawn`-ed a message can be passed along; this message
becomes the input of the task.

In the example, we use the message passing feature to *send* the `packet` we read
from the `RADIO` from the hardware task to the software task. This operation has
*move semantics* so ownership over `packet` is transferred from one task to the
other.

The software task will parse its input `packet` and perform most of the
application logic. As this task *owns* the `packet` it will eventually `drop`
it; this operation returns the memory block back to the pool `P`.

### Task scheduling

Tasks can be assigned *static* priorities; as the name implies these priorities
are selected at compile time and can't change at runtime. The differences in
priorities affect how tasks are scheduled. In our example, the software task has
lower priority so after being `spawn`-ed nothing immediately happens. It's only
after `on_new_packet` returns that `process_packet` gets a chance to run.

We say that in RTFM tasks have *run to completion* semantics because they have
no suspension points like generators have and also there's no periodic context
switching between tasks as seen in threaded systems like Linux. Once a task
starts it will run until it terminates (returns).

However, *higher priority* tasks will preempt lower priority tasks if their
interrupt signal arrives (asynchronous action) or they are `spawn`-ed
(synchronous action) . In either scenario the lower priority task will be
suspended and the higher priority will start and *run to completion*. After the
higher priority task returns the lower priority task is resumed. Note that
there's never a context switch from a high priority task to a lower priority one
or to a task that has the same priority; there's only preemption *towards higher
priorities*.

For this reason, in this particular example if another `EXTI0` signal arrives
while `on_new_packet` is being executed there's no *immediate* effect. Another
instance of the `on_new_packet` task will run in response to the second signal
but only after the first instance ends -- this is because both instances of
`on_new_packet` have the *same* priority.

### Priorities matter

So why bother using a second task? Why not just do a plain function call to a
`process_packet` function? The reason is avoiding packet loss.

If we had used a function call instead of `spawn` we would have ended with a
system with no preemption. In this example that could result in packet loss.
Imagine the scenario where three packets arrive in quick succession. If we do
the packet processing in the hardware task (`on_new_packet`) we would not read
out the next packet *until we are done processing the packet*. If processing a
packet takes too long then the third packet would be ignored by the radio
interface. The timeline of events would look like this:

- Event: first packet arrives.
  - Action: read it out and start processing it.

- Event: second packet arrives.
  - Status: still processing the first packet.

- Event: third packet starts being transmitted.
  - Status: the radio still has the second packet in its buffer so it ignores
    this packet (and subsequent ones).
  - Result: third packet is not successfully delivered.

So what the software task is buying us here is buffering during these bursts of
requests. The software task has a `capacity` of `4` so the hardware task can
queue up to 4 packets for it to process (sequentially). Because the hardware
task has higher priority it can drain packets from the radio while old packets
are being processed by the software task; this avoids the packet loss scenario
described above.

Note that this is *not* real-time system, which is the kind of systems RTFM was
originally designed for, yet timeliness and prioritization are necessary for the
correct operation of the system.

## Locks

So far we have seen these RTFM features:

- Hardware tasks (`#[task(binds = ..)]`)

- Software tasks (`#[task]`) and message passing (`spawn`)

- Task prioritization (e.g. `priority = 1`)

- Runtime initialization of resources (`static [mut]` variables), AKA *late
  resources*.

There's two more features not shown in the example: one of them is the `lock`
API. This API is used when you want two, or more, tasks running at *different*
priorities to share access to the same resource. Here's a contrived example:

``` rust
#![deny(unsafe_code)]
#![no_std]
#![no_main]

use panic_halt as _; // panic handler

#[rtfm::app(device = stm32f103xx)]
const APP: () = {
    // used to count the number of task invocations
    // NOTE: *not* an "atomic integer" because ARMv7-M word size is 32-bit
    static mut COUNT: u64 = 0;

    #[task(
        priority = 1,
        resources = [COUNT], // has access to the `COUNT` resource
    )]
    fn foo(mut c: foo::Context) {
        // the lower priority task needs a critical section to access the data
        c.resources.COUNT.lock(|count: &mut u64| {
            // this closure runs at a priority of `2`
            // task `bar` can't preempt this critical section due to its new priority
            *count += 1;
        });

        // `bar` can preempt `foo` from this point onward
    }

    #[task(
        priority = 2,
        resources = [COUNT], // also has access to the `COUNT` resource
    )]
    fn bar(c: bar::Context) {
        // the higher priority task gets direct access to the resource
        let count: &mut u64 = c.resources.COUNT;
        *count += 1;
    }

    #[task(
        priority = 3,
        resources = [], // can *not* access `COUNT`
    )]
    fn baz(c: baz::Context) {
        // COUNT += 1;
        //~^ error: cannot find value `COUNT` in this scope

        // c.resources.COUNT += 1;
        //~^ error: no field `resources` on type `baz::Context`

        // ..
    }

    // ..
};
```

In this example we have a shared resource named `COUNT` that's accessed by tasks
`foo` and `bar`. The tasks run at different priorities and the resource is not
an atomic variable so some form of synchronization is required to avoid a data
race (torn reads and writes). The `lock` API gives you that synchronization in
the form of a critical section.

`bar` runs at higher priority so it can preempt `foo`; thus `foo` needs a
critical section to access `COUNT`. The `lock` API creates a critical section,
which syntactically looks like a closure, by *temporarily* raising the priority
of, in this case, `foo` to match the priority of `bar`. Raising the priority
*disables* preemption: the task `bar` can *not* start while `foo` is in the
critical section. Only within this critical section can `foo` safely access the
contents of `COUNT`.

On the other hand, `foo` can *not* preempt `bar` so `bar` can access `COUNT`
directly. Other higher priority tasks that do *not* access the resource, like
`baz`, are free to preempt `bar`, and `foo`, at any moment.

The framework enforces access control: only tasks that declared a resource in
their `#[task]` attribute can access the resource (static variable). This
compile time access control lets the framework optimize / minimize critical
sections.

Internally, the `spawn` API makes use of the `lock` API so our example is also
implicitly using the `lock` API. There are a few data structures that the
framework synthesizes to make the `spawn` API work and all the `spawn` calls
access them using the `lock` API -- those data structures are also resources! If
you are interested in learning how the `spawn` API is implemented you can read
our [internal documentation][internals].

[internals]: https://japaric.github.io/rtfm5/book/en/

The most important aspects of the `lock` API are that (a) it's a deadlock-free
abstraction and (b) it has bounded execution time. In contrast, mutexes in
threaded systems, like `std::sync::Mutex`, and spinlocks, like `spin::Mutex`,
can deadlock if one is not careful and may block the thread / task trying to
access the `Mutex` for an indeterminate amount of time. Entering and leaving the
critical section created by `lock` takes only 4 instructions / clock cycles in
the ARM Cortex-M implementation [^inline-asm].

[^inline-asm]: when the `inline-asm` feature, which requires a nightly compiler,
    is enabled. Without the feature the cost is 14 clock cycles.

The `spawn` API which is built on top of the `lock` API inherits these two
properties. A `spawn` call, that is posting a message, has a bounded execution
time (no CAS loops) and never deadlocks or blocks the sender.

## `schedule`

The other feature not covered in the example is the `schedule` API, which lets
you schedule a task to run *at some time in the future*. The main use case for
this API is creating periodic tasks. Here's a simple example:

``` rust
#![deny(unsafe_code)]
#![no_std]
#![no_main]

use cortex_m::{iprintln, peripheral::ITM};
use panic_halt as _;
// like `std::time::{Duration,Instant}` but work with clock cycles rather than seconds
use rtfm::cyccnt::{Duration, Instant};

const PERIOD: u32 = 8_000_000; // CPU clock cycles or about one second

#[rtfm::app(device = stm32f103xx, monotonic = rtfm::cyccnt::CYCCNT)]
const APP: () = {
    static mut ITM: ITM = ();

    #[init(spawn = [periodic])]
    fn init(c: init::Context) -> init::LateResources {
        // `init` owns all the Cortex-M peripherals
        let mut core = c.core;

        // initialize the monotonic timer
        core.DWT.enable_cycle_counter();

        // bootstrap the periodic task
        let _ = c.spawn.periodic(0);

        init::LateResources { ITM: core.ITM }
    }

    #[task(resources = [ITM], schedule = [periodic])]
    fn periodic(c: periodic::Context, count: u32) {
        // time at which this task started executing
        let now = Instant::now();

        // time at which this task was scheduled to run
        let scheduled: Instant = c.scheduled;

        // log this message through the ITM stimulus port #0
        iprintln!(
            &mut c.resources.ITM.stim[0],
            "periodic({}) scheduled @ {:?} ran @ {:?}",
            count,
            scheduled,
            now
        );

        let _ = c.schedule.periodic(
            // when: run again in one second
            scheduled + Duration::from_cycles(PERIOD),

            // the message to pass to the new instance
            count + 1,
        );
    }

    // ..
};
```

Here's the output of the above program:

``` console
$ port-demux -f -r0 /dev/ttyUSB0
periodic(0) scheduled @ Instant(0) ran @ Instant(59)
periodic(1) scheduled @ Instant(8000000) ran @ Instant(8000141)
periodic(2) scheduled @ Instant(16000000) ran @ Instant(16000141)
periodic(3) scheduled @ Instant(24000000) ran @ Instant(24000141)
```

The framework lets the user provide their own `monotonic` timer. In this example
we used the DWT cycle counter (AKA `CYCCNT`) which is a Cortex-M peripheral
found on all ARMv7-M devices and is clocked at the same frequency as the CPU.
However, one could have used a Real Time Clock (RTC) peripheral clocked at
32,768 Hz to schedule tasks with longer periods, in the order of seconds or
minutes.

# The multi-core extension

That covers all the single-core RTFM API. Now let's dig into the multi-core API.
The multi-core API is very similar to the single-core API; that's why this
section is called "the multi-core *extension*".

Deadlock freedom and bounded execution time are highly desirable properties in
safety critical and real time systems. The single-core version has both and we
wanted the multi-core version to inherit these properties. How can we scale out
RTFM in a way that let us maintain these properties?

## Task partitioning

The answer is: *task partitioning*. The idea is the following: you split your
application in *tasks* -- this is what you do today when you use single-core
RTFM -- and then you split those tasks *across your cores*, meaning that *each
task will run on a specific core*.

Tasks can have (`static mut`) resources associated to them; these resources make
tasks stateful. The multi-core version has the restriction that resources can
only be shared between tasks that run *on the same core*. The reason for this
restriction is that the `lock` API is *not* cross-core memory safe. (You can, of
course, safely share `static` variables between the cores -- `static` variables
don't need to be managed by RTFM to be memory-safe to access).

Here's a contrived example that illustrates the multi-core API:

``` rust
#![deny(unsafe_code)]
#![no_main]
#![no_std]

// dual-core application
#[rtfm::app(cores = 2, device = lpc541xx)]
const APP: () = {
    // resource implicitly assigned to core #0
    static mut X: u64 = 0;

    // core #0 initialization routine
    #[init(core = 0)]
    fn init(_: init::Context) {
        // ..
    }

    // software task that runs on core #0
    #[task(core = 0, priority = 1, resources = [X])]
    fn process_mic_data(c: process_mic_data::Context, data: MicData) {
        // ..

        // `lock` API
        c.resources.X.lock(|x| {
            // ..
        });

        // ..
    }

    // hardware task that runs on core #0
    #[task(core = 0, binds = DMA, priority = 2, resources = [X])]
    fn on_new_microphone_data(c: on_new_microphone_data::Context) {
        let x: &mut u64 = c.resources.X;

        // ..

        c.spawn.process_mic_data(data);
    }

    // resource implicitly assigned to core #1
    static mut Y: u64 = 0;

    // core #1 initialization routine
    #[init(core = 1)]
    fn init(_: init::Context) {
        // ..
    }

    // hardware task that runs on core #1
    #[task(core = 1, binds = USB, resources = [Y])]
    fn on_new_usb_packet(c: on_new_usb_packet::Context) {
        // ..
    }
};
```

There are very few differences between the multi-core and the single-core
syntax:

- First, `rtfm::app` now takes a `cores` argument that indicates the number of
  cores the system has. In this example I chose 2 cores. Omitting the `cores`
  argument indicates that the application is a single core application.

[UltraScale+]: https://www.xilinx.com/products/silicon-devices/soc/zynq-ultrascale-mpsoc.html

- All tasks now need a `core` argument that indicates on which core the task
  will run. In this example we have two hardware tasks, each one tied to a
  different interrupt. Core #0 will service DMA transfer complete interrupts
  whereas core #1 will service USB interrupts.

- `init` also needs a `core` argument. Each core runs a different
  initialization function.

The `lock` API is present in the multi-core version and works exactly as it does
in the single-core version, plus it's still free of deadlocks and has bounded
execution time.

## Message passing

One can't share resources between cores but message passing works within a core
*and* across cores. The `spawn` API remains unchanged; if the caller specifies a
task that runs on a different core then the message will be sent to the other
core.

Here's the multi-core RTFM version of the classic ping-pong message passing
example:

(Full source code can be found in the [lpcxpresso54114] repository)

[lpcxpresso54114]: https://github.com/japaric/lpcxpresso54114/blob/4439c4b5877df430e9240ce69fb55706ce0d6fd6/firmware/lpc541xx/examples/xspawn.rs

``` rust
#![deny(unsafe_code)]
#![no_main]
#![no_std]

#[cfg(core = "0")]
use cortex_m::{iprintln, peripheral::ITM};
use panic_halt as _;

// stop at some arbitrary point
const LIMIT: u32 = 5;

#[rtfm::app(cores = 2, device = lpc541xx)]
const APP: () = {
    static mut ITM: ITM = ();

    #[init(core = 0, spawn = [ping])]
    fn init(mut c: init::Context) -> init::LateResources {
        iprintln!(&mut c.core.ITM.stim[0], "[0] init");

        // cross core message passing
        let _ = c.spawn.ping(0);

        init::LateResources { ITM: c.core.ITM }
    }

    #[task(core = 0, resources = [ITM], spawn = [ping])]
    fn pong(c: pong::Context, x: u32) {
        iprintln!(&mut c.resources.ITM.stim[0], "[0] pong({})", x);

        // cross core message passing
        let _ = c.spawn.ping(x + 1);
    }

    #[task(core = 1, spawn = [pong])]
    fn ping(c: ping::Context, x: u32) {
        // (the Cortex-M0+ core has no functional ITM to log messages)

        if x < LIMIT {
            // cross core message passing
            let _ = c.spawn.pong(x + 1);
        }
    }

    // ..
};
```

The target is the LPC54114, a heterogeneous multi-core device. When targeting
heterogeneous devices RTFM uses μAMP under the hood so we need to compile
this RTFM application using `cargo-microamp`.

``` console
$ cargo microamp \
    --example xspawn \
    --target thumbv7em-none-eabihf,thumbv6m-none-eabi \
    --release

$ ( cd target && size target/*/release/examples/xspawn-{0,1} )
   text    data     bss     dec     hex filename
   2796      26       0    2822     b06 thumbv7em-none-eabihf/release/examples/xspawn-0
    574      26       0     600     258 thumbv6m-none-eabi/release/examples/xspawn-1
```

Here's the output of running the program:

``` console
$ port-demux -f -r0 /dev/ttyUSB0
[0] init
[0] pong(1)
[0] pong(3)
[0] pong(5)
```

It must be noted that cross-core `spawn` calls also have bounded execution
time and are non-blocking.

## `schedule`

The `schedule` API also works across cores but one needs to pick a `monotonic`
timer that behaves *the same* when accessed from any of the cores.

Here's the previous ping pong example but we now use `schedule` instead of
`spawn` to delay each message by half a second.

``` rust
#![deny(unsafe_code)]
#![no_main]
#![no_std]

#[cfg(core = "0")]
use cortex_m::{iprintln, peripheral::ITM};
use lpc541xx::Duration;
#[cfg(core = "0")]
use lpc541xx::Instant;
use panic_halt as _;

// stop at some arbitrary point
const LIMIT: u32 = 5;

const DELAY: u32 = 6_000_000; // CTIMER0 clock cycles or about half a second

#[rtfm::app(cores = 2, device = lpc541xx, monotonic = lpc541xx::CTIMER0)]
const APP: () = {
    static mut ITM: ITM = ();

    #[init(core = 0, schedule = [ping])]
    fn init(mut c: init::Context) -> init::LateResources {
        iprintln!(&mut c.core.ITM.stim[0], "[0] init");

        // run this task in half a second from now
        let _ = c.schedule.ping(c.start + Duration::from_cycles(DELAY), 0);

        init::LateResources { ITM: c.core.ITM }
    }

    #[task(core = 0, resources = [ITM], schedule = [ping])]
    fn pong(c: pong::Context, x: u32) {
        let now = Instant::now();
        let scheduled = c.scheduled;

        iprintln!(
            &mut c.resources.ITM.stim[0],
            "[0] pong({}) scheduled @ {:?} ran @ {:?}",
            x,
            scheduled,
            now
        );

        let _ = c
            .schedule
            .ping(scheduled + Duration::from_cycles(DELAY), x + 1);
    }

    #[task(core = 1, schedule = [pong])]
    fn ping(c: ping::Context, x: u32) {
        if x < LIMIT {
            let _ = c
                .schedule
                .pong(c.scheduled + Duration::from_cycles(DELAY), x + 1);
        }
    }

    // ..
};
```

Here's the output:

``` console
$ port-demux -f -r0 /dev/ttyUSB0
[0] init
[0] pong(1) scheduled @ Instant(12000000) ran @ Instant(12000563)
[0] pong(3) scheduled @ Instant(24000000) ran @ Instant(24000563)
[0] pong(5) scheduled @ Instant(36000000) ran @ Instant(36000563)
```

In this example we use a peripheral provided by the device, `CTIMER0`, as the
`monotonic` timer instead of the `CYCCNT` (cycle counter), which we used in the
single-core example. The reason for not using the `CYCCNT` this time is that
(a) the `CYCCNT` is -- to use ARM's terminology -- a *private resource*: each
core has its own cycle counter and it's not possible to synchronize them, plus
each cycle counter could be running at a different frequency; and (b) ARMv6-M
cores, like the Cortex-M0+ core in the LPC54114, don't implement a cycle
counter.

## Cross-core resource initialization

A feature that I thought might be useful is having one core initialize resources
owned by other cores.

One use case would be to have one core initialize *all* the peripherals and then
have it send some of the initialized peripherals, wrapped in higher level
abstractions, to the other cores. You can do that operation with  the `spawn`
API but it's a bit awkward because it requires a one-shot task and an `Option`
and `unwrap` calls on the receiver.

``` rust
#[rtfm::app(
    cores = 2,
    device = lpc541xx,
    peripherals = 0,  // core #0 takes all the device peripherals
)]
const APP: () = {
    #[init(core = 0)]
    fn init(c: init::Context) {
        // all the device peripherals by value
        let device: lpc541xx::Peripherals = c.device;

        // .. initialize all peripherals ..

        // send the initialized USB stack to core #1
        let _ = c.spawn.take_usb_stack(usb);
    }

    // resource implicitly assigned to core #1
    static mut USB: Option<UsbStack> = None;

    #[task(core = 1, resources = [USB])]
    fn take_usb_stack(c: take_usb_stack::Context, usb: UsbStack) {
        c.resources.USB = Some(usb);
    }

    // some task that uses the USB stack
    #[task(core = 1, resources = [USB])]
    fn use_usb(c: use_usb::Context) {
        // whoops, this might panic
        let usb: &mut UsbStack = c.resources.USB.as_mut().unwrap();

        // ..
    }
};
```

With cross-core resource initialization core #0 can initialize the `USB`
resource at the end of `init`:

``` rust
#[rtfm::app(cores = 2, device = lpc541xx, peripheral = 0)]
const APP: () = {
    #[init(core = 0)]
    fn init(c: init::Context) -> init::LateResources {
        // .. initialize all peripherals ..

        init::LateResources { USB: usb }
    }

    // resource implicitly assigned to core #1
    static mut USB: UsbStack = ();

    // some task that uses the USB stack
    #[task(core = 1)]
    fn use_usb(c: use_usb::Context) {
        // always observes an initialized resource
        let usb: &mut UsbStack = c.resources.USB;

        // ..
    }

    // ..
};
```

With this approach the one-off task and the `Option` are not required.

(And, yes, the framework inserts a synchronization barrier somewhere in there
so that the `use_usb` task only ever starts after core #0's `init` returns and
`USB` is initialized.)

## Homogeneous devices

In all the previous multi-core examples I have targeted the LPC54114, a
heterogeneous dual-core device, but there are also homogeneous devices out there
like the [LPC55S69], a device with 2 Cortex-M33 (ARMv8-M) cores. One could
certainly use `cargo-microamp` to build an RTFM application for such device but
`cargo-build` suffices in that case because both cores use the exact same
instruction set.

[LPC55S69]: https://www.nxp.com/products/processors-and-microcontrollers/arm-based-processors-and-mcus/general-purpose-mcus/lpc5500-cortex-m33/high-efficiency-arm-cortex-m33-based-microcontroller-family:LPC55S6x

RTFM has two codegen modes for multi-core applications: `homogeneous` and
`heterogeneous`; you can select either using Cargo features. The `heterogeneous`
mode is the one I have been demoing so far. The `homogeneous` mode lets you
build multi-core applications using `cargo-build` but has the restriction that a
*single* compilation target must be used. Of course, this is fine for
homogeneous devices.

The RTFM API is the same in either multi-core mode but one can use
`#[cfg(core = "0")]` only in the `heterogeneous` mode as that's the one that
uses `cargo-microamp`.

[Here's] an `homogeneous` ping pong example. I'm not going to copy paste the
code here because there's very little difference between it and the
`heterogeneous` version I showed before.

[Here's]: https://github.com/japaric/lpcxpresso55S69/blob/1922c6a3067f349876c750a2d57bfcb87e70e0ed/lpc55s6x/examples/xspawn.rs

This `homogeneous` example is built using `cargo-build`

``` console
$ cargo build --target thumbv8m.main-none-eabi --example xspawn --release
```

And produces a *single* ELF file.

``` console
$ ( cd target/thumbv8m.main-none-eabi/release/examples && size xspawn )
   text    data     bss     dec     hex filename
   1470       0      16    1486     5ce xspawn
```

I think it's worth noting that one *could* use the `homogeneous` mode to target
the heterogeneous LPC54114 (Cortex-M4F + Cortex-M0+) by selecting
`thumbv6m-none-eabi` as the compilation target. This works because the ARMv6-M
instruction set is a subset of the ARMv7E-M instruction set. The disadvantage of
this approach is that one would not be able to use CAS or FPU instructions on
the Cortex-M4F (ARMv7E-M) core as these are not available when one uses the
`thumbv6m-none-eabi` compilation target. The advantage is that the `homegeneous`
mode will work on stable Rust 1.36 whereas `heterogeneous` mode depends on
nightly because its dependency, μAMP, uses the unstable `auto trait` feature for
[memory safety].

[memory safety]: ../microamp/#data-not-code

# Outro

That covers the multi-core API. To my knowledge RTFM is the first Rust
concurrency framework that targets (heterogeneous) multi-core microcontrollers.

The PR for v0.5.0 is [up] so in theory you can go and try it out right now on a
multi-core device. In practice, though, I have not fully documented what RTFM
expects of the `device` crate in multi-core mode so it may be hard to try it out
on devices other than the ones I covered above.

[up]: https://github.com/japaric/cortex-m-rtfm/pull/205

We are using the next minor release (v0.5.0) to tweak various aspects of the
syntax, of which the most contentious bit is probably [the late resource
syntax]. There are [several RFCs][rfcs] open right now so if you have thoughts
on the syntax now would be a good time to comment.

[the late resource syntax]: https://github.com/japaric/cortex-m-rtfm/issues/202

## Supporting other architectures

As part of the work towards the RTFM v0.5.0 release I have refactored out the
main parts of the `#[app]` procedural macro in [reusable][] [crates] with
the goal of making it easier to port RTFM to other architectures.

[reusable]: https://github.com/japaric/rtfm-core
[crates]: https://github.com/japaric/rtfm-syntax

To test these crates I have written two (prototype) RTFM ports: one for the
[HiFive1][], a single-core RISC-V microcontroller, and one for [x86_64 Linux]
-- not a microcontroller! I know. The Linux port has multi-core (`cores`)
and timer-queue (`schedule`) support like the main Cortex-M port so if you want
to try out the multi-core API today that would be easiest thing to try.

[x86_64 Linux]: https://github.com/japaric/linux-rtfm
[HiFive1]: https://github.com/japaric/hifive1/tree/master/rtfm

I have [proposed] creating a GitHub organization for developing and maintaining
all these ports. The idea is to grow a team of people with expertise on
architectures other than ARM Cortex-M to work on these ports and keep them in
sync.

[proposed]: https://github.com/japaric/cortex-m-rtfm/issues/203

## RTFM?

I have also started a GitHub [thread] to discuss the possibility of renaming the
project or least changing its acronym. Not everyone is pleased with the RTFM
moniker for several reasons and I think that if we want to change the name doing
so before creating a GitHub org would be the best time.

[thread]: https://github.com/japaric/cortex-m-rtfm/issues/208

That's all I have for now. I'll announce the final v0.5.0 release of Real Time
for the Masses on [Twitter].

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
[Kjetil Kjeka],
[Kor Nielsen],
[Dietrich Ayala],
[Hadrien Grasland],
[Florian Uekermann],
[Ivan Dubrov]
and 65 more people for [supporting my work on Patreon][Patreon].

[Iban Eguia]: https://github.com/Razican
[Geoff Cant]: https://github.com/archaelus
[Harrison Chin]: http://www.harrisonchin.com/
[Brandon Edens]: https://github.com/brandonedens
[whitequark]: https://github.com/whitequark
[James Munns]: https://jamesmunns.com/
[Fredrik Lundström]: https://github.com/flundstrom2
[Kjetil Kjeka]: https://github.com/kjetilkjeka
[Kor Nielsen]: https://github.com/korran
[Dietrich Ayala]: https://metafluff.com/
[Hadrien Grasland]: https://github.com/HadrienG2
[vitiral]: https://github.com/vitiral
[Lee Smith]: https://github.com/leenozara
[Florian Uekermann]: https://github.com/FlorianUekermann
[Ivan Dubrov]: https://github.com/idubrov

---

Let's discuss on [reddit].

[reddit]: https://www.reddit.com/r/rust/comments/c477n3/real_time_for_the_masses_goes_multicore_embedded/

Enjoyed this post? Like my work on embedded stuff? Consider supporting my work
on [Patreon]!

[Patreon]: https://www.patreon.com/japaric

Follow me on [Twitter] for even more embedded stuff.

[Twitter]: https://twitter.com/japaricious

The embedded Rust community gathers on the #rust-embedded IRC channel
(irc.mozilla.org). Join us!
