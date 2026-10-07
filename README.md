<p align="center"><img src="logo.svg" alt="" width="120"></p>

# Dazzle

Dazzle is an ultra-light operating system for Raspberry Pi computers. It is
made to run well on the smallest and lowest-powered Pi, the Raspberry Pi
Zero: it starts in seconds, runs entirely from memory, and draws everything
with the Pi's own graphics chip, so windows move and animate smoothly at
the screen's full refresh rate.

It has a simple desktop: a dock along the bottom of the screen with your
apps, and windows you can move, resize, maximize and close. Settings is
built in; you choose the other apps when you set Dazzle up (and can add or
remove them later):

- **Settings:** see what the Pi is doing (CPU, memory, temperature,
  storage), connect to wired and Wi-Fi networks, and install and remove
  apps.
- **Files:** browse your files, and look inside them: text, pictures and
  fonts.
- **Camera:** see what a Raspberry Pi Camera Module sees, and take
  photos.
- **Demo:** a spinning 3D shape showing off the graphics, with controls to
  play with.

## Supported devices

- Raspberry Pi Zero
- Raspberry Pi Zero W
- Raspberry Pi 3 A+ (not yet tried on real hardware)

One download works on all of them. Other models are not supported yet.

You will also need:

- a microSD card (256 MB or bigger; everything on it is erased),
- a screen with HDMI (with a mini-HDMI adapter for the Zero),
- a USB keyboard and mouse, or a USB touchscreen (on the Zero, plugged into
  its USB port through a micro-USB OTG adapter, with a hub for more than
  one),
- optionally, for a network on the Zero (which has no Wi-Fi), a USB
  Ethernet adapter,
- optionally, a Raspberry Pi Camera Module v1 or v2 (the Zero needs its
  narrower camera cable). Connect it while the Pi is off.

## Download

**[Download Dazzle (dazzle.img.xz)](https://github.com/robert-ancell/dazzle/releases/latest/download/dazzle.img.xz)**

This is built automatically from the latest code
([release page](https://github.com/robert-ancell/dazzle/releases/latest),
with its checksum). Dazzle is a work in progress: expect things to be
missing or to change.

## Installing

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to write
Dazzle to your microSD card:

1. Open Raspberry Pi Imager and choose your device.
2. Under **Choose OS**, scroll to the bottom and pick **Use Custom**, then
   choose the `dazzle.img.xz` file you downloaded (there is no need to
   unpack it).
3. Under **Choose Storage**, pick your microSD card.
4. Click **Next**. When asked about OS customisation, choose **No**: Dazzle
   asks for its own settings when it starts.

Or, on Linux, from a terminal (replace `/dev/sdX` with your card; check
with `lsblk` first, as this erases it):

```sh
xzcat dazzle.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

## First start

Put the card in the Pi, connect the screen, keyboard and mouse, then plug
in the power. After a few seconds Dazzle asks for a name for your
computer, with a random one filled in (like `awesome-elephant`) that you
can keep or change. While you do, it gets the rest of the card ready for
your files. Then it offers the apps you can install, all chosen to begin
with: untick any you do not want and click Finish. They are downloaded
and installed, so this needs a network (plug in Ethernet before you
start; Wi-Fi can only be joined from Settings for now, so without
Ethernet you install apps from there once the desktop is up). Then the
desktop appears.

From then on, Dazzle starts straight to the desktop.

## Using Dazzle

- **Apps:** click an icon in the dock to open the app, or to bring its
  window to the front if it is already open.
- **Installing apps:** with a network connected, open Settings and choose
  Apps. It lists the apps you can install, from the same place as the
  Dazzle download: click Install to add one to the dock, or Remove to take
  it away. Refresh gets the latest list.
- **Windows:** drag a window by its title bar, and resize it from its
  edges. The buttons in the title bar maximize and close it.
- **Touchscreens:** tap to click, drag to scroll, and press and hold for
  the menu a right-click would show.
- **Copy and paste:** in a text box, select text and press Ctrl+C to copy
  it (or Ctrl+X to cut it), then Ctrl+V to paste it, in the same app or
  another. Right-clicking a text box shows a menu with these too.
- **Screenshots:** press Print Screen. The picture is saved with your files
  as `Screenshot 1.png`, `Screenshot 2.png` and so on.
- **Photos:** open the Camera app and click Take photo. Photos are saved
  with your files as `Photo 1.png`, `Photo 2.png` and so on. The camera is
  new and not yet tried on real hardware.
- **Your files** are kept on the microSD card, in User files in the Files
  app.
- **Turning off:** unplug the power. Your files are kept safe even then.
- **Updating Dazzle:** with a network connected, open Settings and choose
  System. When a newer Dazzle is available, Updates says so: click
  Download. Once it is installed, click Restart to start using it. Your
  files and apps are kept. Check again looks for a newer one.

### Networks

- **Wi-Fi** (Pi Zero W and Pi 3 A+): open Settings, choose Wi-Fi and click
  a network to join it. Open networks, and WPA2 networks with a password,
  are supported. Networks are not yet remembered after a restart.
- **Ethernet:** plug in a USB Ethernet adapter at any time; Dazzle gets an
  address by itself. To set an address by hand, choose Static under
  Ethernet in Settings (it lasts until the Pi restarts). Most common
  adapters work (Realtek, ASIX, SMSC, Microchip and standard ones).

### If something goes wrong

With a network connected, Dazzle shows its log in a web browser. Find the
Pi's address (under Ethernet or Wi-Fi in Settings, or under your
computer's name in your router's list of devices) and open
`http://<address>/` on another computer. `http://<address>/follow` keeps
showing new messages as they come.

If an update does not work (the desktop does not appear within a minute,
or the Pi stops responding), Dazzle goes back to the version before it by
itself: the Pi restarts into it, or starts it the next time you plug it
in, and Settings says the update did not work. If Dazzle does not start at
all after an update, put the card in another computer, open `config.txt`
on it, and change `os_prefix=slot-b/` to `os_prefix=slot-a/` (or the
other way round) to start the previous Dazzle again.

Please report problems, with the log if you can, in the
[issues](https://github.com/robert-ancell/dazzle/issues).

## What's missing

Dazzle is young. Some of what it cannot do yet:

- update installed apps (planned),
- remember Wi-Fi networks after a restart, or join WPA3-only networks,
- keyboard layouts other than US, and typing letters outside English,
- Bluetooth and sound,
- run on the Raspberry Pi 4, 5, Zero 2 W and other models.

## For developers

How Dazzle is built and how it works, including building the image
yourself, is in [ARCHITECTURE.md](ARCHITECTURE.md).

## Licence

Dazzle is free software under the MIT licence ([LICENSE](LICENSE)). It
includes other software under its own licences, listed on the device in
`/os/NOTICES` and beside each app.
