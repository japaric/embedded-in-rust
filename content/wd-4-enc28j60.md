---
title: "Weekly driver 4: ENC28J60, Ethernet for your microcontroller"
date: 2018-03-13T04:32:18+01:00
draft: false
---

It's week number 11 and the weekly driver #4 is out! [Last time], I did drivers 1 and 2 so you may be
wondering where's driver 3? [Driver #3], the [MCP3008] (8 channel 10-bit ADC with SPI interface),
was covered by [@pcein] in [their blog]. Also, as of now there are at least 14 (!) [drivers being
worked on by the community][wip].

[Last time]: /wd-1-2-l3gd20-lsm303dlhc-madgwick/
[Driver #3]: https://crates.io/crates/adc-mcp3008
[MCP3008]: http://www.microchip.com/wwwproducts/en/MCP3008
[@pcein]: https://github.com/pcein
[their blog]: http://pramode.in/2018/02/24/an-introduction-to-writing-embedded-hal-based-drivers-in-rust/
[wip]: https://github.com/rust-lang-nursery/embedded-wg/issues/39#issue-289457410

This week I'm releasing a driver for the [ENC28J60], an [Ethernet] controller with SPI interface.
This IC lets you connect your microcontroller, if it has a SPI interface, to a Local Area Network
or, with more work, to the internet. Apart from the IC you need a RJ45 connector and a few other
components so I'm using [this module] which has the ENC28J60 and all the required components on a
single board.

[Ethernet]: https://en.wikipedia.org/wiki/Ethernet
[ENC28J60]: http://www.microchip.com/wwwproducts/en/en022889
[this module]: https://www.aliexpress.com/item/-/32341839317.html

<p align="center">
  <img alt="ENC28J60" src="/wd-4-enc28j60/enc28j60.jpg">
</p>

# `enc28j60`

The driver crate, the [`enc28j60`], that lets you interface this chip is kind of boring -- as all
drivers should be: boring and with no surprises in them.

[`enc28j60`]: https://crates.io/crates/enc28j60

To initialize a driver you pass something that implements the SPI traits from the [`embedded-hal`]
crate plus a nCS (Clock Select) pin. You can optionally pass the INT and RESET pins; if you pass the
INT (interrupt) pin you can make use of the interrupt API; if you pass the RESET pin then
initialization will use that to reset the ENC28J60 instead of using a software reset. You also need
to pass something that provides delay functionality; a delay is needed in the initialization because
silicon bugs are a thing [^1]. Finally, you have to pass the size of the internal RX (reception)
buffer and the MAC address that the device will use.

[`embedded-hal`]: https://crates.io/crates/embedded-hal
[^1]: Vendors document silicon bugs in a document called Silicon Errata. [Here] is the Silicon
    Errata for the ENC28J60; I had to work around 5 (!) silicon bugs in the driver to make it work.

[Here]: http://ww1.microchip.com/downloads/en/DeviceDoc/80349b.pdf

``` rust
let mut enc28j60 = Enc28j60::new(spi, ncs, int, reset, &mut delay, 7 * KB, MAC)?;
```

The SPI interface usually runs at a lower rate (e.g. 1 Mbps) than the Ethernet interface (10 Mbps)
so it's not possible to move the incoming data into the microcontroller memory as it arrives. That's
why the ENC28J60 has 8 KB of RAM; in that memory it stores (buffers) all the incoming data until the
microcontroller has a chance to read it out. This memory is also used to store the data to transmit
so it's necessary to split the 8 KB in two regions: one for transmission (TX) and one for reception
(RX). That's what the 7 KB in the code snippet is all about: it's the size of the RX part.

To send out data you use the `transmit` method. This method copies (in a blocking fashion) the
specified `bytes` into the ENC28J60 memory and starts a transmission.

``` rust
enc28j60.transmit(bytes)?;
```

`transmit` won't block until the transmission is finished though. For that you can use the `flush`
method.

``` rust
enc28j60.flush()?;
```

But note that the current implementation of `transmit` will `flush` any in progress transmission.
This may be lifted in the future to let you queue several frames to send in the ENC28J60 memory.

The `bytes` you transmit *should* be a valid Ethernet frame otherwise the recipient is likely to
discard your data. In the current API `bytes` has type `&[u8]`, which means that it's up to the
caller to ensure that the data is a valid Ethernet frame. The driver doesn't demand any more
elaborated (new)type to let you use it with any network stack you want.

As per the spec Ethernet frames *must* include a frame check sequence (a CRC) at their end. The
ENC28J60 takes care of computing that and appending it to the frame so the microcontroller doesn't
have to deal with it. The ENC28J60 will also take care of padding `bytes` so the frame meets the
minimum length of 64 bytes.

To check if there's new data available you have the `pending_packets` method which returns the
number of packets that are stored in the ENC28J60 memory and that still need to be processed (read
out).

``` rust
let pending_packets = enc28j60.pending_packets()?;
```

Once you have confirmed that there are packets that still need to be processed you can read them out
using the `receive` method.

``` rust
let buf = [0; 256];
while enc28j60.pending_packets()? > 0 {
    let n = enc28j60.receive(&mut buf)?;
    let frame = &buffer[..n as usize];
    // ..
}
```

`receive` pretty much mimics the API of [`std::io::Read::read`] but returns the number of bytes read
as a `u16` value because that's the smallest integer type that makes sense in this case (remember:
only 8 KB of memory).

