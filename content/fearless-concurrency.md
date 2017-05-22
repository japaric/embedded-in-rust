+++
author = "Jorge Aparicio"
date = "2017-05-09T09:07:39-05:00"
description = "Build memory safe multitasking applications with Rust"
draft = false
tags = ["ARM Cortex-M", "concurrency", "rtfm"]
title = "Fearless concurrency in your microcontroller"
+++

I want to start by thanking all the people that has [sent][1] [improvements][2]
and [comments][3] to [all][4] the [crates][5] and tools I presented in the last
blog post. The Rust community rocks!

[1]: https://github.com/japaric/svd2rust/pulls?q=is:pr%20created:>=2017-04-28%20
[2]: https://github.com/japaric/cortex-m-quickstart/pulls?q=is:pr%20created:>=2017-04-28%20
[3]: https://github.com/japaric/svd2rust/issues?utf8=✓&q=is:issue%20created:>=2017-04-28
[4]: https://github.com/rust-lang/rust/pull/41637
[5]: https://github.com/japaric/cortex-m-rt/pulls?utf8=✓&q=is:pr%20created:>=2017-04-28

---

[Last time] I showed you how to easily develop Rust programs for pretty much
any ARM Cortex-M microcontroller. In this post I'll show you one way of doing
memory safe concurrency. It's important to note that the Rust language doesn't
impose a *single* concurrency model. Instead it gives you building blocks in
the form of the `Send` and `Sync` traits, and the borrow checker. Concurrency
models can then be implemented as crates (libraries) that leverage those core
features.

[Last time]: /quickstart

In the last post I left you with this figure:

![Multitask application](/quickstart/multitask.svg)

Today I reveal the missing piece: the [`cortex-m-rtfm`] crate, a realization of
the Real Time For the Masses (RTFM) framework [^framework] for the Cortex-M
architecture. This framework's main goal is facilitating development of embedded
real time software, but it can be used for general concurrent programming as
well. These are its main features:

[`cortex-m-rtfm`]: https://docs.rs/cortex-m-rtfm/0.1.0/cortex_m_rtfm/
[^framework]: I call it framework, instead of just library, because it forces a
    certain structure into your program

- **Event triggered tasks** as the unit of concurrency.
- Support for prioritization of tasks and, thus, **preemptive multitasking**.
- **Efficient and data race free memory sharing** through fine grained *non
  global* critical sections.
- **Deadlock free execution** guaranteed at compile time.
- **Minimal scheduling overhead** as the scheduler has no "software component":
  the hardware does all the scheduling.
- **Highly efficient memory usage**: All the tasks share a single call stack and
  there's no hard dependency on a dynamic memory allocator.
- **All Cortex M3, M4 and M7 devices are fully supported**. M0(+) is partially
  supported as the whole API is not available due to missing hardware features

This framework is actually a port of the core ideas of the [RTFM language] to
Rust. The RTFM language was created by [LTU]'s Embedded Systems group, led by
prof. [Per Lindgren], to develop real time systems for which FreeRTOS didn't fit
the bill. Prof. Lindgren and I have been working on this port for a while, and
we believe it's now in good shape enough for a v0.1.0 release.

[LTU]: https://www.ltu.se/
[Per Lindgren]: https://www.ltu.se/staff/p/pln-1.11258?l=en
[RTFM language]: http://www.rtfm-lang.org/

In the rest of this post I'll illustrate the core concepts of the RTFM
framework by building an application that runs two tasks concurrently.

# The application

Will be a LED roulette (for lack of a better word) controlled via serial
interface. This is what it will look like:

<p style="text-align: center">
<video controls>
  <source src="/fearless-concurrency/control.webm" type="video/webm">
</video>
</p>

This roulette never actually stops spinning, but its spin direction can be
reversed at any time (see 00:00:03) by sending the `"reverse"` command over the
serial interface. The roulette can operate in two modes: *continuous* mode
(00:00:00 - 00:00:06) where the roulette keeps spinning in the same direction,
and *bounce* mode (00:00:06-00:00:11) where the roulette reverses its direction
every time it completes one turn. The mode can be selected by sending one of
these two strings through the serial interface: `"continuous"` and `"bounce"`.

