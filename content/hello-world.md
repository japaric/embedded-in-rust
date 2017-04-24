+++
author = "Jorge Aparicio"
date = "2017-04-23T23:00:32-05:00"
description = "Introduction post"
draft = false
title = "Hello, world!"
+++

Hey there! Welcome to my blog, where I'll be writing about Rust and embedded
systems-y stuff -- that's it, mainly about programming ARM Cortex-M
microcontrollers as that's what Rust best supports today [^targets]. But, I'm
interested in anything that has a `#![no_std]` attribute in it [^no_std] so I
may cover some other stuff as well.

[^targets]: There's in tree support for MSP430 but the LLVM backend is still
    experimental; and, AVR support is not in tree yet.

[^no_std]: That includes building your own `std`! So I may write about [Xargo]
    and [steed] at some point.

[Xargo]: https://github.com/japaric/xargo
[steed]: https://github.com/japaric/steed

That being said, this post is neither about Rust or embedded stuff as it's
mainly for testing my blogging setup; so, why not write about that instead?
(Otherwise this post will end up being too short)

# My blogging setup

This blog is a static website built using [Hugo], a static site generator
written in Go. The blog theme is a modified version of the [hucore] theme. The
modifications are the following:

[Hugo]: https://gohugo.io
[hucore]: https://themes.gohugo.io/hucore/

- Customizable highlight.js theme.

I didn't like the default theme and there didn't seem to be any way to change it
so I hacked the theme source code to make the theme customizable. I've picked
the `tomorrow-night` theme for this blog since that's what I use in my terminal.
It looks like this:

``` rust
fn main() {
    println!("Hello, world!");
}
```

- LiveReload support.

But you won't notice this one as it's a development only feature.

- Table of Contents

Which you should see on the right. I stole this one from the [Minos] theme. I
... hope they don't mind.

[Minos]: https://themes.gohugo.io/hugo-theme-minos

As a good citizen of the open source world, I sent PRs to [mgjohansen/hucore]
for some of these modifications.

[mgjohansen/hucore]: https://github.com/mgjohansen/hucore

Leaving the theme aside: The "source" of this blog, a bunch of Markdown files,
is hosted on [GitHub]. The site is hosted on [GitHub pages] and I'm [using
Travis] to update the site every time I push to the source repo.

[GitHub]: https://github.com/japaric/embedded-in-rust
[GitHub pages]: https://pages.github.com/
[using Travis]: https://github.com/japaric/embedded-in-rust/blob/master/.travis.yml

I think that's enough for this post. See you in the next one! (Oh, you have no
idea what I have in stock :smile:)
