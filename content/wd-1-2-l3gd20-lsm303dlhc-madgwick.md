---
title: "Weekly driver 1 & 2: L3GD20, LSM303DLHC and Madgwick"
date: 2018-02-19T15:57:59+01:00
draft: false
---

Oh, time flies. It's already week 8 and we have zero [weekly driver] posts out there -- don't worry
though because there's plenty of [drivers] and `embedded-hal` [implementations] in the works.

[weekly driver]: /brave-new-io/#making-more-batteries
[drivers]: https://github.com/japaric/embedded-hal#drivers
[implementations]: https://github.com/japaric/embedded-hal#implementations

To play catch up in this post I'll cover two [`embedded-hal`] drivers: the [`l3gd20`] and the
[`lsm303dlhc`]. The [L3GD20] is an IC that contains a gyroscope and exposes I2C and SPI interfaces;
the [LSM303DLHC] is an IC that contains an accelerometer and a magnetometer, and exposes an I2C
interface. You can find these two ICs on the [STM32F3DISCOVERY] board.

[`embedded-hal`]: https://crates.io/crates/embedded-hal
[`l3gd20`]: https://crates.io/crates/l3gd20
[`lsm303dlhc`]: https://crates.io/crates/lsm303dlhc
[STM32F3DISCOVERY]: http://www.st.com/en/evaluation-tools/stm32f3discovery.html
[L3GD20]: http://www.st.com/en/mems-and-sensors/l3gd20.html
[LSM303DLHC]: http://www.st.com/en/mems-and-sensors/lsm303dlhc.html

Gyroscope, accelerometer and magnetometer -- all these are motion sensors. On their own they aren't
*that* useful because each one has some sort of weakness but when you put them together you can
build some nifty stuff.

<p align="center">
  <video autoplay loop src="/wd-1-2-l3gd20-lsm303dlhc-madgwick/viz.webm"></video></br>
  This is a demo of Madgwick's orientation filter but more on that later.
</p>

# L3GD20

Even though the L3GD20 has I2C and SPI interfaces the `l3gd20` driver only lets you interface the
L3GD20 using SPI. Coincidentally, on the STM32F3DISCOVERY board the L3GD20 is connected to the SPI
bus of the STM32F303 microcontroller.

The L3GD20 contains a gyroscope, but what's a gyroscope useful for?

## Gyroscope

A gyroscope is a sensor that measures the angular rate exerted on it. Angular rate is basically the
speed at which something is rotating, and it's measured in degrees per second or in radians per
second. Gyroscopes like the L3GD20 measure a 3D angular rate but report it as angular rates across
three orthogonal axes. See picture below:

<p align="center">
  <img src="/wd-1-2-l3gd20-lsm303dlhc-madgwick/l3gd20.svg"></br>
  Gyroscope axes
</p>

So the L3GD20 will report an angular rate across its X axis, another one across its Y axis and yet
another across its Z axis.

Going back to the `l3gd20` driver. Once you create an instance of the driver you can read the sensor
using the blocking `gyro()` method. The method returns an `I16x3` value which contains the readings
of the sensor along its X, Y and Z axes.

``` rust
let mut l3gd20 = L3gd20::new(spi, nss)?;

let I16x3 { x, y, z } = l3gd20.gyro()?;
```

Each reading is a 16 bit integer that represents an angular rate. To map this integer to degrees
per second you need to multiply it by the sensitivity of the sensor. The L3GD20 defaults to a
sensitivity of `8.75e-3 dps / LSB` (dps = degrees per second; LSB = Least Significant Bit); this
maps the 16 bit integer to a range of about `[-250, 250]` degrees per second.

If we collect data from the gyroscope while keeping the F3 board still we'll see something like
this:

<img src="/wd-1-2-l3gd20-lsm303dlhc-madgwick/gyro.svg" width="100%"/>

`AR_x` stands for Angular Rate across the X axis; `|AR|` is the magnitude of the 3D angular rate.
The blue line is sensor data collected during the span of one second and the green line is the mean
of the data.

### Calibration

There's a problem with this data though: it says that the mean angular rate is not zero, which
implies that the L3GD20 and the F3 board to which is attached are rotating. We know that was not the
case: the board was kept still while measuring so the all the readings *should* be centered around
zero but instead they are *offset* by some value. This offset is known as *bias* and it's commonly
found on gyroscopes and other kind of sensors.

