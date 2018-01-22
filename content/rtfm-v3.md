---
date: 2018-01-22T19:58:35+01:00
draft: false
tags: ["ARM Cortex-M", "concurrency", "RTFM"]
title: "RTFM v0.3.0: safe `&'static mut T` and less locks"
---

RTFM (Real Time For the Masses) v0.3.0 is [out]! This blog post will cover the goodies of this new
release.

The minor (breaking) release was mainly to become compatible with the new IO model presented in my
[previous blog post][brave-new-io], but a new feature also shipped with this release: *safe*
creation of `&'static mut` references.

[brave-new-io]: /brave-new-io

[out]: https://docs.rs/cortex-m-rtfm/~0.3.1

First, let's look at one feature that landed in v0.2.1 but that didn't get documented in this blog,
yet it was essential to adapt RTFM to the new IO model:

# Late resources

In RTFM all *resources*, the main mechanism to share memory between *tasks*, are implemented as
`static` variables. In Rust `static` variables need to have an initial value so, in v0.2.0, you had
to declare an initial value for all resources declared in the `app!` macro.

``` rust
// cortex-m-rtfm v0.2.0
app! {
    resources: {
        static COUNTER: u32 = 0;
        static ON: bool = false;
    }
}

fn init(p: init::Peripherals, r: init::Resources) {
    assert!(r.COUNTER, 0);
    assert!(!r.ON);
}
```

In v0.2.1, RTFM gained support for "late resources", resources with runtime ("late")
initialization. Resources that are not assigned an initial value in `app!` are considered to be late
resources. These resources need to be assigned an initial value by the end of the `init` function.

``` rust
// cortex-m-rtfm v0.2.1
app! {
    resources: {
        static NORMAL: u32 = 0;
        static LATE: u32;
    },

    idle: {
        resources: [LATE],
    }
}

fn init(p: init::Peripherals, r: init::Resources) -> init::LateResources {
    // normal resources can be accessed via `init::Resources`
    r.NORMAL += 1;

    // but late resources can not because they have not been initialized
    // at this point
    //r.LATE += 1;
    //~^ error: no field named `LATE` found in `init::Resources`

    let private_key = load_from_eeprom();

    // late resources get assigned their initial value here
    init::LateResources {
        LATE: private_key,
    }
}

// late resources, the actual static variables, get initialized somewhere
// between `init` and `idle`
// (recall that the start of `idle` is also when tasks become enabled (can start))

fn idle(t: &mut Threshold, r: idle::Resources) -> ! {
    // late resources can be used at this point
    let private_key = *r.LATE;

    loop {
        // do stuff with `private_key`
    }
}
```

This allows initialization of resources in `init` without the use of `Option`. In v0.2.0, you could
achieve more or less the same using a normal resource with an initial value of `None` but then you
needed to `unwrap` the resource to access its value.

# New I/O model = less locks

The breaking change that moved RTFM to v0.3.0 is: peripherals are no longer special. In v0.2.0,
any resource associated to a task that didn't appear in the list of declared resources was
considered a peripheral. Here's an example:

``` rust
// cortex-m-rtfm v0.2.x

app! {
    // declared resources
    resources: {
        static COUNTER: u32 = 0;
        // no USART1 here!
    },

    tasks: {
        EXTI0: {
            path: exti0,
            // yet it appears here!
            resources: [USART1],
            priority: 1,
        },

        EXTI1: {
            path: exti1,
            // and here!
            resources: [USART1],
            priority: 2,
        },
    }
}

fn init(p: init::Peripherals, r: init::Resources) {
    let usart1: &mut USART1 = p.USART1;

    // omitted: initialization of the serial interface
}

fn exti0(t: &mut Threshold, r: EXTI0::Resources) {
    r.USART1.lock_mut(|usart1: &mut USART1| {
        let tx = Tx(usart1);
        // do stuff with `tx` (transmitter)
    });
}

fn exti1(t: &mut Threshold, r: EXTI1::Resources) {
    let usart1: &mut USART1 = r.USART1;
    let rx = Rx(usart1);
    // do stuff with `rx` (receiver)
}
```

