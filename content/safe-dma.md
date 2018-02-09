---
title: "Memory safe DMA transfers"
date: 2018-02-09T11:47:30+01:00
draft: false
tags: ["I/O", "microcontroller"]
---

In this post I'll describe an approach to building memory safe DMA based APIs.

# DMA?

DMA stands for Direct Memory Access and it's a peripheral used for transferring data between two
memory locations *in parallel* to the operation of the core processor. I like to think of the DMA as
providing asynchronous `memcpy` functionality.

Let me show you the awesomeness of the DMA with an example:

Let's say we want to send the string `"Hello, world"` through the serial interface. As you probably
know by now, using the serial interface involves writing to registers. In particular, sending a byte
through the interface requires writing that byte to a register -- let's call that register the *DR*
register.

The serial interface operates at a slower frequency than the processor so to avoid a buffer
*overrun* is necessary to wait until the byte has been shifted out from the DR register before
writing a new byte to it. In other words, if you write bytes to the DR register too fast you'll end
up overwriting the previous byte before it has chance to be sent through the serial interface --
that condition is known as buffer overrun.

The straightforward approach to performing this task is to do several blocking "write a single byte"
operations:

``` rust
for byte in b"Hello, world!".iter() {
    block!(serial.write(*byte));
}
```

Here `block!` will busy wait until the previous byte gets sent through the serial interface, and
`serial.write` will write the `*byte` into the DR register.

This gets the job done but it uses precious CPU time: the processor will be completely busy
executing the `for` loop.

If we use the DMA the task can be performed with almost 0% CPU usage:

``` rust
static MSG: &'static [u8] = b"Hello, world!";

// this block is executed in a few instructions
unsafe {
    // address of the DR register in the USART1 register block
    const USART1_DR: u32 = 0x4001_3804;

    // (some configuration has been omitted)

    // transfer this number of bytes
    dma1_channel4.set_transfer_size(MSG.len()); // in bytes

    // from here
    dma1_channel4.set_src_address(MSG.as_ptr() as usize as u32);

    // to here
    dma1_channel4.set_dst_address(USART1_DR);

    // go!
    dma1_channel4.start_transfer();
}

// now the processor is free to perform other tasks
// while the DMA sends out the "Hello, world!" string
```

This code performs the same task but now the processor is free to do other tasks while the serial
operation is performed in the background.

Although not shown above, the processor can check if the DMA transfer has finished by reading some
register.

# When DMA transfers go wrong

DMA transfers are pretty useful because they can free up a lot of CPU time but they can be very
dangerous when misused.

Let's look at an example where a DMA transfer goes wrong:

``` rust
fn start() {
    let mut buf = [0u8; 256];

    // starts a DMA transfer to fill `buf` with data from the serial interface
    unsafe {
        // ..
        dma1_channel5.set_transfer_size(buf.len());
        dma1_channel5.set_src_address(USART1_DR);
        dma1_channel5.set_dst_address(buf.as_mut_ptr());
        dma1_channel5.start_transfer();
    }

    // `buf` deallocated here
}

fn corrupted() {
    let mut x = 0;
    let y = 0;

    // do stuff with `x` and `y`
}

start();
corrupted();
```

Here the problem is that a transfer is started on a stack allocated buffer but then the buffer is
immediately deallocated. The call to `corrupted` reuses the stack memory *that the DMA is operating
on* for the stack variables `x` and `y`; this lets the DMA overwrite the values of `x` and `y`,
wreaking havoc. If you add optimization into the mix it becomes impossible to predict what will
happen at runtime.

In this case it's a bit obvious that there's a programmer error as `buf` is never used. The problem
becomes less obvious if you return `buf` from the `start` function; in that case you can still get
undefined behavior depending on how the compiler decides to optimize the code.

# Trying to make it safe

Using the DMA like that is `unsafe` because a lot of things can go wrong. In this section we'll try
to wrap all that `unsafe` code into a safe abstraction.

We start with a newtype over the buffer on which the DMA is operating:

``` rust
/// Ongoing DMA transfer
struct Transfer<'a> {
    buf: &'a mut [u8],
    ongoing: bool,
}
```

We can use this to *freeze* the original buffer while the DMA operation is in progress. That
prevents the buffer from being modified (that would be mutable aliasing -- the DMA is already
mutating the buffer) and from being deallocated (that would let the DMA corrupt memory if the
allocation is reused).

Dropping the `Transfer` instance would let us modify, and also destroy, the original buffer so that
operation should *stop* the transfer to prevent mutable aliasing and memory unsafety:

``` rust
impl<'a> Drop for Transfer<'a> {
    fn drop(&mut self) {
        // NOTE For now I'm not going to explain where this
        // `dma1_channel5` value comes from. I'll come back to it later

        // on drop we stop the ongoing transfer
        if self.ongoing {
            dma1_channel5.stop_transfer();
        }
    }
}
```

We want to be able to get the buffer back when the transfer is over so we add a `wait` method that
waits until the transfer is over and returns back the buffer:

``` rust
impl<'a> Transfer<'a> {
    pub fn wait(mut self) -> &'a mut [u8] {
        // wait until the transfer is over
        while dma1_channel5.transfer_is_in_progress() {}

        // defuse the `drop` method
        self.ongoing = false;

        self.buf
    }
}
```

Now we can pair this `Transfer` API with a `Serial` interface abstraction to provide a safe API for
the asynchronous read operation we had before:

``` rust
impl Serial {
    /// Starts a DMA transfer to fill `buf` with data from the serial interface
    fn read_exact<'a>(&mut self, buf: &'a mut [u8]) -> Transfer<'a> {
        unsafe {
            dma1_channel5.set_src_address(USART1_DR);
            dma1_channel5.set_dst_address(buf.as_mut_ptr());
            dma1_channel5.set_transfer_size(buf.len());
            dma1_channel5.start_transfer();
        }

        Transfer { buf, ongoing: true }
    }
}
```

Usage looks like this:

``` rust
let mut buf = [0; 16];

let transfer = serial.read_exact(&mut buf);

// do other stuff

let buf = transfer.wait();

// do stuff with the now filled `buf`fer
```

Now let's see if the API can prevent us from shooting ourselves in the foot:

``` rust
fn start(serial: &mut Serial) -> Transfer {
    let mut buf = [0; 16];

    serial.read_exact(&mut buf)
    //~^ error: borrowed value does not live long enough
}   // `buf` dropped / deallocated here
```

Good. This won't compile because `buf` is both allocated and deallocated in `start` thus the
`Transfer` can't outlive the scope of `start`.

Let's try the stack corruption example from before:

``` rust
fn start(serial: &mut Serial) {
    let mut buf = [0; 16];

    // (the `Transfer` value will get `drop`ped here even if I don't call `drop`)
    drop(serial.read_exact(&mut buf));
}

fn corrupted() {
    let mut x = 0;
    let y = 0;

    // do stuff with `x` and `y`
}

start(&mut serial);
corrupted();
```

There won't be stack corruption this time because when `Transfer` is dropped in `start` the DMA
transfer is stopped. Great!

## [Leakpocalypse]

[Leakpocalypse]: http://cglab.ca/~abeinges/blah/everyone-poops/#leakpocalypse

Seems like a pretty solid abstraction, right? Unfortunately, it's not completely safe because it
relies on destructors for safety and destructors are not guaranteed to run in Rust.

Here's how to break the abstraction:

``` rust
fn start(serial: &mut Serial) {
    let mut buf = [0; 16];

    // not `unsafe`!
    mem::forget(serial.read_exact(&mut buf));
}

fn corrupted() {
    let mut x = 0;
    let y = 0;

    // do stuff with `x` and `y`
}

start(&mut serial);
corrupted();
```

This produces stack corruption in safe Rust. `mem::forget`-ing `Transfer` prevents its destructor
from running, which means the DMA transfer is never stopped. Furthermore, this also breaks Rust
aliasing rules because it lets the processor mutate `buf` which is already being mutated by the
DMA.

"But nobody writes code like that!". Not on purpose, no; but we are talking about Rust here:
memory unsafety is banned in safe Rust and that property must hold regardless of how contorted
the code is.

# `&'static mut` to the rescue

The good news is that we can fix all the issues by simply tweaking the lifetime of `Transfer`:

``` rust
/// Ongoing DMA transfer
struct Transfer {
    buf: &'static mut [u8], // <- lifetime changed
    // ongoing: bool, // no longer required
}

// impl Drop for Transfer { .. } // no longer required

impl Transfer {
    pub fn wait(self) -> &'static mut [u8] {
        // wait until the transfer is over
        while dma1_channel5.transfer_is_in_progress() {}

        // self.ongoing = false; // no longer required

        self.buf
    }
}

impl Serial {
    /// Starts a DMA transfer to fill `buf` with data from the serial interface
    fn read_exact(&mut self, buf: &'static mut [u8]) -> Transfer {
        // same implementation as before
    }
}
```