To correct this bias error we have to calibrate the gyroscope. But turns out we kind of already did:
the mean values we computed in the previous graph are the biases of the gyroscope. The only thing
that's left is to subtract the bias from each axis measurements.

<img src="/wd-1-2-l3gd20-lsm303dlhc-madgwick/gyro-calibrated.svg" width="100%"/>

Now these are more correct measurements!

We can calibrate the gyroscope for bias while the gyroscope / board is not moving so we can do that
each time the system is initialized if we know that the board is still during initialization. The
problem is that bias doesn't remain constant in time; it tends to drift with both the passage of
time and with changes in temperature so the calibration will eventually become invalid. There are
methods to compensate for bias drift but I won't cover them here.

Let's move on to the next IC.

# LSM303DLHC

This IC contains an accelerometer and a magnetometer. Let's look at each of them in detail.

## Accelerometer

Accelerometers are sensors that measure *proper* acceleration. In simple terms, the difference
between proper acceleration and the *coordinate* acceleration you are familiar with is that proper
acceleration *includes* the acceleration of gravity. This means that even if an accelerometer is not
moving it will sense the acceleration of the gravity.

Like the gyroscope in the L3GD20, the accelerometer in the LSM303DLHC measures a 3D acceleration
vector but it reports the decomposition of the 3D vector along three orthogonal axes.

<p align="center">
  <img src="/wd-1-2-l3gd20-lsm303dlhc-madgwick/lsm303dlhc-accel.svg"></br>
  Accelerometer axes
</p>

Using the `lsm303dlhc` driver is similar to using the `l3gd20` driver. Once you instantiate the
driver you can read the accelerometer data using the blocking `accel()` method.

``` rust
let mut lsm303dlhc = Lsm303dlhc::new(i2c)?;

let I16x3 { x, y, z } = lsm303dlhc.accel()?;
```

Again, you get a 16 bit integer for the reading along each axis. The default sensitivity of the
accelerometer is around `6.1e-5 g / LSB` (g is the acceleration of gravity); this maps the integer
to a range of `[-2, 2]` g.

If we collect data from the accelerometer while keeping the F3 board still on a horizontal surface
we'll see something like this:

<img src="/wd-1-2-l3gd20-lsm303dlhc-madgwick/accel.svg" width="100%"/>

`G_x` stands for acceleration of Gravity across the X axis; `|G|` is the magnitude of the
acceleration of Gravity. The blue line is sensor data collected during the span of one second and
the green line is the mean of the data.

This accelerometer could use some calibration because the X and Y components should have a mean of
zero and the Z (down) component should have a mean of 1g but that's not that critical for the demo
so I'll skip it.

## Magnetometer

Magnetometers are sensors that measure magnetic fields. In the absence of nearby magnets a
magnetometer will measure Earth's magnetic field, which points to the geographic north (unless you
are too close to the poles, [I suppose]), so you can use the magnetometer as digital compass.

[I suppose]: https://mobile.twitter.com/TerribleMaps/status/964950464608571393

Earth's magnetic field is a 3D vector but the magnetometer in the LSM303DLHC decomposes it along
three orthogonal axes.

<p align="center">
  <img src="/wd-1-2-l3gd20-lsm303dlhc-madgwick/lsm303dlhc-mag.svg"></br>
  Magnetometer axes
</p>

The `lsm303dlhc` driver provides a blocking `mag()` method to read the magnetometer data.

``` rust
let I16x3 { x, y, z } = lsm303dlhc.mag()?;
```

As with the other methods, you'll get a 16 bit integer for each axis.

Below is shown a magnetometer reading obtained while the F3 board was sitting still on a horizontal
surface. No scaling (multiply by the sensitivity) was performed.

``` text
I16x3 { x: 26, y: -167, z: -553 }
```

From the X and Y components you can compute where north is in the horizontal XY plane. For instance,
if the X component is zero and the Y component is non zero then north is aligned to the Y axis of
the magnetometer. The Z component, the vertical component of Earth's magnetic field, varies with
latitude; it should be close to zero when the measurement is done on the equator.

### Calibration

