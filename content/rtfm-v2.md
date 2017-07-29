+++
author = "Jorge Aparicio"
date = "2017-07-29T02:39:45-05:00"
tags = ["ARM Cortex-m", "concurrency", "RTFM"]
title = "RTFM v2: simpler, less overhead and more device support"
+++

Hiya folks! It's been a while. Today I'm pleased to present the next version of
the [Real Time For the Masses] framework: `cortex-m-rtfm` v0.2.0 or just v2,
which is how I like to call it.

[Real Time For the Masses]: /fearless-concurrency

Here's the executive summary of the changes:

- v2 is simpler. v1 used a bunch of tokens -- ceiling tokens, priority tokens,
  preemption threshold tokens and task tokens -- for memory safety; this made
  the API rather boilerplatery. Now most of the tokens as well as the
  boilerplate are gone. Porting applications from v1 to v2 should see a
  reduction of about 10 to 30% in lines of code.

- v2 has even less overhead. A long standing [issue] with the borrow checker
  that required   using `Cell` or `RefCell` as a workaround has been fixed.
  Making the `Resource` abstraction truly zero cost.

[issue]: /rtfm-overhead/#a-nonzero-cost-pattern

- v2 fully supports Cortex-M0(+) devices. Now all the Cortex-M devices have the
  same level of support in `cortex-m-rtfm`. Not only that but there's also a
  [port] of this version of RTFM for the MSP430 architecture -- with the exact
  same API.

[port]: https://github.com/japaric/msp430-rtfm

# The new API

Let's dig into the new API by porting some of applications I showed to you in
the [introduction post] of RTFM.

[introduction post]: /fearless-concurrency/#hello-world-again

All the examples shown here target the ["Blue Pill"] development board.

["Blue Pill"]: http://wiki.stm32duino.com/index.php?title=Blue_Pill

## Hello world

This is the simplest RTFM application: it has no tasks.

``` rust
#![feature(proc_macro)] // <- IMPORTANT! Feature gate for procedural macros
#![no_std]

// git = "https://github.com/japaric/blue-pill", rev = "2b7d5c56b25f4efad6c7c40042f884cbecb47c0b"
extern crate blue_pill;

// version = "0.2.0"
extern crate cortex_m_rtfm as rtfm; // <- this rename is required

// version = "0.2.0"
extern crate cortex_m_semihosting as semihosting;

use core::fmt::Write;

use rtfm::app; // <- this is a procedural macro
use semihosting::hio;

// This macro expands into the `main` function
app! {
    // this is a path to a _device_ crate, a crate generated using svd2rust
    device: blue_pill::stm32f103xx,
}

// INITIALIZATION
fn init(_p: init::Peripherals) {
    // Nothing to initialize in this example ...
}

// IDLE LOOP
fn idle() -> ! {
    writeln!(hio::hstdout().unwrap(), "Hello, world!").unwrap();

    // Go to sleep
    loop {
        rtfm::wfi();
    }
}
```

The most notable change is that the [`tasks!`] macro is gone and has been
replaced with a procedural macro: [`app!`]. Procedural macros are the next
iteration of the Rust macro / plugin system and are not yet stable so a feature
gate is required. Don't forget to include it! Or you'll get some rather obscure
errors. Procedural macros are imported into scope using the normal `use`
mechanism, as if they were functions.

[`app!`]: https://docs.rs/cortex-m-rtfm-macros/0.2.0/cortex_m_rtfm_macros/fn.app.html
[`tasks!`]: https://docs.rs/cortex-m-rtfm/0.1.1/cortex_m_rtfm/macro.tasks.html

Like the old `tasks!` macro the `app!` macro expects a path to the device crate
as an argument. However, the `app!` macro uses this `key: value` syntax so the
path must be supplied as the value of the `device` key.

`app!` will expand into a `main` function that will call `init` and then `idle`,
as it did in the previous version. If you didn't know, you can see what macros
expand to using the [cargo-expand] subcommand. Here's the expansion of the
`app!` macro used in the previous program:

[cargo-expand]: https://crates.io/crates/cargo-expand

``` console
$ xargo expand
```

``` rust
// ..

mod init {
    pub use blue_pill::stm32f103xx::Peripherals;
}

fn main() {
    let init: fn(stm32f103xx::Peripherals) = init;

    rtfm::atomic(unsafe { &mut rtfm::Threshold::new(0) }, |_t| unsafe {
        init(stm32f103xx::Peripherals::all());
    });

    let idle: fn() -> ! = idle;

    idle();
}

// ..
```

