<p align="center"><img src="logo.svg" alt="" width="120"></p>

# Dazzle

Dazzle is an ultra-light operating system for Raspberry Pi computers. It is
made to run well on the smallest and lowest-powered Pi, the Raspberry Pi
Zero.

## Installation

You will need:

- a Raspberry Pi (Raspberry Pi 1–5, or Raspberry Pi Zero / Zero W / Zero 2 W)
- a microSD card (256 MB or larger; everything on it will be erased)
- an HDMI display (with a mini-HDMI or micro-HDMI adapter if your board needs one)
- a USB keyboard and mouse, or a USB touchscreen (with a micro-USB OTG adapter and hub for the Zero)
- optionally, a USB Ethernet adapter (for boards without built-in networking)
- optionally, a Raspberry Pi Camera Module v1 or v2

**[Download Dazzle (dazzle.img.xz)](https://github.com/robert-ancell/dazzle/releases/latest/download/dazzle.img.xz)**

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to write
Dazzle to your microSD card:

1. Open Raspberry Pi Imager and choose your device.
2. Under **Choose OS**, scroll to the bottom and pick **Use Custom**, then
   choose the `dazzle.img.xz` file you downloaded (there is no need to
   unpack it).
3. Under **Choose Storage**, pick your microSD card.
4. Click **Next**. When asked about OS customisation, choose **No**: Dazzle
   asks for its own settings when it starts.

## Special Thanks ❤️

Dazzle is built on the foundations of these great projects:

- Linux
- [Raspberry Pi](https://www.raspberrypi.com/)
- [Zig](https://ziglang.org/)
- [Material Design](https://m3.material.io/)