Like the gyroscope, the magnetometer also suffers from bias. Furthermore, the metal components on
the board itself can strengthen / weaken nearby magnetic fields; this results in different *per
axis* sensitivities so a magnetic field of constant magnitude can be perceived as having different
magnitudes when measured along the different axes of the magnetometer.

As Earth's magnetic field magnitude is roughly constant, ideally we should measure it as having the
same magnitude regardless of the orientation of the magnetometer. We'll use this fact to calibrate
the magnetometer and compensate for the ferromagnetic properties of the board.

Assuming the only magnetic field the magnetometer is sensing is the Earth's we should observe that
all the magnetometer readings satisfy the following equation:

``` text
mx * mx + my * my + mz * mz == K  // Eq. 1
```

Where `mx` is the reading along the X axis, `my` is the reading along the Y axis, `mz` the reading
along the Z axis, and `K` is some constant.

This also happens to be the equation of a sphere centered at coordinate `(0, 0, 0)` so if we plot
the readings in 3D space we should see that all of them lie on the surface of a sphere.

To calibrate the magnetometer we'll collect measurements from the magnetometer in different
orientations. We'll do that by logging data while the board in being rotated in different ways. See
video below for a demo of what I mean.

<p align="center">
  <video autoplay loop src="/wd-1-2-l3gd20-lsm303dlhc-madgwick/eights.webm"></video>
</p>

**IMPORTANT** While logging calibration data keep the magnetometer *away* from sources of
electromagnetic fields (EMF). The above video is actually a *bad* example in that regard because
the EMF that the laptop emits heavily affect the magnetometer readings -- the laptop EMF can easily
double the magnetometer readings.


Here's the data that was collected over the lapse of 32 seconds of motion.

<img src="/wd-1-2-l3gd20-lsm303dlhc-madgwick/mag.svg" width="100%"/>

Plot `M_XY` is a scatter plot of the magnetometer readings along the X axis vs the readings along
the Y axis. Plots `M_XZ` and `M_YZ` are similar but involve a different pair of axes.

Remember that I said that the readings plotted in 3D space should look like a sphere? These first
three plots are like the projections of that sphere onto the XY, YZ and XZ planes so they *should*
look like circles centered at coordinate `(0, 0)` but they are a bit off both in position and shape.

Plot `|M|` is the magnitude of the Earth's magnetic field as sensed by the magnetometer. The
Earth's magnetic field is constant so the plot should be a straight line parallel to the X axis.
Instead we see that the sensed magnitude is all over the place.

The calibration process more or less boils down to finding a transformation of the calibration data
that makes it fulfill equation `1`, the sphere equation. A [proper solution] involves matrices but a
[simplified solution] is to independently transform the readings along each axis according to this
equation:

[proper solution]: https://www.nxp.com/docs/en/application-note/AN4246.pdf
[simplified solution]: https://github.com/kriswiner/MPU6050/wiki/Simple-and-Effective-Magnetometer-Calibration

``` rust
// calibrate the magnetometer readings along the X axis
mx = (mx - bias_x) / range_x
```

Where `mx` is an array of readings along the X axis, and `bias_x` and `range_x` are scalars that can
be found using these equations:

``` rust
bias_x = (mx.max() + mx.min()) / 2;
range_x = (mx.max() - mx.min()) / 2;
```

Applying this transformation to the calibration data yields the following calibrated data:

<img src="/wd-1-2-l3gd20-lsm303dlhc-madgwick/mag-calibrated.svg" width="100%"/>

Now the plots `M_XY`, `M_YZ` and `M_XZ` do look like circles centered at `(0, 0)`, and the magnitude
plot `|M|` looks much more like a constant value with some noise sprinkled on it.

# Madgwick's orientation filter

(This is the thing that you saw in the intro video.)

Madgwick's orientation filter is a sensor fusion algorithm that computes the absolute orientation of
an object from MARG sensor data. MARG stands for Magnetic, Angular Rate and Gravity, and basically
refers to a system that can measure Earth's **M**agnetic field, **A**ngular **R**ate and the
acceleration of **G**ravity. The magnetometer (M), gyroscope (AR) and accelerometer (G) on the F3
board form a MARG sensor array.

To give you an idea of how this filter works: the Gravity vector tells you where *down* is and the
Magnetic vector tells you where *north* is. These two vectors kind of form an absolute coordinate
system as their directions are pretty much constant.