As you can see above the `init` function runs within a *global* critical section
and can't be preempted during its execution. For that reason it has *full
access* to all the peripherals of the device in the form of the
`init::Peripherals` argument. In the previous version of RTFM you had to
explicitly declare all the peripherals you were going to use in your application
as *resources*, as a bunch of `static` variables. None of that boilerplate is
required in this version.

## Serial loopback

Next let's port the [serial loopback application] from v1 to v2. Here's the full
code:

[serial loopback application]: /fearless-concurrency/#serial-loopback

``` rust
#![feature(proc_macro)]
#![no_std]

extern crate blue_pill;
extern crate cortex_m_rtfm as rtfm;

use blue_pill::Serial;
use blue_pill::prelude::*;
use blue_pill::serial::Event;
use blue_pill::time::Hertz;
use rtfm::{app, Threshold};

const BAUD_RATE: Hertz = Hertz(115_200);

app! {
    device: blue_pill::stm32f103xx,

    tasks: {
        // this "USART1" refers to the interrupt
        USART1: {
            path: loopback,

            // this "USART1" refers to the peripheral
            resources: [USART1],
        },
    },
}

fn init(p: init::Peripherals) {
    let serial = Serial(p.USART1);

    serial.init(BAUD_RATE.invert(), p.AFIO, None, p.GPIOA, p.RCC);

    // RXNE event = a new byte of data has arrived
    serial.listen(Event::Rxne);
}

fn idle() -> ! {
    // Sleep
    loop {
        rtfm::wfi();
    }
}

fn loopback(_t: &mut Threshold, r: USART1::Resources) {
    let serial = Serial(&**r.USART1);

    // grab the byte we just received
    let byte = serial.read().unwrap();

    // and send it back
    serial.write(byte).unwrap();
}
```

Here we re-introduce the concept of tasks. A task is effectively a response to
some (external) event in the form of a handler / callback function. In this case
the only event the application will respond to is the arrival of new data
through the serial interface. And the response to that event, the `loopback`
function, is to send back the received data through the serial interface.

This program initializes the serial interface in `init` and then goes to sleep
in `idle`. But whenever a new byte of data arrives through the serial interface
it will temporarily wake up to execute the `loopback` handler; then it will go
back to sleep. In more detail: the new data *event* causes the `loopback` task
to become *pending*. As the `loopback` task has higher priority than the `idle`
loop (all tasks have higher priority than `idle`) the scheduler will suspend
`idle` to execute the `loopback` task -- this is known as preemption. Once the
task is completed `idle` is resumed; this sends the processor back to sleep.

Code wise tasks are *declared* in the `app!` macro. As each task is associated
to an interrupt (interrupts are a hardware mechanism for preemption) they are
declared using the name of the interrupt -- `USART1` in this case. The task
declaration must include: the `path` to the task handler and which `resources`
the task has access to. The resources can be peripherals or plain data (`static`
variables).

This last part, the `resources` array, is the most important change since v1. In
v1 resources had global visibility and the user had to assign them a *ceiling*
to make them safe to share between tasks. This was not optimal: although it was
impossible to pick a ceiling that would break memory safety it was possible to
pick a ceiling that imposed more critical sections, and thus more runtime
overhead, than strictly necessary for memory safety.

In v2 you assign resources to tasks and the optimal ceilings are computed
*automatically* so the number of critical sections is minimized without user
effort. Memory safety, in v2, is obtained by limiting *where* the resource is
visible (that is its scope), so resources no longer have global visibility.
Dropping global visibility eliminated the need for most of the tokens needed in
v1.

In this particular program the `loopback` task needs access to the `USART1`
peripheral so `USART1` is declared as its resource. As no other task, or the
idle loop, has access the same resource the `loopback` task ends up having
*exclusive access* to the `USART1` resource, that is a mutable reference
(`&mut-`) to the peripheral. This mutable reference is packed in the
`USART1::Resources` argument.

## Blinky

Now let's port the classic "blinky" application to v2. The v1 version is [here].

[here]: /fearless-concurrency/#a-blinking-task