[`std::io::Read::read`]: https://doc.rust-lang.org/std/io/trait.Read.html#tymethod.read

Note that the ENC28J60 contains a receiver filter and that, by default, will filter out (ignore)
packets with invalid CRC, unicast packets that are *not* addressed to the MAC of the ENC28J60 and
packets that are *not* broadcasts.

That's the description of the boring driver now let's look at some demos!

# Demos

(All these demos were tested on the [Blue Pill] development board.)

[Blue Pill]: http://wiki.stm32duino.com/index.php?title=Blue_Pill

## `ping`

The first demo is a "pong server" (code [here][demo1]). Basically, it's a program that responds to
the `ping` command.

[demo1]: https://github.com/japaric/stm32f103xx-hal/blob/ed402cfaf09c5d0723fb2e751173a6aab3bca8ff/examples/enc28j60.rs

If you ping the hardcoded IP address of the microcontroller you'll see this:

``` console
$ # remove the IP and MAC address of the microcontroller from the ARP cache
$ _ arp -d 192.168.1.33

$ ping -c3 192.168.1.33
PING 192.168.1.33 (192.168.1.33) 56(84) bytes of data.
64 bytes from 192.168.1.33: icmp_seq=1 ttl=64 time=28.4 ms
64 bytes from 192.168.1.33: icmp_seq=2 ttl=64 time=15.6 ms
64 bytes from 192.168.1.33: icmp_seq=3 ttl=64 time=15.6 ms

--- 192.168.1.33 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2003ms
rtt min/avg/max/mdev = 15.674/19.950/28.497/6.043 ms
```

For comparison here's the output of `ping`ing my router:

``` console
$ ping -c3 192.168.1.1
PING 192.168.1.1 (192.168.1.1) 56(84) bytes of data.
64 bytes from 192.168.1.1: icmp_seq=1 ttl=64 time=2.24 ms
64 bytes from 192.168.1.1: icmp_seq=2 ttl=64 time=2.22 ms
64 bytes from 192.168.1.1: icmp_seq=3 ttl=64 time=2.18 ms

--- 192.168.1.1 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2002ms
rtt min/avg/max/mdev = 2.188/2.219/2.240/0.022 ms
```

The Round Trip Time (RTT) is 86% smaller in the case of the router.

The microcontroller will also log a bunch of stuff to the [ITM]. Here are the logs that were
generated during the execution of the first `ping` command:

[ITM]: /itm

