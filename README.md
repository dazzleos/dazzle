<p align="center"><img src="logo.svg" alt="" width="120"></p>

# Dazzle

Dazzle is an ultra-light operating system for Raspberry Pi computers. It is
made to run well on the smallest and lowest-powered Pi, the Raspberry Pi
Zero.

## Installation

You will need a Raspberry Pi computer, i.e. one of:
- Raspberry Pi Zero 1-2
- Raspberry Pi 1-3

(Raspberry Pi 4 and 5 is not supported at this time).

You will also need:

- a microSD card (256 MB or bigger; everything on it is erased),
- a screen with HDMI (with a mini-HDMI adapter for the Zero),
- a USB keyboard and mouse, or a USB touchscreen
- for the Zero a micro-USB OTG adapter and a USB hub,
- optionally, a USB Ethernet adapter,
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