Here RTFM assumes that `USART1` is a peripheral since it doesn't appear in the list of resources.
v0.3.x is less magic: if you assign an undeclared resource to a task you get a compile time (proc
macro) error.

Following the new I/O model in v0.3.x you get *ownership* over all the peripherals in `init` -- no
need to call `Peripherals::take().unwrap()` -- and you are free to put them in *late* resources or
not.

Let's port the USART example to v0.3.x.

``` rust
// cortex-m-rtfm v0.3.x
app! {
    resources: {
        // (the Rx and Tx used here are simplified versions of what you'd find
        //  in stm32f30x-hal)
        static RX: Rx<USART1>;
        static TX: Tx<USART1>;
    },

    tasks: {
        EXTI0: {
            path: exti0,
            resources: [TX],
            priority: 1,
        },

        EXTI1: {
            path: exti1,
            resources: [RX],
            priority: 2,
        },
    }
}

fn init(p: init::Peripherals) -> init::LateResources {
    // Note that this is now an owned value, not a reference
    let usart1: USART1 = p.device.USART1;

    // omitted: GPIO and clock configuration

    // `pa9` and `pa10` are the Tx and Rx pins that `serial` will use
    let serial =
        Serial::new(usart1, (pa9, pa10), 9_600.bps(), clocks, &mut rcc.APB2);

    // split `serial` in transmitter and receiver halves
    let (tx, rx) = serial.split();

    init::LateResources { TX: tx, RX: rx }
}

fn exti0(t: &mut Threshold, r: EXTI0::Resources) {
    let tx: &mut Tx<USART1> = r.TX;
    // do stuff with `tx`
}

fn exti1(t: &mut Threshold, r: EXTI0::Resources) {
    let rx: &mut Rx<USART1> = r.RX;
    // do stuff with `rx`
}
```

In this new version the task `EXTI0` doesn't have to lock the USART1 peripheral to use the
transmitter functionality even though the `RX` in task `EXTI1` is *also* using the USART1
peripheral. This is OK because the `Tx` and `Rx` abstractions are written to operate on USART1
concurrently without needing to lock it.

Why wasn't the same possible in the v0.2.x version? The problem with that version is that `Tx` and
`Rx` are constructed in the tasks themselves so there's no way to guarantee, at compile time, that a
user won't construct a `Rx` instance in both tasks -- if they do that then the lock becomes
necessary.

In the v0.3.x version `Tx` and `Rx` are constructed during `init` and then stored in resources. The
resources have the types `Tx` and `Rx` which mean that there will *always* be *one* `Tx` and *one*
`Rx` -- remember that resources are `static` variables so the values stored in them can't never be
destroyed nor can't their types change.

So with move semantics of the new I/O model and late resources we can achieve even finer grained
concurrency (less locks) than what was possible to do in v0.2.x.

# Safe `&'static mut` references

This is the new feature that landed in v0.3.0. Let me first describe how to use it and then I'll
explain what use cases it enables.

The `init` function can modify all *non-late* resources because it runs before all the tasks can
run. In v0.2.x, every non-late resource appears under `init::Resources` as a field with type `&mut
T`; the lifetime of this reference is constrained to the scoped of the `init` function.

In v0.3.x, you can assign non-late resources to `init`; this was not allowed in v0.2.x. When
you assign a resource to `init` it becomes *owned* by `init`; it will still appear as a field of
`init::Resources` but it will have type `&'static mut T`.

Example below:

``` rust
// rtfm v0.3.x
app! {
    resources: {
        static A: u32 = 0;
        static B: u32 = 0;
    },

    init: {
        // `init.resources` only exists in v0.3.x
        resources: [A],
    },
}

fn init(p: init::Peripherals, r: init::Resources) {
    let a: &'static mut u32 = r.A;
    // note: non-static lifetime
    let b: & mut u32 = r.B;
}
```