``` rust
#![feature(proc_macro)]
#![no_std]

extern crate blue_pill;
extern crate cortex_m;
extern crate cortex_m_rtfm as rtfm;

use blue_pill::led::{self, Green};
use cortex_m::peripheral::SystClkSource;
use rtfm::{app, Threshold};

app! {
    device: blue_pill::stm32f103xx,

    resources: {
        static ON: bool = false;
    },

    tasks: {
        SYS_TICK: {
            path: toggle,
            resources: [ON],
        },
    },
}

fn init(p: init::Peripherals, _r: init::Resources) {
    led::init(p.GPIOC, p.RCC);

    // Configure the system timer to generate periodic events at 1 Hz rate
    p.SYST.set_clock_source(SystClkSource::Core);
    p.SYST.set_reload(8_000_000); // Period = 1s
    p.SYST.enable_interrupt();
    p.SYST.enable_counter();
}

fn idle() -> ! {
    // Sleep
    loop {
        rtfm::wfi();
    }
}

// TASKS

// Toggle the state of the LED
fn toggle(_t: &mut Threshold, r: SYS_TICK::Resources) {
    **r.ON = !**r.ON;

    if **r.ON {
        Green.on();
    } else {
        Green.off();
    }
}
```

Again we have a single task and that task has only one resource. However, this
time the resource is not a peripheral but plain data. The `ON` variable tracks
whether the LED is on or off.

Data resources must be declared and initialized in the `resources` key of the
`app!` macro. Declaration of data resources looks exactly like the declaration
of `static` variables.

Like in the previous program the `toggle` task is the only "owner" of the `ON`
resource so it has exclusive access (`&mut-`) to it.

If you were wondering "what's up with the double dereference (`**`) in the
`toggle` function?" that's required becaused the type of `r.ON` is `&mut
Static<bool>` instead of `&mut bool`; both are semantically equal because
`Static` is just a newtype. The `Static` newtype comes in handy when dealing
with DMA based APIs and code that deals with resources in a generic fashion.

One extra thing to note here is that we are using the `SYS_TICK` exception,
which is available to all Cortex-M microcontrollers, as a task instead of a
device specific interrupt like `TIM2`. This is something new in v2; v1 didn't
support these Cortex-M exceptions.

If you are a careful observer then you probably noticed that the signature of
the `init` function changed in this program: it now includes a `init::Resources`
argument. This argument is a collection of all the data resources declared in
`app!`. Basically the `init` function has exclusive access (`&mut-`) to all the
data resources; this can be used to initialize resources at runtime.

## Concurrency

In the next example we'll merge the previous loopback and blinky programs into
one. The resulting program will run the two tasks *concurrently*. As there's no
data sharing because each task uses different resources merging the two programs
is straightforward. Here's the full code:

``` rust
#![feature(proc_macro)]
#![no_std]

extern crate blue_pill;
extern crate cortex_m;
extern crate cortex_m_rtfm as rtfm;

use blue_pill::Serial;
use blue_pill::led::{self, Green};
use blue_pill::prelude::*;
use blue_pill::serial::Event;
use blue_pill::time::Hertz;
use cortex_m::peripheral::SystClkSource;
use rtfm::{app, Threshold};

const BAUD_RATE: Hertz = Hertz(115_200);

app! {
    device: blue_pill::stm32f103xx,

    resources: {
        static ON: bool = false;
    },

    // There are now two tasks!
    tasks: {
        SYS_TICK: {
            path: toggle,
            resources: [ON],
        },

        USART1: {
            path: loopback,
            resources: [USART1],
        },
    },
}

// The new `init` is the fusion of the other two programs' `init` functions
fn init(p: init::Peripherals, _r: init::Resources) {
    let serial = Serial(p.USART1);

    led::init(p.GPIOC, p.RCC);

    serial.init(BAUD_RATE.invert(), p.AFIO, None, p.GPIOA, p.RCC);
    serial.listen(Event::Rxne);

    p.SYST.set_clock_source(SystClkSource::Core);
    p.SYST.set_reload(8_000_000); // 1s
    p.SYST.enable_interrupt();
    p.SYST.enable_counter();
}

fn idle() -> ! {
    loop {
        rtfm::wfi();
    }
}

// TASKS

// Task code is unchanged
fn loopback(_t: &mut Threshold, r: USART1::Resources) {
    let serial = Serial(&**r.USART1);

    let byte = serial.read().unwrap();
    serial.write(byte).unwrap();
}