Now you may be wondering "But, where can I get a `&'static mut` reference from? Stack allocated
arrays don't have `'static` lifetime". I got you covered: my [last blog post][rtfmv3] explains how
to safely create `&'static mut` references within and without RTFM. Let's use the `singleton!`
approach to test out this API:

[rtfmv3]: /rtfm-v3

``` rust
let buf: &'static mut [u8] = singleton!(_: [u8; 16] = [0; 16]).unwrap();

let transfer = serial.read_exact(buf);

// do stuff

let buf: &'static mut [u8] = transfer.wait();

// do stuff with `buf`
```

Seems to work. What about the issues that plagued the previous API?

``` rust
fn start(serial: &mut Serial) {
    let buf: &'static mut [u8] = singleton!(_: [u8; 16] = [0; 16]).unwrap();

    mem::forget(serial.read_exact(buf));
}

fn corrupted() {
    let mut x = 0;
    let y = 0;

    // do stuff with `x` and `y`
}

start(&mut serial);
corrupted();
```

`buf` will be statically allocated in the `.bss` region, not on the stack, so, in first place, it's
impossible to deallocate `buf`'s memory. Secondly, `Transfer` has no destructor this time so it
doesn't matter if `mem::forget` is used on the value or not. In either case, the DMA transfer will
continue its process but since it's operating on statically allocated memory and not on the stack
there won't be stack corruption problem in this case. Nice!

What about mutable aliasing? `&'static mut T` has move semantics so calling `serial.read_exact`
hands over ownership of `buf` to the `Transfer` value. Even if the `Transfer` value is
`mem::forget`-ten the buffer memory can't be accessed through `buf` anymore:

``` rust
let buf: &'static mut [u8] = singleton!(_: [u8; 16] = [0; 16]).unwrap();

mem::forget(serial.read_exact(buf));

buf[0] = 1;
//~^ error: cannot assign to `buf[..]` because it is borrowed
```

There's one more consequence to using `&'static mut` references in the DMA based API: now `Transfer`
*owns* the buffer *and* has `'static` lifetime (more precisely: it satisfies the `Transfer: 'static`
bound). This means that `Transfer` values can be stored in RTFM resources (`static` variables), which
can be used to move data from one task to another.

So, we can start a DMA transfer in task A, *send* the `Transfer` value to task B and complete (`wait`
for) the transfer there. The send operation is also cheap because the `Transfer` value is only 2
words in size (and it could be just 1 word in size if `&'static mut [T; N]` was used internally).

## An alternative API

While working on this blog post [@nagisa] pointed out to me another way to make a memory safe DMA
based API:

[@nagisa]: https://github.com/nagisa

``` rust
impl Serial {
    fn read_exact<R, F>(&mut self, buf: &mut [u8], f: F) -> R
    where
        F: FnOnce() -> R,
    {
        // start transfer
        unsafe {
            // ..
            dma1_channel5.set_src_address(USART1_DR);
            dma1_channel5.set_dst_address(buf.as_mut_ptr());
            dma1_channel5.set_transfer_size(buf.len());
            dma1_channel5.start_transfer();
        }

        // run closure
        let r = f();

        // wait until the transfer is over
        while dma1_channel5.transfer_is_in_progress() {}

        r
    }
}
```

This closure-based API encodes the "start transfer, do stuff and wait for the transfer to finish"
pattern that we have seen before into a single method call. This method is safe even when used with
stack allocated buffers as there's no way to deallocate the buffer while the transfer is in
progress (\*).

``` rust
let buf = [0; 16];

serial.read_exact(&mut buf, || {
    // do stuff
});

// do stuff with `buf`
```

The disadvantage of this API is that you can't send an ongoing DMA transfer to another task
(execution context) because the transfer will always be completed during the execution of
`read_exact`.

> (\*) A digression
>
> This alternative API made stop and think about *exception safety*. For example, what
> happens if `f` panics and the panicking behavior is to unwind [^1]? That would deallocate the
> array `buf` but wouldn't stop the DMA transfer and that might cause problems.
>
> That's not hard to fix though: you create a *drop guard* that stops the DMA transfer in its
> destructor before calling `f` and then you `mem::forget` it after `f` returns. The fix will cost a
> bit of extra binary size but the increase should be negligible.
>
> Finally, I don't think the `&'static mut`-based API has to concern itself with exception safety
> because `singleton!` and RTFM allocate the memory in `.bss` / `.data` and that memory will never
> be deallocated.

[^1]: Bare metal applications don't *usually* implement unwinding due to the cost / complexity but
    it's not impossible to find an application that does.

# Improving the guarantees

Up to this point the `&'static mut`-based API is memory safe but it's not foolproof. For instance,
nothing stops you from starting *another* DMA transfer on the same serial interface but that's not
allowed by the hardware. Let's see how we can improve the API to prevent that.