``` console
$ itmdump -f /dev/ttyUSB0
Rx(60)
* ether::Frame { destination: mac::Addr([0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), source: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), type: Arp }
** arp::Packet { oper: Request, sha: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), spa: ipv4::Addr([192, 168, 1, 11]), tha: mac::Addr([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]), tpa: ipv4::Addr([192, 168, 1, 33]) }

** arp::Packet { oper: Reply, sha: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), spa: ipv4::Addr([192, 168, 1, 33]), tha: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), tpa: ipv4::Addr([192, 168, 1, 11]) }
* ether::Frame { destination: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), source: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), type: Arp }
Tx(42)

Rx(98)
* ether::Frame { destination: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), source: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), type: Ipv4 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 84, identification: 4374, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Icmp, checksum: 0xa616, source: ipv4::Addr([192, 168, 1, 11]), destination: ipv4::Addr([192, 168, 1, 33]) }
*** icmp::Packet { type: EchoRequest, code: 0, checksum: 0x5638, id: 22953, seq_no: 1 }

*** icmp::Packet { type: EchoReply, code: 0, checksum: 0x5e38, id: 22953, seq_no: 1 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 84, identification: 4374, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Icmp, checksum: 0xa616, source: ipv4::Addr([192, 168, 1, 33]), destination: ipv4::Addr([192, 168, 1, 11]) }
* ether::Frame { destination: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), source: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), type: Ipv4 }
Tx(98)

Rx(98)
* ether::Frame { destination: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), source: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), type: Ipv4 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 84, identification: 5023, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Icmp, checksum: 0xa38d, source: ipv4::Addr([192, 168, 1, 11]), destination: ipv4::Addr([192, 168, 1, 33]) }
*** icmp::Packet { type: EchoRequest, code: 0, checksum: 0x1531, id: 22953, seq_no: 2 }

*** icmp::Packet { type: EchoReply, code: 0, checksum: 0x1d31, id: 22953, seq_no: 2 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 84, identification: 5023, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Icmp, checksum: 0xa38d, source: ipv4::Addr([192, 168, 1, 33]), destination: ipv4::Addr([192, 168, 1, 11]) }
* ether::Frame { destination: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), source: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), type: Ipv4 }
Tx(98)

Rx(98)
* ether::Frame { destination: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), source: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), type: Ipv4 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 84, identification: 5092, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Icmp, checksum: 0xa348, source: ipv4::Addr([192, 168, 1, 11]), destination: ipv4::Addr([192, 168, 1, 33]) }
*** icmp::Packet { type: EchoRequest, code: 0, checksum: 0x2c29, id: 22953, seq_no: 3 }

*** icmp::Packet { type: EchoReply, code: 0, checksum: 0x3429, id: 22953, seq_no: 3 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 84, identification: 5092, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Icmp, checksum: 0xa348, source: ipv4::Addr([192, 168, 1, 33]), destination: ipv4::Addr([192, 168, 1, 11]) }
* ether::Frame { destination: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), source: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), type: Ipv4 }
Tx(98)
```

There are four exchanges in these logs: 1 [ARP] exchange and 3 [ICMP] exchanges. Let's look at
them in more detail.

[ARP]: https://en.wikipedia.org/wiki/Address_Resolution_Protocol
[ICMP]: https://en.wikipedia.org/wiki/Internet_Control_Message_Protocol

### ARP

The first exchange is this ARP exchange.

``` console
Rx(60)
* ether::Frame { destination: mac::Addr([0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), source: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), type: Arp }
** arp::Packet { oper: Request, sha: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), spa: ipv4::Addr([192, 168, 1, 11]), tha: mac::Addr([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]), tpa: ipv4::Addr([192, 168, 1, 33]) }

** arp::Packet { oper: Reply, sha: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), spa: ipv4::Addr([192, 168, 1, 33]), tha: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), tpa: ipv4::Addr([192, 168, 1, 11]) }
* ether::Frame { destination: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), source: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), type: Arp }
Tx(42)
```

In these logs `Rx($N)` indicates that `$N` bytes were received -- the 4 bytes of the CRC are *not*
included in this number. The lines below the `Rx($N)` line correspond to the headers found in the
received data. As we are dealing with Ethernet frames the first header will always be an Ethernet
frame. In this case, the payload of the Ethernet frame is an ARP packet.

The `Tx($N)` in the logs indicate that the `$N` bytes were sent to the ENC28J60 for transmission --
this number doesn't include the CRC or the zero padding that the ENC28J60 appends to the frame. The
lines above the `Tx($N)` line indicate the headers included in the transmitted data.

So, what's this ARP thing?

My laptop wants to `ping` the microcontroller and knows its IP address: 192.168.1.33 (that's the
first argument of the `ping` command) but it doesn't know its MAC address, which is required to send
an Ethernet frame.