// Task code is unchanged
fn toggle(_t: &mut Threshold, r: SYS_TICK::Resources) {
    **r.ON = !**r.ON;

    if **r.ON {
        Green.on();
    } else {
        Green.off();
    }
}
```

## Sharing data

Now let's see what happens if both tasks need to modify the same resource. Let's
say we want to count the number of context switches, which is the number of
times the processor wakes up to run a task, for performance tracking purposes.
For simplicity, we'll omit the part that logs the performance metrics. The
required changes are shown below:

``` rust
app! {
    device: blue_pill::stm32f103xx,

    resources: {
        static CONTEXT_SWITCHES: u32 = 0; // <- NEW!
        static ON: bool = false;
    },

    tasks: {
        SYS_TICK: {
            path: toggle,
            resources: [CONTEXT_SWITCHES, ON], // <- NEW!
        },

        USART1: {
            path: loopback,
            resources: [CONTEXT_SWITCHES, USART1], // <- NEW!
        },
    },
}

// TASKS
fn loopback(r: USART1::Resources) {
    **r.CONTEXT_SWITCHES += 1; // <- NEW!

    // .. same code as before ..
}

fn toggle(r: SYS_TICK::Resources) {
    **r.CONTEXT_SWITCHES += 1; // <- NEW!

    // .. same code as before ..

    // .. some code that logs `CONTEXT_SWITCHES` and resets its value to 0 ..
}
```

Another straightforward change but only because both tasks are operating at the
*same* priority so one task can only start if the other one is not running. This
means that no data race is possible so each task has exclusive access (`&mut-`)
to the `CONTEXT_SWITCHES` resource *in turns*.

## Preemption

RTFM supports prioritization of tasks. As I mentioned before when a higher
priority task becomes pending the scheduler suspends the current task to run the
higher priority task to completion. If not specified in the `app!` macro all
tasks default to a priority of 1, which is the lowest priority a task can have.
`idle`, on the other hand, has a priority of 0.

Let's suppose we now want to increase the priority of the `loopback` task
because the incoming data throughput has increased and waiting for the `toggle`
task to end before we can service `loopback` may cause data loss.

If we go ahead and simply increase the priority of the `loopback` to 2 in the
previous program it will no longer compile:

``` rust
app! {
    device: blue_pill::stm32f103xx,

    resources: {
        static CONTEXT_SWITCHES: u32 = 0;
        static ON: bool = false;
    },

    tasks: {
        SYS_TICK: {
            path: toggle,
            priority: 1, // <- this can be omitted, but let's be explicit for clarity
            resources: [CONTEXT_SWITCHES, ON],
        },

        USART1: {
            path: loopback,
            priority: 2, // <- priority increased
            resources: [CONTEXT_SWITCHES, USART1],
        },
    },
}

// ..
```

``` console
$ xargo build
error[E0614]: type `_resource::CONTEXT_SWITCHES` cannot be dereferenced
  --> examples/sharing.rs:75:6
   |
75 |     **r.CONTEXT_SWITCHES += 1;
   |      ^^^^^^^^^^^^^^^^^^^

error: aborting due to previous error
```

The code around line 75 is this one:

``` rust
fn toggle(r: SYS_TICK::Resources) {
    **r.CONTEXT_SWITCHES += 1;

    // .. same code as before ..
}
```

So the `toggle` task can no longer *directly* access the `CONTEXT_SWITCHES`
resource data. Good! This compile error just prevented a data race: with the
priority change `loopback` can now preempt the `toggle` task; since
incrementing `CONTEXT_SWITCHES` is *not* performed in a single instruction but
as a Read Modify Write (RMW) operation the two RMW operations, the one in
`loopback` and one in `toggle`, can now race and that can result in data loss as
shown below:

``` console
start:    CONTEXT_SWITCHES == 1

toggle:   let mut register = CONTEXT_SWITCHES.read(); // register = 1
toggle:   register += 1;                              // register = 2

~ interrupt start ~

loopback: let mut register = CONTEXT_SWITCHES.read(); // register = 1
loopback: register += 1;                              // register = 2
loopback: CONTEXT_SWITCHES.store(register);           // CONTEXT_SWITCHES = 2
..

~ interrupt end ~

toggle:   CONTEXT_SWITCHES.store(register);           // CONTEXT_SWITCHES = 2
..