First, let's demystify this `dma1_channel5` value. This value actually has type `dma1::Channel5` and,
semantically, has ownership over one of the DMA *channels* (some vendors call them *streams*, not
channels). The DMA subsystem usually can handle several concurrent, independent data transfers; a
channel is the part of the subsystem that handles one of those concurrent data transfers. The number
of DMA channels is device specific: for example, the STM32F103 has two DMA peripherals, DMA1 and
DMA2, and DMA1 has seven channels, DMA2 five.

We can start there and provide an API to split DMA peripherals into independent channels:

``` rust
let p = stm32f103xx::Peripherals::take().unwrap();

// consumes `p.DMA1`
let channels: dma1::Channels = p.DMA1.split();

let c4: dma1::Channel4 = channels.4;
```

This is pretty similar to what we did with the GPIO peripheral, which controls the configuration of
I/O pins, in the [Brave new I/O] blog post.

[Brave new I/O]: /brave-new-io

Next, usage constraints:

Some channels can be used with some peripherals but not with others. Also, a single channel can't be
used with more than one peripheral at the same time, and a single channel can't handle more than one
memory transfer at the same time. We can encode all these properties in the API by having `Transfer`
take ownership of the channel:

``` rust
/// Ongoing DMA transfer
struct Transfer<CHANNEL> {
    buf: &'static mut [u8],
    chan: CHANNEL, // NEW!
}

impl Transfer<dma1::Channel4> {
    /// Waits until the DMA transfer is done
    pub fn wait(self) -> (&'static mut [u8], dma1::Channel4) {
        // wait until the transfer is over
        while self.chan.ifcr().tcif4().bit_is_clear() {}

        (self.buf, self.chan)
    }
}

impl Serial {
    /// Starts a DMA transfer to fill `buf` with data from the serial interface
    pub fn read_exact(
        &mut self,
        chan: dma1::Channel4, // NEW!
        buf: &'static mut [u8],
    ) -> Transfer<dma1::Channel4> {
        // ..

        // `chan` grants access to the registers of DMA1_CHANNEL4

        // set destination address
        chan.cmar().write(|w| w.ma().bits(buf.as_ptr() as usize as u32));
        //   ~~~~ CMAR4 register

        // set transfer size
        chan.cndtr().write(|w| w.ndt().bits(buf.len()));
        //   ~~~~~ CNDTR4 register

        // ..
    }
}
```

Example of hardware constraints being enforced at compile time:

```
let a = singleton!(_: [u8; 16] = [0; 16]).unwrap();
let b = singleton!(_: [u8; 16] = [0; 16]).unwrap();

// wrong channel
// serial.read_exact(channels.1, a);
//~^ error: expected `dma1::Channel4`, found `dma1::Channel1`

// OK
let t = serial.read_exact(channels.4, a);

// can't start a new DMA transfer on the same peripheral
// let t = serial.read_exact(channels.4, b);
//~^ error: use of moved value `channels.4`

// can't start a DMA transfer on another peripheral that also uses dma1::Channel4
// let t = i2c2.write_all(channels.4, ADDRESS, b);
//~^ error: use of moved value `channels.4`
```

This would have also worked if `Transfer` stored a mutable (`&mut-`) reference to `dma1::Channel4`
instead of storing it by value, but with that approach `Transfer` would have lost its `: 'static`
bound and you would no longer be able to store `Transfer` in a RTFM resource.

There's one more change to do here. `Transfer` doesn't freeze the `Serial` instance; this means that
after calling `serial.write_all(c5, "Hello, world!")` you are still be able to call
`serial.write(b'X')` to write a byte to the interface. That's not a good / useful thing to do
because the processor will race against the DMA transfer. Let's forbid that by having `Transfer`
take ownership of the serial interface as well:

``` rust
/// Ongoing DMA transfer
struct Transfer<CHANNEL, P> {
    buf: &'static mut [u8],
    chan: CHANNEL,
    payload: P, // NEW!
}

impl<P> Transfer<dma1::Channel4, P> {
    /// Waits until the DMA transfer is done
    pub fn wait(self) -> (&'static mut [u8], dma1::Channel4, P) {
        // wait until the transfer is over
        while self.chan.ifcr().tcif4().bit_is_clear() {}

        (self.buf, self.chan, self.payload)
    }
}

impl Serial {
    /// Starts a DMA transfer that fills the `buf`fer with serial data
    pub fn read_exact(
        self, // <- main change (was `&mut self`)
        chan: dma1::Channel4,
        buf: &'static mut [u8],
    ) -> Transfer<dma1::Channel4, Serial> {
        // ..

        Transfer { buf, chan, payload: self }
    }
}
```

## Preventing misoptimtization

To us, programmers, using the DMA based API looks like:

``` rust
let buf = singleton!(_: [u8; 45] = [0; 45]).unwrap();

buf.copy_from_slice(b"The quick brown fox jumps over the lazy dog.\n")

let transfer = serial.write_all(channels.5, buf);

// ..

let (buf, c5, serial) = transfer.wait();
```

To the compiler that code looks like this, after inlining some functions calls:

``` rust
let buf = singleton!(_: [u8; 45] = [0; 45]).unwrap();

buf.copy_from_slice(b"The quick brown fox jumps over the lazy dog.\n")

// ..

// set destination address
channels.5.cmar().write(|w| w.ma().bits(buf.as_ptr() as u32));

// set transfer size
channels.5.cndtr().write(|w| w.ndt().bits(buf.len()));

// ..

// start transfer
channels.5.ccr().modify(|w| w.cen().set_bit());

let transfer = Transfer { buf, chan: channels.5, payload: serial }

// ..

// wait until the transfer is over
while transfer.chan.ifcr().tcif4().bit_is_clear() {}

let (buf, c5, serial) = (transfer.buf, transfer.chan, transfer.payload);
```

Now, the operations on registers (e.g. `write`s) are volatile so we are sure the compiler won't
reorder those with respect to other volatile operations. *But*, the compiler is free to move non
volatile operations like `buf.copy_from_slice` to, say, after `// start transfer` as that reordering
doesn't change the outcome of the preceding `buf.as_ptr()` and `buf.len()` operations. Of course,
such reordering would change the semantics of the program (it creates a data race between the DMA
and the processor) because `buf` will be read by the DMA after `// start transfer` but the compiler
doesn't know that.

To prevent those problematic reorderings we can add [`compiler_fence`]s to both `Serial.write_all`
and `Transfer.wait` such that the inlined code looks like this:

[`compiler_fence`]: https://doc.rust-lang.org/core/sync/atomic/fn.compiler_fence.html

``` rust
let buf = singleton!(_: [u8; 45]).unwrap();

buf.copy_from_slice(b"The quick brown fox jumps over the lazy dog.\n")

// ..

// set destination address
channels.5.cmar().write(|w| w.ma().bits(buf.as_ptr() as u32));

// set transfer size
channels.5.cndtr().write(|w| w.ndt().bits(buf.len()));

// ..

atomic::compiler_fence(Ordering::SeqCst); // <- NEW!

// start transfer
channels.5.ccr().modify(|w| w.cen().set_bit());

let transfer = Transfer { buf, chan: channels.5, payload: serial }

// ..

// wait until the transfer is over
while transfer.chan.ifcr().tcif4().bit_is_clear() {}

atomic::compiler_fence(Ordering::SeqCst); // <- NEW!

let (buf, c5, serial) = (transfer.buf, transfer.chan, transfer.payload);
```

`compiler_fence(Ordering::SeqCst)` prevents the compiler [^2] from reordering any memory operation
across it. With this change `buf.copy_from_slice` can't be moved to after `// start transfer`.

[^2]: Some of you may be wondering if something stronger, like a memory synchronization
    *instruction*, is required here. This implementation is for a single core Cortex-M
    microcontroller. That architecture doesn't reorder memory transactions so a compiler barrier is
    enough; a compiler barrier might not be enough in multi-core Cortex-M systems, though.

`compiler_fence` is a bit of a hammer [^3] in this case because it prevents reordering *any* memory
operation across it, which could hinder some optimizations, but here we only want to prevent memory
operations on `buf` from being reordered across the fence. I don't know if it's possible to give a
more precise hint to the compiler, though. If you know the answer, let me know!

[^3]: I've seen worse, though. I've seen C programs mark whole statically allocated buffers that
    will be used with the DMA as `volatile`. That de-optimizes *all* operations on the buffer; that
    approach can even prevent the compiler from optimizing for loops over the buffer into `memcpy` /
    `memset`.

