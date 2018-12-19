+++
author = "Jorge Aparicio"
date = 2018-12-19T18:40:45+01:00
draft = false
tags = ["ARM Cortex-M", "concurrency", "RTFM"]
title = "RTFM v0.4: +stable, software tasks, message passing and a timer queue"
+++

Hey there! It's been a long time since my last post.

Today I'm pleased to announce [v0.4.0] of the Real Time for The Masses framework
(AKA RTFM), a concurrency framework for building real time applications.

[v0.4.0]: https://docs.rs/cortex-m-rtfm/0.4.0/rtfm/

The greatest new feature, IMO, is that RTFM now works on stable Rust (`1.31+`)!
:tada: :tada: :tada:

This release also packs quite a few new features which I'll briefly cover in
this post. For a more throughout explanation of RTFM's task model and its
capabilities check out [the RTFM book], which includes examples you can run on
your laptop (yay for emulation), and the [API documentation].

[the RTFM book]: https://japaric.github.io/cortex-m-rtfm/book/
[API documentation]: https://japaric.github.io/cortex-m-rtfm/api/rtfm/index.html

# New syntax

In previous releases you specified tasks and resources using a bang macro:
[`app!`]. This macro has been replaced by a bunch attributes: `#[app]`,
`#[interrupt]`, `#[exception]`, etc.

[`app!`]: https://github.com/japaric/cortex-m-rtfm/blob/v0.3.4/examples/preemption.rs#L11-L32

To give you an idea of the new syntax here's one example from the book:

``` rust
// examples/interrupt.rs

#![deny(unsafe_code)]
#![deny(warnings)]
#![no_main]
#![no_std]

extern crate panic_semihosting;

use cortex_m_semihosting::{debug, hprintln};
use lm3s6965::Interrupt;
use rtfm::app;

#[app(device = lm3s6965)]
const APP: () = {
    #[init]
    fn init() {
        // Pends the UART0 interrupt but its handler won't run until *after*
        // `init` returns because interrupts are disabled
        rtfm::pend(Interrupt::UART0);

        hprintln!("init").unwrap();
    }

    #[idle]
    fn idle() -> ! {
        // interrupts are enabled again; the `UART0` handler runs at this point

        hprintln!("idle").unwrap();

        rtfm::pend(Interrupt::UART0);

        // exit the emulator
        debug::exit(debug::EXIT_SUCCESS);

        loop {}
    }

    // interrupt handler = hardware task
    #[interrupt]
    fn UART0() {
        static mut TIMES: u32 = 0;

        // Safe access to local `static mut` variable
        *TIMES += 1;

        hprintln!(
            "UART0 called {} time{}",
            *TIMES,
            if *TIMES > 1 { "s" } else { "" }
        )
        .unwrap();
    }
};
```

``` console
$ qemu-system-arm (..) interrupt
init
UART0 called 1 time
idle
UART0 called 2 times
```

(The `const APP` that's used like a module must look a bit weird to you. I'll
get to it in a minute.)

The main motivation for this change is to allow composition with other
attributes like the built-in `#[cfg]` attribute, which is used for conditional
compilation, and an hypothetical [`#[ramfunc]`][ramfunc] attribute, which places
functions in RAM.

[ramfunc]: https://github.com/rust-embedded/cortex-m-rt/pull/100

``` rust
// NOTE: assuming some future release of cortex-m-rt
use cortex_m_rt::ramfunc;

#[rtfm::app(device = lm3s6965)]
const APP: () = {
    // ..

    // gotta go fast: run this exception handler (task) from RAM!
    #[exception]
    #[ramfunc]
    fn SysTick() {
        // ..
    }

    #[cfg(feature = "heartbeat")]
    #[interrupt(resources = [LED])]
    fn TIMER_0A() {
        resources.LED.toggle();
    }

    // ..
};
```

The other motivation is to let you decentralize the declaration of tasks and
resources. With the old `app!` macro everything had to be declared upfront in a
single place; with attributes you'll be able to declare tasks and resources in
different modules.

``` rust
// NOTE: this is NOT a valid rtfm v0.4 application!
#![rtfm::app]

mod resources {
    #[resource]
    static mut FOO: u32 = 0;
}

mod tasks {
    #[resource]
    static mut BAR: u32 = 0;

    #[interrupt(resources = [crate::resources::FOO, BAR])]
    fn UART0() {
        // ..
    }
}
```