In the video I'm emulating a serial interface on top of Bluetooth [^rfcomm], and
I'm sending the commands by typing them on a program
called [`minicom`](https://en.wikipedia.org/wiki/Minicom) (shown below).

[^rfcomm]: using the [RFCOMM](https://en.wikipedia.org/wiki/List_of_Bluetooth_protocols#Radio_frequency_communication_.28RFCOMM.29) protocol

![minicom](/fearless-concurrency/minicom.png)

We'll build this application incrementally, but before that let's first port the
two programs that I presented in the previous post.

# Hello, world! (again)

This is what "Hello, world" looks like when ported to the RTFM framework. You
can see the previous version [here][qs-hello].

[qs-hello]: /quickstart/#hello-world

``` rust
// examples/hello.rs
//! Prints "Hello" and then "World" on the OpenOCD console

#![feature(used)]
#![no_std]

// version = "0.2.6"
#[macro_use]
extern crate cortex_m;

// version = "0.2.0"
extern crate cortex_m_rt;

// version = "0.1.0"
#[macro_use]
extern crate cortex_m_rtfm as rtfm;

// version = "0.4.1"
extern crate f3;

use f3::stm32f30x;
use rtfm::{P0, T0, TMax};

// TASKS
tasks!(stm32f30x, {});

// INITIALIZATION PHASE
fn init(_priority: P0, _threshold: &TMax) {
    hprintln!("Hello");
}

// IDLE LOOP
fn idle(_priority: P0, _threshold: T0) -> ! {
    hprintln!("World");

    // Sleep
    loop {
        rtfm::wfi();
    }
}
```

First thing to note is the `tasks!` macro. I mentioned above that the unit of
concurrency of the RTFM framework is the *task*. The `tasks!` macro is used to
declare all the tasks that made up a program. This particular program has zero
tasks, and that's why the second argument of the macro is just empty braces.

The first argument of the `tasks!` macro *must* be a device crate generated
using the [svd2rust] tool. In this case our program doesn't directly depend on
a device crate; instead it depends on the board support crate [`f3`]. But the
`f3` crate builds upon the device crate [`stm32f30x`] and re-exports it as part
of its API so we can still pass the `stm32f30x` crate to the `tasks!` macro.

[svd2rust]: https://docs.rs/svd2rust/0.7.2/svd2rust/
[`f3`]: https://docs.rs/f3/0.4.1/f3/
[`stm32f30x`]: https://docs.rs/stm32f30x/0.4.1/stm32f30x/

Next thing to note is that the `main` function is missing. Instead we have two
functions: `init` and `idle`. `main` is not required because `tasks!` expands to
a `main` function that will call `init` first and then `idle`.

Finally, note that the  `INTERRUPTS` variable, where interrupt handlers are
normally registered, is missing as well: the `tasks!` macro will create that
variable for us.

Now, let's look at both `init` and `idle` in detail.

The signature of `init` must be `fn(P0, &TMax)`, and the signature of `idle`
must be `fn(P0, T0) -> !`; both signatures are enforced by the `tasks!` macro.
Both `init` and `idle` have two similarly looking arguments available to them:
`priority` and `threshold`. These are zero sized *tokens* that grant them some
privileges. We won't use them in this program though.

The RTFM scheduler uses priorities as part of its scheduling algorithm: *Tasks*
with a higher priority level are more urgent so the scheduler prioritizes their
execution. Although they are *not* tasks, both `init` and `idle` also have a
priority: 0, the lowest priority. The RTFM framework keeps track of priorities
in the type system, in the form of tokens like `P0` and `P1`. The number of
priority levels is device dependent; the STM32F303VCT6 microcontroller, for
instance, supports priorities from 0 (`P0`) to 16 (`P16`).

I'll say more about the `threshold` token later on.

Next, note that `idle` is a *diverging* function, as evidenced by its signature:
`fn(..) -> !`; this means that it *can't* return or terminate. To avoid
returning from `idle` after printing "World" to console, the CPU is put to sleep
(to conserve energy) by calling the WFI (Wait For Interrupt) instruction in a
loop. The "Hello, world" program from the previous post also did this, but
implicitly.

To run this program we can continue from
[the demo crate from the previous post][demo] and run the following commands:

[demo]: /quickstart/#the-cargo-project-template

``` console
$ # add the RTFM framework as a dependency
$ cargo add cortex-m-rtfm --vers 0.1.0

$ # update the source to use the RTFM framework
$ edit examples/hello.rs

$ # (re)compile the program
$ xargo build --example hello

$ # flash and run
$ arm-none-eabi-gdb target/thumbv7em-none-eabihf/examples/hello
```

Then you should see this on the OpenOCD console:

``` console
$ openocd -f interface/stlink-v2-1.cfg -f target/stm32f3x.cfg
(..)
xPSR: 0x01000000 pc: 0x080007e2 msp: 0x10002000, semihosting
Hello
World
```

# A blinking task

Next, let's port [the blinky program from previous post][qs-blinky] to the RTFM
framework. Here's the full program:

[qs-blinky]: /quickstart/#board-support-crates

``` rust
// examples/blinky.rs
//! Blinks an LED

#![feature(const_fn)]
#![feature(used)]
#![no_std]

// version = "0.2.0"
extern crate cortex_m_rt;

// version = "0.1.0"
#[macro_use]
extern crate cortex_m_rtfm as rtfm;

// version = "0.4.1"
extern crate f3;

use f3::led::{self, LEDS};
use f3::stm32f30x::interrupt::Tim7;
use f3::stm32f30x;
use f3::timer::Timer;
use rtfm::{Local, P0, P1, T0, T1, TMax};

// CONFIGURATION
const FREQUENCY: u32 = 1; // Hz

// RESOURCES
peripherals!(stm32f30x, {
    GPIOE: Peripheral {
        register_block: Gpioe,
        ceiling: C0,
    },
    RCC: Peripheral {
        register_block: Rcc,
        ceiling: C0,
    },
    TIM7: Peripheral {
        register_block: Tim7,
        ceiling: C1,
    },
});

// INITIALIZATION PHASE
fn init(ref priority: P0, threshold: &TMax) {
    let gpioe = GPIOE.access(priority, threshold);
    let rcc = RCC.access(priority, threshold);
    let tim7 = TIM7.access(priority, threshold);
    let timer = Timer(&tim7);

    // Configure the PEx pins as output pins
    led::init(&gpioe, &rcc);

    // Configure TIM7 for periodic update events
    timer.init(&rcc, FREQUENCY);

    // Start the timer
    timer.resume();
}

// IDLE LOOP
fn idle(_priority: P0, _threshold: T0) -> ! {
    // Sleep
    loop {
        rtfm::wfi();
    }
}

// TASKS
tasks!(stm32f30x, {
    periodic: Task {
        interrupt: Tim7,
        priority: P1,
        enabled: true,
    },
});

fn periodic(mut task: Tim7, ref priority: P1, ref threshold: T1) {
    // Task local data
    static STATE: Local<bool, Tim7> = Local::new(false);

    let tim7 = TIM7.access(priority, threshold);
    let timer = Timer(&tim7);

    if timer.clear_update_flag().is_ok() {
        let state = STATE.borrow_mut(&mut task);

        *state = !*state;

        if *state {
            LEDS[0].on();
        } else {
            LEDS[0].off();
        }
    } else {
        // Only reachable through `rtfm::request(periodic)`
        #[cfg(debug_assertion)]
        unreachable!()
    }
}
```

Let's analyze this program in parts:

## `peripherals!`

First we have the `peripherals!` macro:

``` rust
peripherals!(stm32f30x, {
    GPIOE: Peripheral {
        register_block: Gpioe,
        ceiling: C0,
    },
    RCC: Peripheral {
        register_block: Rcc,
        ceiling: C0,
    },
    TIM7: Peripheral {
        register_block: Tim7,
        ceiling: C1,
    },
});
```

When using the RTFM framework you have to declare *all* the peripherals you are
going to use in this macro. Both the name of the peripheral (for example:
`GPIOE`) and its type (for example: `Gpioe`) must match the device crate,
`stm32f30x` in this case, definitions. What's new here is that each peripheral
must be assigned a *ceiling*. For now suffices to say that ceilings are just
(type level) numbers in the same range as priorities. In this case ceilings can
range from `C0` to `C16`.

## `init`

Next we have the `init` function:

``` rust
fn init(ref priority: P0, threshold: &TMax) {
    let gpioe = GPIOE.access(priority, threshold);
    let rcc = RCC.access(priority, threshold);
    let tim7 = TIM7.access(priority, threshold);
    let timer = Timer(&tim7);

    // Configure the PEx pins as output pins
    led::init(&gpioe, &rcc);

    // Configure TIM7 for periodic update events
    timer.init(&rcc, FREQUENCY);

    // Start the timer
    timer.resume();
}
```

Here we configure the LED pin and the timer. The timer will be configured to
generate a periodic update event every one second. The code here is actually the
same as the one from the previous blog post version. In that old version we
created a critical section by disabling all the interrupts (`interrupt::free`).
That gave us the necessary synchronization to access the peripherals. The same
happens here: `init` runs under the same kind of *global* critical section; this
is reflected in its `threshold` token which has type `TMax`, the maximum
*preemption threshold*.

The `threshold` token indicates the preemption threshold of the current context.
This threshold indicates the priority that a task must have to preempt the
current context. A threshold of 0, `T0`, indicates that only tasks with priority
of 1 *or* higher can preempt the current context. This is the case of the `idle`
loop: it can be preempted by *any* task since tasks are enforced to always have
a priority of 1 or higher. On the other hand, the maximum threshold, `TMax`, (as
used in `init`) indicates that the current context can't be preempted by any
task.

To actually be able to use the peripherals we must first call the `access`
method. This method requires you to present both the `priority` and the
`threshold` tokens. There are some conditions that must be met between the
priority level, the threshold level and the peripheral ceiling for this method
to work. If the conditions are not met the program won't compile as it would not
be free of data races. The exact conditions are not important at this point
because you'll always be able to access any peripheral within the `init`
function.

## `idle`

``` rust
fn idle(_priority: P0, _threshold: T0) -> ! {
    // Sleep
    loop {
        rtfm::wfi();
    }
}
```

In this program the processor is sent to sleep in the `idle` function.

We could have written something like this:

``` rust
fn idle(priority: P0, threshold: T0) -> ! {
    // ..

    let mut state = false;
    loop {
        while timer.clear_update_flag().is_err() {}

        state = !state;

        if state {
            LEDS[0].on();
        } else {
            LEDS[0].off();
        }
    }
}
```

and we would have ended with the same inefficient busy waiting behavior as the
program from the previous post.

But we are not going to do that. Instead we are going to use ...

## `tasks!`

In the RTFM framework tasks are implemented on top of interrupt handlers; in
fact, each task *is* an interrupt handler. This means that each task is
triggered by the events that would trigger the corresponding interrupt, and also
that each task has a priority.

From the POV of the programmer a task is just a function with the peculiarity
that it will be called by the hardware when some event happens: 10 ms have
elapsed, user pressed a button, data arrived, etc.

In this program, we'll use a single task named `periodic`:

``` rust
tasks!(stm32f30x, {
    periodic: Task {
        interrupt: Tim7,
        priority: P1,
        enabled: true,
    },
});
```

This declaration says that the `periodic` task is the interrupt `Tim7` (TIM7 is
the timer we are using to generate periodic update events), and has a priority
of 1 (`P1`), the lowest priority a task can have. `enabled: true` means
that the `Tim7` interrupt, and thus this task, *will* be enabled after `init`
finishes but before `idle` starts.

This is how scheduling will look like for this program:

![A single periodic task](/fearless-concurrency/periodic.svg)

- The processor will be executing the endless `idle` function where it sleeps
  most of the time due to the WFI instruction.
- At some point, the update event (`UE`) will occur waking up the CPU.
- Because the `periodic` task has higher priority than `idle` the scheduler
  will *pause* the execution of `idle` and then launch the `periodic` task. IOW,
  the   `periodic` task will *preempt* `idle`.
- Once the `periodic` task finishes the scheduler will resume the execution
  of the `idle` loop where the CPU is sent back to sleep.
- The process repeats.

Something important: tasks have *run to completion semantics*. The scheduler
will run every task to completion and only temporarily switch to another task
*if it has higher priority*. For this reason tasks must *not* contain endless
loops; otherwise lower priority tasks will never get a chance to run (this is
known as *starvation*).

## Task local data

We have a `periodic` task (function) that will be executed (called) every
second. We want to toggle the state of an LED on every invocation of the task
but the task is effectively a function and has no state. How do we add state?
The obvious answer would be to use a `static mut` variable, an unsynchronized
global variable, but that's `unsafe`. Instead we'll use the safe task local data
abstraction: `Local`.

Here's the `periodic` task:

``` rust
fn periodic(mut task: Tim7, ref priority: P1, ref threshold: T1) {
    // Task local data
    static STATE: Local<bool, Tim7> = Local::new(false);

    let tim7 = TIM7.access(priority, threshold);
    let timer = Timer(&tim7);

    if timer.clear_update_flag().is_ok() {
        let state = STATE.borrow_mut(&mut task);

        *state = !*state;

        if *state {
            LEDS[0].on();
        } else {
            LEDS[0].off();
        }
    } else {
        // Only reachable through `rtfm::request(periodic)`
        #[cfg(debug_assertion)]
        unreachable!()
    }
}
```

The signature of the `periodic` task must match its `tasks!` declaration; it
must contain three arguments: a `task` token whose type must match the
`interrupt` field of the declaration, a `priority` token whose type must match
the `priority` field of the declaration, and a `threshold` token whose type must
match the level of the `priority` token.

The `priority` and `threshold` tokens we have already seen. The new token here
is the `task` token. Each task has a unique `task` token type. The main use of
this token is accessing task local data. When you create task local data you
pin it to a certain task by assigning a `task` token type to it (for example,
the `Tim7` in `Local<bool, Tim7>`). Afterwards, you can only access the data if
you present an instance of the token, which only a single task has access to.
This arrangement disables sharing of this kind of data across tasks eliminating
the possibility of data races.

As for the logic of the `periodic` task, we simply toggle the boolean `STATE`
variable and turn the LED on / off depending on its value. The interesting bit
here is that we branch depending on the result of
`timer.clear_update_flag().is_ok()`. That expression clears the update event
flag and returns an error (`Err` variant) if the flag was not set. We have to
clear that flag or the task will get invoked again right after it finishes. In
this program we should never hit the `Err` branch because the task is always
triggered by the update event. But that may not be the case in general as it's
possible to manually trigger a task using the `rtfm::request` function.

Something I omitted is that the `TIM7` was `access`ed without extra
synchronization. The reason why this was possible is the ceiling value that was
assigned to `TIM7` (`C1`) matches the task priority (`P1`) and preemption
threshold (`T1`).

If you run this program, you'll see one LED blink. I already showed a video of
this in [the last post] so I'm not going to post it again.

[the last post]: /quickstart/#blinky

# LED Roulette

With some small changes we can turn the LED blinking application into the LED
roulette shown in the intro video. The full code for the roulette is [here].
These are the relevant changes:

[here]: https://docs.rs/f3/0.4.1/f3/examples/_4_roulette/index.html

``` rust
// examples/roulette.rs

// version = "0.2.0", default-features = false
extern crate cast;

use cast::{u8, usize};

// ..

// CONFIGURATION
const FREQUENCY: u32 = 8; // Hz

// ..

// renamed from `periodic` to `roulette`
tasks!(stm32f30x, {
    roulette: Task {
        interrupt: Tim7,
        priority: P1,
        enabled: true,
    },
});

fn roulette(mut task: Tim7, ref priority: P1, ref threshold: T1) {
    static STATE: Local<u8, Tim7> = Local::new(0);

    let tim7 = TIM7.access(priority, threshold);
    let timer = Timer(&tim7);

    if timer.clear_update_flag().is_ok() {
        let state = STATE.borrow_mut(&mut task);

        let curr = *state;
        let next = (curr + 1) % u8(LEDS.len()).unwrap();

        LEDS[usize(curr)].off();
        LEDS[usize(next)].on();

        *state = next;
    } else {
        // Only reachable through `rtfm::request(roulette)`
        #[cfg(debug_assertion)]
        unreachable!()
    }
}
```

Outcome:

<video controls>
  <source src="/fearless-concurrency/roulette.webm" type="video/webm">
</video>

Note that the roulette is spinning in clockwise direction. And yes, this
roulette is spinning faster than the one shown in the intro video.

# Serial loopback

Now we are going to write a totally different program to test out the serial
interface: a loopback. A software loopback is when you send back the data you
just received without processing it. This is a great way to sanity check that
your serial code is working (and that you got the wiring right).

By default [^echo] `minicom` doesnt print back the characters you type, which
are the characters you send through the terminal interface. However, if the
other side of the serial connection is doing a loopback then you should see
what you type printed on the console because that's what the serial device sends
back  to you.

The full source of the loopback program is [here][loopback.rs]. These are the
relevant bits:

[loopback.rs]: https://docs.rs/f3/0.4.1/f3/examples/_5_loopback/index.html
[^echo]: There's a local echo setting to enable that local echo but we are not
    going to use it

``` rust
// example/loopback.rs

// CONFIGURATION
pub const BAUD_RATE: u32 = 115_200; // bits per second

// RESOURCES
peripherals!(stm32f30x, {
    GPIOA: Peripheral {
        register_block: Gpioa,
        ceiling: C0,
    },
    RCC: Peripheral {
        register_block: Rcc,
        ceiling: C0,
    },
    USART1: Peripheral {
        register_block: Usart1,
        ceiling: C1,
    },
});

// INITIALIZATION PHASE
fn init(ref priority: P0, threshold: &TMax) {
    let gpioa = GPIOA.access(priority, threshold);
    let rcc = RCC.access(priority, threshold);
    let usart1 = USART1.access(priority, threshold);

    let serial = Serial(&usart1);

    serial.init(&gpioa, &rcc, BAUD_RATE);
}

// ..

// TASKS
tasks!(stm32f30x, {
    loopback: Task {
        interrupt: Usart1Exti25,
        priority: P1,
        enabled: true,
    },
});

// Send back the received byte
fn loopback(_task: Usart1Exti25, ref priority: P1, ref threshold: T1) {
    let usart1 = USART1.access(priority, threshold);
    let serial = Serial(&usart1);

    if let Ok(byte) = serial.read() {
        if serial.write(byte).is_err() {
            // As we are echoing the bytes as soon as they arrive, it should
            // be impossible to have a TX buffer overrun
            #[cfg(debug_assertions)]
            unreachable!()
        }
    } else {
        // Only reachable through `rtfm::request(loopback)`
        #[cfg(debug_assertions)]
        unreachable!()
    }
}
```

Let's go through the program in parts:

``` rust
// CONFIGURATION
pub const BAUD_RATE: u32 = 115_200; // bits per second
```

We have to pick a transmission speed for the interface. Any number will do as
long as both sides are configured to run at the same speed. `115_200` is a
standard and pretty common baud rate.

``` rust
fn init(ref priority: P0, threshold: &TMax) {
    let gpioa = GPIOA.access(priority, threshold);
    let rcc = RCC.access(priority, threshold);
    let usart1 = USART1.access(priority, threshold);

    let serial = Serial(&usart1);

    serial.init(&gpioa, &rcc, BAUD_RATE);
}
```

In `init` we configure the Serial interface to run at `115_200` bits per
second. It should be noted that the `init` method also configures the USART1
peripheral to generate interrupt events when a new byte is received.

``` rust
tasks!(stm32f30x, {
    loopback: Task {
        interrupt: Usart1Exti25,
        priority: P1,
        enabled: true,
    },
});
```

Here we bind the `loopback` task to the `Usart1Exti25` interrupt handler. As
already mentioned the `Usart1Exti25` interrupt, and thus the `loopback` task,
will be triggered every time a new byte is received.

``` rust
fn loopback(_task: Usart1Exti25, ref priority: P1, ref threshold: T1) {
    let usart1 = USART1.access(priority, threshold);
    let serial = Serial(&usart1);

    if let Ok(byte) = serial.read() {
        if serial.write(byte).is_err() {
            // As we are echoing the bytes as soon as they arrive, it should
            // be impossible to have a TX buffer overrun
            #[cfg(debug_assertions)]
            unreachable!()
        }
    } else {
        // Only reachable through `rtfm::request(loopback)`
        #[cfg(debug_assertions)]
        unreachable!()
    }
}
```

The `loopback` task will send back the byte that was just received. It's
important to note that both the `read` and `write` methods used here are *non
blocking*. Two error conditions needs to be dealt with:

- `serial.read()` returns an error if there was no new data available. This
  condition should be unreachable in our program because the `loopback` task
  only runs every time a new byte is available.

- `serial.write(byte)` returns an error if the TX (send) buffer overflows, which
  should only occur when attempting to send bytes faster than what the current
  baud rate setting allows. This shouldn't be a problem in this case because we
  are sending *one* byte back every time a new byte arrives so the TX data rate
  can never exceed the RX (receive) data rate, which caps at `115_200` bps.

Let's draw a possible timeline of events for this program:

![Loopback](/fearless-concurrency/loopback.svg)

There's only one task running and is non periodic. The task will run only when a
new byte arrives. We'll call this new byte arrived event `RX`.

# Concurrency

Now let's merge these two last programs into a single one. The merged program
will run the `roulette` and `loopback` tasks concurrently. This is actually
trivial to implement beacuse the two tasks are independent: they don't share
state or have a run task A after task B" kind of relationship.

The full source of the merged program is [here][concurrent.rs]. The relevant
parts are shown below:

[concurrent.rs]: https://docs.rs/f3/0.4.1/f3/examples/_6_concurrency/index.html

``` rust
// ..

// INITIALIZATION PHASE
fn init(ref priority: P0, threshold: &TMax) {
    // ..

    // merge both `init`s
    led::init(&gpioe, &rcc);
    timer.init(&rcc, FREQUENCY);
    serial.init(&gpioa, &rcc, BAUD_RATE);

    timer.resume();
}

// TASKS
// declare both tasks
tasks!(stm32f30x, {
    loopback: Task {
        interrupt: Usart1Exti25,
        priority: P1,
        enabled: true,
    },
    roulette: Task {
        interrupt: Tim7,
        priority: P1,
        enabled: true,
    },
});

fn loopback(_task: Usart1Exti25, ref priority: P1, ref threshold: T1) {
    // same as before
}

fn roulette(mut task: Tim7, ref priority: P1, ref threshold: T1) {
    // same as before
}
```

If you run this program you should see the LED roulette in action *and* the
serial console should echo what you type. Yay, multitasking!

Lets see how the scheduler would handle these two task running concurrently:

![Concurrency](/fearless-concurrency/concurrency.svg)

The timeline depicts three situations:

- Only one task, the `roulette` task, runs.

- The `loopback` task is running, and an Update Event (`UE`) occurs. Because
  both   tasks have the same priority the execution of the `roulette` task will
  be   postponed until after `loopback` ends.

- Similar situation but a RX event occurs during the execution of the `roulette`
  task. Again, `receive` won't run until after `roulette` ends.

# Parsing

Let's continue building the final application. We'll have to parse the strings
received through the serial interface. This will require storing the characters
into a buffer. We'll use the [`heapless`] crate to avoid depending on a dynamic
memory allocator; this crate provides common data structures backed by
statically allocated memory.

[`heapless`]: https://docs.rs/heapless/0.1.0/heapless/

These are the relevant changes:

``` rust
// version = "0.1.0"
extern crate heapless;

// ..

// Growable array backed by a fixed size chunk of memory
use heapless::Vec;

// ..

// renamed the `loopback` task to `receive`
fn receive(mut task: Usart1Exti25, ref priority: P1, ref threshold: T1) {
    // 16 byte buffer
    static BUFFER: Local<Vec<u8, [u8; 16]>, Usart1Exti25> = {
        Local::new(Vec::new([0; 16]))
    };

    let usart1 = USART1.access(priority, threshold);
    let serial = Serial(&usart1);

    if let Ok(byte) = serial.read() {
        if serial.write(byte).is_err() {
            // As we are echoing the bytes as soon as they arrive, it should
            // be impossible to have a TX buffer overrun
            #[cfg(debug_assertions)]
            unreachable!()
        }

        let buffer = BUFFER.borrow_mut(&mut task);

        if byte == b'\r' {
            // end of command

            match &**buffer {
                b"bounce" => /* TODO */,
                b"continuous" => /* TODO */,
                b"reverse" => /* TODO */,
                _ => {}
            }

            // clear the buffer to prepare for the next command
            buffer.clear();
        } else {
            // push the byte into the buffer

            if buffer.push(byte).is_err() {
                // error: buffer full
                // KISS: we just clear the buffer when it gets full
                buffer.clear();
            }
        }
    } else {
        // Only reachable through `rtfm::request(receive)`
        #[cfg(debug_assertions)]
        unreachable!()
    }
}
```

Now we are parsing user commands but we are not obeying them. To do that, we'll
need some form of communication between the `roulette` task and the `receive`
task.

# Sharing memory

The RTFM framework provides a `Resource` abstraction that can be used to share
memory between two or more tasks in a data race free manner.

We'll use the following resource to share state [^channel] between the
`roulette` and `receive` tasks:

[^channel]: Yes, a channel abstraction would have been better but we don't yet
    have those in RTFM. I opted for not further complicating the example by
    using shared state instead of building a channel abstraction on top of
    `Resource`.

``` rust
static SHARED: Resource<State, C1> = Resource::new(State::new());
```

where `State` is defined like this:

``` rust
struct State {
    direction: Cell<Direction>,
    mode: Cell<Mode>,
}

impl State {
    const fn new() -> Self {
        State {
            direction: Cell::new(Direction::Clockwise),
            mode: Cell::new(Mode::Continuous),
        }
    }
}

#[derive(Clone, Copy)]
enum Direction {
    Clockwise,
    Counterclockwise,
}

impl Direction {
    fn reverse(self) -> Self {
        match self {
            Direction::Clockwise => Direction::Counterclockwise,
            Direction::Counterclockwise => Direction::Clockwise,
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Bounce,
    Continuous,
}
```

When you declare a resource you must assign a *ceiling* to it in its type
signature. I'll assign a ceiling of 1 (`C1`) to this resource; this value
matches the priority of both the `roulette` and `receive` tasks.

Because both tasks run at the same priority no preemption can occur: if both
tasks needs to run at around the same time one task will be postponed until
after the other finishes. Because of this no data race can occur if `roulette`
and `receive` directly `access` the `SHARED` resource.

With that in mind, let's see the new task code.

Here's the complete `receive` task:

``` rust
fn receive(mut task: Usart1Exti25, ref priority: P1, ref threshold: T1) {
    // 16 byte buffer
    static BUFFER: Local<Vec<u8, [u8; 16]>, Usart1Exti25> = {
        Local::new(Vec::new([0; 16]))
    };

    let usart1 = USART1.access(priority, threshold);
    let serial = Serial(&usart1);

    if let Ok(byte) = serial.read() {
        if serial.write(byte).is_err() {
            // As we are echoing the bytes as soon as they arrive, it should
            // be impossible to have a TX buffer overrun
            #[cfg(debug_assertions)]
            unreachable!()
        }

        let buffer = BUFFER.borrow_mut(&mut task);

        if byte == b'\r' {
            // end of command

            // NEW!
            let shared = SHARED.access(priority, threshold);
            match &**buffer {
                b"bounce" => shared.mode.set(Mode::Bounce),
                b"continuous" => shared.mode.set(Mode::Continuous),
                b"reverse" => {
                    shared.direction.set(shared.direction.get().reverse());
                }
                _ => {}
            }

            // clear the buffer to prepare for the next command
            buffer.clear();
        } else {
            // push the byte into the buffer

            if buffer.push(byte).is_err() {
                // error: buffer full
                // KISS: we just clear the buffer when it gets full
                buffer.clear();
            }
        }
    } else {
        // Only reachable through `rtfm::request(receive)`
        #[cfg(debug_assertions)]
        unreachable!()
    }
}
```

And here's the updated `roulette` task:

``` rust
fn roulette(mut task: Tim7, ref priority: P1, ref threshold: T1) {
    static STATE: Local<u8, Tim7> = Local::new(0);

    let tim7 = TIM7.access(priority, threshold);
    let timer = Timer(&tim7);

    if timer.clear_update_flag().is_ok() {
        let state = STATE.borrow_mut(&mut task);
        let curr = *state;

        // NEW!
        let shared = SHARED.access(priority, threshold);
        let mut direction = shared.direction.get();

        if curr == 0 && shared.mode.get() == Mode::Bounce {
            direction = direction.reverse();
            shared.direction.set(direction);
        }

        let n = u8(LEDS.len()).unwrap();
        let next = match direction {
            Direction::Clockwise => (curr + 1) % n,
            Direction::Counterclockwise => curr.checked_sub(1).unwrap_or(n - 1),
        };

        LEDS[usize(curr)].off();
        LEDS[usize(next)].on();

        *state = next;
    } else {
        // Only reachable through `rtfm::request(roulette)`
        #[cfg(debug_assertion)]
        unreachable!()
    }
}
```

This `access` method has the exact same signature as the peripheral's one. Both
methods require you to present a `priority` and a `threshold` token. This is no
coincidence: when we declare peripherals in the `peripherals!` macro we are
actually converting the raw peripherals defined in the device crate into actual
resources. That's why you have to assign ceilings in the `peripherals!` macro:
all resources must have a ceiling assigned to them.

If you run this program ([here][resource.rs]'s the full code) you'll get the
same behavior as the one shown in the intro video :tada:.

[resource.rs]: https://docs.rs/f3/0.4.1/f3/examples/_7_resource/index.html

So, are we done? Nope, not yet. Let's now spice things up with some ...

# Preemption

The `receive` task can now take much longer because it does parsing. In the
worst case scenario a new byte may arrive *just before* the (timer) update event
causing the `roulette` task to wait for *several* cycles until after the
`receive` task is finished. This deviation from true periodicity is known as
jitter. Although unlikely to be perceived in this particular application, jitter
can cause problems in more critical applications like control systems so let's
see how to address it.

To reduce jitter we can increase the priority of the `roulette` task to 2.
This way, if the previous scenario arises (update event right after the
`receive` task starts) the processor will stop executing the `receive` task, run
the `roulette` task and once it's done with that it will resume the execution of
the `receive` task.

So, let's just change the priority of the `roulette` task in the `tasks!` macro.

``` rust
tasks!(stm32f30x, {
    roulette: Task {
        interrupt: Tim7,
        priority: P2, // changed to `P2`
        enabled: true,
    },
    receive: Task {
        interrupt: Usart1Exti25,
        priority: P1,
        enabled: true,
    },
});
```

We'll have to update the signature of the `roulette` task accordingly as well as
fix some ceiling values:

``` rust
peripherals!(stm32f30x, {
    (..)
    TIM7: Peripheral {
        register_block: Tim7,
        ceiling: C2, // was `C1`
    },
    (..)
});

// the ceiling was `C1`
static SHARED: Resource<State, C2> = Resource::new(State::new());

fn roulette(mut task: Tim7, ref priority: P2, ref threshold: T2) {
    // same as before
}
```

And ...

```
error[E0277]: the trait bound `..` is not satisfied
   --> examples/data-race.rs:168:33
    |
168 |             let shared = SHARED.access(priority, threshold);
```

The program no longer compiles! And that's great because the Rust compiler just
caught a data race -- although I admit that the error message is awful. Here's a
better view of the source of the error:

``` rust
fn receive(mut task: Usart1Exti25, ref priority: P1, ref threshold: T1) {
    // ..

    if let Ok(byte) = serial.read() {
        // ..

        if byte == b'\r' {
            // end of command

            let shared = SHARED.access(priority, threshold);
            //~^ compiler error!

            // ..
```

What went wrong? When we increased the priority of the `roulette` task we made
preemption of the `receive` task possible -- that was the goal. The problem
with this is that both `roulette` and `receive` may modify the `SHARED`
resource, but this time *unsynchronized* mutation is possible: the `receive`
task could be performing a read-modify-write operation on the resource and get
preempted by the `roulette` task, which can do the same! This is a potential
data race so the compiler rejects the program.

How do we fix this? We have to add synchronization. More precisely, we must
ensure that no preemption occurs while the `receive` task is modifying the
`SHARED` resource. How do we that? We temporarily *raise* the preemption
threshold.

Let's refresh our memory: a preemption threshold of `T1` indicates that only a
task with a priority of 2 or higher can preempt the current context. That's the
preemption threshold of the `receive` task. With that threshold the `roulette`
task, which has a priority of 2, *can* preempt the `receive` task. If we could
*raise* that preemption level of the `receive` task to 2 (`T2`) then the
`roulette` wouldn't be able to preempt it.

`threshold` tokens have a `raise` method that does exactly that. This method
takes two arguments: the first one is a resource and second one is a closure.
This method will *temporarily* raise the preemption threshold of the task to
match the resource ceiling value and execute the closure under that raised
threshold condition. This is effectively a critical section for the duration of
the closure.

Let's put that in use. Here's the updated `receive` task:

``` rust
fn receive(mut task: Usart1Exti25, ref priority: P1, ref threshold: T1) {
    // ..

        if byte == b'\r' {
            // end of command

            match &**buffer {
                b"bounce" => {
                    threshold.raise(
                        &SHARED, |threshold| {
                            let shared = SHARED.access(priority, threshold);
                            shared.mode.set(Mode::Bounce)
                        }
                    );
                }
                b"continuous" => {
                    threshold.raise(
                        &SHARED, |threshold| {
                            let shared = SHARED.access(priority, threshold);
                            shared.mode.set(Mode::Continuous)
                        }
                    );
                }
                b"reverse" => {
                    threshold.raise(&SHARED, |threshold| {
                        let shared = SHARED.access(priority, threshold);
                        shared.direction.set(shared.direction.get().reverse());
                    });
                }
                _ => {}
            }

            buffer.clear();

            // ..
```

We use the `Threshold.raise` critical sections to perform updates of the
`SHARED` resource *atomically*. During these critical sections `roulette` can't
preempt the `receive` task so data races are impossible.

How would this program look from a scheduling point of view? See below:

![Preemption](/fearless-concurrency/preemption.svg)

Three scenarios are shown.

- The `roulette` task is being executed and an RX event arrives. Because the
  `receive` task has lower priority than the `roulette` task the `receive` task
  will be postponed until after the `roulette` task ends.

- The `receive` task is being executed and an update event arrives. Because the
  `roulette` task has higher priority than the `receive` task the `roulette`
  task will *preempt* the `receive` task. After the `roulette` task is finished
  the `receive` task will be *resumed*.

- The `receive` task is being executed. The parsing path is hit and the
  `SHARED` resource needs to be updated. The threshold of the `receive` task is
  temporarily raised while `SHARED` is being modified. During this critical
  section an update event arrives, but because the priority of the `roulette`
  task is the same as the current threshold no preemption occurs. Once the
  critical sections finishes and the threshold is lowered the `roulette` task
  immediately preempts the `receive` task. After the `roulette` task finishes
  the `receive` task is resumed.

That's the final version of the application! (full code [here][preemption.rs])
Let's leave coding aside and learn more about the ...

[preemption.rs]: https://docs.rs/f3/0.4.1/f3/examples/_8_preemption/index.html

# The ceiling system

I will now tell you all the rules of the ceiling system. Well, there's only one
rule actually:

> A task with priority `TP` can only `access` a resource with ceiling `RC` given
> a current preemption threshold `PT` if and only if `TP <= RC` AND `PT >= RC`.

But let's re-frame this rule into a practical guideline. It's usually the case
that you know what the priorities of your tasks are as these can be derived from
the deadline constraints of your application. Preemption thresholds are dynamic
due to the `raise` method, and their initial value is known once you know the
tasks priorities so no problem there either. The problem is computing the
ceiling of resources: if you get them wrong then you won't be able to use the
resources in the tasks that you want. So here's the rule of thumb for picking
ceilings:

> The ceiling of a resource should match the priority of the highest priority
> task that can access it

Example: If the resource R must be accessed by tasks A, B and C with priorities
`P2`, `P3` and `P1` respectively then you should set the ceiling of the
resource to `C3`.

You can flip the rule of thumb to answer the question "*who* can access this
resource?":

> A resource with ceiling CN can only be accessed by tasks with a priority of N
> or lower

After you have computed the resource ceilings the next question is: *How* do you
access the resource from the different tasks?

> From the set of tasks that can access a resource, the ones with priority equal
> to the resource ceiling can directly `access` it; the others will have to use
> a `Threshold.raise` critical section to access the resource.

Those are the guidelines for the general case.

What about extreme values? Remember that the minimum task priority is `P1`. From
this fact the following corollary arises:

> A resource with a ceiling `C0` can only be accessed by `idle` and `init`.

Due to how the hardware works you can't use `Threshold.raise` to raise the
threshold all the way to `TMax`. If you need a `TMax` token to access a `CMax`
resource then you'll have to use the `rtfm::atomic` [^atomic] function which is
a *global* critical section that disables all interrupts / tasks.

[^atomic]: `rtfm::atomic` *is* the `interrupt::free` function presented in the
    previous post but its signature has been tailored to the RTFM framework.

Talking about critical sections, `Threshold.raise` is ...

# Not your typical critical section

When people say critical section they usually mean turning off **all** the
interrupts. In RTFM, this would the equivalent of blocking every other task from
running. Although this approach ensures the atomicity of the routine that is
executed within the critical section, it introduces more task blocking than
necessary, which is bad from a scheduling perspective.

`Threshold.raise` does *not* do that. It only blocks tasks *that would cause a
data race*. Other higher priority tasks *can* preempt the `Threshold.raise`
closure and continue to make progress. The ceiling system will ensure that the
preemption of those tasks doesn't lead to data races.

Let me show you an example:

``` rust
static R1: Resource<(), C2> = Resource::new(());

fn t1(_task: Exti0, ref priority: P1, ref threshold: T1) {
    hprintln!("t1: start");

    // we need to raise the ceiling to access R1
    threshold.raise(&R1, |ceil| {
        let r1 = R1.access(priority, threshold);

        hprintln!("t1: before request");
        rtfm::request(t2);
        hprintln!("t1: after request");
    });
}

fn t2(_task: Exti1, priority: P3, ceiling: C3) {
    hprintln!("t2");
}
```

This prints:

``` console
t1: start
t1: before request
t2
t1: after request
```

`Threshold.raise` doesn't block *all* tasks. `t2`, which has greater priority
than `R1`'s ceiling can preempt that critical section.

"But wouldn't it be bad if `t2` accessed the resource `R1` after it has
preempted `t1`?". Yes, that would be bad BUT such program wouldn't compile.

If we change `t2` to look like this:

``` rust
fn t2(_task: Exti1, ref priority: P3, ref threshold: T3) {
    let r1 = R1.access(priority, threshold);
    //~^ error
}
```

You'll get a compiler error.

This follows from the ceiling rules: `t2` has priority `P3` so it can't access a
resource with ceiling `C2`; only tasks with a priority `P2` or lower can
access `R1`.

# Resources are NOT Mutexes

Although `Resource`s provide a form of mutual exclusion, they *can't* deadlock
like Mutexes do. This deadlock freedom is a consequence of the invariants that
hold in the tasks and resources system:

- Once a task has started it can always access to all its resources without
  having to wait / block / spin.
- A task won't *start* if the above condition can't be met.

These invariants are guaranteed by the ceiling system: Once a task has entered a
critical section to access a resource no other task can preempt the first one
to access the same resource.

Here's an example of how using Mutexes and threads can result in a deadlock:

``` rust
// MUTEXES
static X: Mutex<i32> = Mutex::new(0);
static Y: Mutex<i32> = Mutex::new(0);

// THREADS
fn a() {
    // ..

    let x = X.lock();

    // context switch -> B

    let y = Y.lock();

    *x += *y;

    // release the locks
    drop((x, y));

    // ..
}

fn b() {
    // ..

    let y = Y.lock();

    // blocks, context switch -> A
    let x = X.lock();

    *y += *x;

    // release the locks
    drop((x, y));

    // ..
}
```

Here we have a program with two threads and two mutexes where both threads have
to access both mutexes. Let's see how this program may deadlock:

- Let's suppose thread A runs first.
- At some point it locks the mutex X.
- Now suppose that A's time slice runs out just after locking X; the scheduler
  switches to thread B.
- Thread B runs, eventually locks the mutex Y, and then tries to lock mutex X.
- Since thread A is holding that mutex thread B has to block.
- With no other option the scheduler switches back to thread A.
- Thread A resumes execution and tries to lock mutex Y but it can't because
  thread B is holding it so it blocks too.

Now both threads are blocked, each one is waiting for the mutex that the other
thread holds and none can make progress. You got yourself a deadlock.

Now, let's see the equivalent program using tasks and resources:

``` rust
// RESOURCES
static X: Resource<Cell<i32>, C2> = Resource::new(Cell::new(0));
static Y: Resource<Cell<i32>, C2> = Resource::new(Cell::new(0));

// TASKS
tasks!(stm32f30x, {
    a: Task {
        interrupt: Tim6Dacunder,
        priority: P1,
        enabled: true,
    },
    b: Task {
        interrupt: Tim7,
        priority: P2,
        enabled: true,
    },
});

fn a(_task: Tim6Dacunder, ref priority: P1, ref threshold: T1) {
    // ..

    threshold.raise(&X, |threshold| {
        let x = X.access(priority, threshold);

        // <- Tim7 update event - task B is postponed

        let y = Y.access(priority, threshold);

        x.set(x.get() + y.get());
    });

    // task B preempts task A

    // ..
}

fn b(_task: Tim7, ref priority: P2, ref threshold: T2) {
    // ..

    let y = Y.access(priority, threshold);
    let x = X.access(priority, threshold);

    y.set(x.get() + y.get());

    // ..
}
```

Similar scenario: two tasks and two resources where both tasks must access both
resources. Here I give task B a higher priority so context switching can occur
midway A's execution.

Let's see how events would unfold in this case:

- Let's suppose task A runs first.
- To access X and Y task A must temporarily raise its preemption level to match
  the resources' ceilings. This creates a critical section.
- During this critical section an update event may arrive but, because of the
  critical section, task B will be postponed until after the critical section
  ends.
- As soon as A's critical section ends, B immediately preempts A and starts its
  execution.
- As B can't be preempted by A, due the differences in priorities, B can freely
  access the resources.

There you go: no deadlock. You can tweak the priorities, add more tasks, add
more resources and perform the same analysis but the conclusion will be the
same: no deadlock can occur.

You could carefully design your use of `Mutex`es and threads to avoid deadlocks.
In the above Mutex example locking X *before* Y in thread B would have
prevented the deadlock. However, this may not always be so obvious, and the
compiler will happily compile a program that deadlocks. On the other hand, with
tasks and resources you *never* have to worry about deadlocks. As long as you
use the ceiling system correctly -- and the compiler enforces this -- you simply
can't deadlock.

# Outro

Wow, that was a lot of stuff. We just did *totally memory safe* multitasking. No
`unsafe`, no deadlocks, and the compiler detected data races at compile time.
All this on a single core microcontroller without relying on a garbage
collector, dynamic memory collector or operating system.

The best part: this is just the beginning of the RTFM framework.

There's a bunch of stuff in the pipeline:

- More synchronization primitives like readers-writer resources and channels.
- Offset based timing semantics backed by a device agnostic implementation,
  offering task chaining with periodic as well as arbitrary timing patterns.
  Leaving all device specific timers free to use for application purposes.
- Possibly these *Concurrent Reactive Objects* prof. Lindgren keeps telling me
  about.

Longer term work will likely involve:

- Tooling for Worst Case Execution Time (WCET) analysis.
- Tooling for scheduling analysis.
- Exploring building a DSL as a compiler plugin to remove the burden of
  computing ceiling values from the user -- those values can be derived using
  whole program static analysis.

If you have a Cortex-M microcontroller around please give the RTFM framework a
try! We'd love to hear what you think of it.

In the next post I'll analyze the overhead of the RTFM framework. Both the
runtime overhead of `Threshold.raise` and switching tasks as well as the memory
overhead of adding tasks and of using the `Resource` abstraction. I'll leave you
with this:

``` console
$ arm-none-eabi-size preemption
   text    data     bss     dec     hex filename
   1978       2      21    2001     7d1 preemption
```

The size of the final version of this post's application.

---

__Thank you patrons! :heart:__

I want to wholeheartedly thank [Iban Eguia], [Aaron Turon], [Geoff Cant] and 8
more people for [supporting my work on Patreon][Patreon].

[Iban Eguia]: https://github.com/Razican
[Aaron Turon]: https://github.com/aturon
[Geoff Cant]: https://github.com/archaelus

---

Let's discuss on [reddit].

[reddit]: https://www.reddit.com/r/rust/comments/6a5p9o/eir_fearless_concurrency_in_your_microcontroller/

Enjoyed this post? Like my work on embedded stuff? Consider supporting my work
on [Patreon]!

[Patreon]: https://goo.gl/5yNZDa

Follow me on [twitter] for even more embedded stuff.

[twitter]: https://twitter.com/japaricious

The embedded Rust community gathers on the #rust-embedded IRC channel
(irc.mozilla.org). Join us!