end:      CONTEXT_SWITCHES == 2                       // should have been 3!
```

Which doesn't seem *too* bad, but if either task was performing a more complex
operation on `CONTEXT_SWITCHES` this data race could have resulted in Undefined
Behavior (UB) due to compiler misoptimizations.

To eliminate this data race we have to use critical section: enter [`claim` and
`claim_mut`].

[`claim` and `claim_mut`]: https://docs.rs/cortex-m-rtfm/0.2.1/cortex_m_rtfm/trait.Resource.html

``` rust
fn toggle(t: &mut Threshold, mut r: SYS_TICK::Resources) {
    use rtfm::Resource; // <- trait that provides the `claim{,_mut}` method

    r.CONTEXT_SWITCHES.claim_mut(t, |context_switches, _t| {
        // Inside a critical section
        **context_switches += 1;
    });

    // ..
}
```

`claim_mut` creates a critical section and only within this critical section can
the resource data be read and modified. This critical section makes the RMW
operation on `CONTEXT_SWITCHES` uninterruptible by the `loopback` task. Now the
concurrent RMW operations can't overlap and the possibility of data races has
been eliminated.

That's pretty much it for the core of the new API. As usual you can check out
the API documentation on [docs.rs].

[docs.rs]: https://docs.rs/cortex-m-rtfm/0.2.1/cortex_m_rtfm/

# Critical sections and `Threshold`

I think this is good time to tell you, or remind you, that RTFM has *two*
flavors of critical sections: global ones and non-global ones. The non-global
ones are the ones you get when you use `claim` and `claim_mut`; these critical
sections prevent *some* tasks from preempting the current one whereas *global*
critical sections prevent *all* tasks from starting.

As a rule of thumb you should only use non global critical sections unless you
really need a global critical section. Non global critical sections impose less
task blocking so are they better from a real time scheduling point of view.

Here's a contrived example that showcases the two types of critical sections:

``` rust
#![feature(proc_macro)]
#![no_std]

extern crate blue_pill;
extern crate cortex_m;
extern crate cortex_m_rtfm as rtfm;

use blue_pill::stm32f103xx::Interrupt;
use rtfm::{app, Resource, Threshold};

app! {
    device: blue_pill::stm32f103xx,

    resources: {
        static R1: bool = false;
    },

    tasks: {
        EXTI0: {
            path: exti0,
            priority: 1,
            resources: [R1],
        },

        EXTI1: {
            path: exti1,
            priority: 2,
            resources: [R1],
        },

        EXTI2: {
            path: exti2,
            priority: 3,
        },
    },
}

fn init(_p: init::Peripherals, _r: init::Resources) {}

fn idle() -> ! {
    loop {
        rtfm::wfi();
    }
}

fn exti0(t: &mut Threshold, r: EXTI0::Resources) {
    // Threshold == 1

    rtfm::set_pending(Interrupt::EXTI1); // ~> exti1

    // non-global critical section
    r.R1.claim(t, |_r1, _t| {
        // Threshold = 2
        rtfm::set_pending(Interrupt::EXTI1);

        rtfm::set_pending(Interrupt::EXTI2); // ~> exti2
    }); // Threshold = 1

    // ~> exti1

    // global critical section
    rtfm::atomic(t, |t| {
        // Threshold = MAX
        let _r1 = r.R1.borrow(t);

        rtfm::set_pending(Interrupt::EXTI1);

        rtfm::set_pending(Interrupt::EXTI2);
    }); // Threshold = 1

    // ~> exti2, exti1
}

fn exti1(_r: EXTI1::Resources) {
    // .. modify R1 ..
}

