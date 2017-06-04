+++
author = "Jorge Aparicio"
date = "2017-06-04T14:08:14-05:00"
draft = false
tags = ["ARM Cortex-M", "performance", "recipe", "rtfm"]
title = "A CPU usage monitor for the RTFM framework"
+++

We have used [the RTFM framework] in the previous posts but put most of the
application logic in tasks, and always sent the processor to sleep in the `idle`
function. In this post we'll put the `idle` function to better use and build a
CPU usage monitor there.

[the RTFM framework]: /fearless-concurrency

# Idle

The main logic of the CPU usage monitor will be in the `idle` function. Let's
see how it works:

``` rust
// RESOURCES
peripherals!(stm32f30x, {
    DWT: Peripheral {
        register_block: Dwt,
        ceiling: C0,
    },
    (..)
});

// Total sleep time (in clock cycles)
static SLEEP_TIME: Resource<Cell<u32>, C1> = Resource::new(Cell::new(0));

// IDLE LOOP
fn idle(ref prio: P0, _thr: T0) -> ! {
    loop {
        // For the span of this critical section the processor will not service
        // interrupts (tasks)
        rtfm::atomic(|thr| {
            let dwt = DWT.access(prio, thr);
            let sleep_time = SLEEP_TIME.access(prio, thr);

            // Sleep
            let before = dwt.cyccnt.read();
            rtfm::wfi();
            let after = dwt.cyccnt.read();

            let elapsed = after.wrapping_sub(before);

            // Accumulate sleep time
            sleep_time.set(sleep_time.get() + elapsed);
        });

        // Tasks are serviced at this point
    }
}
```

We will still put the processor to sleep in the `idle` function -- you can still
see the WFI (Wait For Interrupt) instruction. However this time the instruction
will be executed within a *global* critical section (`rtfm::atomic`). So what
will happen when an interrupt event arrives? The processor will *wake up* from
the WFI instruction but it will *not* service the interrupt because of the
critical section; instead it will continue executing the `idle` function.

Before and after the WFI instruction [the CYCCNT register] is read; the
difference between these two snapshots, `elapsed`, is the time, in clock cycles,
that the processor spent sleeping, *waiting for an interrupt*. This sleep time
is then accumulated in the `SLEEP_TIME` resource; this resource tracks the
*total* time spent sleeping.

[the CYCCNT register]: /rtfm-overhead/#dwt-and-cyccnt

Once the resource has been updated the critical section ends and `idle` gets
immediately preempted by the pending interrupts. The processor then starts
executing the tasks that need to be serviced. Once the processor has finished
executing all the pending tasks it returns back to `idle`.

The `loop` restarts: a new critical section starts and the processor goes back
to sleep. The whole cycle repeats.

So the logic in the `idle` function is actually *not* measuring the CPU use;
it's measuring the opposite: the total time the CPU is *not* being used. To turn
that number into CPU usage we have to subtract the total elapsed time by the
time spent sleeping; that would be the time the CPU was active. To get a
percentage we have to divide the active time by the total elapsed time and
multiply by 100%. The formula would be:

> `CPU_USE = (TOTAL - SLEEP) / TOTAL * 100.`

Now let's build an example.

# Blinky

We'll add the CPU usage monitor to the blinky example we used in [the post that
introduced the RTFM framework][rtfm].

[rtfm]: /fearless-concurrency/#a-blinking-task

Starting from that example we'll replace the `idle` function with the version
shown in the previous section and then tweak the `blinky` task like this:

``` rust
fn blinky(ref mut task: Tim1UpTim10, ref prio: P1, ref thr: T1) {
    static STATE: Local<bool, Tim1UpTim10> = Local::new(false);

    let tim1 = &TIM1.access(prio, thr);
    let itm = ITM.access(prio, thr);
    let sleep_time = SLEEP_TIME.access(prio, thr);
    let state = STATE.borrow_mut(task);

    let timer = Timer(tim1);

    if timer.clear_update_flag().is_ok() {
        *state = !*state;

        if *state {
            Green.on();
        } else {
            Green.off();
        }

        // NEW!
        // Report clock cycles spent sleeping
        iprintln!(&itm.stim[0], "{}", sleep_time.get());

        // Reset sleep time back to zero
        sleep_time.set(0);
    } else {
        // Only reachable via `rtfm::request(blinky)`
        unreachable!()
    }
}
```