Some restrictions apply: a resource assigned to `init` can't be assigned to (i.e. shared with) any
task; the other restriction, which I already mentioned, is that only *non-late* resources can be
assigned to `init`.

This doesn't seem too exciting on its own ... so

## Why `&'static mut`?

`&'static mut T` is very similar to `Box<T>`. They are both pointer sized and they both *own* the
value `T` so they both have move semantics *and* implement `Send` (if `T: Send`). That makes them
handy for cheaply *sending* stuff like buffers from one context of execution (thread or task) to
another. Sending an owned `*mut [u8; 1024]` is much cheaper than sending `[u8; 1024]` because the
later involves memcpy-ing  the whole array -- whoops!

The main difference between the two is that to create a `Box<T>` you need a (dynamic) memory
allocator whereas `&'static mut T` can be created without one.

Sometimes you may not want to use a memory allocator in your application for performance, code size
and / or reliability [^1] reasons so being able to safely create a `&'static mut T` is a great
alternative to `Box`! Provided that you don't really need a dynamic allocation: for instance, you
can't create a `&'static mut [T]` of arbitrary size; it has to be of a known size, or at least the
upper bound of the size must be known at compile time.

[^1]: e.g. can't afford the possibility of the abort that an OOM condition triggers

### Lockless queue

The use case that originally prompted the need for `&'static mut` references was a mechanism for
inter task communication: a single producer single consumer ring buffer.

What's that useful for? It's a lockless queue. A producer can queue new items into the ring buffer
and a consumer can dequeue items from it. If only a single producer and a single consumer exist then
they can both locklessly operate on the buffer even if they are being used from different execution
contexts that can preempt each other. This mechanism would let us exchange data between a task and
the idle loop without locking so it was a welcome addition!

A `static` variable friendly [implementation] of such ring buffer is available in the [`heapless`]
crate but its API produced a consumer and a producer with a lifetime [parameter] equal to the
lifetime of the ring buffer. That API works fine with scoped threads in `std` land:

[implementation]: https://docs.rs/heapless/0.2.1/heapless/ring_buffer/struct.RingBuffer.html
[`heapless`]: https://docs.rs/heapless
[parameter]: https://docs.rs/heapless/0.2.1/heapless/ring_buffer/struct.RingBuffer.html#method.split

``` rust
use heapless::RingBuffer;
use scoped_threadpool::Pool;

// (the signature is kind of odd due to the lack of const generics;
//  ideally it should simply be `RingBuffer<i32, 4>`)
let mut rb: RingBuffer<i32, [i32; 4]> = RingBuffer::new();

rb.enqueue(0).unwrap();

{
    let (mut p, mut c) = rb.split();

    Pool::new(2).scoped(move |scope| {
        scope.execute(move || {
            p.enqueue(1).unwrap();
        });

        scope.execute(move || {
            c.dequeue().unwrap();
        });
    });
}

rb.dequeue().unwrap();
```

But to use it with RTFM both the producer and consumer need to have a `'static` lifetime parameter,
otherwise they can't be stored in a resource (in a `static` variable). And that's only possible if
one has a `&'static mut` reference to a `RingBuffer`.