However, that's more of a long term goal as it's currently not possible to use
crate level procedural macros or attributes on modules if you are using the
stable channel. The lack of those features on stable is why we are using a
`const` item as a module.

Finally, it's nice that RTFM applications don't contain any special syntax
(compared to v0.3's `app!`) so now `rustfmt` is able to format the whole
crate.

# Software tasks

Until RTFM v0.3, tasks could only be started by an *event* like the user
pressing a button, receiving new data or a software event (see [`rtfm::pend`]).
Also, each of those *hardware* tasks maps to a different interrupt handler
so you can run out of interrupt handlers if you have many tasks.

[`rtfm::pend`]: https://japaric.github.io/cortex-m-rtfm/api/rtfm/fn.pend.html

RTFM v0.4 introduces *software* tasks, tasks that can be *spawned* on-demand
from any context. The runtime will dispatch all the software tasks that run at
the same priority from the same interrupt handler so you won't run out of
interrupt handlers even if you have dozens of tasks.

Software tasks come in handy when you want to keep a hardware task responsive
to events: you can defer non time critical bits to a software task that runs
at lower priority.

``` rust
// heapless = "0.4.1"
use heapless::{consts::U16, Vec};

#[rtfm::app(device = lm3s6965)]
const APP: () = {
    // ..

    // high priority hardware task
    // started when a new byte of data is received
    // needs to finish relatively quickly or incoming data will be lost
    #[interrupt(priority = 2, spawn = [some_command])]
    fn UART0() {
        // Fixed capacity vector with inline storage (no heap memory is used)
        static mut BUFFER: Vec<u8, U16> = Vec::new();

        let byte = read_byte_from_serial_port();

        if byte == b'\n' {
            match &BUFFER[..] {
                b"some-command" => spawn.some_command().unwrap(),
                // .. handle other cases ..
            }

            BUFFER.clear();
        } else {
            if BUFFER.push(byte).is_err() {
                // .. handle error (buffer is full) ..
            }
        }
    }

    // lower priority software task
    // only runs when `UART0` is not running
    // this task can be preempted by `UART0`, which has higher priority
    #[task(priority = 1)]
    fn some_command() {
        // .. do non time critical stuff that takes a while to execute ..
    }

    // ..
};
```

# Message passing

When you spawn a task you can also send a message which will become the input of
the task. Message passing can remove the need for explicit memory sharing and
locks (see [`rtfm::Mutex`]) .

[`rtfm::Mutex`]: https://japaric.github.io/cortex-m-rtfm/api/rtfm/trait.Mutex.html

Using message passing we can change the previous example to handle all commands
from a single task.

``` rust
pub enum Command {
    Foo,
    Bar(u8),
    // ..
}

#[rtfm::app(device = lm3s6965)]
const APP: () = {
    // ..

    #[interrupt(priority = 2, spawn = [run_command])]
    fn UART0() {
        static mut BUFFER: Vec<u8, U16> = Vec::new();

        let byte = read_byte_from_serial_port();

        if byte == b'\n' {
            match &BUFFER[..] {
                // NOTE: this changed!
                b"foo" => spawn.run_command(Command::Foo).ok().unwrap(),
                // .. handle other cases ..
            }

            BUFFER.clear();
        } else {
            if BUFFER.push(byte).is_err() {
                // .. handle error (buffer is full) ..
            }
        }
    }

    // NOTE: NEW!
    // (the default priority for tasks is 1 so we can actually omit it here)
    #[task]
    fn run_command(command: Command) {
        match command {
            Command::Foo => { /* .. */ }
            // ..
        }
    }

    // ..
};
```

Furthermore, unlike hardware tasks, software tasks are buffered so you can spawn
several instances of them: all the posted messages will be queued and executed
in FIFO order.

All the internal buffers used by the RTFM runtime are statically allocated so
RTFM doesn't depend on a dynamic memory allocator. Instead, you specify the
capacity of the message queue in the `#[task]` attribute -- the capacity
defaults to 1 if not explicitly stated.

If in our running example we expect that some command will take long enough to
execute that another command may arrive in the meanwhile then we can increase
the capacity of the message queue.

``` rust
#[rtfm::app(device = lm3s6965)]
const APP: () = {
    // ..

    // now we can receive up to 2 more commands while this runs
    #[task(capacity = 2)]
    fn run_command(command: Command) {
        match command {
            Command::Foo => { /* .. */ }
            // ..
        }
    }

    // ..
};
```

# Timer queue

The RTFM framework provides an opt-in `timer-queue` feature (NOTE: ARMv7-M only
feature, for now). When enabled a global timer queue is added to the RTFM
runtime. This timer queue can be used to `schedule` tasks to run at some time in
the future.

One of the main uses cases of the `schedule` API (also see [`rtfm::Instant`] and
[`rtfm::Duration`]) is creating periodic tasks.

[`rtfm::Instant`]: https://japaric.github.io/cortex-m-rtfm/api/rtfm/struct.Instant.html
[`rtfm::Duration`]: https://japaric.github.io/cortex-m-rtfm/api/rtfm/struct.Duration.html

``` rust
const PERIOD: u32 = 12_000_000; // clock cycles == one second

#[rtfm::app(device = lm3s6965)]
const APP: () = {
    #[init(spawn = [periodic])]
    fn init() {
        // bootstrap the `periodic` task
        spawn.periodic().unwrap();
    }

    #[task(schedule = [periodic])]
    fn periodic() {
        // .. do stuff ..

        // schedule this task to run at `PERIOD` clock cycles after
        // it was last `scheduled` to run
        schedule.periodic(scheduled + PERIOD.cycles()).unwrap();
    }

    // ..
};
```

# What's next?

To compile on stable some sacrifices had to be made in terms of (static) memory
usage and code size. As there's no way to have uninitialized memory in `static`
variables I had to rely on `Option`s and late (runtime) initialization in
several places. But once `MaybeUninit` and `const fn` with trait bounds make
their way into stable I'll be able to remove all that unnecessary overhead.

More importantly though, I've been [playing] with Cortex-R processors, multicore
devices and asymmetric multiprocessing (AKA AMP)! And I'm happy to report that
not only have I got RTFM running on a Cortex-**R** core but I also have
implemented a proof of concept for *multicore* RTFM!

[playing]: https://mobile.twitter.com/japaricious/status/1071116410166935553

This is what my current multicore RTFM prototype looks like:

``` rust
#![no_main]
#![no_std]

extern crate panic_dcc;

use dcc::dprintln;

const LIMIT: u32 = 5;

#[rtfm::app(cores = 2)] // <- TWO cores!
const APP: () = {
    #[cfg(core = "0")]
    #[init]
    fn init() {
        // nothing to do here
    }

    // this task runs on the first core
    #[cfg(core = "0")]
    #[task(spawn = [pong])]
    fn ping(x: u32) {
        dprintln!("ping({})", x);

        if x < LIMIT {
            // here we send a mesasge to the other core!
            spawn.pong(x + 1).unwrap();
        }
    }

    #[cfg(core = "1")]
    #[init(tasks = [pong])]
    fn init() {
        // spawn the local `pong` task
        spawn.pong(0).unwrap();
    }

    // this task runs on the second core
    #[cfg(core = "1")]
    #[task(spawn = [ping])]
    fn pong(x: u32) {
        dprintln!("pong({})", x);

        if x < LIMIT {
            // another cross-core message!
            spawn.ping(x + 1).unwrap();
        }
    }
};
```

``` console
$ # logs from the first core
$ tail -f dcc0.log
IRQ(ICCIAR { cpuid: 1, ackintid: 65 })
ping(1)
~IRQ(ICCIAR { cpuid: 1, ackintid: 65 })
IRQ(ICCIAR { cpuid: 1, ackintid: 65 })
ping(3)
~IRQ(ICCIAR { cpuid: 1, ackintid: 65 })
IRQ(ICCIAR { cpuid: 1, ackintid: 65 })
ping(5)
~IRQ(ICCIAR { cpuid: 1, ackintid: 65 })
```

``` console
$ # logs from the second core
$ tail -f dcc1.log
IRQ(ICCIAR { cpuid: 1, ackintid: 66 })
pong(0)
~IRQ(ICCIAR { cpuid: 1, ackintid: 66 })
IRQ(ICCIAR { cpuid: 0, ackintid: 66 })
pong(2)
~IRQ(ICCIAR { cpuid: 0, ackintid: 66 })
IRQ(ICCIAR { cpuid: 0, ackintid: 66 })
pong(4)
~IRQ(ICCIAR { cpuid: 0, ackintid: 66 })
```

In this PoC, you write multicore applications in a single crate and you use
`#[cfg(core = "*")]` to assign tasks and resources to one core or the other.
Also, you can send messages across cores in a lock-free, wait-free, alloc-free
manner.

I have tested this PoC on a dual core Cortex-R5 device but I'm certain that the
approach can be adapted to heterogeneous devices (e.g. Cortex-M4 + Cortex-M0+)
which are more common in the microcontroller space.

This sounds nice and all but, unfortunately, this PoC is not *completely* memory
safe and thus not ready for show time. It has a few memory safety holes around
its uses of `Send` and `Sync` that I'm not sure how best to solve.

To give you an example of the issues I'm thinking about: something that's
*single-core* `Sync`, like [`bare_metal::Mutex`], is not necessarily
*multi-core* `Sync` (e.g. [`spin::Mutex`] is multi-core `Sync`) but there's only
one widely used `Sync` trait, which most people understand as multi-core `Sync`.
I can create my own `SingleCoreSync` but will the community adopt it? More
importantly, if we change `bare_metal::Mutex` to only implement `SingleCoreSync`
(and make it sound to use in the multicore RTFM model) then you won't be able to
use it in `static` variables (those require a `Sync` bound) which is a valid use
case today.

[`bare_metal::Mutex`]: https://docs.rs/bare-metal/0.2.4/bare_metal/struct.Mutex.html
[`spin::Mutex`]: https://docs.rs/spin/0.4.10/spin/struct.Mutex.html

Another example: a `&'static mut T` (or a `Box<T>`) is a safe thing to `Send`
from one task to another *within a core* but across cores safety depends on
where the reference points to. If it points to memory shared between the cores
then all's good, but if it points to memory that's only visible to one of the
cores (e.g. Tightly Coupled Memory) then the operation is UB. The problem is
that you can't tell where the reference points to by just looking at the type
because the location is specified using an attribute (`#[link_section]`).

I plan to do a more detailed blog post about `no_std` AMP in Rust. Hopefully,
the Rust community will give me some good ideas about how to deal with these
problems!

Until next time!

---

__Thank you patrons! :heart:__

I want to wholeheartedly thank:

<div class="grid">
  <div class="cell">
    <a href="https://www.sharebrained.com/" style="border-bottom:0px">
      <img alt="ShareBrained Technology" class="image" src="/logo/sharebrained.png"/>
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
[Alexander Payne],
[Dietrich Ayala],
[Hadrien Grasland],
[vitiral],
[Lee Smith],
[Florian Uekermann],
[Adam Green]
and 57 more people for [supporting my work on Patreon][Patreon].

[Iban Eguia]: https://github.com/Razican
[Geoff Cant]: https://github.com/archaelus
[Harrison Chin]: http://www.harrisonchin.com/
[Brandon Edens]: https://github.com/brandonedens
[whitequark]: https://github.com/whitequark
[James Munns]: https://jamesmunns.com/
[Fredrik Lundström]: https://github.com/flundstrom2
[Kjetil Kjeka]: https://github.com/kjetilkjeka
[Kor Nielsen]: https://github.com/korran
[Alexander Payne]: https://myrrlyn.net/
[Dietrich Ayala]: https://metafluff.com/
[Hadrien Grasland]: https://github.com/HadrienG2
[vitiral]: https://github.com/vitiral
[Lee Smith]: https://github.com/leenozara
[Florian Uekermann]: https://github.com/FlorianUekermann
[Adam Green]: https://github.com/adamgreen

---

Let's discuss on [reddit].

[reddit]: TODO

Enjoyed this post? Like my work on embedded stuff? Consider supporting my work
on [Patreon]!

[Patreon]: https://www.patreon.com/japaric

Follow me on [twitter] for even more embedded stuff.

[twitter]: https://twitter.com/japaricious

The embedded Rust community gathers on the #rust-embedded IRC channel
(irc.mozilla.org). Join us!