(You can find the full source code of this program in [the appendix])

[the appendix]: /cpu-monitor/#appendix

The new part here is that, after we toggle the state of the LED, we print the
sleep time to the console using [the ITM], and then we reset the `SLEEP_TIME`
counter back to zero. As the `blinky` task is periodic this will print the
number of clock cycles the processor spent sleeping in a period of one second.

[the ITM]: /itm

Let's see the numbers reported by this program when compiled in debug mode
(without optimizations):

``` console
$ cat /dev/ttyUSB0
(..)
7993609
7993608
7993609
7993608
```

The sleep time is reported every one second. As the processor is operating at 8
MHz 1 second is equivalent to 8 millions of processor clock cycles. Subtracting
that value by the ones above yields the active CPU time per second:

``` text
6391
6392
6391
6392
```

Those values can be converted to a CPU usage percentage using the formula we
presented before (`PERIOD` is `8_000_000`):

``` text
0.0798875%
0.0799%
0.0798875%
0.0799%
```

Averaging those values gives 0.0799%

Note that this CPU usage includes both blinking the LED, *and* reporting the
sleep time.

We can repeat the measurement but with the program compiled in release mode
(with optimizations):

``` console
$ cat /dev/ttyUSB0
(..)
7999488
7999488
7999488
7999488
```

Now the average CPU usage is down to 0.0064%.

For extra enlightenment we can do a threshold vs time diagram, like we did
in [the fearless concurrency post][diagram], for this last program:

[diagram]: /fearless-concurrency/#preemption

![Blinky](/cpu-monitor/blinky.svg)

The difference is that the preemption threshold of the idle loop is now maxed
out but once an update event arrives the threshold of `idle` is quickly dropped
to allow preemption and service the `blinky` task. Scheduling wise nothing has
changed.

# Loopback

Let's do one more example. Let's add a CPU usage monitor to [the concurrency
example] we did in the fearless concurrency post. Starting from this post blinky
example we only have to add the `loopback` task and some initialization code:

[the concurrency example]: /fearless-concurrency/#concurrency

``` rust
tasks!(stm32f103xx, {
    // ..
    loopback: Task {
        interrupt: Usart1,
        priority: P1,
        enabled: true,
    },
});

fn loopback(_task: Usart1, ref prio: P1, ref thr: T1) {
    let usart1 = USART1.access(prio, thr);

    let serial = Serial(&usart1);

    if let Ok(byte) = serial.read() {
        if serial.write(byte).is_err() {
            // NOTE(unreachable!) unlikely to overrun the TX buffer because we
            // are sending _one_ byte per byte received
            unreachable!()
        }
    } else {
        // NOTE(unreachable!) only reachable through `rtfm::request(loopback)`
        unreachable!()
    }
}
```

This `loopback` task will send back the data that comes through the serial
interface byte by byte.

In the original example we tested this program by manually sending data through
a serial terminal. The data throughput was rather low as the input came from a
keyboard. This time we'll maximize the data throughput using the following
command:

``` console
$ # Send the pangram over the serial interface 1000 times and as fast possible
$ for i in `seq 1 1000`; do
    echo "The quick brown fox jumps over the lazy dog." > /dev/rfcomm0
  done
```

Let's see if the microcontroller can keep up and what the CPU usage is under
these conditions:

<video controls>
  <source src="/cpu-monitor/loopback.webm" type="video/webm">
</video>

In this take the program running on the microcontroller was compiled in release
mode. The top right terminal shows the data that the microcontroller echoes
back. The bottom right terminal shows the sleep time periodically reported by
the microcontroller. Here's a transcript of the sleep times:

```
$ cat /dev/ttyUSB0
(..)
7999488
7660188
7636788
7636788
7639843
7639612
7648033
7646047
7636788
7926363
7999488
```

The average CPU usage under these conditions is 4.4624% (the first and last two
samples were not taken into account in the computation).

# Delayed interrupt handling

Using this CPU monitor comes at a cost: servicing of interrupts (tasks) will be
delayed by a constant number of clock cycles. You can think of this as an
increased context switching cost when switching from `idle` to some task.

I think this delay is better visualized by looking at the source code of `idle`.
Note the comments:

``` rust
fn idle(ref prio: P0, _thr: T0) -> ! {
    loop {
        rtfm::atomic(|thr| {
            let dwt = DWT.access(prio, thr);
            let sleep_time = SLEEP_TIME.access(prio, thr);

            let before = dwt.cyccnt.read();
            // Sleep
            rtfm::wfi(); // <- event A arrives and wakes the processor up
            let after = dwt.cyccnt.read();

            let elapsed = after.wrapping_sub(before);

            sleep_time.set(sleep_time.get() + elapsed);
        });

        // task A starts
    }
}
```

Starting the task A is delayed by the execution of the code that increases the
`SLEEP_TIME` counter:

``` rust
            let after = dwt.cyccnt.read();

            let elapsed = after.wrapping_sub(before);

            sleep_time.set(sleep_time.get() + elapsed);
        }); // end of critical section
```

The delay is constant and less than 10 clock cycles -- I'll show you the
disassembly in a bit -- which is not that bad. However, there's one particular
scenario where a task can be delayed *indefinitely*. Again let's look at the
source code of `idle`:

``` rust
fn idle(ref prio: P0, _thr: T0) -> ! {
    loop {
        rtfm::atomic(|thr| {
            let dwt = DWT.access(prio, thr);
            let sleep_time = SLEEP_TIME.access(prio, thr);

            // <- event A arrives. Task A is NOT executed

            let before = dwt.cyccnt.read();
            // Sleep
            rtfm::wfi(); // <- event B arrives and wakes the processor up
            let after = dwt.cyccnt.read();

            let elapsed = after.wrapping_sub(before);

            sleep_time.set(sleep_time.get() + elapsed);
        });

        // tasks A and B start
    }
}
```

Here event A arrives after the critical section is started and before WFI is
executed. Because of this the execution of task A will be delayed *until some
other event arrives* and wakes up the processor. That could take a few cycles,
or several, or never occur. In any case it's bad because the delay is non
deterministic in the general case.

The condition to arrive at this scenario is that some interrupt event must
arrive *after* the critical section starts (the interrupts get disabled) and
*before* the processor executes the WFI instruction. The likelihood of this
scenario will thus depend on how big that window is so let's look at the
disassembly of the `idle` function:

``` armasm
08000462 <blinky::idle>:
 8000462:       f241 0c04       movw    ip, #4100       ; 0x1004
 8000466:       f240 0100       movw    r1, #0
 800046a:       f2ce 0c00       movt    ip, #57344      ; 0xe000
 800046e:       f2c2 0100       movt    r1, #8192       ; 0x2000
 8000472:       e000            b.n     8000476 <blinky::idle+0x14>
 8000474:       b662            cpsie   i               ; ENABLE interrupts
 8000476:       f3ef 8210       mrs     r2, PRIMASK
 800047a:       b672            cpsid   i               ; DISABLE interrupts
 800047c:       f8dc 3000       ldr.w   r3, [ip]        ; read CYCCNT
 8000480:       bf30            wfi                     ; SLEEP
 8000482:       f8dc 0000       ldr.w   r0, [ip]        ; read CYCCNT
 8000486:       f012 0f01       tst.w   r2, #1
 800048a:       eba0 0003       sub.w   r0, r0, r3
 800048e:       680b            ldr     r3, [r1, #0]
 8000490:       4418            add     r0, r3
 8000492:       6008            str     r0, [r1, #0]
 8000494:       d1ef            bne.n   8000476 <blinky::idle+0x14>
 8000496:       e7ed            b.n     8000474 <blinky::idle+0x12>
```

The window is very small; it's a single instruction: `ldr.w   r3, [ip]`. That
makes the likelihood of hitting this unbounded delay scenario *almost*
impossible.

# Outro

All right. There you go: a noninvasive (no need for external monitoring
hardware), low overhead CPU usage monitor. Until next time!

---

__Thank you patrons! :heart:__

I want to wholeheartedly thank [Iban Eguia], [Aaron Turon], [Geoff Cant],
[Harrison Chin], [Brandon Edens], [whitequark], [J. Ryan Stinnett], [James
Munns], [Jared Boone] and 20 more people
for [supporting my work on Patreon][Patreon].

[Iban Eguia]: https://github.com/Razican
[Aaron Turon]: https://github.com/aturon
[Geoff Cant]: https://github.com/archaelus
[Harrison Chin]: http://www.harrisonchin.com/
[Brandon Edens]: https://github.com/brandonedens
[whitequark]: https://github.com/whitequark
[J. Ryan Stinnett]: https://convolv.es/
[James Munns]: https://jamesmunns.com/
[Jared Boone]: http://www.sharebrained.com/