# Making it generic

DMA based APIs would be a great addition to the [`embedded-hal`] but they need to be free of device
specific details like the channel types and the `Transfer` type. We can rework `Serial.read_exact`
and `Transfer` into device agnostic traits like these:

[`embedded-hal`]: https://github.com/japaric/embedded-hal

``` rust
/// On going DMA transfer
pub trait Transfer {
    type Payload;

    fn is_done(&self) -> bool;
    fn wait(self) -> Self::Payload;
}

/// Read bytes from a serial interface
pub trait ReadExact {
    type T: Transfer<Payload = (Self, &'static mut [u8])>;

    fn read_exact(self, buf: &'static mut [u8]) -> Self::T;
}
```

An implementation of those traits could look like this:

``` rust
pub struct DmaSerialTransfer {
    // `Transfer` is the implementation from before
    transfer: Transfer<dma1::Channel4, Serial>,
}

impl hal::Transfer for DmaSerialTransfer {
    fn is_done(&self) -> bool {
        self.transfer.is_done()
    }

    fn wait(self) -> (DmaSerial, &'static mut [u8]) {
        let (buf, chan, serial) = self.transfer.wait();

        (DmaSerial { serial, chan }, buf)
    }
}

/// DMA enabled serial interface
pub struct DmaSerial { serial: Serial, chan: dma1::Channel4 }

impl hal::ReadExact for DmaSerial {
    type T = DmaSerialTransfer;

    fn read_exact(self, buf: &'static mut [u8]) -> DmaSerialTransfer {
        // `_read_exact` is the implementation frome before
        let transfer = self.serial._read_exact(self.chan, buf);
        DmaSerialTransfer { transfer }
    }
}

impl Serial {
    /// Enable DMA functionality
    pub fn with_dma(self, chan: dma1::Channel4) -> DmaSerial {
        DmaSerial { serial: self, chan }
    }
}
```

## Futures?

Some of you have probably noticed that the `Transfer` trait is similar to the [`Future`] trait. Why
not use the `Future` trait instead? Well, I'm not a fan of the panicky `poll` interface so I'd
rather not *force* the caller to use it since you can easily write an adapter to turn a `Transfer`
implementer into a `Future`. See below:

[`Future`]: https://docs.rs/futures/0.1.18/futures/future/trait.Future.html

``` rust
struct FutureTransfer<T>
where
    T: Transfer,
{
    transfer: Option<T>,
}

// omitted: constructor

impl<T> Future for FutureTransfer<T>
where
    T: Transfer,
{
    type Item = T::Payload;
    // (at this point you probably have noticed that, for simplicity, I've
    //  omitted error handling in the `Transfer` API)
    type Error = !;

    fn poll(&mut self) -> Poll<T::Payload, !> {
        if self.transfer
            .as_ref()
            .expect("FutureTransfer polled beyond completion") // may `panic!`
            .is_done()
        {
            let payload = self.transfer.take().unwrap().wait();
            Ok(Async::Ready(payload))
        } else {
            Ok(Async::NotReady)
        }
    }
}
```

---

That's my take on memory safe DMA based APIs. If you have come up with a different solution let me
know!

I have [proposed] exploring this approach to DMA based APIs in the `embedded-hal` repo. If you
implement or run into problems trying to implement these APIs leave a comment over there! You can
use my implementation of these APIs  in the [`stm32f103xx-hal`] crate as a reference. Unfortunately,
the APIs in that crate are pretty much undocumented but at least there are some (also undocumented)
examples.

[proposed]: https://github.com/japaric/embedded-hal/issues/36
[`stm32f103xx-hal`]: https://github.com/japaric/stm32f103xx-hal

I've also sketched an API for circular DMA transfers, which I have not included in this blog post,
but I'm going to revisit the API to accommodate a [use case] raised by a user. I might do a small
blog post about that once that API is more fleshed out.

[use case]: https://github.com/japaric/stm32f103xx-hal/issues/48

Until next time.

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
and 45 more people for [supporting my work on Patreon][Patreon].

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

<!-- [reddit]:  -->

Enjoyed this post? Like my work on embedded stuff? Consider supporting my work
on [Patreon]!

[Patreon]: https://www.patreon.com/japaric

Follow me on [twitter] for even more embedded stuff.

[twitter]: https://twitter.com/japaricious

The embedded Rust community gathers on the #rust-embedded IRC channel
(irc.mozilla.org). Join us!