fn exti2() {
    // ..
}
```

In `exti0` the data of R1 is accessed using a non global critical section and
then again using a global critical section. Both critical sections contain
pretty much the same code but behave differently. Let's see why:

But first let's define what `Threshold` is -- I have been ignoring it for a
while now. `Threshold` is a *token* that keeps track of the current *preemption
threshold*. This threshold indicates what priority a task must have to be able
to preempt the current task. A threshold of 1 means that a task must have *at
least* a priority of 2 to preempt the current task.

Now let's go back to the program analysis:

Because the priority of `exti0` is 1 the preemption threshold, tracked by the
token `t`, starts at a value of 1. At the start of `exti0` we set the task
`EXTI1` as [pending]. Because `EXTI1` has a priority of 2, which is greater than
the current preemption threshold of 1, it will be executed immediately.

[pending]: https://docs.rs/cortex-m-rtfm/0.2.1/cortex_m_rtfm/fn.set_pending.html

Then we `claim` the resource `R1`; this creates a critical section by increasing
the preemption threshold, now tracked by `_t`, to 2. Within this critical
section the data of the resource `R1` can be read through the `_r1` reference.
Then, within the critical section, we set the task `EXTI1` as pending; however,
the task won't be executed immediately because its priority, 2, is equal to the
current preemption threshold of 2. Then we set the task `EXTI2` as pending; this
time the task will be serviced immediately because its priority, 3, is higher
than the current threshold of 2.

Once the `claim` ends the threshold is restored to its previous value of 1. Now
the task `EXTI1` can again preempt the current task so it gets executed.

Then we have `rtfm::atomic`, a *global* critical section. Within this critical
section we can access the data of the resource `R1` using the [`borrow`] method.
A global critical section effectively raises the preemption threshold to its
maximum possible value so *no task* can preempt it. Within this critical section
we set the tasks `EXTI1` and `EXTI2` as pending, but none of them can run
because of the threshold value.

[`borrow`]: https://docs.rs/cortex-m-rtfm/0.2.1/cortex_m_rtfm/trait.Resource.html#tymethod.borrow

Once `rtfm::atomic` ends the preemption threshold is restored to its previous
value of 1. Now the tasks can be serviced: `EXTI2` is serviced first, because of
its higher priority, then `EXTI1` is serviced.

# Performance

I wrote a [blog post] where I analyzed the runtime cost of the primitives provided
by RTFM v1. Those numbers mostly hold for v2 with the difference that `claim`
and `claim_mut` are equivalent to v1's `Threshold.raise` but only when the
threshold *needs* to be raised; when the threshold doesn't need to be raised
`claim` and `claim_mut` are no-ops. To elaborate with an example:

[blog post]: /rtfm-overhead

This single claim

``` rust
app! {
    // ..

    tasks: {
        EXTI0: {
            path: exti0,
            priority: 1,
            resources: [R1],
        },

        EXTI1: {
            path: exti1,
            priority: 2,
            resources: [R1],
        },
    },
}

fn exti0(t: &mut Threshold, r: EXTI0::Resources) {
    r.R1.claim(t, |_r1, _t| {
        asm::nop();
    });
}
```

produces this machine code

``` armasm
08000196 <EXTI0>:
 8000196:       f3ef 8011       mrs     r0, BASEPRI
 800019a:       21e0            movs    r1, #224        ; 0xe0
 800019c:       f381 8812       msr     BASEPRI, r1     ; enter
 80001a0:       bf00            nop
 80001a2:       f380 8811       msr     BASEPRI, r0     ; exit
 80001a6:       4770            bx      lr
```

Whereas this nested claim

``` rust
app! {
    // ..

    tasks: {
        EXTI0: {
            path: exti0,
            priority: 1,
            resources: [R1, R2],
        },

        EXTI1: {
            path: exti1,
            priority: 2,
            resources: [R1, R2],
        },
    },
}

fn exti0(t: &mut Threshold, r: EXTI0::Resources) {
    r.R1.claim(t, |_r1, t| {
        asm::nop();

        r.R2.claim(t, |_r2, _t| {
            asm::nop();
        });

        asm::nop();
    });
}
```

produces this machine code

``` armasm
08000196 <EXTI0>:
 8000196:       f3ef 8011       mrs     r0, BASEPRI
 800019a:       21e0            movs    r1, #224        ; 0xe0
 800019c:       f381 8812       msr     BASEPRI, r1     ; enter
 80001a0:       bf00            nop
 80001a2:       bf00            nop
 80001a4:       bf00            nop
 80001a6:       f380 8811       msr     BASEPRI, r0     ; exit
 80001aa:       4770            bx      lr
```

The inner claim is a no-op here because the threshold doesn't need to be raised
again to achieve memory safety.

On the other hand, this similarly looking nested claim

```
app! {
    // ..

    tasks: {
        EXTI0: {
            path: exti0,
            priority: 1,
            resources: [R1, R2],
        },

        EXTI1: {
            path: exti1,
            priority: 2,
            resources: [R1],
        },

        EXTI2: {
            path: exti2,
            priority: 3,
            resources: [R2],
        },
    },
}