Thus, the Gravity and Magnetic data give information about how the MARG system is oriented with
respect to this *down*-*north* coordinate system. Whereas the Angular Rate data gives information
about how that orientation is changing.

None of this data can't be fully trusted though: if the MARG system moves then the accelerometer
will measure not only the acceleration of gravity but also its own acceleration; the Magnetic data
can be easily affected by EM radiation, external magnetic sources and nearby ferromagnetic
materials; and the Angular Rate data suffers from bias that drifts over time and that changes with
the ambient temperature.

The way the filter deals with all this uncertainty is to treat the data not as ground truth but as
the input of an optimization problem. The rest is the magic of mathematics.

And it holds quite well, I must say. In the video at the beginning of this post the magnetometer is
subject to the EMF that my laptop generates and at some point in the video I shake the board along
the different accelerometer axes. All these are disturbances introduced in the input data but the
filter handles them without much trouble.

For more details (i.e. the actual math) you can read Madgwick's [internal report][]. There's also a
conference [paper] but it's behind a paywall -- its contents are not that different from what's
written in the internal report though.

[internal report]: http://x-io.co.uk/res/doc/madgwick_internal_report.pdf
[paper]: http://ieeexplore.ieee.org/document/5975346

## API

I have published Madgwick's orientation filter as the [`madgwick`] crate. This crate is compatible
with `no_std` programs and requires no memory allocation so it can be run on bare metal systems.

[`madgwick`]: https://crates.io/crates/madgwick

The API is straightforward to use: you create an instance of the filter; you feed MARG sensor data
into it and you get back the 3D orientation as a unit quaternion.

``` rust
let mut filter = madgwick::Marg::new(BETA, SAMPLING_PERIOD);

// e.g. `Quaternion(0.9999, 0.0017, -0.0046, 0.0006)`
let quat = filter.update(m, ar, g);
```

The parameter `BETA` is the *gain* of the filter and its value should be in the same order of
magnitude as the measurement noise in the gyroscope (in `rad / s`). You can measure the gyroscope
noise by logging gyroscope data while the board is still and then computing the standard deviation
of the readings along each axis.

The parameter `SAMPLING_PERIOD` is the sampling period in seconds. You should run the filter
periodically and on each periodic run you should feed the latest sensor data to the filter. That
period is the sampling period of the filter.

## Visualizations

You can find the visualization software used for the Madgwick demo [here]. It uses [`kiss3d`] to do
the rendering -- kudos to the authors; this was my first time doing anything graphics related with
Rust and it was pretty straightforward :+1:.

[here]: https://github.com/japaric/f3/tree/v0.5.3/viz
[`kiss3d`]: https://crates.io/crates/kiss3d

All the plots in this blog post where done using this [Python script].

[Python script]: https://github.com/japaric/f3/blob/v0.5.3/plot.py

## Firmware

You can find the F3 firmware used for the demo as the [`madgwick`] example in the [`f3`] crate. That
crate also contains a [`log-sensors`] example that was used to log the data used to make the plots
in this blog post and to calibrate the magnetometer.

[`madgwick`]: https://docs.rs/f3/0.5.3/f3/examples/_14_madgwick/index.html
[`f3`]: https://crates.io/crates/f3
[`log-sensors`]: https://docs.rs/f3/0.5.3/f3/examples/_13_log_sensors/index.html

# Conclusion

That's it! Two `embedded-hal` drivers are out; 50 more to go before the year ends :sweat_smile:. And
you also got a reusable implementation of Madgwick's orientation filter.

Finally, don't forget to calibrate your sensors before you use them for anything serious!

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
and 48 more people for [supporting my work on Patreon][Patreon].

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

[reddit]: https://www.reddit.com/r/rust/comments/7yn7k1/eir_weekly_driver_1_2_l3gd20_lsm303dlhc_and/

Enjoyed this post? Like my work on embedded stuff? Consider supporting my work
on [Patreon]!

[Patreon]: https://www.patreon.com/japaric

Follow me on [twitter] for even more embedded stuff.

[twitter]: https://twitter.com/japaric_io

The embedded Rust community gathers on the #rust-embedded IRC channel
(irc.mozilla.org). Join us!