---

<!-- Let's discuss on [reddit]. -->

<!-- [reddit]:  -->

Enjoyed this post? Like my work on embedded stuff? Consider supporting my work
on [Patreon]!

[Patreon]: https://goo.gl/4ikFFq

Follow me on [twitter] for even more embedded stuff.

[twitter]: https://twitter.com/japaricious

The embedded Rust community gathers on the #rust-embedded IRC channel
(irc.mozilla.org). Join us!

---

# Appendix

``` rust
#![feature(const_fn)]
#![feature(used)]
#![no_std]

// version = "0.2.9"
#[macro_use]
extern crate cortex_m;

// version = "0.2.4"
extern crate cortex_m_rt;

// version = "0.1.0"
#[macro_use]
extern crate cortex_m_rtfm as rtfm;

// git = "https://github.com/japaric/blue-pill"
// rev = "63f2e6195546669f685606096db78ec73c5525b8"
extern crate blue_pill;

use core::cell::Cell;

use blue_pill::led::{Green, self};
use blue_pill::stm32f103xx;
use blue_pill::timer::Timer;
use rtfm::{Local, C1, P0, P1, Resource, T0, T1, TMax};
use stm32f103xx::interrupt::Tim1UpTim10;

// CONFIGURATION
const FREQUENCY: u32 = 1; // Hz

// RESOURCES
peripherals!(stm32f103xx, {
    DWT: Peripheral {
        register_block: Dwt,
        ceiling: C0,
    },
    GPIOC: Peripheral {
        register_block: Gpioc,
        ceiling: C0,
    },
    ITM: Peripheral {
        register_block: Itm,
        ceiling: C1,
    },
    RCC: Peripheral {
        register_block: Rcc,
        ceiling: C0,
    },
    TIM1: Peripheral {
        register_block: Tim1,
        ceiling: C1,
    },
});

// Total sleep time (in clock cycles)
static SLEEP_TIME: Resource<Cell<u32>, C1> = Resource::new(Cell::new(0));

// INITIALIZATION PHASE
fn init(ref prio: P0, thr: &TMax) {
    let dwt = &DWT.access(prio, thr);
    let gpioc = &GPIOC.access(prio, thr);
    let rcc = &RCC.access(prio, thr);
    let tim1 = &TIM1.access(prio, thr);

    let timer = Timer(tim1);

    dwt.enable_cycle_counter();

    led::init(gpioc, rcc);

    timer.init(FREQUENCY, rcc);
    timer.resume();
}

// IDLE LOOP
fn idle(ref prio: P0, _thr: T0) -> ! {
    loop {
        // For the span of this critical section the processor will not service
        // interrupts (tasks)
        rtfm::atomic(|thr| {
            let dwt = DWT.access(prio, thr);
            let sleep_time = SLEEP_TIME.access(prio, thr);

            // Sleep
            let before = dwt.cyccnt.read();
            rtfm::wfi();
            let after = dwt.cyccnt.read();

            let elapsed = after.wrapping_sub(before);

            // Accumulate sleep time
            sleep_time.set(sleep_time.get() + elapsed);
        });

        // Tasks are serviced at this point
    }
}

// TASKS
tasks!(stm32f103xx, {
    blinky: Task {
        interrupt: Tim1UpTim10,
        priority: P1,
        enabled: true,
    },
});

fn blinky(ref mut task: Tim1UpTim10, ref prio: P1, ref thr: T1) {
    static STATE: Local<bool, Tim1UpTim10> = Local::new(false);

    let tim1 = &TIM1.access(prio, thr);
    let itm = ITM.access(prio, thr);
    let sleep_time = SLEEP_TIME.access(prio, thr);
    let state = STATE.borrow_mut(task);

    let timer = Timer(tim1);

    if timer.clear_update_flag().is_ok() {
        *state = !*state;

        if *state {
            Green.on();
        } else {
            Green.off();
        }

        // NEW!
        // Report clock cycles spent sleeping
        iprintln!(&itm.stim[0], "{}", sleep_time.get());

        // Reset sleep time back to zero
        sleep_time.set(0);
    } else {
        // Only reachable via `rtfm::request(blinky)`
        unreachable!()
    }
}
```
