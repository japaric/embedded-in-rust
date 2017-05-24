+++
author = "Jorge Aparicio"
date = "2017-05-23T09:33:23-05:00"
description = "We'll analyze the overhead of the RTFM framework"
draft = false
tags = ["ARM Cortex-M", "rtfm", "analysis"]
title = "Overhead analysis of the RTFM framework"
+++

---

In the [last post] I introduced the RTFM framework, and made several claims
about it being highly efficient both in memory usage and runtime overhead. In
this post I'll analyze all the RTFM concurrency primitives to back up those
claims. To do that I'll first introduce a *non-invasive* timing method that's
accurate to a single clock cycle, which is the time the processor spends to
execute one of the simplest instructions.

[last post]: /fearless-concurrency

Let's dive in.

> **NB** All the measurements shown in this post have been performed on a Cortex
> M3 microcontroller (STM32F100RBT6B) running at 8 MHz with zero Flash memory
> wait states.

# The timing method

## DWT and CYCCNT

Cortex-M processors provide plenty of functionality for debugging and profiling
programs in the form of *core* peripherals. One such peripheral is the Data
Watchpoint and Trace (DWT) peripheral. This peripheral includes a *cycle
counter* that counts every single *core* clock cycle. The core clock is the one
driving the processor; its frequency is the processor frequency. This counter
only makes progress when the processor is running; IOW, the counter will stop
when, for example, the debugger halts the processor. The count of this cycle
counter is available through the 32-bit CYCCNT register of the DWT peripheral.

How can we use this counter to measure the runtime of routines?

## The obvious approach

Let's say that we want to measure how many clock cycles it takes to execute a
NOP (No OPeration) instruction. Let's start by writing a task that executes only
that instruction:

``` rust
use cortex_m::asm;

fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {
    asm::nop();
}
```

This is the disassembly of the task when the program is compiled in release
mode:

``` armasm
0800032e <overhead::main::INTERRUPTS::t1>:
 800032e:	bf00      	nop
 8000330:	4770      	bx	lr
```

The obvious approach to time this NOP is to use [the `std` approach]. As long as
we don't modify the CYCCNT register the cycle counter will effectively be a
monotonically increasing timer. So, we can take a snapshot of CYCCNT before and
after the NOP instruction; the difference between those two values will be the
number of clock cycles spent executing the NOP instruction (*spoilers* well, not
exactly).

[the `std` approach]: https://doc.rust-lang.org/std/time/struct.Instant.html#method.elapsed

Here's a program that does that:

``` rust
fn init(ref prio: P0, thr: TMax) {
    // NB the cycle counter is disabled by default
    let dwt = DWT.access(prio, thr);
    dwt.enable_cycle_counter();
}

fn t1(_task: Exti0Irq, ref prio: P1, ref thr: T1) {
    let dwt = DWT.access(prio, thr);

    let before = dwt.cyccnt.read();
    asm::nop();
    let after = dwt.cyccnt.read();

    let elapsed = after.wrapping_sub(before);

    // volatile magic to prevent LLVM from optimizing away `elapsed`'s value
    unsafe { ptr::write_volatile(0x2000_0000 as *mut _, elapsed) }

    rtfm::bkpt();
}
```