Which became possible with v0.3.x. Here's an example that uses `RingBuffer` for task-idle
communication:
``` rust
use heapless::ring_buffer::{Consumer, Producer, RingBuffer},

enum Event { A, B, C }

// cortex-m-rtfm v0.3.x
app! {
    resources: {
        // (again: with const generics we would be able to write `8` instead of
        //  `[Event; 8]`)
        static RB: RingBuffer<Event, [Event; 8]> = RingBuffer::new();
        static C: Consumer<'static, Event, [Event; 8]>;
        static P: Producer<'static, Event, [Event; 8]>;
    },

    init: {
        resources: [RB],
    },

    idle: {
        resources: [C],
    },

    tasks: {
        EXTI0: {
            path: exti0,
            resources: [P],
        },
    },
}

fn init(p: init::Peripherals, r: init::Resources) -> init::LateResources {
    let rb: &'static mut RingBuffer<_, _> = p.RB;

    let (p, c) = rb.split();

    init::LateResources { P: p, C: c }
}

fn idle(t: &mut Threshold, r: idle::Resources) {
    let c: &mut Consumer<'static, _, _> = r.C;

    loop {
        if let Ok(event) = c.dequeue() {
            // process event
            match event {
                Event::A => { /* .. */ }
                Event::B => { /* .. */ }
                Event::C => { /* .. */ }
            }
        } else {
            // no event to process: go to sleep
            asm::wfi();
        }
    }
}

fn exti0(t: &mut Threshold, r: EXTI0::Resources) {
    let p: &mut Producer<'static, _, _> = r.P;

    // ..

    // notify `idle` about a new event
    if cond {
        p.queue(Event::A).unwrap();
    } else if another_cond {
        p.queue(Event::B).unwrap();
    } else {
        p.queue(Event::C).unwrap();
    }
}
```

### DMA transfers

The other use case that I had for `&'static mut` references was a memory safe API for DMA transfers.
But that topic deserves its own blog post so I won't cover it here.

## Outside RTFM

Not everyone wants to use RTFM (I guess some people don't like the procedural `app!` macro?) so I
always try to make RTFM abstractions available outside of the RTFM framework, when possible at all.
This time it was possible so I brought safe `&'static mut` references to the `cortex-m` crate in
the form of a [`singleton!`] macro. Unlike the RTFM mechanism, the `singleton!` macro is not zero
cost.

[`singleton!`]: https://docs.rs/cortex-m/0.4.2/cortex_m/macro.singleton.html

Here's an example of using the macro:

``` rust
#![no_std]

#[macro_use(singleton)]
extern crate cortex_m;
extern crate cortex_m_rt;

fn main() {
    let a: &'static mut u32 = singleton!(_: u32 = 0).unwrap();
    assert_eq!(*a, 0);

    let b: &'static mut u32 = singleton!(_: u32 = 1).unwrap();
    assert_eq!(*b, 1);

    // pointers to different memory locations
    assert_ne!(a as *mut _ as usize, b as *mut _ as usize);
}
```

This program completes without panicking. Each `singleton!` invocation has a memory overhead of one
(`.bss`) byte so 10 bytes total of (`.bss + .data`) RAM are used in this example. Each `singleton!`
invocation also involves a runtime check and that's why the macro returns an `Option`.

But why is the runtime check required? The runtime check is actually an aliasing check. Look at the
next example:

``` rust
#![no_std]

#[macro_use(singleton)]
extern crate cortex_m;
extern crate cortex_m_rt;

fn main() {
    let a = alias(); // OK
    let b = alias(); // `panic!`s
}

fn alias() -> &'static mut u32 {
    singleton!(_: u32 = 0).unwrap()
}
```

This program will `panic!` because `alias` returns a pointer to the *same* memory location in both
invocations. Without the runtime check `b` would have become an alias of `a` and that would have
broken Rust aliasing model.

That's it for this post. In the next one I'll present an API for memory safe DMA transfers.

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
[Kenneth Keiter]
and 42 more people for [supporting my work on Patreon][Patreon].

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

---

Let's discuss on [reddit].

[reddit]: https://www.reddit.com/r/rust/comments/7s81h1/eir_real_time_for_the_masses_v030_safe_static_mut/

Enjoyed this post? Like my work on embedded stuff? Consider supporting my work
on [Patreon]!

[Patreon]: https://www.patreon.com/japaric

Follow me on [twitter] for even more embedded stuff.

[twitter]: https://twitter.com/japaricious

The embedded Rust community gathers on the #rust-embedded IRC channel
(irc.mozilla.org). Join us!
