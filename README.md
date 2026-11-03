# selphy-cp1500-pi

Print to a **Canon SELPHY CP1500** over USB from a **Raspberry Pi** running
Raspberry Pi OS Bookworm (arm64), through CUPS and gutenprint.

One script installs the driver, keeps `ipp-usb` away from the printer, and
creates a print queue set for borderless postcards. Run it again whenever you
like: if everything is already in place, it changes nothing.

> **Licensing:** this repository's scripts and docs are MIT; gutenprint, which
> the release ships, stays GPL-2.0-or-later. See [Licensing](#licensing).

## Tested on

| | |
|---|---|
| Computer | Raspberry Pi 5, 8 GB |
| OS | Raspberry Pi OS Bookworm, arm64 (kernel 6.12) |
| CUPS | 2.4.2 (Debian `2.4.2-3+deb12u9`), `ipp-usb` 0.9.23 |
| Printer | Canon SELPHY CP1500, USB id `04a9:3302` |
| Paper | Canon RP-108 (postcard, 100x148 mm, "4x6") with its ink cassette |
| Driver | gutenprint 5.3.5 |

Anything else is untested. On another OS or architecture the prebuilt driver
is refused, and `--from-source` builds it there instead.

## Why this exists

- **Bookworm's gutenprint is too old.** Its 5.3.4 snapshot lists SELPHY
  models up to the CP1300. Support for the CP1500 arrived in **gutenprint
  5.3.5**, which Debian ships only in testing and unstable.
- **Driverless printing does not work over USB here.** The CP1500 speaks IPP
  over USB, but it answers `ipp-usb`'s first request with
  `server-error-internal-error`, so `ipp-usb` gives up on it (and resets the
  printer each time it tries). Reports say IPP-over-USB on SELPHYs needs the
  printer on Wi-Fi, which a booth or kiosk may not have.

So this builds gutenprint 5.3.5 for the Pi, once, and publishes the result
with its source.

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/awkent01/selphy-cp1500-pi/v5.3.5-2/install.sh
sudo bash install.sh
```

Switch the printer on and plug it in first: the queue is made from the
printer the Pi can see. If it is off, the driver is still installed, and
running the script again later adds the queue.

What it does, in order, skipping each step that is already done:

1. **The driver.** It fetches `selphy-cp1500-pi-5.3.5-1-bookworm-arm64.tar.xz`
   from this repository's [`v5.3.5-1` release](https://github.com/awkent01/selphy-cp1500-pi/releases/tag/v5.3.5-1),
   checks it against the sha256 written into `install.sh` (a pinned tag
   and checksum, never "latest"), checks every file against the package's
   own MANIFEST, and installs it.
   - Libraries and data go under `/usr/local`. The 12 files CUPS has to find
     in its own directories go to `/usr/lib/cups`, `/usr/share/cups`,
     `/usr/bin`, `/usr/sbin` and `/etc/cups`.
   - **It never writes a file a Debian package owns** (`dpkg -S`), nor one
     that is already there and isn't its own. Either stops it before
     anything is written, and names the file.
   - If CUPS already has the CP1500 driver, installed some other way, it is
     left alone.
2. **The ipp-usb quirk.** It writes `/etc/ipp-usb/quirks/selphy-cp1500.conf`,
   so ipp-usb ignores this one model and keeps working for any other printer:

   ```ini
   [Canon SELPHY CP1500]
     blacklist = true
   ```
3. **The queue `selphy`**: `PageSize=Postcard`, `StpBorderless=True`, not
   shared on the network, and **not** made the system default. Its address
   (`gutenprint53+usb://canon-cp1500/<serial>`) is read from `lpinfo -v`.

Options: `--queue NAME`, `--no-queue`, `--from-source`. Run `install.sh --help`.

Then print:

```bash
lp -d selphy photo.png
```

### Building it yourself

```bash
sudo bash install.sh --from-source
```

This installs the build tools (`build-essential pkg-config libcups2-dev
libcupsimage2-dev libusb-1.0-0-dev`), fetches `gutenprint-5.3.5.tar.xz`
(sha256 `f5a9f47de28530b1ae2069cfbc647a9a641baeeabe809bb0ef2b3ec5b9668d70`,
the upstream release, unmodified), builds it with the flags below, and
installs it the same way. It takes a few minutes on a Pi 5.

```
--prefix=/usr/local --with-cups=/usr --disable-nls --disable-static
--disable-static-genppd --without-gimp2 --disable-samples --disable-test
--disable-testpattern --disable-escputil --disable-translated-cups-ppds
--disable-globalized-cups-ppds
```

`--with-cups=/usr` matters: cupsd runs backends, filters and drivers only from
its own directories, so a pure `/usr/local` install would be invisible to it.

## Uninstall

```bash
curl -fsSLO https://raw.githubusercontent.com/awkent01/selphy-cp1500-pi/v5.3.5-2/uninstall.sh
sudo bash uninstall.sh
```

It removes exactly what `install.sh` installed, from the list it kept in
`/usr/local/share/selphy-cp1500-pi/`: the driver's files, the directories it
created (once empty), the quirk, and the queue if `install.sh` created it. A
file that has changed since, or that a Debian package now claims, is left and
named. A driver installed some other way is not touched.

## The paper

- `PageSize=Postcard` is RP-108's size. There is no custom size to set.
- Borderless prints a **1248x1872 pixel grid at 300 dpi (105.7x158.5 mm)**
  onto a 100x148 mm face: the printer overscans, and the excess lands on the
  sheet's perforated tear-off tabs. On one ruler sheet the top, left and
  right edges looked as expected (not measured to the mm), and at the bottom
  about 5–6 mm fell past the perforation (≈5.25 mm computed). Keep anything
  that matters a few mm inside the edges.
- Send exactly 1248x1872 at 300 dpi and nothing is scaled: checked by
  capturing what CUPS sends to the printer and comparing it with the file. No
  shift, rotation or mirroring; across, the columns line up exactly; down, one
  row slips about a third of the way down (0.08 mm).
- Colour: the driver's colour correction is left at its default. What reaches
  the printer is the image's own colour, inverted to CMY (within 0.5 of 255
  on average), and the printer does its own colour handling.