(The full code of this program is in the [appendix](#appendix). We'll perform
several modifications to this program during the rest of this post.)

This program will store the difference of the CYCCNT snapshots at address
`0x2000_0000`. Let's debug the program and inspect that address.

```
$ arm-none-eabi-gdb target/thumbv7m-none-eabi/release/(..)
(..)
> continue
66          rtfm::bkpt();

> x 0x20000000
0x20000000:     0x00000002
```

The result, according to the measurement, is 2 clock cycles. That is *not* the
number of clock cycles spent executing the NOP instruction because that number
also includes the time spent reading the CYCCNT register. The correct answer is
actually 1 clock cycle; the other cycle was spent reading the register.

This method is rather invasive: it heavily changes the original program and
makes use of processor registers that weren't being used before. Look at the
disassembly:

``` armasm
0800032e <overhead::main::INTERRUPTS::t1>:
 800032e:	f241 0004 	movw	r0, #4100	; 0x1004
 8000332:	f2ce 0000 	movt	r0, #57344	; 0xe000
 8000336:	6801      	ldr	r1, [r0, #0]	; read CYCCNT
 8000338:	bf00      	nop
 800033a:	6800      	ldr	r0, [r0, #0]	; read CYCCNT
 800033c:	1a40      	subs	r0, r0, r1
 800033e:	f04f 5100 	mov.w	r1, #536870912	; 0x20000000
 8000342:	6008      	str	r0, [r1, #0]
 8000344:	be00      	bkpt	0x0000
 8000346:	4770      	bx	lr
```

We can do much better than that.

## A better approach

Instead of reading the CYCCNT register in the program itself we can use GDB to
read the register. With this approach no processor register has to be used. This
approach can also be used in an *interactive* debug session since the cycle
counter will pause its count when the processor is halted.

Let's revise the program to use this new approach:

``` rust
fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {
    rtfm::bkpt(); // read CYCCNT in GDB
    asm::nop();
    rtfm::bkpt(); // read CYCCNT in GDB
}
```

The disassembly now looks very similar to the original program's:

``` armasm
0800032e <overhead::main::INTERRUPTS::t1>:
 800032e:	be00      	bkpt	0x0000		; read CYCCNT
 8000330:	bf00      	nop
 8000332:	be00      	bkpt	0x0000		; read CYCCNT
 8000334:	4770      	bx	lr
```

The CYCCNT register is located at address `0xe000_1004`; this location is the
same regardless of the microcontroller. Let's debug this new program and inspect
that address.

``` console
> continue
> info registers pc
pc             0x800032e        0x800032e <overhead::main::INTERRUPTS::t1>

> x 0xe0001004
0xe0001004:     0x0074e9dc

> continue
> info registers pc
pc             0x8000332        0x8000332 <overhead::main::INTERRUPTS::t1+4>

> x 0xe0001004
0xe0001004:     0x0074e9dd

> print 0x0074e9dd - 0x0074e9dc
$1 = 1
```

This time the measurement returns the correct answer: Executing NOP took a
single clock cycle.

Armed with a proper timing method we can go ahead and start measuring the
runtime overhead of the different RTFM primitives.

# Tasks

Under the RTFM framework a program is split in tasks; tasks are the unit of
concurrency in the RTFM framework. Tasks are usually triggered by events, but
their execution can be manually requested as well. Each task is assigned a
priority that indicates its urgency. Let's analyze them first.

## Scheduling

The RTFM scheduler is a tickless fully preemptive *task* scheduler. The
scheduler decides which task to execute next depending on its priority: higher
priority tasks are more urgent and have to be completed first so those tasks can
preempt lower priority ones.

In the Cortex-M implementation of the RTFM framework tasks *are* interrupts and
the Nested Vectored Interrupt Controller ([NVIC]) is used as the task scheduler.
The NVIC takes care of servicing interrupts: that is of launching interrupts
handlers (tasks) as events arrive, and also of scheduling the execution of
handlers (tasks) according to their priorities. Because RTFM leverages the NVIC
no task bookkeeping is done in the program; the NVIC takes care of doing all
the scheduling.

[NVIC]: http://infocenter.arm.com/help/index.jsp?topic=/com.arm.doc.dui0552a/CIHIGCIF.html

IOW, the scheduling overhead is effectively zero. The NVIC, which is hardware
independent of the processor, will take care of scheduling tasks, that is of
deciding which task must be executed next, freeing the core processor from doing
the job.

> The scheduling overhead is zero

## Context switching

Context switches do use processor time so let's measure their cost.

### Preemption

We'll start measuring the context switching cost of going from a lower priority
task to a higher priority task.

This is the code we'll use to measure the context switching cost:

``` rust
fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {
    rtfm::bkpt();

    // task `t2` will preempt this task
    rtfm::request(t2);

    rtfm::bkpt();
}

fn t2(_task: Exti1Irq, _prio: P2, _thr: T2) {
    rtfm::bkpt();
}
```

The disassembly is shown below:

``` armasm
08000324 <overhead::main::INTERRUPTS::t1>:
 8000324:	f24e 2000 	movw	r0, #57856	; 0xe200
 8000328:	2180      	movs	r1, #128	; 0x80
 800032a:	be00      	bkpt	0x0000
 800032c:	f2ce 0000 	movt	r0, #57344	; 0xe000
 8000330:	6001      	str	r1, [r0, #0]	; read CYCCNT
 8000332:	be00      	bkpt	0x0000		; read CYCCNT
 8000334:	4770      	bx	lr

08000336 <overhead::main::INTERRUPTS::t2>:
 8000336:	be00      	bkpt	0x0000		; read CYCCNT
 8000338:	4770      	bx	lr
```

The disassembly contains comments that indicate the points where the CYCCNT
register will be read. The debug session of running this code is shown below:

``` console
> continue
> stepi
> # PC = 0x08000330, (CYCCNT & 0xff) = 0x3a

> continue
> # PC = 0x08000336, (CYCCNT & 0xff) = 0x45

> continue
> # pc = 0x08000332, (CYCCNT & 0xff) = 0x4f

> print 0x45 - 0x3a
$1 = 11

> print 0x4f - 0x45
$2 = 10
```

The first difference is 11 cycles; this is the time spent switching from the
lower priority task to the higher priority one. In the ARM documentation this
switching time is known as interrupt latency [^latency], the latency between the
interrupt signal arrival and the execution of the interrupt handler.

[^latency]: The [technical reference manual][trm] (*warning* big PDF file),
    in figure 5-2, indicates a worst case scenario of 12 cycles for the
    interrupt latency.

[trm]: http://infocenter.arm.com/help/topic/com.arm.doc.ddi0337e/DDI0337E_cortex_m3_r1p1_trm.pdf

The second difference is 10 cycles; this is the time spent switching from the
higher priority task back to the lower priority one. So the total context
switching cost is the sum: 21 cycles.

> Interrupt latency = 11 cycles

> Context switching cost (preemption) = 21 cycles

#### Extra register stacking

In the previous measurement the higher priority task was an empty function, and
didn't make use of any register. The context switching cost will increase if the
higher priority task uses more than 5 registers because registers #6 and higher
won't be automatically saved and restored by the NVIC, so extra instructions are
needed to do that. Those extra instructions will be automatically inserted by
the compiler as the *prologue* of the task function. We need to consider the
time spent executing the prologue as part of the context switching cost because
the prologue will be executed before the task code we wrote is executed.

We can force the task `t2` to use more than 5 registers with some assembly:

``` rust
fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {
    rtfm::bkpt();

    // task `t2` will preempt this task
    rtfm::request(t2);

    rtfm::bkpt();
}

fn t2(_task: Exti1Irq, _prio: P1, _thr: T1) {
    // load values from 0 to 5 into 6 registers
    unsafe {
        asm!("" :: "r"(0) "r"(1) "r"(2) "r"(3) "r"(4) "r"(5) :: "volatile");
    }

    rtfm::bkpt();
}
```

The disassembly of the above code is shown below:

``` armasm
08000324 <overhead::main::INTERRUPTS::t1>:
 8000324:	f24e 2000 	movw	r0, #57856	; 0xe200
 8000328:	2180      	movs	r1, #128	; 0x80
 800032a:	be00      	bkpt	0x0000
 800032c:	f2ce 0000 	movt	r0, #57344	; 0xe000
 8000330:	6001      	str	r1, [r0, #0]	; read CYCCNT
 8000332:	be00      	bkpt	0x0000		; read CYCCNT
 8000334:	4770      	bx	lr

08000336 <overhead::main::INTERRUPTS::t2>:
 8000336:	b580      	push	{r7, lr}
 8000338:	466f      	mov	r7, sp
 800033a:	f04f 0c00 	mov.w	ip, #0		; read CYCCNT
 800033e:	f04f 0e01 	mov.w	lr, #1
 8000342:	2202      	movs	r2, #2
 8000344:	2303      	movs	r3, #3
 8000346:	2004      	movs	r0, #4
 8000348:	2105      	movs	r1, #5
 800034a:	be00      	bkpt	0x0000		; read CYCCNT
 800034c:	bd80      	pop	{r7, pc}
```

The `push` and the following `mov` instructions at address `0x08000336` are the
prologue of the function `t2`. For the measurement we'll read the CYCCNT
register *after* the prologue of `t2` has been executed as indicated in the
comments of the disassembly.

The debug session is shown bellow:

``` console
> continue
> stepi
> # PC = 0x08000330, (CYCCNT & 0xff) = 0xd4

> break overhead::main::INTERRUPTS::t2
> continue
> # PC = 0x0800033a, (CYCCNT & 0xff) = 0xe3

> continue
> # PC = 0x0800034a, (CYCCNT & 0xff) = 0xe9

> continue
> # PC = 0x08000332, (CYCCNT & 0xff) = 0xf6

> print 0xe3 - 0xd4
$1 = 15

> print 0xf6 - 0xe9
$2 = 13
```

The interrupt latency increases to 15 cycles and the total switching cost
increases to 28 cycles. Let's update our numbers:

> Interrupt latency = 11-15 cycles

> Context switching cost (preemption) = 21-28 cycles

#### vs function calls

Task preemption looks very similar to function calls except that is the
NVIC, and not the user, who calls the tasks. Let's see how the runtime cost of
preemption compares to the runtime cost of doing a function call.

Consider the following program:

``` rust
fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {
    rtfm::bkpt();

    foo();

    rtfm::bkpt();
}

#[inline(never)]
fn foo() {
    rtfm::bkpt();
}
```

With disassembly:

``` armasm
0800032e <overhead::foo>:
 800032e:	be00      	bkpt	0x0000		; read CYCCNT
 8000330:	4770      	bx	lr

08000332 <overhead::main::INTERRUPTS::t1>:
 8000332:	b580      	push	{r7, lr}
 8000334:	466f      	mov	r7, sp
 8000336:	be00      	bkpt	0x0000		; read CYCCNT
 8000338:	f7ff fff9 	bl	800032e <overhead::foo>
 800033c:	be00      	bkpt	0x0000		; read CYCCNT
 800033e:	bd80      	pop	{r7, pc}
```

The debug session reports 4 cycles of overhead:

```
> continue
> # PC = 0x08000336, (CYCCNT & 0xff) = 0x70

> continue
> # PC = 0x0800032e, (CYCCNT & 0xff) = 0x72

> continue
> # PC = 0x0800033c, (CYCCNT & 0xff) = 0x74

> print 0x74 - 0x70
$1 = 4
```

Like before we can repeat the measurement but changing `foo` to use more than 5
registers.

Here's the revised program:

``` rust
fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {
    rtfm::bkpt();

    foo();

    rtfm::bkpt();
}

#[inline(never)]
fn foo() {
    unsafe {
        asm!("" :: "r"(0) "r"(1) "r"(2) "r"(3) "r"(4) "r"(5) :: "volatile");
    }

    rtfm::bkpt();
}
```

Disassembly:

``` armasm
0800032e <overhead::foo>:
 800032e:	b580      	push	{r7, lr}
 8000330:	466f      	mov	r7, sp
 8000332:	f04f 0c00 	mov.w	ip, #0		; read CYCCNT
 8000336:	f04f 0e01 	mov.w	lr, #1
 800033a:	2202      	movs	r2, #2
 800033c:	2303      	movs	r3, #3
 800033e:	2004      	movs	r0, #4
 8000340:	2105      	movs	r1, #5
 8000342:	be00      	bkpt	0x0000		; read CYCCNT
 8000344:	bd80      	pop	{r7, pc}

08000346 <overhead::main::INTERRUPTS::t1>:
 8000346:	b580      	push	{r7, lr}
 8000348:	466f      	mov	r7, sp
 800034a:	be00      	bkpt	0x0000		; read CYCCNT
 800034c:	f7ff ffef 	bl	800032e <overhead::foo>
 8000350:	be00      	bkpt	0x0000		; read CYCCNT
 8000352:	bd80      	pop	{r7, pc}
```

And the interactive session reports 12 cycles of overhead:

``` console
> continue
> # PC = 0x0800034a, (CYCCNT & 0xff) = 0x56

> break overhead::foo
> continue
> # PC = 0x08000332, (CYCCNT & 0xff) = 0x5c

> continue
> # PC = 0x08000342, (CYCCNT & 0xff) = 0x62

> continue
> # PC = 0x08000350, (CYCCNT & 0xff) = 0x68

> print (0x5c - 0x56) + (0x68 - 0x62)
$1 = 12
```

In conclusion,

> Function call cost = 4-12 cycles

So context switching due to preemption is about 2x slower than function calls.

### Tail chaining

Another case that we need to analyze is when an event arrives during the
execution of a task but there's no preemption. The following program showcases
that scenario:

``` rust
fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {
    // no preemption (tasks have the same priority)
    rtfm::request(t2);

    rtfm::bkpt();
}

fn t2(_task: Exti1Irq, _prio: P1, _thr: T1) {
    rtfm::bkpt();
}
```

As both tasks have the same priority no preemption occurs: task `t2` will be
executed *after* task `t1` ends. This is known as tail chaining because the
context will switch from `t1` to `t2` without returning to `idle`.

Disassembly below:

``` armasm
08000324 <overhead::main::INTERRUPTS::t1>:
 8000324:	f24e 2000 	movw	r0, #57856	; 0xe200
 8000328:	2180      	movs	r1, #128	; 0x80
 800032a:	f2ce 0000 	movt	r0, #57344	; 0xe000
 800032e:	6001      	str	r1, [r0, #0]
 8000330:	be00      	bkpt	0x0000		; read CYCCNT
 8000332:	4770      	bx	lr

08000334 <overhead::main::INTERRUPTS::t2>:
 8000334:	be00      	bkpt	0x0000		; read CYCCNT
 8000336:	4770      	bx	lr
```

Debug session:

```
> continue
> # PC = 0x08000330, CYCCNT = 0x54

> continue
> # PC = 0x08000334, CYCCNT = 0x5a

> print 0x5a - 0x54
$1 = 6
```

The cost of this kind of context switch is 6 cycles.

Let's measure again but changing `t2` to use more than 5 registers.

Revised program:

``` rust
fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {
    rtfm::request(t2);

    rtfm::bkpt();
}

fn t2(_task: Exti1Irq, _prio: P1, _thr: T1) {
    unsafe {
        asm!("" :: "r"(0) "r"(1) "r"(2) "r"(3) "r"(4) "r"(5) :: "volatile");
    }
}
```

Disassembly:

``` armasm
08000324 <overhead::main::INTERRUPTS::t1>:
 8000324:	f24e 2000 	movw	r0, #57856	; 0xe200
 8000328:	2180      	movs	r1, #128	; 0x80
 800032a:	f2ce 0000 	movt	r0, #57344	; 0xe000
 800032e:	6001      	str	r1, [r0, #0]
 8000330:	be00      	bkpt	0x0000		; read CYCCNT
 8000332:	4770      	bx	lr

08000334 <overhead::main::INTERRUPTS::t2>:
 8000334:	b580      	push	{r7, lr}
 8000336:	466f      	mov	r7, sp
 8000338:	f04f 0c00 	mov.w	ip, #0		; read CYCCNT
 800033c:	f04f 0e01 	mov.w	lr, #1
 8000340:	2202      	movs	r2, #2
 8000342:	2303      	movs	r3, #3
 8000344:	2004      	movs	r0, #4
 8000346:	2105      	movs	r1, #5
 8000348:	bd80      	pop	{r7, pc}
```

Debug session:

``` console
> continue
> # PC = 0x08000330, CYCCNT = 0x50

> break overhead::main::INTERRUPTS::t2
> continue
> # PC = 0x08000338, CYCCNT = 0x5a

> print 0x5a - 0x50
$1 = 10
```

10 cycles of overhead in the case where `t2` includes a prologue. In conclusion:

> Context switching cost (tail chaining) = 6-10 cycles

Which is around the overhead of function calls.

## Memory overhead

As the NVIC does all the scheduling the processor doesn't keep track of the
running tasks so there's no memory use on that front. The RTFM framework uses
task priorities in its API, but as priorities remain fixed at runtime they are
tracked in the type system and not stored in memory at runtime. In conclusion:

> Memory overhead per task = 0 bytes of .bss / .data / .heap memory

## Setup cost

There is no memory overhead per task, but there is a small setup cost per task.
Let's take a look at that:

### Zero tasks

Consider the following program with zero tasks:

``` rust
#[inline(never)]
fn init(_prio: P0, _thr: &TMax) {
    // Just to make sure LLVM that doesn't optimize away this function
    rtfm::bkpt();
}

#[inline(never)]
fn idle(_prio: P0, _thr: T0) -> ! {
    // Sleep
    loop {
        rtfm::wfi();
    }
}
```

Both `init` and `idle` have been marked as `inline(never)` to make the analysis
easier. Here's the disassembly of the program:

``` armasm
08000340 <cortex_m_rt::reset_handler>:
 8000340:	b5d0      	push	{r4, r6, r7, lr}
 8000342:	af02      	add	r7, sp, #8
 8000344:	f240 0000 	movw	r0, #0
 8000348:	f240 0100 	movw	r1, #0
 800034c:	f2c2 0000 	movt	r0, #8192	; 0x2000
 8000350:	f2c2 0100 	movt	r1, #8192	; 0x2000
 8000354:	1a09      	subs	r1, r1, r0
 8000356:	f021 0103 	bic.w	r1, r1, #3
 800035a:	f000 f85a 	bl	8000412 <__aeabi_memclr4>
 800035e:	f240 0000 	movw	r0, #0
 8000362:	f240 0100 	movw	r1, #0
 8000366:	f2c2 0000 	movt	r0, #8192	; 0x2000
 800036a:	f2c2 0100 	movt	r1, #8192	; 0x2000
 800036e:	1a09      	subs	r1, r1, r0
 8000370:	f021 0203 	bic.w	r2, r1, #3
 8000374:	f240 4124 	movw	r1, #1060	; 0x424
 8000378:	f6c0 0100 	movt	r1, #2048	; 0x800
 800037c:	f000 f83f 	bl	80003fe <__aeabi_memcpy4>
 8000380:	f240 0000 	movw	r0, #0
 8000384:	f2c0 0000 	movt	r0, #0
 8000388:	7800      	ldrb	r0, [r0, #0]
 800038a:	f3ef 8410 	mrs	r4, PRIMASK
 800038e:	b672      	cpsid	i
 8000390:	f7ff ffd2 	bl	8000338 <overhead::init>
 8000394:	f014 0f01 	tst.w	r4, #1
 8000398:	d100      	bne.n	800039c <cortex_m_rt::reset_handler+0x5c>
 800039a:	b662      	cpsie	i
 800039c:	f7ff ffce 	bl	800033c <overhead::idle>
```

`reset_handler` is the entry point of the program. This routine will call the
`init` function and then `idle` function, but before it does that it initializes
RAM as evidenced by the calls to `memclr4` and `memcpy4`. RAM initialization is
required by all programs so we won't count it as part of the overhead of the
RTFM framework.

After RAM initialization `init` will be called within a *global* critical
section (`rtfm::atomic`) hence the `cpsid i` and `cpsie i` instructions around
the call. After `init` returns the critical section ends and `idle` gets called.

### One task

Let's now add one task to the program:

``` rust
#[inline(never)]
fn init(_prio: P0, _thr: &TMax) {
    rtfm::bkpt();
}

#[inline(never)]
fn idle(_prio: P0, _thr: T0) -> ! {
    loop {
        rtfm::wfi();
    }
}

tasks!(stm32f100xx, {
    t1: Task {
        interrupt: Exti0Irq,
        priority: P1,
        enabled: true,
    },
});

fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {}
```

The disassembly of `reset_handler` becomes:

``` armasm
08000338 <cortex_m_rt::reset_handler>:
(..)
 8000386:	b672      	cpsid	i       	; start of critical section
 8000388:	f7ff ffd1 	bl	800032e <overhead::init>
 800038c:	f24e 4006 	movw	r0, #58374	; 0xe406
 8000390:	21f0      	movs	r1, #240	; 0xf0
 8000392:	f014 0f01 	tst.w	r4, #1
 8000396:	f2ce 0000 	movt	r0, #57344	; 0xe000
 800039a:	7001      	strb	r1, [r0, #0]
 800039c:	f24e 1000 	movw	r0, #57600	; 0xe100
 80003a0:	f04f 0140 	mov.w	r1, #64	; 0x40
 80003a4:	f2ce 0000 	movt	r0, #57344	; 0xe000
 80003a8:	6001      	str	r1, [r0, #0]
 80003aa:	d100      	bne.n	80003ae <cortex_m_rt::reset_handler+0x76>
 80003ac:	b662      	cpsie	i   		; end of critical section
 80003ae:	f7ff ffc0 	bl	8000332 <overhead::idle>
```

There's now extra code between the call to `init` and the end of the global
critical section. This extra code takes care of assigning priorities to tasks
(interrupts), and also of enabling the tasks (interrupts) that were declared as
`enabled: true` in the `tasks!` macro.

The RTFM framework doesn't add any extra code to tasks. Only the code you have
written will be executed. Here's the disassembly of the empty task `t1` as a
proof:

``` armasm
0800032e <overhead::main::INTERRUPTS::t1>:
 800032e:	4770      	bx	lr
```

### N tasks

Let's add one more task:

``` rust
tasks!(stm32f100xx, {
    t1: Task {
        interrupt: Exti0Irq,
        priority: P1,
        enabled: true,
    },
    t2: Task {
        interrupt: Exti1Irq,
        priority: P2,
        enabled: true,
    },
});

fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {}

fn t2(_task: Exti1Irq, _prio: P2, _thr: T2) {}
```

With this change the disassembly of `reset_handler` becomes:

``` armasm
08000330 <cortex_m_rt::reset_handler>:
(..)
 800037e:	b672      	cpsid	i   		; start of critical section
 8000380:	f7ff ffd0 	bl	8000324 <overhead::init>
 8000384:	f24e 4006 	movw	r0, #58374	; 0xe406
 8000388:	21f0      	movs	r1, #240	; 0xf0
 800038a:	f014 0f01 	tst.w	r4, #1
 800038e:	f2ce 0000 	movt	r0, #57344	; 0xe000
 8000392:	7001      	strb	r1, [r0, #0]
 8000394:	f04f 01e0 	mov.w	r1, #224	; 0xe0
 8000398:	7041      	strb	r1, [r0, #1]
 800039a:	f24e 1000 	movw	r0, #57600	; 0xe100
 800039e:	f04f 0140 	mov.w	r1, #64	; 0x40
 80003a2:	f2ce 0000 	movt	r0, #57344	; 0xe000
 80003a6:	6001      	str	r1, [r0, #0]
 80003a8:	f04f 0180 	mov.w	r1, #128	; 0x80
 80003ac:	6001      	str	r1, [r0, #0]
 80003ae:	d100      	bne.n	80003b2 <cortex_m_rt::reset_handler+0x82>
 80003b0:	b662      	cpsie	i   		; end of critical section
 80003b2:	f7ff ffb9 	bl	8000328 <overhead::idle>
```

If you keep adding tasks and measure the time that takes to go from the end of
`init` to the start of `idle` you'll find out that the task setup code takes
`O(N)` cycles where `N` is the number of tasks. The exact linear constant
depends on whether all the task have the same priority, or each one has a
different priority but 4 to 6 cycles per task is usual.

> Setup runtime cost = `O(N)` cycles where N = number of tasks

### Shared call stack

How does the RTFM framework makes use of stack memory? How are tasks allocated
on the stack? Let's see what threaded systems do first.

On threaded systems each thread is assigned its own call stack as shown below:

![Multithreaded stack](/rtfm-overhead/threads.svg)

The image depicts three threads: T1, T2 and T3. The stack of each thread can
grow independently so its possible for the stack of one thread to *overflow*
into the stack of the next thread, corrupting it. For this reason each thread is
assigned a *maximum* stack size, depicted in the above figure by the black
boundaries between each thread stack. To enforce these boundaries usually the
Memory Protection Unit (MPU) is used; the MPU can detect stack overflows and
raise an exception when they occur.

The maximum stack size of a thread must be chosen carefully. A large stack size
limits the number of threads that can be running at a given time. For example,
in the above figure only 3 threads fit in memory. OTOH, a small stack size makes
threads more prone to stack overflows.

Under the RTFM framework all tasks *share* a single call stack as shown below:

![RTFM stack](/rtfm-overhead/tasks.svg)

This looks like a compacted version of the multithreaded memory layout.

Under the RTFM scheduler once a high priority task starts its execution all the
other lower priority tasks can't resume execution *until after* the high
priority task is over. Because of this the stacks of *suspended* tasks never
grow so it's not necessary to reserve space for each task. That's why we don't
have this empty space between the stack of each task as in the multithreaded
case.

Although less likely stack overflows are still possible: the shared call stack
can overflow into the heap region. Again, one can use the MPU to protect against
such condition.

So how much stack space does each task use? Let's find out.

Consider the following program:

``` rust
fn idle(_prio: P0, _thr: T0) -> ! {
    rtfm::bkpt();
    rtfm::request(t1);

    // Sleep
    loop {
        rtfm::wfi();
    }
}

fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {
    let x = 42;

    rtfm::bkpt();

    // `t2` will immediately preempt this task
    rtfm::request(t2);

    // Force LLVM to allocate `x` on the stack
    unsafe {
        ptr::read_volatile(&x);
   }
}

fn t2(_task: Exti1Irq, _prio: P2, _thr: T2) {
    let y = 24;

    rtfm::bkpt();

    // Force LLVM to allocate `y` on the stack
    unsafe {
        ptr::read_volatile(&y);
    }
}
```

Disassembly:

``` armasm
08000324 <overhead::main::INTERRUPTS::t1>:
 8000324:	b081      	sub	sp, #4
 8000326:	202a      	movs	r0, #42
 8000328:	2180      	movs	r1, #128
 800032a:	9000      	str	r0, [sp, #0]	; x = 42
 800032c:	f24e 2000 	movw	r0, #57856
 8000330:	be00      	bkpt	0x0000  	; t1's BKPT
 8000332:	f2ce 0000 	movt	r0, #57344
 8000336:	6001      	str	r1, [r0, #0]	; rtfm::request
 8000338:	9800      	ldr	r0, [sp, #0]	; ptr::read_volatile
 800033a:	b001      	add	sp, #4
 800033c:	4770      	bx	lr

0800033e <overhead::main::INTERRUPTS::t2>:
 800033e:	b081      	sub	sp, #4
 8000340:	2018      	movs	r0, #24
 8000342:	9000      	str	r0, [sp, #0]	; y = 24
 8000344:	be00      	bkpt	0x0000  	; t2's BKPT
 8000346:	9800      	ldr	r0, [sp, #0]	; ptr::read_volatile
 8000348:	b001      	add	sp, #4
 800034a:	4770      	bx	lr

0800034c <cortex_m_rt::reset_handler>:
(..)
 80003d6:	b662      	cpsie	i
 80003d8:	f44f 4152 	mov.w	r1, #53760
 80003dc:	be00      	bkpt	0x0000      	; idle's BKPT
 80003de:	f840 c001 	str.w	ip, [r0, r1]	; rtfm::request
 80003e2:	bf30      	wfi
 80003e4:	e7fd      	b.n	80003e2 <cortex_m_rt::reset_handler+0x96>
```

Now let's debug it:

``` console
> continue
> # IDLE: PC = 0x080003dc, SP = 0x20001ff8
```

We hit `idle`'s breakpoint; just before `rtfm::request(t1)` is called. Let's
print the values of some registers at this point. We'll see in a bit why they
are relevant.

```
> info registers r0 r1 r2 r3 r12 lr pc xPSR
r0             0xe0001000
r1             0xd200
r2             0x0
r3             0xd100
r12            0x40
lr             0x800038d
pc             0x80003dc
xPSR           0x61000000
```

We continue the program execution and reach `t1`'s breakpoint.

``` console
> continue
> # T1: PC = 0x08000330, SP = 0x20001fd4
```

At this point `x` has already been allocated on the stack so if we inspect the
stack around the stack pointer (SP) we should see its value:

``` console
> x/12x $sp
0x20001fd4:    (0x0000002a)    [0xe0001000      0x0000d200      0x00000000
0x20001fe4:     0x0000d100      0x00000040      0x0800038d      0x080003e4
0x20001ff4:     0x61000000]     0x20001ff8      0xffffffff      0x00000000
```

> **NB** The parentheses and square brackets were added by me; they are not part
> of GDB's output.

At address `0x20001fd4` we see `(0x0000002a)`; this is the local variable `x`.
Next to that value we see some familiar looking values: `[0xe0001000 ..
0x61000000]`; these values match the output of the `info registers` command
executed before. Those values are, in fact, a snapshot of `idle`'s *state* that
was pushed into the stack by the NVIC. They're there because once `t1` returns
the NVIC will *restore* those values to their corresponding registers to resume
`idle`'s execution.

Here's a snapshot of the same registers at `PC = 0x08000336`:

``` console
> stepi
> # T1: PC = 0x08000336, SP = 0x20001fd4

> info registers r0 r1 r2 r3 r12 lr pc xPSR
r0             0xe000e200
r1             0x80
r2             0x0
r3             0xd100
r12            0x40
lr             0xfffffff9
pc             0x8000336
xPSR           0x21000016
```

These values don't (necessarily) match the ones that are stored in the stack.

Let's now skip to `t2`'s breakpoint:

```
> continue
> # T2: PC = 0x08000344, SP = 0x20001fb0
```

Here's the state of the stack at that point:

```
> x/20x $sp
0x20001fb0:    (0x00000018)    [0x0000002a      0x00000080      0x00000000
0x20001fc0:     0x0000d100      0x00000040      0xfffffff9      0x0800033a
0x20001fd0:     0x21000016]    (0x0000002a)    [0xe0001000      0x0000d200
0x20001fe0:     0x00000000      0x0000d100      0x00000040      0x0800038d
0x20001ff0:     0x080003e4      0x61000000]     0x20001ff8      0xffffffff
```

`(0x00000018)` is the local variable `y`, and `[0x0000002a .. 0x21000016]` is a
snapshot of `t1`'s state. If you are a careful reader then you probably noticed
that not all those values match the output of the last `info register` command.
The difference is due to *when* the registers were stacked: the stacked PC value
is `0x0800033a` and the PC value from the `info register`'s output is
`0x08000336` so the stacking happened *after* the `info register` command was
issued.

Next on the stack is `(0x0000002a)`, `t1`'s `x` value, and finally `[0xe0001000
.. 0x61000000]`, `idle`'s state from before.

So in conclusion to preserve the state of the lower priority task during
preemption at least 8 words of information have to be stored on the stack.
Remember the `push` instruction in function prologues? That instruction pushes
more registers, the ones that are not stacked by default, into the stack. So,
function with prologues use more stack space.

> Stack usage per *suspended* task = at least 8 words (32 bytes)

That's all for the realm of tasks. Let's now move onto the data abstractions.

# Task local data

The task local data abstraction, `Local`, is used to preserve state across the
different runs of a task.

## `Local.borrow`

`Local` provides two methods to access the inner data: `borrow` and
`borrow_mut`. Both methods have zero synchronization overhead as `Local` data is
confined to a single task.

Let's confirm this claim by comparing this program which increases a counter:

``` rust
fn t1(ref mut task: Exti0Irq, _prio: P1, _thr: T1) {
    static COUNTER: Local<u32, Exti0Irq> = Local::new(0);

    let state = COUNTER.borrow_mut(task);
    *state += 1;
}
```

Disassembly:

``` armasm
0800032e <overhead::main::INTERRUPTS::t1>:
 800032e:	f240 0000 	movw	r0, #0
 8000332:	f2c2 0000 	movt	r0, #8192	; 0x2000
 8000336:	6801      	ldr	r1, [r0, #0]
 8000338:	3101      	adds	r1, #1
 800033a:	6001      	str	r1, [r0, #0]
 800033c:	4770      	bx	lr
```

Against its unsynchronized, memory unsafe version shown below:

``` rust
fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {
    static mut COUNTER: u32 = 0;

    unsafe { COUNTER += 1 }
}
```

Disassembly:

``` armasm
0800032e <overhead::main::INTERRUPTS::t1>:
 800032e:	f240 0000 	movw	r0, #0
 8000332:	f2c2 0000 	movt	r0, #8192	; 0x2000
 8000336:	6801      	ldr	r1, [r0, #0]
 8000338:	3101      	adds	r1, #1
 800033a:	6001      	str	r1, [r0, #0]
 800033c:	4770      	bx	lr
```

Both versions produce exactly the same code, but the `Local` version is verified
to be memory safe by the compiler. Note how the `task` token doesn't appear in
the disassembly; as the `task` token is a zero sized type it doesn't exit at
runtime.

## Memory overhead

`Local` is just a newtype over the protected data and imposes no overhead in
terms of memory.

You can confirm that with the following program:

``` rust
fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {
    static L1: Local<(), Exti0Irq> = Local::new(());
    static L2: Local<u8, Exti0Irq> = Local::new(0);
    static L3: Local<u16, Exti0Irq> = Local::new(0);
    static L4: Local<u32, Exti0Irq> = Local::new(0);
    static L5: Local<u64, Exti0Irq> = Local::new(0);

    hprintln!("{}", mem::size_of_val(&L1));
    hprintln!("{}", mem::size_of_val(&L2));
    hprintln!("{}", mem::size_of_val(&L3));
    hprintln!("{}", mem::size_of_val(&L4));
    hprintln!("{}", mem::size_of_val(&L5));
}
```

which prints:

```
$ openocd -f (..)
(..)
0
1
2
4
8
```

## Conclusion

In conclusion the `Local` abstraction is no different than using an unsafe
`static mut` variable in terms of memory usage and the runtime cost of accessing
it. In Rust we call these abstractions *zero cost* abstractions. `Local` is a
zero cost abstraction that makes global variables memory safe by pinning them to
a single task.

# Resources

The RTFM framework provides a `Resource` abstraction that can be used to safely
share data *between* tasks. Let's analyze their overhead.

## `Resource.access`

`Resource` provides an `access` method that grants access to its inner data.
[Some conditions] need to be met for `access` to work; if any of those
conditions is not met then the program doesn't compile. Once the conditions are
met the `access` method, itself, is zero cost.

[Some conditions]: /fearless-concurrency/#the-ceiling-system

Let's confirm that by comparing the counting program ported to use a `Resource`:

``` rust
static COUNTER: Resource<Cell<u32>, C1> = Resource::new(Cell::new(0));

fn t1(_: Exti0, ref prio: P1, ref thr: T1) {
    let counter = COUNTER.access(prio, thr);
    counter.set(counter.get() + 1);
}
```

Disassembly:

``` armasm
0800032e <overhead::main::INTERRUPTS::t1>:
 800032e:	f240 0000 	movw	r0, #0
 8000332:	f2c2 0000 	movt	r0, #8192	; 0x2000
 8000336:	6801      	ldr	r1, [r0, #0]
 8000338:	3101      	adds	r1, #1
 800033a:	6001      	str	r1, [r0, #0]
 800033c:	4770      	bx	lr
```

Against its unsynchronized, memory unsafe version (which we already saw in [the
`Local.borrow` section]):

[the `Local.borrow` section]: #local-borrow

``` rust
fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {
    static mut COUNTER: u32 = 0;

    unsafe { COUNTER += 1 }
}
```

Disassembly:

``` armasm
0800032e <overhead::main::INTERRUPTS::t1>:
 800032e:	f240 0000 	movw	r0, #0
 8000332:	f2c2 0000 	movt	r0, #8192	; 0x2000
 8000336:	6801      	ldr	r1, [r0, #0]
 8000338:	3101      	adds	r1, #1
 800033a:	6001      	str	r1, [r0, #0]
 800033c:	4770      	bx	lr
```

The produced code is exactly the same. Again, the tokens don't exist at runtime.

## `Threshold.raise`

When a resource is accessed by two tasks that have different priorities the
lowest priority task will have to create a critical section using the
`Threshold.raise` method. For the span of this critical section the task's
preemption threshold is temporarily raised to prevent the higher priority task
from preempting the lower priority one. Only within this critical section can
the lower priority task access the resource in a memory safe manner that's free
of data races.

Let's see what's the overhead of a `Threshold.raise` critical section by timing
the following program:

``` rust
static R1: Resource<(), C2> = Resource::new(());

fn t1(_: Exti0, _: P1, thr: T1) {
    rtfm::bkpt(); // before

    thr.raise(
        &R1, |_thr| {
            rtfm::bkpt(); // inside
        }
    );

    rtfm::bkpt(); // after
}
```

Disassembly:

``` armasm
0800032e <overhead::main::INTERRUPTS::t1>:
 800032e:	21e0      	movs	r1, #224	; 0xe0
 8000330:	be00      	bkpt	0x0000		; before
 8000332:	f3ef 8011 	mrs	r0, BASEPRI
 8000336:	f381 8812 	msr	BASEPRI_MAX, r1
 800033a:	be00      	bkpt	0x0000		; inside
 800033c:	f380 8811 	msr	BASEPRI, r0
 8000340:	be00      	bkpt	0x0000		; after
 8000342:	4770      	bx	lr
```

In the disassembly you can see the secret sauce of the RTFM framework: the
[BASEPRI] register. The value of this register *is* the preemption threshold of
the system. The critical section is started by raising the preemption threshold,
using the `msr BASEPRI_MAX` instruction, and then finished by restoring the
previous preemption threshold, using the `msr BASEPRI` instruction.

[BASEPRI]: http://infocenter.arm.com/help/topic/com.arm.doc.dui0552a/CHDBIBGJ.html#BABHCGDA

So how long does it take to enter and exit the critical section?

``` console
> continue
> # PC = 0x08000330, (CYCCNT & 0xff) = 0xdb

> continue
> # PC = 0x0800033a, (CYCCNT & 0xff) = 0xde

> continue
> # PC = 0x08000340, (CYCCNT & 0xff) = 0xdf

> print 0xdf - 0xdb
$1 = 4
```

Entering and leaving the critical section takes only 4 cycles. This overhead is
the same regardless of the number of tasks that get blocked by the critical
section. So, `O(1)` runtime cost.

> Critical section overhead = 4 cycles

### vs `rtfm::atomic`

How does this overhead compare to the overhead of a global [^global] critical
section (`rtfm::atomic`)? Let's find out with this program:

[^global]: Remember that `Threshold.raise` critical sections [are not *global*]
    as they don't block *all* the other tasks; instead they only block tasks
    that could cause data races.

[are not *global*]: /fearless-concurrency/#not-your-typical-critical-section

``` rust
fn t1(_task: Exti0Irq, _prio: P1, ref thr: T1) {
    rtfm::bkpt(); // before

    rtfm::atomic(
        |_| {
            rtfm::bkpt(); // inside
        }
    );

    rtfm::bkpt(); // after
}
```

Here's the disassembly of the program:

``` armasm
0800032e <overhead::main::INTERRUPTS::t1>:
 800032e:	be00      	bkpt	0x0000		; before
 8000330:	f3ef 8010 	mrs	r0, PRIMASK
 8000334:	b672      	cpsid	i
 8000336:	be00      	bkpt	0x0000		; inside
 8000338:	f010 0f01 	tst.w	r0, #1
 800033c:	d100      	bne.n	8000340 <overhead::main::INTERRUPTS::t1+0x12>
 800033e:	b662      	cpsie	i
 8000340:	be00      	bkpt	0x0000		; after
 8000342:	4770      	bx	lr
```

Global critical sections use the [PRIMASK] register to block all tasks. The
critical section is started by disabling all the tasks, using the `cpsid i`
instruction (sets PRIMASK to 1), and finished by re-enabling them, using the
`cpsie i` instruction (sets PRIMASK to 0). There's a catch here: if the tasks
were already disabled *before* the critical section started then they should
*not* be re-enabled when the critical section ends -- if you were wondering:
this situation occurs when `rtfm::atomic` sections are nested. This is why
PRIMASK is read before starting the critical section: to check whether the
tasks were already disabled or not.

[PRIMASK]: http://infocenter.arm.com/help/topic/com.arm.doc.dui0552a/CHDBIBGJ.html#BABBBGEA

How do critical sections fare in terms of runtime overhead?

``` console
> continue
> # PC = 0x0800032e, (CYCCNT & 0xff) = 0xe7

> continue
> # PC = 0x08000336, (CYCCNT & 0xff) = 0xea

> continue
> # PC = 0x08000340, (CYCCNT & 0xff) = 0xed

> print 0xed - 0xe7
$1 = 6
```

Entering and leaving a global critical section takes 6 cycles; this is slower
than the `Threshold.raise` critical section!

In conclusion RTFM style critical sections not only [impose less task blocking]
than *global* critical sections; they also have a lower runtime overhead.

[impose less task blocking]: /fearless-concurrency/#not-your-typical-critical-section

## Memory overhead

Resources have zero memory overhead. Like `Local`, `Resource` is just a newtype
over the protected data. The ceiling of each resource is fixed, and it's tracked
in the type system so it's not stored in memory at runtime.

You can confirm that with the following program:

``` rust
static R1: Resource<(), C1> = Resource::new(());
static R2: Resource<u8, C1> = Resource::new(0);
static R3: Resource<u16, C1> = Resource::new(0);
static R4: Resource<u32, C1> = Resource::new(0);
static R5: Resource<u64, C1> = Resource::new(0);

fn t1(_task: Exti0Irq, _prio: P1, _thr: T1) {
    hprintln!("{}", mem::size_of_val(&R1));
    hprintln!("{}", mem::size_of_val(&R2));
    hprintln!("{}", mem::size_of_val(&R3));
    hprintln!("{}", mem::size_of_val(&R4));
    hprintln!("{}", mem::size_of_val(&R5));
}
```

which prints:

```
$ openocd -f (..)
(..)
0
1
2
4
8
```

## A nonzero cost pattern

There is catch with resources: they don't hand out mutable references (`&mut-`)
to their inner data, only shared references. To achieve mutation through shared
references either a `Cell` or a `RefCell` must be used. If you are dealing with
primitives like `i32` and `bool` then `Cell` gives you a zero cost way to mutate
the data, but anything more complex that requires mutation via `&mut self` will
require a `RefCell`. The problem with `RefCell`s is that they have obligatory
runtime checks to enforce that [Rust borrowing rules] are preserved.

[Rust borrowing rules]: https://doc.rust-lang.org/nightly/book/second-edition/ch04-02-references-and-borrowing.html#the-rules-of-references

### `access_mut`?

From the POV of concurrency if a task meets the conditions to `access` a
resource then it *has* exclusive access to that resource as no other task can
preempt it *and* access the same resource. So, from the POV of concurrency
`access` returning a mutable reference is perfectly valid. However, `access`
returning a mutable reference doesn't sit well with Rust borrowing rules:
mutable aliasing *is* a problem even within a single thread / context / task as
it can lead to pointer invalidation [^1] [^2].

[^1]: http://manishearth.github.io/blog/2015/05/17/the-problem-with-shared-mutability/
[^2]: http://smallcultfollowing.com/babysteps/blog/2013/06/11/on-the-connection-between-memory-management-and-data-race-freedom/

The task local data abstraction faces the same situation, but `Local` does
provide a *safe* `borrow_mut` method that hands out mutable references. Why is
that method safe? Because of its signature:

``` rust
impl<DATA, TASK> Local<DATA, TASK> {
    pub fn borrow_mut<'task>(
        &'static self,
        _task: &'task mut TASK,
    ) -> &'task mut DATA {
        ..
    }
}
```

`borrow_mut` takes a mutable reference to the task token; this *freezes* the
task token making it impossible to use `borrow_mut` for as long as the returned
mutable reference is in scope. This does prevent mutable aliasing as shown
below:

``` rust
fn t1(ref mut task: Exti0Irq, _prio: P1, _thr: T1) {
    static STATE: Local<i32, Exti0Irq> = Local::new(0);

    let state: &mut i32 = STATE.borrow_mut(task);
    let aliased_state: &mut i32 = STATE.borrow_mut(task);
    //~^ error: cannot borrow `*task` as mutable more than once at a time
}
```

However this safety mechanism is also rather restrictive because you can't
mutably borrow two *different* resources within the same scope:

``` rust
fn t1(ref mut task: Exti0Irq, _prio: P1, _thr: T1) {
    static A: Local<i32, Exti0Irq> = Local::new(0);
    static B: Local<i32, Exti0Irq> = Local::new(0);

    // this is valid and safe but ...
    let a: &mut i32 = A.borrow_mut(task);
    let b: &mut i32 = B.borrow_mut(task);
    //~^ error: cannot borrow `*task` as mutable more than once at a time

    *a += 1;
    *b += 2;
}
```

This can, somehow, be worked around by minimizing the spans of the mutable
borrows as shown below:

``` rust
fn t1(ref mut task: Exti0Irq, _prio: P1, _thr: T1) {
    static A: Local<i32, Exti0Irq> = Local::new(0);
    static B: Local<i32, Exti0Irq> = Local::new(0);

    *A.borrow_mut(task) += 1;
    *B.borrow_mut(task) += 2;
}
```

But this workaround is rather unergonomic, and doesn't work when you need to
pass two mutable references to a function / method.

``` rust
fn t1(ref mut task: Exti0Irq, _prio: P1, _thr: T1) {
    static A: Local<i32, Exti0Irq> = Local::new(0);
    static B: Local<i32, Exti0Irq> = Local::new(0);

    mem::swap(A.borrow_mut(task), B.borrow_mut(task));
    //~^ error: cannot borrow `*task` as mutable more than once at a time
}
```

So can we add an `access_mut` method to `Resource` that behaves like
`Local.borrow_mut`? Turns out making the lifetime constraints work out is tricky
because the `access` takes two arguments and already has lifetime constraint wrt
to the threshold token. It's also likely that `access_mut` will hit the borrow
restrictions shown above much more often that in the `Local` case so I'm not
sure if `access_mut` will actually help or rather only cause more frustration
[^rfc].

[^rfc]: You can find more details about `access_mut` in [this thread]
[this thread]: https://github.com/japaric/cortex-m-rtfm/issues/24

### `RefCell` overhead

Until we find a proper solution to the borrow restriction we have to use
`RefCell`s but how much overhead do they impose over the ideal solution that has
no runtime checks? Let's check with this program:

``` rust
static COUNTER: Resource<RefCell<u32>, C1> = Resource::new(RefCell::new(0));

fn t1(_task: Exti0Irq, ref prio: P1, ref thr: T1) {
    rtfm::bkpt();

    let counter = COUNTER.access(prio, thr);
    *counter.borrow_mut() += 1;

    rtfm::bkpt();
}
```

This is our running example of increasing a counter. Here's the disassembly of
the `RefCell` version:

``` armasm
08000336 <overhead::main::INTERRUPTS::t1>:
 8000336:	f240 0000 	movw	r0, #0
 800033a:	be00      	bkpt	0x0000
 800033c:	f2c2 0000 	movt	r0, #8192	; 0x2000
 8000340:	6801      	ldr	r1, [r0, #0]
 8000342:	b931      	cbnz	r1, 8000352 <overhead::main::INTERRUPTS::t1+0x1c>
 8000344:	6841      	ldr	r1, [r0, #4]
 8000346:	2200      	movs	r2, #0
 8000348:	3101      	adds	r1, #1
 800034a:	e9c0 2100 	strd	r2, r1, [r0]
 800034e:	be00      	bkpt	0x0000
 8000350:	4770      	bx	lr
 8000352:	b580      	push	{r7, lr}
 8000354:	466f      	mov	r7, sp
 8000356:	f7ff feeb 	bl	8000130 <core::result::unwrap_failed>
```

And the runtime cost is 12 cycles.

``` console
> continue
> # PC = 0x0800033a, (CYCCNT & 0xff) = 0xb9

> continue
> # PC = 0x0800034e, (CYCCNT & 0xff) = 0xc5

> print 0xc5 - 0xb9
$1 = 12
```

Remember that we measured the `Cell` version and the unsafe `static mut` version
of this example before and they both took 6 cycles. So is the overhead a fixed
cost of 6 cycles? Let's confirm with another program:

``` rust
static COUNTER: Resource<RefCell<()>, C1> = Resource::new(RefCell::new(()));

fn t1(_task: Exti0Irq, ref prio: P1, ref thr: T1) {
    rtfm::bkpt();

    let counter = COUNTER.access(prio, thr);
    counter.borrow_mut();

    rtfm::bkpt();
}
```

Disassembly:

``` armasm
08000336 <overhead::main::INTERRUPTS::t1>:
 8000336:	f240 0000 	movw	r0, #0
 800033a:	be00      	bkpt	0x0000
 800033c:	f2c2 0000 	movt	r0, #8192	; 0x2000
 8000340:	6801      	ldr	r1, [r0, #0]
 8000342:	b919      	cbnz	r1, 800034c <overhead::main::INTERRUPTS::t1+0x16>
 8000344:	2100      	movs	r1, #0
 8000346:	6001      	str	r1, [r0, #0]
 8000348:	be00      	bkpt	0x0000
 800034a:	4770      	bx	lr
 800034c:	b580      	push	{r7, lr}
 800034e:	466f      	mov	r7, sp
 8000350:	f7ff feee 	bl	8000130 <core::result::unwrap_failed>
```

Debug session:

``` console
> continue
> # PC = 0x0800033a, (CYCCNT & 0xff) = 0x93

> continue
> # PC = 0x08000348, (CYCCNT & 0xff) = 0x9a

> print 0x9a - 0x93
$1 = 7
```

The measurement says 7 cycles of overhead for doing a no-op `borrow_mut()`. So
around 6 or 7 cycles seems to be the overhead of using `RefCell.borrow_mut`.

The worst part of `RefCell`s is that they inhibit optimizations. If we rewrite
our program like this:

``` rust
static COUNTER: Resource<RefCell<u32>, C1> = Resource::new(RefCell::new(0));

fn t1(_task: Exti0Irq, ref prio: P1, ref thr: T1) {
    rtfm::bkpt();

    let counter = COUNTER.access(prio, thr);
    let curr = *counter.borrow();
    *counter.borrow_mut() = curr + 1;

    rtfm::bkpt();
}
```

We get a much worse disassembly:

``` armasm
0800033e <overhead::main::INTERRUPTS::t1>:
 800033e:	b580      	push	{r7, lr}
 8000340:	466f      	mov	r7, sp
 8000342:	f240 0000 	movw	r0, #0
 8000346:	be00      	bkpt	0x0000
 8000348:	f2c2 0000 	movt	r0, #8192	; 0x2000
 800034c:	6801      	ldr	r1, [r0, #0]
 800034e:	b931      	cbnz	r1, 800035e <overhead::main::INTERRUPTS::t1+0x20>
 8000350:	6841      	ldr	r1, [r0, #4]
 8000352:	2200      	movs	r2, #0
 8000354:	3101      	adds	r1, #1
 8000356:	e9c0 2100 	strd	r2, r1, [r0]
 800035a:	be00      	bkpt	0x0000
 800035c:	bd80      	pop	{r7, pc}
 800035e:	1c48      	adds	r0, r1, #1
 8000360:	d101      	bne.n	8000366 <overhead::main::INTERRUPTS::t1+0x28>
 8000362:	f7ff fee9 	bl	8000138 <core::result::unwrap_failed>
 8000366:	f7ff fee3 	bl	8000130 <core::result::unwrap_failed>
```

If you do the measurement:

``` console
> continue
> # PC = 0x08000346, (CYCCNT & 0xff) = 0x95

> continue
> # PC = 0x0800035a, (CYCCNT & 0xff) = 0xa1

> print 0xa1 - 0x95
$1 = 12
```

You get 12 cycles as before but that's not the full story. The task now
has a prologue, which increases the context switching cost, and now has *two*
panic branches instead of one.

`RefCell`s also impose a memory overhead of 1 word (4 bytes) per resource:

``` rust
static COUNTER: Resource<RefCell<()>, C1> = Resource::new(RefCell::new(()));

fn t1(_task: Exti0Irq, ref prio: P1, ref thr: T1) {
    hprintln!("{}", mem::size_of_val(&COUNTER));
}
```

This program outputs:

```
$ openocd -f (.)
(..)
4
```

### Less overhead using `unsafe`

Can we improve the situation somehow? Well, one can use `unsafe` to optimize
away the `RefCell` runtime check. But is that actually safe?

Resources have the following property: "once a task has accessed a resource then
no other task that may access the same resource can start", where "start" here
means preempt the current task. You can flip that property into: "by the time a
task accesses a resource no other outstanding borrows to the resource data can
exist in other tasks". Taking this to the `RefCell` context: "the first time a
task accesses a `RefCell` resource the borrow count of the `RefCell` is zero".
Or conversely: "as long as Rust borrowing rules are not broken *within* a task
the dynamic borrows of a `RefCell` can't fail".

Translating that into code:

``` rust
static COUNTER: Resource<RefCell<u32>, C1> = Resource::new(RefCell::new(0));

fn t1(_task: Exti0Irq, ref prio: P1, ref thr: T1) {
    rtfm::bkpt();

    // first access to COUNTER in this task
    let counter = COUNTER.access(prio, thr);

    match counter.try_borrow_mut() {
        Ok(mut counter) => *counter += 1,
        // we know that this is not reachable because no other task can have
        // a reference to COUNTER's inner data and this is the first dynamic
        // borrow of COUNTER in this task
        Err(_) => unsafe { intrinsics::unreachable() },
    }

    rtfm::bkpt();
}
```

Disassembly:

``` armasm
0800032e <overhead::main::INTERRUPTS::t1>:
 800032e:	f240 0000 	movw	r0, #0
 8000332:	be00      	bkpt	0x0000
 8000334:	2200      	movs	r2, #0
 8000336:	f2c2 0000 	movt	r0, #8192	; 0x2000
 800033a:	6841      	ldr	r1, [r0, #4]
 800033c:	3101      	adds	r1, #1
 800033e:	e9c0 2100 	strd	r2, r1, [r0]
 8000342:	be00      	bkpt	0x0000
 8000344:	4770      	bx	lr
```

The measurement says that this program takes 9 cycles. Remember than the ideal
version took 6 cycles.

``` console
> continue
> # PC = 0x08000332, (CYCCNT & 0xff) = 0x9f

> continue
> # PC = 0x08000342, (CYCCNT & 0xff) = 0xa8

> print 0xa8 - 0x9f
$1 = 9
```

This helps a bit with the runtime overhead, but doesn't remove the borrow
counter from the resource so the resource still has a memory overhead of one
word. At the end it's probably not worth to lose memory safety to reduce a bit
of runtime overhead.

# Outro

Wow, that's was a lot (again). Sorry, I probably overdid myself a little up
there. I hope you now have a better idea of what RTFM does under the hood; it
actually does very little! And I hope that's also clear that most of the
guarantees that RTFM provides are enforced at compile time and don't involve
runtime checks. Hopefully we'll get rid of `RefCell` at some point.

Next up: measuring performance at runtime, and then, finally, some applications.

---

__Thank you patrons! :heart:__

I want to wholeheartedly thank [Iban Eguia], [Aaron Turon], [Geoff Cant],
[Harrison Chin], [Brandon Edens], [whitequark], [J. Ryan Stinnett] and 14
more people for [supporting my work on Patreon][Patreon].

[Iban Eguia]: https://github.com/Razican
[Aaron Turon]: https://github.com/aturon
[Geoff Cant]: https://github.com/archaelus
[Harrison Chin]: http://www.harrisonchin.com/
[Brandon Edens]: https://github.com/brandonedens
[whitequark]: https://github.com/whitequark
[J. Ryan Stinnett]: https://convolv.es/

---

Let's discuss on [reddit].

[reddit]: https://www.reddit.com/r/rust/comments/6cv2in/eir_overhead_analysis_of_the_rtfm_framework/

Enjoyed this post? Like my work on embedded stuff? Consider supporting my work
on [Patreon]!

[Patreon]: https://goo.gl/5yNZDa

Follow me on [twitter] for even more embedded stuff.

[twitter]: https://twitter.com/japaricious

The embedded Rust community gathers on the #rust-embedded IRC channel
(irc.mozilla.org). Join us!

---

# Appendix

Initial version of the program used throughout this post:

``` rust
#![feature(const_fn)]
#![feature(used)]
#![no_std]

// version = "0.2.7"
extern crate cortex_m;
// version = "0.2.0"
extern crate cortex_m_rt;
// version = "0.1.0"
#[macro_use]
extern crate cortex_m_rtfm as rtfm;
// git = "https://github.com/japaric/vl"
extern crate vl;

use core::ptr;

use cortex_m::asm;
use rtfm::{P0, P1, T0, T1, TMax};
use vl::stm32f100xx::interrupt::Exti0Irq;
use vl::stm32f100xx;

// RESOURCES
peripherals!(stm32f100xx, {
    DWT: Peripheral {
        register_block: Dwt,
        ceiling: C1,
    },
});

// INITIALIZATION PHASE
fn init(ref prio: P0, thr: &TMax) {
    // NB the cycle counter is disabled by default
    let dwt = DWT.access(prio, thr);
    dwt.enable_cycle_counter();
}

// IDLE LOOP
fn idle(_prio: P0, _thr: T0) -> ! {
    // Start task `t1`
    rtfm::request(t1);

    // Sleep
    loop {
        rtfm::wfi();
    }
}

// TASKS
tasks!(stm32f100xx, {
    t1: Task {
        interrupt: Exti0Irq,
        priority: P1,
        enabled: true,
    },
});

fn t1(_task: Exti0Irq, ref prio: P1, ref thr: T1) {
    let dwt = DWT.access(prio, thr);

    let before = dwt.cyccnt.read();
    asm::nop();
    let after = dwt.cyccnt.read();

    let elapsed = after.wrapping_sub(before);

    unsafe { ptr::write_volatile(0x2000_0000 as *mut _, elapsed) }

    rtfm::bkpt();
}
```