Before actually `ping`ing the microcontroller the laptop will first *broadcast* (MAC address =
ff:ff:ff:ff:ff:ff) an ARP request. The request basically asks everyone on the LAN: "what's the MAC
address (THA: Target Hardware Address) of the machine with IP address (TPA: Target Protocol Address)
192.168.1.33?"

When the microcontroller sees its IP in this request it will answer with another ARP packet
indicating that its MAC address (SHA: Sender Hardware Address) is 20:18:03:01:00:00 and that its IP
address (SPA: Sender Protocol Address) is 192.168.1.33.

From this exchange the microcontroller also learns the MAC address and IP address of my laptop: this
information is in the SHA and SPA fields of the received ARP packet.

So, the Address Resolution Protocol (ARP) is used to find out how Protocol Addresses, like IPv4
addresses, map to Hardware Addresses, like MAC addresses -- at least within a LAN and when using
IPv4 as the data link layer.

### ICMP

What the `ping` command does under the hood is send ICMP packets of the EchoRequest type to the
specified IP address. Machines that receive this kind of ICMP packet *must* respond with ICMP
packets of the EchoReply type. The `ping` program processes these responses and shows some
statistics about the exchange like the Round Trip Time and the hop distance between the nodes (cf.
ttl).

Back to the exchange, once my laptop learned the MAC address of the microcontroller it started
sending ICMP packets. The first ICMP exchange is shown below:

``` console
Rx(98)
* ether::Frame { destination: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), source: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), type: Ipv4 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 84, identification: 4374, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Icmp, checksum: 0xa616, source: ipv4::Addr([192, 168, 1, 11]), destination: ipv4::Addr([192, 168, 1, 33]) }
*** icmp::Packet { type: EchoRequest, code: 0, checksum: 0x5638, id: 22953, seq_no: 1 }

*** icmp::Packet { type: EchoReply, code: 0, checksum: 0x5e38, id: 22953, seq_no: 1 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 84, identification: 4374, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Icmp, checksum: 0xa616, source: ipv4::Addr([192, 168, 1, 33]), destination: ipv4::Addr([192, 168, 1, 11]) }
* ether::Frame { destination: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), source: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), type: Ipv4 }
Tx(98)
```

The first thing to note is that this time the destination MAC address specified in the received
Ethernet frame is the MAC address of the microcontroller, and not the broadcast address. The payload
of the Ethernet frame this time is an IPv4 packet and the payload of that packet is an ICMP packet.

As expected the ICMP packet is of the EchoRequest type. Its `id` (identifier) field indicates the
PID of the `ping` command, and the `seq_no` (sequence number) field tracks the number of packets
send by the `ping` command. If you look at the full log you'll see that `id` remains constant across
all the ICMP exchanges whereas `seq_no` monotonically increases.

The microcontroller sends back a EchoReply packet in response to this EchoRequest packet. Most of
the information in the headers, like the `id` and `seq_no` fields, as well as the payload of the
request are preserved in the reply.

### Benchmark

The pong server I showed works fine but it's wasteful because it busy waits for new packets so I
partially [rewrote][demo2] it to be reactive: now it sleeps most of the time and only wakes up to
process newly received packets. It does this using the INT (interrupt) pin as a source of
interrupts: the ENC28J60 notifies the microcontroller about new packets by driving the INT pin low
and this wakes up the microcontroller.

[demo2]: https://github.com/japaric/stm32f103xx-hal/blob/ed402cfaf09c5d0723fb2e751173a6aab3bca8ff/examples/enc28j60-reactive.rs

To this version I also added a CPU monitor with the goal of being able to benchmark the performance
of the pong server. Then I benchmarked the final version by spawning several parallel instances of
the `ping` command. The results are shown below:

`ping`s | CPU usage during one second (worst of 10 samples)
--------|------
1 | 0.6591%
2 | 0.8111%
4 | 1.8581%
8 | 3.2091%
16 | 6.3993%
32 | 12.8010%

I should note that the CPU was operating at 8 MHz, that logs were disabled during the collection of
these statistics and that the driver only exposes a blocking API [^2] at the moment so CPU usage
could actually be reduced in the future.

[^2]: Methods like `transmit` and `receive` could be made asynchronous / non-blocking with the help
    of the DMA but we don't have traits for DMA based I/O in `embedded-hal` at the moment.

## UDP

