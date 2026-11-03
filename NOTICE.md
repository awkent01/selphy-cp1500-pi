# Third-party software

## gutenprint 5.3.5

- **What:** printer drivers for CUPS, including the Canon SELPHY CP1500 driver
  (`gutenprint.5.3://canon-cp1500/expert`) and its USB backend
  (`gutenprint53+usb`).
- **Licence:** GNU General Public License, version 2 or (at your option) any
  later version. The full text is `COPYING`, shipped inside the release package
  and installed as `/usr/local/share/gutenprint/doc/COPYING`.
- **Upstream:** <https://gimp-print.sourceforge.net/>
- **Source:** `gutenprint-5.3.5.tar.xz`, sha256
  `f5a9f47de28530b1ae2069cfbc647a9a641baeeabe809bb0ef2b3ec5b9668d70`, published
  unmodified in every release of this repository that carries a gutenprint
  binary. That tarball, with the configure flags in `install.sh`, is the
  complete corresponding source of the binary.
- **Changes:** none to gutenprint's source. One generated file in the install
  tree, `usr/local/lib/gutenprint/5.3/config.summary`, has the building user's
  name and host removed.

Nothing in this repository's git history is gutenprint's: its binaries and its
source are release assets only, and the MIT licence of this repository does not
apply to them.