- A CP1500 has its own border setting. If borderless prints come out with a
  white edge, check the printer's settings.

## What it does when things go wrong

Seen on the printer:

- **An error stops the queue and holds the job.** With the ink cassette not
  seated, `lpstat -l -p selphy` read:

  ```
  printer selphy disabled since Mon Nov  2 20:59:04 2026 -
  	Printer error: No Ink (07)
  	Alerts: media-empty paused
  ```

  The backend stopped **before the paper moved**, so no sheet was used.
- **Fixing the printer does not restart the queue.** `sudo cupsenable
  selphy` does, and the held job then prints by itself. **Do not send it
  again** with `lp`: that is a second sheet.
- **CUPS finishes before the printer.** A postcard takes about 2 minutes to
  come out, and the job leaves the queue after 10–20 seconds, once the data
  is sent.
- The backend sets `media-empty` on any printer error, and for a moment at
  the start of a good print. Read the message line, not the alert.

## Troubleshooting

| Symptom | What to do |
|---|---|
| `lpinfo -m` has no CP1500 | The driver isn't installed, or CUPS wasn't restarted: run `install.sh` again. |
| `sudo ipp-usb status` says "Device doesn't implement print or scan service" | That is the printer's own answer. The quirk makes it say "Device is blacklisted" instead. |
| No queue was made ("no CP1500 on USB") | Switch the printer on, plug it in, and run `install.sh` again. |
| `lpstat -p selphy` says `disabled` | The printer reported an error (the line under it says which). Fix it, then `sudo cupsenable selphy`. |
| `install.sh` refuses: "exists and is not ours" | Something else installed gutenprint files there. Remove that install first, or use it as it is. |
| `install.sh` refuses: "the prebuilt driver is for Raspberry Pi OS Bookworm on arm64" | Use `--from-source`. |
| A white border on borderless prints | The printer's own border setting. |