fn exti0(t: &mut Threshold, r: EXTI0::Resources) {
    r.R1.claim(t, |_r1, t| {
        asm::nop();

        r.R2.claim(t, |_r2, _t| {
            asm::nop();
        });

        asm::nop();
    });
}
```

does result in two nested critical sections

``` armasm
08000196 <EXTI0>:
 8000196:       21e0            movs    r1, #224        ; 0xe0
 8000198:       f3ef 8011       mrs     r0, BASEPRI
 800019c:       22d0            movs    r2, #208        ; 0xd0
 800019e:       f381 8812       msr     BASEPRI, r1     ; enter outer
 80001a2:       bf00            nop
 80001a4:       f3ef 8111       mrs     r1, BASEPRI
 80001a8:       f382 8812       msr     BASEPRI, r2     ; enter inner
 80001ac:       bf00            nop
 80001ae:       f381 8811       msr     BASEPRI, r1     ; exit inner
 80001b2:       bf00            nop
 80001b4:       f380 8811       msr     BASEPRI, r0     ; exit outer
 80001b8:       4770            bx      lr
```

because they are required for memory safety in this case.

## `rtfm::atomic`

The overhead of `rtfm::atomic` has also been reduced. This critical section
works by temporarily disabling interrupts. In v1, `rtfm::atomic` checked at
runtime (by reading the `PRIMASK` register) if interrupts were disabled before
executing the closure to prevent enabling the interrupts after executing the
closure. This check is not necessary in v2 because the signature of
`rtfm::atomic` has changed to take the `Threshold` token, which contains
information about the state of interrupts, so whether the interrupts are enabled
or not is now known at compile time.

This code

``` rust
fn exti0(t: &mut Threshold, r: EXTI0::Resources) {
    rtfm::bkpt();

    rtfm::atomic(t, |_t| {});

    rtfm::bkpt();
}
```

now produces this machine code

``` armasm
08000198 <EXTI0>:
 8000198:       be00            bkpt    0x0000
 800019a:       b672            cpsid   i
 800019c:       b662            cpsie   i
 800019e:       be00            bkpt    0x0000
 80001a0:       4770            bx      lr
```

The runtime overhead of v2's `rtfm::atomic` is 3 cycles, down from [the 6 cycles
of v1].

[the 6 cycles of v1]: /rtfm-overhead/#vs-rtfm-atomic

If nested the inner `rtfm::atomic` become a no-op. For example, this

``` rust
fn exti0(t: &mut Threshold, r: EXTI0::Resources) {
    rtfm::atomic(t, |t| {
        asm::nop();

        rtfm::atomic(t, |_t| {
            asm::nop();
        });

        asm::nop();
    });
}
```

produces this:

``` armasm
08000196 <EXTI0>:
 8000196:       b672            cpsid   i
 8000198:       bf00            nop
 800019a:       bf00            nop
 800019c:       bf00            nop
 800019e:       b662            cpsie   i
 80001a0:       4770            bx      lr
```

## Zero cost mutation

The area where v2 does much better than v1, in terms of performance, is mutation
of non primitive types. In v1 you could only get a shared reference (`&-`), to
the resource data. This meant that you had to use a `Cell` or a `RefCell` to
mutate the data; these two abstractions have overhead compared to a plain
mutable reference (`&mut-`). In v2 you can get a mutable reference to the data
with no extra overhead.

Here's some [code that didn't compile in v1][] (without the help of `Cell` /
`RefCell`).

[code that didn't compile in v1]: /rtfm-overhead/#access-mut

``` rust
app! {
    device: blue_pill::stm32f103xx,

    resources: {
        static A: i32 = 0;
        static B: i32 = 0;
    },

    tasks: {
        EXTI0: {
            path: exti0,
            priority: 1,
            resources: [A, B],
        },

        EXTI1: {
            path: exti1,
            priority: 2,
            resources: [A, B],
        },
    },
}

// higher priority task
fn exti1(t: &mut Threshold, r: EXTI1::Resources) {
    **r.A += 1;
    **r.B += 2;

    mem::swap(r.A, r.B);
}