The second demo is a UDP echo server (the code is the [same][demo1] as the first demo's). This
program will send back *all* the received UDP datagrams, regardless of what their destination port
is.

You can test this demo using netcat:

``` console
$ nc -u 192.168.1.33 1337
hello
hello
Rustaceans
Rustaceans
```

The server will echo back everything you send to it.

Here are the logs captured during that UDP exchange:

``` console
$ itmdump -f /dev/ttyUSB0
Rx(60)
* ether::Frame {destination: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), source: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), type: Ipv4 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 34, identification: 3907, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Udp, checksum: 0xa80b, source: ipv4::Addr([192, 168, 1, 11]), destination: ipv4::Addr([192, 168, 1, 33]) }
*** udp::Packet { source: 58248, destination: 1337, length: 14, checksum: 20407 }

*** udp::Packet { source: 1337, destination: 58248, length: 14, checksum: 0 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 34, identification: 3907, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Udp, checksum: 0xa80b, source: ipv4::Addr([192, 168, 1, 33]), destination: ipv4::Addr([192, 168, 1, 11]) }
* ether::Frame { destination: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), source: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x0, 0x00]), type: Ipv4 }
Tx(48)

Rx(60)
* ether::Frame { destination: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), source: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), type: Ipv4 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 39, identification: 4839, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Udp, checksum: 0xa462, source: ipv4::Addr([192, 168, 1, 11]), destination: ipv4::Addr([192, 168, 1, 33]) }
*** udp::Packet { source: 58248, destination: 1337, length: 19, checksum: 36455 }

*** udp::Packet { source: 1337, destination: 58248, length: 19, checksum: 0 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 39, identification: 4839, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Udp, checksum: 0xa462, source: ipv4::Addr([192, 168, 1, 33]), destination: ipv4::Addr([192, 168, 1, 11]) }
* ether::Frame { destination: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), source: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), type: Ipv4 }
Tx(53)
```

This time we have UDP datagrams, instead of ICMP packets, inside the IPv4 packets. I should note
that the echo server doesn't bother with updating the checksum of the UDP datagrams and just zeroes
it [^3]; that's why you see that all the responses have their UDP checksum set to zero.

[^3]: This is allowed by the spec when using IPv4 as the data link layer.

I think this is a good time to show the binary size of the demo program:

``` console
$ arm-none-eabi-size enc28j60
   text    data     bss     dec     hex filename
   7158       0       4    7162    1bfa enc28j60
```

This size is with the logging functionality removed.

## CoAP

The third and final demo (code [here][demo3]) is a simple [CoAP] server.

[demo3]: https://github.com/japaric/stm32f103xx-hal/blob/ed402cfaf09c5d0723fb2e751173a6aab3bca8ff/examples/enc28j60-coap.rs
[CoAP]: https://en.wikipedia.org/wiki/Constrained_Application_Protocol

If you are not familiar with the Constrained Application Protocol (CoAP) it's, more or less, a
simplified version of HTTP that runs on top of UDP (HTTP uses TCP as its transport layer). In CoAP
you also have GET, PUT, POST and DELETE methods that you can use to implement RESTful APIs.

The difference between HTTP and CoAP is that CoAP has been designed to run on resource constrained
nodes; [its RFC][rfc] explicitly mentions "8-bit microcontrollers with small amount of ROM and RAM"
as an example of the environments it targets.

[rfc]: https://tools.ietf.org/html/rfc7252

In this demo the CoAP server exposes a single resource: an LED at path `/led`. The state of the LED
can be queried / modified using GET / PUT requests, respectively.

The [`jnet`] crate provides a simple CoAP client that you can use to interact with the CoAP server.

[`jnet`]: https://github.com/japaric/jnet

This is how a GET request looks like:

``` console
$ coap GET coap://192.168.1.33/led
-> coap::Message { version: 1, type: Confirmable, code: Method::Get, message_id: 0, options: {UriPath: "led"} }
<- coap::Message { version: 1, type: Acknowledgement, code: Response::Content, message_id: 0, payload: "on" }
on
```

And this is how a PUT request looks like:

``` console
$ coap PUT coap://192.168.1.33/led off
-> coap::Message { version: 1, type: Confirmable, code: Method::Put, message_id: 0, options: {UriPath: "led"}, payload: "off" }
<- coap::Message { version: 1, type: Acknowledgement, code: Response::Changed, message_id: 0 }
```

Here's a video where I interact with the CoAP server to control the LED:

<p align="center">
  <video controls src="/wd-4-enc28j60/coap.webm" width="100%"></video>
</p>


And here are the logs collected during the first two CoAP requests:

``` console
$ itmdump -f /dev/ttyUSB0
Rx(60)
* ether::Frame { destination: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), source: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), type: Ipv4 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 37, identification: 20643, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Udp, checksum: 0x66a8, source: ipv4::Addr([192, 168, 1, 11]), destination: ipv4::Addr([192, 168, 1, 33]) }
*** udp::Packet { source: 11983, destination: 5683, length: 17, checksum: 57209 }
**** coap::Message { version: 1, type: Confirmable, code: Method::Get, message_id: 0, options: {UriPath: "led"} }

**** coap::Message { version: 1, type: Acknowledgement, code: Response::Content, message_id: 0, payload: "off" }
*** udp::Packet { source: 5683, destination: 11983, length: 16, checksum: 0 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 36, identification: 20643, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Udp, checksum: 0x66a9, source: ipv4::Addr([192, 168, 1, 33]), destination: ipv4::Addr([192, 168, 1, 11]) }
* ether::Frame { destination: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), source: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), type: Ipv4 }
Tx(50)

Rx(60)
* ether::Frame { destination: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), source: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), type: Ipv4 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 39, identification: 22193, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Udp, checksum: 0x6098, source: ipv4::Addr([192, 168, 1, 11]), destination: ipv4::Addr([192, 168, 1, 33]) }
*** udp::Packet { source: 53402, destination: 5683, length: 19, checksum: 53048 }
**** coap::Message { version: 1, type: Confirmable, code: Method::Put, message_id: 0, options: {UriPath: "led"}, payload: "on" }

**** coap::Message { version: 1, type: Acknowledgement, code: Response::Changed, message_id: 0 }
*** udp::Packet { source: 5683, destination: 53402, length: 13, checksum: 0 }
** ipv4::Packet { version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 33, identification: 22193, df: true, mf: false, fragment_offset: 0, ttl: 64, protocol: Udp, checksum: 0x609e, source: ipv4::Addr([192, 168, 1, 33]), destination: ipv4::Addr([192, 168, 1, 11]) }
* ether::Frame { destination: mac::Addr([0x9c, 0xb6, 0xd0, 0xed, 0xad, 0xff]), source: mac::Addr([0x20, 0x18, 0x03, 0x01, 0x00, 0x00]), type: Ipv4 }
Tx(47)
```

This is binary size of the CoAP demo with logging functionality disabled:

``` console
$ arm-none-eabi-size enc28j60-coap
   text    data     bss     dec     hex filename
   9186       0       4    9190    23e6 enc28j60-coap
```

I swear that at some point the binary size of the CoAP demo was about the of the UDP echo server.
I, somehow, seem to have made some change that regressed the binary size by around 2 KB *sigh*. This
is why I should commit more often.

# Conclusion

There you go: Ethernet functionality for all devices that have a SPI interface via the ENC28J60. The
driver have been kept as simple as possible to let you use it with any network stack. I've been
doing my own network experiments in the [`jnet`] crate but you should definitively check out the
[`smoltcp`] crate (I haven't tested it myself) which is a mature network stack with actual socket
abstractions -- it would be great to have an example of `enc28j60` + `smoltcp` in the
[`stm32f103xx-hal`] crate!

[`smoltcp`]: https://crates.io/crates/smoltcp
[`stm32f103xx-hal`]: https://github.com/japaric/stm32f103xx-hal

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
and 54 more people for [supporting my work on Patreon][Patreon].

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

Let's discuss on [reddit].

[reddit]: https://www.reddit.com/r/rust/comments/84183w/weekly_driver_4_enc28j60_ethernet_for_your/

Enjoyed this post? Like my work on embedded stuff? Consider supporting my work
on [Patreon]!

[Patreon]: https://www.patreon.com/japaric

Follow me on [twitter] for even more embedded stuff.

[twitter]: https://twitter.com/japaricious

The embedded Rust community gathers on the #rust-embedded IRC channel
(irc.mozilla.org). Join us!