## What has been tested, and what hasn't

Proven on a Raspberry Pi 5 with Bookworm, with a real CP1500:

- The driver, queue and quirk as described here: two postcards printed, and
  the "No Ink (07)" stop and `cupsenable` recovery seen on the printer.
- `install.sh` from the release package into a scratch directory: the tree is
  exactly the MANIFEST, a second run changes nothing, and `uninstall.sh`
  leaves nothing. Each refusal (corrupted download, a file a Debian package
  owns, a foreign file, the wrong architecture) stops it before anything is
  written. All of it is `tests/test.sh`.
- `install.sh` run for real on a Pi that already had the driver: nothing
  changed, not even a service restart.

**Not proven yet:**

- **A fresh card.** No clean Bookworm install has gone from nothing to a
  printed postcard with this script. The scratch-directory install is the
  closest test so far.
- **`--from-source`.** The release was built with exactly these configure
  flags, but `install.sh --from-source` itself has not been run end to end.
- Out of paper, and the printer switched off when the Pi boots.

Reports of either, working or not, are welcome as issues.

## Releases

- **v5.3.5-2**: installer fix only. On a Pi whose CP1500 driver was installed
  some other way, v5.3.5-1 could miss it: `lpinfo -m | grep -q` under
  `pipefail` reads as "not found" when lpinfo is cut off by SIGPIPE, which it
  usually is with thousands of models listed. It then tried to install over
  that driver and stopped on the files already there. The driver package is
  unchanged: v5.3.5-2 installs the same `v5.3.5-1` package, by the same sha256.
- **v5.3.5-1**: the first release: gutenprint 5.3.5, built for Bookworm arm64.

## For maintainers: making a release

The release carries three files and their checksums:

| asset | what |
|---|---|
| `gutenprint-5.3.5.tar.xz` | upstream's release, unmodified: the GPL source |
| `selphy-cp1500-pi-5.3.5-1-bookworm-arm64.tar.xz` | the install tree, its MANIFEST, gutenprint's COPYING and a NOTICE |
| `selphy-cp1500-pi-5.3.5-1-bookworm-arm64.manifest` | the MANIFEST on its own, to read before installing |
| `SHA256SUMS` | all three |

On a Pi with Bookworm arm64:

```bash
./install.sh --package OUT                # build from source into OUT
./install.sh --package OUT --stage DIR    # or package an existing DESTDIR stage
tests/test.sh STAGE_DIR gutenprint-5.3.5.tar.xz
```

Packaging is reproducible (fixed file order, owner and time), and refuses a
tree that still names the machine that built it. `make install` writes one
such file, `config.summary`, and packaging removes the user and host name from
it; nothing else is changed. Put the package's sha256 into `PKG_SHA256` in
`install.sh` before tagging: the tests check it.

`tests/test.sh` installs into scratch directories only. It checks that a
package rebuilds byte for byte, that the installed tree is exactly the
MANIFEST, that a second run changes nothing, that uninstall leaves nothing,
and that a corrupted download, a file owned by a Debian package, a foreign
file in the way, and the wrong architecture are each refused before anything
is written.

## Licensing

- **This repository** (`install.sh`, `uninstall.sh`, `tests/`, the docs, and
  the ipp-usb quirk) is under the [MIT licence](LICENSE).
- **gutenprint** is not part of this repository's source. The release ships
  it, built and as upstream's source, under its own licence, the
  **GNU GPL version 2 or later**. Its `COPYING` travels inside the package,
  and its complete source is the unmodified upstream tarball published in the
  same release. See [NOTICE.md](NOTICE.md).

Canon and SELPHY are trademarks of Canon Inc. This project is not affiliated
with Canon or with the gutenprint project.