// lower priority task
fn exti0(
    t: &mut Threshold,
    EXTI0::Resources { mut A, mut B }: EXTI0::Resources,
) {
    A.claim_mut(t, |a, _| **a += 1);
    B.claim_mut(t, |b, _| **b += 2);

    A.claim_mut(t, |a, t| {
        B.claim_mut(t, |b, _| {
            mem::swap(a, b);
        });
    });
}
```

The above code produces this machine code:

``` armasm
08000196 <EXTI1>:
 8000196:       f240 0000       movw    r0, #0
 800019a:       f2c2 0000       movt    r0, #8192       ; 0x2000
 800019e:       e9d0 1200       ldrd    r1, r2, [r0]
 80001a2:       3202            adds    r2, #2
 80001a4:       3101            adds    r1, #1
 80001a6:       e9c0 2100       strd    r2, r1, [r0]
 80001aa:       4770            bx      lr

080001ac <EXTI0>:
 80001ac:       f240 0200       movw    r2, #0
 80001b0:       21e0            movs    r1, #224        ; 0xe0
 80001b2:       f3ef 8011       mrs     r0, BASEPRI
 80001b6:       f381 8811       msr     BASEPRI, r1     ; enter I
 80001ba:       f2c2 0200       movt    r2, #8192       ; 0x2000
 80001be:       6813            ldr     r3, [r2, #0]
 80001c0:       3301            adds    r3, #1
 80001c2:       6013            str     r3, [r2, #0]
 80001c4:       f380 8811       msr     BASEPRI, r0     ; leave I
 80001c8:       f3ef 8011       mrs     r0, BASEPRI
 80001cc:       f381 8811       msr     BASEPRI, r1     ; enter II
 80001d0:       6853            ldr     r3, [r2, #4]
 80001d2:       3302            adds    r3, #2
 80001d4:       6053            str     r3, [r2, #4]
 80001d6:       f380 8811       msr     BASEPRI, r0     ; leave II
 80001da:       f3ef 8011       mrs     r0, BASEPRI
 80001de:       f381 8811       msr     BASEPRI, r1     ; enter III
 80001e2:       e9d2 1300       ldrd    r1, r3, [r2]
 80001e6:       e9c2 3100       strd    r3, r1, [r2]
 80001ea:       f380 8811       msr     BASEPRI, r0     ; leave III
 80001ee:       4770            bx      lr
```

# Outro

That's it for this post. I hope that you agree with me that the new system is
simpler. Please give it a try and let me know what you think! If you need more
convincing here are some open source applications that are using RTFM v2:

- Cortex-M
  - [`2wd`], a remotely controlled wheeled robot
  - [`blue-pill`], bunch of example apps for the Blue Pill development board
  - [`ws2812b`], WS2812B LED ring controlled via a serial interface


- MSP430
  - [`AT2XT`], AT to XT Keyboard Protocol Converter

[`2wd`]: https://github.com/japaric/2wd
[`AT2XT`]: https://github.com/cr1901/AT2XT/
[`blue-pill`]: https://github.com/japaric/blue-pill
[`ws2812b`]: https://github.com/japaric/ws2812b

And of course there are always [new features] in the pipeline.

[new features]: https://github.com/japaric/cortex-m-rtfm/milestone/1

---

__Thank you patrons! :heart:__

I want to wholeheartedly thank:

<p style="text-align:center">
  <a href="http://www.sharebrained.com/" style="border-bottom:0px">
    <img alt="ShareBrained Technology" src="/logo/sharebrained.png" width="200"/>
  </a>
</p>

[Iban Eguia], [Aaron Turon], [Geoff Cant], [Harrison Chin], [Brandon Edens],
[whitequark], [J. Ryan Stinnett], [James Munns] and 27 more people
for [supporting my work on Patreon][Patreon].

[Iban Eguia]: https://github.com/Razican
[Aaron Turon]: https://github.com/aturon
[Geoff Cant]: https://github.com/archaelus
[Harrison Chin]: http://www.harrisonchin.com/
[Brandon Edens]: https://github.com/brandonedens
[whitequark]: https://github.com/whitequark
[J. Ryan Stinnett]: https://convolv.es/
[James Munns]: https://jamesmunns.com/

---

Let's discuss on [reddit].

[reddit]: https://www.reddit.com/r/rust/comments/6q9s76/rtfm_v2_simpler_less_overhead_and_more_device/

Enjoyed this post? Like my work on embedded stuff? Consider supporting my work
on [Patreon]!

[Patreon]: https://goo.gl/ijwc0z

Follow me on [twitter] for even more embedded stuff.

[twitter]: https://twitter.com/japaricious

The embedded Rust community gathers on the #rust-embedded IRC channel
(irc.mozilla.org). Join us!
